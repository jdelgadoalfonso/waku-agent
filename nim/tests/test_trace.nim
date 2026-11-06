## Turn ids and metered side calls (spec 011 group A, units T1), and the
## OTLP exporter wiring (spec: odd/tasks/nim-otel-exporter.md).
##
## Offline only: temp homes, no model calls — the tracer writes files,
## never sockets. The span pins inject a capturing `send`, so no test in
## this file opens a connection to anything.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/otel
import ../src/otelproto
import ../src/observe
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

proc attrs(s: Span): seq[(string, string)] = s.attributes

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

  test "a silent tracer writes no event row and no ledger row":
    # Slice 2b: a worker process sets this so the orchestrator stays the
    # turn's only trace writer. `event` drops the row (and so the ledger
    # row an `llm` event would have appended); the turn markers are
    # `turn`/`endTurn`'s, and a worker never calls those.
    let home = freshHome("waku-trace-silent")
    var t = newTracer(home, "openrouter", "m")
    t.silent = true
    t.turn("hi")
    t.event("llm", %*{"usage": {"in": 11, "out": 7}})
    t.event("tool", %*{"name": "gather.web"})
    t.endTurn("yo", 1)
    let lines = readLines(t.path)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "turn_start"
    assert lines[1]["type"].getStr() == "turn_end"
    assert not fileExists(home / "usage.jsonl")
    removeDir(home)

  test "a silent tracer still records nothing when it has no turn":
    let home = freshHome("waku-trace-silent-noturn")
    var t = newTracer(home, "openrouter", "m")
    t.silent = true
    t.event("gate", %*{"route": "gather"})
    assert not fileExists(t.path)
    removeDir(home)

suite "the tracer wired to a collector":
  test "one POST per turn, carrying the root and every event in order":
    # The wire contract, seen from the tracer: `turn` opens the root,
    # every traced event appends a child, and `endTurn` sends the lot
    # once. Nothing else flushes, so a long turn is still one request.
    let home = freshHome("waku-trace-wired")
    var t = newTracer(home, "openrouter", "m", "localhost:6006")
    var sent: seq[Span] = @[]
    var calls = 0
    t.otel.send = proc(url, body: string): ExportResult =
      inc calls
      assert url == "http://localhost:6006/v1/traces"
      sent = t.otel.spans
      (ok: true, detail: "")
    t.turn("hola")
    t.event("llm", %*{"usage": %*{"in": 10, "out": 2}})
    t.event("tool", %*{"tool": "search", "query": "waku"})
    t.event("text", %*{"delta": "hola"})
    assert calls == 0, "nothing leaves before the turn closes"
    t.endTurn("buenas", 1)
    assert calls == 1
    assert sent.len == 3, "the root plus two events; `text` is not a span"
    assert sent[0].name == "agent_run"
    assert sent[1].name == "llm"
    assert sent[2].name == "tool.search"
    assert sent[1].parentSpanId == sent[0].spanId
    assert sent[2].parentSpanId == sent[0].spanId
    assert sent[1].traceId == sent[0].traceId
    assert sent[0].startNano != 0 and sent[0].endNano != 0
    assert sent[1].startNano == sent[1].endNano, "children are zero-duration"
    assert ("openinference.span.kind", "AGENT") in sent[0].attrs
    assert ("waku.user_message", "hola") in sent[0].attrs
    removeDir(home)

  test "a span carries the stamped payload, never the record's own fields":
    # Python builds the span from the reassigned `event` (provider and
    # model merged in) rather than from the `_write` record, so a
    # collector shows which brain answered. `type` and `ts` exist only on
    # the JSONL line and must not show up as telemetry.
    let home = freshHome("waku-trace-stamped")
    var t = newTracer(home, "openrouter", "sonnet-x", "localhost:6006")
    var sent: seq[Span] = @[]
    t.otel.send = proc(url, body: string): ExportResult =
      sent = t.otel.spans
      (ok: true, detail: "")
    t.turn("hola")
    t.event("llm", %*{"usage": %*{"in": 10, "out": 2}})
    t.endTurn("buenas", 1)
    let child = sent[1]
    assert ("waku.provider", "\"openrouter\"") in child.attrs
    assert ("waku.model", "\"sonnet-x\"") in child.attrs
    assert ("waku.usage", "{\"in\": 10, \"out\": 2}") in child.attrs
    assert ("openinference.span.kind", "LLM") in child.attrs
    for (key, _) in child.attrs:
      assert key != "waku.type", "the record's type is not telemetry"
      assert key != "waku.ts", "the record's ts is not telemetry"
    removeDir(home)

  test "no endpoint means no exporter":
    # The opt-in guarantee: the default port builds no exporter and the
    # JSONL trace still lands whole. (The lines themselves are schema
    # v: 2 since spec 012; this test pins the absence of spans, not the
    # row shape — that is the stamped-lines suite above.)
    let home = freshHome("waku-trace-noendpoint")
    var t = newTracer(home, "openrouter", "m")
    assert t.otel.isNil
    t.turn("hola")
    t.event("llm", %*{"usage": %*{"in": 1, "out": 1}})
    t.endTurn("buenas", 1)
    assert readLines(t.path).len == 3
    removeDir(home)

  test "an endpoint the validator refuses does not stop the trace":
    # `newTracer` runs while the agent starts, so a typo in the env var
    # must cost one stderr line and a working JSONL trace, never an
    # exception that takes the whole binary down before the first turn.
    let home = freshHome("waku-trace-badendpoint")
    var t = newTracer(home, "openrouter", "m", "localhost:6006/v1/traces")
    assert t.otel.isNil, "a refused endpoint builds no exporter"
    t.turn("hola")
    t.endTurn("buenas", 1)
    let lines = readLines(t.path)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "turn_start"
    assert lines[1]["type"].getStr() == "turn_end"
    removeDir(home)

suite "spec 012 stamped lines":
  test "an llm line joins its turn and says what it cost":
    let home = freshHome("waku-trace-llmline")
    var t = newTracer(home, "openrouter", "m")
    t.turn("hi")
    let id = t.turnId
    t.event("llm", %*{"usage": {"in": 10, "out": 2}})
    t.endTurn("yo", 1)
    let lines = readLines(t.path)
    assert lines[1]["turn_id"].getStr() == id
    assert lines[1]["span"].getStr() == "llm"
    assert lines[1]["gen_ai.operation.name"].getStr() == "chat"
    assert lines[1]["cost_usd"].getFloat() ==
      llmCost("openrouter", "m", %*{"in": 10, "out": 2})
    removeDir(home)

  test "a tool line is a v2 record with redacted args":
    let home = freshHome("waku-trace-toolline")
    var t = newTracer(home, "openrouter", "m")
    t.turn("hi")
    let id = t.turnId
    t.event("tool", %*{"tool": "echo", "args": %*{"token": "abc", "x": 1},
      "output": "echo:hi", "call_id": "t1", "duration_ms": 4})
    t.endTurn("yo", 1)
    let lines = readLines(t.path)
    let row = lines[1]
    assert row["v"].getInt() == 2
    assert row["turn_id"].getStr() == id
    assert row["source"].getStr() == "local"
    assert row["span"].getStr() == "tool"
    assert row["ok"].getBool()
    assert row["args"]["token"].getStr() == "***"
    assert row["args"]["x"].getInt() == 1
    assert row["output"].getStr() == "echo:hi"
    assert row["duration_ms"].getInt() == 4
    assert row["gen_ai.tool.call.id"].getStr() == "t1"
    assert row["gen_ai.operation.name"].getStr() == "execute_tool"
    assert not row.hasKey("call_id"), "the raw id leaves with the args"
    removeDir(home)

  test "servers come from mcp.json, tolerantly":
    let home = freshHome("waku-trace-servers")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "engram"}]}""")
    var t = newTracer(home, "openrouter", "m")
    assert t.servers == @["engram"]
    t.turn("hi")
    t.event("tool", %*{"tool": "engram_mem_search",
      "args": %*{"query": "x"}, "output": "none",
      "call_id": "t2", "duration_ms": 1})
    t.endTurn("yo", 1)
    let row = readLines(t.path)[1]
    assert row["source"].getStr() == "mcp:engram"
    removeDir(home)
