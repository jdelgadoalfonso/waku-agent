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
import std/monotimes
import std/os
import std/osproc
import std/streams
import std/strtabs
import std/times

type
  ProcResult* = object
    ## One finished (or killed) subprocess: `timedOut` means the
    ## deadline fired first (exit code is then meaningless) — the
    ## explicit shape Python's `TimeoutExpired` branch carries.
    timedOut*: bool
    code*: int
    stdout*: string
    stderr*: string

  ProcRunner* = proc(argv: seq[string], workdir: string,
      timeoutSec: int): ProcResult {.closure.}
    ## Run and capture. Tests inject recordings; tools pass
    ## `runProcess` (below) for the live path.

  ToolFn* = proc(args: JsonNode): string {.closure.}

  Tool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    fn*: ToolFn
    wantsNotify*: bool
    tags*: seq[string]
      ## Optional tags for the per-turn filter (mcp-per-turn-filter
      ## proposal §4.2): empty means "always send", so flagship tools
      ## keep their current behavior. MCP tools inherit their server's
      ## task tags.

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

proc tagsMatch(tags, taskTags: seq[string]): bool =
  ## Whether any of `tags` appears in `taskTags` — the set
  ## intersection the filter tests, as a linear scan: both are
  ## short (a server's declared tasks against a turn's signal).
  for t in tags:
    if t in taskTags:
      return true
  return false

proc schemasFor*(reg: ToolRegistry, taskTags: seq[string]): seq[JsonNode] =
  ## The per-turn view `runLoop` sends as its `tools=` parameter
  ## (proposal §4.1). An empty signal is allow-by-default (§4.4)
  ## and returns the full set; otherwise a tool is sent when it has
  ## no tags, or its tags intersect the signal. The registry keeps
  ## every tool either way — `execute` still runs a filtered-out
  ## name when the history already contains its call.
  if taskTags.len == 0:
    return reg.schemas()
  for t in reg.tools:
    if t.tags.len == 0 or tagsMatch(t.tags, taskTags):
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

proc runProcess*(argv: seq[string], workdir = "", timeoutSec = 20,
    env: StringTableRef = nil): ProcResult =
  ## One subprocess, captured, with an explicit deadline: stdin starts
  ## closed (readers see EOF, like `DEVNULL`), a live deadline kills at
  ## `timeoutSec` (`timedOut`), anything else returns its exit code. A
  ## missing binary is `code: 127` with the OS reason — callers map it
  ## to their install hint. `env: nil` inherits the process environment.
  if argv.len == 0:
    return ProcResult(timedOut: false, code: 127, stdout: "",
      stderr: "no command")
  var p: Process
  try:
    p = startProcess(argv[0], workingDir = workdir, args = argv[1 .. ^1],
      env = env, options = {poUsePath})
  except OSError as exc:
    return ProcResult(timedOut: false, code: 127, stdout: "",
      stderr: exc.msg)
  try:
    p.inputStream.close()
  except OSError, IOError:
    discard
  let deadline = getMonoTime() + initDuration(seconds = timeoutSec)
  while p.running and getMonoTime() < deadline:
    sleep(50)
  if p.running:
    try:
      p.kill()
    except OSError:
      discard
    result = ProcResult(timedOut: true, code: 124, stdout: "",
      stderr: "")
  else:
    result = ProcResult(timedOut: false, code: p.waitForExit(),
      stdout: "", stderr: "")
  try:
    result.stdout = readAll(p.outputStream)
    result.stderr = readAll(p.errorStream)
  except OSError, IOError:
    discard
  p.close()

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
