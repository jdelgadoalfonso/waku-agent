## Step-3/4 pins: the REAL host table and a graph built from a manifest.
##
## Offline. `fixture_graph_plugin.nim` is compiled to a temp dir with the
## local compiler, the model is a scripted client (the `Script` pattern from
## `test_graph.nim`), and nothing opens a socket: the one `fetch` case dials
## a closed loopback port to pin the failure envelope.
##
## What is pinned, in order: every host function's envelope; `needs` both as
## a narrowed table (nulls) and as a per-call refusal; `stateKeys` per handle;
## `buildPluginGraph` end to end through a real `.so` (the second node sees
## the first's output, the llm node's metered call reaches the observer, the
## router's declarative routes jump, and `log` lands in the trace); every
## malformed `routes` shape refused at load; a router with no routes refused
## at build time; a handle retired after the run and expired by the safety
## net; fail-open for a graph whose plugin is not loaded; and the registry
## listing `plugin:chainfx` after registration.

import std/json
import std/os
import std/osproc
import std/strutils
import std/unittest

import ../src/dashboard
import ../src/graph/engine
import ../src/graph/hostfns
import ../src/graph/plugins
import ../src/graph/registry
import ../src/loop
import ../src/tools
import ../src/wire

type
  Script = ref object
    ## Played back in order; requests are recorded for prompt assertions.
    ## (Cursor, never `delete`: aliasing a seq element and then deleting its
    ## slot dangles the reference under ORC — same note as `test_graph`.)
    items: seq[JsonNode]
    pos: int
    seen: seq[JsonNode]

  Recorder = ref object
    ## Kind and payload kept apart: a metered llm event carries its OWN
    ## `kind` field ("plugin"), which a tagged payload would overwrite.
    kinds: seq[string]
    events: seq[JsonNode]

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 7, "out": 3},
     "content": [{"type": "text", "text": text}]}

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    script.seen.add(copy(req))
    result = script.items[script.pos]
    inc script.pos)

proc record(r: Recorder): Observer =
  result = proc(kind: string, ev: JsonNode) =
    r.kinds.add(kind)
    r.events.add(copy(ev))

proc firstEvent(r: Recorder, kind: string): JsonNode =
  for i in 0 ..< r.kinds.len:
    if r.kinds[i] == kind:
      return r.events[i]

proc echoTool(name: string): Tool =
  Tool(name: name, description: "echo", inputSchema: %*{"type": "object"},
    fn: proc(args: JsonNode): string =
      "echo:" & args.jget("text").getStr(""))

proc boomTool(): Tool =
  Tool(name: "boom", description: "raises", inputSchema: %*{"type": "object"},
    fn: proc(args: JsonNode): string =
      raise newException(CatchableError, "boom"))

proc answerOf(free: proc(value: cstring) {.cdecl, gcsafe.},
              raw: cstring): JsonNode =
  ## Read one host answer and free it through the HOST's allocator — the
  ## half of the ownership rule this side owns.
  doAssert not raw.isNil
  let text = $raw
  free(raw)
  parseJson(text)

proc envelopeValue(env: JsonNode): JsonNode =
  assert env.jget("ok").getBool(false), $env
  env["value"]

proc errorOf(env: JsonNode): string =
  assert not env.jget("ok").getBool(true), "expected ok:false, got " & $env
  env.jget("error").getStr()

proc buildFixture(dir, name: string, extra = ""): string =
  ## Compile the graph fixture to `dir/name`; fail loudly with the compiler
  ## output when it does not build. `extra` is the `-d:` switch a manifest
  ## variant needs (the broken `routes` shapes).
  let nim = findExe("nim")
  assert nim.len > 0, "nim must be on PATH to build the fixture"
  let target = dir / name
  let cmd = nim & " c --app:lib --panics:off --hints:off " & extra &
    " -o:" & target & " tests/fixture_graph_plugin.nim"
  let (output, code) = execCmdEx(cmd)
  assert code == 0, "fixture build failed: " & output
  return target

proc declOf(plugin: LoadedPlugin, name: string): PluginNodeDecl =
  for d in plugin.nodes:
    if d.name == name:
      return d
  assert false, "fixture missing node " & name

suite "plugin host functions (step 3)":

  test "the base table carries the ABI version and all six functions":
    let script = Script(items: @[textResp("x")])
    let table = hostFns(newHostScope(scriptedClient(script), ToolRegistry()))
    assert table.abiVersion == pluginAbiVersion
    assert not table.llmComplete.isNil
    assert not table.toolCall.isNil
    assert not table.stateKeys.isNil
    assert not table.fetch.isNil
    assert not table.stringFree.isNil
    assert not table.log.isNil

  test "llmComplete answers the whole response and meters the call":
    let script = Script(items: @[textResp("hola")])
    let rec = Recorder()
    let table = hostFns(newHostScope(scriptedClient(script), ToolRegistry()))
    beginHostCall(11, %*{"message": "hi"}, @["llm"], record(rec))
    let env = answerOf(table.stringFree, table.llmComplete(11,
      """{"model": "script-model", "messages": []}""".cstring))
    endHostCall(11)
    let value = envelopeValue(env)
    # The whole assembled response crosses, not just the text: a plugin can
    # read stop_reason and usage the same way the loop does.
    assert value["content"][0]["text"].getStr() == "hola"
    assert value["stop_reason"].getStr() == "end_turn"
    assert value["usage"]["in"].getInt() == 7
    assert value["usage"]["out"].getInt() == 3
    assert script.seen.len == 1
    assert script.seen[0]["model"].getStr() == "script-model"
    # Metering: the call reached the observer as a plugin-kind llm event.
    assert rec.kinds == @["llm"]
    assert rec.events[0]["kind"].getStr() == "plugin"
    assert rec.events[0]["model"].getStr() == "script-model"
    assert rec.events[0]["usage"]["in"].getInt() == 7

  test "llmComplete without a model uses the agent's default":
    let script = Script(items: @[textResp("hola")])
    let table = hostFns(newHostScope(scriptedClient(script),
      ToolRegistry(), "agent-model"))
    beginHostCall(14, %*{"message": "hi"}, @["llm"])
    let env = answerOf(table.stringFree, table.llmComplete(14,
      """{"messages": []}""".cstring))
    endHostCall(14)
    assert envelopeValue(env)["content"][0]["text"].getStr() == "hola"
    # The host filled in the agent's model before the call crossed.
    assert script.seen[0]["model"].getStr() == "agent-model"

  test "needs narrows the table to nulls and refuses an undeclared call":
    let script = Script(items: @[textResp("x")])
    let table = hostFns(newHostScope(scriptedClient(script), ToolRegistry()))
    let narrowed = hostFnsFor(table, @["llm"])
    assert not narrowed.llmComplete.isNil
    assert narrowed.toolCall.isNil      # not asked for -> not enabled
    assert narrowed.fetch.isNil
    assert not narrowed.stateKeys.isNil # the run's own input is not a capability
    assert not narrowed.stringFree.isNil
    assert not narrowed.log.isNil
    assert narrowed.abiVersion == pluginAbiVersion
    # And the same rule per call: a node that declares nothing cannot reach
    # the model even though the base table carries the function.
    beginHostCall(12, newJObject(), @[])
    let denied = answerOf(table.stringFree, table.llmComplete(12,
      """{"model": "m", "messages": []}""".cstring))
    endHostCall(12)
    assert "needs: llm" in errorOf(denied)
    assert script.seen.len == 0
    # Outside a node call there is no input and no declared capability.
    assert "no live node call" in errorOf(answerOf(table.stringFree,
      table.toolCall(99, "echo".cstring, "{}".cstring)))

  test "toolCall hands tool text back, including a tool's own errors":
    var tools = ToolRegistry()
    tools.register(echoTool("echo"))
    tools.register(boomTool())
    let table = hostFns(newHostScope(scriptedClient(Script()), tools))
    beginHostCall(13, newJObject(), @["tool"])
    let ok = answerOf(table.stringFree, table.toolCall(13, "echo".cstring,
      """{"text": "hi"}""".cstring))
    assert envelopeValue(ok).getStr() == "echo:hi"
    # A failing tool is an observation, not a broken host call: ok:true with
    # `ToolRegistry.execute`'s text, exactly like the loop sees it.
    let failed = answerOf(table.stringFree, table.toolCall(13, "boom".cstring,
      "{}".cstring))
    assert "Error running boom" in envelopeValue(failed).getStr()
    let missing = answerOf(table.stringFree, table.toolCall(13, "nope".cstring,
      "{}".cstring))
    assert "unknown tool" in envelopeValue(missing).getStr()
    # A malformed payload is the one `ok:false` case.
    assert "not JSON" in errorOf(answerOf(table.stringFree,
      table.toolCall(13, "echo".cstring, "{not json".cstring)))
    endHostCall(13)

  test "stateKeys reads the live input per handle and hides `_` keys":
    let table = hostFns(newHostScope(scriptedClient(Script()), ToolRegistry()))
    beginHostCall(21, %*{"message": "hola", "_notify": "host-private"},
                  @[])
    let value = envelopeValue(answerOf(table.stringFree, table.stateKeys(21,
      """["message", "_notify", "missing"]""".cstring)))
    assert value["message"].getStr() == "hola"
    assert value["_notify"].kind == JNull  # never crosses
    assert value["missing"].kind == JNull
    endHostCall(21)
    # A retired handle has no input left.
    assert "no live node call" in errorOf(answerOf(table.stringFree,
      table.stateKeys(21, """["message"]""".cstring)))
    # Handles do not share input.
    beginHostCall(22, %*{"message": "otra"}, @[])
    assert envelopeValue(answerOf(table.stringFree, table.stateKeys(22,
      """["message"]""".cstring)))["message"].getStr() == "otra"
    endHostCall(22)

  test "fetch answers envelopes, never raising":
    let table = hostFns(newHostScope(scriptedClient(Script()), ToolRegistry()))
    beginHostCall(31, newJObject(), @["fetch"])
    assert "url" in errorOf(answerOf(table.stringFree,
      table.fetch(31, """{"method": "GET"}""".cstring)))
    assert "not supported" in errorOf(answerOf(table.stringFree, table.fetch(31,
      """{"url": "http://127.0.0.1:1/", "method": "TRACE"}""".cstring)))
    # A closed loopback port: no network egress, one refused socket, and the
    # answer is an envelope instead of an exception.
    let dead = answerOf(table.stringFree, table.fetch(31,
      """{"url": "http://127.0.0.1:1/"}""".cstring))
    assert not dead.jget("ok").getBool(true)
    endHostCall(31)
    # `needs` gates it like the other capabilities.
    beginHostCall(32, newJObject(), @[])
    assert "needs: fetch" in errorOf(answerOf(table.stringFree, table.fetch(32,
      """{"url": "http://127.0.0.1:1/"}""".cstring)))
    endHostCall(32)

  test "log and stringFree are plumbing: nil-safe, never raise":
    let table = hostFns(newHostScope(scriptedClient(Script()), ToolRegistry()))
    table.log(41, 2, "hello from a plugin".cstring)
    table.log(41, 2, nil)
    table.stringFree(nil)
    assert true  # reaching this line IS the assertion

suite "plugin graph from the manifest (step 3)":

  test "the chain runs end to end and the second node sees the first's out":
    let dir = getTempDir() / "waku-plugin-step3-graph"
    createDir(dir)
    let script = Script(items: @[textResp("resumen")])
    let rec = Recorder()
    let table = newHostTable(scriptedClient(script), ToolRegistry())
    let plugin = loadPlugin(buildFixture(dir, "fixture_graph_plugin.so"),
                            addr table[])
    assert plugin.name == "chainfx"
    assert plugin.nodes.len == 5
    let g = buildPluginGraph(plugin, plugin.nodes, 7)
    assert g.describe()["name"].getStr() == "plugin:chainfx"
    # Four chained edges (START -> first -> second -> summarize ->
    # pick_branch, where the router ends the chain) plus the router's two
    # conditional edges (shout, END).
    assert g.describe()["edges"].len == 6
    var state = %*{"message": "hola", "pick": "left"}
    discard runGraph(g, state, record(rec))
    # Node one wrote from its inKeys, node two read that outKey (and asked
    # the host, by handle, for a key it never declared), node three called
    # the model through the host table, and the router's `left` route jumped
    # to the one branch node.
    assert state.jget("stage1").getStr() == "first:hola"
    assert state.jget("stage2").getStr() == "second:first:hola/hola"
    assert state.jget("reply").getStr() == "resumen"
    assert state.jget("loud").getStr() == "shout:second:first:hola/hola"
    assert state["errors"].len == 0
    assert script.seen.len == 1
    assert script.seen[0]["messages"][0]["content"].getStr() ==
      "second:first:hola/hola"
    # The plugin's model call is metered like any other side call, tagged
    # with the node the engine was running.
    let llm = firstEvent(rec, "llm")
    assert not llm.isNil
    assert llm["kind"].getStr() == "plugin"
    assert llm["node"].getStr() == "plugin:chainfx/summarize"
    assert llm["usage"]["in"].getInt() == 7
    # `log` reaches the trace as its own event, inheriting the engine's
    # `node=` tag, and it does NOT need `needs`: diagnostics are plumbing.
    let logged = firstEvent(rec, "plugin_log")
    assert not logged.isNil
    assert logged["node"].getStr() == "plugin:chainfx/first"
    assert logged["level"].getStr() == "info"
    assert logged["message"].getStr() == "first ran"

  test "a reasoning-only answer still summarizes instead of replying empty":
    proc reasoningResp(text: string): JsonNode =
      %*{"stop_reason": "end_turn", "usage": {"in": 7, "out": 3},
         "content": [{"type": "reasoning", "text": text}]}
    let dir = getTempDir() / "waku-plugin-step3-reasoning"
    createDir(dir)
    let script = Script(items: @[reasoningResp("razonado")])
    let rec = Recorder()
    let table = newHostTable(scriptedClient(script), ToolRegistry())
    let plugin = loadPlugin(buildFixture(dir, "fixture_graph_plugin.so"),
                            addr table[])
    let g = buildPluginGraph(plugin, plugin.nodes, 8)
    var state = %*{"message": "hola", "pick": "right"}
    discard runGraph(g, state, record(rec))
    assert state.jget("reply").getStr() == "razonado"
    assert state["errors"].len == 0

  test "registration lists plugin:chainfx after the builtins":
    let dir = getTempDir() / "waku-plugin-step3-registry"
    createDir(dir)
    discard buildFixture(dir, "fixture_graph_plugin.so")
    let script = Script(items: @[textResp("resumen")])
    let table = newHostTable(scriptedClient(script), ToolRegistry())
    let loaded = loadPluginGraphs(dir, addr table[])
    assert loaded.len == 1
    assert loaded[0].name == "chainfx"
    assert not findLoadedPlugin("chainfx").isNil
    assert not findLoadedPlugin("CHAINFX").isNil  # the selector lowercases
    assert "plugin:chainfx" in pluginGraphNames()
    let wf = pluginGraph("plugin:chainfx")
    assert not wf.isNil
    assert wf["edges"].len == 6  # four chained + the router's two targets
    let workflows = enabledWorkflows(@["triage", "gather"])
    assert workflows.len == 3
    assert workflows[0]["name"].getStr() == "triage"
    assert workflows[1]["name"].getStr() == "gather"
    assert workflows[2]["name"].getStr() == "plugin:chainfx"
    # `graphSection` needs no change at all: it already draws whatever the
    # registry lists, so the plugin graph appears in the dashboard's list.
    let section = graphSection(
      getTempDir() / "waku-plugin-step3-nohome", false, @["triage", "gather"])
    assert section["workflows"].len == 3
    assert section["workflows"][2]["name"].getStr() == "plugin:chainfx"

suite "declarative routes in the manifest (step 4)":

  test "a router's routes jump to a manifest node and drain to END":
    let dir = getTempDir() / "waku-plugin-step4-route"
    createDir(dir)
    let script = Script(items: @[textResp("uno"), textResp("dos")])
    let rec = Recorder()
    let table = newHostTable(scriptedClient(script), ToolRegistry())
    let plugin = loadPlugin(buildFixture(dir, "fixture_graph_plugin.so"),
                            addr table[])
    let g = buildPluginGraph(plugin, plugin.nodes, 9)
    # `left -> shout`: the route is a jump, so the branch node runs after the
    # router, and the event names the graph node it landed on.
    var left = %*{"message": "hola", "pick": "left"}
    discard runGraph(g, left, record(rec))
    assert left["loud"].getStr() == "shout:second:first:hola/hola"
    assert left["errors"].len == 0
    let routeEv = firstEvent(rec, "route")
    assert routeEv["router"].getStr() == "plugin:chainfx/pick_branch"
    assert routeEv["target"].getStr() == "plugin:chainfx/shout"
    assert routeEv["reason"].getStr() == "left"
    # `right -> END`: the run drains, the branch node never runs, and a route
    # to END is not an unknown label.
    var right = %*{"message": "hola", "pick": "right"}
    discard runGraph(g, right)
    assert not right.hasKey("loud")
    assert right["errors"].len == 0

  test "a dangling route target is refused at load":
    let dir = getTempDir() / "waku-plugin-step4-dangling"
    createDir(dir)
    var table = newHostTable(scriptedClient(Script()), ToolRegistry())
    try:
      discard loadPlugin(buildFixture(dir, "dangling.so",
                        "-d:routeFx=dangling"), addr table[])
      assert false, "a route to an unknown node must not load"
    except CatchableError as exc:
      assert "unknown node 'nope'" in exc.msg

  test "a duplicate route label is refused at load":
    let dir = getTempDir() / "waku-plugin-step4-duplabel"
    createDir(dir)
    var table = newHostTable(scriptedClient(Script()), ToolRegistry())
    try:
      discard loadPlugin(buildFixture(dir, "duplabel.so",
                        "-d:routeFx=duplabel"), addr table[])
      assert false, "two routes with one label must not load"
    except CatchableError as exc:
      assert "duplicate route label 'left'" in exc.msg

  test "routes that are not label/dst strings are refused at load":
    let dir = getTempDir() / "waku-plugin-step4-badshape"
    createDir(dir)
    var table = newHostTable(scriptedClient(Script()), ToolRegistry())
    try:
      discard loadPlugin(buildFixture(dir, "badshape.so",
                        "-d:routeFx=badshape"), addr table[])
      assert false, "a non-string label must not load"
    except CatchableError as exc:
      assert "non-empty label string" in exc.msg

  test "a router without routes is refused when the graph is built":
    let dir = getTempDir() / "waku-plugin-step4-noroutes"
    createDir(dir)
    var table = newHostTable(scriptedClient(Script()), ToolRegistry())
    # The loader accepts the manifest (a router with no edges is a valid
    # manifest shape); the BUILD refuses it, because the chart is the lie.
    let plugin = loadPlugin(buildFixture(dir, "noroutes.so",
                             "-d:routeFx=noroutes"), addr table[])
    try:
      discard buildPluginGraph(plugin, plugin.nodes)
      assert false, "a router without routes must not build a graph"
    except CatchableError as exc:
      assert "router without routes" in exc.msg
      assert "step 4" notin exc.msg

  test "a handle is retired after the run and expireHandle closes the net":
    let dir = getTempDir() / "waku-plugin-step4-handle"
    createDir(dir)
    let table = newHostTable(scriptedClient(Script(items: @[textResp("ok")])),
                             ToolRegistry())
    let plugin = loadPlugin(buildFixture(dir, "fixture_graph_plugin.so"),
                            addr table[])
    # One run, one handle: every node and router call retires its own entry.
    var state = %*{"message": "hola", "pick": "right"}
    discard runGraph(buildPluginGraph(plugin, plugin.nodes, 42), state)
    assert "no live node call" in errorOf(answerOf(table.stringFree,
      table.stateKeys(42, """["message"]""".cstring)))
    # A run that stops between nodes is the window the net exists for.
    beginHostCall(42, %*{"message": "stale"}, @[])
    assert envelopeValue(answerOf(table.stringFree,
      table.stateKeys(42, """["message"]""".cstring)))["message"].getStr() ==
      "stale"
    expireHandle(42)
    assert "no live node call" in errorOf(answerOf(table.stringFree,
      table.stateKeys(42, """["message"]""".cstring)))
    expireHandle(42)  # idempotent: the ordinary case is one no-op lookup

suite "gateway selection of plugin graphs (step 3)":

  test "a plugin graph that was never loaded fails open to the loop":
    let client = scriptedClient(Script())
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    assert resolveGatewayGraph("plugin:nope", client, "mini", "/tmp",
                               binder).isNil
    assert resolveGatewayGraph("plugin:chainfx/extra", client, "mini", "/tmp",
                               binder).isNil

  test "a loaded plugin graph answers from the host table":
    let client = scriptedClient(Script())
    let binder = proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
      LoopResult(reply: "loop", toolCalls: @[], iterations: 1)
    # The turn's nodes call through the PROCESS's host table (the ABI gives
    # them no context), so this test installs the one whose scripted model
    # holds the answer `summarize` reads — not whichever table an earlier
    # test happened to leave behind.
    discard newHostTable(scriptedClient(Script(items: @[textResp("resumen")])),
                         ToolRegistry())
    let bound = resolveGatewayGraph("plugin:chainfx", client, "mini", "/tmp",
                                    binder)
    assert not bound.isNil
    let (answered, res) = bound("hola", nil, false)
    assert answered
    assert res.reply == "resumen"
