## Turn ids and metered side calls (spec 011 group A, units T1).
##
## Offline only: temp homes, no model calls — the tracer writes files,
## never sockets.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/trace

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc readLines(path: string): seq[JsonNode] =
  result = @[]
  for line in readFile(path).strip().splitLines():
    if line.strip().len > 0:
      result.add(parseJson(line))

suite "turn ids":
  test "mintTurnId is t_ plus 16 hex":
    let id = mintTurnId()
    assert id.startsWith("t_")
    assert id.len == 18
    assert id != mintTurnId()

  test "turn and endTurn share one id, then reset":
    let home = freshHome("waku-trace-turnid")
    var t = newTracer(home, "openrouter", "m")
    t.turn("hi")
    let startId = t.turnId
    assert startId.startsWith("t_")
    t.event("llm", %*{"usage": {"in": 3, "out": 1}})
    t.endTurn("yo", 1)
    assert t.turnId == ""
    let lines = readLines(t.path)
    assert lines.len == 3
    assert lines[0]["type"].getStr() == "turn_start"
    assert lines[0]["turn_id"].getStr() == startId
    assert lines[2]["type"].getStr() == "turn_end"
    assert lines[2]["turn_id"].getStr() == startId
    assert lines[2]["reply"].getStr() == "yo"
    removeDir(home)

suite "metered ledger rows":
  test "loop rows default kind and carry the turn":
    let home = freshHome("waku-trace-looprow")
    var t = newTracer(home, "openrouter", "m")
    t.turn("hi")
    let id = t.turnId
    t.event("llm", %*{"usage": {"in": 10, "out": 2}})
    t.endTurn("yo", 1)
    let rows = readLines(home / "usage.jsonl")
    assert rows.len == 1
    assert rows[0]["kind"].getStr() == "loop"
    assert rows[0]["model"].getStr() == "m"
    assert rows[0]["turn_id"].getStr() == id
    assert rows[0]["in"].getInt() == 10
    assert rows[0]["out"].getInt() == 2
    removeDir(home)

  test "a side kind and model ride the event, not the tracer":
    let home = freshHome("waku-trace-kindrow")
    var t = newTracer(home, "openrouter", "m")
    t.turn("hi")
    let id = t.turnId
    t.event("llm", %*{"kind": "gate", "model": "mini",
      "usage": {"in": 5, "out": 0}})
    t.endTurn("yo", 1)
    let rows = readLines(home / "usage.jsonl")
    assert rows.len == 1
    assert rows[0]["kind"].getStr() == "gate"
    assert rows[0]["model"].getStr() == "mini"
    assert rows[0]["turn_id"].getStr() == id
    assert rows[0]["in"].getInt() == 5
    let lines = readLines(t.path)
    assert lines[1]["model"].getStr() == "mini"
    removeDir(home)

  test "text deltas never reach the trace or the ledger":
    let home = freshHome("waku-trace-text")
    var t = newTracer(home, "openrouter", "m")
    t.turn("hi")
    t.event("text", %*{"delta": "hello"})
    t.endTurn("yo", 1)
    assert readLines(t.path).len == 2
    assert not fileExists(home / "usage.jsonl")
    removeDir(home)
