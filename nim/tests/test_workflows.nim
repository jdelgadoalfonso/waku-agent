## Phase 4d tests: triage + gather workflows, binders, brief.
## Offline only: scripted clients, temp homes, no network. Every temp home
## this file creates is gone before the run ends.

import std/algorithm
import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import db_connector/db_sqlite

import ../src/app
import ../src/brief
import ../src/db
import ../src/gather
import ../src/graph/engine
import ../src/memory
import ../src/triage
import ../src/wire

type
  Script = ref object
    items: seq[JsonNode]
    pos: int
    seen: seq[JsonNode]

  Recorder = ref object
    events: seq[JsonNode]

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
     "content": [{"type": "text", "text": text}]}

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    script.seen.add(copy(req))
    result = script.items[script.pos]
    inc script.pos)

proc observe(r: Recorder): Observer =
  result = proc(kind: string, ev: JsonNode) =
    var e = copy(ev)
    e["kind"] = %kind
    r.events.add(e)

## `freshHome` records each home it makes here. Two tests once forgot to
## remove theirs, so every run of this suite left a `waku-tri-*` dir in /tmp
## for good. The last suite in this file fails when a run leaves one behind.
var tempHomes: seq[string] = @[]

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)
  tempHomes.add(result)

proc wakuTempDirs(): seq[string] =
  ## Every `/tmp` dir whose name starts with `waku-`, sorted. A dir this
  ## suite made must not show up after the run, and the dirs another suite
  ## made sit in both the before and the after listing, so they cancel out.
  for kind, path in walkDir(getTempDir()):
    if kind == pcDir and extractFilename(path).startsWith("waku-"):
      result.add(extractFilename(path))
  result.sort()

proc removeTempHomes() =
  ## The run's teardown: it removes every home `freshHome` made, and it is
  ## the only code in this file that does. `removeDir` does not fail on a dir
  ## that is already gone, so a test that cleaned up early costs nothing.
  for home in tempHomes:
    removeDir(home)
  tempHomes.setLen(0)

## What /tmp held before this run touched it: the pin compares against this.
let wakuTempDirsAtStart = wakuTempDirs()

proc testSettings(home: string, graphWorkflows = false): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
           smallModel: "mini", maxIterations: 10, maxTokens: 8192,
           historyTurns: 12, graphWorkflows: graphWorkflows)

proc fullStub(reply: string): FullFn =
  result = proc(s: JsonNode, n: Observer): LoopResult =
    LoopResult(reply: reply, toolCalls: @[], iterations: 2)

suite "phase 4d classify":
  test "the classify call is metered as triage":
    let script = Script(items: @[textResp("{\"route\": \"quick\"}")],
      seen: @[])
    var llms: seq[JsonNode] = @[]
    let obs: Observer = proc(kind: string, ev: JsonNode) =
      if kind == "llm":
        llms.add(ev)
    let (route, _) = classifyMessage(scriptedClient(script), "mini",
      "hi", obs)
    assert route == "quick"
    assert llms.len == 1
    assert llms[0]["kind"].getStr() == "triage"
    assert llms[0]["model"].getStr() == "mini"
    assert llms[0]["usage"]["in"].getInt() == 1
  test "no JSON fails open to full":
    let script = Script(items: @[textResp("just answer it")])
    assert classifyMessage(scriptedClient(script), "mini", "hi") ==
      (route: "full", reason: "no JSON — failing open")

  test "a bad route fails open and says which":
    let script = Script(items: @[textResp("{\"route\": \"sideways\"}")])
    let (route, reason) = classifyMessage(scriptedClient(script), "m", "hi")
    assert route == "full"
    assert "sideways" in reason

  test "JSON is sliced out of surrounding noise":
    let script = Script(items: @[textResp("sure: {\"route\": \"quick\", " &
      "\"reason\": \"thanks\"} done")])
    assert classifyMessage(scriptedClient(script), "mini", "thanks!") ==
      (route: "quick", reason: "thanks")

  test "a broken client fails open with the error name":
    let bad = LlmClient(create: proc(req: JsonNode): JsonNode =
      raise newException(ValueError, "down"))
    let (route, reason) = classifyMessage(bad, "mini", "hi")
    assert route == "full"
    assert "ValueError" in reason

  test "a truncated brace never crashes, it fails open":
    # prosa + `{` cortada por max_tokens: rfind('}') == -1 would slice
    # text[a .. -1] and raise RangeDefect (a Defect, uncatchable by the
    # fail-open layers) — the guard turns it into plain "no JSON"
    let script = Script(items: @[textResp("thinking… {\"route\": ")])
    assert classifyMessage(scriptedClient(script), "mini", "hi") ==
      (route: "full", reason: "no JSON — failing open")

  test "the rendered prompt keeps single braces and fills the message":
    let script = Script(items: @[textResp("{\"route\": \"full\"}")])
    discard classifyMessage(scriptedClient(script), "mini", "hello")
    let prompt = script.seen[0]["messages"][0]["content"].getStr()
    assert "{\"route\": \"quick\" or \"full\"" in prompt
    assert "User message: hello" in prompt

suite "phase 4d calendar":
  test "missing ics reads (no calendar)":
    # no removeDir here: freshHome recorded this home, the run removes it
    assert todaysEvents(freshHome("waku-tri-nocal")) == "(no calendar)"

  test "only today's events are listed":
    let home = freshHome("waku-tri-ics")
    let today = format(now(), "yyyyMMdd")
    writeFile(home / "calendar.ics",
      "BEGIN:VEVENT\nSUMMARY:Old thing\nDTSTART:20000101T100000\n" &
      "BEGIN:VEVENT\nSUMMARY:Swim\nDTSTART:" & today & "T090000\n")
    assert todaysEvents(home) == "Swim"

  test "a day with nothing reads (nothing today)":
    let home = freshHome("waku-tri-empty")
    writeFile(home / "calendar.ics",
      "BEGIN:VEVENT\nSUMMARY:Old\nDTSTART:20000101T100000\n")
    assert todaysEvents(home) == "(nothing today)"

suite "phase 4d triage graph":
  test "topology has the five nodes and the join":
    let d = triageTopology()
    assert d["nodes"].len == 5
    var names: seq[string] = @[]
    for n in d["nodes"]: names.add(n["name"].getStr())
    assert names == @["classify", "check_calendar", "quick_reply",
                     "full_agent", "gather"]

  test "quick path stores the reply and traces triage":
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        ("quick", "trivial"),
      calendarFn = proc(): string = "(nothing today)",
      quickFn = proc(s: JsonNode): string = "hi!",
      fullFn = proc(s: JsonNode, n: Observer): LoopResult =
        raise newException(ValueError, "must not run"))
    var state = %*{"message": "thanks"}
    let rec = Recorder()
    discard runGraph(g, state, rec.observe())
    assert state["reply"].getStr() == "hi!"
    assert state["calendar"].getStr() == "(nothing today)"
    var sawTriage = false
    for e in rec.events:
      if e["kind"].getStr() == "triage":
        sawTriage = true
        assert e["route"].getStr() == "quick"
        assert e["reason"].getStr() == "trivial"
    assert sawTriage

  test "full path serializes the turn under result":
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        ("full", "needs tools"),
      calendarFn = proc(): string = "",
      quickFn = proc(s: JsonNode): string = raise
        newException(ValueError, "must not run"),
      fullFn = fullStub("did it"))
    var state = %*{"message": "schedule x"}
    discard runGraph(g, state)
    assert state["result"]["reply"].getStr() == "did it"
    assert state["result"]["iterations"].getInt() == 2

suite "phase 4d triage binder":
  test "a failed quick_reply answers nothing, the loop takes over":
    var calls = 0
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      inc calls
      if calls == 1:
        return textResp("{\"route\": \"quick\"}")
      raise newException(ValueError, "quick down"))
    let turn = triageGraphTurn(client, "mini",
      freshHome("waku-tri-noreply"),
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        raise newException(ValueError, "must not run"))
    # quick_reply's call raises -> node error drains -> no reply, no result
    let (answered, res) = turn("thanks", nil, false)
    assert answered == false
    assert res.reply == ""

  test "quick triage answers small and cards it":
    let home = freshHome("waku-tri-bindq")
    let db = connectDb(home)
    let script = Script(items: @[textResp("{\"route\": \"quick\", " &
      "\"reason\": \"thanks\"}"), textResp("you're welcome!")])
    var w = newWaku(testSettings(home, graphWorkflows = true),
                    scriptedClient(script), db)
    w.graphTurn = triageGraphTurn(scriptedClient(script), "mini", home,
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        w.runFullTurn(st.jget("message").getStr(), n, s))
    assert w.respond("thanks").reply == "you're welcome!"
    assert script.seen.len == 2  # classify + quick reply, no loop turn
    assert script.seen[1]["model"].getStr() == "mini"
    let rows = db.getAllRows(
      sql"SELECT meta FROM chat_log WHERE role='assistant'")
    let meta = parseJson(rows[0][0])
    assert meta["model"].getStr() == "mini"
    assert meta["graph"]["route"].getStr() == "quick"
    db.close()

  test "full triage runs the same loop as flag-off":
    let home = freshHome("waku-tri-bindf")
    let db = connectDb(home)
    let script = Script(items: @[textResp("{\"route\": \"full\"}"),
                                 textResp("scheduled")])
    var w = newWaku(testSettings(home, graphWorkflows = true),
                    scriptedClient(script), db)
    w.graphTurn = triageGraphTurn(scriptedClient(script), "mini", home,
      proc(st: JsonNode, n: Observer, s: bool): LoopResult =
        w.runFullTurn(st.jget("message").getStr(), n, s))
    assert w.respond("schedule swim").reply == "scheduled"
    let rows = db.getAllRows(
      sql"SELECT meta FROM chat_log WHERE role='assistant'")
    let meta = parseJson(rows[0][0])
    assert meta["model"].getStr() == "m"
    assert meta["graph"]["route"].getStr() == "full"
    db.close()

suite "phase 4d gather workflow":
  test "the router reads counts, never prose":
    assert needsAction(%*{"gh_open_prs": 0, "gh_open_issues": 0,
                          "cal_event_count": 0}) == "quiet"
    assert needsAction(%*{"gh_open_prs": 1, "gh_open_issues": 0,
                          "cal_event_count": 0}) == "propose"
    assert needsAction(%*{"gh_open_prs": 0, "gh_open_issues": 0,
                          "cal_event_count": 2}) == "propose"

  test "every scan owns its key prefix":
    assert scanKeys("scan_github") ==
      @["gh_text", "gh_open_prs", "gh_open_issues"]
    assert scanKeys("scan_web") == @["web_text"]
    assert scanKeys("scan_calendar") == @["cal_text", "cal_event_count"]
    assert scanKeys("scan_memory") == @["mem_text"]
    assert scanKeys("nope") == @[]

  test "safeScan turns failure into honest text":
    let outp = safeScan(%*{"web_text": ""}, proc(): JsonNode =
      raise newException(ValueError, "boom"))
    assert outp["web_text"].getStr() == "unavailable (ValueError: boom)"

  test "quiet runs draft nothing":
    let g = buildGatherGraph(
      githubFn = proc(): JsonNode =
        %*{"gh_text": "", "gh_open_prs": 0, "gh_open_issues": 0},
      webFn = proc(): string = "",
      calendarFn = proc(): JsonNode =
        %*{"cal_text": "", "cal_event_count": 0},
      memoryFn = proc(): string = "",
      synthFn = proc(s: JsonNode): string = "empty",
      draftFn = proc(s: JsonNode): string = raise
        newException(ValueError, "must not run"))
    var state = newJObject()
    discard runGraph(g, state)
    assert state["digest"].getStr() == "empty"
    assert not state.hasKey("draft_path")

  test "propose runs the draft":
    let g = buildGatherGraph(
      githubFn = proc(): JsonNode =
        %*{"gh_text": "one PR", "gh_open_prs": 1, "gh_open_issues": 0},
      webFn = proc(): string = "",
      calendarFn = proc(): JsonNode =
        %*{"cal_text": "", "cal_event_count": 0},
      memoryFn = proc(): string = "",
      synthFn = proc(s: JsonNode): string = "brief!",
      draftFn = proc(s: JsonNode): string = "/tmp/x.md")
    var state = newJObject()
    discard runGraph(g, state)
    assert state["draft_path"].getStr() == "/tmp/x.md"

  test "topology has six nodes and no agent among them":
    let d = gatherTopology()
    assert d["nodes"].len == 6
    for n in d["nodes"]:
      assert n["kind"].getStr() != "agent"  # rule 1: propose, never act

suite "phase 4d gather binders":
  test "calendar binder counts semicolon-separated titles":
    let home = freshHome("waku-g-cal")
    assert calendarBinder(home)() ==
      %*{"cal_text": "(no calendar)", "cal_event_count": 0}
    let today = format(now(), "yyyyMMdd")
    writeFile(home / "calendar.ics",
      "BEGIN:VEVENT\nSUMMARY:A\nDTSTART:" & today & "T090000\n" &
      "BEGIN:VEVENT\nSUMMARY:B\nDTSTART:" & today & "T100000\n")
    assert calendarBinder(home)() ==
      %*{"cal_text": "A; B", "cal_event_count": 2}

  test "memory binder reads facts, honestly empty when none":
    let home = freshHome("waku-g-mem")
    let db = connectDb(home)
    assert memoryBinder(home)() == "(nothing relevant)"
    db.addFact("release", "project repo contributors plan")
    let found = memoryBinder(home)()
    assert "[release]" in found
    db.close()

  test "draft binder writes inside the outbox":
    let home = freshHome("waku-g-draft")
    let path = draftBinder(home)(%*{"digest": "# Morning"})
    assert path == home / "outbox" /
      ("gather-" & format(now(), "yyyy-MM-dd") & ".md")
    assert readFile(path) == "# Morning\n"

  test "a headless gather keeps the digest and writes nothing":
    # Slice 9: a worker may not write runtime data. No `state.db` (the
    # memory scan holds no store), no trace (the tracer is silenced), no
    # outbox draft (`writeDraft = false`) — the orchestrator owns them.
    let home = getTempDir() / ("waku-g-headless-" & $getCurrentProcessId())
    if dirExists(home):
      removeDir(home)
    createDir(home)
    tempHomes.add(home)
    let today = format(now(), "yyyyMMdd")
    writeFile(home / "calendar.ics",
      "BEGIN:VEVENT\nSUMMARY:A\nDTSTART:" & today & "T090000\n")
    let script = Script(items: @[textResp("One meeting.")])
    var w = newWaku(testSettings(home), scriptedClient(script))
    w.tracer.silent = true
    let state = runGather(w, writeDraft = false)
    assert state["digest"].getStr() == "One meeting."
    assert state["cal_event_count"].getInt() == 1
    assert state["draft_path"].getStr() == ""
    assert "no local store" in state["mem_text"].getStr()
    var left: seq[string] = @[]
    for kind, path in walkDir(home):
      left.add(extractFilename(path))
    assert left == @["calendar.ics"]

  test "slice 10: a headless gather keeps its synth usage in the state":
    # The worker cannot write the ledger (silent tracer, no runtime
    # data), so `runGather` hands the synth call's usage back inside
    # the state: `runGatherWorker` turns it into the `cost` child line
    # the orchestrator records. Same usage the response carried.
    let home = getTempDir() / ("waku-g-usage-" & $getCurrentProcessId())
    if dirExists(home):
      removeDir(home)
    createDir(home)
    tempHomes.add(home)
    let today = format(now(), "yyyyMMdd")
    writeFile(home / "calendar.ics",
      "BEGIN:VEVENT\nSUMMARY:A\nDTSTART:" & today & "T090000\n")
    let usageResp = %*{"stop_reason": "end_turn",
      "usage": {"in": 7, "out": 3},
      "content": [{"type": "text", "text": "One meeting."}]}
    let script = Script(items: @[usageResp])
    var w = newWaku(testSettings(home), scriptedClient(script))
    w.tracer.silent = true
    let state = runGather(w, writeDraft = false)
    assert state["usage"]["in"].getInt() == 7
    assert state["usage"]["out"].getInt() == 3
    assert state["usage"]["model"].getStr() == "m"
    assert state["usage"]["kind"].getStr() == "gather"

  test "drafting and headless gathers answer the same digest":
    let filedHome = freshHome("waku-g-draft-filed")
    let headlessHome = freshHome("waku-g-draft-headless")
    let today = format(now(), "yyyyMMdd")
    let stamp = format(now(), "yyyy-MM-dd")
    for home in [filedHome, headlessHome]:
      writeFile(home / "calendar.ics",
        "BEGIN:VEVENT\nSUMMARY:A\nDTSTART:" & today & "T090000\n")
    let filedScript = Script(items: @[textResp("One meeting.")])
    let db = connectDb(filedHome)
    var filed = newWaku(testSettings(filedHome), scriptedClient(filedScript), db)
    let filedState = runGather(filed)
    db.close()
    let headlessScript = Script(items: @[textResp("One meeting.")])
    var headless = newWaku(testSettings(headlessHome),
      scriptedClient(headlessScript))
    headless.tracer.silent = true
    let headlessState = runGather(headless, writeDraft = false)
    assert filedState["digest"].getStr() == headlessState["digest"].getStr()
    assert filedState["draft_path"].getStr() ==
      filedHome / "outbox" / ("gather-" & stamp & ".md")
    assert headlessState["draft_path"].getStr() == ""
    assert not dirExists(headlessHome / "outbox")

  test "bound gather runs end to end and stays quiet":
    let home = freshHome("waku-g-e2e")
    let db = connectDb(home)
    let script = Script(items: @[textResp("All quiet.")])
    var w = newWaku(testSettings(home), scriptedClient(script), db)
    let state = runGather(w)
    assert state["digest"].getStr() == "All quiet."
    assert not state.hasKey("draft_path")  # stubs: no counts, no draft
    assert state["errors"].len == 0
    # the synth prompt saw every section, even empty ones
    assert "WHAT THE WEB SAYS:" in script.seen[0]["messages"][0]["content"].getStr()
    db.close()

suite "phase 4d brief":
  test "runBrief responds and files the reply":
    let home = freshHome("waku-brief")
    let db = connectDb(home)
    let script = Script(items: @[textResp("Your week: swim.")])
    var w = newWaku(testSettings(home), scriptedClient(script), db)
    let (reply, path) = runBrief(w)
    assert reply == "Your week: swim."
    assert path == home / "outbox" /
      ("brief-" & format(now(), "yyyy-MM-dd") & ".txt")
    assert readFile(path) == "Your week: swim.\n"
    db.close()

## The run's teardown, between the last suite that makes a home and the one
## that checks. It sits at module level so a --filter that skips suites still
## cleans up.
removeTempHomes()

suite "phase 4d temp homes":
  test "the run leaves no /tmp waku dir behind":
    check wakuTempDirs() == wakuTempDirsAtStart
