## Phase 3d tests: the loop against scripted clients. Pure and offline.

import std/json
import std/unittest

import ../src/loop
import ../src/tools

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
