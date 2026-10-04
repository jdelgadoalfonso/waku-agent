## `buildRegistry` tests: order, opt-in flags and MCP tools — every
## side effect behind stubs. Offline only: no sockets, no subprocesses.

import std/json
import std/os
import std/strtabs
import std/strutils
import std/tables
import std/unittest

import db_connector/db_sqlite

import ../src/apple
import ../src/config
import ../src/db
import ../src/experimental
import ../src/registry
import ../src/tools

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc baseSettings(home: string): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
    smallModel: "mini")

proc stubFetch(url, meth, body, agent: string): tuple[ok: bool,
    text: string] =
  (true, """{"results": [{"title": "T", "content": "c",
    "url": "https://t.example"}]}""")

proc stubGh(argv: seq[string]): tuple[ok: bool, text: string] =
  (true, "[]")

proc stubPi(): PiSeams =
  PiSeams(piBin: "", jsonMode: false,
    run: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
    runPy: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
    workspaceRoot: "", pythonBin: "python3", autorunOff: true,
    recordUsage: nil, projectFlags: @[])

proc stubApple(): AppleSeams =
  AppleSeams(hostOs: "linux",
    run: proc(script: string, timeoutSec: int): tuple[ok: bool,
        text: string] {.closure.} =
      raise newException(ValueError, "must not run"),
    isRunning: proc(app: string): bool = false,
    launch: proc(app: string) = discard)

proc toolNames(reg: ToolRegistry): seq[string] =
  for t in reg.tools:
    result.add(t.name)

suite "buildRegistry":
  test "the always-on tools register in Python order":
    let home = freshHome("waku-reg-base")
    let db = connectDb(home)
    let reg = buildRegistry(db, home, baseSettings(home), stubFetch,
      stubGh, stubPi(), stubApple())
    db.close()
    assert toolNames(reg) == @["create_event", "list_events", "save_note",
      "send_message", "search_web", "manage_memory", "update_soul",
      "create_skill"]
    removeDir(home)

  test "opt-ins stay off unless the flag says so":
    let home = freshHome("waku-reg-flags")
    let db = connectDb(home)
    var settings = baseSettings(home)
    settings.experimental = true
    settings.appleTools = true
    settings.ghTool = true
    let reg = buildRegistry(db, home, settings, stubFetch, stubGh,
      stubPi(), stubApple())
    db.close()
    let names = toolNames(reg)
    assert "delegate_task" in names
    assert "run_command" in names
    assert "read_apple_calendar" in names
    assert "create_reminder" in names
    assert "github_read" in names
    removeDir(home)

  test "connected MCP tools append last":
    let home = freshHome("waku-reg-mcp")
    let db = connectDb(home)
    let mcpTool = Tool(name: "mcp_x_y", description: "d",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string = "mcp!")
    let reg = buildRegistry(db, home, baseSettings(home), stubFetch,
      stubGh, stubPi(), stubApple(), @[mcpTool])
    db.close()
    let names = toolNames(reg)
    assert names[^1] == "mcp_x_y"
    assert reg.execute("mcp_x_y", %*{}) == "mcp!"
    removeDir(home)

  test "search runs end to end through the registry":
    putEnv("TAVILY_API_KEY", "test-key")
    let home = freshHome("waku-reg-exec")
    let db = connectDb(home)
    let reg = buildRegistry(db, home, baseSettings(home), stubFetch,
      stubGh, stubPi(), stubApple())
    db.close()
    let text = reg.execute("search_web", %*{"query": "nim"})
    delEnv("TAVILY_API_KEY")
    assert "via Tavily" in text
    assert "1. T" in text
    removeDir(home)

  test "mcpRegistryTools skips oauth without a token":
    let home = freshHome("waku-reg-mcpskip")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "mem", "url": "https://m.example/mcp",
        "oauth": true}]}""")
    let tools = mcpRegistryTools(home, initTable[string, string](),
      1700000000, nil, nil)
    assert tools.len == 0
    removeDir(home)
