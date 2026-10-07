## Dashboard backend — units 8a (GET reads) + 8b (POST mutations, SSE,
## reveal, server loop) of the Nim port.
##
## Port target: `waku/ops/dashboard.py` `Handler.do_GET` (8a: `/api/data`
## as a bounded status document, NOT the full `collect()` blob,
## `/api/models`, `/api/events`, statics + index fallback) plus the 8b
## slice of `Handler.do_POST`: `/api/chat`, `/api/memory`, `/api/settings`,
## `/api/query`, `/api/session`, `/api/pin`, `/api/connections`,
## `/api/connections/test`, `/api/providers`, `/api/reveal` (a GET in
## Python — a side effect, so it landed here rather than in 8a) and
## `/api/voice`, the SSE streams (`/api/chat/stream`, `/api/graph/stream`)
## and the server loop (port walk, gateway lifecycle, accept loop).
##
## Unit 8c owns the compare arena through `arena.nim` (the store, the
## reprice-at-read scoreboard, the race/judge seams): GET
## `/api/compare/history` plus POST `clear` / `regrade` / `delete_run` /
## `compare/stream`. Unit 8d owns the memory + judgment arenas through
## `memory_arena.nim` (the scorer, the fixture discovery, the hosted
## seams, the judgment board): GET `/api/judgment-arena`,
## `/api/memory-arena`, `/api/memory-arena/stores` plus POST
## `/api/judgment-arena/key`, `/api/memory-arena/clean` and both arena
## streams. Unknown API paths 404; nothing renders the SPA shell as data.
##
## Like 8a, every handler stays pure dispatch over injected deps: the
## agent turn, the graph runner, the transcriber, the editor open, the
## connection probes and the socket loop all arrive as seams (the 5d2
## pattern — no process-global mutable state, so tests stay 100% offline
## with stub fns like phase 3e's stub `FetchFn`).
##
## Two divergences from Python, both documented in the phase task file:
##
## - `/api/data` is a STATUS SUBSET (generated_at, home, provider, model,
##   usage, connections, trace pointer), not `collect()`. The full blob
##   (turns from traces, db introspection, skills, graph topologies, eval
##   report) is most of dashboard.py and lands across the remaining 8x
##   units; the route contract pins PATHS, not payload keys, so the
##   subset keeps `test_route_contract.py` green.
## - Response bodies render with stdlib `$` (compact JSON) instead of
##   Python's `json.dumps` spaced separators. Files the dashboard READS
##   (usage.jsonl, chat meta) keep `jsonDumps` parity; HTTP bodies are
##   parsed by the browser, so byte shape is not a contract.
## - `bindHost` does not print the off-loopback warning (a side effect);
##   the caller prints it. `dashboardPort` falls back to 7777 on a
##   non-numeric env value where Python would raise — startup must not
##   crash on a typo.
## - `/` and `/static/...` answer from the compile-time embed of
##   `waku/ops/static/` when `DashboardDeps.staticDir` is `""`, which is
##   what `findStaticDir` returns for a binary with no checkout beside it.
##   A configured `staticDir` still wins and still reads the disk, so
##   frontend edits in a checkout need no rebuild and the Python
##   behaviour is unchanged there. The embed is what makes the shipped
##   binary a single file (see the embed section below).

import std/algorithm
import std/httpclient
import std/json
import std/math
import std/nativesockets
import std/sequtils
import std/net
import std/os
import std/osproc
import std/strutils
import std/syncio
import std/tables
import std/times

import db_connector/db_sqlite

import ./app
import ./apple
import ./episodes
import ./arena
import ./arena_live
import ./calendar
import ./catalog
import ./cli
import ./client
import ./commands
import ./connect
import ./config
import ./db
import ./discord
import ./experimental
import ./factstore
import ./gather
import ./gateway
import ./github
import ./http
import ./integrations
import ./observability
import ./observe
import ./mcp
import ./memory_admin
import ./judgment_cases
import ./memory_arena
import ./memory_live
import ./pricing
import ./providers
import ./registry
import ./search
import ./session
import ./skills except FetchFn
import ./telegram
import ./tools
import ./triage
import ./turn_evals
import ./whatsapp
import ./wire

export catalog.FetchFn
## The SSE event type lives in `arena.nim` so the race pipeline shares it.
export arena.SseEmit

const
  defaultHost* = "127.0.0.1"
    ## Loopback unless told otherwise — the dashboard has no auth.
  defaultPort* = 7777

  staticTypes* = [
    (".css", "text/css"),
    (".js", "text/javascript"),
    (".svg", "image/svg+xml"),
    (".html", "text/html; charset=utf-8"),
    (".woff2", "font/woff2"),
  ]
    ## Port of Python's `STATIC_TYPES`: the dashboard serves its own
    ## fonts instead of fetching them, hence `.woff2`.

  pythonPinnedGet* = [
    "/api/data",
    "/api/session",
    "/api/models",
    "/api/events",
    "/api/reveal",
    "/api/compare/history",
    "/static/",
    "/embed/chat",
    "/api/judgment-arena",
    "/api/memory-arena",
    "/api/memory-arena/stores",
  ]
    ## Mirror of the Python `PINNED_GET` set both the route-contract eval
    ## and the hosted policy table read from. 8a serves a SUBSET of these
    ## paths and must never serve anything outside this list: a new path
    ## here is a contract change (same commit updates the eval + policy).

  portOnlyPostRoutes* = [
    "/api/turn-evals/judge",
  ]
    ## POST paths this port serves that Python's `PINNED_POST` does not
    ## name YET, each one a documented divergence rather than a drift:
    ##
    ## - `/api/turn-evals/judge` (spec 015) landed upstream with
    ##   `waku/ops/turn_evals.py`, which this branch does not carry: the
    ##   Python tree here has no turn-evals module, no pin for it and no
    ##   hosted policy entry. The port tracks the newer upstream, so the
    ##   route is served and declared HERE until the Python side syncs —
    ##   at which point it moves into `pythonPinnedPost` and this list
    ##   empties.
    ##
    ## `pythonPinnedGet`/`pythonPinnedPost` stay an EXACT mirror of the
    ## Python pins (a test enforces it); this list is what keeps a served
    ## route from being invisible. A route here is a deliberate gap: it
    ## must never hold one the Python side already pins, and the hosted
    ## route-contract eval cannot see it (no policy entry exists to
    ## check). Two tests pin both halves of that sentence.

  pythonPinnedPost* = [
    "/api/chat",
    "/api/memory",
    "/api/settings",
    "/api/query",
    "/api/session",
    "/api/pin",
    "/api/connections",
    "/api/connections/test",
    "/api/providers",
    "/api/compare/clear",
    "/api/compare/regrade",
    "/api/compare/delete_run",
    "/api/chat/stream",
    "/api/compare/stream",
    "/api/voice",
    "/api/graph/stream",
    "/api/judgment-arena/key",
    "/api/judgment-arena/stream",
    "/api/memory-arena/clean",
    "/api/memory-arena/stream",
  ]
    ## Mirror of the Python `PINNED_POST` set (`POST_ROUTES` +
    ## `STREAM_ROUTES` + the judgment/memory-arena exact checks). 8b serves
    ## a SUBSET; the arena entries stay honest 501s until 8c/8d.

  portOnlyGetRoutes* = [
    "/api/observability",
  ]
    ## GET paths this port serves that Python's `PINNED_GET` does not name
    ## YET, each one a documented divergence rather than a drift:
    ##
    ## - `/api/observability` (spec 012) landed upstream in commit
    ##   `3b08a62`, which this branch does not carry: the Python tree here
    ##   has no `waku/ops/observability.py`, no pin for it and no hosted
    ##   policy entry. The port tracks the newer upstream, so the route is
    ##   served and declared HERE until the Python side syncs — at which
    ##   point it moves into `pythonPinnedGet` and this list empties.
    ##
    ## `pythonPinnedGet`/`pythonPinnedPost` stay an EXACT mirror of the
    ## Python pins (a test enforces it); this list is what keeps a served
    ## route from being invisible. A route here is a deliberate gap: it
    ## must never hold one the Python side already pins, and the hosted
    ## route-contract eval cannot see it (no policy entry exists to
    ## check). Two tests pin both halves of that sentence.

type
  ChatFn* = proc(message: string): JsonNode {.closure.}
    ## One non-streaming turn (`chat`): the final done payload.
  ChatStreamFn* = proc(message: string, emit: SseEmit) {.closure.}
    ## One streaming turn (`chat_stream`): harness events, then done.
  GraphStreamFn* = proc(payload: JsonNode, emit: SseEmit) {.closure.}
    ## One graph workflow run (`graph_stream`): node events, then done.
  VoiceFn* = proc(raw: string): JsonNode {.closure.}
    ## Speech-to-text over the raw audio blob (`transcribe_audio`).
  SessionFn* = proc(payload: JsonNode): JsonNode {.closure.}
    ## The agent-touching half of `session_action` (new/switch against
    ## the live `Waku`); history stays a direct db read.
  RaceFn* = arena.RaceFn
    ## One model race behind `/api/compare/stream` (nil until a harness
    ## runner exists — the honest done error, like the unwired graph).
  JudgeFn* = arena.JudgeFn
    ## One referee grade behind `regrade` and judged races (nil until a
    ## judge backend exists).
  MemoryRunFn* = memory_arena.MemoryRunFn
    ## One memory race behind `/api/memory-arena/stream` (nil until a
    ## harness runner exists — the honest done error, like the rest).
  JudgmentRaceFn* = memory_arena.JudgmentRaceFn
    ## One judgment race behind `/api/judgment-arena/stream` (nil until
    ## a judge runner exists).
  TurnJudgeCallFn* = turn_evals.JudgeCallFn
    ## One turn-judge model call behind `POST /api/turn-evals/judge`.
    ## The live path wires the small model of the provider in use
    ## (`makeLiveTurnJudge`); nil is the in-process deps case
    ## (validate-only callers), where the route answers the honest
    ## error instead of a 500.
  HostedListFn* = memory_arena.HostedListFn
    ## One hosted store's facts behind `/api/memory-arena/stores`.
  HostedWipeFn* = memory_arena.HostedWipeFn
    ## One hosted partition wipe behind `/api/memory-arena/clean`.
  RevealProbeFn* = proc(name: string): bool {.closure.}
    ## `shutil.which` seam: is this editor CLI on PATH?
  RevealOpenFn* = proc(argv: seq[string]) {.closure.}
    ## `subprocess.run` seam: open/reveal one path.
  PortTakenFn* = proc(port: int): bool {.closure.}
    ## Port-walk probe: is this port busy? Nil means the real bind probe.
  GatewayHook* = proc() {.closure.}
    ## Gateway supervisor lifecycle (`reconcile` at startup, `shutdown`
    ## at exit). Nil is a no-op: gateway runners arrive later.
  ServeFn* = proc(srv: var DashboardServer) {.closure.}
    ## The blocking accept loop. Nil means the stdlib socket loop below;
    ## tests inject a stub that captures host/port and returns.

  StaticAsset* = tuple[name, body: string]
    ## One `waku/ops/static/` file frozen into the executable: its
    ## checkout-relative name (always `/`-separated, so a Windows build
    ## looks up the same keys) and its exact bytes. Built by the
    ## compile-time walk in the embed section.

  DashboardDeps* = object
    ## Everything the handlers read, injected so tests stay offline.
    home*: string
      ## `WAKU_HOME`: usage ledger, traces, state.db.
    staticDir*: string
      ## A `waku/ops/static/` checkout served from disk; `""` means
      ## there is none and the compile-time embed answers instead (a bare
      ## binary). Set by `findStaticDir`, injected by tests.
    provider*: string
    model*: string
    smallModel*: string
    baseUrl*: string
    apiKey*: string
    providers*: seq[Provider]
    env*: Table[string, string]
    fetch*: FetchFn
      ## Catalog fetch seam (stub in tests, live client later).
    today*: string
      ## `YYYY-MM-DD` trace file selector; "" means the local today.
    nowIso*: string
      ## `generated_at` override for deterministic tests; "" computes it.
    nowMs*: int64
      ## The clock the observability window reads, in unix millis; 0
      ## means now. Injectable so a pin can date a crafted trace.
    dotenvPath*: string
      ## The `.env` file settings/connections persist to; "" skips disk.
    hostOs*: string
      ## Platform for the reveal fallback; "" means the build host.
    chatFn*: ChatFn
    chatStreamFn*: ChatStreamFn
    graphStreamFn*: GraphStreamFn
    voiceFn*: VoiceFn
    sessionFn*: SessionFn
    raceFn*: RaceFn
    judgeFn*: JudgeFn
    turnJudgeFn*: TurnJudgeCallFn
    memoryRunFn*: MemoryRunFn
    judgmentRaceFn*: JudgmentRaceFn
    hostedListFn*: HostedListFn
    hostedWipeFn*: HostedWipeFn
    judgmentSuites*: JsonNode
      ## The judgment cases for the picker + race validation (empty until
      ## the `judgment_cases` port lands — unknown suites stay honest).
    memoryExample*: string
      ## The shipped probe fixture (`evals/memory_arena.json` in a
      ## checkout, "" in a bare binary — then `available: false`, like
      ## the pip wheel that never shipped `evals/`).
    revealProbe*: RevealProbeFn
    revealOpen*: RevealOpenFn
    store*: HealthStore
      ## Connection health, lazily created per home when nil.
    facts*: FactStore
      ## Where the memory page reads and writes facts. Nil means "ask the
      ## env", exactly like the agent does — one selector, so a page load
      ## and a turn can never disagree about where the facts live. Tests
      ## inject the stateful fake (`tests/factstore_fakes.nim`) rather than
      ## standing up a hosted service.
    probes*: Table[string, ProbeFn]
      ## Injected connection tests (5d2 pattern); missing means untested.
    providerProbe*: ProbeFn
      ## The provider-key probe for `/api/providers` saves.
    rebuild*: AgentRebuildFn
    gatewayReload*: GatewayReloadFn
    gatewayStatus*: GatewayStatusFn

  DashboardServer* = object
    ## One prepared dashboard: where it serves and with what deps.
    host*: string
    port*: int
    deps*: DashboardDeps

proc readGetRoutes*(): seq[string] =
  ## The served GET API surface (8a reads + the 8b `reveal` side effect +
  ## the 8c compare history + the 8d arena GETs + the hosted-front-door
  ## session reads + the port-only divergences). Each MUST be in
  ## `pythonPinnedGet` or in `portOnlyGetRoutes` (there is a test).
  ## Static paths (`/`, `/static/`, `/embed/chat`) are served too but
  ## walk the checkout, not this list — like Python's trailing `else`.
  @["/api/data", "/api/session", "/api/models", "/api/events",
    "/api/reveal", "/api/compare/history", "/api/judgment-arena",
    "/api/memory-arena", "/api/memory-arena/stores"] &
    @portOnlyGetRoutes

proc readPostRoutes*(): seq[string] =
  ## The served POST API surface (8b routes + the 8c compare trio + the
  ## 8d key/clean + the port-only divergences; streams dispatch
  ## separately via `handleStream`). Each MUST be in `pythonPinnedPost`
  ## or in `portOnlyPostRoutes` (there is a test).
  @["/api/chat", "/api/memory", "/api/settings", "/api/query",
    "/api/session", "/api/pin", "/api/connections",
    "/api/connections/test", "/api/providers", "/api/voice",
    "/api/compare/clear", "/api/compare/regrade",
    "/api/compare/delete_run", "/api/judgment-arena/key",
    "/api/memory-arena/clean"] &
    @portOnlyPostRoutes

proc contentTypeFor*(name: string): string =
  ## Port of `STATIC_TYPES.get(target.suffix, "application/octet-stream")`.
  let dot = name.rfind('.')
  let suffix = if dot >= 0: name[dot .. ^1] else: ""
  for (ext, ctype) in staticTypes:
    if suffix == ext:
      return ctype
  return "application/octet-stream"

proc urlDecode*(s: string): string =
  ## Minimal `%XX`/`+` decoding for dashboard query strings (provider
  ## names and integer cursors never need more, and this stays stdlib).
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add(chr(fromHex[int](s[i + 1 .. i + 2])))
        i += 3
        continue
      except ValueError:
        discard
    result.add(if s[i] == '+': ' ' else: s[i])
    inc i

proc splitTarget*(target: string): (string, Table[string, string]) =
  ## `"/api/events?cursor=12"` → `(path, {cursor: "12"})`. No query →
  ## an empty table, like `parse_qs` on a bare path.
  let q = target.find('?')
  if q < 0:
    return (target, initTable[string, string]())
  var query = initTable[string, string]()
  for pair in target[q + 1 .. ^1].split('&'):
    let eq = pair.find('=')
    if eq < 0:
      query[urlDecode(pair)] = ""
    else:
      query[urlDecode(pair[0 ..< eq])] = urlDecode(pair[eq + 1 .. ^1])
  return (target[0 ..< q], query)

# ---------------------------------------------------------------------------
# Compile-time asset embed (9a-1) — the dashboard frontend in the binary.
#
# `waku/ops/static/` holds 55 files / ~668 KB (largest: `style.css`,
# 67 KB) and EVERY one of them embeds byte-identically, the three
# `.woff2` fonts included: `staticRead` keeps raw bytes, so there is no
# escaping, no codegen pass and NO asset left behind for size or format.
# The checkout is only ever READ. Nothing under `design/` is edited
# (AGENTS.md rule 8), and LICENSE-BRAND's "included and unmodified"
# still holds: the design copies reach the binary exactly as they sit on
# disk, never copied into `nim/` and never touched.
#
# The walk happens in the VM, so the checkout must exist when the
# COMPILER runs. Compiling without one (a source drop with no
# `waku/ops/static/`) is not a build error: the table comes out empty
# and the SPA routes answer with the same missing-frontend 404 Python
# gives. At RUN time no binary needs a checkout either way — the served
# bytes are the literals below, never a path.

const
  staticCheckoutDir = currentSourcePath().parentDir / ".." / ".." / "waku" /
    "ops" / "static"
    ## This module's own checkout, derived from this file's path so the
    ## walk works from any working directory and any relative compile.

proc collectStaticAssets(root: string): seq[StaticAsset] {.compileTime.} =
  ## `(name, bytes)` for every file under `root`, name-sorted so the
  ## table order is the same on every machine. Compile-time only: the
  ## literals it reads reach the binary, the proc never does.
  proc byName(a, b: StaticAsset): int = cmp(a.name, b.name)
  result = @[]
  for found in walkDirRec(root, relative = true):
    result.add((name: found.replace(DirSep, '/'),
      body: staticRead(root / found)))
  result.sort(byName)

const
  embeddedStaticAssets = collectStaticAssets(staticCheckoutDir)
  embeddedStaticCount* = embeddedStaticAssets.len
    ## How many files the compiler froze. The suite walks the checkout
    ## and holds the two counts equal, so an asset added but not
    ## embedded fails loudly instead of serving a quiet 404.

proc embeddedAsset*(name: string): (bool, string) =
  ## `(true, bytes)` for a checkout-relative asset name, `(false, "")`
  ## when the embed has no such file. An exact match is traversal-safe
  ## by construction: `..`, a leading `/`, a backslash and the empty name
  ## are simply not keys, so there is nothing to confine and no path to
  ## read.
  for asset in embeddedStaticAssets:
    if asset.name == name:
      return (true, asset.body)
  return (false, "")

proc embeddedIndex*(): (bool, string) =
  ## The SPA shell from the embed — what `serveIndex` answers with when
  ## there is no checkout on disk.
  embeddedAsset("index.html")

proc embeddedStaticNames*(): seq[string] =
  ## Every checkout-relative name in the embed, name-sorted (the suite
  ## compares it against its own walk of the checkout).
  for asset in embeddedStaticAssets:
    result.add(asset.name)

proc serveStatic*(staticDir, reqPath: string): (int, string, string) =
  ## Port of `_serve_static`: strip the query, confine to `staticDir`
  ## (a resolved path outside it is a 404, never a read), map the
  ## content type, serve with no-cache semantics left to the HTTP layer.
  ## With no `staticDir` the same route answers from the compile-time
  ## embed, whose exact-name lookup is the confinement that half.
  var path = reqPath.split('?')[0]
  const prefix = "/static/"
  if not path.startsWith(prefix):
    return (404, "text/plain", "not found")
  let name = path[prefix.len .. ^1]
  if staticDir.len == 0:
    let (embedded, body) = embeddedAsset(name)
    if not embedded:
      return (404, "text/plain", "not found")
    return (200, contentTypeFor(name), body)
  let target = absolutePath(staticDir / name)
  let root = absolutePath(staticDir)
  if target != root and not target.startsWith(root & DirSep):
    return (404, "text/plain", "not found")
  if not fileExists(target):
    return (404, "text/plain", "not found")
  return (200, contentTypeFor(name), readFile(target))

proc serveIndex*(staticDir: string): (int, string, string) =
  ## The `else` branch of `do_GET`: every non-API path renders the SPA.
  ## Python would 500 on a missing `index.html`; the port 404s instead
  ## (a missing frontend is a deployment bug, not a traceback). With no
  ## `staticDir` the shell comes from the compile-time embed.
  if staticDir.len == 0:
    let (embedded, body) = embeddedIndex()
    if not embedded:
      return (404, "text/plain", "not found")
    return (200, "text/html; charset=utf-8", body)
  let index = staticDir / "index.html"
  if not fileExists(index):
    return (404, "text/plain", "not found")
  return (200, "text/html; charset=utf-8", readFile(index))

proc tracePath*(home, today: string): string =
  ## Today's trace file, like `events_since`: `<home>/traces/<date>.jsonl`.
  let day = if today.len > 0: today else: format(now(), "yyyy-MM-dd")
  home / "traces" / day & ".jsonl"

proc readTraceEvents*(home: string): (seq[JsonNode], seq[string]) =
  ## Every trace event in every `<home>/traces/*.jsonl`, oldest file
  ## first; bad lines are skipped, like every other reader here. Returns
  ## the events plus the sorted file paths (Python's `trace_files`).
  var events: seq[JsonNode] = @[]
  var files: seq[string] = @[]
  let dir = home / "traces"
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".jsonl"):
        files.add(path)
  files = sorted(files)
  for path in files:
    var text = ""
    try:
      text = readFile(path)
    except IOError:
      continue
    for line in text.splitLines():
      if line.strip().len == 0:
        continue
      var ev: JsonNode
      try:
        ev = parseJson(line)
      except JsonParsingError:
        continue
      if ev.kind != JObject:
        continue
      events.add(ev)
  result = (events, files)

proc safeInt(n: JsonNode): int =
  ## Ledger numbers default to 0 when missing or mistyped, like Python's
  ## `dict.get(key, 0)` (the traces are append-only and hand-editable).
  case n.kind
  of JInt: int(n.getBiggestInt())
  of JFloat: int(n.getFloat())
  else: 0

proc turnSection*(home, provider, model: string,
                  providers: seq[Provider]): (JsonNode, JsonNode) =
  ## `(turns, stats)` from the trace events — port of the turns-grouping
  ## + stats block in Python `collect()`: events between `turn_start` and
  ## `turn_end` become one turn (gate, llm calls, tools, graph route,
  ## receipt, reply); each turn pays its latency (first-to-last stamp) and
  ## its repriced cost, and `stats` aggregates the FULL list while `turns`
  ## serves at most the newest 50. Always arrays — the Loop tab reads
  ## `d.turns.length` with no fallback, so `undefined` here is the
  ## `TypeError` that blanks the page.
  ##
  ## Three deliberate divergences: tool rows read `statusOf` (the port's
  ## ok/error classifier — the `warn` middle state has no seam in
  ## `app.statusOf`, so warn-ish outputs read ok), pricing never
  ## touches the network (Python warms the catalog cache; `priceFor`
  ## reads it as-is, offline), and a turn's `receipt` is the one `app`
  ## RECORDED (Python's `collect()` never reads the `receipt` trace event,
  ## so the port surfaces the recorded line instead of recomputing it).
  ## Repricing does not change: `cost` still comes from this turn's own
  ## `llm_calls` at the provider estimate, receipt or not.
  let (events, files) = readTraceEvents(home)
  let fileCount = files.len
  var turns: seq[JsonNode] = @[]
  var current = newJNull()
  for ev in events:
    let typ = ev.jget("type").getStr()
    if typ == "turn_start":
      current = %*{"user_message": ev.jget("user_message").getStr(),
                   "ts": ev.jget("ts").getStr(), "gate": newJNull(),
                   "llm_calls": newJArray(), "tools": newJArray(),
                   "reply": newJNull()}
    elif current.kind != JObject:
      continue
    elif typ == "gate":
      current["gate"] = copy(ev)
    elif typ == "route":
      let target = ev.jget("target").getStr()
      var g = current.jget("graph")
      if g.kind != JObject:
        g = %*{"workflow": "", "route": "", "reason": ""}
      g["workflow"] = %ev.jget("workflow").getStr()
      g["route"] = %(if target == "quick_reply": "quick" else: "full")
      current["graph"] = g
    elif typ == "triage":
      var g = current.jget("graph")
      if g.kind != JObject:
        g = %*{"workflow": "", "route": "", "reason": ""}
      g["reason"] = %ev.jget("reason").getStr()
      current["graph"] = g
    elif typ == "llm":
      current["llm_calls"].add(copy(ev))
    elif typ == "tool":
      current["tools"].add(copy(ev))
    elif typ == "consolidation":
      current["consolidation"] = copy(ev)
    elif typ == "receipt":
      # Spec 011: the receipt the turn already recorded, so the Loop tab
      # draws the same line a reopened thread draws from `meta.receipt`
      # (`render.js` reads `t.receipt`). The trace record wraps the
      # payload in `type` and `ts`, so those two come off and what lands
      # on the turn is the object `receipt.nim` built — its pinned keys,
      # in the builder's order. A turn with no `receipt` event carries NO
      # `receipt` key at all: the footer falls back to seconds,
      # iterations and model, exactly as before.
      if ev.kind == JObject:
        var r = copy(ev)
        r.delete("type")
        r.delete("ts")
        current["receipt"] = r
    elif typ == "turn_end":
      current["reply"] = ev.jget("reply")
      current["iterations"] = ev.jget("iterations")
      turns.add(current)
      current = newJNull()
  if current.kind == JObject:
    # A turn that never ended = the smoking gun for hangs.
    current["reply"] = %"TURN NEVER FINISHED — check for a hang after this point"
    current["unfinished"] = %true
    turns.add(current)
  let (pin, pout) = priceFor(provider, model, providers)
  var latencies: seq[int] = @[]
  var toolCalls = 0
  var toolErrors = 0
  var skips = 0
  var retrieves = 0
  var tin = 0
  var tout = 0
  var totalCost = 0.0
  for t in turns:
    var ti = 0
    var to = 0
    for c in t.jget("llm_calls"):
      ti += safeInt(c.jget("usage").jget("in"))
      to += safeInt(c.jget("usage").jget("out"))
    tin += ti
    tout += to
    # Priced from this turn's own calls, like Python — never a total.
    t["cost"] = %(float(ti) / 1000000.0 * pin +
      float(to) / 1000000.0 * pout)
    totalCost += t["cost"].getFloat()
    let (okStart, startMs) = parseTsMs(t.jget("ts").getStr())
    var endMs: int64 = 0
    var hasEnd = false
    let calls = t.jget("llm_calls")
    if calls.kind == JArray and calls.len > 0:
      let (ok, ms) = parseTsMs(calls[calls.len - 1].jget("ts").getStr())
      if ok:
        endMs = ms
        hasEnd = true
    if okStart and hasEnd:
      let lat = int(endMs - startMs)
      t["latency_ms"] = %lat
      latencies.add(lat)
    else:
      t["latency_ms"] = newJNull()
    for x in t.jget("tools"):
      let output = x.jget("output").getStr()
      x["status"] = %statusOf(output)
      var summary = output.split(". ")[0]
      if summary.len > 120:
        summary = summary[0 ..< 120]
      x["summary"] = %summary
      inc toolCalls
      if x["status"].getStr() == "error":
        inc toolErrors
    let dec = t.jget("gate").jget("decision").getStr()
    if dec == "skip":
      inc skips
    elif dec == "retrieve":
      inc retrieves
  latencies = sorted(latencies)
  var latSum = 0
  for l in latencies:
    latSum += l
  let stats = %*{"turns": turns.len, "tool_calls": toolCalls,
    "tool_errors": toolErrors, "gate_skips": skips,
    "gate_retrieves": retrieves, "tokens_in": tin, "tokens_out": tout,
    "cost": round(totalCost * 10000.0) / 10000.0,
    "latency_avg": (if latencies.len > 0: latSum div latencies.len else: 0),
    "latency_p95": (if latencies.len > 0:
      latencies[min(latencies.len - 1, int(float(latencies.len) * 0.95))]
      else: 0),
    "trace_files": fileCount}
  var served = newJArray()
  var n = 0
  for i in countdown(turns.len - 1, 0):
    if n >= 50:
      break
    served.add(turns[i])
    inc n
  result = (served, stats)

proc graphSection*(home: string, enabled: bool): JsonNode =
  ## Port of the `"graph"` block in Python `collect()`: topologies
  ## straight from the engine (never hand-drawn, so the picture cannot
  ## drift) plus the quick/full split and the last runs from the trace
  ## events. A page load never builds an agent — this only reads the
  ## trace files, skipping bad lines like every other reader here.
  ##
  ## `enabled` gates TRIAGE ONLY, the per-message front door: `waku
  ## gather` is a routine run by hand and ignores the flag, like Python.
  var routes: seq[string] = @[]
  var ends: seq[JsonNode] = @[]
  let (events, _) = readTraceEvents(home)
  for ev in events:
    let typ = ev.jget("type").getStr()
    if typ == "route":
      routes.add(ev.jget("target").getStr())
    elif typ == "graph_end":
      ends.add(ev)
  var quick = 0
  var full = 0
  for t in routes:
    if t == "quick_reply":
      inc quick
    elif t == "full_agent":
      inc full
  var runs = newJArray()
  # The last few completed runs, newest first: Overview needs this
  # because triage runs itself on every message while gather runs when
  # asked, so "which chart is relevant" is a question only the trace
  # can answer.
  let start = if ends.len > 8: ends.len - 8 else: 0
  for i in countdown(ends.len - 1, start):
    if i < 0:
      break
    let e = ends[i]
    var path = e.jget("path")
    if path.kind != JArray:
      path = newJArray()
    let ms = e.jget("ms")
    let steps = e.jget("steps")
    runs.add(%*{"workflow": e.jget("workflow").getStr(),
                 "ms": (if ms.kind == JInt: ms else: newJNull()),
                 "at": e.jget("ts").getStr(),
                 "steps": (if steps.kind == JInt: steps else: newJNull()),
                 "path": path,
                 "error": e.jget("error")})
  result = %*{"enabled": enabled,
               "workflows": [triageTopology(), gatherTopology()],
               "runs": runs,
               "stats": {"quick": quick, "full": full}}

proc parseCursor*(raw: string): (bool, int) =
  ## Port of the `cursor` query parse: an optional `-`, then digits only.
  ## Anything else is "no cursor", like Python's `... else None`. (Python
  ## would 500 on `"--1"` via `int()`; the port treats it as absent —
  ## a poll cursor is never worth a traceback.)
  if raw.len == 0:
    return (false, 0)
  var i = 0
  if raw[0] == '-':
    i = 1
  if i >= raw.len:
    return (false, 0)
  for c in raw[i .. ^1]:
    if c notin {'0' .. '9'}:
      return (false, 0)
  try:
    return (true, parseInt(raw))
  except ValueError:
    return (false, 0)

proc eventsSince*(home: string, cursor: int, hasCursor: bool,
                  today = ""): JsonNode =
  ## Port of `events_since`: new trace events past `cursor` (a line count
  ## into today's trace file, so every gateway's appends light the same
  ## live diagram). No cursor — or one outside `0..len` — returns just
  ## the current tail position so the browser starts fresh instead of
  ## replaying history. Bad JSON lines are skipped, like Python.
  let path = tracePath(home, today)
  if not fileExists(path):
    return %*{"events": [], "cursor": 0}
  var lines: seq[string] = @[]
  try:
    lines = readFile(path).splitLines()
  except IOError as exc:
    return %*{"events": [], "cursor": 0, "error": exc.msg}
  var events: seq[JsonNode] = @[]
  for line in lines:
    if line.strip().len == 0:
      continue
    try:
      events.add(parseJson(line))
    except JsonParsingError:
      continue
  if not hasCursor or cursor < 0 or cursor > events.len:
    return %*{"events": newJArray(), "cursor": events.len}
  var tail = newJArray()
  for ev in events[cursor .. ^1]:
    tail.add(ev)
  return %*{"events": tail, "cursor": events.len}

proc catalogSettingsOf*(d: DashboardDeps): CatalogSettings =
  ## The `Settings` fields `list_models` reads, mirrored out of the deps.
  CatalogSettings(home: d.home, provider: d.provider, model: d.model,
    smallModel: d.smallModel, baseUrl: d.baseUrl, apiKey: d.apiKey)

proc settingsInfo*(d: DashboardDeps): JsonNode =
  ## Port of `settings_api.settings_info`, as the subset this port owns:
  ## provider/model resolution, key presence (last-4 never leaves the
  ## machine — only the set flag), the curated pin shortlist with each
  ## provider's default first, disabled providers, and the two toggles.
  ## Display-only extras (typesafe key, pi presence, provider labels)
  ## stay out: only what the Settings page reads is served.
  let (model, smallModel) = modelsFor(d.provider, d.model, d.smallModel,
    d.providers)
  var pinned = newJArray()
  var seen: seq[string] = @[]
  for spec in pinnedSpecs(d.home, d.providers):
    let idx = spec.find(':')
    if idx < 0 or idx + 1 >= spec.len:
      continue
    let p = spec[0 ..< idx]
    let first = p notin seen
    if first:
      seen.add(p)
    pinned.add(%*{"provider": p, "model": spec[idx + 1 .. ^1],
                   "default": first})
  var disabled = newJArray()
  for part in d.env.getOrDefault("WAKU_DISABLED_PROVIDERS", "").split(','):
    if part.strip().len > 0:
      disabled.add(%part.strip())
  %*{
    "provider": d.provider,
    "model": model,
    "small_model": smallModel,
    "base_url": d.baseUrl,
    "custom_key_set": d.apiKey.len > 0,
    "disabled_providers": disabled,
    "pinned": pinned,
    "experimental": d.env.getOrDefault("WAKU_EXPERIMENTAL", "") in
      ["1", "true", "yes"],
    "graph_workflows": d.env.getOrDefault("WAKU_GRAPH_WORKFLOWS", "") in
      ["1", "true", "yes"],
  }

proc sessionIdleMinutes*(env: Table[string, string]): int =
  ## The dashboard-thread freshness window (`WAKU_SESSION_IDLE_MINUTES`,
  ## 60 like Python): resume the most recent dashboard thread only while
  ## it is still fresh, else mint a new dated one.
  let raw = env.getOrDefault("WAKU_SESSION_IDLE_MINUTES", "").strip()
  if raw.len > 0:
    try:
      return parseInt(raw)
    except ValueError:
      discard
  60

proc factsFor*(d: DashboardDeps, db: DbConn): StoreChoice =
  ## The store this page load reads and writes, and which backend it is.
  ##
  ## Built per request because the dashboard opens one connection per call
  ## (like Python's per-`collect()` connect) and the sqlite adapter closes
  ## over that connection. A hosted store is therefore a fresh client per
  ## request, which costs nothing here: the dashboard only lists, updates
  ## and deletes, and the one thing a hosted client carries between calls —
  ## mem0's pending `event_id` — belongs to `settle`, which the memory arena
  ## asks of its own long-lived store. (Zep carries nothing between calls:
  ## every `add` waits on its own episode before it returns.)
  # `FactStore` is a plain object, so there is no `isNil`: a filled record
  # is recognised by one of its functions, which is the same test the
  # conformance suite uses to catch a backend that forgot a method.
  if d.facts.list != nil:
    return (store: d.facts, name: "injected")
  var s = defaultSettings()
  s.home = d.home
  s.provider = d.provider
  s.model = d.model
  s.smallModel = d.smallModel
  s.semanticStore = envOrDefault("WAKU_SEMANTIC_STORE", "sqlite")
  s.mem0UserId = envOrDefault("MEM0_USER_ID", "waku")
  s.zepUserId = envOrDefault("ZEP_USER_ID", "waku")
  factStoreFor(s, db)

proc episodesFor*(d: DashboardDeps, db: DbConn): EpisodeChoice =
  ## The episode store this page load reads, and which backend it is. Same
  ## per-request shape as `factsFor`; unlike facts there is no injected
  ## seam (no test or route injects episodes), so the env always decides.
  var s = defaultSettings()
  s.home = d.home
  s.episodicStore = envOrDefault("WAKU_EPISODIC_STORE", "sqlite")
  s.obsidianVault = envOrDefault("WAKU_OBSIDIAN_VAULT", "")
  episodeStoreFor(s, db)

proc stateRows*(home: string, facts: FactStore, episodes: EpisodeStore,
               episodesSource = "sqlite"): JsonNode =
  ## Everything in Python `collect()` that reads state.db and the home
  ## files: facts, sqlite episodes, calendar, outbox, SOUL, chat counters
  ## and rows, sessions, db introspection. One open connection per call
  ## (like Python's per-`collect()` connect); a page load never builds
  ## an agent.
  proc rowStr(row: Row, i: int): string =
    ## `db_connector` hands every column back as text; nullable columns
    ## arrive empty, like Python's `None` renders in these read-only rows.
    if i < row.len: row[i] else: ""
  let db = connectDb(home)
  # Through the contract, so the memory page shows the same facts a turn
  # would retrieve — which is the whole point of having a store. The id is
  # the opaque string the contract defines, so a hosted store's UUID renders
  # here and round-trips through the JS that posts it back.
  var listed = newJArray()
  for fact in facts.list(200):
    listed.add(%*{"id": fact.id, "subject": fact.subject,
                  "content": fact.content, "source": fact.source,
                  "created_at": fact.createdAt})
  # Episodes through the contract too, so the memory page shows the same
  # events a turn would retrieve. The id is the opaque string the contract
  # defines (sqlite's counter, a vault path on obsidian) and round-trips
  # through the JS that posts it back verbatim.
  var episodeRows = newJArray()
  for e in episodes.list(200):
    episodeRows.add(%*{"id": e.id, "happened_at": e.happenedAt,
                     "summary": e.summary})
  var calendar = newJArray()
  for row in db.getAllRows(sql("SELECT title, start, \"end\", attendees, " &
      "created_at FROM calendar_events ORDER BY start")):
    calendar.add(%*{"title": rowStr(row, 0), "start": rowStr(row, 1),
                     "end": rowStr(row, 2), "attendees": rowStr(row, 3),
                     "created_at": rowStr(row, 4)})
  let chatPending = parseInt(db.getRow(sql("SELECT COUNT(*) FROM chat_log " &
    "WHERE consolidated=0"))[0])
  var chatLog = newJArray()
  for row in db.getAllRows(sql("SELECT role, content, consolidated, " &
      "source, session_id, created_at FROM chat_log " &
      "ORDER BY id DESC LIMIT 80")):
    chatLog.add(%*{"role": rowStr(row, 0), "content": rowStr(row, 1),
                    "consolidated": parseInt(rowStr(row, 2)),
                    "source": rowStr(row, 3), "session_id": rowStr(row, 4),
                    "created_at": rowStr(row, 5)})
  var chatRev = newJArray()
  for i in countdown(chatLog.len - 1, 0):
    chatRev.add(chatLog[i])
  var sessions = newJArray()
  for g in db.getAllRows(sql("SELECT session_id, COUNT(*) AS messages, " &
      "MAX(created_at) AS last_at FROM chat_log GROUP BY session_id " &
      "ORDER BY last_at DESC")):
    let sid = rowStr(g, 0)
    let first = db.getRow(sql("SELECT content FROM chat_log WHERE " &
      "session_id=? AND role='user' ORDER BY id LIMIT 1"), sid)
    let last = db.getRow(sql("SELECT role, content FROM chat_log WHERE " &
      "session_id=? ORDER BY id DESC LIMIT 1"), sid)
    var sources = newJArray()
    for r in db.getAllRows(sql("SELECT DISTINCT source FROM chat_log " &
        "WHERE session_id=?"), sid):
      sources.add(%rowStr(r, 0))
    let lastRole = if last.len > 0: last[0] else: ""
    let lastContent = if last.len > 1: last[1] else: ""
    let preview = (if lastRole == "user": "you: " else: "waku: ") &
      lastContent[0 ..< min(80, lastContent.len)]
    let firstContent = if first.len > 0: first[0] else: ""
    sessions.add(%*{"id": sid,
      "title": (if firstContent.len > 0:
        firstContent[0 ..< min(60, firstContent.len)] else: "(empty)"),
      "last": preview, "sources": sources,
      "messages": parseInt(rowStr(g, 1)), "last_at": rowStr(g, 2)})
  var tables = newJArray()
  for name in ["calendar_events", "facts", "episodes", "chat_log"]:
    var cols: seq[string] = @[]
    var types = newJObject()
    for col in db.getAllRows(sql("PRAGMA table_info(" & name & ")")):
      cols.add(col[1])
      types[col[1]] = %col[2]
    let count = parseInt(db.getRow(sql("SELECT COUNT(*) FROM " & name))[0])
    var sample = newJArray()
    for row in db.getAllRows(sql("SELECT * FROM " & name &
        " ORDER BY rowid DESC LIMIT 200")):
      var obj = newJObject()
      for i, c in cols:
        let v = rowStr(row, i)
        let t = types[c].getStr().toUpperAscii()
        if t.contains("INT"):
          try:
            obj[c] = %parseInt(v)
          except ValueError:
            obj[c] = %v
        elif t in ["REAL", "FLOAT", "DOUBLE", "NUMERIC"]:
          try:
            obj[c] = %parseFloat(v)
          except ValueError:
            obj[c] = %v
        else:
          obj[c] = %v
      sample.add(obj)
    tables.add(%*{"name": name, "columns": cols, "types": types,
                   "count": count, "sample": sample})
  var allTables: seq[string] = @[]
  for row in db.getAllRows(sql("SELECT name FROM sqlite_master WHERE " &
      "type='table' ORDER BY name")):
    allTables.add(row[0])
  var fts = newJArray()
  for t in allTables:
    if t.endsWith("_fts"):
      fts.add(%t)
  var allJ = newJArray()
  for t in allTables:
    allJ.add(%t)
  let dbPath = absolutePath(home / "state.db")
  var dbSize = 0
  try:
    dbSize = int(getFileSize(dbPath))
  except OSError:
    discard
  db.close()
  var outbox = newJArray()
  let outDir = home / "outbox"
  if dirExists(outDir):
    var names: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if kind == pcFile and path.endsWith(".txt"):
        names.add(path)
    var n = 0
    for path in sorted(names, proc(a, b: string): int = cmp(b, a)):
      if n >= 20:
        break
      var text = ""
      try:
        text = readFile(path)
      except IOError:
        continue
      outbox.add(%*{"name": lastPathPart(path),
                     "text": text[0 ..< min(400, text.len)]})
      inc n
  let soulPath = home / "SOUL.md"
  let soul = if fileExists(soulPath): readFile(soulPath) else: ""
  result = %*{"facts": listed, "episodes": episodeRows,
    "episodes_source": episodesSource, "episodes_error": "",
    "calendar": calendar, "outbox": outbox, "soul": soul,
    "chat_pending": chatPending, "chat_log": chatRev,
    "sessions": sessions,
    "db": {"path": dbPath, "size": dbSize, "tables": tables,
              "fts": fts, "all_tables": allJ}}

proc dashboardSession*(db: DbConn, nowMs: int64,
                        idleMinutes = 60): string =
  ## Port of `resume_or_new_session`: the most recent `source='dashboard'`
  ## thread still fresh (within the idle window) else a new dated one —
  ## without this every restart orphaned the visible chat under an old id.
  ## Match by source, never by id prefix: "+ New chat" mints `s-...` ids.
  let row = db.getRow(sql("SELECT session_id, MAX(created_at) AS last_at " &
    "FROM chat_log WHERE source='dashboard' GROUP BY session_id " &
    "ORDER BY last_at DESC LIMIT 1"))
  if row.len == 2 and row[0].len > 0:
    let (ok, stamp) = parseTsMs(row[1])
    if ok and nowMs - stamp <= idleMinutes.int64 * 60000:
      return row[0]
  return "dashboard-" & format(fromUnix(nowMs div 1000).utc,
    "yyyyMMdd-HHmmss")

proc skillRows*(home: string, bundled: seq[string]): JsonNode =
  ## Port of the `skills` list in Python `collect()`: every loaded skill
  ## with the fields the Skills tab edits (name, description, body, path,
  ## home-relative-or-absolute `rel`, `editable` under `<home>/skills`).
  result = newJArray()
  let homeAbs = absolutePath(home)
  let skillsAbs = homeAbs / "skills" & DirSep
  for info in listDistribSkills(home, bundled):
    var text = ""
    try:
      text = readFile(info.path)
    except IOError:
      continue
    let front = frontmatterOf(text)
    let lines = text.splitLines()
    var body = ""
    var bars = 0
    var k = 0
    for i, line in lines:
      if line.strip() == "---":
        inc bars
        if bars == 2:
          k = i + 1
          break
    if bars == 2:
      body = lines[k .. ^1].join("\n").strip()
    let p = absolutePath(info.path)
    let rel = if p.startsWith(homeAbs & DirSep): p[homeAbs.len + 1 .. ^1]
              else: p
    result.add(%*{"name": info.name,
      "description": frontmatterValue(front, "description"),
      "body": body, "path": info.path, "rel": rel,
      "editable": p.startsWith(skillsAbs)})

proc toolCatalog*(db: DbConn, home: string): JsonNode =
  ## Port of `tools_info`: the display-only capability catalog — the same
  ## local tools minus anything that would spawn a subprocess or need the
  ## network on a 5-second poll (no MCP servers, no web search: the port
  ## has no search tool yet, so the catalog lists what it can actually
  ## run). No Apple tools and nothing planned, honestly empty.
  const flagship = ["create_event", "list_events", "save_note",
    "send_message"]
  const selfmgmt = ["manage_memory", "update_soul", "create_skill"]
  var mcpNames: seq[string] = @[]
  let mcpPath = home / "mcp.json"
  if fileExists(mcpPath):
    try:
      let doc = parseJson(readFile(mcpPath))
      for s in doc.jget("servers"):
        let n = s.jget("name").getStr()
        mcpNames.add(if n.len > 0: n else: "?")
    except JsonParsingError, IOError:
      discard
  # The catalog renders DESCRIPTORS (name, description, JSON schema), so the
  # store behind `manage_memory` is never called from here: sqlite's is
  # built so the entry exists, and which backend a live agent uses is decided
  # once, in the agent's own registry. Threading a live store through the
  # whole collector would buy nothing and touch every route.
  var tools: seq[Tool] = @[makeCreateEventTool(db, home),
    makeListEventsTool(db), makeSaveNoteTool(db),
    makeSendMessageTool(home), makeUpdateSoulTool(home),
    makeManageMemoryTool(db, sqliteFactStore(db), sqliteEpisodeStore(db)),
    makeCreateSkillTool(home)]
  var items: seq[JsonNode] = @[]
  for t in tools:
    var source = "other"
    if t.name in flagship:
      source = "flagship"
    elif t.name in selfmgmt:
      source = "self-management"
    elif mcpNames.anyIt(t.name.startsWith(it & "_")):
      source = "mcp"
    items.add(%*{"name": t.name, "description": t.description,
                  "source": source})
  items.sort(proc(x, y: JsonNode): int =
    let a = x["source"].getStr() & "\x00" & x["name"].getStr()
    let b = y["source"].getStr() & "\x00" & y["name"].getStr()
    cmp(a, b))
  var catalog = newJArray()
  for item in items:
    catalog.add(item)
  var servers = newJArray()
  for n in mcpNames:
    servers.add(%n)
  result = %*{"catalog": catalog,
    "mcp": {"configured": fileExists(mcpPath), "servers": servers,
               "live": false},
    "apple_on": false, "planned": newJArray()}

proc evalSection*(home: string): (JsonNode, JsonNode) =
  ## `(eval_report, eval_history)`: the report file verbatim (null when
  ## absent) plus the last 20 eval runs, newest first, bad lines skipped.
  var report = newJNull()
  let reportPath = home / "eval_report.json"
  if fileExists(reportPath):
    try:
      report = parseJson(readFile(reportPath))
    except JsonParsingError, IOError:
      discard
  var runs: seq[JsonNode] = @[]
  let histPath = home / "eval_runs.jsonl"
  if fileExists(histPath):
    var text = ""
    try:
      text = readFile(histPath)
    except IOError:
      text = ""
    for line in text.splitLines():
      if line.strip().len == 0:
        continue
      try:
        runs.add(parseJson(line))
      except JsonParsingError:
        continue
  var history = newJArray()
  for i in countdown(runs.len - 1, max(0, runs.len - 20)):
    history.add(runs[i])
  result = (report, history)

proc providersSection*(d: DashboardDeps): JsonNode =
  ## Port of `"providers": [asdict(view) for view in list_providers()]`
  ## — the full card rows the Models page and the first-run gate read
  ## (`key`/`name` plus `fields[].configured` for the setup gate,
  ## `last4` for the key form). Secrets never leave as values, only the
  ## configured flag and the last four, like Python. Stored health and
  ## the gateway hook feed the status when present, exactly where
  ## Python reads its health store and gateway provider.
  var health: HealthFn = nil
  if not d.store.isNil:
    let store = d.store
    health = proc(key: string): IntegrationStatus =
      let (found, status) = storedHealth(store, key)
      if found:
        status
      else:
        IntegrationStatus(state: configured,
          message: "configured — not tested yet")
  result = newJArray()
  for view in listProviders(d.providers, d.env, health = health,
      gatewayStatus = d.gatewayStatus):
    var fields = newJArray()
    for f in view.fields:
      var opts = newJArray()
      for o in f.options:
        opts.add(%o)
      var labels = newJArray()
      for o in f.optionLabels:
        labels.add(%o)
      fields.add(%*{"name": f.name, "label": f.label,
                     "kind": $f.kind, "required": f.required,
                     "secret": f.secret, "configured": f.configured,
                     "last4": f.last4, "options": opts,
                     "value": f.value, "help": f.help,
                     "option_labels": labels})
    result.add(%*{"key": view.key, "group": view.group,
                   "name": view.name, "what": view.what,
                   "status": {"state": $view.status.state,
                     "message": view.status.message,
                     "checked_at": (if view.status.checkedAt.len > 0:
                       %view.status.checkedAt else: newJNull())},
                   "fields": fields,
                   "install_command": view.installCommand,
                   "setup_url": view.setupUrl})

proc traceSection*(home: string): JsonNode =
  ## `(wake_scans, trace_tail, trace_file)`: the Ops tab's inline trace —
  ## last raw lines plus the heard-everything scans. `trace_errors` stays
  ## empty: the port has no encoding-error tracking on trace reads (a bad
  ## line is skipped, never diagnosed), so claiming errors would invent
  ## them.
  let (events, files) = readTraceEvents(home)
  var scans = newJArray()
  for ev in events:
    if ev.jget("type").getStr() == "wake_scan":
      scans.add(copy(ev))
  var tail = newJArray()
  for i in countdown(events.len - 1, max(0, events.len - 18)):
    let ev = events[i]
    var detail = ""
    for key in ["user_message", "decision", "tool", "reply"]:
      let v = ev.jget(key).getStr()
      if v.len > 0:
        detail = v
        break
    tail.add(%*{"type": ev.jget("type").getStr(),
                 "ts": ev.jget("ts").getStr(), "detail": detail})
  result = %*{"wake_scans": scans, "trace_tail": tail,
    "trace_errors": newJArray(),
    "trace_file": (if files.len > 0: %lastPathPart(files[^1])
                     else: newJNull())}

proc statusPayload*(d: DashboardDeps): JsonNode =
  ## The `/api/data` blob: everything the page shows, like Python
  ## `collect()` — identity, spend (Python's `total_*` shape), health,
  ## trace pointer, the `graph` block, `turns` + `stats`, the state.db
  ## rows and db introspection, skills, tools, settings, eval report and
  ## the inline trace sections. See the module docstring for what is
  ## still honestly unwired elsewhere.
  let usage = usageSummary(d.home, d.providers)
  var byDay = newJArray()
  for row in usage.byDay:
    byDay.add(row)
  var byProvider = newJArray()
  for row in usage.byProvider:
    byProvider.add(row)
  var conns = newJArray()
  for view in listConnections(d.providers, d.env):
    conns.add(%*{"key": view.key, "state": $view.status.state,
                 "message": view.status.message})
  let tpath = tracePath(d.home, d.today)
  var traceInfo: JsonNode
  if fileExists(tpath):
    var n = 0
    try:
      for line in lines(tpath):
        if line.strip().len > 0:
          inc n
    except IOError:
      discard
    traceInfo = %*{"file": lastPathPart(tpath), "lines": n}
  else:
    traceInfo = %*{"file": "none", "lines": 0}
  let stamp = if d.nowIso.len > 0: d.nowIso
              else: format(now().utc,
                "yyyy-MM-dd'T'HH:mm:ss'+00:00'")
  # The per-message graph door: env-read, like `loadSettings`, so a page
  # load shows the flag the next turn will actually run under.
  let graphOn = d.env.getOrDefault("WAKU_GRAPH_WORKFLOWS", "") in
    ["1", "true", "yes"]
  let (turns, stats) = turnSection(d.home, d.provider, d.model,
    d.providers)
  let pageDb = connectDb(d.home)
  let pageStore = factsFor(d, pageDb).store
  let pageEpisodes = episodesFor(d, pageDb)
  let state = stateRows(d.home, pageStore, pageEpisodes.store, pageEpisodes.name)
  pageDb.close()
  let db = connectDb(d.home)
  let idleMin = sessionIdleMinutes(d.env)
  # The consolidation cadence, env-read like `loadSettings` (the deps
  # carry no Settings object, only the injected env table — which also
  # makes it pinnable in tests). Default 6, like Python.
  let consolidateEvery = block:
    let raw = d.env.getOrDefault("WAKU_CONSOLIDATE_EVERY", "").strip()
    var every = 6
    if raw.len > 0:
      try:
        every = parseInt(raw)
      except ValueError:
        discard
    every
  let nowMs = toUnix(getTime()) * 1000
  let currentSession = dashboardSession(db, nowMs, idleMin)
  let tools = toolCatalog(db, d.home)
  db.close()
  let (evalReport, evalHistory) = evalSection(d.home)
  let traces = traceSection(d.home)
  result = %*{
    "generated_at": stamp,
    "home": absolutePath(d.home),
    "provider": d.provider,
    "model": d.model,
    "usage": {"calls": usage.calls, "total_in": usage.totalIn,
              "total_out": usage.totalOut, "total_cost": usage.totalCost,
              "by_day": byDay, "by_provider": byProvider},
    "connections": conns,
    "mcp_connections": %*[tregCard(d.home)],
    "trace": traceInfo,
    "graph": graphSection(d.home, graphOn),
    "turns": turns,
    "stats": stats,
    "facts": state["facts"],
    "episodes": state["episodes"],
    "episodes_source": state["episodes_source"],
    "episodes_error": state["episodes_error"],
    "calendar": state["calendar"],
    "outbox": state["outbox"],
    "soul": state["soul"],
    "chat_pending": state["chat_pending"],
    "chat_log": state["chat_log"],
    "sessions": state["sessions"],
    "current_session": currentSession,
    "consolidate_every": consolidateEvery,
    "db": state["db"],
    "skills": skillRows(d.home, bundledSkillDirs()),
    "tools": tools,
    "settings": settingsInfo(d),
    "eval_report": evalReport,
    "eval_history": evalHistory,
    "wake_scans": traces["wake_scans"],
    "trace_tail": traces["trace_tail"],
    "trace_errors": traces["trace_errors"],
    "trace_file": traces["trace_file"],
    "providers": providersSection(d),
  }

# `/api/reveal`: open a path under WAKU_HOME in the user's editor.

proc findEditor*(env: Table[string, string],
                 probe: RevealProbeFn): string =
  ## Port of `_editor_cmd`: `$WAKU_EDITOR`, then cursor, then code. A
  ## custom editor must both be set AND resolve on PATH, like Python's
  ## `custom and shutil.which(custom)`.
  let isThere: RevealProbeFn =
    if probe.isNil:
      proc(name: string): bool = findExe(name).len > 0
    else:
      probe
  let custom = env.getOrDefault("WAKU_EDITOR", "").strip()
  if custom.len > 0 and isThere(custom):
    return custom
  for cli in ["cursor", "code"]:
    if isThere(cli):
      return cli
  ""

proc defaultEditorOpen*(argv: seq[string]) =
  ## The real `subprocess.run(check=False)`: wait for the editor/reveal
  ## command like Python does (`code`/`cursor`/`open` detach at once, so
  ## the wait is short in practice).
  discard execProcess(argv[0], args = argv[1 .. ^1],
    options = {poUsePath})

proc revealTarget*(home, rel: string, env: Table[string, string],
                   hostOs: string, probe: RevealProbeFn,
                   open: RevealOpenFn): JsonNode =
  ## Port of `reveal_path`: confine to WAKU_HOME (outside is an error,
  ## never a read), then open in the editor for files (sqlite never —
  ## editors choke on it) or reveal via the OS. Off macOS without an
  ## editor the path itself is the answer, like Python.
  let root = absolutePath(home)
  let want = if rel.len > 0: rel else: "."
  let target = absolutePath(if want.isAbsolute: want else: root / want)
  if target != root and not target.startsWith(root & DirSep):
    return %*{"error": "path is outside the .waku home"}
  if not fileExists(target) and not dirExists(target):
    return %*{"error": "not found: " & target}
  let opener = if open.isNil: defaultEditorOpen else: open
  let editor = findEditor(env, probe)
  if editor.len > 0 and fileExists(target) and
      splitFile(target).ext != ".db":
    try:
      opener(@[editor, target])
    except CatchableError as exc:
      return %*{"error": errorText(exc)}
    return %*{"ok": true, "opened_in": editor, "path": target}
  if hostOs != "macosx":
    return %*{"error": "no editor found and reveal is macOS-only — the path is " &
      target}
  try:
    if fileExists(target):
      opener(@["open", "-R", target])
    else:
      opener(@["open", target])
  except CatchableError as exc:
    return %*{"error": errorText(exc)}
  %*{"ok": true, "revealed": target}

# ---------------------------------------------------------------------------
proc sessionAction*(d: DashboardDeps, payload: JsonNode): JsonNode
proc embedPage*(staticDir, theme: string): (bool, string)
  ## Forward declarations: both are defined below beside their
  ## siblings (`sessionAction` with the POST mutations, `embedPage`
  ## with the static servers), but `handleGet` answers their routes.

proc checkoutRoot*(staticDir: string): string =
  ## The repository root beside a checkout, or "" for a bare binary
  ## (no `evals/` anywhere): what the observability payload counts the
  ## eval suites from. Measured from the static dir exactly like
  ## `memoryExampleFor`, so one checkout layout answers both.
  let root = if staticDir.len > 0: staticDir else: "."
  let cand = normalizedPath(root / ".." / ".." / "..")
  if dirExists(cand / "evals"): cand else: ""

proc observabilityPayload*(d: DashboardDeps, window: string): JsonNode =
  ## `GET /api/observability` (spec 012): the Observability page's turns,
  ## tools, memory, spend and evals, read from this home's traces and
  ## ledger ONLY — no agent, no network, nothing outside `WAKU_HOME`
  ## except counting the eval suites in a checkout. An unknown window
  ## falls back to `7d` inside the payload, like Python's `payload`.
  ## `nowMs` is injectable so a pin can date a crafted trace; 0 means
  ## now. See `portOnlyGetRoutes` for why this path is a declared port
  ## divergence.
  let nowMs = if d.nowMs > 0: d.nowMs else: int64(getTime().toUnix) * 1000
  observability.payload(d.home, d.provider, d.model, window, nowMs,
    mcpServerNames(d.home), checkoutRoot(d.staticDir), hosted = false,
    releaseFile = "", judgeModel = d.smallModel, generatedAt = d.nowIso)

proc turnJudge*(d: DashboardDeps, payload: JsonNode): JsonNode =
  ## `POST /api/turn-evals/judge {turn_id}` (spec 015): ask the small
  ## model of the provider in use whether one stored turn's reply answers
  ## its question and stays grounded in its tool outputs. The turn is read
  ## from this home's own traces, so a request cannot supply text to
  ## judge. Answers `{"score"}` or `{"error"}`; never a 500. A declared
  ## port divergence, not a Python route — see `portOnlyPostRoutes`.
  if d.turnJudgeFn.isNil:
    return %*{"error": "no judge backend is wired in the Nim port — " &
      "the small-model call behind \"Judge this turn\" is not connected " &
      "in this process"}
  let turnId = payload.jget("turn_id").getStr()
  try:
    let (events, _, _) = observability.readEvents(d.home)
    let grouped = observability.groupTurns(events)
    let (turn, judged) = turn_evals.findTurn(%grouped, %events, turnId)
    let at = if d.nowIso.len > 0: d.nowIso else: turn_evals.nowIso()
    # `small_model or model`, like Python's `judge_client`: a home with no
    # small model still judges, with the model every turn already uses.
    let model = if d.smallModel.len > 0: d.smallModel else: d.model
    let score = turn_evals.judgeTurn(d.home, turn, judged, d.turnJudgeFn,
      model, d.provider, at)
    return %*{"score": score}
  except CatchableError as exc:
    return %*{"error": exc.msg}

proc handleGet*(d: DashboardDeps, target: string): (int, string, string) =
  ## Pure GET dispatch. Returns `(status, contentType, body)`; the HTTP
  ## layer adds framing (Content-Length, no-cache on statics, SSE for
  ## the streaming units). Unknown non-API paths fall back to the SPA
  ## index, exactly like Python's trailing `else`.
  let (path, query) = splitTarget(target)
  if path == "/api/data":
    return (200, "application/json", $statusPayload(d))
  if path == "/api/models":
    let only = query.getOrDefault("provider", "")
    return (200, "application/json",
      $listModels(catalogSettingsOf(d), d.providers, d.fetch, only))
  if path == "/api/events":
    let (has, cursor) = parseCursor(query.getOrDefault("cursor", ""))
    return (200, "application/json",
      $eventsSince(d.home, cursor, has, d.today))
  if path == "/api/reveal":
    # A GET in Python (and a side effect, so it landed in 8b, not 8a):
    # open a path under WAKU_HOME in the user's editor.
    let host = if d.hostOs.len > 0: d.hostOs else: hostOS
    return (200, "application/json", $revealTarget(d.home,
      query.getOrDefault("path", ""), d.env, host, d.revealProbe,
      d.revealOpen))
  if path == "/api/observability":
    # Spec 012: the Observability page's turns, tools, memory, spend and
    # evals, read from this home's traces and ledger only. An unknown
    # window falls back to `7d`. A declared port divergence, not a
    # Python route — see `portOnlyGetRoutes`.
    return (200, "application/json",
      $observabilityPayload(d, query.getOrDefault("window", "7d")))
  if path == "/" or path == "/index.html":
    return serveIndex(d.staticDir)
  if path.startsWith("/static/"):
    return serveStatic(d.staticDir, path)
  if path == "/api/compare/history":
    # The 8c scoreboard: repriced history + aggregate over the arena's own
    # log (never state.db), via the `arena.nim` store.
    return (200, "application/json",
      $historyResponse(loadRuns(d.home), d.providers))
  if path == "/api/judgment-arena":
    # The 8d picker: suites with their questions (the teaching content,
    # never the labels), every contestant with its readiness reason,
    # and the board of past races.
    return (200, "application/json", $ %*{"suites": d.judgmentSuites,
      "contestants": judgmentContestants(d.env, d.providers),
      "runs": loadJudgmentRuns(d.home)})
  if path == "/api/memory-arena":
    # The bake-off fixture, so the Arena's Memory tab shows WHAT is
    # asked before any of it runs. No example on disk answers
    # `available: false` instead of 500ing — the wheel shape, like Python.
    try:
      let files = probeFiles(d.memoryExample, d.home,
        d.env.getOrDefault("WAKU_MEMORY_PROBES", "").strip())
      let sets = probeSets(files)
      let wanted = query.getOrDefault("probes", "").strip()
      let (found, _, fpath) = resolveTrack(wanted, sets, "")
      let fx = loadFixture(if found: fpath else: d.memoryExample,
        d.memoryExample)
      var payload = fx
      payload["available"] = %true
      payload["backends"] = %availableBackends(d.providers, d.env)
      payload["sets"] = sets
      payload["chosen"] = %(if found: wanted else: "")
      payload["models"] = arenaModels(
        pinnedSpecs(d.home, d.providers), d.providers)
      return (200, "application/json", $payload)
    except CatchableError:
      return (200, "application/json", $ %*{"available": false})
  if path == "/api/memory-arena/stores":
    # What each configured store holds right now. On demand only — every
    # hosted backend here is a live round trip, and a dashboard that
    # bills you for leaving a tab open is not one to ship.
    try:
      let files = probeFiles(d.memoryExample, d.home,
        d.env.getOrDefault("WAKU_MEMORY_PROBES", "").strip())
      let sets = probeSets(files)
      let wanted = query.getOrDefault("probes", "").strip()
      let (found, hitTrack, fpath) = resolveTrack(wanted, sets,
        query.getOrDefault("track", "").strip())
      var fx = newJNull()
      if found:
        fx = loadFixture(fpath, d.memoryExample)
      let only = query.getOrDefault("store", "").strip()
      return (200, "application/json", $storeContents(d.providers,
        d.env, hitTrack, query.getOrDefault("model", "").strip(),
        fx, only, (if only.len > 0: 500 else: 8), d.home,
        d.hostedListFn))
    except CatchableError as exc:
      return (200, "application/json", $ %*[{"store": "?",
        "error": $exc.name & ": " & exc.msg}])
  if path == "/api/session":
    # The two reads of chat history for the hosted front door (spec
    # 007 D): ?action=list, history&id or state. Writes (new, switch)
    # stay POST-only — anything else answers the reads-only error.
    let action = query.getOrDefault("action", "").strip()
    if action in ["list", "history", "state"]:
      return (200, "application/json", $sessionAction(d,
        %*{"action": action, "id": query.getOrDefault("id", "")}))
    return (200, "application/json", $(%*{"error": "GET /api/session " &
      "reads only: action=list, history or state"}))
  if path.startsWith("/api/"):
    # Safety net, not a state: every pinned GET is served above, so this
    # fires only for a path added to `pythonPinnedGet` without its route
    # (the pin comparing the two sets names it). Never the SPA shell as
    # data — the browser must not mistake it for an answer.
    if path in pythonPinnedGet:
      return (501, "application/json",
        $ %*{"error": "not yet implemented in the Nim port: " & path})
    return (404, "application/json", $ %*{"error": "unknown api path"})
  if path == "/embed/chat":
    # The chat column alone for waku.one to frame (spec 008): the page
    # posts outward only to the origins stamped into it, and `?theme=`
    # paints first paint. No-cache like Python — the console must see
    # edits, and the HTTP layer owns that header.
    let (found, page) = embedPage(d.staticDir,
      query.getOrDefault("theme", "").strip())
    if not found:
      return (404, "text/plain", "not found")
    return (200, "text/html; charset=utf-8", page)
  return serveIndex(d.staticDir)

proc bindHost*(env: Table[string, string]): string =
  ## Port of `bind_host()` minus the warning print: loopback unless
  ## `WAKU_DASHBOARD_HOST` says otherwise (the caller warns — the
  ## dashboard has no auth and the SQL console runs arbitrary SQL).
  result = env.getOrDefault("WAKU_DASHBOARD_HOST", "").strip()
  if result.len == 0:
    return defaultHost
  return result

proc dashboardPort*(env: Table[string, string]): int =
  ## Port precedence: `WAKU_DASHBOARD_PORT`, then the conventional
  ## `PORT` (deploy platforms and IDE preview panes), then 7777.
  ## The walk past a busy port is `pickPort` below.
  for name in ["WAKU_DASHBOARD_PORT", "PORT"]:
    let raw = env.getOrDefault(name, "").strip()
    if raw.len == 0:
      continue
    try:
      return parseInt(raw)
    except ValueError:
      return defaultPort
  return defaultPort

# ---------------------------------------------------------------------------
# Unit 8b: POST mutations, SSE streams, reveal, server loop.
#
# Error shape follows Python throughout: handled routes always answer 200
# with either the payload or `{"error": ...}` (Python's `do_POST` wraps
# the router in try/except and `_send`s 200 — the browser shows the
# error). Only the transport-level cases differ: unknown POST path → 404,
# broken JSON body → 400, pinned-but-later arena POST → 501.

proc sseFrame*(kind: string, ev: JsonNode): string =
  ## One SSE frame: `data: {"kind": kind, ...ev}\n\n`, exactly like
  ## Python's `f"data: {json.dumps({'kind': kind, **ev})}\n\n"` — `kind`
  ## first, the event's own fields over it (so an event `kind` wins,
  ## mirroring the `{**{'kind': kind}, **ev}` merge order).
  var obj = newJObject()
  obj["kind"] = %kind
  if ev.kind == JObject:
    for k, v in ev:
      obj[k] = v
  "data: " & $obj & "\n\n"

proc jsonStr*(node: JsonNode): string =
  ## A payload string field; anything non-string reads as absent.
  if node.kind == JString: node.getStr() else: ""

proc jsonBool*(node: JsonNode): bool =
  ## A payload toggle: JSON bool, or `"1"`/`"true"`/`"yes"` text.
  ## Absent (or anything else) means off — turning a toggle OFF sends
  ## `""`, which is falsy, so only presence-plus-content enables.
  if node.kind == JBool:
    node.getBool()
  elif node.kind == JString:
    node.getStr().strip() in ["1", "true", "yes"]
  else:
    false

proc writeDotenvKey*(path, name, value: string) =
  ## Minimal dotenv set: rewrite the `NAME=` line in place, append when
  ## missing, keep every other byte. Same shape as the 5d2 writer (plain
  ## `KEY=VALUE` lines, no quoting — toggle values are `"1"`/`""`).
  ## An empty path skips disk (tests + in-memory callers).
  if path.len == 0:
    return
  var lines: seq[string] = @[]
  if fileExists(path):
    lines = readFile(path).split('\n')
    if lines.len > 0 and lines[^1] == "":
      discard lines.pop()
  var seen = false
  var kept: seq[string] = @[]
  for line in lines:
    let eq = line.find('=')
    let key = if eq > 0: line[0 ..< eq].strip() else: ""
    if key == name:
      if not seen:
        seen = true
        kept.add(name & "=" & value)
      continue
    kept.add(line)
  if not seen:
    kept.add(name & "=" & value)
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)
  var text = kept.join("\n")
  if kept.len > 0:
    text.add("\n")
  writeFile(path, text)

proc applySettings*(d: var DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of `settings_api.apply_settings`: the experimental and
  ## graph-workflows toggles. Absent means don't touch; `""` means
  ## switch off (`if toggle:` would miss that). Connection fields and
  ## provider changes live in integrations, like Python.
  if payload.hasKey("episodic_store"):
    return %*{"error": "episodic_store is managed in Connections"}
  for (field, envName) in [("experimental", "WAKU_EXPERIMENTAL"),
      ("graph_workflows", "WAKU_GRAPH_WORKFLOWS")]:
    if payload.hasKey(field):
      let value = if jsonBool(payload[field]): "1" else: ""
      writeDotenvKey(d.dotenvPath, envName, value)
      d.env[envName] = value
  result = %*{"ok": true}
  for k, v in settingsInfo(d):
    result[k] = v

proc pinAction*(d: DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of `settings_api.pin_action`: pin / unpin / make-default on the
  ## curated `provider:model` shortlist. `default` moves the spec to the
  ## front of its provider's group (the group's first pin is its default).
  let provider = jsonStr(payload.jget("provider"))
  let model = jsonStr(payload.jget("model"))
  if provider.len == 0 or model.len == 0:
    return %*{"error": "provider and model required"}
  let action = jsonStr(payload.jget("action"))
  let spec = provider & ":" & model
  var specs: seq[string] = @[]
  for s in pinnedSpecs(d.home, d.providers):
    if s != spec:
      specs.add(s)
  if action == "pin":
    specs.add(spec)
  elif action == "default":
    var idx = specs.len
    for i, s in specs:
      let cut = s.find(':')
      if cut >= 0 and s[0 ..< cut] == provider:
        idx = i
        break
    specs.insert(spec, idx)
  elif action != "unpin":
    return %*{"error": "unknown action " & action}
  savePinned(d.home, specs)
  result = %*{"ok": true}
  for k, v in settingsInfo(d):
    result[k] = v

proc validSkillDoc*(text: string): bool =
  ## The `save_skill` frontmatter gate: a `---` block carrying `name:`
  ## and `description:`, mirroring `_parse_text` returning non-None.
  let lines = text.strip().splitLines()
  if lines.len < 3 or lines[0].strip() != "---":
    return false
  var close = -1
  for i in 1 ..< lines.len:
    if lines[i].strip() == "---":
      close = i
      break
  if close < 1:
    return false
  var hasName = false
  var hasDesc = false
  for line in lines[1 ..< close]:
    let t = line.strip().toLowerAscii()
    if t.startsWith("name:"):
      hasName = true
    if t.startsWith("description:"):
      hasDesc = true
  hasName and hasDesc

proc memoryAction*(d: DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of `memory_action`: SOUL.md + SKILL.md writes plus sqlite
  ## fact/episode CRUD against the same state.db the agent uses.
  ## `save_skill` admits SKILL.md files under `home/skills` only (Python
  ## also admits the bundled repo skills — read-only here, since the port
  ## ships one binary); the Notion episode path stays an honest error.
  let action = jsonStr(payload.jget("action"))
  if action == "save_soul":
    let text = jsonStr(payload.jget("content")).strip()
    if text.len == 0:
      return %*{"error": "SOUL cannot be empty"}
    createDir(d.home)
    writeFile(d.home / "SOUL.md", text & "\n")
    return %*{"ok": true}
  if action == "save_skill":
    let text = jsonStr(payload.jget("content")).strip()
    let dest = absolutePath(jsonStr(payload.jget("path")))
    let skillsRoot = absolutePath(d.home) / "skills"
    if lastPathPart(dest) != "SKILL.md" or
        not dest.startsWith(skillsRoot & DirSep):
      return %*{"error": "can only edit SKILL.md files inside the skills folders"}
    if not validSkillDoc(text):
      return %*{"error": "invalid SKILL.md — needs a name and description in the frontmatter"}
    createDir(parentDir(dest))
    writeFile(dest, text.strip() & "\n")
    return %*{"ok": true}
  if action == "delete_episode" and
      d.env.getOrDefault("WAKU_EPISODIC_STORE", "") == "notion":
    return %*{"error": "notion episodes are not supported in the Nim port"}
  # Episode ids are opaque strings (sqlite's counter, a vault path on
  # obsidian) and travel verbatim — parsing one as an integer is what used
  # to make a non-sqlite store unusable from this page.
  let factId = rawId(payload)
  let db = connectDb(d.home)
  try:
    let facts = factsFor(d, db).store
    let episodes = episodesFor(d, db).store
    if action == "update_fact":
      # An empty subject means "leave it alone" (Python's `subject or
      # None`); the store's adapter is where each backend absorbs it.
      return %*{"ok": facts.update(factId, jsonStr(payload.jget("content")),
                                   jsonStr(payload.jget("subject")))}
    if action == "delete_fact":
      return %*{"ok": facts.delete(factId)}
    if action == "delete_episode":
      return %*{"ok": episodes.delete(factId)}
    return %*{"error": "unknown action " & action}
  finally:
    db.close()

proc runQuery*(home: string, payload: JsonNode): JsonNode =
  ## Port of `run_query`: the read-only SQL console. Single SELECT/WITH
  ## only, one statement (no semicolons past the trailing ones), 200 rows.
  ## Python additionally opens state.db `mode=ro`; the port opens it
  ## normally but no write statement can reach the engine — the grammar
  ## gate above admits no writes — so the read-only shape holds.
  var sqlText = jsonStr(payload.jget("sql")).strip()
  while sqlText.endsWith(";"):
    sqlText = sqlText[0 ..< ^1].strip()
  if sqlText.len == 0:
    return %*{"error": "Type a SELECT query."}
  let low = sqlText.toLowerAscii()
  if not (low.startsWith("select") or low.startsWith("with")):
    return %*{"error": "Only SELECT (or WITH … SELECT) queries are allowed."}
  if ";" in sqlText:
    return %*{"error": "One statement at a time (no semicolons)."}
  let db = connectDb(home)
  try:
    var cols: DbColumns
    var data = newJArray()
    var n = 0
    for row in db.instantRows(cols, sql(sqlText)):
      if n >= 200:
        break
      var r = newJArray()
      for i in 0 ..< row.len.int:
        r.add(%row[i.int32])
      data.add(r)
      inc n
    var names = newJArray()
    for c in cols:
      names.add(%c.name)
    return %*{"columns": names, "rows": data}
  except CatchableError as exc:
    return %*{"error": exc.msg}
  finally:
    db.close()

proc historyRow(r: Row): JsonNode =
  ## One chat_log row as the dock's card: role + content + meta (null
  ## when missing or broken, like Python's `if r["meta"] else None`).
  var meta: JsonNode = newJNull()
  if r[2].len > 0:
    try:
      meta = parseJson(r[2])
    except JsonParsingError:
      discard
  %*{"role": r[0], "content": r[1], "meta": meta}

proc threadHistory*(home, sid: string): JsonNode =
  ## Port of `_thread_history`: role + content + per-turn meta for one
  ## thread (`__all__` reads the whole cross-thread timeline, newest 200
  ## flipped back to chronological like Python's `[::-1]`).
  let db = connectDb(home)
  try:
    result = newJArray()
    if sid == "__all__":
      let rows = db.getAllRows(sql"SELECT role, content, meta FROM chat_log ORDER BY id DESC LIMIT 200")
      for i in countdown(rows.high, 0):
        result.add(historyRow(rows[i]))
    else:
      let rows = db.getAllRows(sql"SELECT role, content, meta FROM chat_log WHERE session_id=? ORDER BY id",
        sid)
      for r in rows:
        result.add(historyRow(r))
    return result
  finally:
    db.close()

proc conversationList*(db: DbConn): JsonNode =
  ## Port of `session_list` in `waku/ops/dashboard.py`: one row per
  ## conversation (id, first-user-message title, message count, newest
  ## first) for the history picker and the GET `/api/session` reads.
  ## Sessions are just a label on `chat_log` rows — no new storage.
  proc cell(row: Row, i: int): string =
    if i < row.len: row[i] else: ""
  result = newJArray()
  for g in db.getAllRows(sql("SELECT session_id, COUNT(*) AS messages, " &
      "MAX(created_at) AS last_at FROM chat_log GROUP BY session_id " &
      "ORDER BY last_at DESC")):
    let sid = cell(g, 0)
    let first = db.getRow(sql("SELECT content FROM chat_log WHERE " &
      "session_id=? AND role='user' ORDER BY id LIMIT 1"), sid)
    let title = if first.len > 0: first[0].splitWhitespace().join(" ")
      else: ""
    result.add(%*{"id": sid, "title": title,
      "messages": parseInt(cell(g, 1)), "last_at": cell(g, 2)})

const embedOrigins* = ["https://www.waku.one", "https://waku.one",
  "https://dev.waku.one"]
    ## Who may frame `/embed/chat`. Port of Python's `EMBED_ORIGINS`:
    ## locally nothing sends the gateway's `X-Waku-Embed-Origins` header
    ## and Python defaults to exactly these three, so the binary serves
    ## the same default. The gateway-carried header stays Python-only —
    ## `handleGet` answers from deps, never from request headers.

proc embedPage*(staticDir, theme: string): (bool, string) =
  ## The framed chat column (`static/embed.html`, spec 008) with the
  ## embed origins stamped in and `?theme=light|dark` painted on `<html>`
  ## before first paint. From the checkout when one is configured, else
  ## from the compile-time embed; a missing page 404s like `serveIndex`.
  var page = ""
  if staticDir.len == 0:
    let (embedded, body) = embeddedAsset("embed.html")
    if not embedded:
      return (false, "")
    page = body
  else:
    let target = staticDir / "embed.html"
    if not fileExists(target):
      return (false, "")
    page = readFile(target)
  let attr = if theme in ["light", "dark"]: " data-theme=\"" &
      theme & "\"" else: ""
  return (true, page.replace("@@EMBED_ORIGINS@@",
    embedOrigins.join(" ")).replace("<html@@THEME@@>",
    "<html" & attr & ">"))

proc sessionAction*(d: DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of `session_action`. `history` is a direct db read (safe to
  ## poll live — it never touches the agent). `new`/`switch` mutate the
  ## live session, so they delegate to the injected `sessionFn` (the
  ## browser-agent lock pattern as a seam); without one, `new` still
  ## mints a dated thread and `switch` loads its history read-only.
  let action = jsonStr(payload.jget("action"))
  if action == "list":
    let dbL = connectDb(d.home)
    let conv = conversationList(dbL)
    let cur = dashboardSession(dbL, toUnix(getTime()) * 1000,
      sessionIdleMinutes(d.env))
    dbL.close()
    return %*{"ok": true, "conversations": conv, "current": cur}
  if action == "state":
    let dbS = connectDb(d.home)
    let conv = conversationList(dbS)
    let cur = dashboardSession(dbS, toUnix(getTime()) * 1000,
      sessionIdleMinutes(d.env))
    dbS.close()
    let info = settingsInfo(d)
    return %*{"ok": true, "sessions": conv, "current_session": cur,
      "settings": {"provider": info["provider"],
        "model": info["model"], "small_model": info["small_model"],
        "pinned": info["pinned"],
        "disabled_providers": info["disabled_providers"]}}
  if action == "history":
    let sid = jsonStr(payload.jget("id"))
    let sidOr = if sid.len > 0: sid else: "default"
    return %*{"ok": true, "session_id": sidOr,
                "history": threadHistory(d.home, sidOr)}
  if action == "new" or action == "switch":
    if not d.sessionFn.isNil:
      return d.sessionFn(payload)
    if action == "new":
      let sid = "s-" & format(now(), "yyyyMMdd-HHmmss")
      return %*{"ok": true, "session_id": sid, "history": newJArray()}
    let sid = jsonStr(payload.jget("id"))
    let sidOr = if sid.len > 0: sid else: "default"
    return %*{"ok": true, "session_id": sidOr,
                "history": threadHistory(d.home, sidOr)}
  return %*{"error": "unknown action " & action}

proc viewToJson*(view: IntegrationView): JsonNode =
  ## `asdict(view)` for the connections/providers answers. Views already
  ## mask secrets (last4 + flags, never values), so this is safe to send.
  var fields = newJArray()
  for f in view.fields:
    var opts = newJArray()
    for o in f.options:
      opts.add(%o)
    fields.add(%*{"name": f.name, "label": f.label, "kind": $f.kind,
      "required": f.required, "secret": f.secret,
      "configured": f.configured, "last4": f.last4, "options": opts,
      "value": f.value, "help": f.help,
      "option_labels": f.optionLabels})
  %*{"key": view.key, "group": view.group, "name": view.name,
     "what": view.what,
     "status": %*{"state": $view.status.state,
                     "message": view.status.message,
                     "checked_at": view.status.checkedAt},
     "fields": fields, "install_command": view.installCommand,
     "setup_url": view.setupUrl}

proc ensureStore(d: var DashboardDeps) =
  ## The health store, created per home on first use — the lazy global
  ## folded into the deps object, so parallel tests never share state.
  if d.store.isNil:
    d.store = newHealthStore(d.home)

proc hostOf(d: DashboardDeps): string =
  if d.hostOs.len > 0: d.hostOs else: hostOS

proc connectionsApply*(d: var DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of the `/api/connections` branch: `apply_integration` with the
  ## 5d2 seams. (Python also busts the Notion cache here — the port
  ## caches no Notion client, so there is nothing to invalidate.)
  let key = jsonStr(payload.jget("key"))
  var values = initTable[string, string]()
  let vnode = payload.jget("values")
  if vnode.kind == JObject:
    for k, v in vnode:
      values[k] = if v.kind == JString: v.getStr() else: $v
  var clear: seq[string] = @[]
  let cnode = payload.jget("clear")
  if cnode.kind == JArray:
    for item in cnode:
      clear.add(jsonStr(item))
  let force = jsonBool(payload.jget("force"))
  ensureStore(d)
  let res = applyIntegration(key, values, d.providers, d.env, d.store,
    d.dotenvPath, d.probes, clear, force, hostOf(d), d.rebuild,
    d.gatewayReload, d.gatewayStatus)
  if not res.ok:
    return %*{"ok": false, "error": res.error, "can_force": res.canForce}
  %*{"ok": true, "view": viewToJson(res.view)}

proc connectionsTest*(d: var DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of the `/api/connections/test` branch: `test_integration`
  ## against the injected probes. An unknown key raises `ValueError` in
  ## the seam — surfaced as JSON, like Python's router try/except.
  ensureStore(d)
  try:
    return viewToJson(testIntegration(jsonStr(payload.jget("key")),
      d.providers, d.env, d.store, d.probes, hostOf(d), d.gatewayStatus))
  except CatchableError as exc:
    return %*{"error": exc.msg}

proc providersApply*(d: var DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of the `/api/providers` branch: availability toggles go to
  ## `apply_provider_disabled`, everything else to `apply_provider`. The
  ## live agent is NOT rebuilt here (`agentActive` stays false): the
  ## dotenv + env update applies to the next turn's client build, the
  ## same restart-applies shape as the settings toggles.
  ensureStore(d)
  var onlyToggle = payload.hasKey("disabled")
  if payload.kind == JObject:
    for k, _ in payload.pairs:
      if k != "provider" and k != "disabled":
        onlyToggle = false
  if onlyToggle:
    let res = applyProviderDisabled(jsonStr(payload.jget("provider")),
      d.providers, d.env, d.store, d.dotenvPath,
      jsonBool(payload.jget("disabled")), hostOf(d), d.gatewayStatus)
    if not res.ok:
      return %*{"ok": false, "error": res.error}
    return %*{"ok": true, "view": viewToJson(res.view)}
  let res = applyProvider(jsonStr(payload.jget("provider")), d.providers,
    d.env, d.store, d.dotenvPath, d.home, d.providerProbe,
    jsonStr(payload.jget("key")), jsonStr(payload.jget("model")),
    jsonStr(payload.jget("small_model")), jsonStr(payload.jget("base_url")),
    jsonStr(payload.jget("custom_key")), jsonBool(payload.jget("force")),
    (if payload.hasKey("activate"): jsonBool(payload.jget("activate"))
     else: true))
  if not res.ok:
    let outp = %*{"ok": false, "error": res.error}
    if res.canForce:
      outp["can_force"] = %res.canForce
    return outp
  %*{"ok": true, "view": viewToJson(res.view)}

proc chatTurn*(d: DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of the `/api/chat` branch: one turn via the injected `chatFn`
  ## (which drives the same stream accumulator as the SSE door, so the
  ## two can never disagree — the `chat`/`chat_stream` share from Python).
  let message = jsonStr(payload.jget("message")).strip()
  if message.len == 0:
    return %*{"error": "empty message"}
  if d.chatFn.isNil:
    return %*{"error": "chat is not wired in this dashboard build"}
  try:
    return d.chatFn(message)
  except CatchableError as exc:
    return %*{"error": errorText(exc)}

proc streamChat*(d: DashboardDeps, message: string,
                 emitFrame: proc(frame: string) {.closure.}) =
  ## Port of the `/api/chat/stream` branch: harness events as SSE frames
  ## while the turn runs, a terminal `done` at the end, and a terminal
  ## `done` error when the turn raises (never a 500).
  proc emit(kind: string, ev: JsonNode) =
    emitFrame(sseFrame(kind, ev))
  if message.strip().len == 0:
    emit("done", %*{"error": "empty message"})
    return
  if d.chatStreamFn.isNil:
    emit("done",
      %*{"error": "chat streaming is not wired in this dashboard build"})
    return
  try:
    d.chatStreamFn(message.strip(), emit)
  except CatchableError as exc:
    emit("done", %*{"error": errorText(exc)})

proc streamGraph*(d: DashboardDeps, payload: JsonNode,
                   emitFrame: proc(frame: string) {.closure.}) =
  ## Port of `graph_stream`: node events as SSE, then done. Without a
  ## wired runner every workflow is unknown (the runner table arrives
  ## with the commands port) — reported as a done error like Python.
  proc emit(kind: string, ev: JsonNode) =
    emitFrame(sseFrame(kind, ev))
  let name = jsonStr(payload.jget("workflow")).strip()
  if d.graphStreamFn.isNil:
    emit("done", %*{"error": "unknown workflow '" & name & "'"})
    return
  try:
    d.graphStreamFn(payload, emit)
  except CatchableError as exc:
    emit("done", %*{"error": errorText(exc)})

proc streamCompare*(d: DashboardDeps, payload: JsonNode,
                     emitFrame: proc(frame: string) {.closure.}) =
  ## Port of the `/api/compare/stream` branch: the 8c race as SSE frames
  ## while the models run, a terminal `done` at the end, and a terminal
  ## `done` error when the race raises (never a 500). The clock override
  ## keeps stubbed races deterministic in tests.
  proc emit(kind: string, ev: JsonNode) =
    emitFrame(sseFrame(kind, ev))
  let ts = if d.nowIso.len > 0: d.nowIso else: ""
  try:
    compareStreamRun(d.home, payload, d.providers, d.raceFn, d.judgeFn,
      judgeDisplayName(payload, d.env), ts, emit)
  except CatchableError as exc:
    emit("done", %*{"error": errorText(exc)})

proc streamJudgment*(d: DashboardDeps, payload: JsonNode,
                      emitFrame: proc(frame: string) {.closure.}) =
  ## Port of the `/api/judgment-arena/stream` branch: every judge over
  ## the same cases through the same policy, answers as they land.
  proc emit(kind: string, ev: JsonNode) =
    emitFrame(sseFrame(kind, ev))
  var specs: seq[string] = @[]
  let raw = payload.jget("specs")
  if raw.kind == JArray:
    for item in raw:
      if item.kind == JString and item.getStr().strip().len > 0:
        specs.add(item.getStr())
  try:
    judgmentRace(jsonStr(payload.jget("suite")).strip(), specs,
      d.judgmentSuites, d.judgmentRaceFn, emit)
  except CatchableError as exc:
    emit("done", %*{"error": errorText(exc)})

proc streamMemory*(d: DashboardDeps, payload: JsonNode,
                    emitFrame: proc(frame: string) {.closure.}) =
  ## Port of the `/api/memory-arena/stream` branch: the same agent on
  ## the same model, only the semantic store changing. The chosen file
  ## must be one this server offered — a browser-supplied path never
  ## reaches the filesystem.
  proc emit(kind: string, ev: JsonNode) =
    emitFrame(sseFrame(kind, ev))
  try:
    let files = probeFiles(d.memoryExample, d.home,
      d.env.getOrDefault("WAKU_MEMORY_PROBES", "").strip())
    let sets = probeSets(files)
    let wanted = jsonStr(payload.jget("probes")).strip()
    let trackParam = jsonStr(payload.jget("track")).strip()
    let (found, track, fpath) = resolveTrack(wanted, sets,
      if trackParam.len > 0: trackParam else: "example")
    var fx = newJNull()
    if found:
      fx = loadFixture(fpath, d.memoryExample)
    var backs: seq[string] = @[]
    let raw = payload.jget("backends")
    if raw.kind == JArray:
      for item in raw:
        if item.kind == JString and item.getStr().strip().len > 0:
          backs.add(item.getStr())
    memoryRace(backs, track, jsonStr(payload.jget("model")).strip(),
      jsonBool(payload.jget("seed_only")), fx, d.memoryRunFn, emit)
  except CatchableError as exc:
    emit("done", %*{"error": errorText(exc)})

proc handleStream*(d: var DashboardDeps, target, body: string,
                   emitFrame: proc(frame: string) {.closure.}): bool =
  ## SSE dispatch. True when `target` is a stream route (frames were — or
  ## will be — emitted); false for everything else, which belongs to
  ## `handlePost`. An unwired arena runner emits one terminal done-error
  ## frame: the SSE shape of the honest 501.
  if target == "/api/chat/stream":
    var payload: JsonNode
    try:
      payload = parseJson(if body.len > 0: body else: "{}")
    except JsonParsingError as exc:
      emitFrame(sseFrame("done",
        %*{"error": "invalid JSON: " & exc.msg}))
      return true
    streamChat(d, jsonStr(payload.jget("message")), emitFrame)
    return true
  if target == "/api/graph/stream":
    var payload: JsonNode
    try:
      payload = parseJson(if body.len > 0: body else: "{}")
    except JsonParsingError as exc:
      emitFrame(sseFrame("done",
        %*{"error": "invalid JSON: " & exc.msg}))
      return true
    streamGraph(d, payload, emitFrame)
    return true
  if target == "/api/compare/stream":
    var payload: JsonNode
    try:
      payload = parseJson(if body.len > 0: body else: "{}")
    except JsonParsingError as exc:
      emitFrame(sseFrame("done",
        %*{"error": "invalid JSON: " & exc.msg}))
      return true
    streamCompare(d, payload, emitFrame)
    return true
  if target == "/api/judgment-arena/stream":
    var payload: JsonNode
    try:
      payload = parseJson(if body.len > 0: body else: "{}")
    except JsonParsingError as exc:
      emitFrame(sseFrame("done",
        %*{"error": "invalid JSON: " & exc.msg}))
      return true
    streamJudgment(d, payload, emitFrame)
    return true
  if target == "/api/memory-arena/stream":
    var payload: JsonNode
    try:
      payload = parseJson(if body.len > 0: body else: "{}")
    except JsonParsingError as exc:
      emitFrame(sseFrame("done",
        %*{"error": "invalid JSON: " & exc.msg}))
      return true
    streamMemory(d, payload, emitFrame)
    return true
  return false

proc handlePost*(d: var DashboardDeps, target,
                 body: string): (int, string, string) =
  ## POST dispatch. Returns `(status, contentType, body)`; handled routes
  ## answer 200 with the payload or a JSON error (never a 500). `/api/voice`
  ## takes a raw audio blob, not JSON, so it branches before the parse.
  if target == "/api/voice":
    if d.voiceFn.isNil:
      return (200, "application/json", $ %*{"error":
        "voice isn't installed in the Nim port — no local speech-to-text backend is wired"})
    try:
      return (200, "application/json", $d.voiceFn(body))
    except CatchableError as exc:
      return (200, "application/json", $ %*{"error": errorText(exc)})
  var payload: JsonNode
  try:
    payload = parseJson(if body.len > 0: body else: "{}")
  except JsonParsingError as exc:
    return (400, "application/json",
      $ %*{"error": "invalid JSON: " & exc.msg})
  if payload.kind != JObject:
    return (400, "application/json",
      $ %*{"error": "invalid JSON: expected an object"})
  try:
    if target == "/api/chat":
      return (200, "application/json", $chatTurn(d, payload))
    if target == "/api/memory":
      return (200, "application/json", $memoryAction(d, payload))
    if target == "/api/settings":
      return (200, "application/json", $applySettings(d, payload))
    if target == "/api/query":
      return (200, "application/json", $runQuery(d.home, payload))
    if target == "/api/session":
      return (200, "application/json", $sessionAction(d, payload))
    if target == "/api/pin":
      return (200, "application/json", $pinAction(d, payload))
    if target == "/api/connections":
      return (200, "application/json", $connectionsApply(d, payload))
    if target == "/api/connections/test":
      return (200, "application/json", $connectionsTest(d, payload))
    if target == "/api/providers":
      return (200, "application/json", $providersApply(d, payload))
    if target == "/api/compare/clear":
      return (200, "application/json", $compareClear(d.home))
    if target == "/api/compare/regrade":
      return (200, "application/json",
        $compareRegrade(d.home, payload, d.providers, d.judgeFn))
    if target == "/api/compare/delete_run":
      return (200, "application/json",
        $compareDeleteRun(d.home, jsonStr(payload.jget("ts")),
          d.providers))
    if target == "/api/turn-evals/judge":
      return (200, "application/json", $turnJudge(d, payload))
    if target == "/api/judgment-arena/key":
      # Jev is not a chat provider so it skips the provider list, but it
      # still needs a key — written to the user's own `.env`, never sent
      # anywhere but api.typesafe.ai, never logged.
      let key = jsonStr(payload.jget("key")).strip()
      let err = checkJudgmentKey(key)
      if err.len > 0:
        return (200, "application/json", $ %*{"error": err})
      writeDotenvKey(d.dotenvPath, "TYPESAFE_API_KEY", key)
      d.env["TYPESAFE_API_KEY"] = key
      let where = if d.dotenvPath.len > 0: d.dotenvPath else: ".env"
      return (200, "application/json",
        $ %*{"ok": true, "ready": true, "where": where})
    if target == "/api/memory-arena/clean":
      # Deletes only what a race wrote (see `cleanStores`): the same
      # probe-set validation as the race, so a browser-supplied path
      # never reaches the filesystem. Never 500s (the 8b error shape).
      try:
        let files = probeFiles(d.memoryExample, d.home,
          d.env.getOrDefault("WAKU_MEMORY_PROBES", "").strip())
        let sets = probeSets(files)
        let wanted = jsonStr(payload.jget("probes")).strip()
        let (found, track, fpath) = resolveTrack(wanted, sets,
          jsonStr(payload.jget("track")))
        var fx = newJNull()
        if found:
          fx = loadFixture(fpath, d.memoryExample)
        return (200, "application/json", $cleanStores(
          arenaBaseDir(d.home), track,
          jsonStr(payload.jget("model")).strip(), trackSeed(fx, track),
          d.hostedWipeFn))
      except CatchableError as exc:
        return (200, "application/json",
          $ %*{"error": $exc.name & ": " & exc.msg})
  except CatchableError as exc:
    return (200, "application/json", $ %*{"error": errorText(exc)})
  return (404, "application/json", $ %*{"error": "unknown api path"})

# ---------------------------------------------------------------------------
# Server loop: port walk, gateway lifecycle, accept loop.
#
# Single-threaded by design (see the divergence in the phase task file):
# one local user, and turns already serialize behind the chat seam, so a
# streaming turn briefly queues the polls behind it — the same posture as
# the single-threaded gateways. Threaded accept is a follow-up, not a
# silent behaviour change.

proc pickPort*(base: int, taken: PortTakenFn): int =
  ## Walk `base .. base+9` past busy ports, like Python's `main` loop.
  ## All ten busy raises with Python's message (en dash included).
  for port in base ..< base + 10:
    if not taken(port):
      return port
  raise newException(CatchableError,
    "no free port in " & $base & "–" & $(base + 9))

proc defaultPortTaken*(port: int, host = "127.0.0.1"): bool =
  ## True while something answers on `host:port`: a throwaway bind that
  ## closes at once. Loopback only, never egress.
  var sock = newSocket()
  try:
    sock.bindAddr(Port(port), host)
    sock.close()
    return false
  except OSError:
    return true

proc isStreamTarget*(target: string): bool =
  ## POST paths answered as `text/event-stream` (8b live + 8c/8d 501s).
  target in ["/api/chat/stream", "/api/graph/stream",
    "/api/compare/stream", "/api/judgment-arena/stream",
    "/api/memory-arena/stream"]

proc sendResponse(client: Socket, status: int, ctype, body: string) =
  ## Minimal HTTP/1.1 response, always `Connection: close` — no
  ## keep-alive, no chunking, so framing is one Content-Length.
  let reason =
    if status == 200: "OK"
    elif status == 400: "Bad Request"
    elif status == 404: "Not Found"
    elif status == 501: "Not Implemented"
    else: "OK"
  client.send("HTTP/1.1 " & $status & " " & reason & "\r\n" &
    "Content-Type: " & ctype & "\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body)

proc serveOne(srv: var DashboardServer, client: Socket) =
  ## One connection: parse the request line + headers + Content-Length
  ## body, dispatch to the pure handlers, write the answer, return. The
  ## caller closes (and swallows disconnects — the browser navigating
  ## away mid-stream is normal, like Python's BrokenPipeError pass).
  let parts = client.recvLine().strip().split(' ')
  if parts.len < 2:
    return
  let meth = parts[0]
  let target = parts[1]
  var headers = initTable[string, string]()
  while true:
    let line = client.recvLine()
    if line.strip().len == 0:
      break
    let colon = line.find(':')
    if colon > 0:
      headers[line[0 ..< colon].strip().toLowerAscii()] =
        line[colon + 1 .. ^1].strip()
  var length = 0
  try:
    length = parseInt(headers.getOrDefault("content-length", "0"))
  except ValueError:
    discard
  if length < 0:
    length = 0
  var body = ""
  var remaining = length
  while remaining > 0:
    let part = client.recv(remaining)
    if part.len == 0:
      break
    body.add(part)
    remaining -= part.len
  if meth == "GET":
    let (st, ct, b) = handleGet(srv.deps, target)
    sendResponse(client, st, ct, b)
  elif meth == "POST" and isStreamTarget(target):
    client.send("HTTP/1.1 200 OK\r\n" &
      "Content-Type: text/event-stream\r\n" &
      "Cache-Control: no-cache\r\n" &
      "Connection: close\r\n\r\n")
    proc emitFrame(frame: string) =
      client.send(frame)
    discard handleStream(srv.deps, target, body, emitFrame)
  elif meth == "POST":
    let (st, ct, b) = handlePost(srv.deps, target, body)
    sendResponse(client, st, ct, b)
  else:
    sendResponse(client, 404, "application/json",
      $(%*{"error": "unknown api path"}))

proc defaultServe*(srv: var DashboardServer) =
  ## The blocking accept loop over stdlib sockets.
  var listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(srv.port), srv.host)
  listener.listen()
  while true:
    var client: Socket
    listener.accept(client)
    try:
      serveOne(srv, client)
    except CatchableError:
      discard
    try:
      client.close()
    except CatchableError:
      discard

proc prepareDashboard*(deps: DashboardDeps,
                       taken: PortTakenFn = nil): DashboardServer =
  ## Resolve host + base port from env and walk past busy ones. A nil
  ## probe binds for real on the resolved host; tests inject a stub so
  ## preparation never touches a socket.
  let host = bindHost(deps.env)
  let base = dashboardPort(deps.env)
  let probe =
    if taken.isNil:
      let h = host
      proc(port: int): bool = defaultPortTaken(port, h)
    else:
      taken
  DashboardServer(host: host, port: pickPort(base, probe), deps: deps)

proc runDashboardCmd*(srv: var DashboardServer,
                      reconcile: GatewayHook = nil,
                      shutdown: GatewayHook = nil,
                      serve: ServeFn = nil): int =
  ## Print the URL (plus the off-loopback warning `bindHost` leaves to
  ## the caller), reconcile gateways, serve forever, shut down cleanly.
  if srv.host notin ["127.0.0.1", "::1", "localhost"]:
    echo "warning: WAKU_DASHBOARD_HOST=" & srv.host & " — the dashboard has no " &
      "authentication and its SQL console runs arbitrary SQL. " &
      "Only do this behind something that authenticates."
  echo "Waku dashboard → http://localhost:" & $srv.port &
    "  (Ctrl-C to stop)"
  if not reconcile.isNil:
    reconcile()
  try:
    if serve.isNil:
      defaultServe(srv)
    else:
      serve(srv)
  except OSError as exc:
    stderr.writeLine(exc.msg)
    return 1
  finally:
    if not shutdown.isNil:
      shutdown()
  return 0

# ---------------------------------------------------------------------------
# Live wiring: the lazy browser-gateway agent behind the chat/session
# seams. Built on first chat (like `browser_agent.get_agent`) and owned
# by the `WakuBox` — never a process global — so a failed build (no
# keys) surfaces as a chat error while the page itself keeps serving.

type
  WakuBox* = ref object
    ## Everything a live turn needs, plus the agent once built.
    providers*: seq[Provider]
    dotenvPath*: string
    settings*: Settings
    waku*: Waku
    built*: bool
    buildError*: string
    sessionId*: string
      ## The conversation thread this box owns, when it is not the
      ## dashboard's: a supervised gateway answers as its own gateway
      ## (`session_id="telegram"`, Python's `GatewayAgentRunner` pair).
      ## Empty means the `dashboard-<stamp>` thread of a browser chat.
    apiKey*: string
      ## `WAKU_API_KEY` out of the dashboard's own env table, so a
      ## gateway turn reads the same key the panel saves (the process
      ## environment is not mutated by a save). Empty means `os.getenv`,
      ## which is what a browser chat has always used.

proc ensureWaku*(box: WakuBox) =
  ## Build the shared agent once: settings → providers → client → db,
  ## with the triage graph door when enabled (the `buildCliApp` shape,
  ## lazy). Records the error instead of raising, so the dashboard can
  ## answer the chat with it.
  if box.built:
    return
  box.built = true
  try:
    var s = box.settings
    let key = if box.apiKey.len > 0: box.apiKey else: getEnv("WAKU_API_KEY")
    let client = clientFor(s, box.providers, key, box.dotenvPath)
    box.settings = s
    let db = connectDb(s.home)
    box.waku = newWaku(s, client, db)
    var liveEnv = initTable[string, string]()
    for k, v in envPairs():
      liveEnv[k] = v
    box.waku.tools = buildRegistry(db, s.home, s, liveSearchFetch,
      liveGhRun, livePiSeams(s.home, s.provider, s.model),
      liveAppleSeams(), box.waku.facts, box.waku.episodes,
      mcpRegistryTools(s.home, liveEnv,
        getTime().toUnix(), liveStdioFactory(), liveHttpPostFn()))
    wireMemory(box.waku, s, db, client, bundledSkillDirs())
    if s.graphWorkflows:
      box.waku.graphTurn = triageGraphTurn(client, s.smallModel, s.home,
        proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
          box.waku.runFullTurn(st.jget("message").getStr(), n, strm))
    box.waku.session.sessionId =
      if box.sessionId.len > 0: box.sessionId
      else: "dashboard-" & format(now(), "yyyyMMdd-HHmmss")
  except CatchableError as exc:
    box.buildError = errorText(exc)

proc donePayload*(box: WakuBox, res: LoopResult, gate, cons, route,
                  triageEv: JsonNode, latencyMs: int): JsonNode =
  ## The terminal `done` event both chat doors share (the non-streaming
  ## `chat` keeps the final one — the one-implementation rule from
  ## Python). Tool outputs classify ok/error (the `warn` middle state
  ## has no seam in `app.statusOf`, so warn-ish outputs read ok).
  let quick = route.kind == JObject and
    route.jget("target").getStr() == "quick_reply"
  var tools = newJArray()
  for c in res.toolCalls:
    let output = c.jget("output").getStr()
    var summary = output.split(". ")[0]
    if summary.len > 120:
      summary = summary[0 ..< 120]
    tools.add(%*{"tool": c.jget("tool").getStr(),
                   "args": c.jget("args"), "output": output,
                   "status": statusOf(output), "summary": summary})
  var gateObj: JsonNode = newJNull()
  if gate.kind == JObject:
    gateObj = %*{"decision": gate.jget("decision"),
                   "reason": gate.jget("reason")}
  var graphObj: JsonNode = newJNull()
  if route.kind == JObject:
    graphObj = %*{"workflow": route.jget("workflow").getStr("triage"),
      "route": %(if quick: "quick" else: "full"),
      "reason": (if triageEv.kind == JObject: triageEv.jget("reason")
                   else: %"")}
  var consObj: JsonNode = newJNull()
  if cons.kind == JObject:
    consObj = %*{"new_facts": cons.jget("new_facts")}
  %*{"reply": res.reply, "gate": gateObj, "graph": graphObj,
     "tools": tools, "consolidation": consObj,
     "iterations": res.iterations, "latency_ms": latencyMs,
     "model": (if quick: box.waku.settings.smallModel
                 else: box.waku.settings.model),
     "receipt": res.receipt}

type
  SlashConnectFn* = proc(arg, home: string): string {.closure.}
    ## `/connect <name>` without a turn: tests stub the reply, the
    ## binary signs in for real (nil below builds the live seams).
  SlashWorkflowFn* = proc(arg: string, emit: SseEmit): JsonNode {.closure.}
    ## One named workflow run: the state `composeWorkflowDone` renders.
    ## Nil runs the live wiring over `box`.

proc liveSlashConnect*(arg: string, box: WakuBox): string =
  ## `/connect` inside the chat: the dashboard runs on your machine, so
  ## the browser flow happens in-process — no shell, no terminal. Same
  ## live adapters `runConnectCmd` wires for the CLI.
  if arg.len == 0:
    return connectUsage()
  var env = initTable[string, string]()
  for k, v in envPairs():
    env[k] = v
  let nowUnix = getTime().toUnix()
  let google = GoogleSeams(openBrowser: openBrowserLive,
    waitLoopback: waitGoogleCallbackLive, exchange: exchangeGoogleLive,
    nowUnix: nowUnix)
  let livePost: HttpPostFn =
    proc(url, body, sessionId, bearer: string): HttpResult {.closure.} =
      liveHttpPost(url, body, sessionId, bearer)
  let liveFactory: StdioFactory =
    proc(spec: McpServerSpec): ExchangeFn {.closure.} =
      startStdioExchange(spec.command, spec.args, spec.env)
  let flow = oauthFlowWith(liveHttpPost, liveHttpGet, openBrowserLive,
    waitCallbackLive, liveRandInt)
  let signIn: MemorySignInFn =
    proc(home, name: string): tuple[ok: bool, msg: string,
        identity: string] {.closure.} =
      let (ok, msg) = mcpLogin(home, name, env, livePost, liveFactory,
        nowUnix, oauthFlow = flow)
      (ok, msg,
        if ok: mcpIdentity(authFilePath(home, name), nowUnix) else: "")
  return connectIntegration(arg, box.settings.home, google, signIn)

proc runSlashCommand*(message: string, box: WakuBox, emit: SseEmit,
    connect: SlashConnectFn = nil, gather: SlashWorkflowFn = nil,
    triage: SlashWorkflowFn = nil): bool =
  ## A leading `/command` from the chat box, answered without a turn.
  ## False when the message is not a command — the caller runs its turn.
  ## Runners are injected so tests never build an agent or a browser;
  ## nil runs the live wiring over `box`.
  let (isCmd, name, arg) = parseCommand(message)
  if not isCmd:
    return false
  proc doneOk(reply: string): JsonNode =
    %*{"reply": reply, "tools": newJArray(), "iterations": 0,
        "latency_ms": 0, "gate": newJNull()}
  if name == "connect":
    let reply =
      if connect != nil: connect(arg, box.settings.home)
      else: liveSlashConnect(arg, box)
    emit("done", doneOk(reply))
    return true
  if name in ["graphs", "help", "?"]:
    emit("done", doneOk(describeCommands()))
    return true
  let t0 = now()
  let ms = proc(): int = int((now() - t0).inMilliseconds)
  proc fail(reply: string) =
    emit("done", %*{"reply": reply, "tools": newJArray(),
                       "iterations": 0, "gate": newJNull()})
  if name == "gather":
    var state: JsonNode
    try:
      if gather != nil:
        state = gather(arg, emit)
      else:
        box.ensureWaku()
        if box.buildError.len > 0:
          emit("done", %*{"error": box.buildError})
          return true
        state = runGather(box.waku,
          proc(kind: string, ev: JsonNode) {.closure.} = emit(kind, ev))
      if arg.len > 0:
        state["ignored_argument"] = %arg
    except CatchableError as exc:
      fail("`/gather` failed: " & errorText(exc))
      return true
    emit("done", composeWorkflowDone(state, "gather", ms()))
    return true
  if name == "triage":
    if arg.len == 0:
      emit("done", doneOk(triageUsage))
      return true
    var state: JsonNode
    try:
      if triage != nil:
        state = triage(arg, emit)
      else:
        box.ensureWaku()
        if box.buildError.len > 0:
          emit("done", %*{"error": box.buildError})
          return true
        let turn = triageGraphTurn(box.waku.client,
          box.waku.settings.smallModel, box.waku.settings.home,
          proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
            box.waku.runFullTurn(st.jget("message").getStr(), n, strm))
        let (answered, res) = turn(arg,
          proc(kind: string, ev: JsonNode) {.closure.} = emit(kind, ev),
          true)
        state = %*{"digest": res.reply, "answered": answered}
    except CatchableError as exc:
      fail("`/triage` failed: " & errorText(exc))
      return true
    emit("done", composeWorkflowDone(state, "triage", ms()))
    return true
  emit("done", doneOk(unknownCommandReply(name)))
  return true

proc liveProviderProbe*(providers: seq[Provider], home: string,
    fetch: catalog.FetchFn): ProbeFn =
  ## Port of `_provider_probe`: list this provider's models with no
  ## cache — a Save validates the candidate key/endpoint, never a
  ## cached result. A listed error raises, like Python's `ValueError`.
  result = proc(values: Table[string, string]) {.closure.} =
    var name = ""
    for p in providers:
      if p.keyEnv.len > 0 and values.hasKey(p.keyEnv):
        name = p.name
        break
    if name.len == 0:
      return
    let listed = listModels(CatalogSettings(home: home, provider: name,
      model: "", smallModel: "", baseUrl: "", apiKey: ""), providers,
      fetch, onlyProvider = name, useCache = false)
    if listed.jget("error").getStr().len > 0:
      raise newException(ValueError, listed.jget("error").getStr())

proc closeQuietly(sock: Socket) =
  ## Close without ever raising, so a `finally` that calls it cannot
  ## swallow whatever was unwinding (the `test_tls` finally-shape gate
  ## scans for `except` inside `finally` blocks and fails on it).
  try:
    sock.close()
  except OSError:
    discard

proc liveProbes*(): Table[string, ProbeFn] =
  ## The portable connection probes: Tavily (one search call), OTLP
  ## (one TCP dial), and the two Apple automation checks. Notion needs
  ## its SDK and Google Calendar needs its API client — both stay
  ## honestly unprobed, like the dashboard says.
  result["tavily"] =
    proc(values: Table[string, string]) {.closure.} =
      let key = values.getOrDefault("TAVILY_API_KEY", "")
      let body = $(%*{"api_key": key, "query": "health check",
                       "max_results": 1})
      let (ok, text) = liveSearchFetch(tavilyUrl, "POST", body, "")
      if not ok:
        raise newException(ValueError,
          "Tavily unreachable (network or TLS): " & text)
      try:
        discard parseJson(text)
      except JsonParsingError as exc:
        raise newException(ValueError, "Tavily answered badly: " &
          exc.msg)
  result["otel"] =
    proc(values: Table[string, string]) {.closure.} =
      var endpoint = values.getOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT",
        "").strip()
      if "://" in endpoint:
        endpoint = endpoint.split("://", 1)[1]
      for bad in ["/", "?", "#", "@"]:
        if bad in endpoint:
          raise newException(ValueError,
            "OTLP endpoint must be host:port (for example localhost:4317)")
      let parts = endpoint.split(':')
      if parts.len != 2:
        raise newException(ValueError,
          "OTLP endpoint must be host:port (for example localhost:4317)")
      var port = 0
      try:
        port = parseInt(parts[1])
      except ValueError:
        raise newException(ValueError,
          "OTLP endpoint must be a valid host:port")
      if parts[0].len == 0 or port <= 0 or port > 65535:
        raise newException(ValueError,
          "OTLP endpoint must be host:port (for example localhost:4317)")
      var sock = newSocket()
      try:
        sock.connect(parts[0], Port(port), timeout = 3000)
      except OSError as exc:
        closeQuietly(sock)
        raise newException(ValueError,
          "OTLP collector refused: " & exc.msg)
      finally:
        closeQuietly(sock)
  result["apple_calendar"] =
    proc(values: Table[string, string]) {.closure.} =
      if hostOS != "macosx":
        raise newException(ValueError, "Apple Calendar probe is macOS-only.")
      let script = "tell application \"Calendar\"\n" &
        "  repeat with cal in calendars\n" &
        "    try\n" &
        "      if writable of cal then return name of cal\n" &
        "    end try\n" &
        "  repeat\nend tell\nreturn \"\""
      let res = runProcess(@["osascript", "-e", script],
        timeoutSec = 15)
      if res.timedOut:
        raise newException(ValueError,
          "Apple Calendar probe timed out after 15s; Calendar.app may " &
          "be slow or waiting for Automation permission.")
      if res.code != 0:
        let detail = res.stderr.strip()
        raise newException(ValueError, "Apple Calendar probe failed: " &
          (if detail.len > 0: detail[0 ..< min(200, detail.len)]
           else: "failed"))
      if res.stdout.strip().len == 0:
        raise newException(ValueError,
          "Apple Calendar has no writable calendars.")
  result["apple_tools"] =
    proc(values: Table[string, string]) {.closure.} =
      if hostOS != "macosx":
        raise newException(ValueError, "Apple Tools probe is macOS-only.")
      var failures: seq[string] = @[]
      for app in probeApps:
        let res = runProcess(@["osascript", "-e",
          "tell application \"" & app & "\" to return version"],
          timeoutSec = 8)
        if res.timedOut or res.code != 0:
          let detail = if res.timedOut: "timed out"
                       else: res.stderr.strip()
          failures.add(app & ": " & detail)
      if failures.len > 0:
        raise newException(ValueError, "Apple Tools probe failed: " &
          failures.join("; "))

proc liveGraphStream*(box: WakuBox, payload: JsonNode,
    emit: SseEmit) =
  ## Port of `graph_stream`: run the named workflow, streaming the
  ## engine's own events (never node output, so a digest cannot leak
  ## into a frame), then done. Unknown names answer honestly, like the
  ## pinned-but-later routes.
  let name = jsonStr(payload.jget("workflow")).strip()
  if name != "gather" and name != "triage":
    emit("done", %*{"error": "unknown workflow '" & name & "'"})
    return
  box.ensureWaku()
  if box.buildError.len > 0:
    emit("done", %*{"error": box.buildError})
    return
  proc forward(kind: string, ev: JsonNode) {.closure.} = emit(kind, ev)
  try:
    if name == "gather":
      let state = runGather(box.waku, forward)
      emit("done", %*{"workflow": name,
        "digest": state.jget("digest").getStr()[0 ..< min(4000,
          state.jget("digest").getStr().len)],
        "draft_path": state.jget("draft_path").getStr(),
        "errors": state.jget("errors")})
    else:
      emit("done", %*{"workflow": name, "digest": triageUsage,
        "draft_path": "", "errors": newJObject()})
  except CatchableError as exc:
    emit("done", %*{"error": errorText(exc)})

proc liveChatStreamFn*(box: WakuBox): ChatStreamFn =
  ## `chat_stream` against the live agent: gate/tool/text events as they
  ## happen (the browser lights the diagram from these), then done.
  result = proc(message: string, emit: SseEmit) {.closure.} =
    if runSlashCommand(message, box, emit):
      return
    box.ensureWaku()
    if box.buildError.len > 0:
      emit("done", %*{"error": box.buildError})
      return
    var gate: JsonNode = newJNull()
    var cons: JsonNode = newJNull()
    var route: JsonNode = newJNull()
    var triageEv: JsonNode = newJNull()
    proc observer(kind: string, ev: JsonNode) =
      if kind == "gate":
        gate = ev
      elif kind == "consolidation":
        cons = ev
      elif kind == "route":
        route = ev
      elif kind == "triage":
        triageEv = ev
      emit(kind, ev)
    let t0 = now()
    try:
      let res = box.waku.respond(message, observer, "dashboard", true)
      emit("done", donePayload(box, res, gate, cons, route, triageEv,
        int((now() - t0).inMilliseconds)))
    except CatchableError as exc:
      emit("done", %*{"error": errorText(exc)})

proc liveChatFn*(box: WakuBox): ChatFn =
  ## `chat` against the live agent: drive the streaming turn, keep done.
  ## A leading `/command` is answered by the slash table inside the
  ## stream (node events pass through, only `done` is kept).
  result = proc(message: string): JsonNode {.closure.} =
    # No eager `ensureWaku` here: the stream answers `/command` without
    # an agent, and builds it (or its error) only when a turn needs one
    # — the one-implementation rule from Python's shared accumulator.
    var final: JsonNode = newJObject()
    proc collect(kind: string, ev: JsonNode) =
      if kind == "done":
        final = ev
    liveChatStreamFn(box)(message, collect)
    return final

proc liveSessionFn*(box: WakuBox): SessionFn =
  ## `session_action` against the live agent: `history` never touches it
  ## (direct db read, safe to poll); `new`/`switch` move its session.
  result = proc(payload: JsonNode): JsonNode {.closure.} =
    let action = jsonStr(payload.jget("action"))
    if action == "history":
      let sid = jsonStr(payload.jget("id"))
      let sidOr = if sid.len > 0: sid else: "default"
      return %*{"ok": true, "session_id": sidOr,
                  "history": threadHistory(box.settings.home, sidOr)}
    box.ensureWaku()
    if box.buildError.len > 0:
      return %*{"error": box.buildError}
    if action == "new":
      let sid = "s-" & format(now(), "yyyyMMdd-HHmmss")
      box.waku.session.startNew(sid)
      return %*{"ok": true, "session_id": sid, "history": newJArray()}
    if action == "switch":
      let sid = jsonStr(payload.jget("id"))
      let sidOr = if sid.len > 0: sid else: "default"
      box.waku.session.switch(sid)
      return %*{"ok": true, "session_id": sidOr, "history":
        threadHistory(box.waku.settings.home, sidOr)}
    return %*{"error": "unknown action " & action}

proc liveCatalogFetch*(url, key: string): string =
  ## The catalog `FetchFn` with a live client: stdlib GET with a 15s
  ## timeout. Non-2xx raises, like the transport — `listModels` turns it
  ## into the listed=false shape, never a 500. The client comes from
  ## `http.nim`'s one helper, so a catalog URL gets the TLS context in a
  ## `-d:wakuTls` build.
  var client = newTlsHttpClient(timeout = 15000)
  try:
    if key.len > 0:
      client.headers = newHttpHeaders({"Authorization": "Bearer " & key})
    return client.getContent(url)
  finally:
    client.close()

proc findStaticDir*(): string =
  ## Locate the dashboard frontend in a checkout, trying the caller's
  ## working directory first (repo checkout layout) and the binary
  ## directory last — the same shape as the provider-registry lookup in
  ## `waku.nim`. `""` when no checkout is on disk anywhere: that is the
  ## shipped-binary case, and the compile-time embed answers the SPA
  ## routes instead of the filesystem.
  for candidate in ["waku/ops/static", "../waku/ops/static",
      "../../waku/ops/static"]:
    if dirExists(candidate):
      return candidate
  let besideBin = getAppDir() / "static"
  if dirExists(besideBin):
    return besideBin
  ""

proc memoryExampleFor*(staticDir: string): string =
  ## The shipped probe fixture next to a checkout's static dir
  ## (`<repo>/evals/memory_arena.json`), or "" in a bare binary — then
  ## `/api/memory-arena` answers `available: false`, like the pip wheel
  ## that never shipped `evals/`. With no checkout there is no directory
  ## to walk up from, so the same three levels are measured from the
  ## working directory: the spot a developer's checkout runs in.
  let root = if staticDir.len > 0: staticDir else: "."
  let cand = normalizedPath(root / ".." / ".." / ".." / "evals" /
    "memory_arena.json")
  if fileExists(cand): cand else: ""

proc liveGraphStreamFn*(box: WakuBox): GraphStreamFn =
  ## The `GraphStreamFn` seam over `liveGraphStream`.
  result = proc(payload: JsonNode, emit: SseEmit) {.closure.} =
    liveGraphStream(box, payload, emit)

proc buildDashboardDeps*(providers: seq[Provider], settings: Settings,
                         dotenvPath: string): DashboardDeps =
  ## Live deps for the server: process env as the table, live catalog
  ## fetch, the lazy agent box behind the chat/session/graph seams, and
  ## the live connection probes. No network, no disk writes, no agent
  ## build here — first chat (or race, or probe) pays.
  var env = initTable[string, string]()
  for k, v in envPairs():
    env[k] = v
  let box = WakuBox(providers: providers, dotenvPath: dotenvPath,
    settings: settings)
  let staticDir = findStaticDir()
  DashboardDeps(home: settings.home, staticDir: staticDir,
    provider: settings.provider, model: settings.model,
    smallModel: settings.smallModel, baseUrl: settings.baseUrl,
    apiKey: settings.apiKey, providers: providers, env: env,
    fetch: liveCatalogFetch, today: "", nowIso: "",
    dotenvPath: dotenvPath, hostOs: "", chatFn: liveChatFn(box),
    chatStreamFn: liveChatStreamFn(box),
    graphStreamFn: liveGraphStreamFn(box), voiceFn: nil,
    sessionFn: liveSessionFn(box), revealProbe: nil, revealOpen: nil,
    raceFn: nil, judgeFn: nil, turnJudgeFn: nil, memoryRunFn: nil, judgmentRaceFn: nil,
    hostedListFn: nil, hostedWipeFn: nil,
    judgmentSuites: suiteList(allSuites()),
    memoryExample: memoryExampleFor(staticDir), store: nil,
    probes: liveProbes(),
    providerProbe: liveProviderProbe(providers, settings.home,
      liveCatalogFetch),
    rebuild: nil, gatewayReload: nil,
    gatewayStatus: nil)

# ---------------------------------------------------------------------------
# Gateway supervision (7d2-3) — the supervisor `dashboard.py::main` builds,
# the seams the connections panel reads, and the ONE serve loop that stands
# in for the three threads Python gives this process.
#
# Python builds `GatewaySupervisor({"telegram": start_telegram, ...},
# {key: field names for the gateway rows})`, registers its `status` as the
# status provider and its `reconcile` as the reloader, reconciles before
# `serve_forever()` and shuts down after. The port does the same with
# `gateway.nim`'s `Supervisor`, the three 7d1/7d2 starters, and
# `integrations.gatewayEnvFields` for the fields — the same registry table
# the panel renders, so a row and its fingerprint cannot drift apart.
#
# What an idle pass pays is `dashboardIdleWaitMs`, grown per empty telegram
# poll up to a ceiling (`telegramIdleWaitMs`): Python's poller waits inside
# a long-poll on its own thread, and this loop's `timeout=0` poll would
# otherwise ask Telegram four times a second all day.
#
# The three differences are all the price of one thread, all documented at
# the proc that owns them: `gatewayTick` pumps telegram's long-poll and one
# step of the Discord gateway between browser requests (Python runs both on
# daemon threads), `multiplexServe` answers the WhatsApp webhook off the
# same loop (`TakeConn`), and every take is a select with a bounded wait so
# a pass never parks. A gateway TURN still blocks the dashboard while it
# runs — the posture 8b already accepted for streaming chat turns.

const
  telegramStartingLine* = "(telegram) starting:"
    ## Python's `start_in_background` first line, printed by the wiring here
    ## (7d1's `telegramStarter` deliberately stays about the lifecycle).
  discordStartingLine* = "(discord) starting:"
    ## The same line for the Discord gateway.
  discordDialBudget* = 5
    ## Consecutive dials one supervised gateway may burn before it stops
    ## itself. `discordServe` caps a command's dials the same way; here the
    ## cap keeps a gateway that accepts and drops every session from
    ## re-dialling every pass forever, which is the same hot-loop shape
    ## that cap exists to prevent.
  discordDialBudgetLine* = "(discord) gave up after " & $discordDialBudget &
    " connections in a row — save the settings or restart the dashboard"
    ## Said once, plainly, when the budget runs out (the panel reads the
    ## stopped handle; this line says why nobody is answering).
  gatewayTickPollTimeout* = 0
    ## The dashboard's telegram long-poll, in seconds: ZERO, so a poll
    ## returns whatever Telegram already has and never holds a browser
    ## request behind a server-side wait. Python's poller thread can afford
    ## its 30 (and PTB's 10); a tick between requests cannot.
  dashboardIdleWaitMs* = 250
    ## What a pass that found nothing pays before looking again. This is the
    ## sleep that stands in for "three threads": a burst of requests is
    ## drained back-to-back (a pass that served one skips the wait), and an
    ## idle pass pays this until `telegramIdleWaitMs` grows it.
  telegramBackoffFactor* = 2
    ## How much longer each FURTHER empty telegram poll makes an idle pass
    ## wait. Python never needed it: its poller is a thread blocked in a
    ## 30-second long-poll, so an idle bot waits inside `getUpdates` instead
    ## of asking again. The dashboard's poll is `timeout=0` between browser
    ## requests, so an idle bot asks about updates four times a second all
    ## day — which is what this stops, at the cost of latency nobody
    ## notices on an idle bot (Telegram queues the update; the poll finds
    ## it).
  telegramBackoffMaxMs* = 2000
    ## The ceiling on that wait: at most one `getUpdates` every two seconds,
    ## so an idle bot spends 30 requests a minute instead of 240. The cost of
    ## the ceiling is LATENCY and never a lost message — an update that
    ## arrives is still answered, within this window. A busy bot never pays
    ## it, because any activity resets the counter.
  discordTickTimeoutMs* = 250
    ## One read of the Discord socket per pass: long enough not to spin,
    ## short enough that a heartbeat's answer is on its way within a tick.

type
  GatewayRespondFn* = proc(source: string): RespondFn {.closure.}
    ## The agent turn for one named gateway. Built ONCE per rig (Python
    ## builds its runner inside `start_in_background`) and lazily per turn:
    ## a dashboard with no keys set never builds an agent, and a build
    ## failure surfaces as the turn's error instead of a dead gateway.
  GatewayHooks* = object
    ## Everything the supervised gateways reach outside this module. A
    ## process passes the real clients; a test passes recorded ones, so
    ## `nimble test` still opens zero sockets (the Bot API, the Graph API,
    ## the Discord REST client, the gateway dial and the webhook bind are
    ## all here).
    envOf*: proc(): Table[string, string] {.closure.}
      ## The credentials, read LIVE on every call — Python's `os.environ`,
      ## the same live mapping the connections panel writes. It is a seam
      ## and not a stored `Table` for one measured reason: a Nim `Table` is
      ## a VALUE whose assignment copies its buffer, so a rig holding a copy
      ## of the panel's env would go on reading the values it was built with
      ## — saving a brand-new bot token would reconcile against the table
      ## from startup and look like nothing had happened until a restart.
      ## Returning a fresh copy per call costs one header and buys the one
      ## property that matters: it is read where the panel writes it.
    logger*: LogFn
      ## The terminal mirror both `you › …` and every failure line uses.
    respond*: GatewayRespondFn
    telegramHttp*: TelegramHttpFn
    whatsappHttp*: WhatsappHttpFn
    discordHttp*: DiscordHttpFn
    discordDial*: DiscordDialFn
    openWebhook*: proc(host: string, port: int): Socket {.closure.}
      ## The webhook bind itself, so the bind-FAILURE path (a busy port,
      ## which Python's `start_in_background` also raises) is pinnable
      ## without a socket. Nil means the real bind; it raises `OSError`
      ## when the port is taken, and the supervisor reports that as the
      ## gateway's error and rolls the save back.
    now*: DiscordNowFn
      ## The heartbeat/spend clock; nil means `epochTime()`, like
      ## `discordRun`'s own default.
    webhookHost*: string
    webhookPort*: int
      ## Where the supervised WhatsApp listener binds — Python's
      ## `("0.0.0.0", 5000)`, kept as parameters so a second gateway (or a
      ## test) can move it.
  GatewayRig* = ref object
    ## One supervised dashboard: the supervisor, the three handles it
    ## supervises, their agent turns, and the three sockets the loop owns
    ## (browser listener, webhook listener, gateway socket). A `ref` because
    ## the seams outlive the call that built them and the handles' runners
    ## are mutated by turns.
    sup*: Supervisor
    hooks*: GatewayHooks
    logger*: LogFn
    telegram*: TelegramLive
    whatsapp*: WhatsappLive
    discord*: DiscordLive
    telegramTurn*: RespondFn
    whatsappTurn*: RespondFn
    discordTurn*: RespondFn
    browser*: Socket
    webhook*: Socket
    gateway*: DiscordWire
    discordIdleMs*: int
    discordDials*: int
    telegramEmptyPolls*: int
      ## CONSECUTIVE telegram polls that ran no turn, and what the idle wait
      ## is grown from. Counted where the poll runs and cleared by any
      ## gateway activity (a turn, a webhook request, a frame off the
      ## Discord socket) — the "consecutive" part is what keeps a bot that
      ## speaks every few minutes at the base cadence.
      ##
      ## A poll that never ran (nothing configured, a stopped poller) is not
      ## counted and clears nothing: no evidence, no verdict. The browser
      ## channel is deliberately NOT activity here — it is what this loop
      ## serves, not what the bot is doing, so a person refreshing the panel
      ## must not hand the bot back its four-polls-a-second cadence. The wait
      ## is a `select` over the listeners, so their request still wakes the
      ## loop the moment it lands, whatever the window says.

proc loggerOf*(hooks: GatewayHooks): LogFn =
  ## The terminal mirror, or the plain stdout default every gateway command
  ## uses (`gatewayLog(nil)` in `waku.nim`) when no seam was injected.
  if hooks.logger.isNil:
    result = proc(line: string) = echo line
  else:
    result = hooks.logger

proc gatewayReportStatus*(report: GatewayReport): IntegrationStatus =
  ## Python's handle `status()` shape (`GatewayReport` → the panel's
  ## status): `CONNECTED` when the gateway is healthy, `ERROR` plus its
  ## message otherwise. No `installedButUnconfigured` here — a gateway
  ## that never became ready says so in the message (`"starting"`).
  if report.ok:
    return IntegrationStatus(state: connected)
  return IntegrationStatus(state: error, message: report.message)

proc closeWebhook(rig: GatewayRig) =
  ## The listener goes with the handle (`server_close()` in Python, folded
  ## into the stop seam): a webhook with no server behind it would answer
  ## requests the supervisor believes are stopped.
  if rig.webhook.isNil:
    return
  try:
    rig.webhook.close()
  except CatchableError:
    discard
  rig.webhook = nil

proc closeBrowser(rig: GatewayRig) =
  ## The browser listener goes too at shutdown: the loop has already
  ## returned, and leaving the port bound would make the next start walk
  ## past it for no reason.
  if rig.browser.isNil:
    return
  try:
    rig.browser.close()
  except CatchableError:
    discard
  rig.browser = nil

proc dropGateway(rig: GatewayRig) =
  ## The Discord connection goes with its handle, for the same reason the
  ## webhook listener does. Divergence worth naming: `DiscordWire` is the
  ## protocol's transport (a recv closure, a send closure and the read
  ## buffer) and has no `close` — the socket belongs to whoever dialled it,
  ## which `liveDiscordWire` documents. So dropping the reference is all
  ## the supervisor can do here, and all it needs to: a dropped wire is
  ## never pumped again, and the next dial opens its own socket.
  rig.gateway = nil
  rig.discordIdleMs = 0

proc stopHook*(rig: GatewayRig): StopFn =
  ## The supervisor's single `stop` seam, dispatched by key over 7d1's
  ## three adapters — and the one place a stopped gateway's sockets go,
  ## which is Python's `shutdown()` closing the server it started.
  result = proc(key: string) {.closure.} =
    case key
    of "telegram":
      telegramStopFn(rig.telegram)(key)
    of "discord":
      discordStopFn(rig.discord)(key)
      rig.dropGateway()
    of "whatsapp":
      whatsappStopFn(rig.whatsapp)(key)
      rig.closeWebhook()
    else:
      discard   # an unknown key has nothing to stop, like Python's `.get`

proc statusSeam(rig: GatewayRig): StatusFn =
  ## One `statusOf` for the supervisor's `reconcile`/`status`, over the
  ## three handle adapters. A raising status becomes an error report
  ## inside `supervisorStatus`, exactly like Python's `except`.
  result = proc(key: string): GatewayReport {.closure.} =
    case key
    of "telegram": telegramStatusFn(rig.telegram)(key)
    of "discord": discordStatusFn(rig.discord)(key)
    of "whatsapp": whatsappStatusFn(rig.whatsapp)(key)
    else: raise newException(CatchableError, "unknown gateway: " & key)

proc liveWebhookBind*(host: string, port: int): Socket =
  ## The real webhook bind: `0.0.0.0:5000` by default, exactly Python's
  ## `ThreadingHTTPServer(("0.0.0.0", 5000), handler)`. Raises `OSError`
  ## when the port is busy — the failure the supervisor is built to report.
  var listener = newSocket()
  try:
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(port), host)
    listener.listen()
  except CatchableError:
    if not listener.isNil:
      try:
        listener.close()
      except CatchableError:
        discard
    raise
  listener

proc openWebhook(rig: GatewayRig) =
  ## Bind the supervised webhook listener: Python's
  ## `ThreadingHTTPServer(("0.0.0.0", 5000), handler)` inside
  ## `start_in_background`, with the port's own two startup lines (the
  ## third, `Ctrl-C to stop.`, belongs to the standalone command — the
  ## dashboard has its own banner). A bind failure RAISES on purpose: the
  ## supervisor reports it as that gateway's error and rolls the previous
  ## instance back, which is what its docstring promises.
  let bindFn = if rig.hooks.openWebhook.isNil: liveWebhookBind
               else: rig.hooks.openWebhook
  rig.webhook = bindFn(rig.hooks.webhookHost, rig.hooks.webhookPort)
  rig.logger(listeningLine(rig.hooks.webhookHost, rig.hooks.webhookPort))
  rig.logger(webhookUrlLine)

proc env*(rig: GatewayRig): Table[string, string] =
  ## The credentials as they are RIGHT NOW (a fresh copy of what the panel
  ## has written). Reads always go through here — see `GatewayHooks.envOf`
  ## for why the rig stores no table of its own.
  rig.hooks.envOf()

proc rigStarter(rig: GatewayRig, key: string): StarterFn =
  ## The supervisor's starter for one gateway: the gateway's own 7d1/7d2
  ## adapter plus what only this wiring can do — build the agent turn the
  ## way `start_in_background` builds its runner (a FRESH one per start),
  ## print the startup lines it prints (a starter stays about the
  ## lifecycle), and bind the webhook socket on whatsapp. `false` is
  ## Python's `None` (not configured, quietly); a raising bind is the
  ## failure the supervisor reports and rolls back.
  result = proc(): bool {.closure.} =
    let turn = rig.hooks.respond(key)
    case key
    of "telegram":
      rig.telegramTurn = turn
      if not telegramStarter(rig.telegram, rig.env(), rig.telegramTurn,
          rig.hooks.telegramHttp, rig.logger)():
        return false
      rig.telegramEmptyPolls = 0    # a fresh poller owes nobody a backoff
      rig.logger(telegramStartingLine)
      rig.logger(posture(parseAllowedIds(
        rig.env().getOrDefault("TELEGRAM_ALLOWED_USER", ""))))
      return true
    of "discord":
      if not discordStarter(rig.discord, rig.env())():
        return false
      rig.discordTurn = turn
      rig.logger(discordStartingLine)
      rig.logger(describePosture(
        parseDiscordIds(rig.env().getOrDefault("DISCORD_ALLOWED_USER", "")),
        parseDiscordIds(rig.env().getOrDefault("DISCORD_ALLOWED_CHANNEL", "")),
        rig.env().getOrDefault("DISCORD_HOME", ""),
        rig.env().getOrDefault("DISCORD_MAX_TURNS_PER_HOUR", "30")))
      return true
    of "whatsapp":
      rig.whatsappTurn = turn
      if not whatsappStarter(rig.whatsapp, rig.env(), rig.whatsappTurn,
          rig.hooks.whatsappHttp, rig.logger)():
        return false
      rig.openWebhook()
      return true
    else:
      return false

proc newGatewayRig*(hooks: GatewayHooks): GatewayRig =
  ## The supervisor `dashboard.py::main` builds: three starters, the
  ## registry's gateway fields, one stop seam — plus the three handles and
  ## the agent turns they answer with. Builds nothing and starts nothing:
  ## `reconcileHook` is the caller (Python reconciles after the port walk,
  ## so a bind failure cannot leave half a dashboard behind).
  result = GatewayRig(hooks: hooks, logger: hooks.loggerOf(),
    telegram: newTelegramLive("telegram"),
    whatsapp: newWhatsappLive("whatsapp"),
    discord: newDiscordLive("discord"),
    discordIdleMs: 0, discordDials: 0, telegramEmptyPolls: 0)
  result.telegramTurn = hooks.respond("telegram")
  result.whatsappTurn = hooks.respond("whatsapp")
  result.discordTurn = hooks.respond("discord")
  result.sup = newSupervisor(
    [("telegram", result.rigStarter("telegram")),
     ("discord", result.rigStarter("discord")),
     ("whatsapp", result.rigStarter("whatsapp"))],
    gatewayEnvFields(), result.stopHook())

proc reconcileHook*(rig: GatewayRig): GatewayHook =
  ## `supervisor.reconcile()` at startup (Python: one call, no keys, so
  ## every known starter). Reports are discarded here on purpose: the panel
  ## reads the handles themselves, and a failed gateway already says so on
  ## its own status line.
  result = proc() {.closure.} =
    var env = rig.env()
    discard rig.sup.reconcile(env, @[], rig.statusSeam())

proc reloadHook*(rig: GatewayRig): GatewayReloadFn =
  ## `_gateway_reloader`: a connections save reconciles the keys it touched
  ## and hands the statuses back, which is where `applyIntegration` turns
  ## a failed start into the save's error and a good one into health.
  result = proc(keys: seq[string]): Table[string, IntegrationStatus] =
    var env = rig.env()
    for key, report in pairs(rig.sup.reconcile(env, keys, rig.statusSeam())):
      result[key] = gatewayReportStatus(report)

proc gatewayStatusFn*(rig: GatewayRig): GatewayStatusFn =
  ## `_gateway_status_provider`: the panel's standing for one key.
  ## `false` is Python's `None` — a key with no handle, which `_status`
  ## then reads as "not proven", so a never-started gateway keeps whatever
  ## the health store says instead of claiming a connection.
  result = proc(key: string): (bool, IntegrationStatus) {.closure.} =
    let (present, report) = supervisorStatus(rig.sup, key, rig.statusSeam())
    if not present:
      return (false, IntegrationStatus())
    (true, gatewayReportStatus(report))

proc shutdownHook*(rig: GatewayRig): GatewayHook =
  ## `supervisor.shutdown()` at exit (`finally:` in Python): stop every
  ## gateway, then leave nothing bound behind.
  result = proc() {.closure.} =
    rig.sup.supervisorShutdown()
    rig.closeWebhook()
    rig.dropGateway()
    rig.closeBrowser()

proc clockOf(rig: GatewayRig): DiscordNowFn =
  ## The injected clock, or wall time — the same default `discordRun` uses,
  ## so the heartbeat cadence and the spend cap are honest in production.
  if rig.hooks.now.isNil:
    result = proc(): float = epochTime()
  else:
    result = rig.hooks.now

proc tickTelegram(rig: GatewayRig): bool =
  ## ONE `getUpdates` cycle between browser requests (Python's poller
  ## thread, one poll). Skipped when the poller is not live: unconfigured,
  ## stopped, or dead on its own token — a handle that reported itself
  ## stopped stays stopped until a `reconcile` restarts it, which is what
  ## PTB's dead poller thread does. Returns whether a TURN ran.
  ##
  ## The counter at the end is the L4 backoff: a poll that ran a turn proves
  ## the bot is not idle, so it starts over at the base cadence; a poll that
  ## found nothing (an empty `result`, a refused stranger, a retryable API
  ## error) is one piece of evidence that this bot has nothing to say. The
  ## window that evidence buys is `telegramIdleWaitMs`, read by the loop.
  if not rig.sup.running.getOrDefault("telegram", false) or
      rig.telegram.stop or not rig.telegram.running:
    return false
  let token = rig.env().getOrDefault("TELEGRAM_BOT_TOKEN", "")
  if token.len == 0:
    return false
  let turns = telegramPoll(rig.telegram, rig.hooks.telegramHttp,
    parseAllowedIds(rig.env().getOrDefault("TELEGRAM_ALLOWED_USER", "")),
    token, rig.telegramTurn, rig.logger, rig.env(),
    gatewayTickPollTimeout)
  if turns > 0:
    rig.telegramEmptyPolls = 0
  else:
    inc rig.telegramEmptyPolls
  result = turns > 0

proc endDiscordSession(rig: GatewayRig) =
  ## A gateway session that ended: the socket goes and the handle stops (so
  ## the panel stops claiming a live bot), then — unless the dial budget is
  ## spent — the handle is re-armed for the next tick's dial. That is the
  ## sequence `discordServe` runs, minus the command's exit.
  ##
  ## The budget counts CONSECUTIVE dials, and a connection that proved
  ## itself (`READY`, a message) resets it: a gateway that worked for an
  ## hour and then dropped must not inherit the debt of the connections
  ## that failed before it.
  discordStopFn(rig.discord)("discord")
  rig.dropGateway()
  if rig.discordDials >= discordDialBudget:
    rig.logger(discordDialBudgetLine)
    rig.discordDials = 0
    return
  if not rig.sup.running.getOrDefault("discord", false):
    return
  discordRearm(rig.discord, rig.env())
  rig.discord.stop = false
  rig.discord.running = true

proc tickDiscord(rig: GatewayRig): bool =
  ## ONE read of the Discord gateway between browser requests.
  ##
  ## Documented choice (the task file asked for it explicitly): the
  ## supervised gateway does NOT call `discordServe`. `discordServe` owns
  ## the socket AND blocks in its reconnect loop for the life of the
  ## process, which is right for `waku discord` and wrong here — a
  ## supervised bot that stops the dashboard from answering its own page is
  ## the one shape this port must not ship. So the dashboard pumps the wire
  ## itself, through the very seams 7d2-1/7d2-2 left open: `DiscordDialFn`
  ## to connect, `receiveDiscordEvent` to read, `discordHandleMessage` to
  ## answer. The step is the switch `discordRun` runs; the loop and the dial
  ## stay in `discord.nim`, which is where a second reader can find them.
  ##
  ## Two policies carried over: a REFUSED dial is reported once and stops
  ## the handle (a connection that never existed must read as stopped, not
  ## as "starting" forever), and a socket quiet for two missed heartbeats
  ## stops the handle too. Returns whether a TURN ran.
  if not rig.sup.running.getOrDefault("discord", false) or rig.discord.stop:
    rig.dropGateway()
    return false
  let token = rig.env().getOrDefault("DISCORD_BOT_TOKEN", "")
  if rig.gateway.isNil:
    inc rig.discordDials
    if rig.discordDials > discordDialBudget:
      rig.logger(discordDialBudgetLine)
      rig.discordDials = 0
      rig.discord.stop = true
      rig.discord.running = false
      rig.discord.ready = false
      closeRunner(rig.discord.runner)
      return false
    let (ok, wire, why) = rig.hooks.discordDial(token)
    if not ok:
      rig.logger(why)
      rig.discord.stop = true
      rig.discord.running = false
      rig.discord.ready = false
      closeRunner(rig.discord.runner)
      return false
    rig.gateway = wire
    rig.discord.running = true
    rig.discordIdleMs = 0
  let clock = rig.clockOf()
  let env = rig.env()
  let event = receiveDiscordEvent(rig.discord, rig.gateway,
    discordTickTimeoutMs)
  # Anything that came off the socket is activity for the OTHER gateways'
  # backoff too (a message, a hello, a heartbeat this loop answers): the
  # telegram counter counts "this bot is idle", and a live Discord
  # conversation is proof it is not. Only `deTimeout` — the transport said
  # nothing at all in the window — leaves it alone.
  if event.kind != deTimeout:
    rig.telegramEmptyPolls = 0
  case event.kind
  of deTimeout:
    rig.discordIdleMs += discordTickTimeoutMs
    # `discordRun` counts idle TICKS at the heartbeat interval; a tick here
    # is milliseconds, so the honest question is "two heartbeats with
    # nothing at all", which is what a dropped socket looks like.
    if rig.discord.heartbeatMs > 0 and
        rig.discordIdleMs > 2 * rig.discord.heartbeatMs:
      rig.logger(discordQuietLine)
      rig.endDiscordSession()
  of deHello:
    rig.discordIdleMs = 0
    discard discordSendJson(rig.gateway,
      discordIdentify(token, rig.discord.intents))
    rig.discord.lastHeartbeat = clock()
    discard discordSendJson(rig.gateway, discordHeartbeat(rig.discord.seq))
  of deHeartbeat:
    rig.discordIdleMs = 0
    rig.discord.lastHeartbeat = clock()
    discard discordSendJson(rig.gateway, discordHeartbeat(rig.discord.seq))
  of deReady, deAck:
    rig.discordIdleMs = 0
    rig.discordDials = 0     # this connection works: the budget is fresh
  of deStopped, deNone:
    rig.discordIdleMs = 0
  of deMessage:
    rig.discordIdleMs = 0
    rig.discordDials = 0
    result = discordHandleMessage(rig.discord, event.message,
      rig.hooks.discordHttp, token,
      parseDiscordIds(env.getOrDefault("DISCORD_ALLOWED_USER", "")),
      parseDiscordIds(env.getOrDefault("DISCORD_ALLOWED_CHANNEL", "")),
      parseRequireMention(env.getOrDefault("DISCORD_REQUIRE_MENTION", "1")),
      rig.discordTurn, rig.logger, clock(), env)
  of deReconnect:
    rig.logger(discordReconnectLine)
    rig.endDiscordSession()
  of deInvalidSession:
    rig.logger(discordReconnectLine & "session invalid (" & event.detail & ")")
    rig.endDiscordSession()
  of deClosed:
    rig.logger(discordSocketClosedLine & event.detail)
    rig.endDiscordSession()

proc gatewayTick*(rig: GatewayRig): bool =
  ## What one pass of the loop does for the gateways Python ran on threads:
  ## the telegram poll, then one step of the Discord gateway. Returns
  ## whether anything was ANSWERED (a turn ran) — the loop uses it to skip
  ## its idle wait, so a burst of messages is drained back-to-back.
  result = tickTelegram(rig) or tickDiscord(rig)

proc telegramIdleWaitMs*(emptyPolls: int): int =
  ## The window an idle pass pays after `emptyPolls` consecutive empty
  ## telegram polls: `dashboardIdleWaitMs` until the bot has said nothing
  ## once, then that wait times `telegramBackoffFactor` per further empty
  ## poll, never more than `telegramBackoffMaxMs`.
  ##
  ## Both ends of the rule live here on purpose. `tickTelegram` maintains
  ## the counter and `multiplexStep` reads the window through this function,
  ## so the cadence is one exported value a test pins, not arithmetic
  ## sprinkled through the loop. The first empty poll keeps the old cadence
  ## because a burst arrives one update at a time: the first silence is not
  ## yet idleness.
  ##
  ## The early return is the overflow guard too. The wait doubles at most
  ## until the cap, so a rig left idle for a week cannot walk an `int` off
  ## the end.
  result = dashboardIdleWaitMs
  if emptyPolls <= 1:
    return
  var ms = dashboardIdleWaitMs
  for _ in 1 ..< emptyPolls:
    if ms >= telegramBackoffMaxMs:
      return telegramBackoffMaxMs
    ms = ms * telegramBackoffFactor
  result = min(ms, telegramBackoffMaxMs)

proc idleWaitMs*(rig: GatewayRig): int =
  ## The window THIS pass's wait pays, read from the rig as it is now — the
  ## same live read `liveSeams` documents for the webhook listener, because
  ## the counter moves while the loop is running and the wait must not be
  ## the window a pass started with.
  telegramIdleWaitMs(rig.telegramEmptyPolls)

# ── the one loop ──────────────────────────────────────────────────────

type
  LoopStepFn* = proc(srv: var DashboardServer): bool {.closure.}
    ## "Serve whatever is waiting on this channel, if anything": `true`
    ## means a request was served. The browser channel takes one connection
    ## and answers it through `serveOne`; the webhook channel takes one and
    ## answers it through whatsapp's door. Both take it through a
    ## `TakeConn`, which is what keeps this loop testable with no socket.
  MultiplexSeams* = object
    ## The three halves of the loop, injected so `multiplexPass` is
    ## pinnable offline: nil means "nothing on this channel", which is what
    ## a dashboard with no webhook and no browser request looks like.
    browser*: LoopStepFn
    webhook*: LoopStepFn
    wait*: proc(timeoutMs: int) {.closure.}
      ## What a pass that found nothing pays before looking again, with the
      ## window it has to pay AS an argument: the loop decides how long (the
      ## idle telegram backoff) and the seam only waits. That split is what
      ## keeps the cadence injectable — a test records the windows instead of
      ## sleeping through them — and it is why the production half is still
      ## `waitForListener` over the two real listeners.

proc takeConn*(listener: Socket): TakeConn =
  ## The dashboard's `TakeConn`: a select-based take, so "nothing waiting
  ## right now" is an answer instead of a park. This is the seam
  ## `serveWhatsapp` documents as "the dashboard injects a select-based
  ## take" — `selectRead` over the listener's descriptor answers in zero
  ## milliseconds and leaves the loop's own wait to bound the idle case.
  result = proc(): (bool, Socket) {.closure.} =
    if listener.isNil:
      return (false, nil)
    var handles: seq[SocketHandle] = @[listener.getFd()]
    if selectRead(handles, 0) == 0:
      return (false, nil)
    var client: Socket
    try:
      listener.accept(client)
    except OSError:
      return (false, nil)   # a client that hung up between the two
    return (true, client)

proc serveWebhookRequest*(rig: GatewayRig, client: Socket) =
  ## ONE Meta webhook request, answered through whatsapp's own door —
  ## verification, signature, the 200-before-the-turn order and the turn
  ## policy all stay in `whatsapp.nim`. A verb that does not parse answers
  ## 404, the shape `serveWhatsapp` itself uses.
  ##
  ## Documented choice: this half of the loop calls `serveWhatsappRequest`,
  ## not `serveWhatsapp`. `serveWhatsapp` is the standalone command's
  ## blocking accept loop — it prints its banner, owns `running` from bind
  ## to exit and only returns when the handle is stopped, so a supervisor
  ## re-entering it per pass would re-print the banner every pass and leave
  ## the panel reading "stopped" between requests. `TakeConn` is still the
  ## seam connections arrive through, so the wire contract stays one thing.
  let req = readWhatsappRequest(client)
  if req.verb.len == 0:
    writeWhatsappResponse(client, 404, "{}")
    return
  let env = rig.env()
  proc write(status: int, body: string) =
    writeWhatsappResponse(client, status, body)
  discard serveWhatsappRequest(req,
    env.getOrDefault("WHATSAPP_VERIFY_TOKEN", ""),
    env.getOrDefault("WHATSAPP_APP_SECRET", ""),
    env.getOrDefault("WHATSAPP_ALLOWED_PHONE", ""),
    env.getOrDefault("WHATSAPP_TOKEN", ""),
    env.getOrDefault("WHATSAPP_PHONE_NUMBER_ID", ""),
    rig.hooks.whatsappHttp, rig.whatsappTurn, rig.logger, env,
    live = rig.whatsapp, write = write)

proc browserStep*(listener: Socket): LoopStepFn =
  ## The browser channel: one accepted connection through `serveOne`,
  ## closed exactly like `defaultServe` closes it (including the swallow —
  ## one bad request must not take the loop down).
  let take = takeConn(listener)
  result = proc(srv: var DashboardServer): bool {.closure.} =
    let (got, client) = take()
    if not got:
      return false
    try:
      serveOne(srv, client)
    except CatchableError:
      discard
    try:
      client.close()
    except CatchableError:
      discard
    return true

proc webhookStep*(rig: GatewayRig): LoopStepFn =
  ## The webhook channel: one accepted connection through whatsapp's door,
  ## skipped entirely while no webhook is bound (the row is off).
  result = proc(srv: var DashboardServer): bool {.closure.} =
    if rig.webhook.isNil:
      return false
    let (got, client) = takeConn(rig.webhook)()
    if not got:
      return false
    try:
      rig.serveWebhookRequest(client)
    except CatchableError:
      discard   # a client that hung up mid-request: serve the next one
    try:
      client.close()
    except CatchableError:
      discard
    return true

proc waitForListener*(listeners: seq[Socket],
                      timeoutMs = dashboardIdleWaitMs) =
  ## Block until one of `listeners` has a connection waiting or the window
  ## closes — the bounded wait an idle pass pays, and the one place this
  ## loop blocks at all. `selectRead` prunes the list down to the ready
  ## descriptors, which is exactly the question ("is anyone there?") the
  ## loop asks after a pass found nothing. An empty list sleeps the window:
  ## with no listener bound there is nothing to watch.
  ##
  ## The window grows while an idle bot backs off (`telegramIdleWaitMs`), and
  ## that costs a browser request nothing: the select returns the moment a
  ## descriptor is ready, so the window bounds how often Telegram is asked,
  ## never how long a person waits for their page.
  var handles: seq[SocketHandle] = @[]
  for listener in listeners:
    if not listener.isNil:
      handles.add(listener.getFd())
  if handles.len == 0:
    sleep(timeoutMs)
    return
  discard selectRead(handles, timeoutMs)

proc liveSeams*(srv: var DashboardServer, rig: GatewayRig): MultiplexSeams =
  ## The process's three halves: bind the browser listener (the port walk
  ## already chose a free port, like `defaultServe`), take webhook requests
  ## off the rig's own listener, and wait on both when a pass found
  ## nothing. The wait reads the rig as it is NOW, because a connections
  ## save can bind the webhook listener long after this ran.
  var listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(srv.port), srv.host)
  listener.listen()
  rig.browser = listener
  result = MultiplexSeams(
    browser: browserStep(listener),
    webhook: webhookStep(rig),
    wait: proc(timeoutMs: int) {.closure.} =
      waitForListener(@[listener, rig.webhook], timeoutMs))

proc multiplexPass*(srv: var DashboardServer, rig: GatewayRig,
                     seams: MultiplexSeams): bool =
  ## ONE pass of the loop, in the order the port cares about: the browser
  ## first (a person waiting on the page is served before a gateway asks
  ## its own network), then the webhook, then the gateways. Returns whether
  ## the pass found anything to do.
  ##
  ## A webhook request clears the telegram backoff BEFORE the gateways are
  ## asked, because a message arriving on the webhook is the clearest proof
  ## there is that this person is talking to the bot right now — the empty
  ## poll that follows in the same pass is then the first of a new count.
  result = false
  if not seams.browser.isNil and seams.browser(srv):
    result = true
  if not seams.webhook.isNil and seams.webhook(srv):
    result = true
    rig.telegramEmptyPolls = 0
  if rig.gatewayTick():
    result = true

proc multiplexStep*(srv: var DashboardServer, rig: GatewayRig,
                    seams: MultiplexSeams): bool =
  ## One iteration of `multiplexServe`, including the wait rule: a pass that
  ## found something goes straight round again (a burst of requests or of
  ## queued messages is drained back-to-back), and a pass that found
  ## nothing pays the bounded wait — which is `idleWaitMs`, so the poll
  ## cadence backs off while nothing is happening and returns to the base
  ## cadence the moment something does. Returns whether the pass did
  ## anything — the loop ignores it, a test reads it.
  if multiplexPass(srv, rig, seams):
    return true
  if not seams.wait.isNil:
    seams.wait(rig.idleWaitMs())
  return false

proc multiplexServe*(srv: var DashboardServer, rig: GatewayRig,
                     seams: MultiplexSeams) =
  ## The accept loop that stands in for Python's `serve_forever()` plus
  ## its three gateway threads. One pass at a time, one thread, no
  ## scheduler: a gateway TURN still blocks the loop while it runs, which
  ## is the posture 8b already accepted for streaming chat turns.
  while true:
    discard multiplexStep(srv, rig, seams)

proc serveFn*(rig: GatewayRig): ServeFn =
  ## The `ServeFn` `runDashboardCmd` is handed: the one loop, with the
  ## process's real sockets bound here and nowhere else.
  result = proc(srv: var DashboardServer) {.closure.} =
    multiplexServe(srv, rig, liveSeams(srv, rig))

proc gatewayAgents*(providers: seq[Provider], settings: Settings,
    dotenvPath: string,
    envOf: proc(): Table[string, string] {.closure.}): GatewayRespondFn =
  ## One agent per supervised gateway, built on its first turn: Python's
  ## `GatewayAgentRunner(_build_agent, session_id=key)` pair, where the
  ## build happens inside the runner's first turn too. Each box owns its own
  ## conversation thread named after the gateway, and Discord gets its own
  ## memory home from `DISCORD_HOME` (the same override
  ## `waku.discord`'s dispatch passes). A build failure raises inside the
  ## turn, where `runGatewayTurn` records it as `message handling` and the
  ## partner gets the shared error reply.
  ##
  ## The key and the home are read through `envOf` when the box is BUILT, so
  ## a key saved in the panel is the key the next gateway turn uses — the
  ## same "the process env is what the gateway reads" shape Python has.
  ##
  ## A call is a START: it builds that gateway's own box, and a restart
  ## builds a fresh one, exactly like Python's `start_in_background` making a
  ## new `GatewayAgentRunner` (new agent, new session thread) every time.
  ## Nothing is cached here — the box lives exactly as long as the turn
  ## closure the supervisor holds.
  result = proc(source: string): RespondFn {.closure.} =
    var s = settings
    let env = envOf()
    if source == "discord":
      let home = env.getOrDefault("DISCORD_HOME", "")
      if home.len > 0:
        s.home = home
    let box = WakuBox(providers: providers, dotenvPath: dotenvPath,
      settings: s, sessionId: source,
      apiKey: env.getOrDefault("WAKU_API_KEY", ""))
    result = proc(text: string): string {.closure.} =
      box.ensureWaku()
      if box.buildError.len > 0:
        raise newException(CatchableError, box.buildError)
      box.waku.respond(text, cli.liveObserver, source, false).reply

proc liveGatewayHooks*(providers: seq[Provider], settings: Settings,
    dotenvPath: string,
    envOf: proc(): Table[string, string] {.closure.}): GatewayHooks =
  ## The process's seams: the real Bot API, Graph API and Discord REST
  ## clients, the real gateway dial, stdout as the terminal mirror, and one
  ## lazy agent per gateway. Only here does a gateway touch the network.
  result = GatewayHooks(
    envOf: envOf,
    logger: nil,   # plain stdout, the default `loggerOf` resolves
    respond: gatewayAgents(providers, settings, dotenvPath, envOf),
    telegramHttp: liveTelegramHttp,
    whatsappHttp: liveWhatsappPost,
    discordHttp: liveDiscordPost,
    discordDial: liveDiscordWire,
    now: nil,      # wall time, the default `clockOf` resolves
    webhookHost: "0.0.0.0",
    webhookPort: whatsappPort)

proc checkDashboardCmd*(providers: seq[Provider], settings: Settings,
                        dotenvPath: string): int =
  ## In-process dashboard entry: build live deps and walk the port with
  ## a free-probe, without touching sockets or serving. Lets `runCommand`
  ## stay embeddable (and the 4e dispatch test green) while the binary
  ## serves for real below.
  try:
    var deps = buildDashboardDeps(providers, settings, dotenvPath)
    discard prepareDashboard(deps, proc(port: int): bool = false)
    return 0
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    return 1

proc serveDashboardCmd*(providers: seq[Provider], settings: Settings,
                        dotenvPath: string): int =
  ## Process dashboard entry: build, walk past busy ports for real,
  ## print the URL, reconcile the gateways, serve the ONE loop (browser +
  ## webhook + the two polled gateways), shut the gateways down.
  ##
  ## 7d2-3 owns the wiring, and it lives HERE rather than in
  ## `buildDashboardDeps` on purpose: `DashboardDeps` is a flat object
  ## literal every constructor and test fills positionally, so the seams
  ## this unit needs (a supervisor bound to a live env, a serve loop that
  ## pumps it) belong to the process entry, not to the handler bundle. The
  ## in-process `checkDashboardCmd` above therefore validates a dashboard
  ## with no gateway running, exactly like Python's embedders.
  try:
    var deps = buildDashboardDeps(providers, settings, dotenvPath)
    var srv = prepareDashboard(deps)
    # The rig reads the env the panel writes: `srv.deps` is reached through
    # a `var` local (the nested proc captures it by reference), so a save
    # from the connections panel is the next `reconcile`'s input. Building
    # this after `prepareDashboard` is what makes it the SERVER's table
    # rather than the local one the server was copied from — see
    # `GatewayHooks.envOf` for why that distinction is load-bearing.
    proc envLive(): Table[string, string] = srv.deps.env
    let rig = newGatewayRig(
      liveGatewayHooks(providers, settings, dotenvPath, envLive))
    srv.deps.gatewayStatus = rig.gatewayStatusFn()
    srv.deps.gatewayReload = rig.reloadHook()
    var arenaEnv = initTable[string, string]()
    for k, v in envPairs():
      arenaEnv[k] = v
    let adeps = ArenaDeps(home: settings.home, providers: providers,
      dotenvPath: dotenvPath, apiKey: getEnv("WAKU_API_KEY"),
      fetch: liveSearchFetch, gh: liveGhRun,
      apple: liveAppleSeams(),
      makeExchange: liveStdioFactory(), httpPost: liveHttpPostFn(),
      env: arenaEnv, buildClient: nil,
      jevPost: liveJevPost, jevKey: getEnv("TYPESAFE_API_KEY"),
      nowUnix: getTime().toUnix())
    srv.deps.raceFn = makeLiveRace(adeps)
    srv.deps.judgeFn = makeLiveJudge(adeps)
    srv.deps.turnJudgeFn = makeLiveTurnJudge(adeps, settings.provider)
    srv.deps.memoryRunFn = makeLiveMemoryRun(adeps)
    srv.deps.judgmentRaceFn = makeLiveJudgmentRace(adeps)
    return runDashboardCmd(srv, rig.reconcileHook(), rig.shutdownHook(),
      rig.serveFn())
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    return 1
