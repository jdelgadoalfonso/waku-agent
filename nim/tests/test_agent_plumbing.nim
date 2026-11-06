## T2.3 RED: the agent enable list reaches the gate through env, prompt
## and binder. Pure and offline: the client is scripted, no key, no spawn.
##
## Narrow on purpose — this suite pins the PLUMBING. Spawning a worker for
## a delegated route is execution wiring, a later task, so with no
## delegate injected the graph keeps its five nodes and the turn fails
## open to the loop rather than answering half a turn.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/config
import ../src/graph/engine
import ../src/loop
import ../src/triage
import ../src/wire

type
  Script = ref object
    items: seq[JsonNode]
    pos: int
    seen: seq[JsonNode]
      ## every request the gate sent, so a test can read the prompt

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    script.seen.add(req)
    result = script.items[script.pos]
    inc script.pos)

const noHome = "waku-agent-plumbing-nohome"
  ## Never created: `todaysEvents` looks for `calendar.ics`, finds none
  ## and answers "(no calendar)", so the binder needs no filesystem.

proc saved(name: string): tuple[value: string, was: bool] =
  (getEnv(name), existsEnv(name))

proc restore(name: string, env: tuple[value: string, was: bool]) =
  if env.was: putEnv(name, env.value)
  else: delEnv(name)

suite "agent plumbing T2.3 config":

  test "no WAKU_AGENTS enables no agent route":
    let env = saved("WAKU_AGENTS")
    delEnv("WAKU_AGENTS")
    var s = defaultSettings()
    assert s.agents.len == 0
    s.loadFromEnv()
    assert s.agents.len == 0
    restore("WAKU_AGENTS", env)

  test "WAKU_AGENTS parses, trims and dedupes":
    let env = saved("WAKU_AGENTS")
    putEnv("WAKU_AGENTS", " brief , gather,brief,,  ")
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.agents == @["brief", "gather"]
    restore("WAKU_AGENTS", env)

  test "a blank WAKU_AGENTS enables nothing":
    let env = saved("WAKU_AGENTS")
    putEnv("WAKU_AGENTS", "   ")
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.agents.len == 0
    restore("WAKU_AGENTS", env)

  test "the plugin list is untouched by the agent list":
    let env = saved("WAKU_AGENTS")
    putEnv("WAKU_AGENTS", "brief")
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.plugins == @["triage", "gather"]
    restore("WAKU_AGENTS", env)

suite "agent plumbing T2.3 prompt":

  test "no enabled agent renders the untouched prompt":
    assert triagePromptFor() == triagePrompt
    # quick/full are the gate's own paths, never agent routes
    assert triagePromptFor(@["quick", "full"]) == triagePrompt

  test "each enabled agent joins the route line and the legend":
    let prompt = triagePromptFor(@["brief", "gather"])
    assert "\"quick\" or \"full\" or \"brief\" or \"gather\"" in prompt
    # the quick/full wording survives, byte for byte
    assert "quick — greetings, thanks, acknowledgements, pure small talk" in prompt
    assert "full  — anything mentioning tasks, schedules, people, notes," in prompt
    assert prompt.endsWith("User message: {message}")  # the message stays last

  test "classify hands the enabled agent to the model":
    let script = Script(items: @[textResp("{\"route\": \"brief\"}")])
    assert classifyMessage(scriptedClient(script), "mini", "brief me",
      allowedRoutes = @["quick", "full", "brief"]) ==
      (route: "brief", reason: "")
    let prompt = script.seen[0]["messages"][0]["content"].getStr()
    assert "\"brief\"" in prompt
    assert "User message: brief me" in prompt
    assert "{{" notin prompt  # escaped braces are rendered for the model

suite "agent plumbing T2.3 binder":

  test "no delegate keeps the five-node topology":
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        ("quick", ""),
      calendarFn = proc(): string = "",
      quickFn = proc(s: JsonNode): string = "hi",
      fullFn = proc(s: JsonNode, n: Observer): LoopResult = LoopResult(),
      agentRoutes = @["brief"])  # delegateFn stays nil on purpose
    assert g.describe()["nodes"].len == 5

  test "an enabled agent with no delegate keeps today's behavior":
    let script = Script(items: @[textResp("{\"route\": \"brief\"}")])
    var ran = false
    let turn = triageGraphTurn(scriptedClient(script), "mini", noHome,
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        ran = true
        LoopResult(reply: "loop answered", toolCalls: @[], iterations: 1),
      agents = @["brief"])
    let (answered, res) = turn("brief me", nil, false)
    # nothing can receive "brief" yet, so it is not offered to the model
    assert "\"brief\"" notin script.seen[0]["messages"][0]["content"].getStr()
    assert ran  # the model's agent route failed open to full
    assert answered
    assert res.reply == "loop answered"

  test "the binder threads the delegate seam":
    let script = Script(items: @[textResp("{\"route\": \"brief\"}")])
    var delegated = ""
    let turn = triageGraphTurn(scriptedClient(script), "mini", noHome,
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        raise newException(ValueError, "must not run"),
      agents = @["brief"],
      delegateFn = proc(s: JsonNode, n: Observer): JsonNode =
        delegated = s.jget("route").getStr()
        %*{"reply": "delegated reply", "tool_calls": [],
            "iterations": 1})
    let (answered, res) = turn("brief me", nil, false)
    # with a delegate bound the gate offers the route it can actually run
    assert "\"brief\"" in script.seen[0]["messages"][0]["content"].getStr()
    assert delegated == "brief"
    # Slice 2a: the delegate answers through the existing result path.
    assert answered == true
    assert res.reply == "delegated reply"

  test "a fail-open delegate falls back to no answer":
    let script = Script(items: @[textResp("{\"route\": \"brief\"}")])
    let turn = triageGraphTurn(scriptedClient(script), "mini", noHome,
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        raise newException(ValueError, "must not run"),
      agents = @["brief"],
      delegateFn = proc(s: JsonNode, n: Observer): JsonNode =
        %*{"fail_open": true})
    let (answered, _) = turn("brief me", nil, false)
    assert answered == false
