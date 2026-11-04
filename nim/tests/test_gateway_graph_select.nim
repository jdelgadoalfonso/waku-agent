## Gateway graph selector: per-source hot-swap without restart.
## Offline only: no network, no `.waku/` writes outside temp dirs.

import std/json
import std/os
import std/tables
import std/unittest

import ../src/app
import ../src/dashboard
import ../src/loop

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

type
  Script = ref object
    items: seq[JsonNode]
    pos: int

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    result = script.items[script.pos]
    inc script.pos)

suite "gateway graph selector":
  test "per-source key wins over the global flag":
    var env = initTable[string, string]()
    env["WAKU_GRAPH_WORKFLOWS"] = "1"
    env["WAKU_GRAPH_TELEGRAM"] = "off"
    assert graphSelectorFor("telegram", env) == "off"
    assert graphSelectorFor("discord", env) == "1"

  test "off loop and unknown resolve to nil (fail open to loop)":
    let script = Script(items: @[textResp("x")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    assert resolveGatewayGraph("off", client, "mini", "/tmp", binder).isNil
    assert resolveGatewayGraph("loop", client, "mini", "/tmp", binder).isNil
    assert resolveGatewayGraph("", client, "mini", "/tmp", binder).isNil
    assert resolveGatewayGraph("nope-graph", client, "mini", "/tmp", binder).isNil

  test "triage resolves to a turn closure":
    let script = Script(items: @[textResp("x")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    assert not resolveGatewayGraph("triage", client, "mini", "/tmp", binder).isNil
    assert not resolveGatewayGraph("1", client, "mini", "/tmp", binder).isNil
