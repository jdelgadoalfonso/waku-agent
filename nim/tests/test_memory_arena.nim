## Phase 8d tests: memory arena + judgment arena.
## Offline only: temp homes, stub runners, injected fixtures. No network,
## no `.waku/` writes outside temp dirs.
##
## Ground truth: `waku/ops/memory_arena.py` (the scorer is pure; the runners
## are seams) and the judgment half of `waku/ops/judgment_arena.py` (read as
## spec only — its haiku-era defaults travel verbatim, never "fixed").

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import db_connector/db_sqlite

import ../src/arena
import ../src/db
import ../src/memory
import ../src/memory_arena
import ../src/providers

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc exampleFixture(dir: string): string =
  ## The shipped four-probe shape, minimal: recall / update / restraint /
  ## reasoning, one per test kind the scorer handles.
  let path = dir / "probes.json"
  writeFile(path, """{"tracks": {"demo": {
    "label": "Demo", "seed": ["Priya prefers morning meetings."],
    "probes": [
      {"id": "recall", "test": "recall",
       "question": "When does Priya like to meet?",
       "expect_any": ["morning"]},
      {"id": "update", "test": "update",
       "question": "When is the review?",
       "expect_any": ["Wednesday"], "stale_any": ["Tuesday"]},
      {"id": "restraint", "test": "restraint",
       "question": "What is Priya's phone number?",
       "expect_refusal": true},
      {"id": "reasoning", "test": "reasoning",
       "question": "Can Marcus make it Wednesday?",
       "expect_any": ["yes", "can"], "expect_all": ["Wednesday"]},
      {"id": "quiet", "test": "quiet",
       "question": "What is 17 times 4?",
       "expect_retrieval": false}
    ]}}}""")
  path

suite "phase 8d memory score":
  test "a present answer passes, certain":
    let (outcome, certain, _) = memScore("morning works",
      %*{"expect_any": ["morning"]})
    assert outcome == memPass
    assert certain

  test "a superseded answer is stale, with the witness named":
    let (outcome, certain, why) = memScore("Tuesday, obviously",
      %*{"expect_any": ["Wednesday"], "stale_any": ["Tuesday"]})
    assert outcome == memStale
    assert certain
    assert "Tuesday" in why

  test "an absent answer with nothing wrong asserted is a miss":
    let (outcome, certain, _) = memScore("no idea when",
      %*{"expect_any": ["Wednesday"], "stale_any": ["Tuesday"]})
    assert outcome == memMiss
    assert certain

  test "a refusal where one was due passes, but uncertain":
    let (outcome, certain, _) = memScore("I don't know her number",
      %*{"expect_refusal": true})
    assert outcome == memPass
    assert not certain

  test "an answer where refusal was due is invented, uncertain":
    let (outcome, certain, _) = memScore("it is 555-0100",
      %*{"expect_refusal": true})
    assert outcome == memInvented
    assert not certain

  test "multi-hop needs every name or it is half the reasoning":
    let (outcome, _, why) = memScore("yes, she can",
      %*{"expect_any": ["yes", "can"], "expect_all": ["Wednesday"]})
    assert outcome == memMiss
    assert "Wednesday" in why

  test "retrieving for a no-retrieval probe is a miss even when right":
    let (outcome, certain, _) = memScore("68",
      %*{"expect_retrieval": false}, retrieved = true,
      hasRetrieved = true)
    assert outcome == memMiss
    assert certain

  test "unretrieved no-retrieval probes still grade normally":
    let (outcome, _, _) = memScore("I don't know",
      %*{"expect_retrieval": false, "expect_refusal": true},
      retrieved = false, hasRetrieved = true)
    assert outcome == memPass

suite "phase 8d memory scoreboard":
  test "worst behaviour first: invented outranks everything":
    let rows = %*[
      {"contestant": "clean", "probe": "p1", "outcome": "pass",
       "certain": true, "tokens": 10},
      {"contestant": "liar", "probe": "p1", "outcome": "invented",
       "certain": true, "tokens": 3},
      {"contestant": "stale", "probe": "p1", "outcome": "stale",
       "certain": true, "tokens": 5}]
    let board = memScoreboard(rows)
    assert board[0]["contestant"].getStr() == "liar"
    assert board[1]["contestant"].getStr() == "stale"
    assert board[2]["contestant"].getStr() == "clean"
    assert board[2]["probes"].getInt() == 1
    assert board[2]["tokens"].getInt() == 10

  test "uncertain rows count needs_judge":
    let rows = %*[
      {"contestant": "c", "probe": "p1", "outcome": "pass",
       "certain": false, "tokens": 1},
      {"contestant": "c", "probe": "p2", "outcome": "pass",
       "certain": true, "tokens": 2}]
    let board = memScoreboard(rows)
    assert board[0]["needs_judge"].getInt() == 1
    assert board[0]["probes"].getInt() == 2

  test "render names the table and the heuristic footnote":
    let board = %*[{"contestant": "c", "pass": 1, "stale": 0,
      "invented": 0, "miss": 0, "tokens": 4, "needs_judge": 1}]
    let text = renderMemBoard(board)
    assert "contestant" in text
    assert "invented" in text
    assert "judge" in text.toLowerAscii()

  test "render stays quiet when nothing rests on the heuristic":
    let board = %*[{"contestant": "c", "pass": 1, "stale": 0,
      "invented": 0, "miss": 0, "tokens": 4, "needs_judge": 0}]
    assert "judge" notin renderMemBoard(board).toLowerAscii()

suite "phase 8d control leaks":
  test "only recall probes can leak; refusal and arithmetic cannot":
    assert probeAssertsRecall(%*{"expect_any": ["x"]})
    assert probeAssertsRecall(%*{"expect_all": ["x"]})
    assert not probeAssertsRecall(%*{"expect_refusal": true,
      "expect_any": ["x"]})
    assert not probeAssertsRecall(%*{"expect_any": ["x"],
      "expect_retrieval": false})

  test "a control pass on a recall probe names the probe":
    let probes = %*[{"id": "recall", "expect_any": ["x"]},
      {"id": "restraint", "expect_refusal": true}]
    let results = %*[
      {"contestant": "control", "probe": "recall", "outcome": "pass"},
      {"contestant": "control", "probe": "restraint",
       "outcome": "pass"},
      {"contestant": "sqlite", "probe": "recall", "outcome": "pass"}]
    assert leakedProbes(results, probes) == %*["recall"]

suite "phase 8d arena naming":
  test "the key is twelve hex chars over track, model and seed":
    let a = arenaKey("demo", "p:m", @["one", "two"])
    assert a.len == 12
    for c in a:
      assert c in {'0' .. '9', 'a' .. 'f'}
    assert arenaKey("demo", "p:m", @["one", "two"]) == a
    assert arenaKey("other", "p:m", @["one", "two"]) != a
    assert arenaKey("demo", "p:other", @["one", "two"]) != a
    assert arenaKey("demo", "p:m", @["one"]) != a

  test "the partition names the race on both sides":
    let p = arenaPartition("demo", "p:m", @["one"])
    assert p.startsWith("waku-arena-")
    assert arenaKey("demo", "p:m", @["one"]) in p

  test "homes live under the dot-arena base, named for the backend":
    let root = freshDir("waku-mem-naming")
    let base = arenaBaseDir(root)
    assert base.endsWith(".waku-arena")
    assert arenaHome(base, "sqlite", "abc123") .endsWith(
      "sqlite-abc123")
    removeDir(root)

suite "phase 8d probe fixtures":
  test "a temp fixture loads with its source and example flag":
    let root = freshDir("waku-mem-fixture")
    let path = exampleFixture(root)
    let fx = loadFixture(path)
    assert fx["tracks"].hasKey("demo")
    assert fx["source"].getStr() == path
    assert not fx["is_example"].getBool()
    removeDir(root)

  test "probe files scan the home dir and the env override":
    let root = freshDir("waku-mem-files")
    let shipped = exampleFixture(root)
    createDir(root / "home" / "probes")
    writeFile(root / "home" / "probes" / "mine.json", "{}")
    let files = probeFiles(shipped, root / "home", "")
    assert files.len == 2
    assert files[0]["name"].getStr() == "example (shipped)"
    assert files[1]["path"].getStr().endsWith("mine.json")
    let withEnv = probeFiles(shipped, root / "home", "/tmp/other.json")
    assert withEnv[^1]["name"].getStr().endsWith("(env)")
    removeDir(root)

  test "probe sets flatten tracks and skip broken files":
    let root = freshDir("waku-mem-sets")
    let shipped = exampleFixture(root)
    writeFile(root / "broken.json", "{oops")
    let sets = probeSets(@[
      %*{"name": "example (shipped)", "path": shipped},
      %*{"name": "broken", "path": root / "broken.json"}])
    assert sets.len == 1
    assert sets[0]["track"].getStr() == "demo"
    assert sets[0]["facts"].getInt() == 1
    assert sets[0]["probes"].getInt() == 5
    assert sets[0]["id"].getStr().contains("demo")
    removeDir(root)

  test "resolving a wanted set names its track, else the fallback":
    let root = freshDir("waku-mem-resolve")
    let shipped = exampleFixture(root)
    let sets = probeSets(@[
      %*{"name": "example (shipped)", "path": shipped}])
    let (found, track, path) = resolveTrack(sets[0]["id"].getStr(),
      sets, "fallback")
    assert found
    assert track == "demo"
    assert path == shipped
    let (found2, track2, _) = resolveTrack("nope", sets, "fallback")
    assert not found2
    assert track2 == "fallback"
    removeDir(root)

suite "phase 8d arena models":
  test "pinned specs price cheapest first, unknown prices are zero":
    let providers: seq[Provider] = @[]
    let models = arenaModels(@["p:beta", "p:alpha"], providers)
    # default estimate ties, so the spec breaks it, like Python's tuple
    assert models[0]["spec"].getStr() == "p:alpha"
    assert models[1]["spec"].getStr() == "p:beta"
    assert models[0].hasKey("price_in")
    assert models[0].hasKey("price_out")

suite "phase 8d available backends":
  test "sqlite and the control always run, hosted only when ready":
    let backends = availableBackends(@[],
      initTable[string, string]())
    assert backends[0] == "sqlite"
    assert backends[^1] == "control"

  test "a configured mem0 joins between sqlite and the control":
    var env = initTable[string, string]()
    env["MEM0_API_KEY"] = "sk-test"
    let backends = availableBackends(@[], env)
    assert "mem0" in backends
    assert backends[0] == "sqlite"
    assert backends[^1] == "control"

proc judgeProviders(): seq[Provider] =
  ## The tier vendors with their key envs, like the PROVIDERS registry
  ## Python reads `key_env` from (user key comes from the env table).
  @[Provider(name: "anthropic", keyEnv: "ANTHROPIC_API_KEY"),
    Provider(name: "openai", keyEnv: "OPENAI_API_KEY"),
    Provider(name: "xai", keyEnv: "XAI_API_KEY")]

suite "phase 8d judgment contestants":
  test "jev is listed with its key reason, unready without one":
    let outp = judgmentContestants(initTable[string, string](),
      judgeProviders())
    assert outp[0]["spec"].getStr() == jevSpec
    assert outp[0]["label"].getStr() == "Jev"
    assert not outp[0]["ready"].getBool()
    assert "TYPESAFE_API_KEY" in outp[0]["why"].getStr()

  test "a typesafe key readies jev and picks it":
    let outp = judgmentContestants(
      {"TYPESAFE_API_KEY": "ts-1"}.toTable, judgeProviders())
    assert outp[0]["ready"].getBool()
    assert outp[0]["picked"].getBool()

  test "pinned tiers follow their vendor keys, haiku defaults intact":
    # The tier ids are ground truth from judgment_arena.py — a "fix"
    # here would fork the race, so the test pins them verbatim.
    var found = false
    for t in judgeTiers:
      if t == ("anthropic", "claude-opus-5",
          "claude-haiku-4-5-20251001"):
        found = true
    assert found
    assert "anthropic:claude-opus-5" in defaultPicks
    assert "anthropic:claude-haiku-4-5-20251001" in defaultPicks
    assert "openai:gpt-5.4-mini" in defaultPicks
    var env = initTable[string, string]()
    env["ANTHROPIC_API_KEY"] = "sk-a"
    let outp = judgmentContestants(env, judgeProviders())
    var haiku = newJNull()
    for c in outp:
      if c["spec"].getStr() == "anthropic:claude-haiku-4-5-20251001":
        haiku = c
    assert haiku.kind != JNull
    assert haiku["ready"].getBool()
    assert haiku["picked"].getBool()

  test "judges without keys stay unpicked but listed":
    let outp = judgmentContestants(initTable[string, string](),
      judgeProviders())
    var mini = newJNull()
    for c in outp:
      if c["spec"].getStr() == "openai:gpt-5.4-mini":
        mini = c
    assert mini.kind != JNull
    assert not mini["ready"].getBool()
    assert not mini["picked"].getBool()
    assert "OPENAI_API_KEY" in mini["why"].getStr()

suite "phase 8d judgment key":
  test "empty and non-ascii keys are errors before any write":
    assert checkJudgmentKey("").startsWith("paste")
    assert "ASCII" in checkJudgmentKey("clave-con-á")
    assert checkJudgmentKey("ts-live-key").len == 0

suite "phase 8d judgment board":
  test "an empty home loads no runs":
    let root = freshDir("waku-jboard-empty")
    assert loadJudgmentRuns(root).len == 0
    removeDir(root)

  test "runs persist newest first, capped at twenty, bad lines skipped":
    let root = freshDir("waku-jboard-cap")
    for i in 0 ..< 22:
      saveJudgmentRun(root, %*{"at": i, "suite": "s"})
    createDir(root)
    writeFile(judgmentBoardPath(root), readFile(
      judgmentBoardPath(root)) & "not json\n")
    let runs = loadJudgmentRuns(root)
    assert runs.len == 20
    assert runs[0]["at"].getInt() == 21
    removeDir(root)

suite "phase 8d is_right":
  test "noul lands on a side of the coin flip":
    assert isRight("noul", %true, %*{"noul": 0.8})
    assert not isRight("noul", %true, %*{"noul": 0.2})

  test "choice picks the option, score rounds to the level":
    assert isRight("choice", %"b", %*{"choice": "b"})
    assert not isRight("choice", %"b", %*{"choice": "a"})
    assert isRight("score", %2, %*{"score": 2.4})
    assert not isRight("score", %2, %*{"score": 1.4})

  test "answer shapes read one line per primitive":
    assert "probability" in answerShape(%*{"type": "noul"})
    assert "b" in answerShape(%*{"type": "choice",
      "criteria": {"a": "first", "b": "second"}})
    assert "levels" in answerShape(%*{"type": "score",
      "criteria": ["low", "high"]})

suite "phase 8d race pipelines":
  test "memory: an unknown track ends the race before any runner":
    let root = freshDir("waku-mem-race-track")
    let fx = loadFixture(exampleFixture(root))
    var ran = false
    var kinds: seq[string] = @[]
    let run: MemoryRunFn =
      proc(backends: seq[string], track, model: string, seedOnly: bool,
           fixture: JsonNode, emit: SseEmit) = ran = true
    memoryRace(@["sqlite"], "nope", "", false, fx, run,
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert kinds == @["done"]
    assert not ran
    removeDir(root)

  test "memory: no runner is an honest done error, not a hang":
    let root = freshDir("waku-mem-race-nil")
    let fx = loadFixture(exampleFixture(root))
    var last = ""
    memoryRace(@["sqlite"], "demo", "", false, fx, nil,
      proc(kind: string, ev: JsonNode) = last = $ev)
    assert "not wired" in last
    removeDir(root)

  test "memory: empty backends default to sqlite, like Python":
    let root = freshDir("waku-mem-race-default")
    let fx = loadFixture(exampleFixture(root))
    var got: seq[string] = @[]
    var kinds: seq[string] = @[]
    let run: MemoryRunFn =
      proc(backends: seq[string], track, model: string, seedOnly: bool,
           fixture: JsonNode, emit: SseEmit) =
        got = backends
        emit("done", newJObject())
    memoryRace(@[], "demo", "", false, fx, run,
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert got == @["sqlite"]
    assert kinds == @["done"]
    removeDir(root)

  test "memory: a dying runner ends done with no crash":
    let root = freshDir("waku-mem-race-boom")
    let fx = loadFixture(exampleFixture(root))
    var last = ""
    let run: MemoryRunFn =
      proc(backends: seq[string], track, model: string, seedOnly: bool,
           fixture: JsonNode, emit: SseEmit) =
        raise newException(CatchableError, "mem boom")
    memoryRace(@["sqlite"], "demo", "", false, fx, run,
      proc(kind: string, ev: JsonNode) = last = $ev)
    assert "mem boom" in last
    removeDir(root)

  test "judgment: an unknown suite ends the race before any runner":
    var ran = false
    var last = ""
    let race: JudgmentRaceFn =
      proc(suiteId: string, specs: seq[string], suites: JsonNode,
           emit: SseEmit) = ran = true
    judgmentRace("nope", @[jevSpec], newJArray(), race,
      proc(kind: string, ev: JsonNode) = last = $ev)
    assert "unknown suite" in last
    assert not ran

  test "judgment: no runner is an honest done error":
    var last = ""
    judgmentRace("s1", @[jevSpec],
      %*[{"id": "s1", "title": "Leads"}],
      nil, proc(kind: string, ev: JsonNode) = last = $ev)
    assert "not wired" in last

  test "judgment: a stubbed race streams through and closes done":
    var kinds: seq[string] = @[]
    let race: JudgmentRaceFn =
      proc(suiteId: string, specs: seq[string], suites: JsonNode,
           emit: SseEmit) =
        assert suiteId == "s1"
        assert specs == @[jevSpec]
        emit("answer", %*{"spec": jevSpec, "ok": true})
        emit("done", %*{"scoreboard": []})
    judgmentRace("s1", @[jevSpec], %*[{"id": "s1"}], race,
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert kinds == @["answer", "done"]

suite "phase 8d clean":
  test "no seed means nothing can be named, so nothing is deleted":
    let outp = cleanStores("/tmp/does-not-exist", "demo", "p:m", @[])
    assert "no track chosen" in outp["error"].getStr()

  test "clean removes only this race's homes, never the live home":
    let root = freshDir("waku-mem-clean")
    let base = arenaBaseDir(root)
    let key = arenaKey("demo", "p:m", @["seed line"])
    createDir(arenaHome(base, "sqlite", key))
    writeFile(arenaHome(base, "sqlite", key) / "state.db", "x")
    createDir(arenaHome(base, "sqlite", "otherkey1234"))
    let outp = cleanStores(base, "demo", "p:m", @["seed line"],
      nil)
    assert ("sqlite-" & key) in outp["removed"][0].getStr()
    assert not dirExists(arenaHome(base, "sqlite", key))
    assert dirExists(arenaHome(base, "sqlite", "otherkey1234"))
    # hosted wipes with no runner stay honest errors, never silent skips
    assert outp["errors"].len == 2
    assert "not wired" in outp["errors"][0].getStr()
    removeDir(root)

  test "a wired wipe reports the hosted partition it removed":
    let root = freshDir("waku-mem-cleanwipe")
    let base = arenaBaseDir(root)
    let wipe: HostedWipeFn =
      proc(store, partition: string): bool =
        assert "waku-arena-" in partition
        true
    let outp = cleanStores(base, "demo", "p:m", @["seed line"], wipe)
    assert outp["errors"].len == 0
    assert outp["removed"].len == 2
    assert outp["partition"].getStr().startsWith("waku-arena-")
    removeDir(root)

suite "phase 8d store contents":
  test "sqlite reads its arena copy, control explains itself":
    let root = freshDir("waku-mem-stores")
    let live = root / "live"
    createDir(live)
    let fx = loadFixture(exampleFixture(root))
    let seed = @["Priya prefers morning meetings."]
    # seed the arena copy the way a race would have
    let db = connectDb(arenaHome(arenaBaseDir(live), "sqlite",
      arenaKey("demo", "", seed)))
    db.addFact("priya", "prefers morning meetings")
    db.close()
    let rows = storeContents(@[], initTable[string, string](),
      "demo", "", fx, "", 8, live, nil)
    var sqlite = newJNull()
    var control = newJNull()
    for r in rows:
      if r["store"].getStr() == "sqlite":
        sqlite = r
      if r["store"].getStr() == "control":
        control = r
    assert sqlite["count"].getInt() == 1
    assert sqlite["kind"].getStr() == "arena"
    assert sqlite["facts"][0]["subject"].getStr() == "priya"
    assert "told nothing" in control["note"].getStr()
    assert control["kind"].getStr() == "control"
    removeDir(root)

  test "without a track the sqlite card is the live home":
    let root = freshDir("waku-mem-storeslive")
    let live = root / "live"
    createDir(live)
    let db = connectDb(live)
    db.addFact("priya", "prefers morning meetings")
    db.close()
    let rows = storeContents(@[], initTable[string, string](),
      "", "", newJNull(), "", 8, live, nil)
    assert rows[0]["store"].getStr() == "sqlite"
    assert rows[0]["kind"].getStr() == "live"
    assert rows[0]["count"].getInt() == 1
    removeDir(root)

  test "hosted stores without a runner report an error, not zero":
    var env = initTable[string, string]()
    env["MEM0_API_KEY"] = "sk-test"
    let rows = storeContents(@[], env, "", "", newJNull(), "mem0",
      500, "/tmp/does-not-exist", nil)
    assert rows.len == 1
    assert rows[0]["store"].getStr() == "mem0"
    assert "not wired" in rows[0]["error"].getStr()

  test "langmem without postgres explains itself instead of zero":
    var env = initTable[string, string]()
    env["OPENAI_API_KEY"] = "sk-test"
    let rows = storeContents(@[], env, "", "", newJNull(), "", 8,
      "/tmp/does-not-exist", nil)
    for r in rows:
      if r["store"].getStr() == "langmem":
        assert "in-memory" in r["note"].getStr()
