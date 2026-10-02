# Waku Nim port

This folder holds the Nim port of Waku. The port will ship one binary that
reads and writes the same `.waku/` data as Python Waku. Landed: phases 0-5
(skeleton, SQLite + memory, wire + loop + HTTP, session/app/graph/CLI,
integrations + catalog + pricing + skills), phase 6 (MCP: config, stdio,
streamable HTTP, OAuth browser flow in the binary, and a synchronous bridge
that connects the servers one at a time and waits out the connection
deadline), phase 7a-7c, 7d1 and 7d2-1/7d2-2 (gateways: the
runner/supervisor policy, telegram, discord, whatsapp, voice, plus the live
loops for telegram/whatsapp/voice, the external voice engines, the Discord
gateway WebSocket receive and the four `waku telegram|discord|whatsapp|voice`
dispatches, 7d2-3/7d2-4 (the dashboard gateway supervisor and the
deferred hardening), 9a (packaging), 9b (repo-gate meta-evals) and 9c
(black-box cross-check)), live TLS behind the `-d:wakuTls` switch (one
`SslContext` for every live client, and a real `wss://gateway.discord.gg`
dial in a build that asks for it) and phase 8 (ops + dashboard: the server
loop, the routes, the model arena and the memory/judgment arena). Not landed
yet: OTel spans.

## Build and test

Nim 2.0 or newer is required. The package uses the standard library plus
`db_connector` (the stdlib `db_sqlite` successor, already installed — no
network), so `nimble build` and `nimble test` make no network calls.

```sh
cd nim
nimble build    # builds the waku binary
nimble test     # compiles and runs every tests/test_*.nim suite
```

## Live TLS is a build switch, not a default

The default build talks to nothing. Compiled without a flag, every
`https://` call raises `HttpRequestError("SSL support is not available…")`
inside `newConnection`, before a socket is opened, so an API key cannot
leave in the clear. Two switches turn the encrypted paths on, and both are
needed:

```sh
cd nim
nimble buildTls    # -d:ssl -d:wakuTls -> ./waku_tls (needs libssl-dev)
nimble testTls     # the same two switches, running tests/test_tls.nim
```

From the repo root those are `make nim-build-tls` and `make nim-test-tls`,
which `cd nim` first like the other targets. `-d:ssl` is the compiler's own
switch and links the system libssl; `-d:wakuTls` is the port's, and it is
what attaches the one `std/net.SslContext` (`CVerifyPeer`, built once per
process) to every live client and lets `liveDiscordWire` dial
`wss://gateway.discord.gg`. One switch alone degrades to the default build
rather than compiling something half-encrypted. Nothing is added to
`requires`: `std/net` plus `wrappers/openssl` are stdlib and libssl is the
system's, so rule 3 holds. The switches are typed once, in
`waku.nimble`; the Makefile and the `nim-tls` CI job both call the tasks
rather than repeating a compiler line, and the CI job installs `libssl-dev`
where the default job does not need it.

The default build's behaviour is unchanged, refusals included: the `wss://`
dial still answers `discordTlsMissingLine`, and the pin for it in
`tests/test_discord_ws.nim` is a pin about the default build.

`nimble test` is declared in `waku.nimble` rather than left to auto-discovery:
it runs the suites in order and stops at the first failure, so the contract
lives in the manifest a reader opens. That same file holds the version, which
`src/waku.nim` reads at compile time — one edit moves `waku --version` and
nimble together, and a build needs the checkout for it, the one the embedded
dashboard assets need anyway. From the repo root, `make nim-build` and
`make nim-test` are those same two commands (they `cd nim` first, because the
suite's pins read the checkout relative to the working directory).

## The dashboard frontend is inside the binary

`src/dashboard.nim` freezes `waku/ops/static/` into the executable at
compile time (`staticRead`, 55 files, ~668 KB, the `.woff2` fonts
included — bytes, not text). Nothing is copied into `nim/`, nothing under
`design/` is touched (AGENTS.md rule 8), and LICENSE-BRAND still holds:
those files are included unmodified, so they reach the binary exactly as
they sit in the checkout.

Two rules fall out of that:

- **Build from a checkout.** The walk reads the tree beside
  `nim/src/dashboard.nim`, so the compiler needs it there.
- **Run from anywhere.** `nim/waku dashboard` serves the SPA and
  `/static/...` with no checkout on disk — that is what a shipped binary
  has. `tests/test_embed.nim` pins every embedded byte against the
  checkout, so a stale embed (an asset added and not rebuilt) fails the
  suite instead of 404ing in a browser.

A run that DOES find a checkout (`waku/ops/static` in the working
directory, or `static/` beside the binary) keeps serving it from disk, so
frontend edits need no rebuild and behave exactly like Python. Compiling
with no checkout present is not an error: the embed comes out empty and
the SPA routes answer with the same missing-frontend 404 Python gives.

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
  into the gates and wires into the loop seam. It also holds the port's
  ONE TLS helper (`tlsActive`, `tlsContext`, `newTlsHttpClient`,
  `newTlsAsyncHttpClient`): every live client in `src/` is built there, so
  a build with `-d:wakuTls` cannot leave a context-less one behind.
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
  `connections`, `skill install/export` and the four gateway commands for
  real; unknown commands exit 1 with the usage text, and `connect` is the
  one command still reporting phase scaffolding.
- `src/skills.nim` ports `memory/procedural/installer.py` + `exporter.py`
  (phase 5a): `skill install` fetches + validates a SKILL.md and drops it
  into WAKU_HOME/skills (fetch injected, tests run offline); `skill export`
  copies the bundled + home skills into `.claude`/`.codex` under your home
  (or `--project`, `--force` replaces a copy that changed since).
- `src/pricing.nim` ports `ops/pricing.py` (phase 5b): `MODEL_PRICING`
  (15 rates), `MODEL_CUTOFF` ("" = unpublished), `priceFor` (catalog cache
  > `:free` > model > provider row > 3.0/15.0), `rememberPrice` and
  `usageSummary` over `usage.jsonl` (repriced at read, bad lines skipped).
  Provider `price` lists are parsed in `providers.nim`, so the estimate
  stays single-sourced like Python's registry-derived `PRICING`.
- `src/catalog.nim` ports `ops/catalog.py` (phase 5c): `listModels`
  (provider resolution, catalog URL rules, 300 s / ~60 s caches, latin-1
  key guard, entry parsing with `rememberPrice`, free-first sort,
  known-default fallback) with an injected fetch and an explicit clock
  seam, plus the `models.json` shortlist (`pinnedSpecs`,
  `defaultModelFor`, `savePinned`). No live HTTP yet; wiring to a real
  client comes with a later phase. Regional endpoint pairing is skipped
  (the registry parser ignores `[[array]]` tables).
- `src/gateway.nim` ports `gateway/runner.py` + `gateway/supervisor.py`
  (phases 7a, 7d1): `safeException` (credential redaction), `RunnerState`
  plus `accountedRespond` (the `_respond` accounting), `runGatewayTurn`
  and the whole `GatewaySupervisor` (fingerprint, configured-check,
  reconcile with stop-then-start and rollback, shutdown, status) with
  every side effect injected.
- `src/telegram.nim` ports `gateway/telegram.py` (7a, 7d1): the allowlist
  gate, the startup posture, the hand-rolled Bot API wire, and the live
  long-poll with its retry/conflict/dead-token policy plus the handle the
  supervisor stops and reads.
- `src/discord.nim` ports `gateway/discord.py` (7b, 7d2): the
  deny-by-default access policy, mention stripping, the hourly turn budget,
  the posture, the REST send seam, and the gateway WebSocket receive
  (RFC 6455 handshake, frames, masking, heartbeat, op 2/10 and
  `MESSAGE_CREATE`) behind `receiveDiscordEvent`, plus the dial seam and
  the `waku discord` command loop. The encrypted dial (live TLS) is a three-rung
  ladder that opens a real TLS socket under `-d:wakuTls` and refuses, with
  `discordTlsMissingLine`, without it.
- `src/waku.nim` dispatches the four gateway commands (7d2): `telegram`
  → `telegramRun`, `discord` → `discordServe`, `whatsapp` → `serveWhatsapp`
  (its own listener, `take = nil`), `voice` → `voiceMain`, each over one
  real agent with its own session thread and an injected terminal mirror
  (`LogFn`).
- `src/whatsapp.nim` ports `gateway/whatsapp.py` (7b, 7d1): the HMAC
  signature gate (over `mcp.nim`'s SHA-256), the verification challenge,
  the payload walk, the Graph API send, and the live webhook door — decide,
  answer 200 fast, then run the turns — with the accept loop and the
  handle.
- `src/voice.nim` ports `gateway/voice.py` (7c, 7d1): what gets voiced,
  the wake word (with a real `difflib.SequenceMatcher` port), the mic
  threshold, the two command state machines, one spoken turn, the
  always-listening loop, push-to-talk and the `waku voice` command.
- `src/voiceio.nim` is the part Python gets from `pip install
  'waku-agent[voice]'` and this binary cannot ship: the s16le decode, the
  WAV writer, and the recorder spool behind `WAKU_MIC_COMMAND` /
  `WAKU_STT_COMMAND` / `WAKU_TTS_COMMAND`. A missing engine is named in
  one line and the command exits 1.
- `src/integrations.nim` ports `integrations.py` (phases 5d1+5d2):
  the 13 static rows, provider-derived registry, status machine, views
  and the env-example block, with env/hostOs/health/gateway injected,
  plus the health store, injected probes, dotenv apply with rollback,
  provider save/disable and the plain-text `cliMain` behind the
  `connections` dispatch. No pip-extra check (single binary) and no
  regional Base URL field (no `[[array]]` parsing).
- `tests/test_phase0.nim` tests the env overrides, the `.env` parser and the
  command table offline.
- `tests/test_tls.nim` pins the conditional TLS contract in BOTH build
  modes: the refusals the default build owes its callers, the context and
  the recorded RFC 6455 handshake the flagged build gets, and the scan
  that says no module builds an HTTP client behind the helper's back.

## What is not ported yet

Full tool wiring (`build_registry` — the
registry takes injected tools until the remaining tools land), the memory
layer (gated retrieval, consolidation, MEMORY.md sync), the `connect`
flows, the dashboard gateway supervisor (7d2-3, so `waku dashboard` still
reports each gateway instead of running it), OTel spans, and the evals. The
phase list with its
gates lives in
[docs/nim-port-design.md](../docs/nim-port-design.md).
