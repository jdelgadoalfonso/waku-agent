## T2.2 RED: router generalizes to quick|full|<agent>.
## Classify accepts an allow-list; the graph gains a delegate node.
## Self-contained scripted client (mirrors test_workflows.nim).

import std/json
import std/strutils
import std/unittest

import ../src/graph/engine
import ../src/loop
import ../src/triage
import ../src/wire

type
  Script = ref object
    items: seq[JsonNode]
    pos: int

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    result = script.items[script.pos]
    inc script.pos)

suite "router agents T2.2":

  test "classify accepts an enrolled agent route when allowed":
    let script = Script(items: @[textResp("{\"route\": \"gather\"}")])
    assert classifyMessage(scriptedClient(script), "mini", "brief me",
      allowedRoutes = @["quick", "full", "gather"]) ==
      (route: "gather", reason: "")

  test "default allow-list still fails an agent route open":
    let bad = Script(items: @[textResp("{\"route\": \"gather\"}")])
    let (route, reason) = classifyMessage(scriptedClient(bad), "mini",
      "brief me")
    assert route == "full"
    assert "gather" in reason

  test "agent route reaches the delegate node":
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        ("gather", "morning shape"),
      calendarFn = proc(): string = "",
      quickFn = proc(s: JsonNode): string = raise
        newException(ValueError, "must not run"),
      fullFn = proc(s: JsonNode, n: Observer): LoopResult = raise
        newException(ValueError, "must not run"),
      agentRoutes = @["gather"],
      delegateFn = proc(s: JsonNode, n: Observer): JsonNode =
        %*{"delegated_to": s.jget("route").getStr()})
    var state = %*{"message": "brief me"}
    discard runGraph(g, state)
    assert state["delegation"]["delegated_to"].getStr() == "gather"
