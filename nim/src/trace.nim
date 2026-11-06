## Trace — port of `waku/ops/tracing.py`: JSONL, the spend ledger, and OTLP
## spans. Three outputs from the same events (same contract as Python):
##
## 1. JSONL, always on (schema `v: 2`, spec 012): every turn appends
##    lines to `<home>/traces/<date>.jsonl` (`turn_start`, the loop's
##    events, `turn_end`). An `llm` line joins its turn and names its
##    cost; a `tool` line is the redacted v2 record. Records render with `$` (raw UTF-8), exactly like
##    Python's `ensure_ascii=False` — open the file and read.
## 2. The spend ledger `<home>/usage.jsonl`: one line per LLM call
##    (`{provider, model, kind, in, out}`) rendered with `jsonDumps`
##    (`ensure_ascii=True`), like Python's plain `json.dumps`.
## 3. OTLP spans, when `OTEL_EXPORTER_OTLP_ENDPOINT` names a collector:
##    the same events as a span tree any OTel backend can render. There is
##    no Nim OTel SDK and binding opentelemetry-cpp would break the
##    zero-dependency rule, so `otel.nim` is a hand-rolled exporter on
##    stdlib `httpclient` — one POST per turn, no SDK, no dependency. See
##    `odd/tasks/nim-otel-exporter.md`.
##
## The order inside each method is Python's and is part of the contract:
## the JSONL row is written FIRST and the span second (`event`), and the
## turn flushes after `turn_id` resets (`endTurn`), which is where
## Python's `force_flush` sits.
##
## The observer doubles as a loop Observer: `tracerEvent` goes anywhere an
## Observer goes. `text` (streaming token deltas) is for the live UI, never
## the trace, and never a span (Python returns from `event` before it
## reaches the SDK either).
## The legacy-GBK guard (old Windows releases) is skipped too:
## Linux-first port, documented.
##
## Timestamps match `datetime.now(UTC).isoformat(timespec="milliseconds")`
## byte for byte (`2026-09-29T20:19:36.396+00:00`); the trace filename uses
## the local date, like Python's `strftime('%Y-%m-%d')`.

import std/json
import std/os
import std/strutils
import std/sysrand
import std/times

import ./jsondump
import ./loop
import ./observe
import ./otel
import ./wire

export loop

type
  Tracer* = ref object
    home*: string
    provider*: string
    model*: string
    path*: string  ## today's trace file (fixed at construction, like Python)
    turnId*: string  ## current turn, "" outside one (reset by `endTurn`)
    silent*: bool
      ## A worker process sets this (slice 2b): the orchestrator owns the
      ## turn's JSONL and spend ledger, and a second writer would split
      ## one turn across two files. `event` then writes nothing at all —
      ## no row, no ledger row, no span; the turn markers come from
      ## `turn`/`endTurn`, which a worker never calls.
    servers*: seq[string]
      ## The `mcp.json` server names longest-first (read tolerantly at
      ## construction, like Python): what sorts a tool into `mcp:<server>`.
    otel*: SpanExporter
      ## The OTLP exporter, or nil when no endpoint is configured. Every
      ## call below is nil-safe, so an unconfigured port pays one branch
      ## per event and writes byte-identical JSONL.

proc mintTurnId*(): string =
  ## `t_<16 hex>` like Python's `"t_" + secrets.token_hex(8)`: one id
  ## joins a turn's rows across the trace and the ledger.
  result = "t_"
  for b in urandom(8):
    result.add(int(b).toHex(2).toLowerAscii())

proc utcStamp*(): string =
  ## `datetime.now(UTC).isoformat(timespec="milliseconds")`.
  format(now().utc, "yyyy-MM-dd'T'HH:mm:ss'.'fff'+00:00'")

proc newTracer*(home, provider, model: string,
               otelEndpoint = ""): Tracer =
  ## `otelEndpoint` is `Settings.otelEndpoint` (`OTEL_EXPORTER_OTLP_ENDPOINT`).
  ## It defaults to empty so every caller that does not want spans builds
  ## no exporter and the JSONL contract is untouched; an invalid endpoint is
  ## one stderr line from `newSpanExporter`, never an exception, because
  ## this runs while the agent is starting.
  Tracer(home: home, provider: provider, model: model,
         path: home / "traces" / format(now(), "yyyy-MM-dd") & ".jsonl",
         servers: mcpServerNames(home),
         otel: newSpanExporter(otelEndpoint))

proc writeLine(t: Tracer, line: string) =
  createDir(parentDir(t.path))
  var f: File
  discard open(f, t.path, fmAppend)
  f.writeLine(line)
  close(f)

proc writeRecord(t: Tracer, kind: string, ev: JsonNode) =
  ## `{"type": kind, **ev, "ts": now}` — `ts` lands last, like `_write`.
  var rec = %*{"type": kind}
  if ev.kind == JObject:
    for key, value in pairs(ev):
      rec[key] = copy(value)
  rec["ts"] = %utcStamp()
  t.writeLine($rec)

proc usageInt(ev: JsonNode, key: string): int =
  ## usage.get(key, 0): missing ledger numbers are 0, like Python.
  let v = ev.jget("usage").jget(key)
  if v.kind == JInt: int(v.getBiggestInt()) else: 0

proc recordUsage(t: Tracer, ev: JsonNode) =
  ## One LLM call's tokens append to the PERMANENT ledger (never wiped,
  ## unlike traces). Tokens are the ground truth; dollars derive from
  ## pricing, so only tokens + provider/model are stored. Every model
  ## call a turn makes lands here: the loop's own (`kind` "loop") and
  ## the side calls `meteredClient` reports with their own `kind` and
  ## model. Each row carries the turn's `turn_id`.
  let kindNode = ev.jget("kind")
  let modelNode = ev.jget("model")
  let rec = %*{"ts": utcStamp(), "provider": t.provider,
               "model": (if modelNode.kind == JString and
                 modelNode.getStr().len > 0: modelNode.getStr()
                 else: t.model),
               "kind": (if kindNode.kind == JString and
                 kindNode.getStr().len > 0: kindNode.getStr()
                 else: "loop"),
               "turn_id": t.turnId,
               "in": usageInt(ev, "in"), "out": usageInt(ev, "out")}
  createDir(t.home)
  var f: File
  discard open(f, t.home / "usage.jsonl", fmAppend)
  f.writeLine(jsonDumps(rec))
  close(f)

proc event*(t: Tracer, kind: string, ev: JsonNode) =
  ## The Observer: every loop step lands in the trace (and the ledger).
  ## A silent tracer returns first, before the ledger write and the
  ## span, so one writer per turn stays one writer.
  if t.silent:
    return
  if kind == "text":
    return
  var outp = ev
  if kind == "llm":
    t.recordUsage(ev)
    # stamp WHICH brain answered — a trace without the model is half
    # a trace in a multi-model world (shootouts, live switching)
    outp = %*{"provider": t.provider, "model": t.model}
    if ev.kind == JObject:
      for key, value in pairs(ev):
        outp[key] = copy(value)
    # Spec 012: join the call to its turn and say what it cost. The
    # stamp lands after the merge, so it wins — and the ledger above
    # already read the raw event, like Python records usage first.
    outp["turn_id"] = %t.turnId
    outp["cost_usd"] = %llmCost(t.provider, t.model, ev.jget("usage"))
    outp["span"] = %"llm"
    outp["gen_ai.operation.name"] = %"chat"
  elif kind == "tool":
    outp = traceRecord(ev, t.turnId, t.servers)
  t.writeRecord(kind, outp)
  # Python builds the span from the STAMPED event too (`event` is
  # reassigned before both `_write` and `start_as_current_span`), and from
  # the event rather than the record, so the span carries provider/model
  # and never `type`/`ts`. `outp` is exactly that payload.
  t.otel.event(kind, outp)

proc turn*(t: Tracer, userMessage: string) =
  ## One run opens with a `turn_start` marker (the root span in Python),
  ## carrying the fresh `turn_id` every row of the turn shares.
  t.turnId = mintTurnId()
  t.writeRecord("turn_start",
    %*{"turn_id": t.turnId, "user_message": userMessage})
  # After the row, like Python: `_write` runs before `start_as_current_span`.
  t.otel.turn(userMessage)

proc endTurn*(t: Tracer, reply: string, iterations: int) =
  ## ... and closes with `turn_end` (flushed per turn, so the trace
  ## survives even a killed process). The id resets, like Python.
  t.writeRecord("turn_end", %*{"turn_id": t.turnId, "reply": reply,
    "iterations": iterations})
  t.turnId = ""
  # Last, which is where Python's `end_turn` puts `force_flush(2000)`: the
  ## spans leave the process with the turn, and a collector that is down
  ## costs one stderr line rather than this turn.
  discard t.otel.endTurn()

proc tracerEvent*(t: Tracer): Observer =
  ## `tracer.event` as a closured Observer for `compose` and the loop.
  result = proc(kind: string, ev: JsonNode) = t.event(kind, ev)

proc compose*(observers: varargs[Observer]): Observer =
  ## Fan one loop event out to several observers (gateway display +
  ## tracer + capture). Nil observers are skipped, like Python's falsy.
  var active: seq[Observer] = @[]
  for o in observers:
    if not o.isNil:
      active.add(o)
  result = proc(kind: string, ev: JsonNode) =
    for o in active:
      o(kind, ev)
