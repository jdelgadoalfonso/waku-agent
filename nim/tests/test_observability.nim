## Observability page — turns, tools, memory, spend and evals.
##
## Offline only: temp homes with crafted traces, no model, no sockets.

import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import ../src/observability
import ../src/observe

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result / "traces")

proc writeTrace(home, name: string, lines: seq[string]) =
  writeFile(home / "traces" / name, lines.join("\n") & "\n")

proc ev(kind, turn: string): JsonNode =
  %*{"type": kind, "turn_id": turn, "ts": "2026-10-05T10:00:00.000+00:00"}

suite "read events":
  test "files oldest first, bad lines skipped, names listed":
    let home = freshHome("obs-read")
    writeTrace(home, "b.jsonl", @[$(ev("turn_start", "t_1"))])
    writeTrace(home, "a.jsonl", @["not json", $(ev("turn_end", "t_0"))])
    let (events, errors, files) = readEvents(home)
    assert files == @["a.jsonl", "b.jsonl"]
    assert events.len == 2
    assert events[0]["type"].getStr() == "turn_end"
    assert errors.len == 0
    removeDir(home)

  test "a missing traces dir reads empty":
    let (events, errors, files) = readEvents(getTempDir() / "obs-nope-xyz")
    assert events.len == 0 and errors.len == 0 and files.len == 0

suite "group turns":
  test "starts pair with ends, strays and text drop out":
    let events = @[
      %*{"type": "turn_end", "turn_id": "t_0"},
      %*{"type": "turn_start", "turn_id": "t_1",
          "ts": "2026-10-05T10:00:00.000+00:00", "user_message": "hi"},
      %*{"type": "text", "turn_id": "t_1", "delta": "x"},
      %*{"type": "llm", "turn_id": "t_1"},
      %*{"type": "turn_end", "turn_id": "t_1",
          "ts": "2026-10-05T10:00:01.000+00:00", "reply": "yo",
          "iterations": 2},
      %*{"type": "turn_start", "turn_id": "t_2", "user_message": "open"}]
    let turns = groupTurns(events)
    assert turns.len == 2
    assert turns[0]["turn_id"].getStr() == "t_1"
    assert turns[0]["events"].len == 1
    assert turns[0]["reply"].getStr() == "yo"
    assert turns[0]["iterations"].getInt() == 2
    assert turns[1]["turn_id"].getStr() == "t_2"
    assert turns[1]["unfinished"].getBool()

  test "a start before spec 011 splits the same way":
    let events = @[
      %*{"type": "turn_start", "user_message": "old"},
      %*{"type": "llm"},
      %*{"type": "turn_end", "reply": "done"}]
    let turns = groupTurns(events)
    assert turns.len == 1
    assert turns[0]["turn_id"].getStr() == ""
    assert turns[0]["events"].len == 1

suite "windows":
  test "today, 7d and all, garbage falls back at the route":
    proc tsOf(ms: int64): string =
      format(fromUnix(ms div 1000).utc,
        "yyyy-MM-dd'T'HH:mm:ss'.''000''+00:00'")
    assert validWindow("today") == "today"
    assert validWindow("7d") == "7d"
    assert validWindow("all") == "all"
    assert validWindow("garbage") == "7d"
    let (okN, nowMs) = parseTsMs("2026-10-05T12:00:00.000+00:00")
    assert okN
    let mid = localMidnightMs(nowMs)
    assert inWindow(tsOf(mid), "today", nowMs)
    assert inWindow(tsOf(mid + 3600 * 1000), "today", nowMs)
    assert not inWindow(tsOf(mid - 1), "today", nowMs),
      "a millisecond before local midnight is yesterday"
    assert inWindow("2026-10-05T12:00:00.000+00:00", "7d", nowMs)
    assert not inWindow(tsOf(nowMs - 8 * 86400 * 1000), "7d", nowMs)
    assert inWindow("2020-01-01T00:00:00.000+00:00", "all", nowMs)
    assert not inWindow("not-a-ts", "7d", nowMs)

proc stepEv(kind: string): JsonNode =
  %*{"type": kind, "ts": "2026-10-05T10:00:00.000+00:00"}

suite "waterfall rows":
  test "each kind draws, graph bookkeeping does not":
    assert stepRow(%*{"type": "gate", "decision": "retrieve",
      "reason": "x"})["kind"].getStr() == "gate"
    let llm = stepRow(%*{"type": "llm", "usage": {"in": 10, "out": 2},
      "stop_reason": "end_turn"})
    assert llm["kind"].getStr() == "llm"
    assert llm["call"].getStr() == "loop"
    assert llm["in"].getInt() == 10
    assert llm["final_answer"].getBool() == false
    let tool = stepRow(%*{"type": "tool", "tool": "echo",
      "args": %*{"x": 1}, "output": "hi",
      "call_id": "t1", "duration_ms": 4})
    assert tool["kind"].getStr() == "tool"
    assert tool["source"].getStr() == "local"
    assert tool["duration_ms"].getInt() == 4
    assert tool["read_first"].getBool() == false
    let mem = stepRow(%*{"type": "tool", "tool": "waku_memory_memory_search",
      "args": %*{"query": "q"}, "output": $(%*{"entries": []})})
    assert mem["kind"].getStr() == "memory"
    assert mem["span"].getStr() == "retrieval"
    assert stepRow(%*{"type": "graph_start"}).kind == JNull
    assert stepRow(%*{"type": "score"}).kind == JNull
    assert stepRow(%*{"type": "node_start"}).kind == JNull

  test "an llm without a cost estimates, a receipt keeps its total":
    let llm = stepRow(%*{"type": "llm", "usage": {"in": 10, "out": 2}})
    assert llm["usd"].getFloat() ==
      llmCost("", "", %*{"in": 10, "out": 2})
    let rec = stepRow(%*{"type": "receipt", "total_usd": 0.5})
    assert rec["total_usd"].getFloat() == 0.5

suite "stored scores":
  test "scores join by turn, newest wins per source and name":
    let turn = %*{"turn_id": "t_1", "events": [
      {"type": "score", "turn_id": "t_1", "source": "judge",
       "name": "overall", "value": 7,
       "ts": "2026-10-05T10:00:00.000+00:00"},
      {"type": "score", "turn_id": "t_1", "source": "judge",
       "name": "overall", "value": 9,
       "ts": "2026-10-05T11:00:00.000+00:00"},
      {"type": "score", "turn_id": "t_9", "source": "judge",
       "name": "overall", "value": 1}]}
    let scores = storedScores(turn, @[])
    assert scores.len == 1
    assert scores[0]["value"].getInt() == 9
    assert storedScores(%*{"turn_id": "t_1", "events": []},
      @[%*{"type": "score", "source": "human", "name": "x",
           "value": 1}]).len == 1

suite "built turns":
  test "steps, dollars, loops, story and errors":
    let turn = %*{"turn_id": "t_1", "ts": "2026-10-05T10:00:00.000+00:00",
      "user_message": "hi", "events": [
        {"type": "gate", "decision": "skip", "ts": "2026-10-05T10:00:00.000+00:00"},
        {"type": "llm", "usage": {"in": 10, "out": 2},
         "stop_reason": "end_turn", "ts": "2026-10-05T10:00:01.000+00:00"},
        {"type": "tool", "tool": "bad", "output": "failed boom",
         "ts": "2026-10-05T10:00:03.000+00:00"}]}
    let built = buildTurn(turn, @[], "", "")
    assert built["gate"].getStr() == "skip"
    assert built["tool_calls"].getInt() == 1
    assert built["loops"].getInt() == 1
    assert built["latency_ms"].getInt() == 3000
    assert built["tokens_in"].getInt() == 10
    assert built["errors"].len == 1
    assert built["errors"][0]["tool"].getStr() == "bad"
    assert built["hotspots"]["slowest"].getInt() == 2
    assert built["story"][0]["part"].getStr() == "question"
    assert built["scores"].kind == JArray

suite "turn-eval wiring":
  test "build_turn runs the five code checks, then stored scores":
    let turn = %*{"turn_id": "t_9", "ts": "2026-10-05T10:00:00.000+00:00",
      "user_message": "hi", "reply": "Forty-two.", "events": []}
    let extra = @[%*{"type": "score", "source": "judge",
      "name": "overall", "value": 0.8, "note": "fine",
      "ts": "2026-10-05T10:00:01.000+00:00"}]
    let built = buildTurn(turn, @[], "", "", extra)
    assert built["scores"].len == 6
    assert built["scores"][0]["name"].getStr() == "spend_claim"
    assert built["scores"][4]["name"].getStr() == "under_budget"
    for s in built["scores"][0 .. 4]:
      assert s["source"].getStr() == "code"
    assert built["scores"][4]["value"].getFloat() == 1.0
    assert built["scores"][5]["source"].getStr() == "judge"

  test "your_turns counts the checks the page just ran":
    let turn = %*{"turn_id": "t_9", "ts": "2026-10-05T10:00:00.000+00:00",
      "user_message": "hi", "reply": "Forty-two.", "events": []}
    let built = buildTurn(turn, @[], "", "")
    let (okN, nowMs) = parseTsMs("2026-10-06T00:00:00.000+00:00")
    assert okN
    let yt = yourTurns(@[built], "7d", nowMs)
    proc checkRow(name: string): JsonNode =
      for c in yt["checks"]:
        if c["name"].getStr() == name:
          return c
      newJNull()
    assert yt["turns"].getInt() == 1
    assert checkRow("under_budget")["passed"].getInt() == 1
    assert checkRow("one_report")["na"].getInt() == 1

proc toolEv(tool, output, ts: string): JsonNode =
  %*{"type": "tool", "tool": tool, "args": %*{"query": "q"},
      "output": output, "ts": ts, "call_id": "t1", "duration_ms": 3}

suite "tool stats":
  test "sources sort out and windows filter":
    let events = @[
      toolEv("treg_call", $(%*{"cost_usd": 0.007, "provider": "tomba",
        "endpoint_id": "tomba.email.find"}), "2026-10-05T10:00:00.000+00:00"),
      toolEv("waku_memory_memory_search",
        $(%*{"entries": [{"id": "a"}], "retrieval_trace_id": "rt1"}),
        "2026-10-05T10:00:00.000+00:00"),
      toolEv("echo", "hi", "2026-10-05T10:00:00.000+00:00"),
      toolEv("echo", "old", "2020-01-01T00:00:00.000+00:00")]
    let (okN, nowMs) = parseTsMs("2026-10-06T00:00:00.000+00:00")
    assert okN
    let stats = toolStats(events, @[], "7d", nowMs)
    assert stats["treg"]["calls"].getInt() == 1
    assert stats["treg"]["usd"].getFloat() == 0.007
    assert stats["treg"]["endpoints"][0]["endpoint_id"].getStr() ==
      "tomba.email.find"
    assert stats["waku_memory"]["calls"].getInt() == 1
    assert stats["waku_memory"]["recent_queries"][0]["query"].getStr() == "q"
    assert stats["other"]["tools"][0]["tool"].getStr() == "echo"
    assert stats["other"]["tools"][0]["calls"].getInt() == 1,
      "the 2020 call falls outside 7d"
    assert stats["other"]["tools"][0]["usd"].kind == JNull,
      "unpriced tools read null, never zero"

suite "spend":
  test "estimates, exact receipts and tool dollars add up":
    let home = freshHome("obs-spend")
    writeFile(home / "usage.jsonl",
      $(%*{"ts": "2026-10-05T10:00:00.000+00:00", "provider": "p",
           "model": "m", "kind": "loop", "turn_id": "t_1",
           "in": 10, "out": 2}) & "\n")
    let receipt = %*{"type": "receipt", "turn_id": "t_1",
      "ts": "2026-10-05T10:00:00.000+00:00",
      "model": {"estimate": false, "usd": 0.5}, "total_usd": 0.6}
    let items = spendItems(home, @[receipt], @[])
    assert items.len == 1, "the exact receipt replaces the ledger row"
    assert items[0]["usd"].getFloat() == 0.5
    assert items[0]["charged"].getBool()
    let totals = spendTotals(items, -1, @[receipt])
    assert totals["model_usd"].getFloat() == 0.5
    assert totals["total_usd"].getFloat() == 0.5
    assert totals["charged_usd"].getFloat() == 0.5
    assert totals["charged_turns"].getInt() == 1
    let bare = spendTotals(@[], -1, @[])
    assert bare["charged_usd"].kind == JNull
    assert bare["estimated_usd"].getFloat() == 0.0
    removeDir(home)

suite "summary":
  test "four cards from turns, tools, ledger and spend":
    let home = freshHome("obs-summary")
    let turn = %*{"turn_id": "t_1", "ts": "2026-10-05T10:00:00.000+00:00",
      "user_message": "hi", "loops": 2, "gate": "retrieve", "kept": 1,
      "usd": 0.1, "steps": []}
    let tools = %*{"treg": {"tools": []},
      "waku_memory": {"tools": [
        {"tool": "memory_search", "calls": 2, "errors": 0,
         "span": "retrieval", "avg_results": 3.0},
        {"tool": "memory_remember", "calls": 1, "errors": 0,
         "span": "memory_write"}]},
      "other": {"tools": []}}
    let (okN, nowMs) = parseTsMs("2026-10-06T00:00:00.000+00:00")
    assert okN
    let s = summary(home, @[], @[turn], tools, "7d", nowMs, @[])
    assert s["turns"]["count"].getInt() == 1
    assert s["turns"]["avg_loops"].getFloat() == 2.0
    assert s["memory"]["retrievals"].getInt() == 2
    assert s["memory"]["writes"].getInt() == 1
    assert s["memory"]["gate_retrieve"].getInt() == 1
    removeDir(home)

suite "your turns":
  test "checks read stored scores, judge row counts verdicts":
    let turns = @[%*{"turn_id": "t_1", "ts": "2026-10-05T10:00:00.000+00:00",
      "user_message": "hi",
      "scores": [%*{"source": "code", "name": "spend_claim", "value": 1,
                    "note": "ok"},
                 %*{"source": "judge", "name": "overall", "value": 0.8,
                    "note": "fine"}]}]
    let (okN, nowMs) = parseTsMs("2026-10-06T00:00:00.000+00:00")
    assert okN
    let yt = yourTurns(turns, "7d", nowMs)
    proc checkRow(name: string): JsonNode =
      for c in yt["checks"]:
        if c["name"].getStr() == name:
          return c
      newJNull()
    assert yt["turns"].getInt() == 1
    assert checkRow("spend_claim")["passed"].getInt() == 1
    assert checkRow("one_report")["na"].getInt() == 1
    assert yt["judge"]["passed"].getInt() == 1

suite "turns report":
  test "the table, then every failing turn with its note":
    let home = freshHome("obs-turns-report")
    writeFile(home / "traces" / "2026-10-05.jsonl", [
      $(%*{"type": "turn_start", "turn_id": "t_r1",
           "ts": "2026-10-05T10:00:00.000+00:00", "user_message": "hi"}),
      $(%*{"type": "tool", "turn_id": "t_r1", "tool": "treg_call",
           "args": {},
           "output": "{\"endpoint_id\": \"tomba.x\", \"cost_usd\": 0.0089}",
           "ts": "2026-10-05T10:00:01.000+00:00"}),
      $(%*{"type": "turn_end", "turn_id": "t_r1",
           "ts": "2026-10-05T10:00:02.000+00:00",
           "reply": "The research cost $0.00.", "iterations": 1}),
      $(%*{"type": "turn_start", "turn_id": "t_r2",
           "ts": "2026-10-05T11:00:00.000+00:00", "user_message": "hi"}),
      $(%*{"type": "turn_end", "turn_id": "t_r2",
           "ts": "2026-10-05T11:00:01.000+00:00",
           "reply": "Forty-two.", "iterations": 1})].join("\n") & "\n")
    let text = turnsReport(home, "7d", 1791288000000'i64)
    assert ("Your turns, the last 7 days: 2 turn(s) in " & home /
      "traces") in text, text
    assert "spend_claim" in text
    assert "Failing turns: 1" in text, text
    assert "t_r1  spend_claim: reply says $0.00" in text, text
    assert "\"hi\"" in text
    assert "No failing turns." notin text
    let garbage = turnsReport(home, "garbage", 1791288000000'i64)
    assert "the last 7 days" in garbage
    removeDir(home)

suite "evals info":
  test "no checkout says so, a checkout counts":
    let home = freshHome("obs-evals")
    let bare = evalsInfo(home, "")
    assert bare["deterministic"].kind == JNull
    assert bare["judge_suites"].kind == JNull
    let repo = getTempDir() / "obs-repo"
    if dirExists(repo):
      removeDir(repo)
    createDir(repo / "evals" / "deterministic")
    createDir(repo / "evals" / "judge")
    writeFile(repo / "evals" / "deterministic" / "test_a.py",
      "def test_one():\n    pass\n")
    writeFile(repo / "evals" / "judge" / "test_b.py", "x = 1\n")
    let full = evalsInfo(home, repo)
    assert full["deterministic"]["files"].getInt() == 1
    assert full["deterministic"]["tests"].getInt() == 1
    assert full["judge_suites"] == %*["b"]
    removeDir(home)
    removeDir(repo)

suite "payload":
  test "every key lands, turns newest first":
    let home = freshHome("obs-payload")
    writeTrace(home, "t.jsonl", @[
      $(%*{"type": "turn_start", "turn_id": "t_1",
           "ts": "2026-10-05T10:00:00.000+00:00", "user_message": "hi"}),
      $(%*{"type": "llm", "turn_id": "t_1",
           "ts": "2026-10-05T10:00:01.000+00:00",
           "usage": {"in": 10, "out": 2}, "stop_reason": "end_turn"}),
      $(%*{"type": "turn_end", "turn_id": "t_1",
           "ts": "2026-10-05T10:00:02.000+00:00", "reply": "yo",
           "iterations": 1})])
    let (okN, nowMs) = parseTsMs("2026-10-06T00:00:00.000+00:00")
    assert okN
    let p = payload(home, "p", "m", "7d", nowMs, @[], "")
    for key in ["generated_at", "summary", "spend_by_day", "trace_files",
        "trace_file", "trace_errors", "turns", "tools", "memory", "spend",
        "evals"]:
      assert p.hasKey(key), "payload carries " & key
    assert p["turns"].len == 1
    assert p["turns"][0]["turn_id"].getStr() == "t_1"
    assert p["turns"][0]["judge_offer"].kind == JNull
    assert "your_turns" in p["evals"]
    removeDir(home)
