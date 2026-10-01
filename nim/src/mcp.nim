## MCP connector, phases 6a + 6b — config, stdio and streamable HTTP.
##
## Port of `waku/tools/mcp_client.py` (`MCPBridge`, `_model_safe_name`,
## `_auth_hint`, `_connect_one`/`_connect_all`/`_deadline`) for both
## transports plus `waku/tools/mcp_cli.py` (`list`/`login`/`logout`, JWT
## identity) without the OAuth browser flow (6c owns DCR/PKCE/callback
## and `FileTokenStorage`; `authFilePath`/`sanitizeServerName` here are
## the path half 6c will reuse).
##
## Hand-rolled JSON-RPC with stdlib (`json`, `osproc`, `net` via
## `httpclient`), like `http.nim` with SSE: the same three method shapes
## (`initialize`, `tools/list`, `tools/call`) travel over stdio lines or
## HTTP POSTs with `Mcp-Session-Id` + `Bearer` from `auth_env`.
##
## Every side effect travels through an injected seam (`ExchangeFn` for
## stdio lines, `HttpPostFn` for HTTP POSTs) with `env` as a `Table` and
## `home` as a plain path. The live adapters (`startStdioExchange`,
## `liveHttpPost`) are never called in tests, which replay recorded
## responses instead: zero real subprocesses, zero sockets.
## No new dependencies: stdlib only (AGENTS.md rule 3).

import std/base64
import std/httpclient
import std/json
import std/os
import std/osproc
import std/streams
import std/strtabs
import std/strutils
import std/tables

import ./tools

const mcpProtocolVersion* = "2024-11-05"
  ## Version announced in `initialize` (mirrors what the Python SDK
  ## negotiates; the demo server answers with the same line).

type
  McpServerSpec* = object
    ## One entry of `mcp.json`'s `servers` array. The transport is picked
    ## by shape — `url` for remote, `command` for local — exactly like
    ## Python's `_open_streams` (no `transport` field).
    name*: string
    command*: string
    args*: seq[string]
    env*: Table[string, string]
    url*: string
    authEnv*: string
    oauth*: bool

  McpToolMeta* = object
    ## One tool a server lists: the wire name plus what the model reads.
    name*: string
    description*: string
    inputSchema*: JsonNode

  ExchangeFn* = proc(requestLine: string): string {.closure.}
    ## One JSON-RPC request line -> one response line. `nil` means the
    ## server is not connected (mirrors `MCPBridge._sessions` missing).

proc isRemote*(spec: McpServerSpec): bool =
  ## True for `url` specs (streamable HTTP, connected in 6b).
  spec.url.len > 0

proc parseMcpConfig*(text: string): seq[McpServerSpec] =
  ## Parse an `mcp.json` document into server specs. Port of the
  ## `json.loads(...).get("servers", [])` line in `MCPBridge.start`:
  ## a missing `servers` key means no servers, but invalid JSON and a
  ## nameless entry raise (Python would `KeyError` on the latter).
  var root: JsonNode
  try:
    root = parseJson(text)
  except JsonParsingError as e:
    raise newException(ValueError, "mcp.json is not valid JSON: " & e.msg)
  if root.kind != JObject or not root.hasKey("servers"):
    return @[]
  for entry in root["servers"]:
    if not entry.hasKey("name") or entry["name"].kind != JString:
      raise newException(ValueError, "mcp.json server entry without 'name'")
    var spec = McpServerSpec(name: entry["name"].getStr(),
      env: initTable[string, string]())
    if entry.hasKey("command") and entry["command"].kind == JString:
      spec.command = entry["command"].getStr()
    if entry.hasKey("args") and entry["args"].kind == JArray:
      for a in entry["args"]:
        spec.args.add(a.getStr())
    if entry.hasKey("env") and entry["env"].kind == JObject:
      for k, v in entry["env"]:
        spec.env[k] = v.getStr()
    if entry.hasKey("url") and entry["url"].kind == JString:
      spec.url = entry["url"].getStr()
    if entry.hasKey("auth_env") and entry["auth_env"].kind == JString:
      spec.authEnv = entry["auth_env"].getStr()
    if entry.hasKey("oauth") and entry["oauth"].kind == JBool:
      spec.oauth = entry["oauth"].getBool()
    result.add(spec)

proc validateSpec*(spec: McpServerSpec,
                   env: Table[string, string]): string =
  ## `""` when the spec can be connected, else the exact refusal.
  ## Ports the three `ValueError`s in `_open_streams` verbatim
  ## (config-vs-config refuses precedence silently picked).
  if spec.url.len > 0 and spec.command.len > 0:
    return "server has both 'url' and 'command' — pick one transport"
  if spec.url.len == 0:
    # Divergence: Python `KeyError`s on `spec["command"]` here. A missing
    # transport gets a sentence naming the server instead of a traceback.
    if spec.command.len == 0:
      return "server '" & spec.name &
        "' names neither 'url' nor 'command' — pick one transport"
    return ""
  if spec.authEnv.len > 0 and spec.oauth:
    return "server names both 'auth_env' and 'oauth' — pick one"
  if spec.authEnv.len > 0 and not env.hasKey(spec.authEnv):
    # Fail here rather than connecting anonymously: the server would
    # answer 401 and the tools would simply be missing, which reads as
    # "the server is down" instead of "you did not export the key".
    return spec.authEnv & " is not set (named by 'auth_env' in mcp.json)"
  return ""

proc connectError*(spec: McpServerSpec,
                   env: Table[string, string]): string =
  ## `""` when this spec can be connected now. 6a returned an honest
  ## 6b-deferral for remote specs; 6b lifts that gate (streamable HTTP
  ## below), so only the three `validateSpec` refusals remain.
  let invalid = validateSpec(spec, env)
  if invalid.len > 0:
    return invalid
  return ""

proc modelSafeName*(server, tool: string): string =
  ## Port of `_model_safe_name`: `<server>_<tool>` reduced to what a
  ## model provider accepts (`^[a-zA-Z0-9_-]{1,64}$`). Only the name the
  ## model reads is rewritten — dispatch keeps the original tool name.
  var safe = ""
  for c in server & "_" & tool:
    if c.isAlphaNumeric() or c == '_' or c == '-':
      safe.add(c)
    else:
      safe.add('_')
  if safe.len <= 64:
    return safe
  # Keep the tail: the tool's own name is what disambiguates, and the
  # server prefix is the part a reader can afford to lose.
  return safe[^64 .. ^1].strip(leading = true, trailing = false,
    chars = {'_'})

proc authHint*(spec: McpServerSpec, authDir: string): string =
  ## Port of `_auth_hint`: what to tell someone whose remote server
  ## would not connect. An `oauth` server has no `auth_env`, so it is
  ## never pointed at one.
  if spec.oauth:
    return "  " & spec.url &
      " — sign-in did not complete. Run waku again to use a token " &
      "that was saved, or delete " & authDir & " to start over"
  let named = if spec.authEnv.len > 0: spec.authEnv else: "auth_env"
  return "  " & spec.url & " — if the server requires auth, check that " &
    named & " holds a current credential"

proc rpcRequest(id: int, meth: string, params: JsonNode): string =
  ## One JSON-RPC 2.0 request as a single newline-terminated line
  ## (stdio framing, as the Python SDK's `stdio_client` speaks it).
  var node = %*{"jsonrpc": "2.0", "id": id, "method": meth}
  if params.kind != JNull:
    node["params"] = params
  return $node & "\n"

proc initializeReq*(id: int): string =
  ## Port of `ClientSession.initialize`'s wire shape.
  rpcRequest(id, "initialize", %*{
    "protocolVersion": mcpProtocolVersion,
    "capabilities": {},
    "clientInfo": {"name": "Waku", "version": "nim-port"}})

proc initializedNote*(): string =
  ## The `notifications/initialized` ack after a successful initialize
  ## (no `id`, so no response is read for it).
  "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"

proc listToolsReq*(id: int): string =
  ## Port of `session.list_tools()`' wire shape.
  rpcRequest(id, "tools/list", %*{})

proc callToolReq*(id: int, name: string, args: JsonNode): string =
  ## Port of `session.call_tool(tool, args)`' wire shape.
  rpcRequest(id, "tools/call", %*{"name": name, "arguments": args})

proc checkResult*(respLine: string, meth: string): JsonNode =
  ## Parse one response line: return `result`, or raise naming the
  ## server's own error message (never a bare code).
  var node: JsonNode
  try:
    node = parseJson(respLine.strip())
  except JsonParsingError as e:
    raise newException(ValueError,
      "MCP " & meth & " returned invalid JSON: " & e.msg)
  if node.hasKey("error"):
    let err = node["error"]
    let msg = if err.hasKey("message") and
        err["message"].kind == JString: err["message"].getStr()
      else: $err
    raise newException(ValueError, "MCP " & meth & " failed: " & msg)
  if not node.hasKey("result"):
    raise newException(ValueError,
      "MCP " & meth & " returned no result")
  return node["result"]

proc parseToolList*(respLine: string): seq[McpToolMeta] =
  ## Port of the metadata mapping in `_connect_one`: `inputSchema`
  ## defaults to an empty object (Python covers both SDK spellings
  ## `input_schema`/`inputSchema`; the wire here always says
  ## `inputSchema`, so one lookup suffices).
  let res = checkResult(respLine, "tools/list")
  if not res.hasKey("tools") or res["tools"].kind != JArray:
    return @[]
  for t in res["tools"]:
    var meta = McpToolMeta(inputSchema: %*{"type": "object",
      "properties": {}})
    meta.name = t{"name"}.getStr()
    if t.hasKey("description") and t["description"].kind == JString:
      meta.description = t["description"].getStr()
    if t.hasKey("inputSchema") and t["inputSchema"].kind == JObject:
      meta.inputSchema = t["inputSchema"]
    result.add(meta)

proc parseCallResult*(respLine: string): string =
  ## Port of `_acall`'s content join: text blocks concatenated,
  ## anything else marked, silence said out loud.
  let res = checkResult(respLine, "tools/call")
  var parts: seq[string] = @[]
  if res.hasKey("content") and res["content"].kind == JArray:
    for blk in res["content"]:
      if blk.hasKey("text") and blk["text"].kind == JString:
        parts.add(blk["text"].getStr())
      else:
        parts.add("[non-text content]")
  if parts.len == 0:
    return "(no output)"
  return parts.join("\n")

proc listToolsVia*(exchange: ExchangeFn,
                   spec: McpServerSpec): seq[McpToolMeta] =
  ## `initialize` + `initialized` + `tools/list` over one stdio server.
  ## Failures propagate: the caller (6b's bridge) skips that server
  ## with a warning, like `_connect_all`. Port of `_connect_one`.
  discard exchange(initializeReq(1))
  discard exchange(initializedNote())
  return parseToolList(exchange(listToolsReq(2)))

proc callToolVia*(exchange: ExchangeFn, server, tool: string,
                  args: JsonNode): string =
  ## Port of `MCPBridge.call` + `_acall`: failures read as text, never
  ## raise — the model observes the error instead of the loop crashing.
  if exchange == nil:
    return "MCP server '" & server & "' is not connected."
  try:
    return parseCallResult(exchange(callToolReq(3, tool, args)))
  except CatchableError as exc:
    return "MCP call " & server & "_" & tool & " failed: " & exc.msg

proc toRegistryTools*(server: string, metas: seq[McpToolMeta],
                      exchange: ExchangeFn): seq[Tool] =
  ## Port of the `Tool(...)` construction in `MCPBridge.start`: the
  ## model reads `modelSafeName`, the server hears its own `meta.name`.
  for meta in metas:
    let tname = meta.name
    let exc = exchange
    result.add(Tool(
      name: modelSafeName(server, tname),
      description: "[MCP:" & server & "] " & meta.description,
      inputSchema: meta.inputSchema,
      fn: proc(args: JsonNode): string {.closure.} =
        callToolVia(exc, server, tname, args)))

proc startStdioExchange*(command: string, args: seq[string],
                         env: Table[string, string]): ExchangeFn =
  ## Live stdio transport: launch the server and trade newline-delimited
  ## JSON-RPC lines with it. Real subprocess — never called in tests
  ## (they inject `ExchangeFn` fakes with recorded responses).
  var merged = initTable[string, string]()
  for k, v in envPairs():
    merged[k] = v
  for k, v in env:
    merged[k] = v
  var stab = newStringTable()
  for k, v in merged:
    stab[k] = v
  let child = startProcess(command, args = args, env = stab,
    options = {poUsePath, poStdErrToStdOut})
  result = proc(requestLine: string): string {.closure.} =
    child.inputStream.writeLine(requestLine.strip())
    child.inputStream.flush()
    return child.outputStream.readLine() & "\n"

## Phase 6b — streamable HTTP + bridge + `waku mcp` CLI helpers.
##
## Port of the remote half of `mcp_client.py` (`_open_streams` HTTP
## branch, `_connect_one` remote, `_connect_all`, `_deadline`) and of
## `mcp_cli.py` (`list`/`login`/`logout`, `_claims`/`_identity`). OAuth
## (DCR/PKCE/callback/`FileTokenStorage`) stays in 6c: specs with
## `oauth` parse here, but `mcpLogin` refuses them naming 6c.

const signInTimeout* = 300.0
  ## Port of `SIGN_IN_TIMEOUT` in `mcp_oauth.py`: human time for the
  ## browser consent screen. `connectionDeadline` waits past it when an
  ## oauth server has no token yet; 6c owns the callback server that
  ## this number also bounds.

type
  HttpResult* = object
    ## One stubbed-or-live HTTP POST outcome: status, body text, and the
    ## response's `Mcp-Session-Id` (empty when the server sent none).
    status*: int
    body*: string
    sessionId*: string

  HttpPostFn* = proc(url, body, sessionId, bearer: string): HttpResult {.closure.}
    ## POST one JSON-RPC body to `url`. `sessionId` is `""` on the first
    ## `initialize`, then the echoed session; `bearer` is `""` when the
    ## spec names no `auth_env`. Tests inject recorded responses; the
    ## binary passes `liveHttpPost`. Never opens a socket in tests.

  StdioFactory* = proc(spec: McpServerSpec): ExchangeFn {.closure.}
    ## Build one server's stdio exchange. Tests inject recorded fakes;
    ## the binary passes a `startStdioExchange` wrapper.

  McpConnectResult* = object
    ## What `connectAll` keeps: every connected server's registry tools
    ## plus one warning line per skipped server (and its auth hint when
    ## remote), so callers print instead of the bridge printing.
    tools*: seq[Tool]
    warnings*: seq[string]

proc sanitizeServerName*(name: string): string =
  ## Port of `_sanitise` in `mcp_oauth.py`: a user-supplied server name
  ## made filename-safe (anything outside `[A-Za-z0-9-_]` becomes `_`,
  ## capped at 64 chars). Defined here so 6b token paths and 6c storage
  ## share one spelling. Divergence: ASCII alphanumerics only (Python's
  ## `str.isalnum` accepts Unicode); server names are config keys.
  for c in name:
    if c.isAlphaNumeric() or c == '-' or c == '_':
      result.add(c)
    else:
      result.add('_')
  if result.len > 64:
    result = result[0 .. 63]

proc authFilePath*(home, serverName: string): string =
  ## Port of `FileTokenStorage(home, name)._path`: one JSON file per
  ## server under `mcp-auth/`. 6c owns the storage layer; this is only
  ## the path it will reuse (existence checks for retry/deadline/CLI).
  home / "mcp-auth" / (sanitizeServerName(serverName) & ".json")

proc hasToken*(home: string, spec: McpServerSpec): bool =
  ## Port of `_token_exists`: read from disk, not remembered, because
  ## the token is written by a different flow than this one. False for
  ## non-oauth specs (they never mint a file).
  if not spec.oauth:
    return false
  return fileExists(authFilePath(home, spec.name))

proc connectionDeadline*(specs: seq[McpServerSpec], home: string,
                          timeout: float): float =
  ## Port of `_deadline`: twice the per-call timeout, unless an oauth
  ## server still has no token — then the browser flow is about to take
  ## human minutes, and giving up early would read as a broken server.
  ## The margin over `signInTimeout` matters (the callback must not
  ## outlive the wait holding it).
  for s in specs:
    if s.oauth and not hasToken(home, s):
      return signInTimeout + 60.0
  return timeout * 2.0

proc extractJsonResponse*(body: string): string =
  ## The JSON-RPC response inside an HTTP body: plain JSON, or the last
  ## `data:` payload when the server answers with an SSE stream (the
  ## streamable-HTTP framing the Python SDK's `streamable_http_client`
  ## already unwraps). `[DONE]` and empty payloads are skipped. The old
  ## HTTP+SSE transport stays unsupported, like in Python.
  var last = ""
  for line in body.splitLines():
    let t = line.strip()
    if t.startsWith("data:"):
      let payload = t[5 .. ^1].strip()
      if payload.len == 0 or payload == "[DONE]":
        continue
      last = payload
  if last.len > 0:
    return last
  return body.strip()

proc bearerFor*(spec: McpServerSpec,
                 env: Table[string, string]): string =
  ## The `Authorization: Bearer` value for `spec` ("" when the spec
  ## names no `auth_env`). Port of the header branch of `_open_streams`:
  ## the variable's VALUE travels, never the secret in `mcp.json`.
  ## A missing variable reads as "" here; `validateSpec` already
  ## refused it upfront so the bridge warns instead of connecting
  ## anonymously against a 401 that looks like an outage.
  if spec.authEnv.len == 0:
    return ""
  if env.hasKey(spec.authEnv):
    return env[spec.authEnv]
  return ""

proc listToolsViaHttp*(post: HttpPostFn, spec: McpServerSpec,
                        env: Table[string, string]): tuple[metas: seq[McpToolMeta],
                          sessionId: string] =
  ## `initialize` + `tools/list` over one remote server. Port of the
  ## remote half of `_connect_one`: failures raise so the caller (the
  ## bridge) can skip that server with a warning, like `_connect_all`.
  ## A 401 raises `IOError` (never `ValueError`) so the bridge still
  ## appends `authHint` — config refusals stay `ValueError`-free here
  ## because `connectAll` validates before calling.
  if post == nil:
    raise newException(IOError,
      "MCP server '" & spec.name & "' is not connected.")
  let bearer = bearerFor(spec, env)
  let initRes = post(spec.url, initializeReq(1), "", bearer)
  if initRes.status == 401:
    raise newException(IOError,
      "MCP initialize failed with status 401 for '" & spec.name & "'")
  if initRes.status < 200 or initRes.status >= 300:
    raise newException(IOError, "MCP initialize failed with status " &
      $initRes.status & " for '" & spec.name & "'")
  discard checkResult(extractJsonResponse(initRes.body), "initialize")
  let listRes = post(spec.url, listToolsReq(2), initRes.sessionId, bearer)
  if listRes.status == 401:
    raise newException(IOError,
      "MCP tools/list failed with status 401 for '" & spec.name & "'")
  if listRes.status < 200 or listRes.status >= 300:
    raise newException(IOError, "MCP tools/list failed with status " &
      $listRes.status & " for '" & spec.name & "'")
  let metas = parseToolList(extractJsonResponse(listRes.body))
  let sid = if listRes.sessionId.len > 0: listRes.sessionId
            else: initRes.sessionId
  return (metas, sid)

proc callToolViaHttp*(post: HttpPostFn, url, sessionId, bearer, server,
                       tool: string, args: JsonNode): string =
  ## Port of `MCPBridge.call` + `_acall` for the HTTP transport:
  ## failures read as text, never raise — the model observes the error
  ## instead of the loop crashing.
  if post == nil:
    return "MCP server '" & server & "' is not connected."
  try:
    let res = post(url, callToolReq(3, tool, args), sessionId, bearer)
    if res.status < 200 or res.status >= 300:
      return "MCP call " & server & "_" & tool & " failed: HTTP " &
        $res.status
    return parseCallResult(extractJsonResponse(res.body))
  except CatchableError as exc:
    return "MCP call " & server & "_" & tool & " failed: " & exc.msg

proc toRegistryToolsHttp*(server: string, metas: seq[McpToolMeta],
                            post: HttpPostFn, url, sessionId,
                            bearer: string): seq[Tool] =
  ## Port of the `Tool(...)` construction in `MCPBridge.start` for
  ## remote servers: the model reads `modelSafeName`, the server hears
  ## its own `meta.name` over the recorded `HttpPostFn`.
  for meta in metas:
    let tname = meta.name
    let pp = post
    let uu = url
    let ss = sessionId
    let bb = bearer
    result.add(Tool(
      name: modelSafeName(server, tname),
      description: "[MCP:" & server & "] " & meta.description,
      inputSchema: meta.inputSchema,
      fn: proc(args: JsonNode): string {.closure.} =
        callToolViaHttp(pp, uu, ss, bb, server, tname, args)))

proc connectOneHttp(post: HttpPostFn, spec: McpServerSpec,
                     env: Table[string, string]): tuple[tools: seq[Tool],
                       sessionId: string] =
  ## List one remote server and map its tools (single-attempt helper
  ## for `connectAll`; retry re-calls `listToolsViaHttp` directly).
  let (metas, sid) = listToolsViaHttp(post, spec, env)
  let bearer = bearerFor(spec, env)
  return (toRegistryToolsHttp(spec.name, metas, post, spec.url, sid,
    bearer), sid)

proc connectAll*(specs: seq[McpServerSpec], env: Table[string, string],
                  home: string, timeout: float = 30.0,
                  makeExchange: StdioFactory = nil,
                  httpPost: HttpPostFn = nil): McpConnectResult =
  ## Port of `_connect_all` + the tool mapping in `start`: connect
  ## every server, skip a bad one with a warning (plus `authHint` when
  ## remote), retry once when a token appears after the first failure
  ## (the sign-in completed while the attempt was already failing),
  ## and compute `connectionDeadline` for parity.
  ##
  ## Divergence: Python waits on an asyncio bridge (`fut.result` with
  ## the deadline); this port is synchronous, so the deadline is
  ## computed but not awaited — injected transports are instant in
  ## tests and the live HTTP client owns its own 30s timeout.
  ## Config refusals are detected upfront via `validateSpec` (same
  ## observable warnings as Python's `ValueError`-without-hint path)
  ## instead of branching on the exception type.
  result = McpConnectResult(tools: @[], warnings: @[])
  discard connectionDeadline(specs, home, timeout)
  for spec in specs:
    let invalid = validateSpec(spec, env)
    if invalid.len > 0:
      result.warnings.add("MCP server '" & spec.name &
        "' failed to connect: " & invalid)
      continue
    let hadToken = hasToken(home, spec)
    var firstErr = ""
    var connected = false
    try:
      if spec.isRemote:
        for t in connectOneHttp(httpPost, spec, env).tools:
          result.tools.add(t)
      else:
        if makeExchange == nil:
          raise newException(IOError, "no stdio transport for '" &
            spec.name & "'")
        let exc = makeExchange(spec)
        for t in toRegistryTools(spec.name, listToolsVia(exc, spec), exc):
          result.tools.add(t)
      connected = true
    except CatchableError as exc:
      firstErr = exc.msg
    if connected:
      continue
    if not hadToken and hasToken(home, spec):
      result.warnings.add("  signed in — reconnecting to '" & spec.name & "'")
      try:
        if spec.isRemote:
          for t in connectOneHttp(httpPost, spec, env).tools:
            result.tools.add(t)
        else:
          if makeExchange == nil:
            raise newException(IOError, "no stdio transport for '" &
              spec.name & "'")
          let exc = makeExchange(spec)
          for t in toRegistryTools(spec.name, listToolsVia(exc, spec), exc):
            result.tools.add(t)
        continue
      except CatchableError as exc:
        firstErr = exc.msg
    result.warnings.add("MCP server '" & spec.name &
      "' failed to connect: " & firstErr)
    if spec.isRemote:
      result.warnings.add(authHint(spec, home / "mcp-auth"))

proc liveHttpPost*(url, body, sessionId, bearer: string): HttpResult =
  ## Live streamable-HTTP transport: one POST with the MCP headers.
  ## Real socket — never called in tests (they inject `HttpPostFn`
  ## fakes with recorded responses). Port of the client half of
  ## `_open_streams` for `url` specs (`create_mcp_http_client` +
  ## `streamable_http_client` in the SDK).
  var client = newHttpClient(timeout = 30000)
  try:
    var hdrs = newHttpHeaders([("Content-Type", "application/json"),
      ("Accept", "application/json, text/event-stream")])
    if bearer.len > 0:
      hdrs["Authorization"] = "Bearer " & bearer
    if sessionId.len > 0:
      hdrs["Mcp-Session-Id"] = sessionId
    let resp = client.request(url, HttpPost, body, hdrs)
    var code = 0
    try:
      code = parseInt(resp.status.split(' ')[0])
    except ValueError:
      discard
    var sid = sessionId
    try:
      if resp.headers.hasKey("Mcp-Session-Id"):
        let v: string = resp.headers["Mcp-Session-Id"]
        if v.len > 0:
          sid = v
    except CatchableError:
      discard
    var text = ""
    try:
      text = resp.body
    except CatchableError as exc:
      raise newException(IOError, exc.msg)
    return HttpResult(status: code, body: text, sessionId: sid)
  finally:
    try:
      client.close()
    except CatchableError:
      discard

proc decodeClaims*(token: string): JsonNode =
  ## Port of `_claims` in `mcp_cli.py`: the token's own claims, read
  ## WITHOUT verifying the signature. Deliberately unverified: this is
  ## our own stored credential described back to its owner, not a token
  ## being trusted for access (verification is the server's job on every
  ## call). Anything unparsable reads as no claims.
  result = newJObject()
  let parts = token.split('.')
  if parts.len != 3:
    return newJObject()
  var body = parts[1].replace("-", "+").replace("_", "/")
  while body.len mod 4 != 0:
    body.add('=')
  var raw = ""
  try:
    raw = decode(body)
  except CatchableError:
    return newJObject()
  try:
    let node = parseJson(raw)
    if node.kind == JObject:
      return node
  except JsonParsingError:
    discard
  return newJObject()

proc mcpIdentity*(authFile: string, nowUnix: int64): string =
  ## Port of `_identity` in `mcp_cli.py`: one line saying whose token
  ## this is, or why there is none. `nowUnix` travels by parameter so
  ## tests pin time (Python reads `datetime.now(UTC)` inline).
  if not fileExists(authFile):
    return "not signed in"
  var stored: JsonNode
  try:
    stored = parseJson(readFile(authFile))
  except CatchableError:
    return "unreadable — will sign in again"
  var token = ""
  if stored.kind == JObject and stored.hasKey("tokens") and
      stored["tokens"].kind == JObject:
    let toks = stored["tokens"]
    if toks.hasKey("access_token") and toks["access_token"].kind == JString:
      token = toks["access_token"].getStr()
  let claims = decodeClaims(token)
  var who = "unknown account"
  if claims.hasKey("email") and claims["email"].kind == JString and
      claims["email"].getStr().len > 0:
    who = claims["email"].getStr()
  elif claims.hasKey("sub") and claims["sub"].kind == JString and
      claims["sub"].getStr().len > 0:
    who = claims["sub"].getStr()
  if not claims.hasKey("exp"):
    return who
  let expNode = claims["exp"]
  var exp: int64 = 0
  if expNode.kind == JInt:
    exp = expNode.getBiggestInt()
  elif expNode.kind == JFloat:
    exp = int64(expNode.getFloat())
  else:
    return who
  if exp == 0:
    return who
  let left = exp - nowUnix
  if left <= 0:
    return who & " — token expired, refreshes on next use"
  let minutes = left div 60
  if minutes >= 60:
    return who & " — " & $(minutes div 60) & "h left"
  return who & " — " & $minutes & "m left"

proc loadMcpServers*(home: string): seq[McpServerSpec] =
  ## Port of `_servers` in `mcp_cli.py`: `home/mcp.json` or no servers
  ## when the file is absent. Invalid JSON raises `ValueError` naming
  ## the file (Python prints it, then `SystemExit(1)` — the CLI maps
  ## that to stderr + exit 1).
  let path = home / "mcp.json"
  if not fileExists(path):
    return @[]
  var text = ""
  try:
    text = readFile(path)
  except OSError as exc:
    raise newException(ValueError, path & " is not readable: " & exc.msg)
  try:
    return parseMcpConfig(text)
  except ValueError as exc:
    if "not valid JSON" in exc.msg:
      raise newException(ValueError, path & " is not valid JSON: " & exc.msg)
    raise

proc mcpListLines*(home: string, nowUnix: int64): seq[string] =
  ## Port of `_list` in `mcp_cli.py`, without the printing: one block
  ## per server (what is configured, and who each server knows you as).
  ## Callers echo each line. Raises `ValueError` on invalid JSON via
  ## `loadMcpServers`.
  let servers = loadMcpServers(home)
  if servers.len == 0:
    return @["No MCP servers configured. See docs/integrations.md, or write " &
      home / "mcp.json"]
  for spec in servers:
    if spec.url.len > 0:
      var auth = "no credential"
      if spec.oauth:
        auth = "oauth · " & mcpIdentity(authFilePath(home, spec.name), nowUnix)
      elif spec.authEnv.len > 0:
        auth = "api key · $" & spec.authEnv
      result.add("  " & spec.name)
      result.add("    " & spec.url)
      result.add("    " & auth)
    else:
      result.add("  " & spec.name)
      result.add("    " & spec.command & " (local process)")
      result.add("    no credential needed")

proc mcpLogout*(home, name: string): tuple[msg: string, code: int] =
  ## Port of `_logout` in `mcp_cli.py`: forget the token file.
  let path = authFilePath(home, name)
  if not fileExists(path):
    return ("'" & name & "' is not signed in", 0)
  try:
    removeFile(path)
  except OSError as exc:
    return ("could not sign out of '" & name & "': " & exc.msg, 1)
  return ("Signed out of '" & name &
    "'. The next run will sign in again.", 0)

proc mcpLogin*(home, name: string, env: Table[string, string],
                httpPost: HttpPostFn, makeExchange: StdioFactory,
                nowUnix: int64, timeout: float = 30.0): tuple[ok: bool,
                  msg: string] =
  ## Port of `sign_in` in `mcp_cli.py`: forget the token, then connect
  ## — which is what triggers a sign-in. `nowUnix` is accepted for
  ## symmetry with `mcpIdentity` (non-oauth logins report the bridge,
  ## not a token file, so it goes unused there).
  ##
  ## Divergence: Python judges success by "a token now exists", which
  ## is oauth-shaped — a key/stdio server never writes one, so every
  ## such login would read as failed. This port reports the bridge
  ## result for non-oauth servers (tools connected vs warnings) and
  ## reserves the token-file check for 6c's oauth flow. An `oauth`
  ## server refuses honestly naming 6c (no DCR/PKCE/callback yet).
  discard nowUnix
  let servers = loadMcpServers(home)
  var spec: McpServerSpec
  var found = false
  for s in servers:
    if s.name == name:
      spec = s
      found = true
      break
  if not found:
    var names: seq[string] = @[]
    for s in servers:
      names.add(s.name)
    let cfg = if names.len > 0: names.join(", ") else: "none"
    return (false, "No server called '" & name & "' in " & home / "mcp.json" &
      ". Configured: " & cfg)
  let path = authFilePath(home, name)
  if fileExists(path):
    try:
      removeFile(path)
    except OSError:
      discard
  if spec.oauth:
    return (false, "server '" & name &
      "' needs the OAuth browser flow — arrives in 6c " &
      "(no DCR/PKCE/callback/token storage yet)")
  let res = connectAll(@[spec], env, home, timeout, makeExchange, httpPost)
  if res.warnings.len == 0:
    return (true, "\n  " & name & " connected (" & $res.tools.len &
      " tools).")
  return (false, "\n  Sign-in did not complete — '" & name &
    "' has no token.\n" & res.warnings.join("\n"))
