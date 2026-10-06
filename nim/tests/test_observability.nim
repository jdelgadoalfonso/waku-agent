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
