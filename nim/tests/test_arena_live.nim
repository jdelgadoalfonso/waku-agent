## Live-runner tests: model/memory/judgment races plus the judge,
## probes and graph stream — every LLM call scripted, no keys, no
## sockets. The runners are exercised end to end (temp homes, ledgers,
## boards on disk); only the transports are fake.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import ../src/app
import ../src/apple
import ../src/arena_live
import ../src/client
import ../src/config
import ../src/dashboard
import ../src/judge
import ../src/judgment_cases
import ../src/loop
import ../src/wire

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc textResp(text: string, tin = 10, tout = 5): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": tin, "out": tout},
     "content": [{"type": "text", "text": text}]}

proc gateResp(retrieve: bool): JsonNode =
  textResp(if retrieve: """{"retrieve": true, "query": "q",
    "reason": "needs it"}"""
  else: """{"retrieve": false, "query": "", "reason": "small talk"}""")

type Bank = ref object
  scripts: Table[string, seq[JsonNode]]
  pos: Table[string, int]

proc bankClient(bank: Bank): BuildClientFn =
  result = proc(provider, model: string): LlmClient {.closure.} =
    LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      let key = provider & ":" & model
      let i = bank.pos.getOrDefault(key, 0)
      bank.pos[key] = i + 1
      bank.scripts[key][i])

proc stubDeps(home: string, bank: Bank): ArenaDeps =
  ArenaDeps(home: home, providers: @[], dotenvPath: "", apiKey: "",
    fetch: proc(url, meth, body, agent: string): tuple[ok: bool,
      text: string] {.closure.} = (true, "{}"),
    gh: proc(argv: seq[string]): tuple[ok: bool,
      text: string] {.closure.} = (false, "no gh"),
    apple: AppleSeams(hostOs: "linux",
      run: proc(script: string, timeoutSec: int): tuple[ok: bool,
        text: string] {.closure.} = (false, "macOS-only"),
      isRunning: proc(app: string): bool = false,
      launch: proc(app: string) = discard),
    makeExchange: nil, httpPost: nil, env: initTable[string, string](),
    buildClient: bankClient(bank),
    jevPost: proc(body, key: string): tuple[ok: bool, text: string,
      ms: int64] {.closure.} = (false, "no jev", 0),
    jevKey: "", nowUnix: 1700000000)

suite "live model race":
  test "one column runs the loop and prices the ledger":
    let home = freshHome("waku-race-live")
    var bank = Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]())
    bank.scripts["p:m"] = @[gateResp(false), textResp("hi there")]
    var frames: seq[string] = @[]
    let collected = liveRace("hi", @["p:m"], false,
      proc(kind: string, ev: JsonNode) {.closure.} =
        frames.add(kind & ":" & ev.jget("spec").getStr("?")),
      stubDeps(home, bank))
    assert collected.len == 1
    assert collected[0]["reply"].getStr() == "hi there"
    assert collected[0]["gate"]["decision"].getStr() == "skip"
    # Gate + loop: the metered gate call lands in the ledger beside the
    # loop's own row (spec 011) — 10/5 each here.
    assert collected[0]["tokens_in"].getInt() == 20
    assert collected[0]["tokens_out"].getInt() == 10
    var kinds: seq[string] = @[]
    for f in frames:
      kinds.add(f.split(':')[0])
    assert "start" in kinds and "result" in kinds
    removeDir(home)

  test "a dead key is that column's error":
    let home = freshHome("waku-race-dead")
    var bank = Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]())
    let deps = stubDeps(home, bank)
    var deps2 = deps
    deps2.buildClient = proc(provider, model: string): LlmClient =
      LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
        raise newException(CatchableError, "bad key"))
    var frames: seq[string] = @[]
    let collected = liveRace("hi", @["p:m"], false,
      proc(kind: string, ev: JsonNode) {.closure.} =
        frames.add(kind),
      deps2)
    assert collected[0].hasKey("error")
    assert "bad key" in collected[0]["error"].getStr()
    removeDir(home)

suite "live memory race":
  test "sqlite seeds, probes and scores; control runs empty":
    let home = freshHome("waku-memrace-live")
    var bank = Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]())
    let seedTurn = @[gateResp(false), textResp("noted")]
    let probeTurn = @[gateResp(true), textResp("Wednesday")]
    let summ = textResp("""{"facts": [], "episode": ""}""")
    # Every respond also runs afterTurn (consolidation when due), so
    # each turn costs gate + loop + summarizer — the explicit flush
    # then finds nothing pending and makes no call.
    bank.scripts["p:m"] = seedTurn & @[summ] & probeTurn & @[summ] &
      probeTurn & @[summ]
    let fx = %*{"tracks": {"example": {
      "seed": ["the review moved to Wednesday"],
      "probes": [{"id": "p1", "test": "update",
                   "question": "When is the review?",
                   "expect_any": ["Wednesday"],
                   "stale_any": ["Tuesday"]}]}}}
    var frames: seq[string] = @[]
    let run = makeLiveMemoryRun(stubDeps(home, bank))
    run(@["sqlite", "control"], "example", "p:m", false, fx,
      proc(kind: string, ev: JsonNode) {.closure.} =
        frames.add(kind & ":" & ev.jget("contestant").getStr("?")))
    var kinds: seq[string] = @[]
    for f in frames:
      kinds.add(f.split(':')[0])
    assert "start" in kinds
    assert "probe" in kinds
    var dones = 0
    for f in frames:
      if f.startsWith("done:"):
        inc dones
    assert dones == 1
    removeDir(home)

  test "unknown backends fail per contestant, not the run":
    let home = freshHome("waku-memrace-skip")
    var bank = Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]())
    let fx = %*{"tracks": {"example": {"seed": [], "probes": []}}}
    var failed = 0
    let run = makeLiveMemoryRun(stubDeps(home, bank))
    run(@["mem0"], "example", "p:m", false, fx,
      proc(kind: string, ev: JsonNode) {.closure.} =
        if kind == "failed":
          inc failed)
    assert failed == 1
    removeDir(home)

suite "live judgment race":
  test "columns answer blocks and land on the board":
    let home = freshHome("waku-jrace-live")
    var bank = Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]())
    var answers: seq[JsonNode] = @[]
    let suites = allSuites()
    for blk in suites["memory"]["cases"]:
      var one = newJObject()
      for q in blk["questions"]:
        let qid = q["id"].getStr()
        case q["type"].getStr()
        of "noul":
          one[qid] = %max(0.0, min(1.0,
            if q["expected"].getBool(): 0.9 else: 0.1))
        of "choice":
          one[qid] = %q["expected"].getStr()
        else:
          one[qid] = %float(q["expected"].getBiggestInt())
      answers.add(textResp($one))
    bank.scripts["p:m"] = answers
    var cells = 0
    var boards = 0
    let run = makeLiveJudgmentRace(stubDeps(home, bank))
    run("memory", @["p:m"], suites,
      proc(kind: string, ev: JsonNode) {.closure.} =
        if kind == "answer":
          inc cells
        elif kind == "done":
          inc boards)
    assert cells == 15
    assert boards == 1
    assert fileExists(home / "judgment_arena.jsonl")
    removeDir(home)

suite "live judge":
  test "the seam grades empty replies as nothing to grade":
    let judge = makeLiveJudge(stubDeps(freshHome("waku-judge-none"),
      Bank(scripts: initTable[string, seq[JsonNode]](),
        pos: initTable[string, int]()))) 
    assert judge("task", "   ", "", %*[]).kind == JNull

  test "judgeReply grades through the injected client":
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      textResp("""{"score": 8, "reason": "solid work"}"""))
    let grade = judgeReply("do the thing", "did it", "p", "m",
      @["save_note"],
      proc(prov, mdl: string): LlmClient = client, nil)
    assert grade["score"].getInt() == 8
    assert grade["reason"].getStr() == "solid work"
    assert grade["judge"].getStr() == "m"

  test "an empty reply is never graded":
    let grade = judgeReply("do it", "   ", "p", "m", @[],
      proc(prov, mdl: string): LlmClient =
        raise newException(CatchableError, "must not run"), nil)
    assert grade.kind == JNull

  test "the referee call is metered as judge":
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      textResp("""{"score": 8, "reason": "solid work"}""", 4, 1))
    var llms: seq[JsonNode] = @[]
    let obs: Observer = proc(kind: string, ev: JsonNode) =
      if kind == "llm":
        llms.add(ev)
    let grade = judgeReply("do the thing", "did it", "p", "m",
      @[], proc(prov, mdl: string): LlmClient = client, nil, obs)
    assert grade["score"].getInt() == 8
    assert llms.len == 1
    assert llms[0]["kind"].getStr() == "judge"
    assert llms[0]["model"].getStr() == "m"
    assert llms[0]["usage"]["in"].getInt() == 4

suite "live turn judge":
  test "one small-model call carries the prompt and reads its tokens":
    let home = freshHome("waku-turnjudge-live")
    var deps = stubDeps(home, Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]()))
    var seen: seq[JsonNode] = @[]
    deps.buildClient = proc(provider, model: string): LlmClient {.closure.} =
      LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
        seen.add(req)
        textResp(
          """{"addresses_question": 9, "grounded": 8, "reason": "ok"}""",
          120, 20))
    let call = makeLiveTurnJudge(deps, "prov")
    let resp = call("grade this turn", "small-1")
    assert seen.len == 1
    assert seen[0]["model"].getStr() == "small-1"
    assert seen[0]["max_tokens"].getInt() == 300
    assert seen[0]["messages"].len == 1
    assert seen[0]["messages"][0]["role"].getStr() == "user"
    assert seen[0]["messages"][0]["content"].getStr() == "grade this turn"
    assert resp["text"].getStr() ==
      """{"addresses_question": 9, "grounded": 8, "reason": "ok"}"""
    assert resp["in"].getInt() == 120
    assert resp["out"].getInt() == 20
    removeDir(home)

  test "a call that raises propagates for the route to refuse":
    let home = freshHome("waku-turnjudge-dead")
    var deps = stubDeps(home, Bank(scripts: initTable[string, seq[JsonNode]](),
      pos: initTable[string, int]()))
    deps.buildClient = proc(provider, model: string): LlmClient {.closure.} =
      raise newException(CatchableError, "bad key")
    let call = makeLiveTurnJudge(deps, "prov")
    expect CatchableError:
      discard call("grade this turn", "small-1")
    removeDir(home)

suite "live probes and graph stream":
  test "provider probe passes silently without a matching key":
    let probe = liveProviderProbe(@[], freshHome("waku-probe-none"),
      proc(url, key: string): string {.closure.} = "{}")
    var values = initTable[string, string]()
    probe(values)

  test "graph stream answers unknown workflows and triage usage":
    let box = WakuBox(providers: @[], dotenvPath: "",
      settings: Settings(provider: "anthropic", home: freshHome("waku-gs")))
    var frames: seq[string] = @[]
    liveGraphStream(box, %*{"workflow": "nope"},
      proc(kind: string, ev: JsonNode) {.closure.} =
        frames.add(kind & ":" & ev.jget("error").getStr("")))
    assert frames.len == 1
    assert "unknown workflow" in frames[0]
    frames = @[]
    liveGraphStream(box, %*{"workflow": "triage"},
      proc(kind: string, ev: JsonNode) {.closure.} =
        frames.add(kind))
    assert frames == @["done"]
    removeDir(box.settings.home)
