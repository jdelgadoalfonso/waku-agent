# Nim port — full 1:1, single binary, full compat

## Decisions (user)
- Scope: port completo 1:1 (197 archivos Python, ~13.6k LOC waku/ + evals + dashboard + gateways)
- Goal: binario único sin Python
- Compat: total (.waku/, state.db, CLI, providers.toml)

## Process requirement
- Tier Proposal per conventions §2 (loop, memory, graph, tool contract). Needs design doc in docs/ + maintainer yes before code.
- Open: dónde vive el código Nim (nim/ nuevo vs repo separado) para no romper wheel PyPI.

## Compatibility surface (from scout mufmke6t-1-w241)
- .waku/state.db schema + FTS5 triggers + migraciones, PRAGMAs busy_timeout=3000
- _fts_query semantics: unicode61, tokens [^\W_]{2,}, OR, prefijos CJK*, BM25
- usage.jsonl, traces/, outbox/, calendar.ics, SOUL.md (cap 8000), MEMORY.md, mcp.json, mcp-auth/, token.json/credentials.json, models.json, connections_health.json
- providers.toml: 12 rows, 14 base + 7 opt-in fields
- CLI: chat, dashboard, connections, connect, mcp, voice, telegram, discord, whatsapp, brief, gather, skill install/export
- Env: Settings completos + per-provider keys + WAKU_* (ver mapa completo en resultado del scout)

## Phases
0. Skeleton + config + providers (offline testeable)
1. SQLite + memory (riesgo FTS5 — validar primero)
2. Tool registry + local tools (calendar SQLite+ICS, notes, messages)
3. HTTP + wire formats + loop (riesgo SSE + tool-call reassembly)
4. Session + app + graph + CLI gateway
5. Integrations + catalog + pricing
6. MCP stdio+HTTP+OAuth (sin SDK Nim — hand-rolled)
7. Gateways (telegram/discord/whatsapp/voice; riesgo audio vs binario único)
8. Ops + dashboard (embed assets en compilación)
9. Evals + packaging (portear 81 tests deterministas por fase, no al final)

## Risks ranked
1. SSE/streaming + reassembly ambos wire formats
2. FTS5 unicode61/BM25 exacto en binding Nim
3. OAuth Google loopback + MCP DCR/PKCE 41765
4. Audio faster-whisper/kokoro vs single binary
5. MCP sin SDK, rich→ANSI, threading→event loop, discord WS + WA HMAC

## Landed
- Phase 0 skeleton: c3444cf on feature/nim-phase0-skeleton (nimble package, config.nim, CLI skeleton, 6 offline tests green; verifier accept-with-notes, notes fixed).
- Task-file + docs bookkeeping: 51cfa32.
- Providers + dotenv + connections (phase 0b/0c): 86c843b, 290fbd7.
- Phase 1a state.db (db.nim, schema/triggers/migrations): 6800bb6.
- Phase 1b FTS parity gate (ftsQuery + 32 vectors): d7595bd.
- Phase 1c facts/episodes CRUD (memory.nim stores + 9 tests): 9bde10a→4238db6 (amended with task note).
- Phase 2a registry (tools.nim + 5 tests): a45c0bd.
- Phase 2b local calendar (calendar.nim + 7 tests): cd32a8b.
- Phase 2c local tools (notes/messages/memory_admin + 6 suites): de0768e.
- Next: phase 3 (HTTP + wire formats + loop, behind the SSE/reassembly gate).
- Phase 3a wire bridge (wire.nim + 9 tests): 989c93e.
- Phase 3b OpenAI SSE gate (feedOpenAi/finalOpenAi + 5 tests): df3b026.
- Phase 3c Anthropic SSE gate (feedAnthropic/finalAnthropic + 5 tests): 607aea5.
- Phase 3d agent loop (loop.nim + scripted seam, 7 tests): e641307.
- Phase 3e HTTP transport (http.nim + localhost stub, 7 tests): 683d298.
- Next: phase 4 (session + app + graph + CLI gateway).
- Phase 4a graph engine+nodes (graph/engine.nim, graph/nodes.nim + 27 tests): 188592f (verifier accept-with-notes, 4 notes fixed: _-key filter + test, deep-copy doc, 3 robustness tests, unknown-jump doc).
- Phase 4b session assembly (session.nim + config/memory extensions + 15 tests): f6d02f2 (verifier accept-with-notes, 8 notes fixed: locale doc, turns=0 test, config/envInt tests, multi-fold test, model-tail test, RetrieveFn notify, default consts, meta-render doc).
- Phase 4c app respond (app/trace/jsondump + 18 tests): ff86ed2 (verifier accept-with-notes, 7 notes fixed: test count, triage_reason "", utcStamp test, astral test, flag-on-no-seam test, afterTurn test, errorText-vs-repr doc).
- Phase 4d workflows+ops (triage/gather/brief + 26 tests): 3763c4e (verifier first REJECTED on RangeDefect crash with truncated '{'; fixed with b<a guard + regression test + 5 minor notes; re-verify subagent errored, blocker re-verified inline with a crash-shape probe + full suite).
- Phase 4e CLI dispatch (cli/client/waku dispatch + 10 tests): f78a0a1 (verifier accept-with-notes, 6 notes fixed; README refreshed per rule 9).
- PHASE 4 COMPLETE (session + app + graph + CLI gateway): 188592f, f6d02f2, ff86ed2, 3763c4e, f78a0a1 — suite 185 OK green, zero warnings. Stubs left for phases 5-8 (dashboard, connect, mcp, voice, telegram, discord, whatsapp); skill install/export has no explicit phase in the design doc — deferred, needs anchoring.
- Anchored: Phase 5a skill install/export (installer.py 47 líneas: fetch 15s + _parse + WAKU_HOME/skills/<name>/SKILL.md vía _incoming; exporter.py 108 líneas: TARGETS claude/codex, skip roots+_incoming, copytree con --to/--project/--force; reusa validSkillText de phase 2c + http.nim de phase 3; Tier Short Plan, no Proposal).
- Next: phase 5 (integrations + catalog + pricing, empezando por 5a skill distribution).
- Phase 5a skill distribution landed (skills.nim + waku.nim dispatch + 19 tests): ba1a14b, df659c6, ec28531 — suite 204 OK, cero warnings.
- Phase 5b pricing landed (pricing.nim + provider price lists + 16 tests): 4d20c5e
  (verifier accept-with-notes, 7 notes: 2 fixed — empty-provider parity,
  int-literal price test — 5 recorded as deliberate robustness deltas).
  Suite 220 OK, cero warnings.
- Phase 5c catalog landed (catalog.nim + 24 tests): c7ea28e
  (verifier accept-with-notes, 7 notes: 2 coverage tests added — pinless
  file keeps empty choice, global base URL never leaks into scoped rows —
  5 recorded as deliberate divergences). Suite 244 OK, cero warnings.
- Next: phase 5d integrations registry.

## Next
- Escribir docs/proposals/nim-port.md y pedir yes antes de fase 0.
