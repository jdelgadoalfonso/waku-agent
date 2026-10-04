## `delegate_task` tests: pi-stream parsing, the refusal paths and the
## scratch flow — the subprocess is always a stub here. Offline only:
## no `pi` ever runs.

import std/json
import std/os
import std/strtabs
import std/strutils
import std/unittest

import ../src/experimental
import ../src/tools

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc stubSeams(piBin = "/bin/pi", jsonMode = true): PiSeams =
  PiSeams(piBin: piBin, jsonMode: jsonMode,
    run: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
    runPy: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "py ok", stderr: ""),
    workspaceRoot: freshDir("waku-exp-ws"), pythonBin: "python3",
    autorunOff: true,
    recordUsage: proc(tin, tout: int) {.closure.} = discard,
    projectFlags: @[])

suite "pi stream parsing":
  test "texts join, usage and cost accumulate":
    let (reply, tin, tout, cost) = parsePiStream(@[
      """{"type": "message_update", "x": 1}""",
      "not json",
      """{"type": "message_end", "message": {"role": "assistant",
        "usage": {"input": 10, "output": 4, "cost": {"total": 0.02}},
        "content": [{"type": "text", "text": "hello"},
                    {"type": "toolCall", "name": "write"}]}}""",
      """{"type": "message_end", "message": {"role": "user",
        "content": []}}"""])
    assert reply == "hello"
    assert (tin, tout) == (10, 4)
    assert abs(cost - 0.02) < 1e-9

  test "slugs fall back to task":
    assert slugWords("Fix THE 3 failing-tests!", 4) == "fix-the-3-failing"
    assert slugWords("!!!", 4) == "task"

  test "entry prefers main over a stray script":
    let dir = freshDir("waku-exp-entry")
    writeFile(dir / "zzz.py", "print(1)")
    writeFile(dir / "main.py", "print(2)")
    let files = createdFiles(dir)
    assert lastPathPart(pickEntry(files)) == "main.py"
    removeDir(dir)

suite "delegate_task":
  test "an empty task never reaches pi":
    let seams = stubSeams()
    let msg = delegateTask(seams, "anthropic", "m", freshDir("h1"),
      "  ", "/tmp", 0, 300, "2026-10-03/120000")
    assert "needs a 'task'" in msg

  test "a missing pi names the installer":
    var seams = stubSeams()
    seams.piBin = ""
    let msg = delegateTask(seams, "anthropic", "m", freshDir("h2"),
      "do things", "/tmp", 0, 300, "2026-10-03/120000")
    assert "npm install" in msg

  test "a missing cwd is refused before any subprocess":
    let seams = stubSeams()
    let msg = delegateTask(seams, "anthropic", "m", freshDir("h3"),
      "do things", "/no/such/dir", 0, 300, "2026-10-03/120000")
    assert "doesn't exist" in msg

  test "a timeout names the env knob":
    var seams = stubSeams()
    seams.run = proc(argv: seq[string], workdir: string,
        timeoutSec: int, env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: true, code: 124, stdout: "partial",
        stderr: "")
    let msg = delegateTask(seams, "anthropic", "m", freshDir("h4"),
      "do things", "/tmp", 0, 300, "2026-10-03/120000")
    assert "after 300s" in msg
    assert "WAKU_DELEGATE_TIMEOUT" in msg

  test "a coding run reports and logs the transcript":
    let home = freshDir("waku-exp-home")
    var seams = stubSeams()
    seams.run = proc(argv: seq[string], workdir: string,
        timeoutSec: int, env: StringTableRef): ProcResult {.closure.} =
      assert "--mode" in argv and "json" in argv
      assert "-p" in argv
      ProcResult(timedOut: false, code: 0,
        stdout: "{\"type\": \"message_end\", \"message\": {\"role\": " &
        "\"assistant\", \"usage\": {\"input\": 5, \"output\": 5}, " &
        "\"content\": [{\"type\": \"text\", \"text\": \"fixed it\"}]}}",
        stderr: "")
    var spent: seq[(int, int)] = @[]
    seams.recordUsage = proc(tin, tout: int) {.closure.} =
      spent.add((tin, tout))
    let msg = delegateTask(seams, "anthropic", "claude", home,
      "fix it", "/tmp", 0, 300, "2026-10-03/120000")
    assert "fixed it" in msg
    assert "pi finished the delegated task in /tmp" in msg
    assert spent == @[(5, 5)]
    assert fileExists(home / "outbox" / "delegate-120000.log")
    removeDir(home)

  test "a scratch run documents, autoruns and manifests":
    let home = freshDir("waku-exp-home2")
    var seams = stubSeams()
    seams.autorunOff = false
    seams.run = proc(argv: seq[string], workdir: string,
        timeoutSec: int, env: StringTableRef): ProcResult {.closure.} =
      writeFile(workdir / "main.py", "print('ran')")
      ProcResult(timedOut: false, code: 0,
        stdout: "{\"type\": \"message_end\", \"message\": {\"role\": " &
        "\"assistant\", \"content\": [{\"type\": \"text\", " &
        "\"text\": \"wrote it\"}]}}", stderr: "")
    let msg = delegateTask(seams, "openai", "gpt", home, "write snake",
      "", 0, 300, "2026-10-03/120000")
    assert "Files saved to" in msg
    assert "Auto-ran main.py: ran clean" in msg
    assert "py ok" in msg
    assert fileExists(seams.workspaceRoot / "2026-10-03" /
      "120000-gpt-write-snake" / "MANIFEST.md")
    removeDir(home)

  test "stubs stay honest":
    let tools = makeExperimentalTools(stubSeams(), "a", "m",
      freshDir("h5"))
    assert tools[0].name == "delegate_task"
    assert tools[1].name == "run_command"
    assert "coming soon" in tools[1].fn(%*{})
    assert tools.len == 1 + plannedTools.len
