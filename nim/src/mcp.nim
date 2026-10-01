## MCP connector, phase 6a — config + stdio transport.
##
## Port of `waku/tools/mcp_client.py` (`MCPBridge`, `_model_safe_name`,
## `_auth_hint`) for the stdio half: `mcp.json` parsing, spec validation,
## hand-rolled JSON-RPC over stdio (the MCP SDK is async Python; there is
## no Nim SDK, so the three method shapes — `initialize`, `tools/list`,
## `tools/call` — are built here), and mapping to registry `Tool`s.
##
## Every process interaction travels through the injected `ExchangeFn`
## (one request line -> one response line). The live `osproc` adapter
## (`startStdioExchange`) is never called in tests, which replay recorded
## responses instead: zero real subprocesses, zero sockets.
##
## Deferred to 6b: streamable HTTP (`url` specs parse and validate here
## but `connectError` says so honestly), OAuth (`mcp_oauth.py`), and the
## `waku mcp` CLI (`mcp_cli.py`). No new dependencies: stdlib only
## (AGENTS.md rule 3), like the rest of the port.

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
  ## `""` when 6a can connect this spec now. Remote specs parse and
  ## validate, but their transport arrives in 6b — said honestly, like
  ## the dashboard's 501-for-later-routes pattern.
  let invalid = validateSpec(spec, env)
  if invalid.len > 0:
    return invalid
  if spec.isRemote:
    return "server '" & spec.name & "' (" & spec.url &
      ") needs streamable HTTP — arrives in 6b"
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
