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
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: true, code: 124, stdout: "", stderr: "")
    let outcome = runWorker(@["waku", "--role", "worker"], task, 1, fake)
    assert outcome.timedOut
    assert outcome.shouldFailOpen

  test "non-zero exit fails open":
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 1, stdout: "", stderr: "boom")
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert not outcome.timedOut
    assert outcome.shouldFailOpen

  test "malformed-only output fails open":
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "not json\n",
        stderr: "")
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert outcome.malformed == 1
    assert outcome.shouldFailOpen

  test "done line does not fail open":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: $doneLine & "\n",
        stderr: "")
    let task = makeTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    let outcome = runWorker(@["waku"], task, 20, fake)
    assert not outcome.shouldFailOpen
    assert outcome.childLines.len == 1
