# Waku Nim port (phase 0)

This folder holds the Nim port of Waku. The port will ship one binary that
reads and writes the same `.waku/` data as Python Waku. Phase 0 is the
skeleton: the package builds, the config module loads, and the CLI entry
point lists the commands the port will implement.

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
- `src/tools.nim` ports the tool registry (`Tool`, `register`, `to_api`,
  `schemas`, `execute` with errors-as-text) plus JSON arg helpers.
- `src/calendar.nim` ports the local calendar paths: `create_event` (guard,
  +1h default, idempotence, SQLite + ICS) and the windowed local list.
- `src/notes.nim`, `src/messages.nim`, `src/memory_admin.nim` port the local
  tools: `save_note`, `send_message` (outbox drafts), `manage_memory`,
  `update_soul` (+ `SOUL.md` default) and `create_skill` (+ SKILL.md
  validation). Sync branches, web search and gateway tools are later phases.
- `src/waku.nim` loads the `.env` before dispatch and implements the real
  `connections` output: one line per visible provider (`configured` vs
  `missing key (set VAR)`), no network probes. Every other command still
  prints the not-yet-implemented reason to stderr and exits 0.
- `tests/test_phase0.nim` tests the env overrides, the `.env` parser and the
  command table offline.

## What is not ported yet

The tool registry, the Anthropic and OpenAI loop,
the session assembly, the integrations catalog, MCP, the chat gateways, the
dashboard and the evals. The phase list with its gates lives in
[docs/nim-port-design.md](../docs/nim-port-design.md).
