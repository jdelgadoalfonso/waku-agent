## Slice 1 RED/GREEN: pure productive-caller helpers stay offline.
## No spawn, no tracer IO, no clock — injected child lines only.

import std/json
import std/unittest

import ../src/aggregate
import ../src/delegate
import ../src/delegation
import ../src/supervisor
import ../src/tools

suite "delegate slice 1":

  test "argv is same binary with worker role and agent":
    assert delegateArgv("waku", "gather") ==
      @["waku", "--role", "worker", "--agent", "gather"]

  test "task line round-trips through parseTaskLine":
    let line = delegateTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    var err = ""
    assert parseTaskLine(line, err)
    assert line["trace_id"].getStr() == "t_1"
    assert line["budget"]["timeout_ms"].getInt() == 30000

  test "timeout seconds never kill before the child votes":
    assert delegateTimeoutSec(30000) == 31
    assert delegateTimeoutSec(30001) == 32
    assert delegateTimeoutSec(0) == 1
    assert delegateTimeoutSec(1000) == 2

  test "reply is the last done payload":
    let lines = @[
      makeChildLine("event", "t_1", "t_2", "gather", 0,
        %*{"kind": "node_end"}),
      makeChildLine("done", "t_1", "t_2", "gather", 4321,
        %*{"reply": "first"}),
      makeChildLine("done", "t_1", "t_2", "gather", 4321,
        %*{"reply": "second"}),
    ]
    assert delegateReply(lines) == "second"
    let res = delegateLoopResult(lines)
    assert res.reply == "second"
    assert res.iterations == 1
    assert res.toolCalls.len == 0

  test "error-only turn answers empty for fail-open":
    let lines = @[makeChildLine("error", "t_1", "t_2", "gather", 0,
      %*{"message": "boom"})]
    assert delegateReply(lines) == ""
    assert delegateLoopResult(lines).reply == ""

  test "trace pairs keep order and stamp identity":
    let lines = @[makeChildLine("done", "t_1", "t_2", "gather", 4321,
      %*{"reply": "ok"})]
    let pairs = delegateTracePairs(lines)
    assert pairs.len == 1
    assert pairs[0].kind == "worker_done"
    assert pairs[0].ev["agent"].getStr() == "gather"
    assert pairs[0].ev["pid"].getInt() == 4321
    assert pairs[0].ev["trace_id"].getStr() == "t_1"

  test "edge is shaped like the engine route event":
    let ev = delegateEdge("orchestrator", "gather", "t_1", "t_2",
      "gather", "nightly")
    assert ev["workflow"].getStr() == "gather"
    assert ev["router"].getStr() == "orchestrator"
    assert ev["target"].getStr() == "gather"

suite "delegate slice 2a":

  test "done answers through the result path and emits pairs":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "delegated reply"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 4321)
    var kinds: seq[string] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather",
      "triage_reason": "morning shape"},
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert ans["reply"].getStr() == "delegated reply"
    assert ans["iterations"].getInt() == 1
    assert "delegation" in kinds
    assert "worker_done" in kinds

  test "timeout fails open with a marker and still emits the edge":
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: true, code: 124, stdout: "",
        stderr: ""), pid: 0)
    var kinds: seq[string] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather"},
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert ans["fail_open"].getBool(false)
    assert kinds == @["delegation"]

  test "error-only exit 0 fails open instead of answering empty":
    let errLine = makeChildLine("error", "t_1", "t_2", "gather", 0,
        %*{"message": "boom"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $errLine & "\n", stderr: ""), pid: 0)
    var kinds: seq[string] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather"},
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert ans["fail_open"].getBool(false)
    assert "worker_error" in kinds

  test "route mismatch never spawns the wrong worker":
    var spawned = false
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      spawned = true
      (res: ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
        pid: 0)
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "brief me", "route": "brief"}, nil)
    assert ans["fail_open"].getBool(false)
    assert not spawned
