## Gateway graph selector: per-source hot-swap without restart.
## Offline only: no network, no `.waku/` writes outside temp dirs.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import db_connector/db_sqlite

import ../src/app
import ../src/dashboard
import ../src/db
import ../src/loop

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

type
  Script = ref object
    items: seq[JsonNode]
    pos: int
    seen: seq[JsonNode]

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    script.seen.add(copy(req))
    result = script.items[script.pos]
    inc script.pos)

const noHome = "waku-agent-graph-select-nohome"
  ## A home with no calendar file: the gate still runs, offline.

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc selectSettings(home: string, agents: seq[string]): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
    smallModel: "mini", maxIterations: 10, maxTokens: 8192,
    historyTurns: 12, graphWorkflows: true, agents: agents)

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

  test "gather without a bound turn stays nil (fail open to loop)":
    let script = Script(items: @[textResp("x")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    assert resolveGatewayGraph("gather", client, "mini", "/tmp", binder).isNil

  test "gather with a bound turn resolves to it":
    let script = Script(items: @[textResp("x")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    let gatherTurn: GraphTurn = proc(userMessage: string, notify: Observer,
        stream: bool): tuple[answered: bool, res: LoopResult] =
      (true, LoopResult(reply: "briefing", toolCalls: @[], iterations: 1))
    let bound = resolveGatewayGraph("gather", client, "mini", "/tmp", binder, gatherTurn)
    assert not bound.isNil
    let (answered, res) = bound("hola", nil, false)
    assert answered
    assert res.reply == "briefing"

  test "dashboard and cli sources read their own keys, then the global":
    var env = initTable[string, string]()
    env["WAKU_GRAPH_WORKFLOWS"] = "triage"
    env["WAKU_GRAPH_DASHBOARD"] = "off"
    env["WAKU_GRAPH_CLI"] = "gather"
    assert graphSelectorFor("dashboard", env) == "off"
    assert graphSelectorFor("cli", env) == "gather"
    assert graphSelectorFor("telegram", env) == "triage"

  test "plugin miss and unknown names stay nil (fail open to loop)":
    let script = Script(items: @[textResp("x")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    assert resolveGatewayGraph("plugin:missing", client, "mini", "/tmp",
      binder).isNil

suite "gateway graph selector: live delegation seam (slice 2c)":

  test "triage binds the agent route and answers through the delegate":
    let script = Script(items: @[textResp("{\"route\": \"gather\"}")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      raise newException(ValueError, "the delegate answers, not the loop")
    let bound = resolveGatewayGraph("triage", client, "mini", noHome,
      binder, nil, @["gather"],
      proc(st: JsonNode, n: Observer): JsonNode =
        %*{"reply": "delegated reply", "tool_calls": [],
           "iterations": 1})
    assert not bound.isNil
    let (answered, res) = bound("gather news", nil, false)
    assert answered
    assert res.reply == "delegated reply"

  test "triage with agents but no delegate keeps quick|full":
    let script = Script(items: @[textResp("{\"route\": \"full\"}")])
    let client = scriptedClient(script)
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop answered", toolCalls: @[], iterations: 1)
    let bound = resolveGatewayGraph("triage", client, "mini", noHome,
      binder, nil, @["gather"])
    let (answered, res) = bound("gather news", nil, false)
    # nothing can receive "gather" without a delegate, so it is not offered
    assert "\"gather\"" notin
      script.seen[0]["messages"][0]["content"].getStr()
    assert answered
    assert res.reply == "loop answered"

  test "reselect threads the enabled worker into the gate":
    let home = freshHome("waku-graph-reselect-seam")
    defer: removeDir(home)
    let db = connectDb(home)
    defer: db.close()
    let script = Script(items: @[textResp("{\"route\": \"quick\"}"),
                                 textResp("quick answer")])
    var w = newWaku(selectSettings(home, @["gather"]), scriptedClient(script),
      db)
    var env = initTable[string, string]()
    env["WAKU_GRAPH_CLI"] = "triage"
    reselectGraphTurn(w, "cli", env)
    assert not w.graphTurn.isNil
    let (answered, res) = w.graphTurn("hi", nil, false)
    assert answered
    assert res.reply == "quick answer"
    # the per-turn binder must keep offering what the worker can run
    assert "\"gather\"" in script.seen[0]["messages"][0]["content"].getStr()

  test "reselect with no enabled worker keeps today's quick|full graph":
    let home = freshHome("waku-graph-reselect-plain")
    defer: removeDir(home)
    let db = connectDb(home)
    defer: db.close()
    let script = Script(items: @[textResp("{\"route\": \"quick\"}"),
                                 textResp("quick answer")])
    var w = newWaku(selectSettings(home, @[]), scriptedClient(script), db)
    var env = initTable[string, string]()
    env["WAKU_GRAPH_CLI"] = "triage"
    reselectGraphTurn(w, "cli", env)
    assert not w.graphTurn.isNil
    let (answered, res) = w.graphTurn("hi", nil, false)
    assert answered
    assert res.reply == "quick answer"
    assert "\"gather\"" notin
      script.seen[0]["messages"][0]["content"].getStr()
