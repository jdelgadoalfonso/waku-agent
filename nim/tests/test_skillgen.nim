## Skill Nim template generator (T2): validated SkillGraph → Nim source.
##
## The generator produces a complete .nim file that compiles to a .so
## with the plugin ABI v1. The LLM never writes Nim — only the JSON
## manifest changes between skills. This test pins the generated code
## structure and the prompt interpolation logic.

import std/json
import std/os
import std/osproc
import std/strutils
import std/unittest

import ../src/graph/skillgraph
import ../src/graph/skillgen
import ../src/graph/plugins
import ../src/worker_plugin
import ../src/loop  # LlmClient
import ../src/graph/engine
import ../src/graph/hostfns
import ../src/tools  # ToolRegistry
import ../src/wire  # jget

proc validGraph(): SkillGraph =
  validateSkillGraph(%*{
    "name": "summarize",
    "abi": 1,
    "nodes": [
      {"name": "summarize", "kind": "llm", "inKeys": ["message"],
       "outKey": "summary", "needs": ["llm"],
       "prompt": "Summarize: {{message}}"}
    ]
  })

suite "skill Nim generator":

  test "generates valid Nim source for a single llm node":
    let source = generateSkillNim(validGraph())
    assert source.contains("waku_plugin_abi_version")
    assert source.contains("waku_plugin_init")
    assert source.contains("waku_plugin_describe")
    assert source.contains("waku_plugin_node_run")
    assert source.contains("waku_plugin_string_free")
    assert source.contains("\"summarize\"")
    assert source.contains("Summarize: {{message}}")

  test "generates manifest without prompt field":
    let source = generateSkillNim(validGraph())
    # The describe manifest should not contain the prompt field
    # (prompt is internal to node_run, not part of the plugin ABI)
    let describeStart = source.find("waku_plugin_describe")
    let describeEnd = source.find("waku_plugin_node_run")
    let describeSection = source[describeStart ..< describeEnd]
    assert not describeSection.contains("\"prompt\"")

  test "generates llm node with prompt interpolation":
    let source = generateSkillNim(validGraph())
    assert source.contains("llmComplete")
    assert source.contains("{{message}}")
    assert source.contains("summary")

  test "generates router node with route labels":
    let graph = validateSkillGraph(%*{
      "name": "branch",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["summary"],
         "needs": ["llm"],
         "routes": [{"label": "long", "dst": "translate",
                     "when": {"key": "summary", "op": "len_gt", "value": 120}},
                    {"label": "short", "dst": "END"}]},
        {"name": "translate", "kind": "llm", "inKeys": ["summary"],
         "outKey": "reply", "needs": ["llm"], "prompt": "Translate: {{summary}}"}
      ]
    })
    let source = generateSkillNim(graph)
    assert source.contains("long")
    assert source.contains("short")
    assert source.contains("route")
    assert source.contains("translate")

  test "generates declarative condition code per op":
    let graph = validateSkillGraph(%*{
      "name": "conds",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "reply", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["reply"],
         "needs": ["llm"],
         "routes": [
           {"label": "big", "dst": "END",
            "when": {"key": "reply", "op": "len_gt", "value": 120}},
           {"label": "tiny", "dst": "END",
            "when": {"key": "reply", "op": "len_lt", "value": 10}},
           {"label": "yes", "dst": "END",
            "when": {"key": "reply", "op": "eq", "value": "yes"}},
           {"label": "err", "dst": "END",
            "when": {"key": "reply", "op": "contains", "value": "error"}},
           {"label": "other", "dst": "END"}]}
      ]
    })
    let source = generateSkillNim(graph)
    assert source.contains(".len > 120")
    assert source.contains(".len < 10")
    assert source.contains("== \"yes\"")
    assert source.contains(".contains(\"error\")")

  test "generates LLM fallback that validates the label":
    let graph = validateSkillGraph(%*{
      "name": "fallback",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "reply", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["reply"],
         "needs": ["llm"],
         "routes": [{"label": "long", "dst": "END"},
                    {"label": "short", "dst": "END"}]}
      ]
    })
    let source = generateSkillNim(graph)
    # The router branch must call llmComplete for the fallback decision
    let routerStart = source.find("of \"route\":")
    assert routerStart >= 0
    let routerSection = source[routerStart .. ^1]
    assert routerSection.contains("llmComplete")
    # And it must reject a label outside the declared set
    assert routerSection.contains("unknown route label")
    # The old placeholder heuristic is gone
    assert not source.contains("if val.len > 120:\n      return retText")

  test "generates HostFns type matching plugin ABI":
    let source = generateSkillNim(validGraph())
    assert source.contains("HostFns")
    assert source.contains("abiVersion")
    assert source.contains("llmComplete")
    assert source.contains("stringFree")
    assert source.contains("log")

  test "generates NimMain import for runtime init":
    let source = generateSkillNim(validGraph())
    assert source.contains("NimMain")
    assert source.contains("importc")

  test "generates error envelope helper":
    let source = generateSkillNim(validGraph())
    assert source.contains("errEnvelope")
    assert source.contains("ok")
    assert source.contains("false")

  test "generates ok patch helper":
    let source = generateSkillNim(validGraph())
    assert source.contains("okPatch")
    assert source.contains("ok")
    assert source.contains("true")

  test "generates copy-before-free pattern":
    let source = generateSkillNim(validGraph())
    assert source.contains("readEnvelope")
    assert source.contains("stringFree")

  test "generates unknown node error":
    let source = generateSkillNim(validGraph())
    assert source.contains("unknown node")

  test "generates exportc and cdecl pragmas":
    let source = generateSkillNim(validGraph())
    assert source.contains("exportc")
    assert source.contains("cdecl")
    assert source.contains("dynlib")

  test "generates abi version 1":
    let source = generateSkillNim(validGraph())
    assert source.contains("1'u32")

  test "generates multiple llm nodes with different prompts":
    let graph = validateSkillGraph(%*{
      "name": "chain",
      "abi": 1,
      "nodes": [
        {"name": "step1", "kind": "llm", "inKeys": ["message"],
         "outKey": "a", "needs": ["llm"], "prompt": "First: {{message}}"},
        {"name": "step2", "kind": "llm", "inKeys": ["a"],
         "outKey": "b", "needs": ["llm"], "prompt": "Second: {{a}}"}
      ]
    })
    let source = generateSkillNim(graph)
    assert source.contains("First: {{message}}")
    assert source.contains("Second: {{a}}")
    assert source.contains("\"step1\"")
    assert source.contains("\"step2\"")

  test "generates prompt with multiple placeholders":
    # `a` and `b` need real producers: data flow (S9) refuses an inKey no
    # earlier node writes, so the two prior llm nodes are part of the case.
    # The point is unchanged — one prompt reading several placeholders.
    let graph = validateSkillGraph(%*{
      "name": "multi",
      "abi": 1,
      "nodes": [
        {"name": "first", "kind": "llm", "inKeys": ["message"],
         "outKey": "a", "needs": ["llm"], "prompt": "First: {{message}}"},
        {"name": "second", "kind": "llm", "inKeys": ["message"],
         "outKey": "b", "needs": ["llm"], "prompt": "Second: {{message}}"},
        {"name": "combine", "kind": "llm", "inKeys": ["a", "b"],
         "outKey": "result", "needs": ["llm"],
         "prompt": "Combine {{a}} and {{b}}"}
      ]
    })
    let source = generateSkillNim(graph)
    assert source.contains("{{a}}")
    assert source.contains("{{b}}")

  test "generated source never calls tool or fetch":
    let source = generateSkillNim(validGraph())
    # The HostFns type must match the host ABI layout (includes toolCall/fetch
    # fields), but the generated runNode code must never CALL them.
    assert not source.contains("h.toolCall(")
    assert not source.contains("h.fetch(")

  test "the final llm node also writes reply for the worker contract":
    # pluginRunHeadless answers state["reply"]: a skill whose last node
    # writes only its own outKey would run headless and answer nothing.
    let graph = validateSkillGraph(%*{
      "name": "twonodes",
      "abi": 1,
      "nodes": [
        {"name": "first", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"], "prompt": "a"},
        {"name": "second", "kind": "llm", "inKeys": ["summary"],
         "outKey": "translated", "needs": ["llm"], "prompt": "b"}
      ]
    })
    let source = generateSkillNim(graph)
    let secondBranch = source[source.find("of \"second\":") .. ^1]
    assert secondBranch.contains("\"reply\"")
    let firstBranch = source[source.find("of \"first\":") ..< source.find("of \"second\":")]
    assert not firstBranch.contains("\"reply\"")

  test "generated Nim compiles to .so and loads via loadPlugin":
    let dir = getTempDir() / "waku-skillgen-integration"
    createDir(dir)
    let source = generateSkillNim(validGraph())
    let nimFile = dir / "summarize.nim"
    writeFile(nimFile, source)
    let nim = findExe("nim")
    assert nim.len > 0, "nim must be on PATH"
    let soFile = dir / "summarize.so"
    let cmd = nim & " c --app:lib --panics:off --hints:off -o:" & soFile & " " & nimFile
    let (output, code) = execCmdEx(cmd)
    assert code == 0, "generated Nim failed to compile: " & output
    assert fileExists(soFile)
    var host = nullHostFns()
    let plugin = loadPlugin(soFile, addr host)
    assert plugin.name == "summarize"
    assert plugin.nodes.len == 1
    assert plugin.nodes[0].kind == "llm"
    assert plugin.nodes[0].name == "summarize"

  test "hybrid router skill runs headless: condition path and fallback path":
    let graph = validateSkillGraph(%*{
      "name": "hybridfx",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"],
         "prompt": "Summarize: {{message}}"},
        {"name": "route", "kind": "router", "inKeys": ["summary"],
         "needs": ["llm"],
         "routes": [
           {"label": "long", "dst": "expand",
            "when": {"key": "summary", "op": "len_gt", "value": 120}},
           {"label": "short", "dst": "END"}]},
        {"name": "expand", "kind": "llm", "inKeys": ["summary"],
         "outKey": "reply", "needs": ["llm"],
         "prompt": "Expand: {{summary}}"}
      ]
    })
    let dir = getTempDir() / "waku-skillgen-hybrid"
    createDir(dir)
    let nimFile = dir / "hybridfx.nim"
    writeFile(nimFile, generateSkillNim(graph))
    let nim = findExe("nim")
    let soFile = dir / "hybridfx.so"
    let (output, code) = execCmdEx(nim &
      " c --app:lib --panics:off --hints:off -o:" & soFile & " " & nimFile)
    assert code == 0, "hybrid skill failed to compile: " & output
    var host = nullHostFns()
    let plugin = loadPlugin(soFile, addr host)
    assert pluginWorkerEligible(plugin.nodes)
    let home = getTempDir() / "waku-skillgen-hybrid-home"
    if dirExists(home):
      removeDir(home)
    createDir(home / "plugins")
    copyFile(soFile, home / "plugins" / "hybridfx.so")

    # Path 1: short summary — no condition matches, LLM fallback says
    # "short" → END. The router label call is scripted separately from
    # the summarize call by inspecting the request prompt.
    let scriptedShort = LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      let content = req{"messages"}[0]{"content"}.getStr("")
      let answer = if content.startsWith("You are a routing step"): "short"
                   else: "corto"
      %*{"stop_reason": "end_turn", "usage": {"in": 5, "out": 2},
         "content": [{"type": "text", "text": answer}]},
      stream: nil)
    let stateShort = pluginRunHeadless(home, "hybridfx", "hola", "m", "",
      scriptedShort)
    # short → END: no reply, and the fallback routing call did happen
    # (summarize + metered router call = 2 llm events, 5 tokens each).
    assert stateShort["reply"].getStr() == ""
    assert stateShort["usage"]["in"].getInt() == 10

    # Path 2: long summary — the len_gt condition matches without any
    # LLM routing call; expand runs and writes reply.
    let longText = "x".repeat(150)
    let scriptedLong = LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      let content = req{"messages"}[0]{"content"}.getStr("")
      let answer = if content.startsWith("You are a routing step"):
                     raiseAssert("condition path must not call the LLM router")
                   elif content.startsWith("Expand:"): "expanded"
                   else: longText
      %*{"stop_reason": "end_turn", "usage": {"in": 5, "out": 2},
         "content": [{"type": "text", "text": answer}]},
      stream: nil)
    let stateLong = pluginRunHeadless(home, "hybridfx", "hola", "m", "",
      scriptedLong)
    assert stateLong["reply"].getStr() == "expanded"

    # Path 3: fallback answers a label outside the declared set — the
    # run must record the error, never route silently. Observed at the
    # engine level: pluginRunHeadless answers only reply/usage/logs.
    let scriptedBad = LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      let content = req{"messages"}[0]{"content"}.getStr("")
      let answer = if content.startsWith("You are a routing step"): "bogus"
                   else: "corto"
      %*{"stop_reason": "end_turn", "usage": {"in": 5, "out": 2},
         "content": [{"type": "text", "text": answer}]},
      stream: nil)
    let table = newHostTable(scriptedBad, ToolRegistry(), "m")
    let badPlugin = loadPlugin(soFile, addr table[])
    let handle = nextHostHandle()
    var badState = %*{"message": "hola"}
    try:
      discard runGraph(buildPluginGraph(badPlugin, badPlugin.nodes, handle),
        badState)
    finally:
      expireHandle(handle)
    assert badState["errors"].len > 0
    assert badState.jget("reply").getStr("") != "expanded"
    removeDir(dir)
    removeDir(home)

  test "router fallback is decided once per (handle, node)":
    # The engine calls the node fn AND then the route fn for ONE router
    # visit, so waku_plugin_node_run runs twice with the same node name and
    # the same handle. The fallback decision must be paid once per
    # (handle, node) and both calls must answer the same label; another run
    # (another handle) still decides for itself. Declarative `when`
    # conditions stay first and authoritative on every call.
    let graph = validateSkillGraph(%*{
      "name": "routememo",
      "abi": 1,
      "nodes": [
        {"name": "prepare", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "Prepare: {{message}}"},
        {"name": "answer", "kind": "llm", "inKeys": ["x"],
         "outKey": "reply", "needs": ["llm"], "prompt": "Answer: {{x}}"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [
           {"label": "big", "dst": "END",
            "when": {"key": "x", "op": "len_gt", "value": 120}},
           {"label": "small", "dst": "END"}]}
      ]
    })
    let dir = getTempDir() / "waku-skillgen-routememo"
    createDir(dir)
    let nimFile = dir / "routememo.nim"
    writeFile(nimFile, generateSkillNim(graph))
    let nim = findExe("nim")
    let soFile = dir / "routememo.so"
    let (output, code) = execCmdEx(nim &
      " c --app:lib --panics:off --hints:off -o:" & soFile & " " & nimFile)
    assert code == 0, "routememo skill failed to compile: " & output

    # The scripted fallback alternates its answer, so a re-used decision and
    # a fresh one are visibly different: "small" for odd routing calls,
    # "big" for even ones.
    var routingCalls = 0
    let counting = LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      let content = req{"messages"}[0]{"content"}.getStr("")
      var text = "hola"
      if content.startsWith("You are a routing step"):
        inc routingCalls
        text = if routingCalls mod 2 == 1: "small" else: "big"
      %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
         "content": [{"type": "text", "text": text}]},
      stream: nil)
    let table = newHostTable(counting, ToolRegistry(), "m")
    let plugin = loadPlugin(soFile, addr table[])
    assert plugin.name == "routememo"
    var needs: seq[string] = @[]
    for decl in plugin.nodes:
      if decl.kind == "router":
        needs = decl.needs
    assert needs == @["llm"]

    let longText = "y".repeat(150)
    # Path 1: the `when` condition matches, so both calls answer "big" with
    # no LLM call at all — the condition still runs first, every time.
    let handle = nextHostHandle()
    beginHostCall(handle, %*{"x": longText}, needs)
    let condFirst = callPlugin(plugin, "route", %*{"x": longText}, handle)
    let condSecond = callPlugin(plugin, "route", %*{"x": longText}, handle)
    endHostCall(handle)
    assert condFirst["route"].getStr() == "big"
    assert condSecond["route"].getStr() == "big"
    assert routingCalls == 0

    # Path 2: no condition matches — the same handle asked twice (exactly
    # one router visit) pays the fallback ONCE and answers "small" twice.
    beginHostCall(handle, %*{"x": "hola"}, needs)
    let first = callPlugin(plugin, "route", %*{"x": "hola"}, handle)
    let second = callPlugin(plugin, "route", %*{"x": "hola"}, handle)
    endHostCall(handle)
    assert first["route"].getStr() == "small"
    assert second["route"].getStr() == "small"
    assert routingCalls == 1

    # Path 2b: the memo never outranks a condition — the same handle with a
    # long value answers "big" again, still without an LLM routing call.
    beginHostCall(handle, %*{"x": longText}, needs)
    let condAgain = callPlugin(plugin, "route", %*{"x": longText}, handle)
    endHostCall(handle)
    assert condAgain["route"].getStr() == "big"
    assert routingCalls == 1

    # Path 3: a different run makes its own decision — a new handle gets the
    # second scripted answer, never the previous run's memo.
    let otherHandle = nextHostHandle()
    beginHostCall(otherHandle, %*{"x": "hola"}, needs)
    let third = callPlugin(plugin, "route", %*{"x": "hola"}, otherHandle)
    endHostCall(otherHandle)
    assert third["route"].getStr() == "big"
    assert routingCalls == 2

    # Path 4: one real engine visit. runOne calls the node fn, then the run
    # walks the router and calls the route fn — the double call this memo
    # exists for.
    let runHandle = nextHostHandle()
    var reasons: seq[string] = @[]
    let observe = proc(kind: string, ev: JsonNode) =
      if kind == "route":
        reasons.add(ev{"reason"}.getStr(""))
    var state = %*{"message": "hi"}
    let before = routingCalls
    try:
      discard runGraph(buildPluginGraph(plugin, plugin.nodes, runHandle),
        state, observe)
    finally:
      expireHandle(runHandle)
    assert routingCalls - before == 1
    assert reasons == @["small"]
    assert state["errors"].len == 0
    removeDir(dir)
