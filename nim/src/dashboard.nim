## Dashboard read-only backend — unit 8a of the Nim port.
##
## Port target: the GET half of `waku/ops/dashboard.py` `Handler.do_GET`,
## restricted to reads with no side effects: `/api/data` (as a bounded
## status document, NOT the full `collect()` blob), `/api/models`
## (`list_models`), `/api/events` (`events_since`), plus the static-file
## server (`_serve_static` + the index fallback) served from disk.
##
## Deliberately OUT (units 8b/8c/8d): every POST route (chat, memory,
## settings, query, session, pin, connections, providers, arena judges),
## every stream (`/api/chat/stream`, compare/graph/arena streams, voice),
## `/api/reveal` (opens an editor — a side effect, not a read),
## `/api/compare/history` and both arena GETs (arena repricing lives with
## the arena unit), and the live `ThreadingHTTPServer` loop (no sockets
## here — `handleGet` is pure dispatch over injected deps, so tests stay
## 100% offline with a stub `FetchFn` like phase 3e).
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

import std/json
import std/os
import std/strutils
import std/tables
import std/times

import ./catalog
import ./integrations
import ./pricing
import ./providers

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

type
  DashboardDeps* = object
    ## Everything the GET handlers read, injected so tests stay offline.
    home*: string
      ## `WAKU_HOME`: usage ledger, traces, (later) state.db.
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

proc readGetRoutes*(): seq[string] =
  ## The 8a GET API surface. Each MUST be in `pythonPinnedGet` (there is
  ## a test); arena reads (`compare/history`, both arenas) and the
  ## editor side effect (`reveal`) arrive with their own units.
  @["/api/data", "/api/models", "/api/events"]

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
  if path == "/" or path == "/index.html":
    return serveIndex(d.staticDir)
  if path.startsWith("/static/"):
    return serveStatic(d.staticDir, path)
  if path.startsWith("/api/"):
    # A pinned-but-later GET (arena, reveal, compare/history): honest
    # 501, not a silent index render — the browser must not mistake the
    # SPA shell for data.
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
  ## The walk past a busy port stays with the server loop (a later unit).
  for name in ["WAKU_DASHBOARD_PORT", "PORT"]:
    let raw = env.getOrDefault(name, "").strip()
    if raw.len == 0:
      continue
    try:
      return parseInt(raw)
    except ValueError:
      return defaultPort
  return defaultPort
