## Step-3 pins: the REAL host table and a graph built from a manifest.
##
## Offline. `fixture_graph_plugin.nim` is compiled to a temp dir with the
## local compiler, the model is a scripted client (the `Script` pattern from
## `test_graph.nim`), and nothing opens a socket: the one `fetch` case dials
## a closed loopback port to pin the failure envelope.
##
## What is pinned, in order: every host function's envelope; `needs` both as
## a narrowed table (nulls) and as a per-call refusal; `stateKeys` per handle;
## `buildPluginGraph` end to end through a real `.so` (the second node sees
## the first's output, the llm node's metered call reaches the observer); a
## `router` decl refusing the build; fail-open for a graph whose plugin is
## not loaded; and the registry listing `plugin:chainfx` after registration.

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

proc buildFixture(dir, name: string): string =
  ## Compile the graph fixture to `dir/name`; fail loudly with the compiler
  ## output when it does not build.
  let nim = findExe("nim")
  assert nim.len > 0, "nim must be on PATH to build the fixture"
  let target = dir / name
  let cmd = nim & " c --app:lib --panics:off --hints:off -o:" & target &
    " tests/fixture_graph_plugin.nim"
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
    assert plugin.nodes.len == 3
    let g = buildPluginGraph(plugin, plugin.nodes, 7)
    assert g.describe()["name"].getStr() == "plugin:chainfx"
    assert g.describe()["edges"].len == 4  # START->first->second->reply->END
    var state = %*{"message": "hola"}
    discard runGraph(g, state, record(rec))
    # Node one wrote from its inKeys, node two read that outKey (and asked
    # the host, by handle, for a key it never declared), node three called
    # the model through the host table.
    assert state.jget("stage1").getStr() == "first:hola"
    assert state.jget("stage2").getStr() == "second:first:hola/hola"
    assert state.jget("reply").getStr() == "resumen"
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

  test "a router node refuses the graph and points at step 4":
    let plugin = LoadedPlugin(name: "routed")
    let decls = @[PluginNodeDecl(name: "choose", kind: "router",
                                 inKeys: @["pick"], outKey: "", needs: @[])]
    try:
      discard buildPluginGraph(plugin, decls)
      assert false, "a router decl must not build a chain"
    except CatchableError as exc:
      assert "router" in exc.msg
      assert "step 4" in exc.msg

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
    assert wf["edges"].len == 4
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
    let bound = resolveGatewayGraph("plugin:chainfx", client, "mini", "/tmp",
                                    binder)
    assert not bound.isNil
    let (answered, res) = bound("hola", nil, false)
    assert answered
    assert res.reply == "resumen"
