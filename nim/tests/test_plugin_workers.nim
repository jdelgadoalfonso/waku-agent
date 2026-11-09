## T2 RED: plugin eligibility by manifest needs, and the plugin
## runner child-line shape. Pure and offline: injected fakes only, no
## `.so` loads here — the fixture `.so` pins live with the loader tests.

import std/json
import std/os
import std/osproc
import std/strutils
import std/unittest

import ../src/delegation
import ../src/graph/plugins
import ../src/loop
import ../src/wire
import ../src/worker_plugin
import ../src/workers

proc decl(name, kind: string, needs: seq[string]): PluginNodeDecl =
  PluginNodeDecl(name: name, kind: kind, inKeys: @["message"],
    outKey: name, needs: needs, routes: @[])

suite "T2 plugin eligibility":

  test "pure and llm-only manifests are eligible":
    assert pluginWorkerEligible(@[])  # no nodes, nothing to forbid
    assert pluginWorkerEligible(@[decl("upper", "tool", @[])])
    assert pluginWorkerEligible(@[decl("summarize", "llm", @["llm"])])

  test "tool or fetch anywhere is ineligible":
    assert not pluginWorkerEligible(@[decl("search", "tool",
      @["fetch"])])
    assert not pluginWorkerEligible(@[decl("upper", "tool", @[]),
      decl("run", "tool", @["tool"])])

  test "a router declaring tool needs is ineligible":
    var router = decl("pick", "router", @["tool"])
    router.routes = @[(label: "a", dst: "END")]
    assert not pluginWorkerEligible(@[router])

  test "unknown need names enable nothing and stay eligible":
    # `allowed` only gates llm/tool/fetch: a typo enables nothing, so
    # there is nothing a worker could leak through it.
    assert pluginWorkerEligible(@[decl("weird", "tool", @["llms"])])

suite "T2 plugin runner":

  test "a valid task answers event then done with the reply":
    let task = makeTaskLine("t_a", "t_b", "summarize this", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "brief digest",
      "draft_path": ""}
    let lines = runPluginWorker("plugin:textops", task, fake)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "event"
    assert lines[0]["agent"].getStr() == "plugin:textops"
    assert lines[1]["type"].getStr() == "done"
    assert lines[1]["payload"]["reply"].getStr() == "brief digest"
    assert lines[1]["trace_id"].getStr() == "t_a"
    assert lines[1]["turn_id"].getStr() == "t_b"

  test "usage rides one cost line before done":
    let task = makeTaskLine("t_a", "t_b", "summarize this", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "brief digest",
      "draft_path": "",
      "usage": {"kind": "plugin", "model": "m", "in": 7, "out": 3}}
    let lines = runPluginWorker("plugin:textops", task, fake)
    assert lines.len == 3
    assert lines[1]["type"].getStr() == "cost"
    assert lines[1]["payload"]["in"].getInt() == 7
    assert lines[2]["type"].getStr() == "done"

  test "no usage means no invented charge":
    let task = makeTaskLine("t_a", "t_b", "summarize this", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "brief digest",
      "draft_path": ""}
    let lines = runPluginWorker("plugin:textops", task, fake)
    assert lines.len == 2

  test "an invalid task answers one error line":
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "unreachable"}
    let lines = runPluginWorker("plugin:textops", %*{"v": 9}, fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"

  test "a failing run answers error, never raises":
    let task = makeTaskLine("t_a", "t_b", "summarize this", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode =
      raise newException(CatchableError, "plugin boom")
    let lines = runPluginWorker("plugin:textops", task, fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"

  test "logged lines ride message lines before done":
    let task = makeTaskLine("t_a", "t_b", "summarize this", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "brief digest",
      "draft_path": "",
      "logs": [{"level": "info", "message": "thinking out loud"}]}
    let lines = runPluginWorker("plugin:textops", task, fake)
    assert lines.len == 3
    assert lines[0]["type"].getStr() == "event"
    assert lines[1]["type"].getStr() == "message"
    assert lines[1]["payload"]["kind"].getStr() == "log"
    assert lines[1]["payload"]["text"].getStr() == "thinking out loud"
    assert lines[2]["type"].getStr() == "done"

  test "a plugin that answers nothing fails open with one error line":
    # An empty reply would read as success — say so instead, and the
    # parent fails open on the missing claim like any error line.
    let task = makeTaskLine("t_a", "t_b", "summarize this", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "",
      "draft_path": ""}
    let lines = runPluginWorker("plugin:textops", task, fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    assert "answered nothing" in lines[0]["payload"]["message"].getStr()

proc buildFixture(dir, name, source: string): string =
  let nim = findExe("nim")
  assert nim.len > 0, "nim must be on PATH to build the fixture"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  let target = dir / name
  let cmd = nim & " c --app:lib --panics:off --hints:off" &
    " -o:" & target & " tests/" & source
  let (output, code) = execCmdEx(cmd)
  assert code == 0, "fixture build failed: " & output
  return target

proc deadClient(): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
    raise newException(CatchableError, "no llm here"),
    stream: nil)

suite "T2 headless plugin run":

  test "an eligible fixture runs headless with no cost line":
    let dir = getTempDir() / "waku-pw-fixture"
    discard buildFixture(dir, "workergreet.so", "fixture_plugin_worker.nim")
    let home = getTempDir() / "waku-pw-home"
    if dirExists(home):
      removeDir(home)
    createDir(home / "plugins")
    copyFile(dir / "workergreet.so", home / "plugins" / "workergreet.so")
    let task = makeTaskLine("t_a", "t_b", "echo hi", "", 1000, 1)
    let state = pluginRunHeadless(home, "workergreet", "echo hi", "m",
      "", deadClient())
    assert state["reply"].getStr() == "hello: echo hi"
    assert state.jget("usage").kind != JObject  # no llm, no charge
    let lines = runPluginWorker("plugin:workergreet", task,
      proc(): JsonNode = state)
    assert lines[^1]["type"].getStr() == "done"
    assert lines[^1]["payload"]["reply"].getStr() == "hello: echo hi"
    removeDir(dir)
    removeDir(home)

  test "an ineligible manifest is refused before running anything":
    let dir = getTempDir() / "waku-pw-toolneeds"
    discard buildFixture(dir, "toolhungry.so", "fixture_plugin_toolneeds.nim")
    let home = getTempDir() / "waku-pw-toolhome"
    if dirExists(home):
      removeDir(home)
    createDir(home / "plugins")
    copyFile(dir / "toolhungry.so", home / "plugins" / "toolhungry.so")
    let task = makeTaskLine("t_a", "t_b", "fetch this", "", 1000, 1)
    let lines = runPluginWorker("plugin:toolhungry", task,
      proc(): JsonNode =
        pluginRunHeadless(home, "toolhungry", "fetch this", "m", "",
          deadClient()))
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    assert "eligible" in lines[0]["payload"]["message"].getStr()
    removeDir(dir)
    removeDir(home)

  test "a missing plugin file fails open with one error line":
    let home = getTempDir() / "waku-pw-missing"
    if dirExists(home):
      removeDir(home)
    createDir(home / "plugins")
    let task = makeTaskLine("t_a", "t_b", "echo hi", "", 1000, 1)
    let lines = runPluginWorker("plugin:ghost", task,
      proc(): JsonNode =
        pluginRunHeadless(home, "ghost", "echo hi", "m", "",
          deadClient()))
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    removeDir(home)

suite "T2 plugin gate and dispatch":

  test "a plugin table entry answers through the lookup":
    let task = makeTaskLine("t_a", "t_b", "echo hi", "", 1000, 1)
    let fake: PluginFn = proc(): JsonNode = %*{"reply": "hi",
      "draft_path": ""}
    let table = @[(agent: "plugin:workergreet",
      body: pluginBody("plugin:workergreet", fake))]
    let lines = runWorkerLines("plugin:workergreet", $task, table)
    assert lines.len == 2
    assert lines[1]["type"].getStr() == "done"
    assert lines[1]["payload"]["reply"].getStr() == "hi"

  test "no loaded plugin means no plugin worker names":
    assert pluginWorkerNames(@[]) == @[]
    assert pluginWorkerNames(@["plugin:ghost"]) == @[]
    assert pluginWorkerNames(@["gather"]) == @[]

  test "a loaded eligible plugin names its worker":
    var host = nullHostFns()
    let dir = getTempDir() / "waku-pw-gate"
    discard buildFixture(dir, "workergreet.so", "fixture_plugin_worker.nim")
    let plugin = loadPlugin(dir / "workergreet.so", addr host)
    assert plugin.name == "workergreet"
    registerLoadedPlugin(plugin)
    assert pluginWorkerNames(@["plugin:workergreet",
                               "plugin:ghost"]) == @["plugin:workergreet"]
    assert pluginWorkerNames(@["gather",
                               "plugin:workergreet"]) == @["plugin:workergreet"]
    removeDir(dir)
