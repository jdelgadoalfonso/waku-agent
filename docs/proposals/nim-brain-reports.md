# Nim port: research brain + reports (spec 007, 009 A/B)

Status: **proposed** — needs the maintainer's yes before any code
(conventions §2, Proposal tier: new memory-interface seams across
`app`/`session`/`tools`/MCP, a new skill-driven turn behavior, and a
new receipt key).

Python precedent: `waku/memory/brain.py` (spec 009 A),
`waku/memory/reports.py` (spec 007), `skills/research-report/SKILL.md`.

## 1. Problem

A research turn in the port starts from nothing: no earlier-report
lookup before the loop, no report saved after it. The frontend already
draws report cards (`render.js`, shared) and the receipt already
reserves no `report` key — both wait on data the binary never
produces.

## 2. Backend: Engram, not hosted memory

Python reads and writes Waku Memory (hosted). The port's hosted
backends are honest errors by decision, so a faithful port would be
dead code. The live alternative is already wired: Engram over MCP
(`engram mcp`, 19 tools, proven against this binary).

Design, mirroring Python's transport-agnostic seams (`search_via` /
`remember` callables injected into `app`, never the transport):

- A `BrainBackend` seam on the agent: `search(args): string` and
  `remember(title, body, scope): bool`, plus `connected: bool`. Built
  from the MCP bridge exchanges when a memory server (`engram` first,
  `waku_memory` later by the same shape) is configured, nil otherwise
  — nil means the whole feature is off, fail-open, exactly like
  Python with no Waku Memory.
- Scope mapping (maintainer yes, as implemented): Engram's scopes are
  project/personal/global, so the same two-way split Python makes with
  `COMPANY_PROJECT` maps as `global` for company research (shared
  knowledge about the world, readable by every agent) and `personal`
  for reports about the person; a read with no scope filter is
  Python's "all". Engram's `type: discovery` stands in for Waku
  Memory's `kind: semantic`. Nothing leaves the machine either way.

## 3. Port plan (two units, in order)

1. **Read path (009 A).** In `runFullTurn` before the loop: when the
   backend exists and the matched skills name `research-report`
   (`matchingSkills` already matches by keyword), run the two
   searches (subject everywhere + earlier reports), notify each as a
   `tool` event, append the "what the brain already knows" block to
   the system prompt, and keep the Used list — which also fills
   `memory.used`, honestly counted at last. A failed search is
   skipped, never fatal. Meter the classifier-free calls as today
   (plain reads, no new model calls on this path).
2. **Write path (007 + 009 B).** After the loop: `find` the
   `<!-- waku-report v1 -->` marker; `is_company_research` via one
   metered small-model call (new `report` kind, fail-closed to
   personal so nothing lands in the shared project by mistake);
   `remember` it whole and shorten the chat reply; notify the
   `report` event and put it on `meta.report` for the card. The
   receipt regains its `memory.report` key (dropped in T2 for having
   no emitter — it has one now) and `turn_events` learns `report`.
   Consolidation caps at two facts when a report body arrived (009 B)
   via a `reportBody` parameter (default empty: every existing caller
   compiles unchanged).

## 4. Non-goals (explicit)

- Hosted Waku Memory as a backend (same seams would carry it later).
- Jev slot gate (separate opt-in, separate proposal if ever).
- Rewriting `SKILL.md` (shared file; the generated brain block names
  the real backend, the skill text stays as-is).
- Changing skill matching, the loop, prompts, or any frontend file.
- New model calls except the one company/personal classifier, which
  Python also makes.

## 5. Verification

- `nimble test` green, zero warnings.
- Offline suites with a stub backend (nil backend does nothing;
  stubbed searches shape the Used list, the block and the tool
  events; a MARKER reply shortens and emits; classifier-false files
  personal; consolidation caps at two with a report body).
- Live (needs `engram` in `mcp.json`, already this machine's setup):
  one research turn shows earlier hits in context, one report turn
  saves and draws its card; the receipt carries `memory.report`.

## 6. Decision needed

Maintainer yes/no on §2 (Engram-first, company-project mapping) and
§3 as scoped. A yes authorizes units 1–2 in that order, one
work-unit commit each, no push. Anything in §4 reopens this doc.
