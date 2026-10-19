## `waku connect <name>` — sign in to an integration that needs your browser.
##
## Port of `waku/connect.py` plus the three connector entries
## (`google_calendar.connect`, `waku_memory.connect`, `treg.connect`). Signing in opens a
## browser and waits for a click, so it is the one step a turn must never
## take on its own: exactly three doors, the CLI here and `/connect` in the
## dashboard chat (the chat door arrives with the slash-command table —
## chat turns still run `/connect x` as a plain turn).
##
## Every browser/network step is an injected seam (`GoogleSeams`,
## `MemorySignInFn`); tests never open either. The binary wires the live
## adapters in `waku.runConnectCmd`, reusing `mcp`'s browser, loopback and
## OAuth pieces the way `runMcpCmd` does.
##
## Two deliberate divergences: there is no `pip install` gate (the single
## binary has no optional extras — MCP is always aboard, so the
## waku-memory `[mcp]`-missing branch has nothing to say), and episodes
## stay out of it (no `notion` mode anywhere in this port).

import std/asynchttpserver
import std/asyncdispatch
import std/httpclient
import std/json
import std/net
import std/os
import std/strutils
import std/times
import std/uri

import ./http
import ./mcp
import ./wire

const
  connectorNames* = ["google", "waku-memory", "treg"]
    ## What `waku connect` accepts, in registry order.

  googleScope* = "https://www.googleapis.com/auth/calendar.events.readonly"
    ## The one read-only scope the calendar's client sources request.

  gmailScopes* = @["https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.send"]
    ## Gmail parity, deliberately scope-only: this binary carries no Gmail
    ## tools (the row in `integrations.nim` plus these scopes is the whole
    ## port, and `docs/status.md` declares the asymmetry), but a sign-in here
    ## must not leave the same home unable to read mail once the Python side
    ## asks. Sending still needs WAKU_GMAIL_SEND there.

  googleAuthUri* = "https://accounts.google.com/o/oauth2/auth"
  googleTokenUri* = "https://oauth2.googleapis.com/token"
    ## Defaults when `credentials.json` names no URIs (same values as the
    ## empty bundled config in `google_calendar.py`).

  memoryName* = "waku_memory"
  memoryUrl* = "https://api.waku.one/mcp"
  memoryDocs* = "https://www.waku.one/docs"
    ## Where the same memory lives for the other agents, named in every
    ## waku-memory reply like Python's `DOCS`.
  retiredHosts* = ["d1o2fv4416yi84.cloudfront.net"]
    ## The host Waku Memory answered on before 2026-08-29: it now refuses
    ## clients, so a config copied from the old README is moved, not failed.

  tregName* = "treg"
  tregUrl* = "https://treg.to/mcp/"
  tregDocs* = "https://treg.to"
    ## Live external data for research (search, companies, people, social,
    ## ads, the web), billed to your own treg account. Named in every
    ## treg reply like Python's `DOCS`.
  tregWhat* = "Live data for research: search, companies, people, " &
    "social, ads and the web."
    ## Port of Python's `WHAT`, shown on the Connections card.

proc connectUsage*(): string =
  ## What to run. Unknown names land here with exit 1, like Python.
  "Usage: waku connect <name>  —  available: " & connectorNames.join(", ") & "."

proc connectUnknown*(name: string): string =
  ## The unknown-name reply: what failed plus the usage, like Python.
  "Nothing called '" & name & "' to connect. " & connectUsage()

type
  WaitLoopbackFn* = proc(port: int): string {.closure.}
    ## Serve the one OAuth redirect on 127.0.0.1 and return its target
    ## (`/?code=...`), or "" when the browser never came back. Raises
    ## `IOError` when the port is already held.
  GoogleExchangeFn* = proc(tokenUri, body: string): tuple[ok: bool,
      doc: JsonNode] {.closure.}
    ## POST the code for tokens: `(true, response)` or `(false, {})`.
  GoogleSeams* = object
    openBrowser*: BrowserFn
    waitLoopback*: WaitLoopbackFn
    exchange*: GoogleExchangeFn
    nowUnix*: int64
  MemorySignInFn* = proc(home, name: string): tuple[ok: bool, msg: string,
      identity: string] {.closure.}
    ## The `mcp_cli.sign_in` step: `(ok, message, signed-in account)`.

proc freeLoopbackPort*(): int =
  ## A free 127.0.0.1 port for the OAuth redirect (`run_local_server`
  ## passes `port=0` for the same reason).
  var sock = newSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = sock.getLocalAddr()
  sock.close()
  int(port)

proc callbackCode*(target: string): (bool, string) =
  ## The `code=` (or `error=`) out of a loopback redirect target.
  let q = target.find('?')
  let query = if q >= 0: target[q + 1 .. ^1] else: target
  for part in query.split('&'):
    let eq = part.find('=')
    if eq <= 0:
      continue
    let key = decodeUrl(part[0 ..< eq])
    if key == "code":
      return (true, decodeUrl(part[eq + 1 .. ^1]))
    if key == "error":
      return (false, decodeUrl(part[eq + 1 .. ^1]))
  return (false, "")

proc googleClient*(home: string): tuple[found: bool, client: JsonNode,
    source: string] =
  ## The OAuth client: your own `.waku/credentials.json` wins (it replaces
  ## the client configuration only, never the permissions); otherwise the
  ## bundled client — which ships unconfigured (empty id/secret), so a
  ## checkout without your file answers honestly instead of opening a
  ## browser that Google would refuse.
  let own = home / "credentials.json"
  if fileExists(own):
    try:
      let doc = parseJson(readFile(own))
      for section in ["installed", "web"]:
        let client = doc.jget(section)
        if client.kind == JObject and
            client.jget("client_id").getStr().len > 0:
          return (true, client, "credentials.json override")
    except JsonParsingError, IOError:
      discard
    return (false, newJNull(), "")
  return (false, newJNull(), "")

proc googleConsentScopes*(): seq[string] =
  ## What one consent asks for: the calendar's read scope plus Gmail's, so a
  ## single click covers both capabilities.
  @[googleScope] & gmailScopes


proc googleAuthUrl*(client: JsonNode, redirectUri: string): string =
  ## The consent URL for the loopback flow (offline scope, so the cached
  ## token carries a refresh token).
  let authUri = block:
    let u = client.jget("auth_uri").getStr()
    if u.len > 0: u else: googleAuthUri
  authUri & "?client_id=" & encodeUrl(client.jget("client_id").getStr()) &
    "&redirect_uri=" & encodeUrl(redirectUri) &
    "&response_type=code&scope=" & encodeUrl(googleConsentScopes().join(" ")) &
    "&access_type=offline&prompt=consent"

proc googleExchangeBody*(client: JsonNode, code, redirectUri: string): string =
  ## The `application/x-www-form-urlencoded` code-for-token POST body.
  "code=" & encodeUrl(code) &
    "&client_id=" & encodeUrl(client.jget("client_id").getStr()) &
    "&client_secret=" & encodeUrl(client.jget("client_secret").getStr()) &
    "&redirect_uri=" & encodeUrl(redirectUri) &
    "&grant_type=authorization_code"

proc googleConnect*(home: string, seams: GoogleSeams): string =
  ## Open the browser, get consent, cache the token — the ONE place a
  ## browser window may appear, never mid-turn. Mirrors
  ## `google_calendar.connect` message for message.
  let (found, client, source) = googleClient(home)
  if not found:
    return "Google Calendar's bundled OAuth client is not configured " &
      "yet. Add .waku/credentials.json to use your own Desktop " &
      "OAuth client."
  let tokenUri = block:
    let u = client.jget("token_uri").getStr()
    if u.len > 0: u else: googleTokenUri
  var port = 0
  try:
    port = freeLoopbackPort()
  except OSError as exc:
    return "Google sign-in failed or was cancelled (" & exc.msg &
      "). Nothing was saved."
  let redirectUri = "http://localhost:" & $port
  if not seams.openBrowser(googleAuthUrl(client, redirectUri)):
    return "Google sign-in failed or was cancelled (no browser). " &
      "Nothing was saved."
  var target = ""
  try:
    target = seams.waitLoopback(port)
  except IOError as exc:
    return "Google sign-in failed or was cancelled (" & exc.msg &
      "). Nothing was saved."
  let (ok, codeOrError) = callbackCode(target)
  if not ok:
    return "Google sign-in failed or was cancelled" &
      (if codeOrError.len > 0: " (" & codeOrError & ")" else: "") &
      ". Nothing was saved."
  let (exchanged, doc) = seams.exchange(tokenUri,
    googleExchangeBody(client, codeOrError, redirectUri))
  if not exchanged or doc.kind != JObject or
      doc.jget("access_token").getStr().len == 0:
    return "Google sign-in failed or was cancelled (token refused). " &
      "Nothing was saved."
  # The cached shape mirrors `Credentials.to_json`: the token, the
  # refresh, where it came from and when it dies — everything a later
  # reader needs without reopening a browser.
  var expiresIn: int64 = 3600
  let ei = doc.jget("expires_in")
  if ei.kind == JInt:
    expiresIn = ei.getBiggestInt()
  elif ei.kind == JFloat:
    expiresIn = int64(ei.getFloat())
  let record = %*{"token": doc.jget("access_token").getStr(),
    "refresh_token": doc.jget("refresh_token").getStr(),
    "token_uri": tokenUri,
    "client_id": client.jget("client_id").getStr(),
    "client_secret": client.jget("client_secret").getStr(),
    "scopes": googleConsentScopes(), "expiry": seams.nowUnix + expiresIn}
  let path = home / "google-token.json"
  try:
    createDir(home)
    writeFile(path, $record)
  except IOError as exc:
    return "Google sign-in failed or was cancelled (" & exc.msg &
      "). Nothing was saved."
  return "Google connected (via " & source & "): calendar read-only, " &
    "plus the mail scopes the Gmail tools use. Token cached at " & path & "."

proc addMemoryServer*(home: string): tuple[status: string, spec: JsonNode] =
  ## Make sure `mcp.json` names Waku Memory: "added", "present", "moved"
  ## (a retired address is updated) or "conflict" (a `waku_memory` entry
  ## pointing elsewhere on purpose is left alone).
  let config = home / "mcp.json"
  var data = %*{"servers": newJArray()}
  if fileExists(config):
    try:
      data = parseJson(readFile(config))
    except JsonParsingError:
      raise newException(ValueError,
        config & " is not valid JSON — fix it or move it aside, then run again.")
  if data.kind != JObject:
    data = %*{"servers": newJArray()}
  if data.jget("servers").kind != JArray:
    data["servers"] = newJArray()
  let servers = data["servers"]
  for spec in servers:
    if spec.jget("url").getStr().strip(chars = {'/'}) == memoryUrl:
      return ("present", spec)
  for spec in servers:
    if spec.jget("name").getStr() != memoryName:
      continue
    let url = spec.jget("url").getStr()
    var retired = false
    for host in retiredHosts:
      if host in url:
        retired = true
    if retired:
      spec["url"] = %memoryUrl
      writeFile(config, pretty(data, 2) & "\n")
      return ("moved", spec)
    return ("conflict", spec)
  let spec = %*{"name": memoryName, "url": memoryUrl, "oauth": true}
  servers.add(spec)
  createDir(home)
  writeFile(config, pretty(data, 2) & "\n")
  return ("added", spec)

proc memoryConnect*(home: string, signIn: MemorySignInFn): string =
  ## Add the server, then sign in — message for message with
  ## `waku_memory.connect`. Reads files only until the sign-in itself,
  ## so a dry listing never opens a browser.
  let elsewhere = "To use the same memory in Claude Code, Codex or Grok " &
    "Bot: " & memoryDocs
  var status = ""
  var spec = newJNull()
  try:
    (status, spec) = addMemoryServer(home)
  except ValueError as exc:
    return exc.msg
  let config = home / "mcp.json"
  if status == "conflict":
    return "'" & memoryName & "' in " & config & " already points at " &
      spec.jget("url").getStr() & ", not " & memoryUrl & ". " &
      "Change it there if you meant the hosted Waku Memory."
  let done = case status
    of "added": "Added Waku Memory to " & config & ". "
    of "moved": "Moved '" & memoryName & "' to " & memoryUrl &
      "; the old address refuses clients. "
    else: ""
  if spec.jget("auth_env").getStr().len > 0:
    return done & "Waku Memory is set up as '" & memoryName &
      "', using the API key in $" & spec.jget("auth_env").getStr() &
      ". Restart Waku to load its tools. " & elsewhere
  let token = authFilePath(home, memoryName)
  if fileExists(token) and status == "present":
    return "Waku Memory is already connected as " &
      mcpIdentity(token, toUnix(getTime())) &
      ". To switch accounts: waku mcp login " & memoryName & ". " & elsewhere
  let (ok, msg, identity) = signIn(home, memoryName)
  if not ok:
    return done & msg.strip() & " Help: " & memoryDocs
  return done & "Connected to Waku Memory as " & identity & ". " &
    "Restart Waku to load its tools (waku_memory_*). " & elsewhere

proc tregState*(home: string): tuple[state: string, detail: string] =
  ## Port of `treg.state`: where treg stands — "connected",
  ## "not_signed_in" or "not_added" — plus a detail line. Files only,
  ## so the Connections page can ask on every poll and never opens a
  ## browser. No `[mcp]` gate: the single binary always carries MCP (the
  ## same divergence `tregConnect` documents). The server is the one at
  ## the URL, or the one named treg wherever it points: a hosted
  ## container's relay entry carries the platform token in `auth_env`,
  ## and that is connected.
  let config = home / "mcp.json"
  var servers = newJArray()
  if fileExists(config):
    try:
      servers = parseJson(readFile(config)).jget("servers")
    except JsonParsingError:
      return ("not_added", config & " is not valid JSON")
  if servers.kind != JArray:
    return ("not_added", config & " is not valid JSON")
  var spec = newJNull()
  for s in servers:
    if s.kind == JObject and s.jget("url").getStr().strip(
        chars = {'/'}) == tregUrl.strip(chars = {'/'}):
      spec = s
      break
  if spec.kind != JObject:
    for s in servers:
      if s.kind == JObject and s.jget("name").getStr() == tregName:
        spec = s
        break
  if spec.kind != JObject:
    return ("not_added", "")
  if spec.jget("auth_env").getStr().len > 0:
    return ("connected",
      "using the key in $" & spec.jget("auth_env").getStr())
  if not spec.jget("oauth").getBool(false):
    return ("connected", "")
  let token = authFilePath(home, spec.jget("name").getStr())
  if not fileExists(token):
    return ("not_signed_in", "")
  return ("connected", "as " & mcpIdentity(token, toUnix(getTime())))

proc tregCard*(home: string): JsonNode =
  ## Port of `treg.card`: treg's card on the Connections page and the
  ## `mcp_connections` payload key the tab reads from `/api/data`.
  let (where, detail) = tregState(home)
  %*{"key": tregName, "name": "treg", "group": "Search & " &
    "Observability", "what": tregWhat, "state": where,
    "detail": detail}

proc addTregServer*(home: string): tuple[status: string, spec: JsonNode] =
  ## Make sure `mcp.json` names treg: "added", "present" (already there,
  ## under any name — the URL is the identity) or "conflict" (a `treg`
  ## entry pointing elsewhere on purpose, like a hosted container's relay,
  ## is left alone). No retired-address move: treg has no retired host.
  let config = home / "mcp.json"
  var data = %*{"servers": newJArray()}
  if fileExists(config):
    try:
      data = parseJson(readFile(config))
    except JsonParsingError:
      raise newException(ValueError,
        config & " is not valid JSON — fix it or move it aside, then run again.")
  if data.kind != JObject:
    data = %*{"servers": newJArray()}
  if data.jget("servers").kind != JArray:
    data["servers"] = newJArray()
  let servers = data["servers"]
  for spec in servers:
    if spec.jget("url").getStr().strip(chars = {'/'}) ==
        tregUrl.strip(chars = {'/'}):
      return ("present", spec)
  for spec in servers:
    if spec.jget("name").getStr() != tregName:
      continue
    return ("conflict", spec)
  let spec = %*{"name": tregName, "url": tregUrl, "oauth": true}
  servers.add(spec)
  createDir(home)
  writeFile(config, pretty(data, 2) & "\n")
  return ("added", spec)

proc tregConnect*(home: string, signIn: MemorySignInFn): string =
  ## Add the server, then sign in — message for message with
  ## `treg.connect`. Same shape as `memoryConnect` (the `mcp_cli.sign_in`
  ## step signs both in); only the names, the docs and the billing line
  ## differ. Reads files only until the sign-in itself, so a dry listing
  ## never opens a browser.
  var status = ""
  var spec = newJNull()
  try:
    (status, spec) = addTregServer(home)
  except ValueError as exc:
    return exc.msg
  let config = home / "mcp.json"
  if status == "conflict":
    return "'" & tregName & "' in " & config & " already points at " &
      spec.jget("url").getStr() & ", not " & tregUrl & ". " &
      "Change it there if you meant your own treg account."
  let done = if status == "added": "Added treg to " & config & ". "
    else: ""
  if spec.jget("auth_env").getStr().len > 0:
    return done & "treg is set up as '" & spec.jget("name").getStr() &
      "', using the key in $" & spec.jget("auth_env").getStr() &
      ". Restart Waku to load its tools."
  let name = spec.jget("name").getStr()
  let token = authFilePath(home, name)
  if fileExists(token) and status == "present":
    return "treg is already connected as " &
      mcpIdentity(token, toUnix(getTime())) &
      ". To switch accounts: waku mcp login " & name & "."
  let (ok, msg, identity) = signIn(home, name)
  if not ok:
    return done & msg.strip() & " Help: " & tregDocs
  return done & "Connected to treg as " & identity & ". " &
    "Restart Waku to load its tools (treg_*). treg bills your own account."

proc connectIntegration*(name, home: string, google: GoogleSeams,
    signIn: MemorySignInFn): string =
  ## One connector's reply for a KNOWN name; unknown names stay with
  ## `connectUnknown` (usage + exit 1), like Python.
  case name.strip().toLowerAscii()
  of "google":
    return googleConnect(home, google)
  of "waku-memory":
    return memoryConnect(home, signIn)
  of "treg":
    return tregConnect(home, signIn)
  else:
    return connectUnknown(name)

proc cliConnect*(argv: seq[string], home: string, google: GoogleSeams,
    signIn: MemorySignInFn): tuple[msg: string, code: int] =
  ## `waku connect` exit codes, like Python: usage/unknown → 1, a
  ## connector's own reply (even a refusal sentence) → 0.
  if argv.len == 0:
    return (connectUsage(), 1)
  let name = argv[0].strip().toLowerAscii()
  if name notin connectorNames:
    return (connectUnknown(argv[0]), 1)
  createDir(home)
  return (connectIntegration(name, home, google, signIn), 0)

proc waitGoogleCallbackLive*(port: int): string =
  ## The live loopback waiter: serve the one redirect on 127.0.0.1, answer
  ## the browser with a plain page, return the target. Real socket — never
  ## called in tests (they inject `WaitLoopbackFn` fakes).
  var target = ""
  var server = newAsyncHttpServer()
  proc onReq(req: Request) {.async.} =
    let got = req.url.path &
      (if req.url.query.len > 0: "?" & req.url.query else: "")
    target = got
    await req.respond(Http200, "<html><body>You signed in — back to the " &
      "terminal.</body></html>",
      newHttpHeaders([("Content-Type", "text/html; charset=utf-8")]))
    server.close()
  proc watchdog() {.async.} =
    await sleepAsync(300 * 1000)
    server.close()
  asyncCheck watchdog()
  try:
    waitFor server.serve(Port(port), onReq, "127.0.0.1")
  except OSError:
    raise newException(IOError, "port " & $port &
      " is in use — the sign-in redirect has nowhere to land. " &
      "Close whatever holds it and try again.")
  return target

proc exchangeGoogleLive*(tokenUri, body: string): tuple[ok: bool,
    doc: JsonNode] =
  ## The live code-for-token POST, through `http.nim`'s one helper so a
  ## `-d:wakuTls` build carries the context (and the default build
  ## refuses `https://` before any byte goes out). Real socket — never
  ## called in tests.
  var client = newTlsHttpClient(timeout = 30 * 1000)
  try:
    client.headers = newHttpHeaders(
      [("Content-Type", "application/x-www-form-urlencoded")])
    let res = client.postContent(tokenUri, body)
    let doc = parseJson(res)
    if doc.kind == JObject and doc.jget("access_token").getStr().len > 0:
      return (true, doc)
    return (false, newJNull())
  except CatchableError:
    return (false, newJNull())
