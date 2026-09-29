## Phase 4a tests: the graph engine and its node factories. Pure and offline:
## scripted clients drive the llm/agent nodes, no network, no `.waku/` writes.

import std/json
import std/strutils
import std/unittest

import ../src/graph/engine
import ../src/graph/nodes
import ../src/loop
import ../src/tools

type
  Script = ref object
    items: seq[JsonNode]
    pos: int
    seen: seq[JsonNode]

  Recorder = ref object
    events: seq[JsonNode]

  Log = ref object
    items: seq[string]

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

proc toolResp(id, name: string, input: JsonNode): JsonNode =
  %*{"stop_reason": "tool_use", "usage": {"in": 1, "out": 1},
     "content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}

proc scriptedClient(script: Script): LlmClient =
  ## Play back the scripted responses in order (cursor, never `delete`:
  ## `let`-aliasing a seq element and then deleting its slot dangles the
  ## reference under ORC). Requests are recorded for prompt assertions.
  LlmClient(create: proc(req: JsonNode): JsonNode =
    script.seen.add(copy(req))
    result = script.items[script.pos]
    inc script.pos)

proc observe(r: Recorder): Observer =
  ## Record every event with its kind tagged in, in arrival order.
  result = proc(kind: string, ev: JsonNode) =
    var e = copy(ev)
    e["kind"] = %kind
    r.events.add(e)

proc kinds(r: Recorder): seq[string] =
  for e in r.events:
    result.add(e["kind"].getStr())

proc firstEventOfKind(r: Recorder, kind: string): JsonNode =
  for e in r.events:
    if e["kind"].getStr() == kind:
      return e

proc noopNode(name: string): Node =
  newNode(name, proc(s: JsonNode, n: Observer): JsonNode = newJObject())

suite "phase 4a run_graph":

  test "waves run in order; nodes wire the drain to END":
    let log = Log()
    var g = Graph(name: "flow")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("a")
      var o = newJObject()
      o["a_out"] = %"first"
      o))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("b")
      var o = newJObject()
      o["b_out"] = %"second"
      o))
    g.addEdge(START, "a")
    g.addEdge("a", "b")
    var state = newJObject()
    let rec = Recorder()
    discard runGraph(g, state, rec.observe())
    assert state["a_out"].getStr() == "first"
    assert state["b_out"].getStr() == "second"
    assert state["errors"].len == 0
    assert log.items == @["a", "b"]
    assert rec.kinds() == @["graph_start", "node_start", "node_end",
                            "node_start", "node_end", "graph_end"]
    let endEv = rec.events[^1]
    assert endEv["steps"].getInt() == 2
    assert endEv["path"][0].getStr() == "a"
    assert endEv["path"][1].getStr() == "b"
    assert endEv["error"].kind == JNull  # a clean run has no first error

  test "fan-out wave: both starts fire before either node runs":
    let log = Log()
    var g = Graph(name: "fan")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("a")
      var o = newJObject()
      o["left"] = %"L"
      o))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("b")
      var o = newJObject()
      o["right"] = %"R"
      o))
    g.addEdge(START, "a")
    g.addEdge(START, "b")
    var state = newJObject()
    let rec = Recorder()
    discard runGraph(g, state, rec.observe())
    assert state["left"].getStr() == "L"
    assert state["right"].getStr() == "R"
    # Python notifies every node_start before the wave runs; Nim keeps that
    # order and runs the wave sequentially (documented divergence).
    assert rec.kinds() == @["graph_start", "node_start", "node_start",
                            "node_end", "node_end", "graph_end"]
    assert log.items == @["a", "b"]

  test "same-wave collision raises GraphStateCollision":
    var g = Graph(name: "clash")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["shared"] = %"from a"
      o))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["shared"] = %"from b"
      o))
    g.addEdge(START, "a")
    g.addEdge(START, "b")
    var state = newJObject()
    try:
      discard runGraph(g, state)
      assert false, "must raise"
    except GraphStateCollision as e:
      # the current node is named first (the earlier writer second), the
      # same order Python's f-string uses
      assert "'b' and 'a' both wrote 'shared'" in e.msg

  test "max_visits bounds a cycle and records the error once":
    let log = Log()

    proc cycle(s: JsonNode, n: Observer): JsonNode =
      log.items.add("a")
      var o = newJObject()
      o["next"] = %"again"
      return o

    var g = Graph(name: "cycle")
    g.addNode(newNode("a", cycle, maxVisits = 2))
    g.addEdge(START, "a")
    g.addRouter("a", keyRouter("next", "END"), @[(label: "again", dst: "a")])
    var state = newJObject()
    discard runGraph(g, state)
    assert log.items.len == 2
    assert state["errors"]["a"].getStr() == "max_visits=2 reached"
    assert state["next"].getStr() == "again"

  test "max_steps stops the run and records the engine error":

    proc spin(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["next"] = %"again"
      return o

    var g = Graph(name: "spin")
    g.addNode(newNode("a", spin, maxVisits = 100))
    g.addEdge(START, "a")
    g.addRouter("a", keyRouter("next", "END"), @[(label: "again", dst: "a")])
    var state = newJObject()
    discard runGraph(g, state, nil, 5)
    assert state["errors"]["engine"].getStr() == "max_steps=5 reached"
    assert state["next"].getStr() == "again"

  test "unknown router label surfaces in errors and drains to END":
    var g = Graph(name: "route")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["kind"] = %"weird"
      o))
    g.addNode(noopNode("b"))
    g.addNode(newNode("c", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["c_out"] = %"never"
      o))
    g.addEdge(START, "a")
    g.addEdge("a", "c")  # a router node fires no edges — the router takes over
    g.addRouter("a", keyRouter("kind", "END"), @[(label: "known", dst: "b")])
    var state = newJObject()
    let rec = Recorder()
    discard runGraph(g, state, rec.observe())
    assert state["errors"]["a"].getStr() ==
      "router returned unknown label 'weird'"
    assert not state.hasKey("c_out")  # c never ran: no jump fired
    let routeEv = rec.firstEventOfKind("route")
    assert routeEv["target"].getStr() == "END"
    assert routeEv["reason"].getStr() == "weird"
    assert routeEv["router"].getStr() == "a"

  test "router with a known label jumps (a route is a jump, not a dependency)":
    var g = Graph(name: "route")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["kind"] = %"go"
      o))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["b_out"] = %"reached"
      o))
    g.addEdge(START, "a")
    g.addRouter("a", keyRouter("kind", "END"), @[(label: "go", dst: "b")])
    var state = newJObject()
    discard runGraph(g, state)
    assert state["b_out"].getStr() == "reached"

  test "a jump and a ready node dedupe into one run (no spurious max_visits)":
    let log = Log()
    var g = Graph(name: "dupe")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("a")
      var o = newJObject()
      o["a_out"] = %"1"
      o))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("b")
      var o = newJObject()
      o["next"] = %"join"
      o))
    g.addNode(newNode("c", proc(s: JsonNode, n: Observer): JsonNode =
      log.items.add("c")
      var o = newJObject()
      o["c_out"] = %"done"
      o))
    g.addEdge(START, "a")
    g.addEdge(START, "b")
    g.addEdge("a", "c")   # a fires c's dep during wave 1's merge
    g.addRouter("b", keyRouter("next", "END"), @[(label: "join", dst: "c")])
    var state = newJObject()
    discard runGraph(g, state)
    assert log.items == @["a", "b", "c"]  # c ran once, not twice
    assert state["errors"].len == 0       # no spurious max_visits error
    assert state["c_out"].getStr() == "done"

  test "node error surfaces in errors; on_error jumps to the fix":
    var g = Graph(name: "err")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      raise newException(ValueError, "kaput"), onError = "fix"))
    g.addNode(newNode("fix", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["fixed"] = %"yes"
      o))
    g.addEdge(START, "a")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["errors"]["a"].getStr() == "ValueError: kaput"
    assert state["fixed"].getStr() == "yes"

  test "node error without on_error drains to END":
    var g = Graph(name: "err")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      raise newException(ValueError, "kaput")))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["b_out"] = %"never"
      o))
    g.addEdge(START, "a")
    g.addEdge("a", "b")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["errors"]["a"].getStr() == "ValueError: kaput"
    assert not state.hasKey("b_out")

  test "private keys never merge":
    var g = Graph(name: "priv")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["_secret"] = %"x"
      o["public"] = %"y"
      o))
    g.addEdge(START, "a")
    var state = newJObject()
    discard runGraph(g, state)
    assert not state.hasKey("_secret")
    assert state["public"].getStr() == "y"

  test "pre-seeded errors survive the run":
    var g = Graph(name: "seed")
    g.addNode(noopNode("a"))
    g.addEdge(START, "a")
    var state = %*{"errors": {"prior": "before"}}
    discard runGraph(g, state)
    assert state["errors"]["prior"].getStr() == "before"
    assert state["errors"].len == 1

  test "a malformed errors entry is replaced by an empty object":
    var g = Graph(name: "bad")
    g.addNode(noopNode("a"))
    g.addEdge(START, "a")
    var state = %*{"errors": "not an object"}
    discard runGraph(g, state)
    assert state["errors"].kind == JObject
    assert state["errors"].len == 0

  test "a state that is not a JSON object starts as an empty one":
    var g = Graph(name: "null")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["a_out"] = %"1"
      o))
    g.addEdge(START, "a")
    var state = newJNull()
    discard runGraph(g, state)
    assert state["a_out"].getStr() == "1"

  test "a non-object event through the tagged observer is a node error":
    var g = Graph(name: "ev")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      n("custom", %"not an object")
      var o = newJObject()
      o["a_out"] = %"never"
      o))
    g.addEdge(START, "a")
    var state = newJObject()
    let rec = Recorder()
    discard runGraph(g, state, rec.observe())
    assert state["errors"]["a"].getStr() ==
      "CatchableError: node event must be an object to carry node=a"
    assert "custom" notin rec.kinds()  # the event never reached the observer
    assert not state.hasKey("a_out")

  test "a non-object or nil node output merges nothing":
    var g = Graph(name: "out")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode = %"str"))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode = nil))
    g.addEdge(START, "a")
    g.addEdge(START, "b")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["errors"].len == 0  # nothing to merge is not an error
    assert state.len == 1            # only the errors object landed

suite "phase 4a node factories":

  test "llm node formats the prompt and writes the reply":
    let script = Script(items: @[textResp("positive")])
    var g = Graph(name: "classify")
    g.addNode(llmNode("classify", "tone: {text}", "tone",
                      scriptedClient(script), "m"))
    g.addEdge(START, "classify")
    var state = newJObject()
    state["text"] = %"I love it"
    discard runGraph(g, state)
    assert state["tone"].getStr() == "positive"
    assert script.seen[0]["messages"][0]["content"].getStr() == "tone: I love it"
    assert script.seen[0]["model"].getStr() == "m"

  test "llm node raises a node error on an unknown placeholder":
    let script = Script(items: @[])
    var g = Graph(name: "classify")
    g.addNode(llmNode("classify", "tone: {missing}", "tone",
                      scriptedClient(script), "m"))
    g.addEdge(START, "classify")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["errors"]["classify"].getStr() ==
      "KeyError: no state key filled '{missing}'"
    assert script.seen.len == 0  # the client was never called

  test "llm node treats a pre-seeded _key as an unknown placeholder":
    let script = Script(items: @[])
    var g = Graph(name: "classify")
    g.addNode(llmNode("classify", "tone: {_x}", "tone",
                      scriptedClient(script), "m"))
    g.addEdge(START, "classify")
    var state = newJObject()
    state["_x"] = %"seeded"
    discard runGraph(g, state)
    assert state["errors"]["classify"].getStr() ==
      "KeyError: no state key filled '{_x}'"
    assert script.seen.len == 0  # the client was never called

  test "llm node escapes {{ and }} like Python's format":
    let script = Script(items: @[textResp("ok")])
    var g = Graph(name: "classify")
    g.addNode(llmNode("classify", "{{literal}} {text}", "tone",
                      scriptedClient(script), "m"))
    g.addEdge(START, "classify")
    var state = newJObject()
    state["text"] = %"x"
    discard runGraph(g, state)
    assert script.seen[0]["messages"][0]["content"].getStr() == "{literal} x"

  test "agent node runs a full loop turn and tags its events":
    let script = Script(items: @[toolResp("t1", "echo", %*{"text": "x"}),
                                 textResp("done")])
    var reg: ToolRegistry
    reg.register(Tool(name: "echo", description: "e",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string = "echo:" & args["text"].getStr()))
    var g = Graph(name: "agent")
    g.addNode(agentNode("agent", "result", scriptedClient(script), "m", "sys",
                        reg))
    g.addEdge(START, "agent")
    var state = newJObject()
    state["message"] = %"go"
    let rec = Recorder()
    discard runGraph(g, state, rec.observe())
    assert state["result"]["reply"].getStr() == "done"
    assert state["result"]["iterations"].getInt() == 2
    assert state["result"]["tool_calls"][0]["output"].getStr() == "echo:x"
    # the loop's llm/tool events passed through tagged with node=
    var tagged = 0
    for e in rec.events:
      let kind = e["kind"].getStr()
      if kind == "llm" or kind == "tool":
        assert e["node"].getStr() == "agent"
        inc tagged
    assert tagged == 3  # two llm events + one tool event

  test "tool node reads in_keys and writes out_key":
    var g = Graph(name: "tool")
    g.addNode(toolNode("lookup",
      proc(args: seq[JsonNode]): JsonNode =
        var o = newJObject()
        o["found"] = %(args[0].getStr() & "!")
        o,
      @["name"], "result"))
    g.addEdge(START, "lookup")
    var state = newJObject()
    state["name"] = %"waku"
    discard runGraph(g, state)
    assert state["result"]["found"].getStr() == "waku!"

  test "tool node passes JNull for a missing in_key":
    var g = Graph(name: "tool")
    g.addNode(toolNode("lookup",
      proc(args: seq[JsonNode]): JsonNode =
        var o = newJObject()
        o["missing"] = %(args[0].kind == JNull)
        o,
      @["nope"], "result"))
    g.addEdge(START, "lookup")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["result"]["missing"].getBool()

  test "keyRouter reads the key and falls back to the default":
    let route = keyRouter("kind", "unknown")
    assert route(%*{"kind": "urgent"}) == "urgent"
    assert route(%*{"kind": ""}) == "unknown"
    assert route(%*{}) == "unknown"
    assert route(%*{"kind": 3}) == "unknown"

  test "describe renders the topology as data":
    var g = Graph(name: "shape")
    g.addNode(llmNode("classify", "tone: {text}", "tone",
                      scriptedClient(Script()), "m"))
    g.addNode(noopNode("save"))
    g.addEdge(START, "classify")
    g.addEdge("classify", "save")
    g.addRouter("classify", keyRouter("tone", "END"),
                @[(label: "a", dst: "save"), (label: "b", dst: "save")])
    let d = g.describe()
    assert d["name"].getStr() == "shape"
    assert d["nodes"].len == 2
    assert d["nodes"][0]["name"].getStr() == "classify"
    assert d["nodes"][0]["kind"].getStr() == "llm"
    assert d["nodes"][1]["kind"].getStr() == "fn"
    # unconditional edges first, then conditional ones deduped per target
    assert d["edges"][0] == %*{"src": "START", "dst": "classify",
                               "conditional": false}
    assert d["edges"][1] == %*{"src": "classify", "dst": "save",
                               "conditional": false}
    assert d["edges"][2] == %*{"src": "classify", "dst": "save",
                               "conditional": true}
    assert d["edges"].len == 3

  test "reserved names and unknown endpoints fail at build time":
    var g = Graph(name: "v")
    g.addNode(noopNode("a"))
    expect ValueError:
      g.addNode(newNode(START, proc(s: JsonNode, n: Observer): JsonNode =
        newJObject()))
    expect ValueError:
      g.addNode(newNode(END, proc(s: JsonNode, n: Observer): JsonNode =
        newJObject()))
    expect ValueError:
      g.addEdge("a", "nope")
    expect ValueError:
      g.addEdge("nope", "a")
    expect ValueError:
      g.addRouter("nope", keyRouter("k", "END"), @[])
    expect ValueError:
      g.addRouter("a", keyRouter("k", "END"), @[(label: "x", dst: "nope")])

  test "re-adding a node replaces it and keeps its position":
    var g = Graph(name: "replace")
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["v"] = %"old"
      o))
    g.addNode(newNode("b", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["v"] = %"middle"
      o))
    g.addNode(newNode("a", proc(s: JsonNode, n: Observer): JsonNode =
      var o = newJObject()
      o["w"] = %"new"
      o))
    let d = g.describe()
    assert d["nodes"].len == 2
    assert d["nodes"][0]["name"].getStr() == "a"  # position kept
    g.addEdge(START, "a")
    g.addEdge(START, "b")  # if the old `a` were still in, the wave would collide
    var state = newJObject()
    discard runGraph(g, state)
    assert state["w"].getStr() == "new"     # the replacement ran
    assert state["v"].getStr() == "middle"  # b ran
