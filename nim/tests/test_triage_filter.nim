## Slice B RED: the gate's per-turn task filter.
## Pure and offline: `routesForTask` narrows the offer, and one turn pins
## that the list the filter returns is the same one the gate prompt and
## the graph receive (the domain==build invariant).

import std/json
import std/strutils
import std/unittest

import ../src/graph/agents
import ../src/loop
import ../src/triage

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

const noHome = "/tmp/waku-trifilter-nonexistent-home"
  ## `todaysEvents` only stats `<home>/calendar.ics`, so a missing home
  ## reads "(no calendar)" and nothing is ever created.

suite "slice B gate filter":
  test "a matching tag narrows the offer":
    enrollAgent(%*{"name": "alpha", "kind": "graph",
      "tasks": ["research"]})
    enrollAgent(%*{"name": "beta", "kind": "graph", "tasks": ["brief"]})
    let routes = @["quick", "full", "alpha", "beta"]
    assert routesForTask(routes, @["research"]) == @["quick", "full", "alpha"]

  test "an empty signal restores the full offer":
    # `delta` is tagless: without the empty-signal early return the
    # loop below would keep it (agents == 1, no fallback) and return
    # [quick, full, delta] instead of the full offer.
    enrollAgent(%*{"name": "delta", "kind": "graph"})
    let routes = @["quick", "full", "alpha", "delta"]
    assert routesForTask(routes, @[]) == routes

  test "a route without tasks is always listed":
    enrollAgent(%*{"name": "gamma", "kind": "graph"})
    let routes = @["quick", "full", "alpha", "gamma"]
    assert routesForTask(routes, @["brief"]) ==
      @["quick", "full", "gamma"]

  test "all agents filtered out restores the full offer":
    let routes = @["quick", "full", "alpha", "beta"]
    assert routesForTask(routes, @["unrelated"]) == routes

  test "the filter is what the prompt and the graph receive":
    var seen: seq[JsonNode] = @[]
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      seen.add(copy(req))
      textResp("{\"route\": \"alpha\", \"reason\": \"research\"}"))
    let delegateStubs: Delegates = @[
      (agent: "alpha",
       fn: proc(st: JsonNode, n: Observer): JsonNode =
         %*{"reply": "alpha answered"}),
      (agent: "beta",
       fn: proc(st: JsonNode, n: Observer): JsonNode =
         %*{"reply": "beta answered"})]
    let turn = triageGraphTurn(client, "mini", noHome,
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        LoopResult(reply: "full answered", toolCalls: @[], iterations: 1),
      agents = @["alpha", "beta"],
      delegates = delegateStubs,
      taskTagsFn = proc(m: string): seq[string] = @["brief"])
    let (answered, res) = turn("summarise the sprint", nil, false)
    # `alpha` is filtered out of the answer domain, so the model's
    # `alpha` fails open to full instead of reaching the delegate; a
    # filter applied to the graph but not the domain would leave the
    # router with no `alpha` label and answer nothing.
    assert answered
    assert res.reply == "full answered"
    assert seen.len == 1
    let prompt = seen[0]["messages"][0]["content"].getStr()
    assert "\"quick\" or \"full\" or \"beta\"" in prompt
    assert "beta" in prompt
    assert "alpha" notin prompt
    # Reverse divergence (graph offering more than the domain) needs
    # no pin: the model can only emit labels inside the domain, and
    # both lists come from the single `offered` value in the closure.
