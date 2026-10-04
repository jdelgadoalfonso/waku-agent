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
    assert collected[0]["tokens_in"].getInt() == 10
    assert collected[0]["tokens_out"].getInt() == 5
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
