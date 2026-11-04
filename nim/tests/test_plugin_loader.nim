## Step-2 pins: the loader crosses a REAL dynamic library boundary.
##
## This suite compiles `fixture_plugin.nim` with `--app:lib` into a temp
## dir (local compiler, no network) and drives it through `loadPlugin`
## and the engine: describe, tool patch (+ `_secret` never merges),
## router label, `ok:false` into `state["errors"]`, version gate, and
## the failure shapes (bogus path, garbage .so, missing dir).

import std/json
import std/os
import std/osproc
import std/strutils
import std/unittest

import ../src/graph/engine
import ../src/graph/plugins

proc buildFixture(dir, name, extra: string): string =
  ## Compile the fixture to `dir/name`; fail loudly with the compiler
  ## output when it does not build.
  let nim = findExe("nim")
  assert nim.len > 0, "nim must be on PATH to build the fixture"
  let target = dir / name
  let cmd = nim & " c --app:lib --panics:off --hints:off " & extra &
    " -o:" & target & " tests/fixture_plugin.nim"
  let (output, code) = execCmdEx(cmd)
  assert code == 0, "fixture build failed: " & output
  return target

proc declOf(plugin: LoadedPlugin, name: string): PluginNodeDecl =
  for d in plugin.nodes:
    if d.name == name:
      return d
  assert false, "fixture missing node " & name

proc sinkNode(name, outKey: string): Node =
  newNode(name, proc(s: JsonNode, n: Observer): JsonNode =
    var o = newJObject()
    o[outKey] = %"reached"
    o)

suite "plugin loader step 2":

  test "loads, describes, runs a tool node through the engine":
    let dir = getTempDir() / "waku-plugin-step2-ok"
    createDir(dir)
    var host = nullHostFns()
    let plugin = loadPlugin(buildFixture(dir, "fixture_plugin.so", ""),
                            addr host)
    assert plugin.name == "fixture"
    assert plugin.nodes.len == 3
    var g = Graph(name: "plug")
    g.addNode(pluginNode(plugin, declOf(plugin, "echo_tool")))
    g.addEdge(START, "plugin:fixture/echo_tool")
    var state = %*{"text": "hi"}
    discard runGraph(g, state)
    assert state["echoed"].getStr() == "echo:hi"
    assert not state.hasKey("_secret")  # private keys never cross back
    assert state["errors"].len == 0

  test "a router label crosses the boundary":
    let dir = getTempDir() / "waku-plugin-step2-route"
    createDir(dir)
    var host = nullHostFns()
    let plugin = loadPlugin(buildFixture(dir, "fixture_plugin.so", ""),
                            addr host)
    let choose = declOf(plugin, "choose")
    var g = Graph(name: "proute")
    g.addNode(pluginNode(plugin, choose))
    g.addNode(sinkNode("left", "picked"))
    g.addEdge(START, "plugin:fixture/choose")
    g.addRouter("plugin:fixture/choose", pluginRouter(plugin, choose, "END"),
                @[(label: "left", dst: "left")])
    var state = %*{"pick": "left"}
    discard runGraph(g, state)
    assert state["picked"].getStr() == "reached"
    assert state["errors"].len == 0

  test "ok:false lands in errors and merges nothing":
    let dir = getTempDir() / "waku-plugin-step2-err"
    createDir(dir)
    var host = nullHostFns()
    let plugin = loadPlugin(buildFixture(dir, "fixture_plugin.so", ""),
                            addr host)
    var g = Graph(name: "perr")
    g.addNode(pluginNode(plugin, declOf(plugin, "failer")))
    g.addEdge(START, "plugin:fixture/failer")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["errors"]["plugin:fixture/failer"].getStr() ==
      "CatchableError: fixture refuses"
    assert not state.hasKey("patch")

  test "a wrong ABI version is refused at load":
    let dir = getTempDir() / "waku-plugin-step2-abi"
    createDir(dir)
    var host = nullHostFns()
    let so = buildFixture(dir, "fixture_abi2.so", "-d:fixtureAbi=2")
    try:
      discard loadPlugin(so, addr host)
      assert false, "must refuse ABI 2"
    except CatchableError as exc:
      assert "ABI" in exc.msg

  test "bogus paths and garbage libraries fail loudly":
    var host = nullHostFns()
    try:
      discard loadPlugin(getTempDir() / "waku-plugin-nope.so", addr host)
      assert false, "must fail on a missing file"
    except CatchableError as exc:
      assert "cannot load" in exc.msg
    let dir = getTempDir() / "waku-plugin-step2-garbage"
    createDir(dir)
    writeFile(dir / "junk.so", "not a library")
    try:
      discard loadDiscovered(dir, addr host)
      assert false, "must fail when nothing loads"
    except CatchableError as exc:
      assert "no plugin loaded" in exc.msg
    assert discoverPluginPaths(
      getTempDir() / "waku-plugin-missing-dir") == newSeq[string]()
    let (found, _, _) = findPluginNode(@[], "plugin:fixture/echo_tool")
    assert not found
