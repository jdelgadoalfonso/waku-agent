## Phase 6a tests: MCP config + stdio JSON-RPC, offline only.
##
## Every process interaction travels through the injected `ExchangeFn`
## (one JSON-RPC request line -> one response line, recorded responses
## in these tests). No real subprocess is ever spawned and no socket is
## ever opened; the live `osproc` adapter in `src/mcp.nim` is never
## called here. HTTP+OAuth+CLI arrive in 6b/6c.

import std/base64
import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import ../src/mcp

proc envOf(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (k, v) in pairs:
    result[k] = v

proc stdioSpec(): McpServerSpec =
  McpServerSpec(name: "fs", command: "npx",
    args: @["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    env: initTable[string, string]())

const initOkLine = """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"demo","version":"1.0"}}}"""
const listOkLine = """{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"word_count","description":"Count words","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},{"name":"memory.remember","description":"Store it","inputSchema":{"type":"object","properties":{}}}]}}"""
const callOkLine = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"3 words"},{"type":"image","data":"x"},{"type":"text","text":"tail"}]}}"""

proc newSeen(): ref seq[string] =
  new(result)
  result[] = @[]

proc recordExchange(seen: ref seq[string]): ExchangeFn =
  ## Fake transport: records every request line, replays canned responses
  ## by method (notification -> "").
  result = proc(req: string): string {.closure.} =
    seen[].add(req)
    let node = parseJson(req.strip())
    let meth = node{"method"}.getStr()
    case meth
    of "initialize": initOkLine
    of "notifications/initialized": ""
    of "tools/list": listOkLine
    of "tools/call": callOkLine
    else: raise newException(ValueError, "unexpected method: " & meth)

suite "phase 6a config parse":
  test "a stdio server parses with command, args and env":
    let servers = parseMcpConfig("""{"servers": [{"name": "fs",
      "command": "npx", "args": ["-y", "srv", "/tmp"],
      "env": {"FOO": "bar"}}]}""")
    assert servers.len == 1
    assert servers[0].name == "fs"
    assert servers[0].command == "npx"
    assert servers[0].args == @["-y", "srv", "/tmp"]
    assert servers[0].env["FOO"] == "bar"
    assert not servers[0].isRemote()
    assert not servers[0].oauth

  test "a remote server parses url, auth_env and oauth":
    let servers = parseMcpConfig("""{"servers": [
      {"name": "mem", "url": "https://host/mcp", "auth_env": "MEM_KEY"},
      {"name": "mem2", "url": "https://host2/mcp", "oauth": true}]}""")
    assert servers.len == 2
    assert servers[0].url == "https://host/mcp"
    assert servers[0].authEnv == "MEM_KEY"
    assert servers[0].isRemote()
    assert servers[1].oauth
    assert servers[1].authEnv == ""

  test "missing servers key parses to no servers":
    assert parseMcpConfig("""{}""").len == 0
    assert parseMcpConfig("""{"servers": []}""").len == 0

  test "invalid JSON raises ValueError":
    expect ValueError:
      discard parseMcpConfig("{nope")

  test "an entry without a name raises ValueError":
    expect ValueError:
      discard parseMcpConfig("""{"servers": [{"command": "npx"}]}""")

suite "phase 6a spec validation":
  test "a server naming both url and command is refused":
    var spec = stdioSpec()
    spec.url = "https://host/mcp"
    assert validateSpec(spec, envOf([])) ==
      "server has both 'url' and 'command' — pick one transport"

  test "a server naming both auth_env and oauth is refused":
    let spec = McpServerSpec(name: "m", url: "https://host/mcp",
      authEnv: "K", oauth: true)
    assert validateSpec(spec, envOf([("K", "v")])) ==
      "server names both 'auth_env' and 'oauth' — pick one"

  test "an unset auth_env names the variable":
    let spec = McpServerSpec(name: "m", url: "https://host/mcp",
      authEnv: "MEM_KEY")
    assert validateSpec(spec, envOf([])) ==
      "MEM_KEY is not set (named by 'auth_env' in mcp.json)"
    assert validateSpec(spec, envOf([("MEM_KEY", "tok")])) == ""

  test "a server naming neither transport is refused":
    let spec = McpServerSpec(name: "m")
    assert validateSpec(spec, envOf([])) ==
      "server 'm' names neither 'url' nor 'command' — pick one transport"

  test "a valid stdio spec passes":
    assert validateSpec(stdioSpec(), envOf([])) == ""

suite "phase 6a model-safe names":
  test "dotted tool names are rewritten with the server prefix":
    assert modelSafeName("waku_memory", "memory.remember") ==
      "waku_memory_memory_remember"

  test "short names pass through":
    assert modelSafeName("demo", "word_count") == "demo_word_count"

  test "long names keep the tail within 64 chars":
    let long = modelSafeName("averylongservername_that_goes_on_and_on",
      "averylongtoolname_that_also_goes_on_and_on_forever")
    assert long.len == 64
    assert long.endsWith("_that_also_goes_on_and_on_forever")
    assert not long.startsWith("_")

suite "phase 6a auth hint":
  test "an oauth server points at deleting the auth dir":
    let spec = McpServerSpec(name: "m", url: "https://host/mcp", oauth: true)
    let hint = authHint(spec, ".waku/mcp-auth")
    assert "https://host/mcp" in hint
    assert ".waku/mcp-auth" in hint
    assert "auth_env" notin hint

  test "a key server names its variable, defaulting to auth_env":
    let named = McpServerSpec(name: "m", url: "https://host/mcp",
      authEnv: "MEM_KEY")
    assert "MEM_KEY" in authHint(named, ".waku/mcp-auth")
    let bare = McpServerSpec(name: "m", url: "https://host/mcp")
    assert "auth_env" in authHint(bare, ".waku/mcp-auth")

suite "phase 6a json-rpc builders":
  test "initialize carries the protocol version and Waku client info":
    let req = parseJson(initializeReq(1).strip())
    assert req["jsonrpc"].getStr() == "2.0"
    assert req["id"].getInt() == 1
    assert req["method"].getStr() == "initialize"
    assert req["params"]["protocolVersion"].getStr() == mcpProtocolVersion
    assert req["params"]["clientInfo"]["name"].getStr() == "Waku"

  test "list and call carry their method and params":
    let list = parseJson(listToolsReq(2).strip())
    assert list["method"].getStr() == "tools/list"
    assert list["id"].getInt() == 2
    let call = parseJson(callToolReq(3, "word_count",
      %*{"text": "hi"}).strip())
    assert call["method"].getStr() == "tools/call"
    assert call["params"]["name"].getStr() == "word_count"
    assert call["params"]["arguments"]["text"].getStr() == "hi"

  test "requests are newline-terminated single lines":
    for line in [initializeReq(1), listToolsReq(1),
                 callToolReq(1, "t", %*{})]:
      assert line.endsWith("\n")
      assert line.strip().len > 0
      assert "\n" notin line.strip()

suite "phase 6a response parsers":
  test "a tool list maps names, descriptions and schemas":
    let tools = parseToolList(listOkLine)
    assert tools.len == 2
    assert tools[0].name == "word_count"
    assert tools[0].description == "Count words"
    assert tools[0].inputSchema["required"][0].getStr() == "text"
    assert tools[1].name == "memory.remember"

  test "missing description and schema fall back to empty and {}":
    let tools = parseToolList("""{"jsonrpc":"2.0","id":2,"result": {
      "tools": [{"name": "bare"}]}}""")
    assert tools.len == 1
    assert tools[0].description == ""
    assert tools[0].inputSchema ==
      %*{"type": "object", "properties": {}}

  test "an error response raises with the server message":
    try:
      discard parseToolList("""{"jsonrpc":"2.0","id":2,
        "error": {"code": -32601, "message": "Method not found"}}""")
      assert false, "must raise"
    except ValueError as e:
      assert "Method not found" in e.msg

  test "a call joins text blocks and marks non-text":
    assert parseCallResult(callOkLine) == "3 words\n[non-text content]\ntail"

  test "an empty content list reads as no output":
    assert parseCallResult("""{"jsonrpc":"2.0","id":3,
      "result": {"content": []}}""") == "(no output)"

suite "registry tools call the server's own name":
  test "each tool asks for itself, not the last one listed":
    # Regression pin (found live against `engram mcp`): building the
    # registry in a loop made every closure share one binding, so
    # `mem_search` asked the server for whatever tool came last.
    var asked: seq[string] = @[]
    let naming: ExchangeFn = proc(req: string): string {.closure.} =
      let node = parseJson(req.strip())
      let meth = node["method"].getStr()
      if meth == "tools/call":
        asked.add(node["params"]["name"].getStr())
        return callOkLine
      if meth == "tools/list":
        return listOkLine
      initOkLine
    let reg = toRegistryTools("engram", @[
      McpToolMeta(name: "mem_search", description: "s",
        inputSchema: %*{"type": "object"}),
      McpToolMeta(name: "mem_save", description: "s",
        inputSchema: %*{"type": "object"}),
      McpToolMeta(name: "mem_update", description: "s",
        inputSchema: %*{"type": "object"})], naming)
    assert reg.len == 3
    for t in reg:
      discard t.fn(%*{"query": "x"})
    assert asked == @["mem_search", "mem_save", "mem_update"]

suite "phase 6a stdio exchange":
  test "listToolsVia initializes then lists, returning tool metas":
    let seen = newSeen()
    let tools = listToolsVia(recordExchange(seen), stdioSpec())
    assert tools.len == 2
    assert tools[0].name == "word_count"
    assert seen[].len == 3
    assert parseJson(seen[][0].strip())["method"].getStr() == "initialize"
    assert parseJson(seen[][1].strip())["method"].getStr() ==
      "notifications/initialized"
    assert parseJson(seen[][2].strip())["method"].getStr() == "tools/list"

  test "expectsReply is false for notifications, true for requests":
    assert not expectsReply(initializedNote())
    assert expectsReply(initializeReq(1))
    assert expectsReply(listToolsReq(2))
    assert expectsReply("""{"jsonrpc":"2.0","id":"abc","method":"tools/list","params":{}}""")
    assert expectsReply("{nope")

  test "an exchange failure propagates for the caller to skip":
    let failing: ExchangeFn = proc(req: string): string {.closure.} =
      raise newException(ValueError, "boom")
    expect ValueError:
      discard listToolsVia(failing, stdioSpec())

  test "callToolVia returns the joined text":
    let seen = newSeen()
    let text = callToolVia(recordExchange(seen), "demo", "word_count",
      %*{"text": "hi"})
    assert text == "3 words\n[non-text content]\ntail"
    let req = parseJson(seen[][0].strip())
    assert req["method"].getStr() == "tools/call"
    assert req["params"]["name"].getStr() == "word_count"

  test "a failing call reads as text, never raises":
    let failing: ExchangeFn = proc(req: string): string {.closure.} =
      raise newException(ValueError, "boom")
    assert callToolVia(failing, "demo", "word_count", %*{}) ==
      "MCP call demo_word_count failed: boom"

  test "a nil exchange reads as not connected":
    let noExchange: ExchangeFn = nil
    assert callToolVia(noExchange, "demo", "word_count", %*{}) ==
      "MCP server 'demo' is not connected."

suite "phase 6a registry mapping":
  test "tools register under model-safe names with the MCP prefix":
    let seen = newSeen()
    let tools = toRegistryTools("demo",
      parseToolList(listOkLine), recordExchange(seen))
    assert tools.len == 2
    assert tools[0].name == "demo_word_count"
    assert tools[1].name == "demo_memory_remember"
    assert tools[0].description == "[MCP:demo] Count words"
    assert tools[0].inputSchema["required"][0].getStr() == "text"

  test "the registered fn dispatches under the original tool name":
    let seen = newSeen()
    let tools = toRegistryTools("demo",
      parseToolList(listOkLine), recordExchange(seen))
    let text = tools[1].fn(%*{})
    assert text == "3 words\n[non-text content]\ntail"
    let req = parseJson(seen[][0].strip())
    assert req["params"]["name"].getStr() == "memory.remember"

suite "phase 6a remote deferral":
  test "stdio and valid remote connect clean, invalid explains (6b lifts the gate)":
    assert connectError(stdioSpec(), envOf([])) == ""
    let remote = McpServerSpec(name: "m", url: "https://host/mcp",
      authEnv: "K")
    assert connectError(remote, envOf([("K", "v")])) == ""
    var both = stdioSpec()
    both.url = "https://host/mcp"
    assert connectError(both, envOf([])) ==
      "server has both 'url' and 'command' — pick one transport"

## Phase 6b tests: streamable HTTP + bridge + `waku mcp` CLI helpers.
##
## Offline only: every HTTP interaction travels through the injected
## `HttpPostFn` (recorded request/response, never a socket); `home` and
## `env` travel by parameter; real files live only under `getTempDir()`.
## The live `liveHttpPost` adapter is never called here.

proc b64url(s: string): string =
  result = encode(s).replace("+", "-").replace("/", "_")
  while result.endsWith("="):
    result = result[0 .. ^2]

proc jwtWith(payload: string): string =
  "h." & b64url(payload) & ".s"

proc freshTmpHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc writeTokenFile(home, server, payload: string) =
  let dir = home / "mcp-auth"
  createDir(dir)
  writeFile(dir / (sanitizeServerName(server) & ".json"),
    "{\"tokens\": {\"access_token\": \"" & jwtWith(payload) & "\"}}")

const fixedNow: int64 = 1700000000'i64

proc remoteKeySpec(): McpServerSpec =
  McpServerSpec(name: "mem", url: "https://host/mcp", authEnv: "MEM_KEY")

suite "phase 6b http transport":
  test "list posts carry bearer and the session id round-trips":
    var seenBearer = ""
    var seenSessions: seq[string] = @[]
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      let node = parseJson(extractJsonResponse(body))
      let meth = node{"method"}.getStr()
      case meth
      of "initialize":
        seenBearer = bearer
        assert url == "https://host/mcp"
        assert sessionId == ""
        HttpResult(status: 200, body: initOkLine, sessionId: "sess-1")
      of "tools/list":
        seenSessions.add(sessionId)
        HttpResult(status: 200, body: listOkLine, sessionId: "sess-1")
      else:
        raise newException(ValueError, "unexpected method: " & meth)
    let (metas, sid) = listToolsViaHttp(post, remoteKeySpec(),
      envOf([("MEM_KEY", "tok123")]))
    assert sid == "sess-1"
    assert seenBearer == "tok123"
    assert seenSessions == @["sess-1"]
    assert metas.len == 2
    assert metas[0].name == "word_count"

  test "an sse stream body parses to the json-rpc result":
    let sseList = "event: message\n" & "data: " & listOkLine & "\n\n"
    let sseCall = "data: " & callOkLine & "\n\n"
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: sseList, sessionId: "s")
      of "tools/call":
        HttpResult(status: 200, body: sseCall, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let (metas, _) = listToolsViaHttp(post, remoteKeySpec(),
      envOf([("MEM_KEY", "t")]))
    assert metas.len == 2
    let text = callToolViaHttp(post, "https://host/mcp", "s", "t",
      "mem", "word_count", %*{"text": "hi"})
    assert text == "3 words\n[non-text content]\ntail"

  test "a 401 raises, and the bridge warning carries the auth hint":
    let post401: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      HttpResult(status: 401, body: """{"error": "unauthorized"}""",
        sessionId: "")
    expect IOError:
      discard listToolsViaHttp(post401, remoteKeySpec(),
        envOf([("MEM_KEY", "stale")]))
    let home = freshTmpHome("waku-mcp-401")
    let res = connectAll(@[remoteKeySpec()], envOf([("MEM_KEY", "stale")]),
      home, 30.0, nil, post401)
    assert res.tools.len == 0
    assert res.warnings.len == 2
    assert "failed to connect" in res.warnings[0]
    assert "MEM_KEY" in res.warnings[1]
    removeDir(home)

  test "a failing http call reads as text, nil reads as not connected":
    let failing: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      raise newException(IOError, "boom")
    assert callToolViaHttp(failing, "https://host/mcp", "s", "t",
      "mem", "word_count", %*{}) ==
      "MCP call mem_word_count failed: boom"
    let noPost: HttpPostFn = nil
    assert callToolViaHttp(noPost, "https://host/mcp", "", "", "mem",
      "word_count", %*{}) == "MCP server 'mem' is not connected."

suite "phase 6b bridge connectAll":
  test "one bad server does not stop the rest":
    let seen = newSeen()
    let good = stdioSpec()
    let bad = remoteKeySpec()
    let badPost: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      raise newException(IOError, "down")
    let factory: StdioFactory = proc(spec: McpServerSpec): ExchangeFn {.closure.} =
      recordExchange(seen)
    let home = freshTmpHome("waku-mcp-skip")
    let res = connectAll(@[good, bad], envOf([("MEM_KEY", "t")]), home,
      30.0, factory, badPost)
    assert res.tools.len == 2
    assert res.tools[0].name == "fs_word_count"
    assert res.warnings.len == 2
    assert "'mem'" in res.warnings[0]
    assert "MEM_KEY" in res.warnings[1]
    removeDir(home)

  test "a missing auth_env is a config warning with no hint":
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      raise newException(IOError, "must not be called")
    let home = freshTmpHome("waku-mcp-nokey")
    let res = connectAll(@[remoteKeySpec()], envOf([]), home, 30.0,
      nil, post)
    assert res.tools.len == 0
    assert res.warnings.len == 1
    assert "MEM_KEY is not set" in res.warnings[0]
    removeDir(home)

  test "retry fires once when a token appears after the first failure":
    let home = freshTmpHome("waku-mcp-retry")
    var calls = 0
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      if calls == 0 and meth == "initialize":
        inc calls
        createDir(home / "mcp-auth")
        writeFile(home / "mcp-auth" / (sanitizeServerName("o") & ".json"),
          """{"tokens": {}}""")
        raise newException(IOError, "browser still open")
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: listOkLine, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let spec = McpServerSpec(name: "o", url: "https://host/mcp", oauth: true)
    let res = connectAll(@[spec], envOf([]), home, 30.0, nil, post)
    assert res.tools.len == 2
    assert res.warnings.len == 1
    assert "reconnecting" in res.warnings[0]
    removeDir(home)

  test "deadline doubles the timeout, oauth without token waits for sign-in":
    let home = freshTmpHome("waku-mcp-deadline")
    assert connectionDeadline(@[remoteKeySpec()], home, 30.0) == 60.0
    let oauth = McpServerSpec(name: "o", url: "https://h/m", oauth: true)
    assert connectionDeadline(@[oauth], home, 30.0) == signInTimeout + 60.0
    createDir(home / "mcp-auth")
    writeFile(home / "mcp-auth" / (sanitizeServerName("o") & ".json"), "{}")
    assert connectionDeadline(@[oauth], home, 30.0) == 60.0
    removeDir(home)

  test "an oauth server that never signs in names the deadline it waited":
    let home = freshTmpHome("waku-mcp-waited")
    let seen = newSeen()
    # The sleeper is what keeps the 360 s this server would really be
    # given out of the suite; the two servers are the other half of the
    # pin, because the one that waited out its deadline must not stop
    # the next one.
    let sleeper: SleepFn = proc(seconds: float) {.closure.} = discard
    let down: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      raise newException(IOError, "browser still open")
    let factory: StdioFactory = proc(spec: McpServerSpec): ExchangeFn {.closure.} =
      recordExchange(seen)
    let oauth = McpServerSpec(name: "o", url: "https://rs.example/mcp",
      oauth: true)
    let res = connectAll(@[oauth, stdioSpec()], envOf([]), home, 30.0,
      factory, down, fixedNow, sleeper)
    assert res.tools.len == 2
    let warning = res.warnings[0]
    assert ("no token within the " & $int(signInTimeout + 60.0) &
      "s connection deadline") in warning
    assert not ("signed in" in warning)
    removeDir(home)

  test "the wait polls the token file to the deadline and gives up":
    let home = freshTmpHome("waku-mcp-wait-cadence")
    var slept = 0.0
    var naps = 0
    let sleeper: SleepFn = proc(seconds: float) {.closure.} =
      slept += seconds
      inc naps
    let down: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      raise newException(IOError, "browser still open")
    let oauth = McpServerSpec(name: "o", url: "https://rs.example/mcp",
      oauth: true)
    let res = connectAll(@[oauth], envOf([]), home, 30.0, nil, down,
      fixedNow, sleeper)
    assert res.tools.len == 0
    assert res.warnings.len == 2
    assert "no token within the 360s connection deadline" in
      res.warnings[0]
    assert "browser still open" in res.warnings[0]
    assert "sign-in did not complete" in res.warnings[1]
    assert slept == signInTimeout + 60.0
    assert naps == int((signInTimeout + 60.0) / signInPollSeconds)
    removeDir(home)

  test "a token that lands during the wait reconnects once":
    let home = freshTmpHome("waku-mcp-wait-late")
    var naps = 0
    let sleeper: SleepFn = proc(seconds: float) {.closure.} =
      inc naps
      if naps == 3:
        writeTokenFile(home, "o",
          "{\"email\": \"o@x\", \"exp\": " & $(fixedNow + 3600) & "}")
    var attempts = 0
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      inc attempts
      if attempts == 1:
        raise newException(IOError, "browser still open")
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: listOkLine, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let oauth = McpServerSpec(name: "o", url: "https://rs.example/mcp",
      oauth: true)
    let res = connectAll(@[oauth], envOf([]), home, 30.0, nil, post,
      fixedNow, sleeper)
    assert res.tools.len == 2
    assert res.warnings.len == 1
    assert "signed in" in res.warnings[0]
    assert naps == 3
    removeDir(home)

  test "the live clock waits for the same token, without burning time":
    let home = freshTmpHome("waku-mcp-wait-live-clock")
    var naps = 0
    let sleeper: SleepFn = proc(seconds: float) {.closure.} =
      inc naps
      writeTokenFile(home, "o", "{\"email\": \"o@x\"}")
    var attempts = 0
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      inc attempts
      if attempts == 1:
        raise newException(IOError, "browser still open")
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: listOkLine, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let oauth = McpServerSpec(name: "o", url: "https://rs.example/mcp",
      oauth: true)
    # `nowUnix` 0 reads the wall clock, so the wait re-reads it after
    # each sleep. The token lands on the first poll: one fake sleep, no
    # real waiting.
    let res = connectAll(@[oauth], envOf([]), home, 30.0, nil, post, 0,
      sleeper)
    assert res.tools.len == 2
    assert res.warnings.len == 1
    assert "signed in" in res.warnings[0]
    assert naps == 1
    removeDir(home)

  test "a non-oauth failure waits for nothing":
    let home = freshTmpHome("waku-mcp-nowait")
    var naps = 0
    let sleeper: SleepFn = proc(seconds: float) {.closure.} =
      inc naps
    let down: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      raise newException(IOError, "down")
    let res = connectAll(@[remoteKeySpec()], envOf([("MEM_KEY", "t")]),
      home, 30.0, nil, down, fixedNow, sleeper)
    assert naps == 0
    assert res.tools.len == 0
    assert res.warnings.len == 2
    assert "down" in res.warnings[0]
    removeDir(home)

  test "registry http tools dispatch under the original name":
    var seenName = ""
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      seenName = parseJson(extractJsonResponse(body))["params"]["name"].getStr()
      HttpResult(status: 200, body: callOkLine, sessionId: "s")
    let tools = toRegistryToolsHttp("demo", parseToolList(listOkLine),
      post, "https://host/mcp", "s", "t")
    assert tools[1].name == "demo_memory_remember"
    assert tools[1].description == "[MCP:demo] Store it"
    assert tools[1].fn(%*{}) == "3 words\n[non-text content]\ntail"
    assert seenName == "memory.remember"

suite "phase 6b jwt identity":
  test "claims decode unverified, garbage decodes to empty":
    let claims = decodeClaims(jwtWith("""{"email": "a@x", "exp": 99}"""))
    assert claims{"email"}.getStr() == "a@x"
    assert decodeClaims("abc").len == 0
    assert decodeClaims("h.!!!.s").len == 0

  test "identity covers signed-out, unreadable and bare accounts":
    let home = freshTmpHome("waku-mcp-ident")
    assert mcpIdentity(home / "mcp-auth" / "m.json", fixedNow) ==
      "not signed in"
    createDir(home / "mcp-auth")
    writeFile(home / "mcp-auth" / "m.json", "{nope")
    assert mcpIdentity(home / "mcp-auth" / "m.json", fixedNow) ==
      "unreadable — will sign in again"
    writeTokenFile(home, "n", """{"sub": "u123"}""")
    assert mcpIdentity(authFilePath(home, "n"), fixedNow) == "u123"
    removeDir(home)

  test "identity renders minutes, hours and expiry like python":
    let home = freshTmpHome("waku-mcp-exp")
    writeTokenFile(home, "a",
      "{\"email\": \"a@x\", \"exp\": " & $(fixedNow + 42 * 60) & "}")
    assert mcpIdentity(authFilePath(home, "a"), fixedNow) ==
      "a@x — 42m left"
    writeTokenFile(home, "b",
      "{\"email\": \"b@x\", \"exp\": " & $(fixedNow + 3 * 3600) & "}")
    assert mcpIdentity(authFilePath(home, "b"), fixedNow) ==
      "b@x — 3h left"
    writeTokenFile(home, "c",
      "{\"email\": \"c@x\", \"exp\": " & $(fixedNow - 10) & "}")
    assert mcpIdentity(authFilePath(home, "c"), fixedNow) ==
      "c@x — token expired, refreshes on next use"
    removeDir(home)

suite "phase 6b cli helpers":
  test "list with no servers points at the config path":
    let home = freshTmpHome("waku-mcp-list-empty")
    let lines = mcpListLines(home, fixedNow)
    assert lines.len == 1
    assert "No MCP servers configured" in lines[0]
    assert (home / "mcp.json") in lines[0]
    removeDir(home)

  test "list shows local, key and oauth rows with identity":
    let home = freshTmpHome("waku-mcp-list")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "fs", "command": "npx"},
      {"name": "mem", "url": "https://host/mcp", "auth_env": "MEM_KEY"},
      {"name": "o", "url": "https://h2/m", "oauth": true}]}""")
    writeTokenFile(home, "o",
      "{\"email\": \"o@x\", \"exp\": " & $(fixedNow + 3600) & "}")
    let text = mcpListLines(home, fixedNow).join("\n")
    assert "fs" in text
    assert "(local process)" in text
    assert "api key · $MEM_KEY" in text
    assert "oauth · o@x" in text
    removeDir(home)

  test "logout removes the file, unknown stays signed-out":
    let home = freshTmpHome("waku-mcp-logout")
    let (msg1, code1) = mcpLogout(home, "o")
    assert code1 == 0
    assert "not signed in" in msg1
    createDir(home / "mcp-auth")
    writeFile(authFilePath(home, "o"), "{}")
    let (msg2, code2) = mcpLogout(home, "o")
    assert code2 == 0
    assert "Signed out" in msg2
    assert not fileExists(authFilePath(home, "o"))
    removeDir(home)

  test "login on unknown servers and oauth names 6c honestly":
    let home = freshTmpHome("waku-mcp-login")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://h2/m", "oauth": true}]}""")
    let (ok1, msg1) = mcpLogin(home, "nope", envOf([]), nil, nil, fixedNow)
    assert not ok1
    assert "No server called 'nope'" in msg1
    let (ok2, msg2) = mcpLogin(home, "o", envOf([]), nil, nil, fixedNow)
    assert not ok2
    assert "OAuthFlowFn" in msg2
    removeDir(home)

  test "login reconnects stdio and key servers through the bridge":
    let home = freshTmpHome("waku-mcp-login-ok")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "fs", "command": "npx"},
      {"name": "mem", "url": "https://host/mcp", "auth_env": "MEM_KEY"}]}""")
    let seen = newSeen()
    let factory: StdioFactory = proc(spec: McpServerSpec): ExchangeFn {.closure.} =
      recordExchange(seen)
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: listOkLine, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let (okFs, msgFs) = mcpLogin(home, "fs", envOf([]), post, factory,
      fixedNow)
    assert okFs
    assert "2 tools" in msgFs
    let (okMem, _) = mcpLogin(home, "mem", envOf([("MEM_KEY", "t")]),
      post, factory, fixedNow)
    assert okMem
    let (okBad, msgBad) = mcpLogin(home, "mem", envOf([]), post, factory,
      fixedNow)
    assert not okBad
    assert "MEM_KEY is not set" in msgBad
    removeDir(home)

## Phase 6c tests: OAuth browser flow (DCR + PKCE + loopback callback +
## FileTokenStorage), offline only.
##
## Every interactive effect travels through an injected seam (HttpPostFn /
## HttpGetFn fakes with recorded responses, BrowserFn, CallbackWaitFn,
## RandIntFn). No socket is opened, no browser spawned, no clock read:
## `home` lives under getTempDir() and time travels via fixedNow. The live
## adapters (waitCallbackLive, openBrowserLive, liveHttpGet, liveRandInt)
## are never called here.

const rfc7636Verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
const rfc7636Challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

proc oauthSpec(): McpServerSpec =
  McpServerSpec(name: "o", url: "https://rs.example/mcp", oauth: true)

proc cannedGet(url, bearer: string): tuple[status: int, body: string] =
  if url.endsWith("/.well-known/oauth-protected-resource/mcp"):
    return (200,
      """{"authorization_servers": ["https://idp.example"]}""")
  if url == "https://idp.example/.well-known/oauth-authorization-server":
    return (200,
      """{"authorization_endpoint": "https://idp.example/authorize",
      "token_endpoint": "https://idp.example/token",
      "registration_endpoint": "https://idp.example/register"}""")
  return (404, """{"error": "not found"}""")

proc seqRand(vals: seq[int]): RandIntFn =
  var i = 0
  result = proc(maxExclusive: int): int {.closure.} =
    let v = vals[i mod vals.len] mod maxExclusive
    inc i
    return v

proc captureBrowser(seen: ref string, opened: bool): BrowserFn =
  result = proc(url: string): bool {.closure.} =
    seen[] = url
    return opened

proc stateOf(url: string): string =
  let q = url.split('?')
  if q.len < 2:
    return ""
  for part in q[1].split('&'):
    if part.startsWith("state="):
      return part[6 .. ^1]
  return ""

proc echoStateWait(seen: ref string): CallbackWaitFn =
  result = proc(port: int, path: string,
      maxAttempts: int): string {.closure.} =
    assert port == callbackPort
    assert path == callbackPath
    assert maxAttempts == callbackPollAttempts()
    return "/callback?code=authcode123&state=" & stateOf(seen[])

suite "phase 6c sha256 and pkce":
  test "sha256 matches the NIST vectors for empty and abc":
    assert sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "pkce S256 matches the RFC 7636 appendix B vector":
    assert pkceChallenge(rfc7636Verifier) == rfc7636Challenge

  test "base64url has no padding and randomToken is deterministic":
    assert base64urlEncode([byte(ord('f'))]) == "Zg"
    let tok = randomToken(64, seqRand(@[1, 2, 3]))
    assert tok.len == 64
    assert tok[0 .. 5] == "BCDBCD"
    for c in tok:
      assert c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '.', '_', '~'}
    for _ in 1 .. 50:
      assert liveRandInt(66) in 0 ..< 66

suite "phase 6c token storage":
  test "tokens and client_info round-trip under one file":
    let home = freshTmpHome("waku-mcp-store")
    setStoredTokens(home, "o", %*{"access_token": "a1"})
    setStoredClientInfo(home, "o", %*{"client_id": "cid"})
    assert fileExists(authFilePath(home, "o"))
    assert getStoredTokens(home, "o"){"access_token"}.getStr() == "a1"
    assert getStoredClientInfo(home, "o"){"client_id"}.getStr() == "cid"
    removeDir(home)

  test "missing and corrupt files read as absent, never raise":
    let home = freshTmpHome("waku-mcp-store-bad")
    assert getStoredTokens(home, "o") == nil
    assert getStoredClientInfo(home, "o") == nil
    assert readTokenDoc(authFilePath(home, "o")) == newJObject()
    createDir(home / "mcp-auth")
    writeFile(authFilePath(home, "o"), "{truncated")
    assert getStoredTokens(home, "o") == nil
    assert getStoredClientInfo(home, "o") == nil
    assert readTokenDoc(authFilePath(home, "o")) == newJObject()
    removeDir(home)

  test "writes are 0600 with no tmp file left behind":
    let home = freshTmpHome("waku-mcp-store-mode")
    setStoredTokens(home, "o", %*{"access_token": "a1"})
    let path = authFilePath(home, "o")
    assert getFilePermissions(path) == {fpUserRead, fpUserWrite}
    assert not fileExists(path & ".tmp")
    setStoredClientInfo(home, "o", %*{"client_id": "cid"})
    assert getStoredTokens(home, "o"){"access_token"}.getStr() == "a1"
    assert not fileExists(path & ".tmp")
    removeDir(home)

  test "odd names stay in one safe file":
    assert sanitizeServerName("a/b c") == "a_b_c"
    let home = freshTmpHome("waku-mcp-store-name")
    assert authFilePath(home, "a/b c").endsWith("a_b_c.json")
    removeDir(home)

suite "phase 6c callback":
  test "a code callback parses code, state and iss":
    let p = parseCallbackTarget(
      "/callback?code=abc&state=s1&iss=https%3A%2F%2Fidp")
    assert p.status == 200
    assert p.code == "abc"
    assert p.state == "s1"
    assert p.iss == "https://idp"
    assert p.err == ""

  test "an error callback keeps the server's own words":
    let p = parseCallbackTarget(
      "/callback?error=access_denied&error_description=User+denied")
    assert p.status == 200
    assert p.err == "access_denied"
    assert callbackError(p.err, p.errDesc) ==
      "authorization failed: access_denied \u2014 User denied"
    assert callbackError("invalid_client", "") ==
      "authorization failed: invalid_client"
    assert callbackError("", "") == ""

  test "a wrong path is a 404 and the page reads as signed in":
    assert parseCallbackTarget("/nope?code=x").status == 404
    assert "Signed in." in callbackSuccessPage()
    assert "close this tab" in callbackSuccessPage()

suite "phase 6c oauth http shapes":
  test "resource metadata url inserts the well-known path":
    assert resourceMetadataUrl("https://host/mcp") ==
      "https://host/.well-known/oauth-protected-resource/mcp"
    assert resourceMetadataUrl("https://host") ==
      "https://host/.well-known/oauth-protected-resource"
    assert resourceMetadataUrl("https://host/") ==
      "https://host/.well-known/oauth-protected-resource"
    assert redirectUri() == "http://127.0.0.1:41765/callback"

  test "dcr body carries the Waku client metadata":
    let body = dcrBody()
    assert body["client_name"].getStr() == "Waku"
    assert body["redirect_uris"][0].getStr() == redirectUri()
    assert "authorization_code" in $body["grant_types"]
    assert "refresh_token" in $body["grant_types"]
    assert body["response_types"][0].getStr() == "code"
    assert body["token_endpoint_auth_method"].getStr() == "none"

  test "the authorize url carries S256, challenge and state":
    let url = authorizeUrl("https://idp.example/authorize", "cid123",
      rfc7636Challenge, "st8")
    assert url.startsWith("https://idp.example/authorize?")
    assert "response_type=code" in url
    assert "client_id=cid123" in url
    assert "code_challenge=" & rfc7636Challenge in url
    assert "code_challenge_method=S256" in url
    assert "state=st8" in url
    assert "redirect_uri=http%3A%2F%2F127.0.0.1%3A41765%2Fcallback" in url

  test "token and refresh bodies carry grant types and verifier":
    let ex = tokenExchangeBody("code1", "ver1", "cid")
    assert ex["grant_type"].getStr() == "authorization_code"
    assert ex["code"].getStr() == "code1"
    assert ex["code_verifier"].getStr() == "ver1"
    assert ex["client_id"].getStr() == "cid"
    assert ex["redirect_uri"].getStr() == redirectUri()
    let rf = refreshBody("r1", "cid")
    assert rf["grant_type"].getStr() == "refresh_token"
    assert rf["refresh_token"].getStr() == "r1"

  test "parsers refuse shapes without ids, tokens or endpoints":
    expect ValueError:
      discard parseDcrResponse("""{"no": 1}""")
    expect ValueError:
      discard parseTokenResponse("""{"no": 1}""")
    expect ValueError:
      discard parseServerMetadata("""{"token_endpoint": "t"}""")
    expect ValueError:
      discard parseResourceMetadata("""{"authorization_servers": []}""")

suite "phase 6c sign-in flow":
  test "a full sign-in stores client_info and tokens":
    let home = freshTmpHome("waku-mcp-oauth-ok")
    let jwt = jwtWith("""{"email": "o@x"}""")
    let dcrCount = new(int)
    dcrCount[] = 0
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      if url == "https://idp.example/register":
        inc dcrCount[]
        return HttpResult(status: 201,
          body: """{"client_id": "cid123"}""", sessionId: "")
      assert url == "https://idp.example/token"
      let node = parseJson(body)
      assert node["grant_type"].getStr() == "authorization_code"
      assert node["code"].getStr() == "authcode123"
      assert node["code_verifier"].getStr().len >= 43
      assert node["client_id"].getStr() == "cid123"
      return HttpResult(status: 200, body: "{\"access_token\": \"" &
        jwt & "\", \"refresh_token\": \"r123\"}", sessionId: "")
    let seen = new(string)
    seen[] = ""
    let (ok, _, timedOut) = oauthSignIn(home, oauthSpec(), post,
      cannedGet, captureBrowser(seen, true), echoStateWait(seen),
      seqRand(@[7]))
    assert ok
    assert not timedOut
    assert seen[].startsWith("https://idp.example/authorize?")
    assert getStoredClientInfo(home, "o"){"client_id"}.getStr() ==
      "cid123"
    assert getStoredClientInfo(home,
      "o"){"token_endpoint"}.getStr() == "https://idp.example/token"
    assert getStoredTokens(home, "o"){"access_token"}.getStr() == jwt
    assert getStoredTokens(home, "o"){"refresh_token"}.getStr() == "r123"
    assert dcrCount[] == 1
    removeDir(home)

  test "a second sign-in reuses the stored client without DCR":
    let home = freshTmpHome("waku-mcp-oauth-reuse")
    var dcrCalls = 0
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      if url == "https://idp.example/register":
        inc dcrCalls
        return HttpResult(status: 201,
          body: """{"client_id": "cid123"}""", sessionId: "")
      return HttpResult(status: 200,
        body: """{"access_token": "tok"}""", sessionId: "")
    let seen = new(string)
    seen[] = ""
    for _ in 1 .. 2:
      let (ok, _, _) = oauthSignIn(home, oauthSpec(), post, cannedGet,
        captureBrowser(seen, true), echoStateWait(seen), seqRand(@[7]))
      assert ok
    assert dcrCalls == 1
    removeDir(home)

  test "a denied authorization surfaces the server's words":
    let home = freshTmpHome("waku-mcp-oauth-deny")
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      return HttpResult(status: 201,
        body: """{"client_id": "cid"}""", sessionId: "")
    let denied: CallbackWaitFn = proc(port: int, path: string,
        maxAttempts: int): string {.closure.} =
      "/callback?error=access_denied&error_description=No+way"
    let seen = new(string)
    seen[] = ""
    let (ok, msg, timedOut) = oauthSignIn(home, oauthSpec(), post,
      cannedGet, captureBrowser(seen, true), denied, seqRand(@[7]))
    assert not ok
    assert not timedOut
    assert "authorization failed: access_denied" in msg
    assert getStoredTokens(home, "o") == nil
    removeDir(home)

  test "silence from the browser is a timeout naming the retry":
    let home = freshTmpHome("waku-mcp-oauth-timeout")
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      return HttpResult(status: 201,
        body: """{"client_id": "cid"}""", sessionId: "")
    let silent: CallbackWaitFn = proc(port: int, path: string,
        maxAttempts: int): string {.closure.} = ""
    let seen = new(string)
    seen[] = ""
    let (ok, msg, timedOut) = oauthSignIn(home, oauthSpec(), post,
      cannedGet, captureBrowser(seen, true), silent, seqRand(@[7]))
    assert not ok
    assert timedOut
    assert "timed out waiting for the browser sign-in" in msg
    removeDir(home)

  test "headless timeout prints the url as the only way through":
    let home = freshTmpHome("waku-mcp-oauth-headless")
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      return HttpResult(status: 201,
        body: """{"client_id": "cid"}""", sessionId: "")
    let silent: CallbackWaitFn = proc(port: int, path: string,
        maxAttempts: int): string {.closure.} = ""
    let seen = new(string)
    seen[] = ""
    let (_, msg, timedOut) = oauthSignIn(home, oauthSpec(), post,
      cannedGet, captureBrowser(seen, false), silent, seqRand(@[7]))
    assert timedOut
    assert "If it does not open" in msg
    assert seen[] in msg
    removeDir(home)

  test "a wrong state fails closed":
    let home = freshTmpHome("waku-mcp-oauth-state")
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      return HttpResult(status: 201,
        body: """{"client_id": "cid"}""", sessionId: "")
    let evil: CallbackWaitFn = proc(port: int, path: string,
        maxAttempts: int): string {.closure.} =
      "/callback?code=abc&state=forged"
    let seen = new(string)
    seen[] = ""
    let (ok, msg, _) = oauthSignIn(home, oauthSpec(), post, cannedGet,
      captureBrowser(seen, true), evil, seqRand(@[7]))
    assert not ok
    assert "state mismatch" in msg
    assert getStoredTokens(home, "o") == nil
    removeDir(home)

  test "a busy loopback port fails naming the port":
    let home = freshTmpHome("waku-mcp-oauth-busy")
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      return HttpResult(status: 201,
        body: """{"client_id": "cid"}""", sessionId: "")
    let busy: CallbackWaitFn = proc(port: int, path: string,
        maxAttempts: int): string {.closure.} =
      raise newException(IOError,
        "port 41765 is in use \u2014 the sign-in redirect has nowhere to land.")
    let seen = new(string)
    seen[] = ""
    let (ok, msg, _) = oauthSignIn(home, oauthSpec(), post, cannedGet,
      captureBrowser(seen, true), busy, seqRand(@[7]))
    assert not ok
    assert "is in use" in msg
    assert seen[].len > 0
    removeDir(home)

suite "phase 6c stored bearer and login":
  test "connectAll attaches a fresh stored token":
    let home = freshTmpHome("waku-mcp-bearer")
    let jwt = jwtWith(
      "{\"email\": \"o@x\", \"exp\": " & $(fixedNow + 3600) & "}")
    writeTokenFile(home, "o",
      "{\"email\": \"o@x\", \"exp\": " & $(fixedNow + 3600) & "}")
    var bearers: seq[string] = @[]
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      bearers.add(bearer)
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: listOkLine, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let res = connectAll(@[oauthSpec()], envOf([]), home, 30.0, nil,
      post, fixedNow)
    assert res.tools.len == 2
    assert res.warnings.len == 0
    assert bearers == @[jwt, jwt]
    removeDir(home)

  test "an expired stored token refreshes through the stored endpoint":
    let home = freshTmpHome("waku-mcp-refresh")
    let stale = jwtWith(
      "{\"email\": \"o@x\", \"exp\": " & $(fixedNow - 10) & "}")
    let fresh = jwtWith(
      "{\"email\": \"o@x\", \"exp\": " & $(fixedNow + 3600) & "}")
    createDir(home / "mcp-auth")
    writeFile(authFilePath(home, "o"), "{\"tokens\": {\"access_token\": \"" &
      stale & "\", \"refresh_token\": \"r1\"}, \"client_info\": " &
      "{\"client_id\": \"cid\", \"token_endpoint\": \"https://tok.example/t\"}}")
    var bearers: seq[string] = @[]
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      if url == "https://tok.example/t":
        assert parseJson(body)["grant_type"].getStr() == "refresh_token"
        assert parseJson(body)["refresh_token"].getStr() == "r1"
        return HttpResult(status: 200,
          body: "{\"access_token\": \"" & fresh & "\"}",
          sessionId: "")
      bearers.add(bearer)
      let meth = parseJson(extractJsonResponse(body)){"method"}.getStr()
      case meth
      of "initialize":
        HttpResult(status: 200, body: initOkLine, sessionId: "s")
      of "tools/list":
        HttpResult(status: 200, body: listOkLine, sessionId: "s")
      else:
        raise newException(ValueError, "unexpected: " & meth)
    let res = connectAll(@[oauthSpec()], envOf([]), home, 30.0, nil,
      post, fixedNow)
    assert res.tools.len == 2
    assert bearers == @[fresh, fresh]
    assert getStoredTokens(home, "o"){"access_token"}.getStr() == fresh
    assert getStoredTokens(home,
      "o"){"refresh_token"}.getStr() == "r1"
    removeDir(home)

  test "login with a flow reports the account like python sign_in":
    let home = freshTmpHome("waku-mcp-login-flow")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://rs.example/mcp", "oauth": true}]}""")
    let jwt = jwtWith(
      "{\"email\": \"o@x\", \"exp\": " & $(fixedNow + 3600) & "}")
    let flow: OAuthFlowFn = proc(h: string,
        spec: McpServerSpec): tuple[ok: bool, msg: string,
        timedOut: bool] {.closure.} =
      setStoredTokens(h, spec.name,
        %*{"access_token": jwt, "token_type": "Bearer"})
      return (true, "signed in", false)
    let (ok, msg) = mcpLogin(home, "o", envOf([]), nil, nil, fixedNow,
      30.0, flow)
    assert ok
    assert "o@x" in msg
    removeDir(home)

  test "login timeout names the account check, failure the missing token":
    let home = freshTmpHome("waku-mcp-login-flow-bad")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://rs.example/mcp", "oauth": true}]}""")
    let timeoutFlow: OAuthFlowFn = proc(h: string,
        spec: McpServerSpec): tuple[ok: bool, msg: string,
        timedOut: bool] {.closure.} =
      (false, "timed out waiting for the browser sign-in", true)
    let (okT, msgT) = mcpLogin(home, "o", envOf([]), nil, nil, fixedNow,
      30.0, timeoutFlow)
    assert not okT
    assert "Timed out waiting for the browser sign-in" in msgT
    let failFlow: OAuthFlowFn = proc(h: string,
        spec: McpServerSpec): tuple[ok: bool, msg: string,
        timedOut: bool] {.closure.} =
      (false, "authorization failed: access_denied", false)
    let (okF, msgF) = mcpLogin(home, "o", envOf([]), nil, nil, fixedNow,
      30.0, failFlow)
    assert not okF
    assert "has no token" in msgF
    removeDir(home)

  test "login without a flow names the seam and touches nothing":
    let home = freshTmpHome("waku-mcp-login-noseam")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://rs.example/mcp", "oauth": true}]}""")
    let (ok, msg) = mcpLogin(home, "o", envOf([]), nil, nil, fixedNow)
    assert not ok
    assert "OAuthFlowFn" in msg
    assert not fileExists(authFilePath(home, "o"))
    removeDir(home)

suite "phase 6c constants":
  test "loopback constants match python and share the sign-in timeout":
    assert callbackPort == 41765
    assert callbackPath == "/callback"
    assert redirectUri() == "http://127.0.0.1:41765/callback"
    assert callbackPollAttempts() == 600
    assert signInTimeout == 300.0
