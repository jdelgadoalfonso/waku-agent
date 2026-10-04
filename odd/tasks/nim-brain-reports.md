# Nim port — research brain + reports (spec 007, 009 A/B)

## Header
Proposal `docs/proposals/nim-brain-reports.md` (maintainer yes, 2026-10-04).
Two units in order, one work-unit commit each, no push.

## Specs
- S1: backend seam (search/remember/connected) built from MCP bridge exchanges; nil = off.
- S2: read path — skill-gated pre-loop searches, tool events, context block, Used list (fills memory.used).
- S3: write path — MARKER find, company classifier (metered), remember whole, short reply, report event + meta.report.
- S4: receipt regains memory.report; turn_events learns report; consolidation caps at 2 with body.
- S5 (non-goals): hosted backend, Jev, SKILL rewrite, matching/loop/prompt/frontend changes.

## Tasks
- [x] T1 (S1, S2): backend seam + read path — Engram-first via registry
  tools (no bridge changes); scorer compartido sin cambio de conducta;
  receipt mapea engram_mem_search. Suite 1102 OK, cero warnings.
- [x] T2 (S3, S4): write path + receipt key + cap — reports.nim (find /
  chatReply / isCompanyResearch fail-closed / saveReport), meta.report,
  receipt memory.report de vuelta, cap 009 B en consolidateIfDue vía
  reportCell (un closure no puede capturar un var Waku). Suite 1114 OK.
  Divergencias: scopes de Engram en vez de project:Company brain; kind
  semantic -> type discovery; sin read_first para reports.
  L2: verificacion viva (build wakuTls + Engram real) encontró TRES bugs que
  los fakes offline no veían: (1) toRegistryTools compartía el binding del
  bucle, así que TODA herramienta MCP llamaba a la última del listado
  (mem_search pedía mem_update) — ahora un proc por tool; (2) brainEntries
  recibía el sobre JSON de Engram entero con los newlines escapados → 0 hits;
  ahora acepta entries (Waku Memory) y envelope-result (Engram); (3) el id
  que devuelve Engram es numérico. Suite 1119 OK. La escritura completa con
  modelo queda pendiente de cuota free (429 upstream).

## Log
- L1: user "vamos a hacer brain/reports" → investigation → proposal nim-brain-reports.md → user "ok" (company-project mapping as proposed).
