## Phase 6a tests: MCP config + stdio JSON-RPC, offline only.
##
## Every process interaction travels through the injected `ExchangeFn`
## (one JSON-RPC request line -> one response line, recorded responses
## in these tests). No real subprocess is ever spawned and no socket is
## ever opened; the live `osproc` adapter in `src/mcp.nim` is never
## called here. HTTP+OAuth+CLI arrive in 6b/6c.

import std/json
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
  test "stdio connects clean, remote waits for 6b, invalid explains":
    assert connectError(stdioSpec(), envOf([])) == ""
    let remote = McpServerSpec(name: "m", url: "https://host/mcp",
      authEnv: "K")
    let deferred = connectError(remote, envOf([("K", "v")]))
    assert "6b" in deferred
    assert "https://host/mcp" in deferred
    var both = stdioSpec()
    both.url = "https://host/mcp"
    assert connectError(both, envOf([])) ==
      "server has both 'url' and 'command' — pick one transport"
