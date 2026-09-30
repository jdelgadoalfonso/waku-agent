# Waku Nim port (phase 4)

This folder holds the Nim port of Waku. The port will ship one binary that
reads and writes the same `.waku/` data as Python Waku. Phase 4 (session +
app + graph + CLI gateway) is landed; phases 5+ (integrations, MCP,
gateways, ops, evals) are not.

## Build and test

Nim 2.0 or newer is required. The package uses the standard library plus
`db_connector` (the stdlib `db_sqlite` successor, already installed — no
network), so `nimble build` and `nimble test` make no network calls.

```sh
cd nim
nimble build    # builds the waku binary
nimble test     # runs the offline phase 0 tests
```

## What is ported so far

- `waku.nimble` declares one package (stdlib plus `db_connector`).
- `src/config.nim` defines the `Settings` object (provider, apiKey, model,
  home) with `WAKU_PROVIDER`, `WAKU_API_KEY`, `WAKU_MODEL` and `WAKU_HOME` env overrides,
  a small `.env` line parser, and the cwd-walk loader (`findDotenv` /
  `loadDotenvFile` / `loadDotenv`): the `.env` is found upward from where you
  run, not where the binary lives. This ports `waku/config.py` `_load_env`.
- `src/providers.nim` parses the `providers.toml` registry subset and ports
  the `models_for` / `_belongs_elsewhere` / scoped-key resolution rules.
- `src/db.nim` ports `waku/db.py`: the full `state.db` schema (4 tables,
  FTS5 indexes, 5 sync triggers), `chat_log` migrations and `connect` with
  `busy_timeout=3000`. Requires `db_connector` (the stdlib `db_sqlite`
  successor, links the system SQLite).
- `src/memory.nim` ports the semantic/episodic stores: the `_fts_query`
  parity gate (32 ground-truth vectors from the live Python function) plus
  the `Fact`/`Episode` CRUD with identical SQL, limits and output formats.
- `src/wire.nim` bridges the loop's Anthropic-shape messages to OpenAI
  chat.completions (request build, response shaping, thought_signature
  echo, max_tokens retry rule).
- `src/sse.nim` reassembles both SSE dialects (OpenAI chunks, Anthropic
  events) into the loop's assembled shape.
- `src/loop.nim` is the agent loop (stream-then-fallback, tool execution,
  iteration limits) over a closure client seam.
- `src/http.nim` transports both wire formats over HTTP(S), streams SSE
  into the gates and wires into the loop seam.
- `src/tools.nim` ports the tool registry (`Tool`, `register`, `to_api`,
  `schemas`, `execute` with errors-as-text) plus JSON arg helpers.
- `src/calendar.nim` ports the local calendar paths: `create_event` (guard,
  +1h default, idempotence, SQLite + ICS) and the windowed local list.
- `src/notes.nim`, `src/messages.nim`, `src/memory_admin.nim` port the local
  tools: `save_note`, `send_message` (outbox drafts), `manage_memory`,
  `update_soul` (+ `SOUL.md` default) and `create_skill` (+ SKILL.md
  validation). Sync branches, web search and gateway tools are later phases.
- `src/session.nim` ports `runtime/session.py`: SOUL.md create-only-once,
  system-prompt assembly (soul + clock + model line + nil-able retrieval
  seams), `[tools used: ...]` folding, `start_new`/`switch` with the
  `history_turns` window.
- `src/app.nim` ports `app.py`: the `Waku` assembly, `respond` (capture +
  fail-open graph door + canonical-JSON meta), the bounded history window.
- `src/trace.nim` ports `ops/tracing.py` minus OTel: JSONL traces,
  `usage.jsonl` ledger, `compose` fanout.
- `src/jsondump.nim` renders `json.dumps`-shaped meta/ledger bytes and
  Python-`str()`-shaped tool args.
- `src/graph/` ports `graph/engine.py` + `graph/nodes.py` (waves, routers,
  guards, tool/llm/agent/fn nodes).
- `src/triage.nim` ports the triage workflow (fail-open classify, `.ics`
  reader, 5-node graph) plus the `graphTurn` app binder.
- `src/gather.nim` ports the gather workflow + ops binders (calendar,
  memory with its own connection, toolless synthesis, outbox draft) and
  `runGather`. GitHub/web stay honestly unavailable until phase 5.
- `src/brief.nim` ports `ops/brief.py` (`runBrief` → outbox txt).
- `src/client.nim` ports `get_client` (row lookup, key scoping, default
  models, endpoint resolution, helpful startup errors).
- `src/cli.nim` ports `gateway/cli.py` (REPL with `/memory`, read-only
  snapshot, live observer lines, `terminal` thread).
- `src/waku.nim` dispatches `chat` (default), `brief`, `gather`,
  `connections` and `skill install/export` for real; unknown commands
  exit 1 with the usage text.
- `src/skills.nim` ports `memory/procedural/installer.py` + `exporter.py`
  (phase 5a): `skill install` fetches + validates a SKILL.md and drops it
  into WAKU_HOME/skills (fetch injected, tests run offline); `skill export`
  copies the bundled + home skills into `.claude`/`.codex` under your home
  (or `--project`, `--force` replaces a copy that changed since).
- `tests/test_phase0.nim` tests the env overrides, the `.env` parser and the
  command table offline.

## What is not ported yet

The integrations catalog/pricing, full tool wiring (`build_registry` — the
registry takes injected tools until the remaining tools land), the memory
layer (gated retrieval, consolidation, MEMORY.md sync), MCP, the `connect`
flows, the chat gateways (telegram/discord/whatsapp/
voice), the dashboard, OTel spans, and the evals. The phase list with its
gates lives in
[docs/nim-port-design.md](../docs/nim-port-design.md).
