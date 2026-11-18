## Live-memory tests: gate, gated retrieval, skill matching,
## consolidation and the MEMORY.md mirror — plus the wiring that fills
## the session/app seams. Offline only: scripted `LlmClient` answers,
## temp homes, no network.

import std/json
import std/os
import std/osproc
import std/sets
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/app
import ../src/config
import ../src/db
import ../src/episodes
import ../src/factstore
import ../src/loop
import ../src/memory
import ../src/session
import ../src/memory_live
import ../src/trace
import ../src/wire
import ../src/worker_plugin

proc store(db: DbConn): FactStore = sqliteFactStore(db)

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
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    addFact(db, "Alex", "prefers mornings")
    let client = scriptedClient(
      """{"retrieve": false, "query": "", "reason": "small talk"}""")
    var kinds: seq[string] = @[]
    var decisions: seq[string] = @[]
    let found = gatedRetrieve(db, facts, episodes, client, "mini", 4, "thanks!",
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
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    addFact(db, "Alex", "prefers mornings")
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      %*{"stop_reason": "end_turn", "usage": {"in": 11, "out": 2},
        "content": [{"type": "text",
          "text": """{"retrieve": false, "query": "", "reason": "x"}"""}]})
    var llms: seq[JsonNode] = @[]
    discard gatedRetrieve(db, facts, episodes, client, "mini", 4, "thanks!",
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
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    addFact(db, "Alex", "prefers morning meetings")
    addEpisode(db, "planned the demo with Alex", "2026-09-01")
    let client = scriptedClient(
      """{"retrieve": true, "query": "Alex", "reason": "asks about Alex"}""")
    let found = gatedRetrieve(db, facts, episodes, client, "mini", 4, "when is Alex free?")
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
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "hi", "hello")
    let client = scriptedClient("""{"facts": [], "episode": ""}""")
    assert consolidateIfDue(db, facts, episodes, client, "mini", 6) == 0
    db.close()
    removeDir(home)

  test "a due backlog distills facts, an episode and flips the rows":
    let home = freshHome("waku-memlive-due")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "Alex likes mornings", "noted")
    logChat(db, "ok", "bye")
    let client = scriptedClient(
      """{"facts": [{"subject": "Alex", "content": "likes mornings"}],
         "episode": "talked about Alex"}""")
    assert consolidateIfDue(db, facts, episodes, client, "mini", 1) == 1
    let kept = listFacts(db)
    assert kept.len == 1
    assert kept[0].subject == "alex"
    assert kept[0].source == "consolidation"
    assert listEpisodes(db).len == 1
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "1"
    db.close()
    removeDir(home)

  test "a factless summary still retires the rows":
    let home = freshHome("waku-memlive-nofacts")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "hi", "hello")
    let client = scriptedClient("""{"episode": "said hi"}""")
    assert consolidateIfDue(db, facts, episodes, client, "mini", 1) == 0
    assert listEpisodes(db).len == 1
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "1"
    db.close()
    removeDir(home)

  test "garbage from the summarizer keeps the log pending":
    let home = freshHome("waku-memlive-garbage")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "hi", "hello")
    let client = scriptedClient("thinking only, no JSON here")
    assert consolidateIfDue(db, facts, episodes, client, "mini", 1) == 0
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "0"
    db.close()
    removeDir(home)

suite "operating state is never a fact":
  const opsFacts = [
    "User's treg balance is $0.759 USD (759,000 micro), enabling completion of full research passes.",
    "User's treg balance of $0.00188 is insufficient to complete YouTube research.",
    "The TikHub search returned a 402 when the balance ran out.",
    "treg rate-limited the Aviato calls.",
    "The research turn used 328.5k input tokens.",
    "Sean is out of treg credits."]
  const userFacts = [
    "User researches competitor funding with treg.",
    "Sean values work-life balance.",
    "Sean pays for his tools with a credit card.",
    "Sean's startup spends about $500 a month on AWS."]

  test "a balance, a 402 or a token count is operating state":
    for content in opsFacts:
      assert opsState(%*{"subject": "user", "content": content}), content

  test "a fact about the person is not operating state":
    for content in userFacts:
      assert not opsState(%*{"subject": "sean", "content": content}), content

  test "what memory holds or lacks is the assistant's state, not the person's":
    assert memoryState(%*{"subject": "company",
      "content": "The user does not have the company's business address " &
        "stored in memory and requested it be provided for future use " &
        "on legal pages and footers."})
    assert memoryState(%*{"subject": "company",
      "content": "No record of Sean's passport number exists in memory."})
    assert memoryState(%*{"subject": "company",
      "content": "The assistant could not find the user's address in memory."})
    assert memoryState(%*{"subject": "company",
      "content": "Waku Memory has no business address for the company."})

  test "a fact about the person is not memory state":
    for content in ["Sean has no passport.",
        "Alex prefers morning meetings.",
        "Sean does not keep his passwords in a notes app.",
        "The user connected Claude Code to Waku Memory."]:
      assert not memoryState(%*{"subject": "sean", "content": content}), content

  test "consolidation keeps the person's facts and drops the operating state":
    let home = freshHome("waku-memlive-ops")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "hi", "hello")
    logChat(db, "ok", "bye")
    var proposed: seq[JsonNode] = @[]
    for content in opsFacts:
      proposed.add(%*{"subject": "user", "content": content})
    for content in userFacts:
      proposed.add(%*{"subject": "user", "content": content})
    let distilled = newJObject()
    distilled["facts"] = %proposed
    distilled["episode"] = %"Researched Letta's funding with treg."
    let client = scriptedClient($distilled)
    assert consolidateIfDue(db, facts, episodes, client, "mini", 1) ==
      userFacts.len
    let kept = listFacts(db)
    assert kept.len == userFacts.len
    # newest first, so the person's facts come back reversed
    for i, row in kept:
      assert row.content == userFacts[userFacts.len - 1 - i]
    db.close()
    removeDir(home)

  test "the summariser is told to extract only what the person said":
    assert "Extract only what the person said" in summarizerPrompt
    assert "what the assistant's memory holds or lacks" in
      summarizerPrompt

suite "restates":
  const recalled = "Letta raised a $10M seed (2024-08-01) at a $60M " &
    "valuation, the largest disclosed round among Mem0's competitors. " &
    "Zep raised a $2.3M pre-seed on 2023-12-27. Cognee raised a $1.58M " &
    "pre-seed on 2024-11-20. Mem0 says it raised $24M across a Seed and " &
    "Series A, announced 2025-10-28. Aviato's newest data for these " &
    "companies is from 2024-11-20."

  test "words normalize like the_eval: money, possessives, dates":
    assert "10m" in recallWords("$10M,")
    assert "mem0" in recallWords("Mem0's")
    assert "2026-10-05" in recallWords("dated 2026-10-05")
    assert "2026" notin recallWords("dated 2026-10-05")

  test "all five restated findings drop against what was read":
    const restated = [
      "Letta raised a $10M seed round announced 2024-08-01 at a $60M " &
        "valuation, the largest disclosed round among Mem0's competitors.",
      "Zep raised a $2.3M pre-seed round on 2023-12-27.",
      "Cognee raised a $1.58M pre-seed round on 2024-11-20.",
      "Mem0 claims it raised $24M across a Seed and Series A announced 2025-10-28.",
      "Aviato's most recent data for Mem0's competitors is dated 2024-11-20."]
    for content in restated:
      assert restatesFact(content, recalled), "kept a restatement: " & content

  test "something new the user says is kept: 2026 is not in what was read":
    assert restatesFact("Zep raised another round in 2026.", recalled) == false

  test "a fact without a number is never dropped by the rule":
    assert restatesFact("Sean decided to price below Mem0",
      "Sean and Mem0 met last week") == false

  test "memory read as JSON is compared as text":
    let asJson = "{\"fact\": \"Zep raised a $2.3M\\npre-seed on 2023-12-27.\"}"
    assert restatesFact("Zep raised a $2.3M pre-seed on 2023-12-27.", asJson)

  test "a date is one word, so a bare year never matches it":
    assert restatesFact("Something happened in 2026.", "dated 2026-10-05") == false

suite "recall prompt":
  test "the rule rides along only when something was read, capped":
    let bare = consolidationPrompt("user: hi", "", "")
    assert "already kept" notin bare
    # Distinct tokens: with a repetitive string any slice also matches the
    # kept prefix, which would pass for the wrong reason.
    var toks: seq[string] = @[]
    for i in 0 .. 2000:
      toks.add("w" & align($i, 4, '0'))
    let long = toks.join(" ")
    assert long.len > 7000
    let capped = consolidationPrompt("user: hi", "", long)
    assert "already kept" in capped
    assert "w0001" in capped
    assert "w1999" notin capped

suite "recall consolidation":
  test "a recall turn keeps nothing it read, and still retires the rows":
    let home = freshHome("waku-memlive-recall")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    addFact(db, "zep", "Zep raised $2.3M in 2023")
    logChat(db, "what did Zep raise?", "Zep raised $2.3M in 2023")
    let client = scriptedClient(
      """{"retrieve": true, "query": "Zep", "reason": "asks about Zep"}""",
      """{"facts": [{"subject": "Zep", "content": "Zep raised $2.3M in 2023."}], "episode": ""}""")
    var w = newWaku(liveSettings(home), client, db)
    wireMemory(w, liveSettings(home), db, client, @[])
    let found = w.session.retrieve("what did Zep raise?", nil)
    assert "2.3M" in found, "the gate must find the seeded fact first"
    var kinds: seq[string] = @[]
    w.afterTurn(proc(kind: string, ev: JsonNode) {.closure.} = kinds.add(
      kind & ":" & $ev.jget("new_facts").getInt(0)))
    # afterTurn only announces kept facts, so a dropped batch reads as the
    # metered llm call alone — no "consolidation:N" entry at all.
    assert kinds == @["llm:0"], "restated proposal must drop: " & $kinds
    assert listFacts(db).len == 1, "nothing new stored"
    for row in db.getAllRows(sql"SELECT consolidated FROM chat_log"):
      assert row[0] == "1", "rows retire even when nothing is kept"
    db.close()
    removeDir(home)

  test "something new the user says in a recall turn is still kept":
    let home = freshHome("waku-memlive-recallnew")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    addFact(db, "zep", "Zep raised $2.3M in 2023")
    logChat(db, "what did Zep raise, and note we meet in 2026", "as above")
    let client = scriptedClient(
      """{"retrieve": true, "query": "Zep", "reason": "asks about Zep"}""",
      """{"facts": [{"subject": "Zep", "content": "Zep raised another round in 2026."}], "episode": ""}""")
    var w = newWaku(liveSettings(home), client, db)
    wireMemory(w, liveSettings(home), db, client, @[])
    discard w.session.retrieve("what did Zep raise?", nil)
    var kinds: seq[string] = @[]
    w.afterTurn(proc(kind: string, ev: JsonNode) {.closure.} = kinds.add(
      kind & ":" & $ev.jget("new_facts").getInt(0)))
    assert "consolidation:1" in kinds, "new fact must survive: " & $kinds
    assert listFacts(db).len == 2
    db.close()
    removeDir(home)

suite "MEMORY.md mirror":
  test "the mirror counts what the tables hold":
    let home = freshHome("waku-memlive-mirror")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
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
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
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

  test "a fact save_note saved counts as read, so consolidation leaves it out":
    let home = freshHome("waku-memlive-saved")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "remember Alex",
      "Saved here. Waku Memory is not connected.")
    logChat(db, "anything", "ok")
    # the gate skips: only the saved cell feeds the rule
    let client = scriptedClient(
      """{"retrieve": false, "query": "", "reason": "chat"}""",
      """{"facts": [{"subject": "Alex",
                    "content": "Alex prefers meetings on 2026-10-05."}],
         "episode": "noted a preference"}""")
    var w = newWaku(liveSettings(home), client, db)
    wireMemory(w, liveSettings(home), db, client, @[])
    discard w.session.retrieve("what is the weather?", nil)
    w.savedCell[] = "alex: Alex prefers meetings on 2026-10-05."
    var kinds: seq[string] = @[]
    w.afterTurn(proc(kind: string, ev: JsonNode) {.closure.} = kinds.add(kind))
    assert "consolidation" notin kinds
    assert listFacts(db).len == 0
    db.close()
    removeDir(home)

  test "the same fact is kept when the turn saved nothing":
    let home = freshHome("waku-memlive-unsaved")
    let db = connectDb(home)
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    logChat(db, "remember Alex",
      "Saved here. Waku Memory is not connected.")
    logChat(db, "anything", "ok")
    let client = scriptedClient(
      """{"retrieve": false, "query": "", "reason": "chat"}""",
      """{"facts": [{"subject": "Alex",
                    "content": "Alex prefers meetings on 2026-10-05."}],
         "episode": "noted a preference"}""")
    var w = newWaku(liveSettings(home), client, db)
    wireMemory(w, liveSettings(home), db, client, @[])
    discard w.session.retrieve("what is the weather?", nil)
    var kinds: seq[string] = @[]
    w.afterTurn(proc(kind: string, ev: JsonNode) {.closure.} = kinds.add(
      kind & ":" & $ev.jget("new_facts").getInt(0)))
    assert "consolidation:1" in kinds
    assert listFacts(db).len == 1
    db.close()
    removeDir(home)

# ── S15: installed skills answer the turn (T7b) ──────────────────────────────
#
# Two layers are proven here. `skillWorkerTurn` is the decision itself:
# which matched skill has an installed plugin, what the worker gets, and
# every way it can decline. The wiring below is the other half — the same
# body must still reach `buildSystem` through `wireMemory` (S15c), which
# until now was pinned only in pieces.

proc writeSkill(home, name, description, body: string) =
  ## One home skill exactly as the existing "skill matching" pin writes it.
  createDir(home / "skills" / name)
  writeFile(home / "skills" / name / "SKILL.md",
    "---\nname: " & name & "\ndescription: " & description & "\n---\n\n" &
    body & "\n")

proc deadClient(): LlmClient =
  ## A compiled skill that never calls the model must never reach it.
  LlmClient(create: proc(req: JsonNode): JsonNode =
    raise newException(CatchableError, "no model call expected here"))

proc buildFixture(dir, name, source: string): string =
  ## Compile an EXISTING fixture into `dir/name`, once per suite run (two
  ## `.so` builds are the slowest thing in this file, so the second test
  ## reuses the first). Same command `test_plugin_workers` uses; the
  ## working directory is `nim/`.
  if not dirExists(dir):
    createDir(dir)
  let target = dir / name
  if fileExists(target):
    return target
  let nim = findExe("nim")
  assert nim.len > 0, "nim must be on PATH to build the fixture"
  let (output, code) = execCmdEx(nim & " c --app:lib --panics:off " &
    "--hints:off -o:" & target & " tests/" & source)
  assert code == 0, "fixture build failed: " & output
  target

proc install(home, skill, source: string) =
  ## `<home>/plugins/<skill>.so` — the whole installation signal (S15).
  createDir(home / "plugins")
  copyFile(buildFixture(getTempDir() / "waku-s15-fixtures",
    skill & ".so", source), home / "plugins" / (skill & ".so"))

proc ledgerRows(home: string): seq[JsonNode] =
  ## The permanent spend ledger, read exactly as `test_trace` and
  ## `test_app` read it: one parsed row per model call.
  if not fileExists(home / "usage.jsonl"):
    return @[]
  for line in lines(home / "usage.jsonl"):
    result.add(parseJson(line))

suite "S15 a compiled skill answers the turn":

  test "no installed plugin answers nothing, and stays silent":
    # S15a's rule at the decision point: the absence of a `.so` is not a
    # failure, so it must not colour the turn with a line.
    let home = freshHome("waku-s15-none")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    var lines: seq[JsonNode] = @[]
    var kinds: seq[string] = @[]
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "", "m",
      deadClient(), notify = proc(kind: string, ev: JsonNode) {.closure.} =
        kinds.add(kind)
        lines.add(ev))
    assert not turn.answered
    assert turn.skill == ""
    assert turn.reason == "", "nothing installed is not a failure"
    assert kinds.len == 0, "the text path must stay exactly as silent"
    removeDir(home)

  test "an installed plugin answers the turn headless":
    # The real thing: a `.so` in `<home>/plugins`, loaded and run through
    # `pluginRunHeadless` against a fixture that answers without a model.
    let home = freshHome("waku-s15-live")
    install(home, "workergreet", "fixture_plugin_worker.nim")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    var lines: seq[JsonNode] = @[]
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "", "m",
      deadClient(), notify = proc(kind: string, ev: JsonNode) {.closure.} =
        lines.add(ev))
    assert turn.answered
    assert turn.skill == "workergreet"
    assert turn.reply == "hello: greet the user politely"
    assert lines.len == 1
    assert lines[0]["skill"].getStr() == "workergreet"
    assert lines[0]["mode"].getStr() == "worker"
    assert lines[0]["reason"].getStr() == ""
    removeDir(home)

  test "the worker gets the turn's message, memory and model":
    # What crosses into the plugin: the user's text, the memory this turn
    # read, and the brain the turn is running on. Pinned with a recording
    # runner, because no fixture reads `mem_text`.
    let home = freshHome("waku-s15-args")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var got: seq[string] = @[]
    let turn = skillWorkerTurn(home, @[], "greet the user politely",
      "alex likes mornings", "m", deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        got = @[home, skill, message, memText, model]
        %*{"reply": "worker answer"})
    assert turn.answered
    assert turn.reply == "worker answer"
    assert got == @[home, "workergreet", "greet the user politely",
      "alex likes mornings", "m"]
    removeDir(home)

  test "an empty reply falls back, naming the skill and the reason":
    let home = freshHome("waku-s15-empty")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var lines: seq[JsonNode] = @[]
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "", "m",
      deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        %*{"reply": "   "},
      notify = proc(kind: string, ev: JsonNode) {.closure.} =
        lines.add(ev))
    assert not turn.answered, "an empty answer must never win the turn"
    assert turn.skill == "workergreet"
    assert turn.reason.len > 0
    assert lines.len == 1
    assert lines[0]["skill"].getStr() == "workergreet"
    assert lines[0]["mode"].getStr() == "text"
    assert lines[0]["reason"].getStr() == turn.reason
    removeDir(home)

  test "a raising plugin falls back, naming the skill and the reason":
    let home = freshHome("waku-s15-raise")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var lines: seq[JsonNode] = @[]
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "", "m",
      deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        raise newException(CatchableError, "the graph blew up"),
      notify = proc(kind: string, ev: JsonNode) {.closure.} =
        lines.add(ev))
    assert not turn.answered
    assert "blew up" in turn.reason, turn.reason
    assert lines.len == 1
    assert lines[0]["skill"].getStr() == "workergreet"
    assert lines[0]["reason"].getStr() == turn.reason
    removeDir(home)

  test "an ineligible manifest falls back, and the turn survives it":
    # A real `.so` whose manifest needs a parent-side tool: the worker
    # gate refuses it and `pluginRunHeadless` raises. S15b's other half.
    let home = freshHome("waku-s15-ineligible")
    install(home, "toolhungry", "fixture_plugin_toolneeds.nim")
    writeSkill(home, "toolhungry", "fetch data needing tools", "Fetch it.")
    var lines: seq[JsonNode] = @[]
    let turn = skillWorkerTurn(home, @[], "fetch data", "", "m", deadClient(),
      notify = proc(kind: string, ev: JsonNode) {.closure.} =
        lines.add(ev))
    assert not turn.answered
    assert "not eligible" in turn.reason, turn.reason
    assert lines.len == 1
    assert lines[0]["skill"].getStr() == "toolhungry"
    assert lines[0]["mode"].getStr() == "text"
    removeDir(home)

  test "the best-ranked matched skill that has a plugin answers":
    # The choice is "the first matched skill with a plugin", over the same
    # capped, ranked list `matchingSkills` builds. Here the top match has
    # no plugin and the second does, so the second answers.
    let home = freshHome("waku-s15-rank")
    writeSkill(home, "pool", "plan swim sessions for saturday", "Book a lane.")
    writeSkill(home, "swim", "plan swim sessions", "Bring goggles.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "swim.so", "a file is the signal")
    let turn = skillWorkerTurn(home, @[], "plan a swim saturday", "", "m",
      deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        %*{"reply": "goggles: " & skill})
    assert turn.answered
    assert turn.skill == "swim", "swim is the installed one, pool is not"
    assert turn.reply == "goggles: swim"
    removeDir(home)

# ── S16: a compiled skill's model calls reach the ledger (T7c) ───────────────
#
# The headless run already answers its token counts in `state["usage"]`;
# until T7c that node died at the seam, so the most expensive path in the
# feature booked only its gate call. These tests assert on `usage.jsonl`
# through a real `Tracer`, the same surface the loop and delegated-worker
# tests read, and on the flat `cost` event shape that path already emits.

suite "S16 a compiled skill's run is metered":

  test "an llm skill turn books the skill's tokens on the live turn":
    # The real path: a `.so` whose graph runs an llm node against a
    # scripted client, under a real tracer. Two claims at once — the row
    # carries the skill's counts and its kind names the skill, and it is
    # written while the turn is live (`endTurn` is what blanks the id).
    let home = freshHome("waku-s16-llm")
    install(home, "textopsfx", "fixture_plugin_textops.nim")
    writeSkill(home, "textopsfx", "summarise text operations",
      "Summarise it.")
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      %*{"stop_reason": "end_turn", "usage": {"in": 7, "out": 3},
         "content": [{"type": "text", "text": "corto"}]})
    var t = newTracer(home, "openai", "m")
    t.turn("summarise text operations")
    let turnId = t.turnId
    let turn = skillWorkerTurn(home, @[], "summarise text operations", "",
      "m", client, notify = t.tracerEvent())
    assert turn.answered
    assert turn.reply == "corto"
    t.endTurn(turn.reply, 1)
    let rows = ledgerRows(home)
    assert rows.len == 1, "one skill call, one row: " & $rows
    assert rows[0]["kind"].getStr() == "skill:textopsfx"
    assert rows[0]["model"].getStr() == "m"
    assert rows[0]["in"].getInt() == 7
    assert rows[0]["out"].getInt() == 3
    assert rows[0]["turn_id"].getStr() == turnId,
      "the row must land inside the turn, not after endTurn"
    # The existing `skill` line keeps its current fields; the cost row is
    # added beside it, never instead of it.
    var skillRows, costRows: seq[JsonNode] = @[]
    for line in lines(t.path):
      let row = parseJson(line)
      if row["type"].getStr() == "skill":
        skillRows.add(row)
      elif row["type"].getStr() == "cost":
        costRows.add(row)
    assert skillRows.len == 1
    assert skillRows[0]["skill"].getStr() == "textopsfx"
    assert skillRows[0]["mode"].getStr() == "worker"
    assert skillRows[0]["reason"].getStr() == ""
    assert costRows.len == 1
    assert costRows[0]["kind"].getStr() == "skill:textopsfx"
    assert costRows[0]["in"].getInt() == 7
    assert costRows[0]["out"].getInt() == 3
    removeDir(home)

  test "an empty reply still books its reported usage":
    # S23 supersedes S16's other half: an empty reply that spent tokens
    # still books what it spent — only missing usage books nothing.
    let home = freshHome("waku-s16-empty")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var t = newTracer(home, "openai", "m")
    t.turn("greet the user politely")
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "",
      "m", deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        %*{"reply": "   ",
           "usage": {"kind": "plugin", "model": model, "in": 9,
                     "out": 4}},
      notify = t.tracerEvent())
    assert not turn.answered
    t.endTurn("", 0)
    let rows = ledgerRows(home)
    assert rows.len == 1, "an empty reply with usage still books its cost"
    assert rows[0]["kind"].getStr() == "skill:workergreet"
    assert rows[0]["in"].getInt() == 9
    var skillRows: seq[JsonNode] = @[]
    for line in lines(t.path):
      let row = parseJson(line)
      if row["type"].getStr() == "skill":
        skillRows.add(row)
    assert skillRows.len == 1
    assert skillRows[0]["skill"].getStr() == "workergreet"
    assert skillRows[0]["mode"].getStr() == "text"
    assert skillRows[0]["reason"].getStr() == turn.reason
    removeDir(home)

  test "a run that raises without usage books nothing":
    let home = freshHome("waku-s16-raise")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var t = newTracer(home, "openai", "m")
    t.turn("greet the user politely")
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "",
      "m", deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        raise newException(CatchableError, "the graph blew up"),
      notify = t.tracerEvent())
    assert not turn.answered
    t.endTurn("", 0)
    assert ledgerRows(home).len == 0, "a run that raised is not a cost"
    var skillRows: seq[JsonNode] = @[]
    for line in lines(t.path):
      let row = parseJson(line)
      if row["type"].getStr() == "skill":
        skillRows.add(row)
    assert skillRows.len == 1
    assert skillRows[0]["skill"].getStr() == "workergreet"
    assert skillRows[0]["mode"].getStr() == "text"
    assert skillRows[0]["reason"].getStr() == turn.reason
    removeDir(home)

  test "a bare PluginFailed without usage fails open with no cost":
    let home = freshHome("waku-s23-bare")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var t = newTracer(home, "openai", "m")
    t.turn("greet the user politely")
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "",
      "m", deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        raise newException(PluginFailed, "bare boom"),
      notify = t.tracerEvent())
    assert not turn.answered
    t.endTurn("", 0)
    assert ledgerRows(home).len == 0
    removeDir(home)

  test "a run that raises with partial usage still books it":
    # S23: a raise after llm calls keeps its spend.
    let home = freshHome("waku-s23-raise-usage")
    writeSkill(home, "workergreet", "greet the user politely", "Say hello.")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "workergreet.so", "a file is the signal")
    var t = newTracer(home, "openai", "m")
    t.turn("greet the user politely")
    let turn = skillWorkerTurn(home, @[], "greet the user politely", "",
      "m", deadClient(),
      run = proc(home, skill, message, memText, model: string,
                 client: LlmClient): JsonNode {.closure.} =
        var pf = newException(PluginFailed, "the graph blew up mid-run")
        pf.usage = %*{"kind": "plugin", "model": model, "in": 6, "out": 2}
        raise pf,
      notify = t.tracerEvent())
    assert not turn.answered
    t.endTurn("", 0)
    let prows = ledgerRows(home)
    assert prows.len == 1, "a raise with usage still books its cost"
    assert prows[0]["kind"].getStr() == "skill:workergreet"
    assert prows[0]["in"].getInt() == 6
    removeDir(home)

  test "an ineligible skill books nothing":
    # The real `.so` gate: `pluginRunHeadless` refuses a manifest that
    # needs a parent-side tool before running anything, so no model was
    # called and no row may appear.
    let home = freshHome("waku-s16-ineligible")
    install(home, "toolhungry", "fixture_plugin_toolneeds.nim")
    writeSkill(home, "toolhungry", "fetch data needing tools", "Fetch it.")
    var t = newTracer(home, "openai", "m")
    t.turn("fetch data")
    let turn = skillWorkerTurn(home, @[], "fetch data", "", "m",
      deadClient(), notify = t.tracerEvent())
    assert not turn.answered
    assert "not eligible" in turn.reason, turn.reason
    t.endTurn("", 0)
    assert ledgerRows(home).len == 0, "an ineligible skill never ran"
    var skillRows: seq[JsonNode] = @[]
    for line in lines(t.path):
      let row = parseJson(line)
      if row["type"].getStr() == "skill":
        skillRows.add(row)
    assert skillRows.len == 1
    assert skillRows[0]["skill"].getStr() == "toolhungry"
    assert skillRows[0]["mode"].getStr() == "text"
    assert skillRows[0]["reason"].getStr() == turn.reason
    removeDir(home)

suite "S15c a matched skill reaches the prompt through the wiring":

  test "wireMemory and buildSystem carry a non-empty skill body":
    # The chain end to end: the seam `wireMemory` fills answers a body,
    # and `buildSystem` splices it under the heading the model reads.
    let home = freshHome("waku-s15c")
    writeSkill(home, "swim", "plan Saturday swim sessions", "Bring goggles.")
    let db = connectDb(home)
    let client = scriptedClient(
      """{"retrieve": false, "query": "", "reason": "chat"}""")
    var w = newWaku(liveSettings(home), client, db)
    wireMemory(w, liveSettings(home), db, client, @[])
    let sys = w.session.buildSystem("plan a swim Saturday")
    assert "Relevant skill instructions:" in sys
    assert "### swim" in sys
    assert "Bring goggles." in sys
    db.close()
    removeDir(home)
