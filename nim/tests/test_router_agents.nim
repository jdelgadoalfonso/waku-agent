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
        %*{"reply": "delegated", "tool_calls": [], "iterations": 1})
    var state = %*{"message": "brief me"}
    discard runGraph(g, state)
    assert state["result"]["reply"].getStr() == "delegated"

  test "fail-open delegate leaves no result for the binder":
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
        %*{"fail_open": true})
    var state = %*{"message": "brief me"}
    discard runGraph(g, state)
    assert not state.hasKey("result")

## T16 (S10): the gate must not hand a memory or identity question to the
## digest agent. The worker holds no memory by design (slice 9), so a
## `gather` route answers a generic briefing instead of failing. Two pins
## keep that honest without a network call: the prompt has to say which
## question belongs to which brain, and `classifyMessage` relays that
## answer instead of inventing one.

type
  GateScript = ref object
    prompts: seq[string]

proc readsOnlyThePrompt(script: GateScript): LlmClient =
  ## A scripted small model that believes what it reads: it names `full`
  ## only when the prompt says a memory/identity question is the loop's
  ## and keeps the agent out of it, and the agent route otherwise. It
  ## records the rendered prompt, so a prompt that loses the rule
  ## misroutes exactly like the live gate did.
  LlmClient(create: proc(req: JsonNode): JsonNode =
    let prompt = req["messages"][0]["content"].getStr()
    script.prompts.add(prompt)
    let fullIsMemory = "identity" in prompt and
      "personal preferences" in prompt and
      "never a memory or identity question" in prompt
    textResp("{\"route\": \"" & (if fullIsMemory: "full" else: "gather") &
      "\"}"))

suite "router agents T16 misrouting":

  test "the gate prompt names memory and identity as the loop's":
    assert "identity" in triagePrompt
    assert "personal preferences" in triagePrompt
    assert "nothing to look up" in triagePrompt  # quick stays small talk

  test "the agent legend keeps digest work apart from memory questions":
    let prompt = triagePromptFor(@["quick", "full", "gather"])
    assert "gather — only an explicit digest, briefing or report" in prompt
    assert "never a memory or identity question" in prompt

  test "an agent that is not gather gets no digest rule":
    let prompt = triagePromptFor(@["quick", "full", "brief"])
    assert "digest" notin prompt
    assert "never a memory or identity question" notin prompt

  test "memory and identity questions classify as full, not the agent":
    let script = GateScript()
    let client = readsOnlyThePrompt(script)
    for message in ["what do you remember about me?", "who am I?",
                    "qué recuerdas de mí"]:
      assert classifyMessage(client, "mini", message,
        allowedRoutes = @["quick", "full", "gather"]) ==
        (route: "full", reason: "")
    # the rule the model obeyed reached it, and so did the question
    assert "never a memory or identity question" in script.prompts[0]
    assert "what do you remember about me?" in script.prompts[0]

## T17 (S1,S2): N enabled agents, N delegates. One `delegate_agent` node
## serves every agent route, so the NODE has to pick the delegate the route
## names. Before this slice one `DelegateFn` guarded every route, so the
## second enabled agent reached the first one's guard and failed open with
## a delegate of its own sitting right there. Two scripted delegates, no
## spawn and no new productive worker: `gather` and a fake `brief`.

type
  DelegateCalls = ref object
    names: seq[string]

proc scriptedDelegate(calls: DelegateCalls, agent, reply: string):
    DelegateFn =
  ## Answers for its own agent and records that it ran, so a pin can tell
  ## "the right delegate answered" from "someone answered".
  result = proc(s: JsonNode, n: Observer): JsonNode {.closure.} =
    calls.names.add(agent)
    %*{"reply": reply, "tool_calls": [], "iterations": 1}

proc twoAgentGraph(route: string, calls: DelegateCalls): Graph =
  ## The shape T17 is about: two agent routes, one delegate each, and a
  ## single `delegate_agent` node between them.
  buildTriageGraph(
    classifyFn = proc(m: string): tuple[route, reason: string] =
      (route: route, reason: "routed by the gate"),
    calendarFn = proc(): string = "",
    quickFn = proc(s: JsonNode): string = raise
      newException(ValueError, "must not run"),
    fullFn = proc(s: JsonNode, n: Observer): LoopResult = raise
      newException(ValueError, "must not run"),
    agentRoutes = @["gather", "brief"],
    delegates = @[
      (agent: "gather", fn: scriptedDelegate(calls, "gather", "digest")),
      (agent: "brief", fn: scriptedDelegate(calls, "brief", "briefing"))])

suite "router agents T17 multi-agent dispatch":

  test "each agent route answers through its own delegate":
    for expected in [(route: "gather", reply: "digest"),
                     (route: "brief", reply: "briefing")]:
      let calls = DelegateCalls()
      var state = %*{"message": "do the " & expected.route & " thing"}
      discard runGraph(twoAgentGraph(expected.route, calls), state)
      assert state["result"]["reply"].getStr() == expected.reply
      assert calls.names == @[expected.route]

  test "a route with no delegate fails open, never another agent's":
    # Fail-open stays an empty patch: the binder falls back to the loop.
    # Answering through the first delegate would run the wrong worker.
    let calls = DelegateCalls()
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        (route: "brief", reason: "no worker behind that route yet"),
      calendarFn = proc(): string = "",
      quickFn = proc(s: JsonNode): string = "",
      fullFn = proc(s: JsonNode, n: Observer): LoopResult = LoopResult(),
      agentRoutes = @["gather", "brief"],
      delegates = @[(agent: "gather",
        fn: scriptedDelegate(calls, "gather", "digest"))])
    var state = %*{"message": "brief me"}
    discard runGraph(g, state)
    assert not state.hasKey("result")
    assert calls.names.len == 0

  test "N delegates keep one node and one route per agent":
    let calls = DelegateCalls()
    let g = twoAgentGraph("gather", calls)
    var delegateNodes = 0
    for node in g.describe()["nodes"]:
      if node["name"].getStr() == "delegate_agent":
        inc delegateNodes
    assert delegateNodes == 1
    # both agent labels reach that one node: N agents cost N router
    # labels, not N nodes
    var labels: seq[string] = @[]
    for r in g.routers:
      if r.src == "gather":
        for target in r.targets:
          if target.dst == "delegate_agent":
            labels.add(target.label)
    assert labels == @["gather", "brief"]

  test "a single delegateFn still serves every route it is bound for":
    # T2.2's shape is untouched: no `delegates` means the one fn answers.
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        (route: "brief", reason: "one delegate"),
      calendarFn = proc(): string = "",
      quickFn = proc(s: JsonNode): string = "",
      fullFn = proc(s: JsonNode, n: Observer): LoopResult = LoopResult(),
      agentRoutes = @["gather", "brief"],
      delegateFn = proc(s: JsonNode, n: Observer): JsonNode =
        %*{"reply": "the only delegate", "tool_calls": [],
           "iterations": 1})
    var state = %*{"message": "brief me"}
    discard runGraph(g, state)
    assert state["result"]["reply"].getStr() == "the only delegate"
