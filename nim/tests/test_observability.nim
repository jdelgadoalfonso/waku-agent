## Observability page — turns, tools, memory, spend and evals.
##
## Offline only: temp homes with crafted traces, no model, no sockets.

import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import ../src/observability

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
