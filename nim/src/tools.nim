## Tool registry — port of `waku/tools/registry.py`.
##
## A tool is three things: a name+description the model reads, a JSON schema
## for its arguments, and a function that runs and returns the string the
## model observes. Argument passing differs by language: Python calls
## `fn(**args)` with typed params; here every tool takes one `JsonNode`
## object (missing keys read as `JNull`), which is also the shape the phase 3
## loop will hand over from a parsed tool-call block.
##
## `wantsNotify` is carried for schema fidelity (long-running tools opt in to
## progress events); the loop's observer is wired in phase 3, not here.

import std/json

type
  ToolFn* = proc(args: JsonNode): string {.closure.}

  Tool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    fn*: ToolFn
    wantsNotify*: bool

  ToolRegistry* = object
    tools*: seq[Tool]

proc register*(reg: var ToolRegistry, tool: Tool) =
  ## Add (or replace by name) one tool.
  for i in 0 ..< reg.tools.len:
    if reg.tools[i].name == tool.name:
      reg.tools[i] = tool
      return
  reg.tools.add(tool)

proc toApi*(tool: Tool): JsonNode =
  ## The shape the Messages API expects in its `tools=` parameter.
  %*{"name": tool.name, "description": tool.description,
      "input_schema": tool.inputSchema}

proc schemas*(reg: ToolRegistry): seq[JsonNode] =
  ## Every tool's API shape, in registration order.
  for t in reg.tools:
    result.add(t.toApi())

proc execute*(reg: ToolRegistry, name: string, args: JsonNode): string =
  ## Run one tool call safely: the model observes errors as text instead of
  ## crashing the loop. Port of `ToolRegistry.execute` (the `notify`
  ## passthrough for `wantsNotify` tools lands with the phase 3 loop).
  for t in reg.tools:
    if t.name == name:
      try:
        return t.fn(args)
      except CatchableError as exc:
        return "Error running " & name & ": " & exc.msg
  return "Error: unknown tool '" & name & "'"

proc hasTool*(reg: ToolRegistry, name: string): bool =
  ## True when `name` is registered (convenience; Python uses `in` on dict).
  for t in reg.tools:
    if t.name == name:
      return true
  return false

proc strArg*(args: JsonNode, key: string, default = ""): string =
  ## Read an optional string arg (missing/null/wrong-type -> default).
  if args.kind == JObject and args.hasKey(key) and args[key].kind == JString:
    return args[key].getStr()
  return default

proc intArg*(args: JsonNode, key: string, default = 0): int =
  ## Read an optional integer arg (missing/wrong-type -> default).
  if args.kind == JObject and args.hasKey(key) and args[key].kind == JInt:
    return args[key].getInt()
  return default
