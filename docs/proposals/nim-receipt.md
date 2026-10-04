# Nim port: turn receipts (spec 011 group A)

Status: **proposed** — needs the maintainer's yes before any code
(conventions §2, Proposal tier: it changes the loop's accounting, the
trace event contract and the turns repricing the dashboard reads).

Python precedent: `dbd36d7` ("Show what each turn did and cost",
spec 011 group A) + `evals/deterministic/test_turn_receipt.py`.
This doc mirrors that change into the port, nothing more.

## 1. Problem

The dashboard's cost line undercounts every turn: the spend it shows
counts only the loop's own calls. The retrieval gate, consolidation,
the triage router (and the arena judge) each call the small model and
reach no ledger, so a turn that retrieved + consolidated + triaged
reports a fraction of what it spent. The chat footer has no per-turn
tokens or dollars at all. Python fixed exactly this; the port still
has the bug.

## 2. What Python did (the spec to mirror)

- **A1 — `turn_id`**: `Tracer.turn` mints `t_<hex>` and writes it on
  `turn_start`, `turn_end`, every `usage.jsonl` row and the chat log's
  `meta`. One id joins a turn's rows across files.
- **A2 — `metered()`**: side LLM calls (gate, consolidation, report,
  triage, quick reply) report as `llm` events carrying `kind` + model,
  so they land in `usage.jsonl` and the trace like the loop's own.
- **A3 — `receipt.py`**: `build()` makes the receipt once from the
  turn's events (every `llm` event, every `tool` event, the kept facts,
  the report). Key sets are pinned (`KEYS`, `MODEL_KEYS`, `TOOL_KEYS`,
  `MEMORY_KEYS`, … — a new field is a deliberate change). Privacy is
  structural: named fields copied into new objects, every string
  checked against short patterns — never text, args, outputs or keys.
- The `done` payload carries it as `receipt`, the chat log keeps it in
  `meta.receipt`, the tracer writes one `receipt` event, and the
  footer draws one line (`render.js`, already shared — the port serves
  the same files, so no frontend work).

## 3. Port plan (three units, in order)

1. **Trace + metered.** `trace.nim`: `turn` mints `turn_id`, written
   on `turn_start`/`turn_end`/usage rows. A `metered` seam wraps the
   port's side calls (gate + consolidation in `memory_live.nim`,
   triage in `graph/`, the arena judge in `arena_live.nim`) reporting
   `llm` events with `kind` + model through the existing observer —
   injected, so offline tests replay without a key. Touches the loop's
   accounting but changes no tool semantics and no prompt.
2. **`receipt.nim`.** Pure builder repulsion: the pinned key sets, the
   id/name/provider patterns, estimate-only dollars via `priceFor`.
   No hosted `charges` passthrough (estimate, labelled `est` — the
   metering proxy stays Python-side). Unit tests mirror
   `test_turn_receipt.py`'s pinned sets, including a hostile-input
   case (tool output echoing a fake key must not leak into a receipt).
3. **Surfacing.** `app` writes `meta.receipt` + the `receipt` trace
   event; `turnSection` prefers the recorded receipt and reprices the
   same way (single-threaded, same `priceFor`). The turns payload
   gains `receipt`; the footer draws itself — no JS change.

## 4. Non-goals (explicit)

- Hosted exact charges/credits (estimate only, like Python local).
- Frontend changes (shared files, already updated by `dbd36d7`).
- Research brain/reports (blocked on hosted Waku Memory in Nim).
- New model calls anywhere: metering wraps calls that already happen.
- Changing what any tool does, or any prompt text.

## 5. Verification

- `nimble test` green, zero warnings (repo gate).
- New suites: metered-offline (gate/consolidation/triage/judge emit
  `llm` rows with `kind`), receipt key-set pins + hostile-input pin,
  turns-prefer-recorded-receipt pin.
- Live (needs a key): one turn with retrieval + consolidation shows
  gate+loop dollars in the footer; `test_turn_receipt.py` stays the
  Python-side oracle — same shapes, asserted in both languages.

## 6. Decision needed

Maintainer yes/no on §3–§4 as scoped. A yes authorizes units 1–3 in
that order, one work-unit commit each, no push. Anything in §4 reopens
this doc first.
