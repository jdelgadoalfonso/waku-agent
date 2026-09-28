## Phase 2a tests: the tool registry contract. Pure and offline.

import std/json
import std/unittest

import ../src/tools

proc echoTool(): Tool =
  Tool(name: "echo", description: "repeat the text",
       inputSchema: %*{"type": "object",
                       "properties": {"text": {"type": "string"}},
                       "required": ["text"]},
       fn: proc(args: JsonNode): string = args["text"].getStr())

suite "phase 2a registry":
  test "schemas returns the Messages API shape in order":
    var reg: ToolRegistry
    reg.register(echoTool())
    reg.register(Tool(name: "second", description: "s", inputSchema: %*{},
                      fn: proc(args: JsonNode): string = ""))
    let s = reg.schemas()
    assert s.len == 2
    assert s[0]["name"].getStr() == "echo"
    assert s[0]["input_schema"]["required"][0].getStr() == "text"
    assert s[1]["name"].getStr() == "second"
    assert "fn" notin s[0]

  test "execute runs the tool and observes its string":
    var reg: ToolRegistry
    reg.register(echoTool())
    assert reg.execute("echo", %*{"text": "hi"}) == "hi"

  test "execute reports an unknown tool instead of crashing":
    var reg: ToolRegistry
    assert reg.execute("nope", %*{}) == "Error: unknown tool 'nope'"
    assert not reg.hasTool("nope")
    reg.register(echoTool())
    assert reg.hasTool("echo")

  test "execute surfaces a raising tool as text":
    var reg: ToolRegistry
    reg.register(Tool(name: "boom", description: "b", inputSchema: %*{},
                      fn: proc(args: JsonNode): string = raise newException(ValueError, "kaput")))
    assert reg.execute("boom", %*{}) == "Error running boom: kaput"

  test "re-registering a name replaces the tool":
    var reg: ToolRegistry
    reg.register(echoTool())
    reg.register(Tool(name: "echo", description: "v2", inputSchema: %*{},
                      fn: proc(args: JsonNode): string = "v2"))
    assert reg.execute("echo", %*{"text": "hi"}) == "v2"
    assert reg.schemas().len == 1
