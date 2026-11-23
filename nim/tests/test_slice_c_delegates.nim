## Slice C: the delegates table comes from the inventory, and the offer
## the gate sees is built from the same list — every offered route has
## something that can receive it. Pure and offline: registry fixtures,
## injected fake runner, no spawn and no `.so` load.

import std/json
import std/unittest

import ../src/dashboard
import ../src/delegate
import ../src/delegation
import ../src/graph/inventory
import ../src/graph/plugins
import ../src/graph/registry
import ../src/supervisor
import ../src/tools
import ../src/workers

const noHome = "/tmp/waku-slicec-nonexistent-home"
  ## No skills, no plugins dir: `skillStatusesFor` answers empty.

proc entry(name, kind, source: string, installed: bool): JsonNode =
  ## One inventory row, the shape `inventoryEntries` emits. The pins read
  ## only `name`/`installed`, but a half row is never worth writing.
  %*{"name": name, "kind": kind, "tasks": [], "when_to_use": "",
     "cost": "", "fallback": "plain-loop", "source": source,
     "installed": installed}

proc decl(name, kind: string, needs: seq[string]): PluginNodeDecl =
  PluginNodeDecl(name: name, kind: kind, inKeys: @["message"],
    outKey: name, needs: needs, routes: @[])

proc loadFakePlugin(name: string, nodes: seq[PluginNodeDecl] = @[]) =
  ## A loaded manifest without a `.so`: the process registry is the same
  ## one `loadPluginGraphs` fills, so eligibility reads exactly the live
  ## verdict.
  registerLoadedPlugin(LoadedPlugin(name: name, path: "", nodes: nodes))

suite "slice C runnable inventory":

  test "a builtin member of delegateWorkers is kept":
    let entries = @[entry("triage", "graph", "builtin", true),
                    entry("gather", "graph", "builtin", true),
                    entry("brief", "graph", "builtin", true)]
    assert runnableAgents(entries) == @["gather", "brief"]

  test "a builtin with no worker is dropped":
    let entries = @[entry("triage", "graph", "builtin", true)]
    assert runnableAgents(entries) == newSeq[string]()

  test "an eligible loaded plugin is kept":
    loadFakePlugin("slicecok", @[decl("summarize", "llm", @["llm"])])
    let entries = @[entry("plugin:slicecok", "plugin", "plugin-so", true)]
    assert runnableAgents(entries) == @["plugin:slicecok"]

  test "a plugin that is not loaded is dropped":
    let entries = @[entry("plugin:slicecghost", "plugin", "plugin-so",
      true)]
    assert runnableAgents(entries) == newSeq[string]()

  test "a loaded plugin with tool or fetch needs is dropped":
    loadFakePlugin("slicecneeds", @[decl("search", "tool", @["fetch"])])
    let entries = @[entry("plugin:slicecneeds", "plugin", "plugin-so",
      true)]
    assert runnableAgents(entries) == newSeq[string]()

  test "an uninstalled entry is dropped even when the gates would pass":
    loadFakePlugin("slicecuninstalled")
    let entries = @[
      entry("gather", "graph", "builtin", false),
      entry("plugin:slicecuninstalled", "plugin", "plugin-so", false),
      entry("plugin:slicecgap", "plugin", "skill-md", false)]
    assert runnableAgents(entries) == newSeq[string]()

  test "order is inventory order, duplicates collapse":
    loadFakePlugin("slicecorder")
    let entries = @[
      entry("plugin:slicecorder", "plugin", "plugin-so", true),
      entry("triage", "graph", "builtin", true),
      entry("gather", "graph", "builtin", true),
      entry("gather", "graph", "builtin", true)]
    assert runnableAgents(entries) == @["plugin:slicecorder", "gather"]

suite "slice C roster union":

  test "brief is offered when enabled even with no inventory row":
    # `brief` has a worker in `delegateWorkers` but no graph topology,
    # so `inventoryEntries` can never list it. The union with today's
    # gate-checked enable list is what keeps `WAKU_AGENTS=brief` working.
    let entries = inventoryEntries(@["brief"], @[])
    assert runnableAgents(entries) == newSeq[string]()
    assert inventoryFind(entries, "brief") == nil
    let roster = agentRoster(entries, @["brief"],
      pluginWorkerNames(@["brief"]))
    assert roster == @["brief"]
    assert workerAgents(roster, pluginWorkerNames(roster)) == roster

  test "inventory plugin and settings brief both survive, order kept":
    loadFakePlugin("slicecunion")
    let entries = @[entry("plugin:slicecunion", "plugin", "plugin-so",
      true)]
    assert runnableAgents(entries) == @["plugin:slicecunion"]
    let roster = agentRoster(entries, @["brief"],
      pluginWorkerNames(@["brief"]))
    assert roster == @["plugin:slicecunion", "brief"]

  test "extra recomputed from the roster keeps its plugins":
    loadFakePlugin("slicecextra")
    let entries = @[entry("plugin:slicecextra", "plugin", "plugin-so",
      true)]
    let roster = agentRoster(entries, @["brief"],
      pluginWorkerNames(@["brief"]))
    let extra = pluginWorkerNames(roster)
    assert extra == @["plugin:slicecextra"]
    assert workerAgents(roster, extra) == roster
    # The settings-only extra would let workerAgents drop the plugin.
    assert workerAgents(roster, pluginWorkerNames(@["brief"])) ==
      @["brief"]

suite "slice C binder shape":

  test "the offer is built from the same inventory the delegates read":
    loadFakePlugin("slicecbind")
    registerPluginGraph("plugin:slicecbind",
      %*{"name": "plugin:slicecbind", "nodes": [], "edges": []})
    assert skillStatusesFor(noHome, @[]).len == 0
    let entries = inventoryEntries(@["triage", "gather"],
      skillStatusesFor(noHome, @[]))
    let runnable = runnableAgents(entries)
    assert runnable == @["gather", "plugin:slicecbind"]
    # What the binder hands `triageGraphTurn` and what it hands
    # `liveDelegateFor` is the same list; `workerAgents` re-applies the
    # gates and must keep every offered route.
    let offered = workerAgents(runnable, pluginWorkerNames(runnable))
    for route in offered:
      assert route in runnable
    assert offered == runnable

  test "every offered route reaches a live delegate":
    loadFakePlugin("slicecreach")
    registerPluginGraph("plugin:slicecreach",
      %*{"name": "plugin:slicecreach", "nodes": [], "edges": []})
    let runnable = runnableAgents(inventoryEntries(@["gather"],
      skillStatusesFor(noHome, @[])))
    assert runnable == @["gather", "plugin:slicecreach"]
    var argvSeen: seq[seq[string]] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "answered"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      argvSeen.add(argv)
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 7)
    let seam = liveDelegateFor(runnable, "waku",
      proc(): string = "t_1", fake,
      extra = pluginWorkerNames(runnable))
    assert not seam.isNil
    for route in runnable:
      let ans = seam(%*{"message": "do it", "route": route}, nil)
      assert ans["reply"].getStr() == "answered"
    assert argvSeen.len == runnable.len
    for argv in argvSeen:
      assert argv[0] == "waku"

  test "an unknown route fails open without spawning":
    loadFakePlugin("slicecunknown")
    let runnable = runnableAgents(@[entry("gather", "graph", "builtin",
      true)])
    var spawned = 0
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      inc spawned
      (res: ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
        pid: 0)
    let seam = liveDelegateFor(runnable, "waku",
      proc(): string = "t_1", fake)
    assert not seam.isNil
    let ans = seam(%*{"message": "do it", "route": "plugin:slicecunknown"},
      nil)
    assert ans["fail_open"].getBool(false)
    assert spawned == 0

  test "nothing runnable means no seam, so the loop answers":
    loadFakePlugin("slicecnone", @[decl("search", "tool", @["tool"])])
    let entries = @[
      entry("triage", "graph", "builtin", true),
      entry("plugin:slicecnone", "plugin", "plugin-so", true),
      entry("plugin:slicecnever", "plugin", "plugin-so", true)]
    assert runnableAgents(entries) == newSeq[string]()
    let noSpawn: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      raise newException(CatchableError, "must not spawn")
    let seam = liveDelegateFor(runnableAgents(entries), "waku",
      proc(): string = "t_1", noSpawn)
    assert seam.isNil
