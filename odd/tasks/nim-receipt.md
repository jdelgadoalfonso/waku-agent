# Nim port — turn receipts (spec 011 group A)

## Header
Proposal `docs/proposals/nim-receipt.md` (maintainer yes, 2026-10-04).
Three units in order, one work-unit commit each, no push.

## Specs
- S1: `turn_id` (`t_<hex>`) on `turn_start`, `turn_end`, usage rows, chat meta (mirror of Python A1).
- S2: side calls (gate, consolidation, triage, arena judge) report `llm` events with `kind` + model via injected seams, offline-testable (mirror of A2 `metered()`).
- S3: pure `receipt.nim` builder with pinned key sets + structural privacy, estimate-only dollars (mirror of A3).
- S4: `meta.receipt` + `receipt` trace event + `turnSection` prefers recorded receipt (surfacing).
- S5 (non-goals): no hosted charges, no frontend changes, no brain/reports, no new model calls, no tool/prompt changes.

## Tasks
- [x] T1 (S1, S2): trace turn_id + metered seams — 1072 OK, cero warnings.
  L2: judge queda con notify=nil en el seam vivo (el grading de arena
  emite por SSE fuera de todo tracer); meteredClient + gate/consolidation/
  triage/quick cableados al observer del turno.
- [x] T2 (S3): receipt.nim builder + pins — worker-built, parent review
  found the input shape wrong ("type" field vs oracle's (kind, ev)
  pairs); corrected before commit. Judge con notify=nil (ver T1 L2).
- [x] T3 (S4): surfacing in app/turnSection — worker-built, parent review
  found stale-rowid (last_insert_rowid read after afterTurn; a due
  consolidation moved it onto the fact row) — hoisted to right after
  addExchange + regression pin. donePayload without receipt: follow-up.

## Log
- L1: user "si" x2 → write receipt proposal; user "ok" → maintainer yes, authorized units 1-3.
