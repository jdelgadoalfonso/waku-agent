## T1.2 RED: spawn and supervise workers with timeout/kill + fail-open.
## Pure decision plus injected runner; no real sleep or network.

import std/json
import std/unittest

import ../src/delegation
import ../src/supervisor
import ../src/tools

suite "supervisor T1.2":

  test "timeout fails open":
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 50, 8)
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: true, code: 124, stdout: "", stderr: ""),
       pid: 0)
    let outcome = runWorker(@["waku", "--role", "worker"], task, 1, fake)
    assert outcome.timedOut
    assert outcome.shouldFailOpen

  test "non-zero exit fails open":
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 1, stdout: "", stderr: "boom"),
       pid: 0)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert not outcome.timedOut
    assert outcome.shouldFailOpen

  test "malformed-only output fails open":
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0, stdout: "not json\n",
        stderr: ""), pid: 0)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert outcome.malformed == 1
    assert outcome.shouldFailOpen

  test "done line does not fail open":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0, stdout: $doneLine & "\n",
        stderr: ""), pid: 0)
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert not outcome.shouldFailOpen
    assert outcome.childLines.len == 1

  test "observed pid stamps child lines and outcome":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0, stdout: $doneLine & "\n",
        stderr: ""), pid: 4321)
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert not outcome.shouldFailOpen
    assert outcome.pid == 4321
    assert outcome.childLines.len == 1
    assert outcome.childLines[0]["pid"].getInt() == 4321

  test "parent pid wins over child pid":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 111,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0, stdout: $doneLine & "\n",
        stderr: ""), pid: 4321)
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert outcome.childLines[0]["pid"].getInt() == 4321

  test "zero observed keeps child value":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 111,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0, stdout: $doneLine & "\n",
        stderr: ""), pid: 0)
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert outcome.pid == 0
    assert outcome.childLines[0]["pid"].getInt() == 111

  test "timeout keeps observed pid":
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 50, 8)
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: true, code: 124, stdout: "", stderr: ""),
       pid: 4321)
    let outcome = runWorker(@["waku", "--role", "worker"], task, 1, fake)
    assert outcome.timedOut
    assert outcome.shouldFailOpen
    assert outcome.pid == 4321
