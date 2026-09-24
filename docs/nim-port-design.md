# Nim port — system design (proposal)

Status: PROPOSED. No Nim code yet. This doc needs a maintainer yes before any
code lands under `nim/` (conventions §2: new top-level package + loop, memory,
graph and tool-contract changes).

Scope: a full 1:1 port of Waku into Nim, living in `nim/` beside `waku/`,
distributed as a single binary, fully compatible with existing runtime data.

## 1. What and why

Python Waku works but requires a Python install plus pip extras per gateway.
A Nim port produces one binary (`nim/waku`) with no interpreter, faster
startup and lower memory, while reading and writing the same `.waku/`
directory, `state.db`, `providers.toml` and CLI surface.

Non-goals for v1: no new features, no format migrations, no replacement of
`waku/` in the wheel. Python stays the source of truth until the Nim binary
passes the ported deterministic evals phase by phase.

## 2. Where the code goes

```
nim/
  README.md            # how to build (nimble), what is ported, what is not
  waku.nimble          # single package, no required deps beyond stdlib where possible
  src/
    config.nim         # Settings + .env cwd-walk (port of waku/config.py)
    providers.nim      # providers.toml parse + models_for/get_client shapes
    db.nim             # state.db schema, FTS5 triggers, migrations, PRAGMAs
    memory.nim         # facts/episodes, _fts_query, MEMORY.md, consolidation gate
    tools.nim          # registry + local tools (calendar SQLite+ICS, notes, messages)
    loop.nim           # Anthropic Messages + OpenAI-compat adapter, run_loop
    session.nim        # working memory assembly (SOUL.md, skills, history window)
    app.nim            # respond() wiring + CLI gateway
    graph.nim          # engine + triage/gather (after loop is stable)
    integrations.nim   # registry minus subprocess probes, catalog, pricing
    mcp.nim            # stdio + Streamable HTTP + OAuth DCR/PKCE (hand-rolled)
    gateway.nim        # telegram/discord/whatsapp/voice (voice likely external)
    ops.nim            # release_gate, arenas, dashboard routes (embed static/)
  tests/
    test_*.nim         # ported deterministic evals, one file per phase
```

`waku/` and `evals/` never import from `nim/`. `nim/` never imports from
`examples/` or `lab/`. Static assets under `waku/ops/static/` are embedded at
compile time (`include`/`staticRead`), never copied.

## 3. Compatibility contract (must not drift)

- `state.db`: tables `calendar_events`, `facts` + `facts_fts`, `episodes` +
  `episodes_fts`, `chat_log` with `session_id/source/meta`; sync triggers;
  `busy_timeout=3000`, `row_factory` row semantics.
- `_fts_query`: unicode61, tokens `[^\W_]{2,}` lowercased, `OR`-joined,
  CJK/hiragana `token*` prefixes, empty → `recent()`; BM25 rank.
- Append-only files never wiped: `usage.jsonl`
  (`{provider,model,kind,in,out}`), `traces/<date>.jsonl`, `outbox/`,
  `calendar.ics` append, `SOUL.md` (8000-char cap), `MEMORY.md`,
  `mcp.json`, `mcp-auth/`, `token.json`/`credentials.json`, `models.json`,
  `connections_health.json` (atomic tmp+replace).
- `providers.toml`: 12 rows, 14 base + 7 opt-in fields; model-resolution rules
  (`_belongs_elsewhere`, hosted never falls back to `WAKU_API_KEY`).
- CLI: `chat, dashboard, connections, connect, mcp, voice, telegram, discord,
  whatsapp, brief, gather, skill install/export` with the same exit codes.
- Env: full `Settings` list plus per-provider keys and `WAKU_*`.

## 4. Phases with gates (from scout mufmke6t-1-w241)

0. Skeleton + config + providers — offline testable, no network.
1. SQLite + memory — GATE: FTS5 tokenizer+rank parity proven before building on it.
2. Tool registry + local tools — no network.
3. HTTP + wire formats + loop — GATE: SSE streaming + tool-call reassembly on
   both wire formats (incl. `thought_signature` echo, max_tokens fallback).
4. Session + app + graph + CLI gateway.
5. Integrations + catalog + pricing.
6. MCP (hand-rolled, both transports + OAuth loopback 41765).
7. Gateways — voice ships only as external helper if it breaks single-binary.
8. Ops + dashboard (embed fonts/design copies, respect LICENSE-BRAND).
9. Evals + packaging — port deterministic tests per phase, not at the end;
   judge evals stay Python-optional.

## 5. Risks

1. SSE + reassembly divergence across providers.
2. FTS5 binding semantics in Nim.
3. Hand-rolled OAuth (Google loopback, MCP DCR/PKCE).
4. Audio stack vs single binary.
5. No Nim SDK for MCP/Telegram/Discord; websocket + HMAC webhook by hand.
6. `rich` → plain ANSI; threaded server → async event loop (keep SSE contract).
7. Double maintenance until one implementation is retired.

## 6. Testing

Each phase ports its deterministic evals with the same scripted-client seam
(`Waku(settings, client, conn)` injection → Nim equivalent). `nimble test`
must be green before the next phase starts. `make gate`/`make lint` keep
running the Python suite; the Nim gate is additive, never a replacement, until
parity is declared in this doc.

## 7. Open decisions (need maintainer yes)

1. `nim/` in this repo (proposed) vs separate repo — user chose `nim/`.
2. Voice scope for v1: external helper vs out of scope.
3. Which Nim SQLite/HTTP libs are allowed without violating "no new default
   dependency" spirit (stdlib first, nimble only where stdlib cannot do it).
