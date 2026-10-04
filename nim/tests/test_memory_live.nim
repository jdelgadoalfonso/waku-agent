## Live-memory tests: gate, gated retrieval, skill matching,
## consolidation and the MEMORY.md mirror — plus the wiring that fills
## the session/app seams. Offline only: scripted `LlmClient` answers,
## temp homes, no network.

import std/json
import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/app
import ../src/config
import ../src/db
import ../src/loop
import ../src/memory
import ../src/memory_live
import ../src/wire

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc scriptedClient(replies: varargs[string]): LlmClient =
  var i = 0
  var texts: seq[string] = @[]
  for r in replies:
    texts.add(r)
  LlmClient(create: proc(req: JsonNode): JsonNode =
    let text = texts[i]
    inc i
    %*{"content": [{"type": "text", "text": text}]})

proc liveSettings(home: string): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
    smallModel: "mini", consolidateEvery: 1, retrievalTopK: 4)

suite "retrieval gate":
  test "a yes returns query and reason":
    let client = scriptedClient(
      """{"retrieve": true, "query": "alex meetings", "reason": "asks about Alex"}""")
    let (retrieve, query, reason) = shouldRetrieve(client, "mini",
      "when am I meeting Alex?")
    assert retrieve == true
    assert query == "alex meetings"
    assert reason == "asks about Alex"

  test "a no passes through":
    let client = scriptedClient(
      """{"retrieve": false, "query": "", "reason": "pure small talk"}""")
    let (retrieve, query, reason) = shouldRetrieve(client, "mini", "thanks!")
    assert retrieve == false
    assert query == ""
    assert reason == "pure small talk"

  test "no JSON fails open with the raw message":
    let client = scriptedClient("thinking thinking thinking")
    let (retrieve, query, reason) = shouldRetrieve(client, "mini", "hi Alex")
    assert retrieve == true
    assert query == "hi Alex"
    assert "no JSON" in reason

  test "a broken client fails open":
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      raise newException(CatchableError, "down"))
    let (retrieve, query, reason) = shouldRetrieve(client, "mini", "hi Alex")
    assert retrieve == true
    assert query == "hi Alex"
    assert "failed open" in reason

suite "gated retrieval":
  test "a skip announces itself and searches nothing":
    let home = freshHome("waku-memlive-skip")
    let db = connectDb(home)
    addFact(db, "Alex", "prefers mornings")
    let client = scriptedClient(
      """{"retrieve": false, "query": "", "reason": "small talk"}""")
    var kinds: seq[string] = @[]
    var decisions: seq[string] = @[]
    let found = gatedRetrieve(db, client, "mini", 4, "thanks!",
      proc(kind: string, ev: JsonNode) {.closure.} =
        kinds.add(kind)
        if kind == "gate":
          decisions.add(ev["decision"].getStr()))
    assert found == ""
    assert kinds == @["llm", "gate"]
    assert decisions == @["skip"]
    db.close()
    removeDir(home)

  test "the gate call is metered with kind and model":
    let home = freshHome("waku-memlive-gatemeter")
    let db = connectDb(home)
    addFact(db, "Alex", "prefers mornings")
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      %*{"stop_reason": "end_turn", "usage": {"in": 11, "out": 2},
        "content": [{"type": "text",
          "text": """{"retrieve": false, "query": "", "reason": "x"}"""}]})
    var llms: seq[JsonNode] = @[]
    discard gatedRetrieve(db, client, "mini", 4, "thanks!",
      proc(kind: string, ev: JsonNode) {.closure.} =
        if kind == "llm":
          llms.add(ev))
    assert llms.len == 1
    assert llms[0]["kind"].getStr() == "gate"
    assert llms[0]["model"].getStr() == "mini"
    assert llms[0]["usage"]["in"].getInt() == 11
    db.close()
    removeDir(home)

  test "a retrieve returns facts and episodes":
    let home = freshHome("waku-memlive-hit")
    let db = connectDb(home)
    addFact(db, "Alex", "prefers morning meetings")
    addEpisode(db, "planned the demo with Alex", "2026-09-01")
    let client = scriptedClient(
      """{"retrieve": true, "query": "Alex", "reason": "asks about Alex"}""")
    let found = gatedRetrieve(db, client, "mini", 4, "when is Alex free?")
    assert "morning meetings" in found
    assert "demo with Alex" in found
    db.close()
    removeDir(home)

suite "skill matching":
  test "two shared keywords match, one does not":
    let home = freshHome("waku-memlive-skills")
    createDir(home / "skills" / "swim")
    writeFile(home / "skills" / "swim" / "SKILL.md",
      "---\nname: swim\n" &
      "description: plan Saturday swim sessions\n---\n\nBring goggles.\n")
    let hit = matchingSkills(home, @[], "plan a swim Saturday")
    assert "### swim" in hit
    assert "Bring goggles." in hit
    assert matchingSkills(home, @[], "what is for lunch") == ""
    removeDir(home)

suite "consolidation":
  test "fewer than N exchanges is not due":
    let home = freshHome("waku-memlive-notdue")
    let db = connectDb(home)
    logChat(db, "hi", "hello")
    let client = scriptedClient("""{"facts": [], "episode": ""}""")
    assert consolidateIfDue(db, client, "mini", 6) == 0
    db.close()
    removeDir(home)

  test "a due backlog distills facts, an episode and flips the rows":
    let home = freshHome("waku-memlive-due")
    let db = connectDb(home)
    logChat(db, "Alex likes mornings", "noted")
    logChat(db, "ok", "bye")
    let client = scriptedClient(
      """{"facts": [{"subject": "Alex", "content": "likes mornings"}],
         "episode": "talked about Alex"}""")
    assert consolidateIfDue(db, client, "mini", 1) == 1
    let facts = listFacts(db)
    assert facts.len == 1
    assert facts[0].subject == "alex"
    assert facts[0].source == "consolidation"
    assert listEpisodes(db).len == 1
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "1"
    db.close()
    removeDir(home)

  test "a factless summary still retires the rows":
    let home = freshHome("waku-memlive-nofacts")
    let db = connectDb(home)
    logChat(db, "hi", "hello")
    let client = scriptedClient("""{"episode": "said hi"}""")
    assert consolidateIfDue(db, client, "mini", 1) == 0
    assert listEpisodes(db).len == 1
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "1"
    db.close()
    removeDir(home)

  test "garbage from the summarizer keeps the log pending":
    let home = freshHome("waku-memlive-garbage")
    let db = connectDb(home)
    logChat(db, "hi", "hello")
    let client = scriptedClient("thinking only, no JSON here")
    assert consolidateIfDue(db, client, "mini", 1) == 0
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "0"
    db.close()
    removeDir(home)

suite "MEMORY.md mirror":
  test "the mirror counts what the tables hold":
    let home = freshHome("waku-memlive-mirror")
    let db = connectDb(home)
    addFact(db, "Alex", "prefers mornings")
    addEpisode(db, "a quiet week", "2026-09-01")
    exportMarkdown(db, home)
    let text = readFile(home / "MEMORY.md")
    assert "Facts — semantic memory (1)" in text
    assert "prefers mornings" in text
    assert "Episodes — episodic memory (1)" in text
    assert "a quiet week" in text
    db.close()
    removeDir(home)

suite "wiring":
  test "wireMemory fills the seams and syncs after a turn":
    let home = freshHome("waku-memlive-wire")
    let db = connectDb(home)
    addFact(db, "Alex", "prefers morning meetings")
    logChat(db, "remember Alex", "done")
    let client = scriptedClient(
      """{"retrieve": true, "query": "Alex", "reason": "asks about Alex"}""",
      """{"facts": [{"subject": "Priya", "content": "dives on Saturdays"}],
         "episode": "met Priya"}""")
    var w = newWaku(liveSettings(home), client, db)
    assert w.session.retrieve.isNil
    wireMemory(w, liveSettings(home), db, client, @[])
    assert not w.session.retrieve.isNil
    assert not w.session.skillsFor.isNil
    assert not w.afterTurn.isNil
    let found = w.session.retrieve("when is Alex free?", nil)
    assert "morning meetings" in found
    var kinds: seq[string] = @[]
    w.afterTurn(proc(kind: string, ev: JsonNode) {.closure.} = kinds.add(
      kind & ":" & $ev.jget("new_facts").getInt(0)))
    assert "consolidation:1" in kinds
    assert fileExists(home / "MEMORY.md")
    assert "dives on Saturdays" in readFile(home / "MEMORY.md")
    db.close()
    removeDir(home)
