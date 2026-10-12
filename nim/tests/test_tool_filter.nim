## Deterministic tests: the per-turn tool filter
## (docs/mcp-per-turn-filter-design.md §4 and §6). A task signal
## narrows the schemas one turn's model call sees, without
## unregistering anything; an empty or missing signal sends the
## full set — the filter defaults to allow (§4.4). The registry
## keeps every tool either way: execute() still runs a name the
## filter held back when the history already contains its call.
##
## Pure and offline: no subprocess, no network, no .waku state.

import std/json
import std/unittest

import ../src/loop
import ../src/mcp
import ../src/tools

proc filteredRegistry(): ToolRegistry =
  ## Two tagged MCP-style tools (<server>_<tool>) plus one
  ## flagship tool that carries no tags.
  result.register(Tool(
    name: "gh_create_pr", description: "Create a GitHub pull request",
    inputSchema: %*{"type": "object", "properties": {}},
    fn: proc(args: JsonNode): string = "created",
    tags: @["code"]))
  result.register(Tool(
    name: "calendar_create_event", description: "Create a calendar event",
    inputSchema: %*{"type": "object", "properties": {}},
    fn: proc(args: JsonNode): string = "created",
    tags: @["calendar"]))
  result.register(Tool(
    name: "save_note", description: "Save a note to memory",
    inputSchema: %*{"type": "object", "properties": {}},
    fn: proc(args: JsonNode): string = "saved"))

proc names(schemas: seq[JsonNode]): seq[string] =
  ## The tool names in a `tools=` list, in order.
  for s in schemas:
    result.add(s["name"].getStr())

proc names(tools: JsonNode): seq[string] =
  ## The tool names in a `tools=` JSON array, in order —
  ## the request-side pin (what the model was actually sent).
  for s in tools:
    result.add(s["name"].getStr())

proc strList(node: JsonNode): seq[string] =
  ## A JSON array of strings as a seq (the `tools_sent` log).
  for s in node:
    result.add(s.getStr())

suite "per-turn tool filter (§6)":
  test "a code task sends the gh tools and omits calendar":
    let sent = names(filteredRegistry().schemasFor(@["code"]))
    assert "gh_create_pr" in sent
    assert "calendar_create_event" notin sent
    # untagged flagship tools keep current behavior (§4.2)
    assert "save_note" in sent

  test "a calendar task sends the calendar tools and omits gh":
    let sent = names(filteredRegistry().schemasFor(@["calendar"]))
    assert "calendar_create_event" in sent
    assert "gh_create_pr" notin sent
    assert "save_note" in sent

  test "an empty signal sends the full set":
    let reg = filteredRegistry()
    assert names(reg.schemasFor(@[])) == names(reg.schemas())

suite "mcp.json task declarations (§4.2/§4.3)":
  test "a server's tasks reach every tool it publishes":
    let specs = parseMcpConfig("""{"servers": [
      {"name": "gh", "command": "mcp-gh", "tasks": ["code"]}]}""")
    assert specs.len == 1
    assert specs[0].tasks == @["code"]
    let metas = @[McpToolMeta(name: "do_thing", description: "do it",
      inputSchema: %*{"type": "object", "properties": {}})]
    let tools = toRegistryTools("gh", metas, nil, tags = specs[0].tasks)
    assert tools[0].tags == @["code"]
    var reg: ToolRegistry
    reg.register(tools[0])
    assert names(reg.schemasFor(@["code"])) == @["gh_do_thing"]
    assert names(reg.schemasFor(@["calendar"])) == @[]

  test "a server without tasks is always visible":
    let specs = parseMcpConfig("""{"servers": [
      {"name": "fs", "command": "npx"}]}""")
    assert specs[0].tasks == @[]
    let metas = @[McpToolMeta(name: "read", description: "read a file",
      inputSchema: %*{"type": "object", "properties": {}})]
    let tools = toRegistryTools("fs", metas, nil)
    var reg: ToolRegistry
    reg.register(tools[0])
    assert names(reg.schemasFor(@["code"])) == @["fs_read"]

  test "an invalid tasks declaration is ignored, the server stays always visible":
    let specs = parseMcpConfig("""{"servers": [
      {"name": "gh", "command": "mcp-gh", "tasks": "code"}]}""")
    assert specs[0].tasks == @[]

  test "deriveTaskTags fires a server's tasks on its when phrases":
    let specs = parseMcpConfig("""{"servers": [
      {"name": "gh", "command": "mcp-gh", "tasks": ["code"],
       "when": ["repo", "pull request"]},
      {"name": "cal", "command": "mcp-cal", "tasks": ["calendar"],
       "when": ["calendar"]}]}""")
    assert deriveTaskTags("open a PR on the repo", specs) == @["code"]
    assert deriveTaskTags("what is on my CALENDAR today", specs) == @["calendar"]
    assert deriveTaskTags("hello there", specs) == @[]

  test "a server with tasks but no when never fires on its own":
    # a tag with no trigger would fire on every turn, which is a
    # false positive, not a filter (§4.2)
    let specs = parseMcpConfig("""{"servers": [
      {"name": "gh", "command": "mcp-gh", "tasks": ["code"]}]}""")
    assert deriveTaskTags("fix the repo", specs) == @[]

suite "run_loop filter point (§4.1/§4.4)":
  # The scripted-client pattern from test_loop.nim: the responses
  # play back in order, and every request the client saw stays
  # readable in `reqs` — the request-side pins live there.
  proc textResp(text: string): JsonNode =
    %*{"stop_reason": "end_turn", "usage": {"in": 1, "out": 1},
       "content": [{"type": "text", "text": text}]}

  proc toolResp(id, name: string, input: JsonNode): JsonNode =
    %*{"stop_reason": "tool_use", "usage": {"in": 1, "out": 1},
       "content": [{"type": "tool_use", "id": id, "name": name,
                    "input": input}]}

  type Script = ref object
    items: seq[JsonNode]
    pos: int
    reqs*: seq[JsonNode]

  proc scriptedClient(script: Script): LlmClient =
    LlmClient(create: proc(req: JsonNode): JsonNode =
      script.reqs.add(copy(req))
      result = script.items[script.pos]
      inc script.pos)

  proc taggedRegistry(): ToolRegistry =
    result.register(Tool(
      name: "gh_create_pr", description: "Create a GitHub pull request",
      inputSchema: %*{"type": "object", "properties": {}},
      fn: proc(args: JsonNode): string = "created",
      tags: @["code"]))
    result.register(Tool(
      name: "calendar_create_event", description: "Create a calendar event",
      inputSchema: %*{"type": "object", "properties": {}},
      fn: proc(args: JsonNode): string = "created",
      tags: @["calendar"]))

  test "runLoop sends the filtered set and logs it per turn":
    let script = Script(items: @[textResp("done")])
    var llmEvents: seq[JsonNode] = @[]
    var messages = @[%*{"role": "user", "content": "hi"}]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      taggedRegistry(), 10, 2048,
                      proc(kind: string, ev: JsonNode) =
                        if kind == "llm": llmEvents.add(ev),
                      taskTags = @["code"])
    assert res.reply == "done"
    # §4.1: the request carried only the code-tagged tool
    assert names(script.reqs[0]["tools"]) == @["gh_create_pr"]
    # §4.4: the turn logged what the model actually saw
    assert strList(llmEvents[0]["tools_sent"]) == @["gh_create_pr"]

  test "runLoop with no signal sends the full set":
    let script = Script(items: @[textResp("done")])
    var messages = @[%*{"role": "user", "content": "hi"}]
    discard runLoop(scriptedClient(script), "m", "sys", messages,
                    taggedRegistry(), 10, 2048)
    assert names(script.reqs[0]["tools"]) ==
      @["gh_create_pr", "calendar_create_event"]

  test "the tools-off call after the limit sends the turn's filtered set":
    let script = Script(items: @[toolResp("1", "gh_create_pr", %*{}),
                                 textResp("done")])
    var messages = @[%*{"role": "user", "content": "hi"}]
    let res = runLoop(scriptedClient(script), "m", "sys", messages,
                      taggedRegistry(), 1, 2048, nil,
                      taskTags = @["code"])
    assert res.limitReached
    assert res.reply == "done"
    # the final call (tools off) still carries this turn's set,
    # never the full registry: its history names a tool_use block
    assert script.reqs[1]["tool_choice"]["type"].getStr() == "none"
    assert names(script.reqs[1]["tools"]) == @["gh_create_pr"]
