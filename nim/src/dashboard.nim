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
## Deliberately OUT (units 8c/8d): the compare POSTs (`clear`, `regrade`,
## `delete_run`), the judgment-arena key/stream and memory-arena
## clean/stream POSTs, `/api/compare/history` and both arena GETs. Pinned
## but later routes answer an honest 501 (GET/POST) or a terminal
## done-error frame (streams) — never the SPA shell as data.
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

import std/httpclient
import std/json
import std/net
import std/os
import std/osproc
import std/strutils
import std/syncio
import std/tables
import std/times

import db_connector/db_sqlite

import ./app
import ./catalog
import ./client
import ./config
import ./db
import ./integrations
import ./memory
import ./pricing
import ./providers
import ./session
import ./triage
import ./wire

export catalog.FetchFn

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
    "/api/models",
    "/api/events",
    "/api/reveal",
    "/api/compare/history",
    "/static/",
    "/api/judgment-arena",
    "/api/memory-arena",
    "/api/memory-arena/stores",
  ]
    ## Mirror of the Python `PINNED_GET` set both the route-contract eval
    ## and the hosted policy table read from. 8a serves a SUBSET of these
    ## paths and must never serve anything outside this list: a new path
    ## here is a contract change (same commit updates the eval + policy).

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

type
  SseEmit* = proc(kind: string, ev: JsonNode) {.closure.}
    ## One harness event into an SSE stream (`chat_stream`'s `emit`).
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

  DashboardDeps* = object
    ## Everything the handlers read, injected so tests stay offline.
    home*: string
      ## `WAKU_HOME`: usage ledger, traces, state.db.
    staticDir*: string
      ## The `waku/ops/static/` checkout served as-is from disk. The
      ## compile-time embed is a phase-close decision, still pending.
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
    dotenvPath*: string
      ## The `.env` file settings/connections persist to; "" skips disk.
    hostOs*: string
      ## Platform for the reveal fallback; "" means the build host.
    chatFn*: ChatFn
    chatStreamFn*: ChatStreamFn
    graphStreamFn*: GraphStreamFn
    voiceFn*: VoiceFn
    sessionFn*: SessionFn
    revealProbe*: RevealProbeFn
    revealOpen*: RevealOpenFn
    store*: HealthStore
      ## Connection health, lazily created per home when nil.
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
  ## The served GET API surface (8a reads + the 8b `reveal` side effect).
  ## Each MUST be in `pythonPinnedGet` (there is a test); arena reads
  ## (`compare/history`, both arenas) arrive with their own units.
  @["/api/data", "/api/models", "/api/events", "/api/reveal"]

proc readPostRoutes*(): seq[string] =
  ## The 8b POST API surface (JSON routes; streams dispatch separately
  ## via `handleStream`). Each MUST be in `pythonPinnedPost` (there is a
  ## test); the arena POSTs arrive with 8c/8d.
  @["/api/chat", "/api/memory", "/api/settings", "/api/query",
    "/api/session", "/api/pin", "/api/connections",
    "/api/connections/test", "/api/providers", "/api/voice"]

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

proc serveStatic*(staticDir, reqPath: string): (int, string, string) =
  ## Port of `_serve_static`: strip the query, confine to `staticDir`
  ## (a resolved path outside it is a 404, never a read), map the
  ## content type, serve with no-cache semantics left to the HTTP layer.
  var path = reqPath.split('?')[0]
  const prefix = "/static/"
  if not path.startsWith(prefix):
    return (404, "text/plain", "not found")
  let name = path[prefix.len .. ^1]
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
  ## (a missing frontend is a deployment bug, not a traceback).
  let index = staticDir / "index.html"
  if not fileExists(index):
    return (404, "text/plain", "not found")
  return (200, "text/html; charset=utf-8", readFile(index))

proc tracePath*(home, today: string): string =
  ## Today's trace file, like `events_since`: `<home>/traces/<date>.jsonl`.
  let day = if today.len > 0: today else: format(now(), "yyyy-MM-dd")
  home / "traces" / day & ".jsonl"

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

proc statusPayload*(d: DashboardDeps): JsonNode =
  ## The 8a `/api/data` STATUS SUBSET: identity + spend + health + the
  ## trace pointer. The full `collect()` blob (turns, db introspection,
  ## skills, graph topologies, eval report) lands across the remaining
  ## 8x units; see the module docstring.
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
  result = %*{
    "generated_at": stamp,
    "home": absolutePath(d.home),
    "provider": d.provider,
    "model": d.model,
    "usage": {"calls": usage.calls, "in": usage.totalIn,
              "out": usage.totalOut, "cost": usage.totalCost,
              "by_day": byDay, "by_provider": byProvider},
    "connections": conns,
    "trace": traceInfo,
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
  if path == "/" or path == "/index.html":
    return serveIndex(d.staticDir)
  if path.startsWith("/static/"):
    return serveStatic(d.staticDir, path)
  if path.startsWith("/api/"):
    # A pinned-but-later GET (arenas, compare/history): honest 501, not
    # a silent index render — the browser must not mistake the SPA shell
    # for data.
    if path in pythonPinnedGet or path == "/api/compare/history":
      return (501, "application/json",
        $ %*{"error": "not yet implemented in the Nim port: " & path})
    return (404, "application/json", $ %*{"error": "unknown api path"})
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

proc settingsInfo*(d: DashboardDeps): JsonNode =
  ## Port of `settings_api.settings_info`, as the subset this port owns:
  ## provider/model resolution, key presence (last-4 never leaves the
  ## machine — only the set flag), the curated pin shortlist with each
  ## provider's default first, disabled providers, and the two toggles.
  ## Display-only extras (typesafe key, pi presence, provider labels)
  ## stay out: the contract pins PATHS, not payload keys (same argument
  ## as the 8a `/api/data` subset).
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
  var rid: int64 = 0
  try:
    let idNode = payload.jget("id")
    if idNode.kind == JNull:
      rid = 0
    elif idNode.kind == JInt:
      rid = idNode.getBiggestInt()
    elif idNode.kind == JString:
      rid = parseBiggestInt(idNode.getStr())
    else:
      return %*{"error": "bad id"}
  except ValueError:
    return %*{"error": "bad id"}
  let db = connectDb(d.home)
  try:
    if action == "update_fact":
      let subject = jsonStr(payload.jget("subject"))
      let content = jsonStr(payload.jget("content"))
      let ok = if subject.len > 0: db.updateFact(rid, content, subject)
               else: db.updateFactContent(rid, content)
      return %*{"ok": ok}
    if action == "delete_fact":
      return %*{"ok": db.deleteFact(rid)}
    if action == "delete_episode":
      return %*{"ok": db.deleteEpisode(rid)}
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

proc sessionAction*(d: DashboardDeps, payload: JsonNode): JsonNode =
  ## Port of `session_action`. `history` is a direct db read (safe to
  ## poll live — it never touches the agent). `new`/`switch` mutate the
  ## live session, so they delegate to the injected `sessionFn` (the
  ## browser-agent lock pattern as a seam); without one, `new` still
  ## mints a dated thread and `switch` loads its history read-only.
  let action = jsonStr(payload.jget("action"))
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

proc handleStream*(d: var DashboardDeps, target, body: string,
                   emitFrame: proc(frame: string) {.closure.}): bool =
  ## SSE dispatch. True when `target` is a stream route (frames were — or
  ## will be — emitted); false for everything else, which belongs to
  ## `handlePost`. Later-unit streams (compare, judgment, memory arenas)
  ## emit one terminal done-error frame: the SSE shape of the 501.
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
  if target in ["/api/compare/stream", "/api/judgment-arena/stream",
      "/api/memory-arena/stream"]:
    emitFrame(sseFrame("done", %*{"error":
      "not yet implemented in the Nim port: " & target}))
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
    if target in ["/api/compare/clear", "/api/compare/regrade",
        "/api/compare/delete_run", "/api/judgment-arena/key",
        "/api/memory-arena/clean"]:
      return (501, "application/json", $ %*{"error":
        "not yet implemented in the Nim port: " & target})
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
    let client = clientFor(s, box.providers, getEnv("WAKU_API_KEY"),
      box.dotenvPath)
    box.settings = s
    let db = connectDb(s.home)
    box.waku = newWaku(s, client, db)
    if s.graphWorkflows:
      box.waku.graphTurn = triageGraphTurn(client, s.smallModel, s.home,
        proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
          box.waku.runFullTurn(st.jget("message").getStr(), n, strm))
    box.waku.session.sessionId =
      "dashboard-" & format(now(), "yyyyMMdd-HHmmss")
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
                 else: box.waku.settings.model)}

proc liveChatStreamFn*(box: WakuBox): ChatStreamFn =
  ## `chat_stream` against the live agent: gate/tool/text events as they
  ## happen (the browser lights the diagram from these), then done.
  result = proc(message: string, emit: SseEmit) {.closure.} =
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
  ## A leading `/command` runs as a plain turn here (the slash-command
  ## table arrives with the commands port — documented, not silent).
  result = proc(message: string): JsonNode {.closure.} =
    box.ensureWaku()
    if box.buildError.len > 0:
      return %*{"error": box.buildError}
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
  ## into the listed=false shape, never a 500.
  var client = newHttpClient(timeout = 15000)
  try:
    if key.len > 0:
      client.headers = newHttpHeaders({"Authorization": "Bearer " & key})
    return client.getContent(url)
  finally:
    client.close()

proc findStaticDir*(): string =
  ## Locate the dashboard frontend, trying the caller's working directory
  ## first (repo checkout layout) and the binary directory last — the
  ## same shape as the provider-registry lookup in `waku.nim`.
  for candidate in ["waku/ops/static", "../waku/ops/static",
      "../../waku/ops/static"]:
    if dirExists(candidate):
      return candidate
  let besideBin = getAppDir() / "static"
  if dirExists(besideBin):
    return besideBin
  return "waku/ops/static"

proc buildDashboardDeps*(providers: seq[Provider], settings: Settings,
                         dotenvPath: string): DashboardDeps =
  ## Live deps for the server: process env as the table, live catalog
  ## fetch, and the lazy agent box behind the chat/session seams. No
  ## network, no disk writes, no agent build here — first chat pays.
  ## Probes stay unwired (no live client for them yet — see the phase
  ## task file); connection saves validate + persist without probing.
  var env = initTable[string, string]()
  for k, v in envPairs():
    env[k] = v
  let box = WakuBox(providers: providers, dotenvPath: dotenvPath,
    settings: settings)
  DashboardDeps(home: settings.home, staticDir: findStaticDir(),
    provider: settings.provider, model: settings.model,
    smallModel: settings.smallModel, baseUrl: settings.baseUrl,
    apiKey: settings.apiKey, providers: providers, env: env,
    fetch: liveCatalogFetch, today: "", nowIso: "",
    dotenvPath: dotenvPath, hostOs: "", chatFn: liveChatFn(box),
    chatStreamFn: liveChatStreamFn(box), graphStreamFn: nil, voiceFn: nil,
    sessionFn: liveSessionFn(box), revealProbe: nil, revealOpen: nil,
    store: nil, probes: initTable[string, ProbeFn](),
    providerProbe: nil, rebuild: nil, gatewayReload: nil,
    gatewayStatus: nil)

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
  ## print the URL, serve until Ctrl-C.
  try:
    var deps = buildDashboardDeps(providers, settings, dotenvPath)
    var srv = prepareDashboard(deps)
    return runDashboardCmd(srv)
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    return 1
