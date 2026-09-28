## HTTP transport — the network half of phase 3.
##
## Posts JSON and reads responses/SSE over HTTPS via `AsyncHttpClient`
## (the sync client buffers the whole body, which would defeat live text
## deltas). The procs below stay synchronous: one `waitFor` pump per call.
## Line splitting is transport-owned; chunk reassembly stays in `sse.nim`.
##
## URL convention (SDK-style bases, path appended per wire):
## OpenAI-compatible base like `https://api.openai.com/v1` + `/chat/completions`;
## Anthropic base like `https://api.anthropic.com` + `/v1/messages`.
## Tests run against a localhost stub (see `tests/test_http.nim`).

import std/asyncdispatch
import std/httpclient
import std/json
import std/strutils

import ./loop
import ./sse
import ./wire

type
  WireKind* = enum
    wkOpenAi, wkAnthropic

  Transport* = object
    baseUrl*: string
    apiKey*: string
    wire*: WireKind

proc openAiHeaders(t: Transport): HttpHeaders =
  newHttpHeaders([("Content-Type", "application/json"),
                  ("Authorization", "Bearer " & t.apiKey)])

proc anthropicHeaders(t: Transport): HttpHeaders =
  newHttpHeaders([("Content-Type", "application/json"),
                  ("x-api-key", t.apiKey),
                  ("anthropic-version", "2023-06-01")])

proc statusCode(status: string): int =
  ## `"401 Unauthorized"` -> 401.
  try: parseInt(status.split(' ')[0])
  except ValueError: 0

proc refusedMessage(wire: WireKind, body: string): string =
  ## Best-effort human sentence from an error body, else raw text.
  ## Truncated to 200 chars (deviation: Python shows the full `str(exc)`;
  ## a bounded message cannot flood a chat turn).
  try:
    let parsed = parseJson(body)
    let err = parsed.jget("error")
    if err.kind == JObject:
      let msg = err.jget("message").getStr()
      if msg.len > 0:
        return msg
    elif err.kind == JString and err.getStr().len > 0:
      return err.getStr()
  except JsonParsingError:
    discard
  return body.strip()[0 ..< min(200, body.strip().len)]

proc raiseRefused(wire: WireKind, status, body: string) {.noReturn.} =
  var e: ref LlmRefused
  new(e)
  e.statusCode = statusCode(status)
  e.msg = refusedMessage(wire, body)
  raise e

proc pumpLines(fs: FutureStream[string],
               onLine: proc(line: string) {.closure.}) {.async.} =
  ## Buffer socket chunks, emit `\n`-terminated lines (SSE framing).
  var buf = ""
  while true:
    let (ok, chunk) = await fs.read()
    if not ok:
      break
    buf.add(chunk)
    var start = 0
    for i in 0 ..< buf.len:
      if buf[i] == '\n':
        onLine(buf[start ..< i].strip())
        start = i + 1
    if start > 0:
      buf = buf[start .. ^1]
  if buf.strip().len > 0:
    onLine(buf.strip())

proc openAiPayload(req: JsonNode, stream: bool): JsonNode =
  ## The loop's Anthropic-shape request -> chat.completions kwargs.
  var kwargs = toOpenAi(req["model"].getStr(), req["messages"],
    req["max_tokens"].getInt(), req.jget("system").getStr(),
    req.jget("tools"))
  if stream:
    kwargs["stream"] = %true
    kwargs["stream_options"] = %*{"include_usage": true}
  return kwargs

proc anthropicPayload(req: JsonNode, stream: bool): JsonNode =
  ## The loop's request is already Anthropic-shaped; pass through with the
  ## input tool schemas and the stream flag.
  var tools = newJArray()
  for t in req.jget("tools"):
    tools.add(%*{"name": t["name"].getStr(),
      "description": t["description"].getStr(),
      "input_schema": t["input_schema"]})
  result = %*{"model": req["model"].getStr(), "system": req["system"].getStr(),
    "messages": req["messages"], "max_tokens": req["max_tokens"].getInt(),
    "tools": tools, "stream": stream}

proc anthropicAssembled(resp: JsonNode): JsonNode =
  ## A `/v1/messages` response (blocks already loop-shaped) -> assembled.
  let usage = resp.jget("usage")
  result = %*{"stop_reason": resp.jget("stop_reason").getStr("end_turn"),
    "content": resp.jget("content")}
  var usev = %*{"in": 0, "out": 0}
  if usage.kind == JObject:
    if usage.hasKey("input_tokens"):
      usev["in"] = usage["input_tokens"]
    if usage.hasKey("output_tokens"):
      usev["out"] = usage["output_tokens"]
  result["usage"] = usev

proc postJson(t: Transport, path: string, payload: JsonNode): Future[(AsyncHttpClient, AsyncResponse)] {.async.} =
  let client = newAsyncHttpClient()
  let headers = if t.wire == wkOpenAi: t.openAiHeaders()
                else: t.anthropicHeaders()
  let resp = await client.request(t.baseUrl & path, HttpPost, $payload, headers)
  return (client, resp)

proc fetch(t: Transport, path: string, payload: JsonNode): tuple[status, body: string] =
  ## One POST: status+body with the client CLOSED again (a fresh client
  ## per call keeps connections from leaking across a long-lived loop).
  let (client, resp) = waitFor postJson(t, path, payload)
  result.status = resp.status
  result.body = waitFor resp.body
  client.close()

proc createRemote*(t: Transport, req: JsonNode): JsonNode =
  ## One non-streaming turn leg. OpenAI wire retries once with the legacy
  ## `max_tokens` key when the error is about that parameter (see wire).
  if t.wire == wkOpenAi:
    var kwargs = openAiPayload(req, false)
    for attempt in 0 .. 1:
      let (status, body) = fetch(t, "/chat/completions", kwargs)
      if status.startsWith("2"):
        return fromOpenAi(req["model"].getStr(), parseJson(body))
      if attempt == 0 and shouldRetryWithMaxTokens(body):
        kwargs = withMaxTokensKey(kwargs)
        continue
      raiseRefused(t.wire, status, body)
  else:
    let (status, body) = fetch(t, "/v1/messages", anthropicPayload(req, false))
    if status.startsWith("2"):
      return anthropicAssembled(parseJson(body))
    raiseRefused(t.wire, status, body)

proc streamRemote*(t: Transport, req: JsonNode, onText: TextFn): JsonNode =
  ## One streaming turn leg: pump SSE lines into the wire's accumulator.
  ## Transport hiccups propagate (the loop decides fallback); refusals
  ## (4xx) propagate as `LlmRefused` for the loop's no-retry rule.
  if t.wire == wkOpenAi:
    var st: OpenAiSse
    var done = false
    proc onLine(line: string) =
      if not line.startsWith("data: ") or done:
        return
      let payload = line[6 .. ^1]
      if payload == "[DONE]":
        done = true
        return
      for d in feedOpenAi(st, parseJson(payload)):
        onText(d)
    let (client, resp) = waitFor postJson(t, "/chat/completions",
                                        openAiPayload(req, true))
    if not resp.status.startsWith("2"):
      let body = waitFor resp.body
      client.close()
      raiseRefused(t.wire, resp.status, body)
    waitFor pumpLines(resp.bodyStream, onLine)
    client.close()
    return finalOpenAi(st)
  else:
    var st: AnthropicSse
    proc onLine(line: string) =
      if not line.startsWith("data: "):
        return
      for d in feedAnthropic(st, parseJson(line[6 .. ^1])):
        onText(d)
    let (client, resp) = waitFor postJson(t, "/v1/messages",
                                        anthropicPayload(req, true))
    if not resp.status.startsWith("2"):
      let body = waitFor resp.body
      client.close()
      raiseRefused(t.wire, resp.status, body)
    waitFor pumpLines(resp.bodyStream, onLine)
    client.close()
    return finalAnthropic(st)

proc toLlmClient*(t: Transport): LlmClient =
  ## Wire the transport into the loop seam.
  let tt = t
  LlmClient(
    create: proc(req: JsonNode): JsonNode = createRemote(tt, req),
    stream: proc(req: JsonNode, onText: TextFn): JsonNode =
      streamRemote(tt, req, onText))
