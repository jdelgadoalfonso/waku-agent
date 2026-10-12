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
import std/times

import ./tools
import ./trim
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
    limitReached*: bool
      ## True when the turn hit max_iterations and the reply came
      ## from the one tools-off call after it (guardrail 2), not
      ## from a natural end. Port of `LoopResult.limit_reached`.
    receipt*: JsonNode = newJNull()
    readFirst*: seq[JsonNode] = @[]
    used*: seq[JsonNode] = @[]
      ## The turn's receipt (spec 011 S4), null until `app.respond` builds
      ## one: the pure builder leaves `turn_id`/`model.id` neutral, so only
      ## the turn that owns them can fill them in. The field DEFAULT (not a
      ## bare `JsonNode`) is the point — every `LoopResult(...)` literal
      ## above and in `triage.nim` compiles unchanged, and reading
      ## `result.receipt.kind` stays safe, where a nil JsonNode is a
      ## segfault waiting for its first dereference.

proc usageNum*(node: JsonNode, key: string): int =
  ## A ledger number that may be missing: absent or non-integer usage
  ## reads as 0, like `usageInt` in `trace.nim` — a side call with an
  ## unusual response shape must never crash the turn it meters.
  let v = node.jget(key)
  if v.kind == JInt: int(v.getBiggestInt()) else: 0

proc meteredClient*(client: LlmClient, kind, model: string,
    notify: Observer = nil): LlmClient =
  ## Port of `metered()`: the same client, reporting each call as an
  ## `llm` event with its `kind` (gate/consolidation/triage/quick/judge)
  ## and model, so side calls land in usage.jsonl and the trace like the
  ## loop's own. A call that raises reports nothing and raises as before;
  ## without an observer this is the client it was given. The loop keeps
  ## reporting its own calls — meter the clients around it, never this.
  let wrapped = client
  result = LlmClient(
    create: proc(req: JsonNode): JsonNode {.closure.} =
      let response = wrapped.create(req)
      if not notify.isNil:
        let usage = response.jget("usage")
        let stop = response.jget("stop_reason")
        notify("llm", %*{"kind": kind, "model": model,
          "stop_reason": (if stop.kind == JString: stop.getStr()
            else: ""),
          "usage": {"in": usageNum(usage, "in"),
            "out": usageNum(usage, "out")}})
      response,
    stream: wrapped.stream)

const iterationLimitReply* =
  "(I hit my iteration limit before finishing — try breaking the request into smaller steps.)"

const limitNote* =
  "You have reached the step limit for this turn and cannot call any more " &
  "tools. Answer now from what you already gathered; say plainly what is " &
  "missing or what failed."
  ## `LIMIT_NOTE`: what the one tools-off call after the iteration
  ## limit rides on its system prompt. The loop's own
  ## `iterationLimitReply` is only the fallback when that call
  ## fails or writes nothing.

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

proc toolNames(schemas: seq[JsonNode]): seq[string] =
  ## The tool names in a `tools=` list, in registry order —
  ## the payload of §4.4's per-turn `tools_sent` log.
  for t in schemas:
    result.add(t.jget("name").getStr())

proc finalAnswer*(client: LlmClient, model, system: string,
                  messages: var seq[JsonNode], tools: ToolRegistry,
                  maxTok: int, notify: Observer, trim: Trim,
                  iteration: int, taskTags: seq[string] = @[]): string =
  ## The one tools-off call after the iteration limit: its text, or
  ## "" when it failed or wrote none. Port of `_final_answer`. The
  ## tool definitions are still sent — this turn's filtered set
  ## (§4.1), never the full registry, because Anthropic refuses a
  ## history with tool_use blocks and no tools; `tool_choice`
  ## "none" is what stops the model calling one.
  if not trim.isNil:
    trim(messages)
  let schemas = tools.schemasFor(taskTags)
  var req = %*{"model": model,
               "system": system & "\n\n" & limitNote,
               "max_tokens": maxTok}
  req["messages"] = %messages
  req["tools"] = %schemas
  req["tool_choice"] = %*{"type": "none"}
  var response: JsonNode
  try:
    response = client.create(req)
  except CatchableError:
    return ""
  # kind "final", not "loop": the waterfall keeps it in the last
  # loop's row and the receipt counts it apart; final_answer is
  # the flag to look for.
  notify("llm", %*{"iteration": iteration, "kind": "final",
    "final_answer": true,
    "stop_reason": response["stop_reason"].getStr(),
    "usage": {"in": usageNum(response["usage"], "in"),
      "out": usageNum(response["usage"], "out")},
    "tools_sent": %toolNames(schemas)})
  var blocks = newJArray()
  for b in response["content"]:
    if b.kind == JObject and b.jget("type").getStr() == "text":
      blocks.add(b)
  if blocks.len > 0:
    messages.add(%*{"role": "assistant", "content": blocks})
  var text = ""
  for b in blocks:
    text.add(b.jget("text").getStr())
  text

proc runLoop*(client: LlmClient, model, system: string,
              messages: var seq[JsonNode], tools: ToolRegistry,
              maxIter = 10, maxTok = 2048, observer: Observer = nil,
              stream = false, trim: Trim = nil,
              taskTags: seq[string] = @[]): LoopResult =
  ## Run one agent turn. `messages` is mutated in place — after the call it
  ## holds the full working memory of the turn. Port of `run_loop`.
  ## `trim`, when given, may shorten tool results the model has already
  ## read before each later call, so one large result is not re-sent on
  ## every iteration after it; nil leaves `messages` as they are.
  ##
  ## `taskTags` is the per-turn filter signal (mcp-per-turn-filter
  ## proposal §4.1): the schemas sent to the model come from
  ## `tools.schemasFor(taskTags)`, so a turn that names one
  ## task carries only that task's MCP tools. An empty
  ## signal is allow-by-default (§4.4) and sends the full set —
  ## the registry itself is untouched, so `execute` still runs
  ## a tool the filter held back.
  let notify: Observer = if observer.isNil:
    proc(kind: string, ev: JsonNode) = discard
  else:
    observer
  let canStream = stream and not client.stream.isNil
  # The turn's view of the registry, computed once: the same
  # filtered set goes out on every call this turn, including
  # the tools-off call after the iteration limit, which must
  # still carry the schemas its history's tool_use blocks name.
  let schemas = tools.schemasFor(taskTags)
  # §4.4: what the model actually saw this turn, for traces
  # and the dashboard — the names, in registry order.
  let toolsSent = toolNames(schemas)
  for iteration in 1 .. maxIter:
    result.iterations = iteration
    if not trim.isNil and iteration > 1:
      trim(messages)
    var req = %*{"model": model, "system": system,
                 "max_tokens": maxTok}
    req["messages"] = %messages
    req["tools"] = %schemas
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
    llmEv["tools_sent"] = %toolsSent
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
      let started = epochTime()
      let output = tools.execute(call["name"].getStr(),
                                 call.jget("input"))
      # Spec 012: how long the call took, for the trace — stamped on the
      # event the turn keeps AND the one observers see (same node, both).
      let event = %*{"tool": call["name"].getStr(),
        "args": call.jget("input"), "output": output,
        "call_id": call.jget("id").getStr(),
        "duration_ms": max(0,
          int((epochTime() - started) * 1000))}
      result.toolCalls.add(event)
      notify("tool", event)
      toolResults.add(%*{"type": "tool_result",
        "tool_use_id": call["id"].getStr(), "content": output})
    messages.add(%*{"role": "user", "content": toolResults})
  # ---- guardrail 2: ran out of iterations. Everything gathered so
  # far is in `messages`, so ask once more with tools off for an
  # answer from it, rather than throwing it away. If that call
  # fails, say so the old way.
  result.limitReached = true
  result.reply = finalAnswer(client, model, system, messages, tools,
                             maxTok, notify, trim, maxIter + 1,
                             taskTags)
  if result.reply.len == 0:
    result.reply = iterationLimitReply
  return result
