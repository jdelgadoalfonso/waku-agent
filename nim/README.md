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
loop, the routes, the model arena, the memory/judgment arena and the `graph`
block in `/api/data` — flag, engine-drawn topologies, runs and quick/full
stats from the trace events — plus `turns`/`stats` and the rest of the
`collect()` blob the tabs read (state.db rows, db introspection, skills,
tools, settings, providers, eval report, inline trace sections), and OTLP
span export (`OTEL_EXPORTER_OTLP_ENDPOINT` -> `src/otel.nim`, one POST per
turn, hand-rolled protobuf, no SDK).

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

## Facts can live in mem0 instead of sqlite

Nothing to do by default: facts go to `state.db`, keyword search and all. Name
a hosted backend and the same seven operations go over REST instead — the
retrieval gate, the consolidation and `manage_memory` all read and write
whichever store answered, and the dashboard's memory page shows the same ones.

    export WAKU_SEMANTIC_STORE=mem0
    export MEM0_API_KEY=m0-...        # required; without it, sqlite + a line
    export MEM0_USER_ID=waku          # optional; BLANK falls back to this

No SDK and no new dependency: `src/mem0.nim` speaks the API by hand over the
same HTTP helper the MCP bridge and the OTLP exporter use.

Two honest caveats, both from the API rather than from this port. The v3
pipeline that the pinned SDK uses has no `infer` flag, so `add` means "queued
for extraction", not "stored and findable" — a sentence mem0 decides is not
worth remembering will not come back on `search`. What *is* better is
`settle()`: `add` returns an `event_id` the client polls, so "is it searchable
yet" is a question with an answer instead of a row count watched until it
stops moving.

Episodic memory stays on sqlite by default — and since this port, it can
also live in your Obsidian vault (`WAKU_EPISODIC_STORE=obsidian` plus
`WAKU_OBSIDIAN_VAULT`), one note per event under `waku/episodes/`. Notion
stays Python-only: it answers an honest error here, and Obsidian took its
place. And
a fact's id is now an opaque string (`"1"` locally, a UUID on a hosted store),
which the dashboard's JSON already carried as a token the JS posts back
verbatim — episode ids made the same trip (a vault path reads as `"waku/episodes/....md"`).

## Facts can also live in a Zep graph instead of sqlite

The temporal-graph alternative to mem0's rows: entities and relationships with
validity intervals, so a correction supersedes the older edge at a point in
time rather than merely outranking it.

    export WAKU_SEMANTIC_STORE=zep
    export ZEP_API_KEY=z_...          # required; without it, sqlite + a line
    export ZEP_USER_ID=waku           # optional; BLANK falls back to this

No SDK and no new dependency: `src/zep.nim` speaks the API by hand over the
same HTTP helper, against the generation the pinned `zep-cloud 3.29.0` SDK
speaks (base `api.getzep.com/api/v2`, header `Api-Key`).

Two honest caveats, both from the product rather than from this port. `add`
is a graph ingest, not an insert: Zep decides how to decompose the text, so
`search` returns Zep's rendering of an edge or node, not Waku's sentence —
answers will read differently from the other backends even when equally
correct. And ingestion is asynchronous twice over: `add` blocks until the
episode reports `processed`, and `settle` additionally waits until the node
count holds still — `processed` describes the episode, and the nodes derived
from it arrive afterwards.

## Facts can live in your own Postgres instead of sqlite

The vector upgrade path, on your own database rather than a service: real
embeddings and cosine similarity instead of keyword BM25. Any Postgres with
the `vector` extension works — not just Supabase, whose Python backend this
replaces with direct SQL (no PostgREST, no `match_chunks` RPC to install).

    createdb waku
    psql waku < sql/init_postgres.sql   # extension + table + indexes
    export WAKU_SEMANTIC_STORE=postgres
    export DATABASE_URL=postgres://user:pass@localhost:5432/waku
    export OPENAI_API_KEY=sk-...        # embeddings; without either key, sqlite + a line
    export OPENAI_EMBED_MODEL=text-embedding-3-small  # optional

No SDK and no new dependency: `src/pgvector.nim` speaks SQL through the
`db_postgres` driver that already ships, and embeddings go over the same HTTP
helper as every other REST call.

Three honest caveats. Every `add` AND every `search` pays one embeddings call
(network + latency + dollars) — the trade this backend makes for phrasing
that diverges from wording ("my business partner" finding "Alex is my
cofounder"). The `source` column holds the subject, so the dashboard's
provenance column stays blank on this backend, exactly like Python. And
`settle` answers immediately: the embedding is computed before the insert,
so the row is searchable as soon as Postgres commits it.

## Facts can live in LangMem instead of sqlite

The library, not a service: LangGraph memory primitives over a store YOU
provide — in this process by default, in your Postgres when configured. No
account, no console, no key of its own; what it bills you for is embeddings
(one per `add`, one per `search`).

    export WAKU_SEMANTIC_STORE=langmem
    export OPENAI_API_KEY=sk-...        # required; without it, sqlite + a line
    export OPENAI_EMBED_MODEL=openai:text-embedding-3-small  # optional
    export WAKU_LANGMEM_POSTGRES=postgres://user:pass@localhost:5432/waku
                                        # optional; without it, memory mode

THE DEFAULT IS EPHEMERAL, AND THAT IS DISCLOSED LOUDLY. Without the database
this client's rows die with the process: the agent's long-lived client holds
them for the run, and the dashboard's per-request client sees an empty store
— exactly like Python's per-collect construction. `list` after a restart
returning nothing is the store working as documented, not a bug. For
persistence run `sql/init_langmem.sql` on a fresh database and set the DSN
above (table `langmem_store`, HNSW cosine index included).

This is also why the arena reports LangMem reads as "unreadable" rather
than "0 facts": every read through a fresh store answers from an empty
table, and calling that zero would be a true statement about the wrong
object.

Two port notes. What gets embedded is the whole value as canonical JSON
(upstream's default index fields), not the `subject: content` packing the
other backends use. And `list` answers newest-first per this repo's contract;
upstream scans in key order.

## Traces are JSONL; spans need a collector you name

Every turn already writes two files under `WAKU_HOME`: `traces/<date>.jsonl`
(what happened, in order) and `usage.jsonl` (tokens and dollars, never wiped).
That needs nothing and stays on.

Point `OTEL_EXPORTER_OTLP_ENDPOINT` at a collector and the same events also
leave the machine as a span tree any OTel backend can draw:

    phoenix serve                                                  # localhost:6006
    OTEL_EXPORTER_OTLP_ENDPOINT=localhost:6006 ./waku chat

`6006`, not `4317`: the port POSTs OTLP/HTTP to `<host>:port/v1/traces`,
whereas Python's SDK ships the gRPC exporter, and Phoenix serves OTLP/HTTP
on the port its own UI is on. The value is `host:port` under the same rules
as the dashboard's `otel` connection probe, so a typo is one stderr line and
no spans rather than a crash. One POST per turn, and a collector that is
down costs that turn's spans and nothing else.

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
  home, otelEndpoint) with `WAKU_PROVIDER`, `WAKU_API_KEY`, `WAKU_MODEL`,
  `WAKU_HOME` and `OTEL_EXPORTER_OTLP_ENDPOINT` env overrides,
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
- `src/factstore.nim` is the `FactStore` contract every semantic backend has
  to honour, as a record of required function fields, plus the sqlite adapter
  over the procs above. Seven methods; ids are opaque strings; a miss returns
  empty and never raises; `settle()` means searchable rather than written.
- `src/episodes.nim` is the `EpisodeStore` contract every episodic backend
  has to honour, as a record of required function fields, plus the sqlite
  adapter over the procs above. Five methods; ids are opaque strings; a miss
  returns empty and never raises; an empty query falls back to recent.
- `src/obsidian.nim` is the episodic backend that is files, not a service:
  one markdown note per event under `<vault>/waku/episodes/`, frontmatter
  for the date, keyword scan with Notion parity. Opt-in:
  `WAKU_EPISODIC_STORE=obsidian` plus `WAKU_OBSIDIAN_VAULT`. Filenames are
  sanitized and deletes resolve inside the folder, so a hostile summary
  cannot escape the vault.
- `src/mem0.nim` is the hosted backend by hand — no SDK, no dependency, over
  `http.nim`'s one helper — against the API generation the pinned `mem0ai`
  SDK speaks (v3 for add/search/get_all, v1 for update/delete). It is opt-in:
  `WAKU_SEMANTIC_STORE=mem0` plus `MEM0_API_KEY`, with `MEM0_USER_ID` scoping
  the person (default `waku`, and a BLANK value falls back to the default —
  the Connections form writes optional fields even when you leave them empty).
- `src/zep.nim` is the second hosted backend by hand — same helper, no SDK —
  against the API generation the pinned `zep-cloud` SDK speaks (`POST graph`
  ingest, `POST graph/search`, `POST graph/node/user/{id}` for listing,
  per-uuid node/edge get and delete, `POST users`). It is opt-in:
  `WAKU_SEMANTIC_STORE=zep` plus `ZEP_API_KEY`, with `ZEP_USER_ID` scoping the
  graph (default `waku`, same empty-means-default rule). `add` blocks on the
episode; `settle` waits for the graph to stop growing, not just the episodes.
- `src/pgvector.nim` is the user-hosted backend over direct SQL — same
  `rag_chunks` table as Python's Supabase store, no PostgREST, no RPC: the
  cosine goes straight into the query. Opt-in: `WAKU_SEMANTIC_STORE=postgres`
  plus `DATABASE_URL` and `OPENAI_API_KEY` (`OPENAI_EMBED_MODEL` scopes the
  model, default `text-embedding-3-small`). `settle` is immediate; every
  `add` and `search` spends one embedding.
- `src/langmem.nim` is the library backend in two twins — in-process rows
  plus a Postgres twin over direct SQL on the port's own `langmem_store`
  table (JSONB value, HNSW cosine, upsert on `(prefix, key)`). Opt-in:
  `WAKU_SEMANTIC_STORE=langmem` plus `OPENAI_API_KEY`, with
  `WAKU_LANGMEM_POSTGRES` switching memory mode to Postgres. Memory mode is
  ephemeral by design (see above); `settle` is immediate in both.
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
  `schemas`, `execute` with errors-as-text) plus JSON arg helpers and the
  shared subprocess runner with an explicit deadline.
- `src/registry.nim` ports `build_registry` in the same order (calendar,
  notes, messages, search, memory trio, experimental/apple/github opt-ins,
  connected MCP tools) — every side effect injected, like everywhere else.
- `src/search.nim` (`search_web`: Tavily when keyed, DuckDuckGo scrape
  otherwise), `src/github.nim` (`github_read` over the `gh` CLI allowlist),
  `src/experimental.nim` (`delegate_task` over a `pi` subprocess with JSON
  event parsing, workspace folders, manifests and autorun, plus the three
  coming-soon stubs) and `src/apple.nim` (the four osascript readers /
  writers, macOS-gated, with their TTL caches).
- `src/judgment_cases.nim` ports `ops/judgment_cases.py`: all five suites
  (25 invented cases, fifteen questions each), the label-free picker, and
  the grading rules with Python's banker's rounding.
- `src/scoring.nim` (`check_case`/`case_for_message`), `src/judge.nim`
  (the 0-10 referee with ground-truth tools and retry) and
  `src/arena_live.nim` (live model/memory/judgment race runners over
  scripted-or-`clientFor` brains, sequential by design). The dashboard
  wires them plus the provider/integration probes and the graph stream;
  races need API keys, everything else is offline-testable.
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
- `src/trace.nim` ports `ops/tracing.py`: JSONL traces, the `usage.jsonl`
  ledger, `compose` fanout, and the OTLP span tree.
- `src/otelproto.nim` is a hand-rolled protobuf writer (varint, tag,
  length-delimited, fixed64) plus the `ExportTraceServiceRequest` tree. It
  exists because there is no Nim OTel SDK and binding opentelemetry-cpp
  would break the zero-dependency rule for what is plain length-delimited
  messages; it mints nothing, so ids and timestamps stay the caller's.
- `src/otel.nim` is the exporter itself: the `OTEL_EXPORTER_OTLP_ENDPOINT`
  rules the dashboard's `otel` probe already applies, the span tree Python's
  SDK builds (`agent_run` root, one zero-duration child per event,
  `openinference.span.kind` as an attribute, `waku.<field>` holding
  Python-shaped JSON text), and one POST to `http://host:port/v1/traces` per
  turn. A collector that is down costs one stderr line, never the turn.
- `src/jsondump.nim` renders `json.dumps`-shaped meta/ledger bytes and
  Python-`str()`-shaped tool args.
- `src/graph/` ports `graph/engine.py` + `graph/nodes.py` (waves, routers,
  guards, tool/llm/agent/fn nodes).
- `src/triage.nim` ports the triage workflow (fail-open classify, `.ics`
  reader, 5-node graph) plus the `graphTurn` app binder.
- `src/gather.nim` ports the gather workflow + ops binders (calendar,
  memory with its own connection, toolless synthesis, outbox draft) and
  `runGather`. GitHub/web stay honestly unavailable until phase 5.
- `src/memory_live.nim` ports the live layer (`retrieval_gate.py`,
  consolidation, `MEMORY.md` mirror, skill keyword match): the gate judge
  with fail-open, gated facts+episodes retrieval, distill-every-N with the
  recall rule (a turn never re-keeps what it read — `restates`), and the
  `wireMemory` that fills the session/app seams for every built agent.
- `src/commands.nim` ports `ops/commands.py` (the `/gather` + `/triage`
  table with `parse`/`describe`/honest-unknown, no dynamic imports) and
  `src/connect.nim` ports `connect.py` plus both sign-ins (`google` over
  loopback OAuth, `waku-memory` over the MCP bridge — every browser and
  socket step injected, so tests never open either). The dashboard chat
  answers the table without building an agent first.
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

Episodic memory (Notion) is not ported and stays that way — Obsidian took
its place in this port. A value either selector does not recognise
falls back to sqlite with a line on stderr rather than refusing. And the
evals. The
phase list with its
gates lives in
[docs/nim-port-design.md](../docs/nim-port-design.md).
