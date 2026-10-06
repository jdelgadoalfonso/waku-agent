## Phase 3d tests: the loop against scripted clients. Pure and offline.

import std/json
import std/strutils
import std/unittest

import ../src/loop
import ../src/tools
import ../src/trim

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

proc toolResp(id, name: string, input: JsonNode): JsonNode =
  %*{"stop_reason": "tool_use", "usage": {"in": 1, "out": 1},
     "content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}

type Script = ref object
  items: seq[JsonNode]
  pos: int

proc scriptedClient(script: Script): LlmClient =
  ## Play back the scripted responses in order (cursor, never `delete`:
  ## `let`-aliasing a seq element and then deleting its slot dangles the
  ## reference under ORC and corrupts the heap downstream).
  LlmClient(create: proc(req: JsonNode): JsonNode =
    result = script.items[script.pos]
    inc script.pos)

proc echoRegistry(): ToolRegistry =
  var reg: ToolRegistry
  reg.register(Tool(name: "echo", description: "e",
    inputSchema: %*{"type": "object"},
    fn: proc(args: JsonNode): string = "echo:" & args["text"].getStr()))
  reg

suite "phase 3d run_loop":
  test "text-only turn replies in one iteration":
    let script = Script(items: @[textResp("hello")])
    var messages = @[%*{"role": "user", "content": "hi"}]
    var llmEvents: seq[JsonNode] = @[]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      echoRegistry(), 10, 2048,
                      proc(kind: string, ev: JsonNode) =
                        if kind == "llm": llmEvents.add(ev))
    assert res.reply == "hello"
    assert res.iterations == 1
    assert res.toolCalls.len == 0
    assert messages.len == 2
    assert llmEvents.len == 1
    assert llmEvents[0]["stop_reason"].getStr() == "end_turn"

  test "tool turn executes and feeds results back":
    let script = Script(items: @[toolResp("t1", "echo", %*{"text": "x"}), textResp("done")])
    var messages = @[%*{"role": "user", "content": "go"}]
    var toolEvents: seq[JsonNode] = @[]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      echoRegistry(), 10, 2048,
                      proc(kind: string, ev: JsonNode) =
                        if kind == "tool": toolEvents.add(ev))
    assert res.reply == "done"
    assert res.iterations == 2
    assert res.toolCalls.len == 1
    assert res.toolCalls[0]["output"].getStr() == "echo:x"
    assert toolEvents.len == 1
    assert messages.len == 4
    assert messages[2]["content"][0]["type"].getStr() == "tool_result"
    assert messages[2]["content"][0]["tool_use_id"].getStr() == "t1"

  test "unknown tool surfaces as text and the turn continues":
    let script = Script(items: @[toolResp("t1", "nope", %*{}), textResp("ok")])
    var messages = @[%*{"role": "user", "content": "go"}]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      echoRegistry())
    assert res.toolCalls[0]["output"].getStr() == "Error: unknown tool 'nope'"
    assert res.reply == "ok"

  test "iteration limit stops with the honest message":
    var items: seq[JsonNode] = @[]
    for i in 1 .. 5:
      items.add(toolResp("t" & $i, "echo", %*{"text": "x"}))
    let script = Script(items: items)
    var messages = @[%*{"role": "user", "content": "go"}]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      echoRegistry(), 2, 2048)
    assert res.reply == iterationLimitReply
    assert res.iterations == 2
    assert res.toolCalls.len == 2

  test "stream path emits text deltas then assembles":
    var createCalls = 0
    let client = LlmClient(
      create: proc(req: JsonNode): JsonNode =
        inc createCalls
        textResp("fallback"),
      stream: proc(req: JsonNode, onText: TextFn): JsonNode =
        onText("Hel")
        onText("lo")
        textResp("Hello"))
    var messages = @[%*{"role": "user", "content": "hi"}]
    var deltas: seq[string] = @[]
    let res = runLoop(client, "m", "sys", messages, echoRegistry(), 10, 2048,
      proc(kind: string, ev: JsonNode) =
        if kind == "text": deltas.add(ev["delta"].getStr()),
      stream = true)
    assert deltas == @["Hel", "lo"]
    assert res.reply == "Hello"
    assert createCalls == 0

  test "stream refusal is not retried, hiccup falls back":
    var createCalls = 0
    var refused: ref LlmRefused
    new(refused)
    refused.msg = "bad key"
    refused.statusCode = 401
    let refClient = LlmClient(
      create: proc(req: JsonNode): JsonNode =
        inc createCalls
        textResp("x"),
      stream: proc(req: JsonNode, onText: TextFn): JsonNode =
        raise refused)
    var messages = @[%*{"role": "user", "content": "hi"}]
    try:
      discard runLoop(refClient, "m", "sys", messages, echoRegistry(),
                      10, 2048, nil, true)
      assert false, "must raise"
    except LlmRefused as e:
      assert e.msg == "bad key"
    assert createCalls == 0
    let flaky = LlmClient(
      create: proc(req: JsonNode): JsonNode =
        inc createCalls
        textResp("recovered"),
      stream: proc(req: JsonNode, onText: TextFn): JsonNode =
        raise newException(CatchableError, "connection reset"))
    var messages2 = @[%*{"role": "user", "content": "hi"}]
    let res = runLoop(flaky, "m", "sys", messages2, echoRegistry(),
                      10, 2048, nil, true)
    assert res.reply == "recovered"

suite "phase 3d error_text":
  test "refusal message wins, bugs keep their type":
    var refused: ref LlmRefused
    new(refused)
    refused.msg = "Free tier used up."
    refused.statusCode = 403
    assert errorText(refused) == "Free tier used up."
    var silent: ref LlmRefused
    new(silent)
    silent.statusCode = 500
    assert errorText(silent) == "LlmRefused: "
    assert errorText(newException(ValueError, "kaput")) == "ValueError: kaput"

suite "metered side clients":
  test "a metered call reports kind, model and usage, returning the reply":
    let inner = LlmClient(create: proc(req: JsonNode): JsonNode =
      %*{"stop_reason": "end_turn", "usage": {"in": 7, "out": 3},
         "content": [{"type": "text", "text": "yes"}]})
    var seen: seq[JsonNode] = @[]
    var kinds: seq[string] = @[]
    let obs: Observer = proc(kind: string, ev: JsonNode) =
      kinds.add(kind)
      seen.add(ev)
    let gated = meteredClient(inner, "gate", "mini", obs)
    let res = gated.create(%*{"model": "mini"})
    assert res["content"][0]["text"].getStr() == "yes"
    assert kinds == @["llm"]
    assert seen[0]["kind"].getStr() == "gate"
    assert seen[0]["model"].getStr() == "mini"
    assert seen[0]["usage"]["in"].getInt() == 7
    assert seen[0]["usage"]["out"].getInt() == 3

  test "without an observer the client passes through silently":
    var calls = 0
    let inner = LlmClient(create: proc(req: JsonNode): JsonNode =
      inc calls
      %*{"content": []})
    let gated = meteredClient(inner, "gate", "mini")
    discard gated.create(%*{"model": "mini"})
    assert calls == 1

  test "a raising call reports nothing and raises as before":
    var kinds: seq[string] = @[]
    let inner = LlmClient(create: proc(req: JsonNode): JsonNode =
      raise newException(IOError, "down"))
    let obs: Observer = proc(kind: string, ev: JsonNode) =
      kinds.add(kind)
    let gated = meteredClient(inner, "gate", "mini", obs)
    expect IOError:
      discard gated.create(%*{"model": "mini"})
    assert kinds.len == 0

  test "an unusual shape meters zeros instead of crashing the turn":
    var kinds: seq[string] = @[]
    let inner = LlmClient(create: proc(req: JsonNode): JsonNode =
      %*{"content": [{"type": "text", "text": "x"}]})
    let obs: Observer = proc(kind: string, ev: JsonNode) =
      kinds.add(kind)
    let gated = meteredClient(inner, "consolidation", "mini", obs)
    discard gated.create(%*{"model": "mini"})
    assert kinds == @["llm"]

suite "trim hook":
  test "trim runs before the second call and nil leaves messages as they are":
    let big = "x".repeat(5000)
    var seen: seq[int] = @[]
    var secondReq: JsonNode = nil
    var calls = 0
    let client = LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      inc calls
      if calls == 1:
        return toolResp("t1", "echo", %*{"text": "hi"})
      secondReq = req["messages"]
      textResp("done"))
    var messages = @[%*{"role": "user", "content": "go"}]
    let reg = echoRegistry()
    let hook: Trim = proc(msgs: var seq[JsonNode]) {.closure.} =
      seen.add(msgs.len)
      for m in msgs.mitems:
        if m.kind == JObject and m.hasKey("content") and m["content"].kind == JString and m["content"].getStr() == "go":
          m["content"] = %"go-trimmed"
      discard big
    let res = runLoop(client, "m", "sys", messages, reg, 10, 2048, nil, false, hook)
    assert res.reply == "done"
    assert seen == @[3], "trim runs once, before iteration 2"
    assert secondReq[0]["content"].getStr() == "go-trimmed"
    var plain = @[%*{"role": "user", "content": "go"}]
    let script = Script(items: @[toolResp("t1", "echo", %*{"text": "x"}), textResp("ok")])
    let res2 = runLoop(scriptedClient(script), "m", "sys", plain, echoRegistry())
    assert res2.reply == "ok"
    assert plain[0]["content"].getStr() == "go"

suite "spec 012 tool stamps":
  test "every tool event carries its call id and how long it took":
    let script = Script(items: @[toolResp("t1", "echo", %*{"text": "x"}), textResp("done")])
    var messages = @[%*{"role": "user", "content": "go"}]
    var toolEvents: seq[JsonNode] = @[]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      echoRegistry(), 10, 2048,
                      proc(kind: string, ev: JsonNode) =
                        if kind == "tool": toolEvents.add(ev))
    assert res.toolCalls[0]["call_id"].getStr() == "t1"
    assert res.toolCalls[0]["duration_ms"].getInt() >= 0
    assert toolEvents.len == 1
    assert toolEvents[0]["call_id"].getStr() == "t1"
    assert toolEvents[0]["duration_ms"].getInt() >= 0

  test "an unknown tool is stamped too, not just the happy path":
    let script = Script(items: @[toolResp("t9", "nope", %*{}), textResp("ok")])
    var messages = @[%*{"role": "user", "content": "go"}]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      echoRegistry())
    assert res.toolCalls[0]["call_id"].getStr() == "t9"
    assert res.toolCalls[0]["duration_ms"].getInt() >= 0
