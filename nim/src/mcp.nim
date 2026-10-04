## MCP connector, phases 6a + 6b + 6c — config, stdio, streamable HTTP,
## OAuth browser flow.
##
## Port of `waku/tools/mcp_client.py` (`MCPBridge`, `_model_safe_name`,
## `_auth_hint`, `_connect_one`/`_connect_all`/`_deadline`) for both
## transports plus `waku/tools/mcp_cli.py` (`list`/`login`/`logout`, JWT
## identity) plus `waku/tools/mcp_oauth.py` (DCR/PKCE/loopback callback
## and `FileTokenStorage`; `authFilePath`/`sanitizeServerName` here are
## the path half 6c reuses).
##
## Hand-rolled JSON-RPC with stdlib (`json`, `osproc`, `net` via
## `httpclient`), like `http.nim` with SSE: the same three method shapes
## (`initialize`, `tools/list`, `tools/call`) travel over stdio lines or
## HTTP POSTs with `Mcp-Session-Id` + `Bearer` from `auth_env`.
##
## Every side effect travels through an injected seam (`ExchangeFn` for
## stdio lines, `HttpPostFn`/`HttpGetFn` for HTTP, `BrowserFn` /
## `CallbackWaitFn` / `RandIntFn` for the interactive OAuth half,
## `SleepFn` for the connection deadline) with `env` as a `Table` and
## `home` as a plain path. The live adapters (`startStdioExchange`,
## `liveHttpPost`) are never called in tests, which replay recorded
## responses instead: zero real subprocesses, zero sockets, zero browser.
## No new dependencies: stdlib only (AGENTS.md rule 3).
##
## The bridge is synchronous by design, and that is its whole
## concurrency story: `connectAll` walks the servers one at a time,
## like the `for spec in servers` loop in `_connect_all` it ports, with
## no thread and no event loop of its own (precedent: dashboard 8b,
## gateways 7d1). Python wraps that same serial loop in a daemon thread
## so the caller can block on `fut.result(deadline)`; this port waits
## for itself instead — `connectionDeadline` is waited out, not
## computed and dropped — and a blocking transport keeps its own
## timeout (`liveHttpPost` still has its 30 s). Multiplexing servers
## over one connection stays unbuilt by decision, the way the JSON-RPC
## ids 1/2/3 are: a `mcp.json` does not need it, and a follow-up is
## not a silent change (the 6a decision).

import std/asyncdispatch
import std/asynchttpserver
import std/base64
import std/browsers
import std/httpclient
import std/httpcore
import std/json
import std/os
import std/osproc
import std/streams
import std/strtabs
import std/strutils
import std/sysrand
import std/tables
import std/times

import ./http
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

proc toolFor*(server, tname: string, meta: McpToolMeta,
              exchange: ExchangeFn): Tool =
  ## One server tool as a `Tool`: the model reads `modelSafeName`, the
  ## server hears its own `meta.name`. A PROC, not a loop body, on
  ## purpose: a `let` inside a `for` is ONE binding that every closure
  ## shares, so a loop-built registry called the LAST tool of the list
  ## under every name (found live against `engram mcp`: `mem_search`
  ## asked the server for `mem_update`). Parameters are per call, so each
  ## closure here keeps its own name.
  result = Tool(
    name: modelSafeName(server, tname),
    description: "[MCP:" & server & "] " & meta.description,
    inputSchema: meta.inputSchema,
    fn: proc(args: JsonNode): string {.closure.} =
      callToolVia(exchange, server, tname, args))

proc toRegistryTools*(server: string, metas: seq[McpToolMeta],
                      exchange: ExchangeFn): seq[Tool] =
  ## Port of the `Tool(...)` construction in `MCPBridge.start`, one
  ## `toolFor` per meta (see why it is a proc).
  for meta in metas:
    result.add(toolFor(server, meta.name, meta, exchange))

proc expectsReply*(line: string): bool =
  ## JSON-RPC framing rule for the stdio transport: a message without
  ## an `id` member is a notification — the server sends no response
  ## line for it, so the transport must not read after writing one.
  ## Reading anyway blocks until the server speaks again, which for
  ## `notifications/initialized` is never (found live against
  ## `engram mcp`: exactly two reply lines for initialize + tools/list).
  ## Unparseable lines default to true so the read surfaces the real
  ## error instead of silently swallowing the exchange.
  try:
    result = parseJson(line.strip()).hasKey("id")
  except JsonParsingError:
    result = true

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
    if not expectsReply(requestLine):
      return ""
    return child.outputStream.readLine() & "\n"

## Phase 6b — streamable HTTP + bridge + `waku mcp` CLI helpers.
##
## Port of the remote half of `mcp_client.py` (`_open_streams` HTTP
## branch, `_connect_one` remote, `_connect_all`, `_deadline`) and of
## `mcp_cli.py` (`list`/`login`/`logout`, `_claims`/`_identity`). The
## bridge prefers a fresh stored oauth token when the spec names no
## `auth_env` (6c's `storedAccessToken`, refreshed silently like the
## SDK did); `mcpLogin` runs the injected browser flow for oauth.

const signInTimeout* = 300.0
  ## Port of `SIGN_IN_TIMEOUT` in `mcp_oauth.py`: human time for the
  ## browser consent screen. `connectionDeadline` waits past it when an
  ## oauth server has no token yet; 6c owns the callback server that
  ## this number also bounds.

const signInPollSeconds* = 0.5
  ## How often a wait re-reads the thing a person is about to finish.
  ## One cadence for both waits on human time: the loopback callback in
  ## 6c (`callbackPollAttempts`) and the token file the bridge polls
  ## below. A 0.5s slice is short enough that a sign-in that finishes
  ## costs half a second, long enough that 360 s of polling is 720
  ## cheap file checks.

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

  SleepFn* = proc(seconds: float) {.closure.}
    ## Wait `seconds` while the bridge holds a connection deadline.
    ## Injected because 360 s of sign-in is a test that never finishes,
    ## and the suite's promise is zero real waiting like its promise of
    ## zero network. A nil seam means the live `liveSleep`.

  McpConnectResult* = object
    ## What `connectAll` keeps: every connected server's registry tools
    ## plus one warning line per skipped server (and its auth hint when
    ## remote), so callers print instead of the bridge printing.
    tools*: seq[Tool]
    warnings*: seq[string]

  OAuthFlowFn* = proc(home: string,
      spec: McpServerSpec): tuple[ok: bool, msg: string,
      timedOut: bool] {.closure.}
    ## One injected browser flow for `mcpLogin` (6c): nil means no
    ## interactive context is wired — offline tests, and `runMcpCmd`
    ## until its one-line follow-up passes `oauthFlowWith` over the
    ## live seams. The triple mirrors `oauthSignIn`: `timedOut` keeps
    ## the CLI's special-case message honest. Defined here (next to
    ## the other seams) because `mcpLogin` below takes one.

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

proc storedBearerFor(home: string, spec: McpServerSpec,
    env: Table[string, string], httpPost: HttpPostFn,
    nowUnix: int64): string
  ## 6c bearer resolution for the bridge (defined in the 6c section
  ## below): a fresh-or-refreshed stored oauth token when the spec
  ## names no `auth_env`, else "". Forward-declared: the bridge
  ## below runs before the 6c section in file order.

proc listToolsViaHttp*(post: HttpPostFn, spec: McpServerSpec,
                        env: Table[string, string],
                        storedBearer: string = ""): tuple[metas: seq[McpToolMeta],
                          sessionId: string] =
  ## `initialize` + `tools/list` over one remote server. Port of the
  ## remote half of `_connect_one`: failures raise so the caller (the
  ## bridge) can skip that server with a warning, like `_connect_all`.
  ## A 401 raises `IOError` (never `ValueError`) so the bridge still
  ## appends `authHint` — config refusals stay `ValueError`-free here
  ## because `connectAll` validates before calling. `storedBearer` is
  ## 6c's cached oauth token, used only when the spec names no
  ## `auth_env` (explicit config beats a cached file).
  if post == nil:
    raise newException(IOError,
      "MCP server '" & spec.name & "' is not connected.")
  let bearer = block:
    # Explicit config beats a cached file: `auth_env` first, the
    # stored oauth token only when the spec names no variable.
    let fromEnv = bearerFor(spec, env)
    if fromEnv.len > 0: fromEnv else: storedBearer
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
                     env: Table[string, string],
                     storedBearer: string = ""): tuple[tools: seq[Tool],
                       sessionId: string] =
  ## List one remote server and map its tools (single-attempt helper
  ## for `connectAll`; retry re-calls `listToolsViaHttp` directly).
  ## `storedBearer` is 6c's cached oauth token, same rule as
  ## `listToolsViaHttp`: only when the spec names no `auth_env`.
  let (metas, sid) = listToolsViaHttp(post, spec, env, storedBearer)
  let fromEnv = bearerFor(spec, env)
  let bearer = if fromEnv.len > 0: fromEnv else: storedBearer
  return (toRegistryToolsHttp(spec.name, metas, post, spec.url, sid,
    bearer), sid)

proc liveSleep*(seconds: float) =
  ## The live `SleepFn`: the real wait a person spends on a consent
  ## screen. `os.sleep` counts milliseconds, so a sub-millisecond poll
  ## rounds to no wait at all rather than to a second.
  os.sleep(int(seconds * 1000))

proc waitForToken(home: string, spec: McpServerSpec, stopAt: float,
                   pinned: bool, startAt: float,
                   sleeper: SleepFn): bool =
  ## Whether the token file a sign-in writes lands before `stopAt`.
  ## This is the one thing Python's daemon thread covers and serial
  ## code cannot: the attempt that triggered the browser has already
  ## failed, a person is still reading the consent screen, and the
  ## caller is still inside `fut.result(deadline)` when the callback
  ## writes the file. Here the bridge polls the file itself and gives
  ## up at the deadline, so a server that is never signed in costs one
  ## deadline and no more (the file decides, like Python's).
  ##
  ## A pinned clock (tests pass `nowUnix`) advances with the sleep, so
  ## human time costs a loop and no wall clock; a live call re-reads the
  ## clock after every sleep, because the sleep itself moved it.
  let nap = if sleeper != nil: sleeper else: liveSleep
  var at = startAt
  while at < stopAt:
    if hasToken(home, spec):
      return true
    nap(signInPollSeconds)
    at = if pinned: at + signInPollSeconds else: float(getTime().toUnix())
  return hasToken(home, spec)

proc connectAll*(specs: seq[McpServerSpec], env: Table[string, string],
                  home: string, timeout: float = 30.0,
                  makeExchange: StdioFactory = nil,
                  httpPost: HttpPostFn = nil,
                  nowUnix: int64 = 0,
                  sleeper: SleepFn = nil): McpConnectResult =
  ## Port of `_connect_all` + the tool mapping in `start`: connect
  ## every server in order, skip a bad one with a warning (plus
  ## `authHint` when remote), retry once when a token appears after the
  ## first failure, and wait out `connectionDeadline` for a sign-in
  ## still in flight.
  ##
  ## 6c: an oauth spec with no `auth_env` bearer first tries its
  ## stored access token (fresh, else silently refreshed like the SDK
  ## did) before connecting anonymously into a 401 that reads as an
  ## outage. `nowUnix` pins time for the expiry check (0 reads the
  ## clock); homes without a token file behave exactly as in 6b.
  ##
  ## Synchronous by design, like the `for spec in servers` loop it
  ## ports. Python runs the same loop on a daemon thread and blocks the
  ## caller on `fut.result(deadline)`, so one deadline bounds one wait
  ## for the whole batch. `connectionDeadline` is load-bearing here for
  ## the same reason: the batch has one stop instant, and a server that
  ## is still waiting on human time when it passes is abandoned with a
  ## warning naming the deadline, and the next server is tried. What a
  ## serial port cannot copy is a preempt: a transport that blocks past
  ## the deadline is its own timeout's business (`liveHttpPost` keeps
  ## 30 s), exactly as the injected transports are instant in tests.
  ## The wait itself (`waitForToken`) is the sign-in case only — an
  ## oauth server with no token whose first attempt failed — because a
  ## key or stdio server has nothing a person can still be finishing.
  ##
  ## `sleeper` times that wait (nil means the live `liveSleep`); it is
  ## a parameter so a test can pin 360 s of consent-screen time. Only
  ## a caller that has a sign-in running should hand the bridge an
  ## oauth spec with no token: this port never opens a browser, so
  ## without one it waits the full deadline for a token nobody is
  ## writing (Python waits the same way only when its attempt is the
  ## thing a person is answering). Config refusals are detected upfront
  ## via `validateSpec` (same observable warnings as Python's
  ## `ValueError`-without-hint path) instead of branching on the
  ## exception type.
  result = McpConnectResult(tools: @[], warnings: @[])
  let deadline = connectionDeadline(specs, home, timeout)
  let effNow = if nowUnix != 0: nowUnix else: getTime().toUnix()
  let pinned = nowUnix != 0
  let stopAt = float(effNow) + deadline
  proc attempt(s: McpServerSpec): tuple[ok: bool, err: string,
                                        tools: seq[Tool]] =
    ## One connect pass over `s` (Python's `_connect_one` inside
    ## `_connect_all`'s `try`): the tools come back, and a failure
    ## comes back as text for the caller to warn about.
    try:
      if s.isRemote:
        let stored = storedBearerFor(home, s, env, httpPost, effNow)
        return (true, "", connectOneHttp(httpPost, s, env, stored).tools)
      if makeExchange == nil:
        raise newException(IOError, "no stdio transport for '" & s.name &
          "'")
      let exc = makeExchange(s)
      return (true, "", toRegistryTools(s.name, listToolsVia(exc, s), exc))
    except CatchableError as exc:
      return (false, exc.msg, @[])
  for spec in specs:
    let invalid = validateSpec(spec, env)
    if invalid.len > 0:
      result.warnings.add("MCP server '" & spec.name &
        "' failed to connect: " & invalid)
      continue
    let hadToken = hasToken(home, spec)
    let first = attempt(spec)
    if first.ok:
      for t in first.tools:
        result.tools.add(t)
      continue
    var firstErr = first.err
    # One retry, and only for a token that exists now and did not
    # before: that is true exactly after a sign-in. The serial port has
    # to wait for the sign-in itself (`waitForToken`), which is the
    # wait Python's thread covers by holding `fut.result` open.
    var reconnect = not hadToken and hasToken(home, spec)
    var gaveUp = false
    if not reconnect and spec.oauth and not hasToken(home, spec):
      reconnect = waitForToken(home, spec, stopAt, pinned, float(effNow),
        sleeper)
      gaveUp = not reconnect
    if reconnect:
      result.warnings.add("  signed in — reconnecting to '" & spec.name & "'")
      let retry = attempt(spec)
      if retry.ok:
        for t in retry.tools:
          result.tools.add(t)
        continue
      firstErr = retry.err
    elif gaveUp:
      firstErr = "no token within the " & $int(deadline) &
        "s connection deadline (" & firstErr & ")"
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
  ## The client comes from `http.nim`'s one helper, so an `https` MCP
  ## server gets the TLS context in a `-d:wakuTls` build — and the
  ## default build refuses the URL before the bearer token is written.
  ##
  ## Transport failures PROPAGATE, and the bare `finally` is what does it:
  ## a `try/except` nested in a `finally` running during exception
  ## unwinding catches the in-flight exception, which used to turn the
  ## no-TLS refusal into a status-0 `HttpResult` that every caller then
  ## had to decode as an HTTP failure. Both live callers are total and
  ## name the refusal verbatim: `oauthSignIn` turns a `CatchableError`
  ## into its `(false, msg, false)` triple, and `refreshAccessToken`
  ## into `""` (a full sign-in).
  var client = newTlsHttpClient(timeout = 30000)
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
    client.close()

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
                nowUnix: int64, timeout: float = 30.0,
                oauthFlow: OAuthFlowFn = nil): tuple[ok: bool,
                  msg: string] =
  ## Port of `sign_in` in `mcp_cli.py`: forget the token, then connect
  ## — which is what triggers a sign-in.
  ##
  ## Divergence: Python judges success by "a token now exists", which
  ## is oauth-shaped — a key/stdio server never writes one, so every
  ## such login would read as failed. This port reports the bridge
  ## result for non-oauth servers (tools connected vs warnings) and
  ## keeps Python's token-file verdict for oauth: the injected
  ## `oauthFlow` runs the 6c browser flow, then the file decides — a
  ## bridge error after a completed sign-in is noise the next run
  ## will not reproduce (Python's `except Exception: pass` says the
  ## same). A nil flow refuses honestly naming the seam: offline
  ## tests and `runMcpCmd` pass none until its one-line follow-up
  ## wires `oauthFlowWith` over the live adapters — so this path
  ## never opens a browser or a socket from a test.
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
    if oauthFlow == nil:
      return (false, "server '" & name &
        "' needs the OAuth browser flow — no OAuthFlowFn is wired " &
        "in this client (the flow itself lives in oauthSignIn)")
    var timedOut = false
    try:
      timedOut = oauthFlow(home, spec).timedOut
    except CatchableError:
      # A raising flow is a broken seam, not a verdict: the token
      # file below is the thing that was asked for, and it is either
      # on disk or it is not (mirrors sign_in's swallowed bridge).
      discard
    if hasToken(home, spec):
      return (true, "\n  " & name & " \u2014 " &
        mcpIdentity(authFilePath(home, name), nowUnix))
    if timedOut:
      # Port of sign_in's TimeoutError branch: the callback may still
      # have landed the token after the wait gave up, so say what to
      # check rather than what broke.
      return (false, "\n  Timed out waiting for the browser sign-in.\n" &
        "  If you did finish it, `waku mcp` will show the account. " &
        "Otherwise run this again.")
    return (false, "\n  Sign-in did not complete — '" & name &
      "' has no token.")
  let res = connectAll(@[spec], env, home, timeout, makeExchange, httpPost)
  if res.warnings.len == 0:
    return (true, "\n  " & name & " connected (" & $res.tools.len &
      " tools).")
  return (false, "\n  Sign-in did not complete — '" & name &
    "' has no token.\n" & res.warnings.join("\n"))

## Phase 6c — OAuth browser flow: DCR + PKCE + loopback callback +
## FileTokenStorage. Port of `waku/tools/mcp_oauth.py` plus the PKCE
## math and the three HTTP shapes the Python SDK drove on our behalf
## (discovery, DCR, code exchange), replayed here over injected seams.
##
## SHA-256 decision (AGENTS.md rule 3): `std/sha1` is deprecated — a
## deprecation warning fails this repo's zero-warning gate — and the
## `checksums` package would be a new dependency, so SHA-256 is
## vendored below in pure stdlib (~60 lines, FIPS 180-4), pinned by
## the NIST `""`/`"abc"` vectors and the RFC 7636 appendix-B vector
## (same precedent as the vendored FNV-1a in `memory_arena.nim`).
## `std/md5` cannot stand in: PKCE `S256` names SHA-256 exactly.

func ror32(x: uint32, n: int): uint32 =
  ## 32-bit rotate-right for the digest below (`bitops` has wider
  ## helpers but nothing this small without an import, and this file
  ## owns its crypto anyway).
  (x shr n) or (x shl (32 - n))

const sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256Digest*(data: string): array[32, byte] =
  ## FIPS 180-4 SHA-256 over the string's bytes. PKCE verifiers and
  ## challenges are ASCII, so one byte per char is exact.
  var h: array[8, uint32] = [0x6a09e667'u32, 0xbb67ae85'u32,
    0x3c6ef372'u32, 0xa54ff53a'u32, 0x510e527f'u32, 0x9b05688c'u32,
    0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg = newSeq[byte](data.len)
  for i, c in data:
    msg[i] = byte(ord(c))
  let bitLen = uint64(data.len) * 8'u64
  msg.add(0x80'u8)
  while msg.len mod 64 != 56:
    msg.add(0'u8)
  for i in countdown(7, 0):
    msg.add(byte((bitLen shr (i * 8)) and 0xff'u64))
  var w: array[64, uint32]
  var i = 0
  while i < msg.len:
    for t in 0 .. 15:
      w[t] = (uint32(msg[i + t * 4]) shl 24) or
        (uint32(msg[i + t * 4 + 1]) shl 16) or
        (uint32(msg[i + t * 4 + 2]) shl 8) or uint32(msg[i + t * 4 + 3])
    for t in 16 .. 63:
      let s0 = ror32(w[t-15], 7) xor ror32(w[t-15], 18) xor (w[t-15] shr 3)
      let s1 = ror32(w[t-2], 17) xor ror32(w[t-2], 19) xor (w[t-2] shr 10)
      w[t] = w[t-16] + s0 + w[t-7] + s1
    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
    var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
    for t in 0 .. 63:
      let s1 = ror32(e, 6) xor ror32(e, 11) xor ror32(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + s1 + ch + sha256K[t] + w[t]
      let s0 = ror32(a, 2) xor ror32(a, 13) xor ror32(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    i += 64
  for i, v in h:
    for j in 0 .. 3:
      result[i * 4 + j] = byte((v shr ((3 - j) * 8)) and 0xff'u32)

proc sha256Hex*(data: string): string =
  ## Lowercase hex of the digest (how the NIST vectors are printed).
  for b in sha256Digest(data):
    result.add(toHex(int(b), 2).toLowerAscii())

proc base64urlEncode*(data: openArray[byte]): string =
  ## `base64.encode` with the URL alphabet and no padding (RFC 7636
  ## section 2: the `S256` challenge transform).
  var raw = newString(data.len)
  for i, b in data:
    raw[i] = char(b)
  result = encode(raw).replace("+", "-").replace("/", "_")
  while result.endsWith("="):
    result = result[0 .. ^2]

proc formEncode*(s: string): string =
  ## Percent-encoding for one OAuth query value: RFC 3986 unreserved
  ## passes through, everything else is uppercase `%XX`.
  for c in s:
    if c.isAlphaNumeric() or c in {'-', '_', '.', '~'}:
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c), 2).toUpperAscii())

proc formDecode*(s: string): string =
  ## The inverse, plus `+` as space (how servers word
  ## `error_description`). Malformed `%` passes through untouched.
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i+1] in HexDigits and
        s[i+2] in HexDigits:
      result.add(char(parseHexInt($s[i+1] & $s[i+2])))
      i += 3
    elif s[i] == '+':
      result.add(' ')
      inc i
    else:
      result.add(s[i])
      inc i

const pkceAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" &
  "abcdefghijklmnopqrstuvwxyz0123456789-._~"
  ## RFC 7636 section 2 unreserved characters: verifiers and states
  ## drawn from here never need encoding inside the authorize URL.

proc pkceChallenge*(verifier: string): string =
  ## `S256`: base64url of SHA-256 of the verifier. The server checks
  ## the code against this; the verifier itself travels only in the
  ## back-channel token call, never through the browser.
  base64urlEncode(sha256Digest(verifier))

type RandIntFn* = proc(maxExclusive: int): int {.closure.}
  ## One draw below `maxExclusive`. Tests pin it; the binary passes
  ## `liveRandInt` — randomness, like the clock, travels by seam.

proc randomToken*(n: int, rng: RandIntFn): string =
  ## `n` PKCE-alphabet characters (verifiers are 43-128 chars per the
  ## RFC; states just need to be unguessable).
  if rng == nil:
    raise newException(IOError, "oauth seam 'rng' is missing")
  for _ in 0 ..< n:
    result.add(pkceAlphabet[rng(pkceAlphabet.len)])

proc liveRandInt*(maxExclusive: int): int =
  ## One unbiased draw from the OS CSPRNG. Never called in tests.
  ## Rejection sampling: 256 is a multiple of nothing interesting, so
  ## the biased `mod` tail is redrawn, not kept.
  doAssert maxExclusive > 0 and maxExclusive <= 256
  let limit = 256 - (256 mod maxExclusive)
  while true:
    let b = int(urandom(1)[0])
    if b < limit:
      return b mod maxExclusive

const callbackPort* = 41765
  ## Port of `CALLBACK_PORT`: fixed, not ephemeral, because the
  ## redirect URI is registered at DCR time and must still be true on
  ## the next run — a random port would force re-registration every
  ## time, and some servers pin the URI.
const callbackPath* = "/callback"
  ## Port of `CALLBACK_PATH`: the one path the loopback server answers.

proc redirectUri*(): string =
  ## Port of the `redirect_uri` in `build_provider`.
  "http://127.0.0.1:" & $callbackPort & callbackPath

proc callbackPollAttempts*(): int =
  ## Port of `range(int(SIGN_IN_TIMEOUT / 0.5))`: `signInPollSeconds`
  ## slices of human time (consent screens, picking between two
  ## accounts), sharing 6b's `connectionDeadline` through
  ## `signInTimeout`.
  int(signInTimeout / signInPollSeconds)

proc readTokenDoc*(path: string): JsonNode =
  ## Port of `FileTokenStorage._read`: a missing, corrupt or
  ## non-object file reads as an empty document, never raises — one
  ## bad file costs a sign-in, not a harness that will not start.
  try:
    let node = parseJson(readFile(path))
    if node.kind == JObject:
      return node
    return newJObject()
  except CatchableError:
    return newJObject()

proc writeTokenDoc*(path: string, doc: JsonNode) =
  ## Port of `FileTokenStorage._write`: parents first, write-then-
  ## rename so an interrupted write cannot halve a valid file, chmod
  ## 0600 BEFORE the rename so the secret is never briefly readable.
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)
  let tmp = path & ".tmp"
  writeFile(tmp, pretty(doc))
  setFilePermissions(tmp, {fpUserRead, fpUserWrite})
  moveFile(tmp, path)

proc getStoredTokens*(home, server: string): JsonNode =
  ## Port of `FileTokenStorage.get_tokens` (shape only): the stored
  ## `tokens` object, or nil when the server never signed in or the
  ## file went bad. Callers check `!= nil`, like the SDK's `| None`.
  let doc = readTokenDoc(authFilePath(home, server))
  if doc.hasKey("tokens") and doc["tokens"].kind == JObject:
    return doc["tokens"]
  return nil

proc setStoredTokens*(home, server: string, tokens: JsonNode) =
  ## Port of `FileTokenStorage.set_tokens`: merge under `tokens` and
  ## keep the sibling `client_info` — a token write must not forget
  ## the DCR that minted it.
  var doc = readTokenDoc(authFilePath(home, server))
  doc["tokens"] = tokens
  writeTokenDoc(authFilePath(home, server), doc)

proc getStoredClientInfo*(home, server: string): JsonNode =
  ## Port of `FileTokenStorage.get_client_info`: the stored
  ## registration, or nil when this client never registered.
  let doc = readTokenDoc(authFilePath(home, server))
  if doc.hasKey("client_info") and doc["client_info"].kind == JObject:
    return doc["client_info"]
  return nil

proc setStoredClientInfo*(home, server: string, info: JsonNode) =
  ## Port of `FileTokenStorage.set_client_info`: merge under
  ## `client_info`, keep the sibling `tokens`.
  var doc = readTokenDoc(authFilePath(home, server))
  doc["client_info"] = info
  writeTokenDoc(authFilePath(home, server), doc)

proc parseCallbackTarget*(target: string): tuple[status: int, code: string,
    state: string, iss: string, err: string, errDesc: string] =
  ## Port of `_CallbackHandler.do_GET` without the socket: the one
  ## redirect is accepted, anything else is a 404. `error` params are
  ## kept verbatim — the caller reports the server's own words.
  result = (status: 404, code: "", state: "", iss: "", err: "",
    errDesc: "")
  let q = target.split('?', maxsplit = 1)
  if q[0] != callbackPath:
    return
  result.status = 200
  if q.len < 2:
    return
  for part in q[1].split('&'):
    let kv = part.split('=', maxsplit = 1)
    let val = if kv.len > 1: formDecode(kv[1]) else: ""
    case kv[0]
    of "code": result.code = val
    of "state": result.state = val
    of "iss": result.iss = val
    of "error": result.err = val
    of "error_description": result.errDesc = val
    else: discard

proc callbackError*(err, errDesc: string): string =
  ## Port of the `authorization failed` raise in `callback_handler`:
  ## the server said no, in its own words (`access_denied` and
  ## `invalid_client` send you to completely different places).
  if err.len == 0:
    return ""
  if errDesc.len > 0:
    return "authorization failed: " & err & " \u2014 " & errDesc
  return "authorization failed: " & err

proc callbackSuccessPage*(): string =
  ## Port of the 200 body in `do_GET`: the tab you can close.
  "<html><body style='font-family:system-ui;padding:3rem'>" &
    "<h2>Signed in.</h2><p>You can close this tab and return to the terminal.</p>" &
    "</body></html>"

type
  BrowserFn* = proc(url: string): bool {.closure.}
    ## Open `url` for sign-in; false when there is no browser (headless
    ## or SSH) and the printed URL is the only way through — the honest
    ## signal Python reads from `webbrowser.open_new_tab`.
  CallbackWaitFn* = proc(port: int, path: string,
      maxAttempts: int): string {.closure.}
    ## The raw callback target (`/callback?code=...`), or "" when the
    ## browser never came back. Raises `IOError` when the loopback port
    ## is already held.
  HttpGetFn* = proc(url, bearer: string): tuple[status: int,
      body: string] {.closure.}
    ## GET one OAuth metadata document. Tests inject recorded bodies;
    ## the binary passes `liveHttpGet`. Never a socket in tests.

proc openBrowserLive*(url: string): bool =
  ## Port of `redirect_handler`: always print the URL (a headless or
  ## SSH session has no browser, and the line below is then the only
  ## way through), then ask the OS. Real process — never in tests.
  echo "\n  Opening your browser to sign in\u2026"
  echo "  If it does not open: " & url & "\n"
  openDefaultBrowser(url)
  return true

proc waitCallbackLive*(port: int, path: string,
    maxAttempts: int): string =
  ## Port of `callback_handler`: serve the one loopback request, in
  ## 0.5s slices up to `maxAttempts` (300s of human time), then stop.
  ## Real socket — never called in tests. Raises `IOError` naming the
  ## port when it is held (Python's `RuntimeError` for the same case).
  doAssert path == callbackPath
  var target = ""
  var server = newAsyncHttpServer()
  proc onReq(req: Request) {.async.} =
    let got = req.url.path &
      (if req.url.query.len > 0: "?" & req.url.query else: "")
    if parseCallbackTarget(got).status != 200:
      await req.respond(Http404, "not found")
      return
    target = got
    await req.respond(Http200, callbackSuccessPage(),
      newHttpHeaders([("Content-Type", "text/html; charset=utf-8")]))
    server.close()
  proc watchdog() {.async.} =
    await sleepAsync(maxAttempts * 500)
    server.close()
  asyncCheck watchdog()
  try:
    waitFor server.serve(Port(port), onReq, "127.0.0.1")
  except OSError:
    raise newException(IOError, "port " & $port &
      " is in use \u2014 the sign-in redirect has nowhere to land. " &
      "Close whatever holds it and try again.")
  return target

proc liveHttpGet*(url, bearer: string): tuple[status: int, body: string] =
  ## Live GET for OAuth metadata (discovery documents are GETs; the
  ## MCP wire stays on `liveHttpPost`). Real socket — never in tests.
  ## Same helper as the POST: the discovery document is fetched from the
  ## same server, so it needs the same TLS context. Transport failures
  ## PROPAGATE (bare `finally`, as above), so `discoverOAuth`'s "HTTP 0
  ## at <url>" no longer stands in for "this build was never allowed to
  ## dial that server" — the refusal reaches `oauthSignIn` as the
  ## exception it is.
  var client = newTlsHttpClient(timeout = 30000)
  try:
    var hdrs = newHttpHeaders([("Accept", "application/json")])
    if bearer.len > 0:
      hdrs["Authorization"] = "Bearer " & bearer
    let resp = client.request(url, HttpGet, "", hdrs)
    var code = 0
    try:
      code = parseInt(resp.status.split(' ')[0])
    except ValueError:
      discard
    var text = ""
    try:
      text = resp.body
    except CatchableError as exc:
      raise newException(IOError, exc.msg)
    return (code, text)
  finally:
    client.close()

proc resourceMetadataUrl*(serverUrl: string): string =
  ## The RFC 9728 well-known lookup the SDK did: insert
  ## `/.well-known/oauth-protected-resource` between host and path.
  var base = serverUrl
  for cut in ['?', '#']:
    let i = base.find(cut)
    if i >= 0:
      base = base[0 ..< i]
  let schemeEnd = base.find("://")
  var host = base
  var path = ""
  if schemeEnd >= 0:
    let rest = base[schemeEnd + 3 .. ^1]
    let slash = rest.find('/')
    if slash >= 0:
      host = base[0 ..< schemeEnd + 3 + slash]
      path = rest[slash .. ^1]
  if path.len == 0 or path == "/":
    return host & "/.well-known/oauth-protected-resource"
  return host & "/.well-known/oauth-protected-resource" & path

type OAuthEndpoints* = object
  authEndpoint*: string
  tokenEndpoint*: string
  regEndpoint*: string

proc parseResourceMetadata*(body: string): seq[string] =
  ## The `authorization_servers` of an RFC 9728 resource document.
  ## Raises `ValueError`: without one, discovery has nowhere to go.
  var node: JsonNode
  try:
    node = parseJson(body.strip())
  except JsonParsingError as e:
    raise newException(ValueError,
      "OAuth resource metadata is not valid JSON: " & e.msg)
  if node.kind == JObject and node.hasKey("authorization_servers") and
      node["authorization_servers"].kind == JArray:
    for s in node["authorization_servers"]:
      if s.kind == JString and s.getStr().len > 0:
        result.add(s.getStr())
  if result.len == 0:
    raise newException(ValueError,
      "OAuth resource metadata names no authorization_servers")

proc parseServerMetadata*(body: string): OAuthEndpoints =
  ## The endpoints of an authorization-server metadata document.
  ## Registration is optional: without it DCR is honestly refused at
  ## sign-in time. Raises `ValueError` naming a missing endpoint.
  var node: JsonNode
  try:
    node = parseJson(body.strip())
  except JsonParsingError as e:
    raise newException(ValueError,
      "OAuth server metadata is not valid JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(ValueError, "OAuth server metadata is not an object")
  for key in ["authorization_endpoint", "token_endpoint"]:
    if not node.hasKey(key) or node[key].kind != JString or
        node[key].getStr().len == 0:
      raise newException(ValueError,
        "OAuth server metadata has no " & key)
  result.authEndpoint = node["authorization_endpoint"].getStr()
  result.tokenEndpoint = node["token_endpoint"].getStr()
  if node.hasKey("registration_endpoint") and
      node["registration_endpoint"].kind == JString:
    result.regEndpoint = node["registration_endpoint"].getStr()

proc dcrBody*(): JsonNode =
  ## Port of the `OAuthClientMetadata` in `build_provider`: this
  ## client, named, loopback-bound, public (no secret — `none`).
  %*{"client_name": "Waku",
     "redirect_uris": [redirectUri()],
     "grant_types": ["authorization_code", "refresh_token"],
     "response_types": ["code"],
     "token_endpoint_auth_method": "none"}

proc parseDcrResponse*(body: string): tuple[clientId: string,
    clientSecret: string] =
  ## The registered client: `client_id` is required, the secret is
  ## public-client-optional. Raises `ValueError` without an id.
  var node: JsonNode
  try:
    node = parseJson(body.strip())
  except JsonParsingError as e:
    raise newException(ValueError,
      "dynamic client registration is not valid JSON: " & e.msg)
  if node.kind != JObject or not node.hasKey("client_id") or
      node["client_id"].kind != JString or
      node["client_id"].getStr().len == 0:
    raise newException(ValueError,
      "dynamic client registration did not return a client_id")
  result.clientId = node["client_id"].getStr()
  if node.hasKey("client_secret") and
      node["client_secret"].kind == JString:
    result.clientSecret = node["client_secret"].getStr()

proc authorizeUrl*(authEndpoint, clientId, challenge,
    state: string): string =
  ## The browser URL: code flow with the `S256` challenge. Port of
  ## what the SDK built before calling `redirect_handler`.
  result = authEndpoint & (if '?' in authEndpoint: "&" else: "?") &
    "response_type=code" &
    "&client_id=" & formEncode(clientId) &
    "&redirect_uri=" & formEncode(redirectUri()) &
    "&code_challenge=" & formEncode(challenge) &
    "&code_challenge_method=S256" &
    "&state=" & formEncode(state)

proc tokenExchangeBody*(code, verifier, clientId: string): JsonNode =
  ## The back-channel code swap (the verifier travels here, never
  ## through the browser).
  %*{"grant_type": "authorization_code", "code": code,
     "redirect_uri": redirectUri(), "client_id": clientId,
     "code_verifier": verifier}

proc refreshBody*(refreshToken, clientId: string): JsonNode =
  ## The silent swap the SDK did before retrying a 401.
  %*{"grant_type": "refresh_token", "refresh_token": refreshToken,
     "client_id": clientId}

proc parseTokenResponse*(body: string): JsonNode =
  ## A token endpoint answer: the whole object, stored as-is (like the
  ## SDK's `model_dump`), refused when it carries no `access_token`.
  var node: JsonNode
  try:
    node = parseJson(body.strip())
  except JsonParsingError as e:
    raise newException(ValueError,
      "token response is not valid JSON: " & e.msg)
  if node.kind != JObject or not node.hasKey("access_token") or
      node["access_token"].kind != JString or
      node["access_token"].getStr().len == 0:
    raise newException(ValueError, "token response has no access_token")
  return node

proc discoverOAuth*(get: HttpGetFn, serverUrl: string): OAuthEndpoints =
  ## Ports the SDK's discovery: the resource's metadata, then the
  ## named authorization server's metadata. Raises `IOError` on
  ## transport, `ValueError` on shapes without endpoints.
  if get == nil:
    raise newException(IOError,
      "MCP server '" & serverUrl & "' is not connected.")
  let rmUrl = resourceMetadataUrl(serverUrl)
  let rm = get(rmUrl, "")
  if rm.status != 200:
    raise newException(IOError, "could not discover the authorization " &
      "server for '" & serverUrl & "': HTTP " & $rm.status & " at " & rmUrl)
  let servers = parseResourceMetadata(rm.body)
  let base = servers[0].strip(leading = false, trailing = true,
    chars = {'/'})
  let smUrl = base & "/.well-known/oauth-authorization-server"
  let sm = get(smUrl, "")
  if sm.status != 200:
    raise newException(IOError, "could not read the authorization " &
      "server metadata for '" & serverUrl & "': HTTP " & $sm.status &
      " at " & smUrl)
  return parseServerMetadata(sm.body)

proc dcrRegister*(post: HttpPostFn,
    regEndpoint: string): tuple[clientId: string, clientSecret: string] =
  ## One dynamic-client registration. Raises `IOError` on transport,
  ## `ValueError` when the answer carries no `client_id`.
  if post == nil:
    raise newException(IOError, "no HTTP transport for registration")
  let res = post(regEndpoint, $dcrBody(), "", "")
  if res.status < 200 or res.status >= 300:
    raise newException(IOError,
      "dynamic client registration failed with status " & $res.status &
      " at " & regEndpoint)
  return parseDcrResponse(res.body.strip())

proc exchangeCode*(post: HttpPostFn, tokenEndpoint, code, verifier,
    clientId: string): JsonNode =
  ## Port of the SDK's code exchange, PKCE `code_verifier` included.
  ## Raises `IOError`, naming the server's `error` when it says no.
  if post == nil:
    raise newException(IOError, "no HTTP transport for token exchange")
  let res = post(tokenEndpoint,
    $tokenExchangeBody(code, verifier, clientId), "", "")
  if res.status < 200 or res.status >= 300:
    var detail = "HTTP " & $res.status
    try:
      let node = parseJson(res.body.strip())
      if node.kind == JObject and node.hasKey("error") and
          node["error"].kind == JString:
        detail = node["error"].getStr()
        if node.hasKey("error_description") and
            node["error_description"].kind == JString:
          detail &= " \u2014 " & node["error_description"].getStr()
    except CatchableError:
      discard
    raise newException(IOError, "token exchange failed: " & detail)
  return parseTokenResponse(res.body.strip())

proc storedAccessToken*(home: string, spec: McpServerSpec,
    nowUnix: int64): string =
  ## The stored access token while it is good for more than a minute
  ## (60s skew margin), else "": the bridge then refreshes or signs
  ## in. Tokens without `exp` return as-is — like `mcpIdentity`, which
  ## still names their account instead of judging them.
  let toks = getStoredTokens(home, spec.name)
  if toks == nil or not toks.hasKey("access_token") or
      toks["access_token"].kind != JString:
    return ""
  let access = toks["access_token"].getStr()
  if access.len == 0:
    return ""
  let claims = decodeClaims(access)
  if not claims.hasKey("exp"):
    return access
  let expNode = claims["exp"]
  var exp: int64 = 0
  var known = true
  if expNode.kind == JInt:
    exp = expNode.getBiggestInt()
  elif expNode.kind == JFloat:
    exp = int64(expNode.getFloat())
  else:
    known = false
  if not known or exp == 0:
    return access
  if exp - nowUnix > 60:
    return access
  return ""

proc refreshAccessToken*(post: HttpPostFn, home: string,
    spec: McpServerSpec): string =
  ## Port of the SDK's silent refresh: swap the stored `refresh_token`
  ## for a fresh access token and store the answer. Never raises — ""
  ## means the caller falls through to a full sign-in. A refreshed
  ## answer that omits `refresh_token` keeps the old one (servers
  ## rotate access tokens far more eagerly than refresh tokens).
  if post == nil:
    return ""
  let info = getStoredClientInfo(home, spec.name)
  let toks = getStoredTokens(home, spec.name)
  if info == nil or toks == nil:
    return ""
  if not info.hasKey("token_endpoint") or
      info["token_endpoint"].kind != JString or
      info["token_endpoint"].getStr().len == 0:
    return ""
  if not toks.hasKey("refresh_token") or
      toks["refresh_token"].kind != JString or
      toks["refresh_token"].getStr().len == 0:
    return ""
  let oldRefresh = toks["refresh_token"].getStr()
  var clientId = ""
  if info.hasKey("client_id") and info["client_id"].kind == JString:
    clientId = info["client_id"].getStr()
  var answer: JsonNode
  try:
    let res = post(info["token_endpoint"].getStr(),
      $refreshBody(oldRefresh, clientId), "", "")
    if res.status < 200 or res.status >= 300:
      return ""
    answer = parseTokenResponse(res.body.strip())
  except CatchableError:
    return ""
  if not answer.hasKey("refresh_token"):
    answer["refresh_token"] = %oldRefresh
  setStoredTokens(home, spec.name, answer)
  return answer["access_token"].getStr()

proc storedBearerFor(home: string, spec: McpServerSpec,
    env: Table[string, string], httpPost: HttpPostFn,
    nowUnix: int64): string =
  ## 6c bearer resolution for `connectAll` (forward-declared above
  ## it): a fresh-or-refreshed stored oauth token when the spec names
  ## no `auth_env`, else "". Never raises and never touches the net
  ## without both a stored refresh token and its endpoint — homes
  ## without a token file behave exactly as in 6b.
  if not spec.oauth or bearerFor(spec, env) != "":
    return ""
  result = storedAccessToken(home, spec, nowUnix)
  if result == "" and httpPost != nil:
    result = refreshAccessToken(httpPost, home, spec)

proc oauthSignIn*(home: string, spec: McpServerSpec, post: HttpPostFn,
    get: HttpGetFn, openBrowser: BrowserFn, waitCode: CallbackWaitFn,
    randInt: RandIntFn): tuple[ok: bool, msg: string, timedOut: bool] =
  ## The browser flow `build_provider` drove through the SDK, replayed
  ## here over injected seams: discover, reuse-or-register the client,
  ## open the browser at the `S256` authorize URL, catch the loopback
  ## code, exchange it, store both halves. Never raises — every failure
  ## reads as a triple, like the SDK's `RuntimeError`s read as text in
  ## `sign_in`. `timedOut` keeps the CLI's special-case message honest
  ## (the token may still land after the wait gives up).
  ##
  ## Divergence: the stored `client_info` also keeps the discovered
  ## endpoints (the SDK re-discovered per run; persisting them lets a
  ## later refresh skip the GETs). The `state` check the SDK did
  ## internally is explicit here: a mismatch fails closed.
  try:
    if post == nil or get == nil or openBrowser == nil or
        waitCode == nil or randInt == nil:
      raise newException(IOError, "oauth seams are missing")
    let eps = discoverOAuth(get, spec.url)
    var clientId = ""
    let stored = getStoredClientInfo(home, spec.name)
    if stored != nil and stored.hasKey("client_id") and
        stored["client_id"].kind == JString and
        stored["client_id"].getStr().len > 0:
      clientId = stored["client_id"].getStr()
    else:
      if eps.regEndpoint.len == 0:
        raise newException(IOError, "server '" & spec.name &
          "' does not advertise dynamic client registration — " &
          "ask its operator for a client_id")
      let (cid, csec) = dcrRegister(post, eps.regEndpoint)
      var info = %*{"client_id": cid,
        "authorization_endpoint": eps.authEndpoint,
        "token_endpoint": eps.tokenEndpoint}
      if csec.len > 0:
        info["client_secret"] = %csec
      if eps.regEndpoint.len > 0:
        info["registration_endpoint"] = %eps.regEndpoint
      setStoredClientInfo(home, spec.name, info)
      clientId = cid
    let verifier = randomToken(64, randInt)
    let state = randomToken(32, randInt)
    let url = authorizeUrl(eps.authEndpoint, clientId,
      pkceChallenge(verifier), state)
    let opened = openBrowser(url)
    let target = waitCode(callbackPort, callbackPath,
      callbackPollAttempts())
    if target.len == 0:
      var msg = "timed out waiting for the browser sign-in to come back"
      if not opened:
        msg &= "\n  If it does not open: " & url
      return (false, msg, true)
    let parsed = parseCallbackTarget(target)
    if parsed.err.len > 0:
      return (false, callbackError(parsed.err, parsed.errDesc), false)
    if parsed.status != 200 or parsed.code.len == 0:
      raise newException(IOError,
        "sign-in response had no code — try again")
    if parsed.state != state:
      raise newException(IOError,
        "sign-in state mismatch — not the browser run this client started")
    let tokens = exchangeCode(post, eps.tokenEndpoint, parsed.code,
      verifier, clientId)
    setStoredTokens(home, spec.name, tokens)
    return (true, "signed in to '" & spec.name & "'", false)
  except CatchableError as exc:
    return (false, exc.msg, false)

proc oauthFlowWith*(post: HttpPostFn, get: HttpGetFn,
    openBrowser: BrowserFn, waitCode: CallbackWaitFn,
    randInt: RandIntFn): OAuthFlowFn =
  ## Wrap the real `oauthSignIn` into an `OAuthFlowFn`: the future
  ## `runMcpCmd` wiring is this one line over the live adapters
  ## (`liveHttpPost`, `liveHttpGet`, `openBrowserLive`,
  ## `waitCallbackLive`, `liveRandInt`).
  result = proc(home: string,
      spec: McpServerSpec): tuple[ok: bool, msg: string,
      timedOut: bool] {.closure.} =
    oauthSignIn(home, spec, post, get, openBrowser, waitCode, randInt)
