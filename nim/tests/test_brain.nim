## Research reads first (spec 009 A, unit T1).
##
## Offline only: stub backends, no model calls — the read path makes none
## by itself (searches go through the injected backend).

import std/json
import std/strutils
import std/unittest

import ../src/brain
import ../src/tools
import ../src/wire

proc stubBackend(failSecond: bool,
    texts: varargs[string]): BrainBackend =
  var i = 0
  var answers: seq[string] = @[]
  for t in texts:
    answers.add(t)
  BrainBackend(search: proc(args: JsonNode): string {.closure.} =
    if failSecond and i == 1:
      inc i
      raise newException(IOError, "down")
    let text = answers[i]
    inc i
    text)

proc engramRegistry(search: proc(args: JsonNode): string
    {.closure.}): ToolRegistry =
  var reg: ToolRegistry
  reg.register(Tool(name: "engram_mem_search", description: "s",
    inputSchema: %*{"type": "object"}, fn: search))
  reg

const hits = """Found 2 memories:

[1] #12 (decision) — Pick mem0
    We picked mem0 for the long tail."""

suite "research subject":
  test "filler words go, the subject stays":
    assert subject("research the competitors of mem0") ==
      "competitors mem0"

  test "nothing left falls back to the message":
    assert subject("please research") == "please research"

suite "research trigger":
  test "the skill name is the detector":
    assert isResearch(@["research-report", "other"])
    assert not isResearch(@["other"])
    assert not isResearch(@[])

suite "engram entries":
  test "rows parse to id, title and capped text":
    let found = brainEntries(hits)
    assert found.len == 1
    assert found[0]["id"].getStr() == "#12"
    assert found[0]["title"].getStr() == "Pick mem0"
    assert "long tail" in found[0]["text"].getStr()

  test "rows without an id are skipped":
    let found = brainEntries("Found 0 memories:\n\nno rows here")
    assert found.len == 0

suite "read first":
  test "a disconnected backend reads nothing":
    let (calls, used, context, digests) = readFirst("research mem0",
      BrainBackend())
    assert calls.len == 0 and used.len == 0 and context == ""
    assert digests.len == 0

  test "two searches shape the Used list and the block":
    var seen: seq[string] = @[]
    let backend = stubBackend(false, hits, hits)
    let (calls, used, context, digests) = readFirst("research mem0", backend)
    assert calls.len == 2
    assert calls[0]["tool"].getStr() == brainSearchTool
    assert calls[0]["args"]["limit"].getInt() == subjectLimit
    assert calls[0]["args"]["all_projects"].getBool(),
      "Engram refuses a search that names no project"
    assert calls[0]["args"]["match_mode"].getStr() == "any",
      "the subject search is broad recall, like Python's"
    assert calls[1]["args"]["match_mode"].getStr() == "all",
      "the targeted one is a precise lookup"
    assert calls[1]["args"]["scope"].getStr() == companyScope
    assert used.len == 1, "same hit twice dedupes by id"
    assert used[0]["id"].getStr() == "#12"
    assert used[0]["report"].getBool() == false
    assert context.startsWith("\n" & brainHeading)
    assert "long tail" in context
    assert "Start from this." in context
    assert seen.len == 0

  test "a failed search is skipped, never fatal":
    let backend = stubBackend(true, hits, "unused")
    let (calls, used, context, digests) = readFirst("research mem0", backend)
    assert calls.len == 1
    assert used.len == 1
    assert brainHeading in context

suite "backend lookup":
  test "the registry search tool connects, absence disconnects":
    let backend = brainBackendFor(engramRegistry(
      proc(args: JsonNode): string {.closure.} = "none"))
    assert brainConnected(backend)
    var empty: ToolRegistry
    assert not brainConnected(brainBackendFor(empty))

suite "backend answer shapes":
  test "a json envelope unwraps to its rows, with kind and report":
    # Engram answers a JSON envelope whose `result` holds the rows with
    # their newlines ESCAPED, so parsing the envelope as text finds none.
    let envelope = $(%*{"project": "", "result": hits})
    let found = brainEntries(envelope)
    assert found.len == 1
    assert found[0]["id"].getStr() == "#12"
    assert found[0]["kind"].getStr() == "decision"
    assert found[0]["report"].getBool() == false

  test "waku memory's own entries shape is read too":
    let doc = $(%*{"entries": [
      {"id": "m1", "body": reportMarkerOf & "\n\n# Rival map\n\n- one",
       "kind": "semantic", "created_at": "2026-10-01"},
      {"id": "", "body": "no id, skipped"},
      {"id": "m2", "snippet": "Alex prefers mornings"}]})
    let found = brainEntries(doc)
    assert found.len == 2
    assert found[0]["title"].getStr() == "Rival map"
    assert found[0]["report"].getBool() == true
    assert found[0]["created_at"].getStr() == "2026-10-01"
    assert found[1]["text"].getStr() == "Alex prefers mornings"
    assert found[1]["report"].getBool() == false

  test "a report's marker never reaches the prompt text":
    let doc = $(%*{"entries": [{"id": "m1",
      "body": reportMarkerOf & "\n\n# Rival map\n\nbody here"}]})
    assert brainEntries(doc)[0]["text"].getStr() == "# Rival map body here"

let stubDigest: proc(body: string): string {.closure.} =
  proc(body: string): string =
    "DIGEST:" & body[0 ..< min(20, body.len)]

proc getBackend(answer: string, fail = false): BrainBackend =
  BrainBackend(
    search: proc(args: JsonNode): string {.closure.} = hits,
    get: proc(args: JsonNode): string {.closure.} =
      if fail:
        raise newException(IOError, "down")
      answer,
    digest: stubDigest)

suite "report digest":
  test "waku and engram answer shapes digest, anything else is empty":
    let marked = reportMarkerOf & "\n\n# Rival map\n\n- one\n"
    let waku = getBackend($( %*{"memory": {"id": "7", "body": marked}}))
    assert reportDigest(waku, "7") == "DIGEST:" & marked[0 ..< 20]
    let engram = getBackend($( %*{"result": marked}))
    assert reportDigest(engram, "#12") == "DIGEST:" & marked[0 ..< 20]
    assert reportDigest(getBackend("not json"), "7") == ""
    assert reportDigest(getBackend($( %*{"memory": {"body": "no marker here"}})), "7") == ""
    assert reportDigest(getBackend("boom", true), "7") == "",
      "a failing get reads as no digest, the snippet stands in"
    assert reportDigest(BrainBackend(), "7") == "",
      "no get means no digest"

  test "the tool is asked once with the numeric id":
    var asked: seq[JsonNode] = @[]
    let backend = BrainBackend(
      get: proc(args: JsonNode): string {.closure.} =
        asked.add(args)
        $( %*{"result": reportMarkerOf & "\n\n# t\n"}),
      digest: stubDigest)
    discard reportDigest(backend, "#12")
    assert asked == @[%*{"id": 12}]
    discard reportDigest(backend, "abc")
    assert asked.len == 1, "a non-numeric id never calls"

suite "get lookup":
  test "the registry get tool connects, absence disconnects":
    var reg: ToolRegistry
    reg.register(Tool(name: "engram_mem_search", description: "s",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string {.closure.} = "none"))
    reg.register(Tool(name: "engram_mem_get_observation", description: "g",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string {.closure.} = "one"))
    let backend = brainBackendFor(reg)
    assert brainConnected(backend)
    assert not backend.get.isNil
    var bare: ToolRegistry
    bare.register(Tool(name: "engram_mem_search", description: "s",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string {.closure.} = "none"))
    assert brainBackendFor(bare).get.isNil

const bigReport = reportMarkerOf & """

# Rival map

## Summary
- rival A ships fast

## Findings
""" & "x".repeat(4000)

proc digestBackend(searchAnswers: seq[string], getAnswer: string,
    failGet = false): BrainBackend =
  var i = 0
  var gets = 0
  BrainBackend(
    search: proc(args: JsonNode): string {.closure.} =
      let text = searchAnswers[i]
      inc i
      text,
    get: proc(args: JsonNode): string {.closure.} =
      inc gets
      if failGet:
        raise newException(IOError, "down")
      getAnswer,
    digest: stubDigest)

suite "read first with get":
  test "a report hit is read once and kept as its digest":
    let doc = $(%*{"entries": [{"id": "7",
      "body": bigReport, "kind": "semantic", "created_at": "2026-10-05T12:00:00"}]})
    let backend = digestBackend(@[doc, """{"entries": []}"""],
      $(%*{"memory": {"id": "7", "body": bigReport}}))
    let (calls, used, context, digests) = readFirst("research rivals", backend)
    assert used.len == 1
    assert used[0]["report"].getBool()
    assert used[0]["title"].getStr() == "Rival map"
    assert used[0]["created_at"].getStr() == "2026-10-05"
    assert digests.jget("7").getStr().startsWith("DIGEST:")
    assert calls[0].jget("read_first").getBool()
    assert brainHeading in context

  test "a failing get keeps the snippet and no digest":
    let doc = $(%*{"entries": [{"id": "7",
      "body": bigReport, "kind": "semantic", "created_at": "2026-10-05"}]})
    let backend = digestBackend(@[doc, """{"entries": []}"""], "", true)
    let (calls, used, context, digests) = readFirst("research rivals", backend)
    assert used.len == 1
    assert digests.len == 0
    assert "Rival map" in used[0]["text"].getStr() or "rival" in used[0]["text"].getStr()
    assert brainHeading in context
    assert calls.len == 2

  test "facts are never read and reports stop at three":
    let fact = $(%*{"entries": [{"id": "9", "body": "Alex prefers mornings"}]})
    let three = $(%*{"entries": [
      {"id": "1", "body": bigReport, "kind": "semantic"},
      {"id": "2", "body": bigReport, "kind": "semantic"},
      {"id": "3", "body": bigReport, "kind": "semantic"},
      {"id": "4", "body": bigReport, "kind": "semantic"}]})
    var gets = 0
    let backend = BrainBackend(
      search: proc(args: JsonNode): string {.closure.} = three,
      get: proc(args: JsonNode): string {.closure.} =
        inc gets
        $(%*{"result": bigReport}),
      digest: stubDigest)
    let (calls, used, context, digests) = readFirst("research rivals", backend)
    assert gets == 3, "at most three reports are read whole"
    assert digests.len == 3
    assert "4" notin digests
    let plain = digestBackend(@[fact, """{"entries": []}"""], "")
    let (_, used2, _, digests2) = readFirst("research mornings", plain)
    assert used2.len == 1 and not used2[0]["report"].getBool()
    assert digests2.len == 0
    assert calls.len == 2 and context.len > 0

proc usedEntry(id, title, text, created: string, report: bool): JsonNode =
  %*{"id": id, "title": title, "text": text, "created_at": created,
      "kind": "semantic", "report": report}

suite "brain context":
  test "empty stays empty":
    assert brainContext(@[], newJObject()) == ""

  test "reports come first even when older, newest first inside groups":
    let used = @[
      usedEntry("9", "", "Alex prefers mornings", "2026-10-05", false),
      usedEntry("7", "Rival map", "snippet here", "2026-01-01", true),
      usedEntry("8", "", "older fact", "2026-09-01", false)]
    let ctx = brainContext(used, newJObject())
    assert ctx.startsWith("\n" & brainHeading)
    let r = ctx.find("Rival map")
    let f1 = ctx.find("2026-10-05")
    let f2 = ctx.find("2026-09-01")
    assert r >= 0 and r < f1 and f1 < f2
    assert "date unknown" notin ctx
    assert "memory 7" in ctx and "memory 9" in ctx

  test "a digest renders indented, a missing one falls back to the snippet":
    let used = @[usedEntry("7", "Rival map", "snippet here", "2026-01-01", true)]
    let ctx = brainContext(used, %*{"7": "line1\nline2"})
    assert "its summary:\n  line1\n  line2" in ctx
    let bare = brainContext(used, newJObject())
    assert "snippet here" in bare
    assert "its summary" notin bare

  test "nameless reports and missing dates read honestly":
    let used = @[usedEntry("7", "", "snippet", "", true)]
    let ctx = brainContext(used, newJObject())
    assert "an earlier report" in ctx
    assert "date unknown" in ctx

  test "footers close the block, the get note only with reports":
    let withReport = brainContext(
      @[usedEntry("7", "Rival map", "s", "2026-01-01", true)], newJObject())
    assert "Start from this." in withReport
    assert brainGetTool in withReport
    let factsOnly = brainContext(
      @[usedEntry("9", "", "fact text", "2026-10-05", false)], newJObject())
    assert "Start from this." in factsOnly
    assert brainGetTool notin factsOnly
