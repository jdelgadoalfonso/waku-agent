## Research reads first (spec 009 A, unit T1).
##
## Offline only: stub backends, no model calls — the read path makes none
## by itself (searches go through the injected backend).

import std/json
import std/strutils
import std/unittest

import ../src/brain
import ../src/tools

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
    let (calls, used, context) = readFirst("research mem0",
      BrainBackend())
    assert calls.len == 0 and used.len == 0 and context == ""

  test "two searches shape the Used list and the block":
    var seen: seq[string] = @[]
    let backend = stubBackend(false, hits, hits)
    let (calls, used, context) = readFirst("research mem0", backend)
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
    assert context.startsWith(brainHeading)
    assert "Pick mem0" in context
    assert seen.len == 0

  test "a failed search is skipped, never fatal":
    let backend = stubBackend(true, hits, "unused")
    let (calls, used, context) = readFirst("research mem0", backend)
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
