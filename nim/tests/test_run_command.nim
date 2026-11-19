## `run_command` C1 tests: read-only allowlist, argv-only, no shell.
## Offline only: the subprocess is always a stub here.

import std/json
import std/os
import std/strtabs
import std/strutils
import std/unittest

import ../src/run_command
import ../src/tools

template withEnv(vars: openArray[tuple[key: string, value: string]],
                 body: untyped) =
  block:
    var saved: seq[tuple[key: string, existed: bool, old: string]] = @[]
    for (key, value) in vars:
      saved.add((key, existsEnv(key), getEnv(key)))
      putEnv(key, value)
    try:
      body
    finally:
      for (key, existed, old) in saved:
        if existed: putEnv(key, old)
        else: delEnv(key)

proc freshWs(name: string): string =
  result = getTempDir() / name
  if not dirExists(result):
    createDir(result)

proc stubRunner(expectedArgv: seq[string] = @[],
    outText = "ok"): RunRunner =
  result = proc(argv: seq[string], workdir: string,
      timeoutSec: int): ProcResult {.closure.} =
    assert argv == expectedArgv
    ProcResult(timedOut: false, code: 0, stdout: outText, stderr: "")

suite "run_command allowlist":
  test "an unknown binary is refused before any subprocess":
    let ws = freshWs("waku-run-ws")
    var ran = false
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ran = true
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    let msg = runRead(run, ws, "rm", @["-rf", "/"], ws, 20)
    assert not ran
    assert "read-only" in msg.toLowerAscii()

  test "a shell string is refused, argv only":
    let ws = freshWs("waku-run-ws")
    var ran = false
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ran = true
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    let msg = runRead(run, ws, "ls; rm -rf /", @[], ws, 20)
    assert not ran
    assert "read-only" in msg.toLowerAscii()

  test "git push is refused, git status passes":
    let ws = freshWs("waku-run-ws")
    var ran = false
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ran = true
      ProcResult(timedOut: false, code: 0, stdout: "ok", stderr: "")
    assert "read-only" in runRead(run, ws, "git",
      @["push"], ws, 20).toLowerAscii()
    assert not ran
    let ok = runRead(stubRunner(@["git", "status"], "clean"),
      ws, "git", @["status"], ws, 20)
    assert "clean" in ok

  test "parent escape and absolute paths are refused":
    let ws = freshWs("waku-run-ws")
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    assert "refuse" in runRead(run, ws, "cat",
      @["../secret"], ws, 20).toLowerAscii()
    assert "refuse" in runRead(run, ws, "cat",
      @["/etc/passwd"], ws, 20).toLowerAscii()

  test "a cwd outside the workspace is refused":
    let ws = freshWs("waku-run-ws")
    var ran = false
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ran = true
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    let msg = runRead(run, ws, "ls", @[], "/etc", 20)
    assert not ran
    assert "workspace" in msg.toLowerAscii()

  test "long output truncates with a pointer":
    let ws = freshWs("waku-run-ws")
    let big = "x".repeat(9000)
    let msg = runRead(stubRunner(@["ls"], big),
      ws, "ls", @[], ws, 20)
    assert "truncated" in msg.toLowerAscii()
    assert big[0 ..< 100] in msg

  test "a timeout is honest about the deadline":
    let ws = freshWs("waku-run-ws")
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      assert timeoutSec == 20
      ProcResult(timedOut: true, code: 124, stdout: "", stderr: "")
    let msg = runRead(run, ws, "ls", @[], ws, 20)
    assert "timed out" in msg.toLowerAscii()
    assert "killed" in msg.toLowerAscii()

  test "a failing command surfaces stderr honestly":
    let ws = freshWs("waku-run-ws")
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 1, stdout: "",
        stderr: "ls: cannot access nope")
    let msg = runRead(run, ws, "ls", @[], ws, 20)
    assert "cannot access" in msg

  test "a cwd with .. that escapes is refused":
    let ws = freshWs("waku-run-ws")
    var ran = false
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ran = true
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    let msg = runRead(run, ws, "ls", @[], ws / "..", 20)
    assert not ran
    assert "outside the workspace" in msg

  test "a relative cwd resolves against the workspace root":
    let ws = freshWs("waku-run-ws")
    createDir(ws / "sub")
    var seen = ""
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      seen = workdir
      ProcResult(timedOut: false, code: 0, stdout: "ok", stderr: "")
    let msg = runRead(run, ws, "ls", @[], "sub", 20)
    assert "ok" in msg
    assert seen == normalizedPath(ws / "sub")

  test "grep file-input flags are refused":
    let ws = freshWs("waku-run-ws")
    var ran = false
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ran = true
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    assert "Refused flag" in runRead(run, ws, "grep",
      @["-f", "/tmp/x"], ws, 20)
    assert not ran
    assert "Refused flag" in runRead(run, ws, "grep",
      @["--file=/etc/passwd"], ws, 20)

  test "dangerous git flags are refused with an escape note":
    let ws = freshWs("waku-run-ws")
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: "")
    let msg = runRead(run, ws, "git", @["status", "--upload-pack"],
      ws, 20)
    assert "escape" in msg.toLowerAscii()

  test "a failing command names its exit code":
    let ws = freshWs("waku-run-ws")
    let run: RunRunner = proc(argv: seq[string], workdir: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 2, stdout: "", stderr: "")
    assert "exit 2" in runRead(run, ws, "ls", @[], ws, 20)

suite "run_command env":
  test "the deny list is honored at call time":
    withEnv({"RC_SECRET": "hunter2",
        "WAKU_DELEGATE_ENV_DENY": "RC_SECRET"}):
      let env = runDelegateEnv()
      assert not env.hasKey("RC_SECRET")
      assert env.hasKey("WAKU_DELEGATE_ENV_DENY")
    withEnv({"RC_SECRET": "hunter2",
        "WAKU_DELEGATE_ENV_DENY": ""}):
      assert runDelegateEnv().hasKey("RC_SECRET")
