## THE LOOP — port of `waku/loop/agent.py`: observe → reason → act → repeat.
##
## Every agent framework is this while-loop with more indirection. Messages
## are `JsonNode` objects in the loop's Anthropic-shape dialect; the client
## seam is two closures (`create`, optional `stream`) so scripted fakes drive
## offline tests exactly like Python's `ScriptedClient`.
##
## Streaming errors: a refusal (4xx) is a decision, not a transport fault —
## it is re-raised, never retried without streaming (that would double what
## a metered tenant spends on being told no). Any other streaming hiccup
## falls back to one plain call.

import std/json

import ./tools
import ./wire

type
  LlmRefused* = object of CatchableError
    ## A provider refusal carrying its HTTP status (mirrors the SDK's
    ## `APIStatusError` shape the Python loop branches on).
    statusCode*: int

  TextFn* = proc(delta: string) {.closure.}
  StreamFn* = proc(req: JsonNode, onText: TextFn): JsonNode {.closure.}

  LlmClient* = object
    create*: proc(req: JsonNode): JsonNode {.closure.}
    stream*: StreamFn

  Observer* = proc(kind: string, ev: JsonNode) {.closure.}

  LoopResult* = object
    reply*: string
    toolCalls*: seq[JsonNode]
    iterations*: int

const iterationLimitReply* =
  "(I hit my iteration limit before finishing — try breaking the request into smaller steps.)"

proc errorText*(exc: ref CatchableError): string =
  ## What the user reads when a call fails. Port of `error_text`: a refusal
  ## that already wrote a human sentence wins; anything else keeps
  ## `Type: message`. Python duck-types `message`+`status_code` on any
  ## exception; typed Nim narrows the check to `LlmRefused` — the loop's
  ## only refusal carrier (transport maps provider 4xx to it).
  if exc of LlmRefused and exc.msg.len > 0:
    return exc.msg
  return $exc.name & ": " & exc.msg

proc textReply*(content: JsonNode): string =
  ## The human-visible reply: concatenated text blocks.
  textOf(content)

proc runLoop*(client: LlmClient, model, system: string,
              messages: var seq[JsonNode], tools: ToolRegistry,
              maxIter = 10, maxTok = 2048, observer: Observer = nil,
              stream = false): LoopResult =
  ## Run one agent turn. `messages` is mutated in place — after the call it
  ## holds the full working memory of the turn. Port of `run_loop`.
  let notify: Observer = if observer.isNil:
    proc(kind: string, ev: JsonNode) = discard
  else:
    observer
  let canStream = stream and not client.stream.isNil
  for iteration in 1 .. maxIter:
    result.iterations = iteration
    var req = %*{"model": model, "system": system,
                 "max_tokens": maxTok}
    req["messages"] = %messages
    req["tools"] = %tools.schemas()
    var response: JsonNode = nil
    if canStream:
      try:
        response = client.stream(req, proc(delta: string) =
          notify("text", %*{"delta": delta}))
      except LlmRefused as exc:
        if exc.statusCode >= 400 and exc.statusCode < 500:
          raise
        response = nil
      except CatchableError:
        response = nil
    if response.isNil:
      response = client.create(req)
    var llmEv = newJObject()
    llmEv["iteration"] = %iteration
    llmEv["stop_reason"] = %response["stop_reason"].getStr()
    var usev = newJObject()
    usev["in"] = %response["usage"].jget("in").getInt()
    usev["out"] = %response["usage"].jget("out").getInt()
    llmEv["usage"] = usev
    notify("llm", llmEv)
    messages.add(%*{"role": "assistant", "content": response["content"]})
    var toolUses: seq[JsonNode] = @[]
    for b in response["content"]:
      if b.kind == JObject and b.jget("type").getStr() == "tool_use":
        toolUses.add(b)
    if toolUses.len == 0:
      result.reply = textReply(response["content"])
      return result
    var toolResults = newJArray()
    for call in toolUses:
      # `notify` passthrough for `wantsNotify` tools is deferred with those
      # tools (none registered yet); the registry contract carries the flag.
      let output = tools.execute(call["name"].getStr(),
                                 call.jget("input"))
      let event = %*{"tool": call["name"].getStr(),
        "args": call.jget("input"), "output": output}
      result.toolCalls.add(event)
      notify("tool", event)
      toolResults.add(%*{"type": "tool_result",
        "tool_use_id": call["id"].getStr(), "content": output})
    messages.add(%*{"role": "user", "content": toolResults})
  result.reply = iterationLimitReply
  return result
