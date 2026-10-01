## Phase 8c tests: the model arena — compare history store, reprice +
## aggregate, clear / regrade / delete_run, compare/stream pipeline.
## Offline only: temp homes, stub race/judge runners, injected clock via
## explicit `ts`. No network, no `.waku/` writes outside temp dirs.
##
## Ground truth: `waku/ops/compare_history.py` (store + aggregate) and the
## `history_response` / `compare_regrade` / `compare_delete_run` /
## `compare_stream` entry points of `waku/ops/arena.py`.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import ../src/arena

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc fullResult(spec: string = "anthropic:m"): JsonNode =
  ## One per-model result shaped like the race produces it: gate as an
  ## object, tools as [{tool}], a long reply, token counts and a stale
  ## cost (repriced at read time, like Python).
  %*{
    "spec": spec,
    "provider": spec.split(':')[0],
    "model": spec.split(':')[1],
    "reply": "r".repeat(1500),
    "gate": {"decision": "retrieve", "reason": "needs facts"},
    "iterations": 2,
    "latency_ms": 120,
    "tools": [{"tool": "search_notes"}],
    "tokens_in": 100,
    "tokens_out": 50,
    "cost_usd": 999.0,
    "cutoff": "",
    "completion": {"passed": true, "why": "ok", "case": "c1"},
  }
  # No "quality" key: ungraded, like a fresh race result.

suite "phase 8c compare history store":
  test "an empty home loads no runs":
    let root = freshDir("waku-arena-empty")
    assert loadRuns(root).len == 0
    removeDir(root)

  test "append persists one slimmed run under an explicit ts":
    let root = freshDir("waku-arena-append")
    appendRun(root, "hello", @[fullResult()], "2026-10-01T00:00:00+00:00")
    let runs = loadRuns(root)
    assert runs.len == 1
    assert runs[0]["ts"].getStr() == "2026-10-01T00:00:00+00:00"
    assert runs[0]["message"].getStr() == "hello"
    assert runs[0]["results"].len == 1
    removeDir(root)

  test "slim caps the reply and flattens gate and tools":
    let root = freshDir("waku-arena-slim")
    appendRun(root, "hi", @[fullResult()], "2026-10-01T00:00:00+00:00")
    let r = loadRuns(root)[0]["results"][0]
    assert r["reply"].getStr().len == 1000
    assert r["gate"].getStr() == "retrieve"
    assert r["tools"] == %*["search_notes"]
    assert r["completion"]["passed"].getBool()
    removeDir(root)

  test "bad json lines are skipped, like Python":
    let root = freshDir("waku-arena-badline")
    createDir(root / "compare")
    writeFile(root / "compare" / "history.jsonl",
      "{\"ts\": \"t1\", \"message\": \"a\", \"results\": []}\nnot json\n\n")
    assert loadRuns(root).len == 1
    removeDir(root)

  test "the log caps at the most recent 50 runs":
    let root = freshDir("waku-arena-cap")
    for i in 0 ..< 52:
      appendRun(root, "m" & $i, newJArray(), "ts-" & $i)
    let runs = loadRuns(root)
    assert runs.len == 50
    assert runs[0]["ts"].getStr() == "ts-2"
    assert runs[^1]["ts"].getStr() == "ts-51"
    removeDir(root)

  test "clear wipes only the arena log":
    let root = freshDir("waku-arena-clear")
    writeFile(root / "usage.jsonl", "{}\n")
    appendRun(root, "hi", newJArray(), "ts-1")
    clearRuns(root)
    assert loadRuns(root).len == 0
    assert fileExists(root / "usage.jsonl")
    removeDir(root)

suite "phase 8c aggregate":
  test "totals sum over successful runs; errors count runs only":
    let ok = %*{"spec": "a:m", "provider": "a", "model": "m",
      "latency_ms": 100, "tokens_in": 10, "tokens_out": 5,
      "cost_usd": 0.5, "completion": {"passed": true},
      "quality": {"score": 8.0}}
    let bad = %*{"spec": "a:m", "provider": "a", "model": "m",
      "error": "boom"}
    let runs = %*[{"ts": "t1", "message": "q", "results": [ok, bad]}]
    let agg = aggregateRuns(runs)
    assert agg.len == 1
    assert agg[0]["runs"].getInt() == 2
    assert agg[0]["ok"].getInt() == 1
    assert agg[0]["total_latency_ms"].getInt() == 100
    assert agg[0]["total_tokens_in"].getInt() == 10
    assert agg[0]["total_tokens"].getInt() == 15
    assert agg[0]["cases_passed"].getInt() == 1
    assert agg[0]["cases_scored"].getInt() == 1
    assert agg[0]["quality_avg"].getFloat() == 8.0
    assert agg[0]["quality_n"].getInt() == 1
    assert agg[0]["total_cost_usd"].getFloat() == 0.5
    removeDir(freshDir("waku-arena-noop"))

  test "cheapest total first, like Python":
    let runs = %*[{"ts": "t", "message": "q", "results": [
      {"spec": "a:pricey", "provider": "a", "model": "pricey",
       "cost_usd": 9.0},
      {"spec": "a:cheap", "provider": "a", "model": "cheap",
       "cost_usd": 1.0}]}]
    let agg = aggregateRuns(runs)
    assert agg[0]["spec"].getStr() == "a:cheap"
    assert agg[1]["spec"].getStr() == "a:pricey"

suite "phase 8c historyResponse reprice":
  test "stored costs reprice from tokens with the current table":
    # claude-haiku-4-5-20251001 is (1.0, 5.0): 1M in + 1M out = 6.0,
    # so the stale 999.0 is visibly replaced (exact in binary, no eps).
    let r = %*{"spec": "anthropic:claude-haiku-4-5-20251001",
      "provider": "anthropic", "model": "claude-haiku-4-5-20251001",
      "tokens_in": 1000000, "tokens_out": 1000000, "cost_usd": 999.0}
    let outp = historyResponse(%*[{"ts": "t", "message": "q",
      "results": [r]}], @[])
    assert outp["runs"][0]["results"][0]["cost_usd"].getFloat() == 6.0
    assert outp["runs"][0]["results"][0]["cutoff"].getStr() == "2025-02"
    let row = outp["aggregate"][0]
    assert row["rate_in"].getFloat() == 1.0
    assert row["rate_out"].getFloat() == 5.0
    assert row["cutoff"].getStr() == "2025-02"

  test "error rows keep their cost but still get the cutoff":
    let r = %*{"spec": "a:m", "provider": "a", "model": "m",
      "error": "boom", "cost_usd": 7.0}
    let outp = historyResponse(%*[{"ts": "t", "message": "q",
      "results": [r]}], @[])
    assert outp["runs"][0]["results"][0]["cost_usd"].getFloat() == 7.0
    assert outp["runs"][0]["results"][0].hasKey("cutoff")

  test "runs come back newest first, at most 20":
    var runs = newJArray()
    for i in 0 ..< 22:
      runs.add(%*{"ts": "ts-" & $i, "message": "q", "results": []})
    let outp = historyResponse(runs, @[])
    assert outp["runs"].len == 20
    assert outp["runs"][0]["ts"].getStr() == "ts-21"
    assert outp["runs"][^1]["ts"].getStr() == "ts-2"

suite "phase 8c compareClear and compareDeleteRun":
  test "clear returns the empty shape and wipes the file":
    let root = freshDir("waku-arena-cclear")
    appendRun(root, "hi", @[fullResult()], "ts-1")
    let outp = compareClear(root)
    assert outp["ok"].getBool()
    assert outp["runs"].len == 0
    assert outp["aggregate"].len == 0
    assert loadRuns(root).len == 0
    removeDir(root)

  test "delete_run drops one race by ts and refreshes the shape":
    let root = freshDir("waku-arena-cdel")
    appendRun(root, "first", @[fullResult()], "ts-1")
    appendRun(root, "second", @[fullResult()], "ts-2")
    let outp = compareDeleteRun(root, "ts-1", @[])
    assert outp["runs"].len == 1
    assert outp["runs"][0]["ts"].getStr() == "ts-2"
    assert loadRuns(root).len == 1
    removeDir(root)

suite "phase 8c compareRegrade":
  test "no runs means the empty shape, never a judge call":
    let root = freshDir("waku-arena-rgempty")
    var called = false
    let judge: JudgeFn =
      proc(task, reply, spec: string, tools: JsonNode): JsonNode =
        called = true
        %*{"score": 9.0}
    let outp = compareRegrade(root, newJObject(), @[], judge)
    assert outp["runs"].len == 0
    assert outp["aggregate"].len == 0
    assert not called
    removeDir(root)

  test "only_missing grades the ungraded and skips the graded":
    let root = freshDir("waku-arena-rgmiss")
    let graded = fullResult("a:m1")
    graded["quality"] = %*{"score": 5.0}
    let pending = fullResult("a:m2")
    appendRun(root, "q", @[graded, pending], "ts-1")
    var seen: seq[string] = @[]
    let judge: JudgeFn =
      proc(task, reply, spec: string, tools: JsonNode): JsonNode =
        seen.add(reply)
        %*{"score": 9.0}
    let outp = compareRegrade(root, %*{"only_missing": true}, @[], judge)
    assert seen.len == 1
    let rows = outp["runs"][0]["results"]
    assert rows[0]["quality"]["score"].getFloat() == 5.0
    assert rows[1]["quality"]["score"].getFloat() == 9.0
    # persisted: a reload still shows the grade
    assert loadRuns(root)[0]["results"][1]["quality"]["score"].getFloat() == 9.0
    removeDir(root)

  test "a spec filter grades just one card":
    let root = freshDir("waku-arena-rgspec")
    appendRun(root, "q", @[fullResult("a:m1"), fullResult("a:m2")], "ts-1")
    var seen: seq[string] = @[]
    let judge: JudgeFn =
      proc(task, reply, spec: string, tools: JsonNode): JsonNode =
        seen.add(spec)
        %*{"score": 7.0}
    discard compareRegrade(root, %*{"spec": "a:m2"}, @[], judge)
    assert seen == @[""]
    let rows = loadRuns(root)[0]["results"]
    assert rows[0].getOrDefault("quality").kind == JNull
    assert rows[1]["quality"]["score"].getFloat() == 7.0
    removeDir(root)

  test "error and empty-reply rows are never graded":
    let root = freshDir("waku-arena-rgskip")
    let bad = %*{"spec": "a:m1", "provider": "a", "model": "m1",
      "error": "boom", "reply": "text"}
    let empty = %*{"spec": "a:m2", "provider": "a", "model": "m2",
      "reply": "   "}
    appendRun(root, "q", @[bad, empty], "ts-1")
    var called = false
    let judge: JudgeFn =
      proc(task, reply, spec: string, tools: JsonNode): JsonNode =
        called = true
        %*{"score": 9.0}
    discard compareRegrade(root, newJObject(), @[], judge)
    assert not called
    removeDir(root)

  test "history tools reach the judge as stored names":
    let root = freshDir("waku-arena-rgtools")
    appendRun(root, "q", @[fullResult()], "ts-1")
    var got: JsonNode = newJNull()
    let judge: JudgeFn =
      proc(task, reply, spec: string, tools: JsonNode): JsonNode =
        got = tools
        %*{"score": 9.0}
    discard compareRegrade(root, newJObject(), @[], judge)
    assert got == %*["search_notes"]
    removeDir(root)

suite "phase 8c compareStreamRun pipeline":
  test "an empty message or no models ends the race before it starts":
    let root = freshDir("waku-arena-stempty")
    var frames: seq[string] = @[]
    let race: RaceFn =
      proc(message: string, specs: seq[string], emit: SseEmit): JsonNode =
        newJArray()
    compareStreamRun(root, %*{"message": "  ", "models": ["a:m"]}, @[],
      race, nil, "", "ts-now",
      proc(kind: string, ev: JsonNode) = frames.add(kind & ":" & $ev))
    assert frames.len == 1
    assert frames[0].startsWith("done:")
    assert "message and models required" in frames[0]
    assert loadRuns(root).len == 0
    removeDir(root)

  test "no wired runner is an honest done error, not a hang":
    let root = freshDir("waku-arena-stnil")
    var frames: seq[string] = @[]
    compareStreamRun(root, %*{"message": "hi", "models": ["a:m"]}, @[],
      nil, nil, "", "ts-now",
      proc(kind: string, ev: JsonNode) = frames.add(kind & ":" & $ev))
    assert frames.len == 1
    assert "not wired" in frames[0]
    assert loadRuns(root).len == 0
    removeDir(root)

  test "a stubbed race persists slimmed results and ends done":
    let root = freshDir("waku-arena-stub")
    var kinds: seq[string] = @[]
    let race: RaceFn =
      proc(message: string, specs: seq[string], emit: SseEmit): JsonNode =
        assert message == "hi"
        assert specs == @["a:m"]
        emit("start", %*{"spec": "a:m"})
        emit("result", %*{"spec": "a:m"})
        result = newJArray()
        result.add(fullResult("a:m"))
    compareStreamRun(root, %*{"message": "hi", "models": ["a:m"]}, @[],
      race, nil, "", "ts-now",
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert kinds == @["start", "result", "done"]
    let runs = loadRuns(root)
    assert runs.len == 1
    assert runs[0]["message"].getStr() == "hi"
    assert runs[0]["results"][0]["gate"].getStr() == "retrieve"
    removeDir(root)

  test "judge=true grades after the race and folds quality in":
    let root = freshDir("waku-arena-stjudge")
    var kinds: seq[string] = @[]
    let race: RaceFn =
      proc(message: string, specs: seq[string], emit: SseEmit): JsonNode =
        result = newJArray()
        result.add(fullResult("a:m"))
    let judge: JudgeFn =
      proc(task, reply, judgeSpec: string, tools: JsonNode): JsonNode =
        assert task == "hi"
        assert judgeSpec == ""
        assert tools == %*["search_notes"]
        %*{"score": 8.0}
    compareStreamRun(root,
      %*{"message": "hi", "models": ["a:m"], "judge": true}, @[],
      race, judge, "", "ts-now",
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert kinds[0] == "grading"
    assert kinds[^1] == "done"
    assert "grade" in kinds
    assert loadRuns(root)[0]["results"][0]["quality"]["score"].getFloat() == 8.0
    removeDir(root)

  test "judge=true with no runner fails the race honestly":
    let root = freshDir("waku-arena-stjudgenil")
    var last = ""
    let race: RaceFn =
      proc(message: string, specs: seq[string], emit: SseEmit): JsonNode =
        result = newJArray()
        result.add(fullResult("a:m"))
    compareStreamRun(root,
      %*{"message": "hi", "models": ["a:m"], "judge": true}, @[],
      race, nil, "", "ts-now",
      proc(kind: string, ev: JsonNode) = last = $ev)
    assert "not wired" in last
    assert loadRuns(root).len == 0
    removeDir(root)

  test "a dying race ends done with no history write":
    let root = freshDir("waku-arena-stboom")
    var last = ""
    let race: RaceFn =
      proc(message: string, specs: seq[string], emit: SseEmit): JsonNode =
        raise newException(CatchableError, "race boom")
    compareStreamRun(root, %*{"message": "hi", "models": ["a:m"]}, @[],
      race, nil, "", "ts-now",
      proc(kind: string, ev: JsonNode) = last = $ev)
    assert "race boom" in last
    assert loadRuns(root).len == 0
    removeDir(root)

suite "phase 8c judge display name":
  test "the judge_model spec names the grading pass, with a default":
    assert judgeDisplayName(%*{"judge_model": "openai:gpt-x"},
      initTable[string, string]()) == "gpt-x"
    assert judgeDisplayName(newJObject(),
      initTable[string, string]()) == defaultJudgeModel
    assert judgeDisplayName(newJObject(),
      {"WAKU_JUDGE_MODEL": "custom-j"}.toTable) == "custom-j"
