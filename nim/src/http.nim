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
##
## This module also holds the port's ONE TLS helper (`tlsActive`,
## `tlsContext`, `newTlsHttpClient`, `newTlsAsyncHttpClient`), because it
## is the module that already owns an HTTP client and the transport is
## what TLS is for. It is conditional: see the section below.

import std/asyncdispatch
import std/httpclient
import std/json
import std/net
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

# ── live TLS, conditional on `-d:wakuTls` ─────────────────────────────

proc tlsActive*(): bool =
  ## Whether THIS build can open a TLS socket. The whole conditional
  ## lives in the two `defined()` tests below: a port that asked the
  ## user to flip a runtime flag would have to carry a "can I do
  ## anything today?" path anyway, and this way the default build
  ## contains no TLS code at all.
  ##
  ## Two switches, and BOTH are needed. `-d:ssl` is the compiler's own:
  ## it links the system libssl and is what `std/httpclient`'s guard
  ## checks, so without it every `https://` request raises
  ## `HttpRequestError("SSL support is not available…")` before it
  ## connects. `-d:wakuTls` is this port's, and it is what says a
  ## developer meant it. A build with only the second one degrades to
  ## the default rather than compiling something half-encrypted.
  ##
  ## No new package: `std/net` plus `wrappers/openssl` are stdlib, and
  ## libssl is the system's, so rule 3 is intact.
  when defined(wakuTls) and defined(ssl): true
  else: false

when defined(wakuTls) and defined(ssl):
  var tlsCtx: SslContext
    ## The process-wide context, built on first use. One, not one per
    ## request: an `SslContext` carries a session cache and a cipher
    ## setup, so a fresh one per call would re-read the trust store on
    ## every request. Only exists in a build that can use it, so the
    ## default build carries no TLS state at all.

proc tlsContext*(): SslContext =
  ## The one TLS context, or `nil` in a build without the flag. Nil is
  ## the honest answer rather than a stub: with no TLS in the build
  ## there is no context to hand out, which is why the constructors
  ## below make the call this module always made instead of passing
  ## nothing to a parameter that does not exist in that build.
  ##
  ## `CVerifyPeer` is the point: the certificate chain is checked
  ## against the system trust store, and `newContext` raises rather than
  ## handing back a context with nothing to verify against. Nothing here
  ## ever asks for `CVerifyNone` — an unverified gateway dial would put
  ## the bot token in front of whoever answered.
  when defined(wakuTls) and defined(ssl):
    if tlsCtx.isNil:
      tlsCtx = newContext(verifyMode = CVerifyPeer)
    return tlsCtx
  else:
    return nil

proc newTlsHttpClient*(timeout = -1): HttpClient =
  ## A blocking client that carries the TLS context, or exactly the
  ## client this module built before this existed when there is no
  ## context to carry. Every live REST call in the port goes through
  ## here or `newTlsAsyncHttpClient`; building a client any other way is
  ## a context-less one, which `tests/test_tls.nim` fails on.
  ##
  ## The two branches are NOT the same line: without `-d:ssl`,
  ## `std/httpclient` declares its own private `SslContext` (a stub
  ## `ref object`, since there is no TLS to hand out) and would not
  ## accept a `std/net` one. So the default branch is literally the call
  ## this module always made, which is what makes "the default build is
  ## unchanged" checkable by reading rather than by testing.
  when defined(wakuTls) and defined(ssl):
    newHttpClient(timeout = timeout, sslContext = tlsContext())
  else:
    newHttpClient(timeout = timeout)

proc newTlsAsyncHttpClient*(): AsyncHttpClient =
  ## The streaming twin: same one-context rule, same default-build
  ## behaviour. Separate because the two constructors differ (this one
  ## has no timeout and returns a `FutureStream` body), and one helper
  ## per shape is still one place to change.
  when defined(wakuTls) and defined(ssl):
    newAsyncHttpClient(sslContext = tlsContext())
  else:
    newAsyncHttpClient()

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
  ## input tool schemas and the stream flag. A toolless request carries
  ## no `tools` key, so only an array iterates — the payload still emits
  ## `"tools": []`, byte-identical to every request that already worked.
  var tools = newJArray()
  let src = req.jget("tools")
  if src.kind == JArray:
    for t in src:
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
  let client = newTlsAsyncHttpClient()
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
