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
- Next unit: providers.nim + dotenv cwd-walk + full dispatch (providers.nim
  landed as 86c843b; phase 0c dotenv + connections implemented, verifier
  accept-with-notes, notes fixed — ready to commit).

## Next
- Escribir docs/proposals/nim-port.md y pedir yes antes de fase 0.
