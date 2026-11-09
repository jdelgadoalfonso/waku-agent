## Slice 1 RED/GREEN: pure productive-caller helpers stay offline.
## No spawn, no tracer IO, no clock — injected child lines only.

import std/json
import std/strutils
import std/unittest

import ../src/aggregate
import ../src/delegate
import ../src/delegation
import ../src/supervisor
import ../src/tools
import ../src/triage

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

  test "slice 10: a cost child rides the trace pairs before done":
    let lines = @[
      makeChildLine("cost", "t_1", "t_2", "gather", 0,
        %*{"kind": "gather", "model": "m", "in": 7, "out": 3}),
      makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "ok"}),
    ]
    let pairs = delegateTracePairs(lines)
    assert pairs.len == 2
    assert pairs[0].kind == "cost"
    assert pairs[0].ev["agent"].getStr() == "gather"
    assert pairs[0].ev["trace_id"].getStr() == "t_1"
    assert pairs[0].ev["turn_id"].getStr() == "t_2"
    assert pairs[1].kind == "worker_done"

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

  test "slice 10: a worker cost line reaches the observer before done":
    # End to end through the binder: the parent re-emits the child's
    # cost line with the observed pid and the worker identity, in
    # order, so the tracer (and the dashboard) see it on the turn.
    let costLine = makeChildLine("cost", "t_1", "t_2", "gather", 0,
        %*{"kind": "gather", "model": "m", "in": 7, "out": 3})
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "delegated reply"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $costLine & "\n" & $doneLine & "\n", stderr: ""), pid: 4321)
    var seen: seq[tuple[kind: string, ev: JsonNode]] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    discard fn(%*{"message": "gather news", "route": "gather"},
      proc(kind: string, ev: JsonNode) = seen.add((kind, copy(ev))))
    assert seen.len == 3
    assert seen[0].kind == "delegation"
    assert seen[1].kind == "cost"
    assert seen[1].ev["agent"].getStr() == "gather"
    assert seen[1].ev["pid"].getInt() == 4321
    assert seen[1].ev["trace_id"].getStr() == "t_1"
    assert seen[1].ev["in"].getInt() == 7
    assert seen[2].kind == "worker_done"

  test "timeout fails open with a marker and still emits the edge":
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: true, code: 124, stdout: "",
        stderr: ""), pid: 0)
    var seen: seq[tuple[kind: string, ev: JsonNode]] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather"},
      proc(kind: string, ev: JsonNode) = seen.add((kind, copy(ev))))
    assert ans["fail_open"].getBool(false)
    assert seen.len == 2
    assert seen[0].kind == "delegation"
    assert seen[1].kind == "delegation_error"
    assert seen[1].ev["error"].getStr() == "worker timed out"

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

  test "done without reply fails open":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert ans["fail_open"].getBool(false)

  test "whitespace-only reply fails open":
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "   "})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert ans["fail_open"].getBool(false)

suite "delegate slice 2b":

  test "workerRole reads the argv delegateArgv builds":
    let (isWorker, agent) = workerRole(delegateArgv("waku", "gather"))
    assert isWorker
    assert agent == "gather"

  test "workerRole reads the child's own commandLineParams":
    # Inside the child there is no argv[0]: the same flags arrive through
    # `commandLineParams`, so the scan never assumes a position.
    assert workerRole(@["--role", "worker", "--agent", "gather"]) ==
      (isWorker: true, agent: "gather")
    assert workerRole(@["--role", "worker"]) == (isWorker: true, agent: "")
    assert workerRole(@["chat"]) == (isWorker: false, agent: "")

  test "workerRole keeps the last role it reads":
    assert not workerRole(@["--role", "worker", "--role", "chat"]).isWorker
    assert workerRole(@["--role", "chat", "--role", "worker"]).isWorker

  test "T3: workerAgents keeps enabled agents with a worker":
    # `brief` (T3) is the second agent with a real worker: unknown names
    # stay out, order is kept, duplicates collapse.
    assert workerAgents(@[]) == @[]
    assert workerAgents(@["nope"]) == @[]
    assert workerAgents(@["brief", "gather", "gather"]) == @["brief",
      "gather"]

  test "no enabled worker means no delegate seam":
    let noSpawn: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      raise newException(CatchableError, "must not spawn")
    let ids = proc(): string = "t_1"
    assert liveDelegateFor(@[], "waku", ids, noSpawn).isNil
    assert liveDelegateFor(@["nope"], "waku", ids, noSpawn).isNil
    assert not liveDelegateFor(@["brief"], "waku", ids,
      noSpawn).isNil

  test "liveDelegateFor binds one agent and its guard still refuses others":
    var argvSeen: seq[seq[string]] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "delegated"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      argvSeen.add(argv)
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 7)
    let fn = liveDelegateFor(@["gather"], "waku", proc(): string = "t_1",
      fake)
    assert not fn.isNil
    let refused = fn(%*{"message": "brief me", "route": "brief"}, nil)
    assert refused["fail_open"].getBool(false)
    assert argvSeen.len == 0
    let ans = fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert ans["reply"].getStr() == "delegated"
    assert argvSeen[0] == @["waku", "--role", "worker", "--agent", "gather"]

  test "live fn reads the trace id per call and mints a turn id per call":
    var traceId = "t_turn_one"
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "", "", "gather", 0,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = makeLiveDelegateFn("gather", "waku", proc(): string = traceId,
      fake)
    discard fn(%*{"message": "one", "route": "gather"}, nil)
    traceId = "t_turn_two"
    discard fn(%*{"message": "two", "route": "gather"}, nil)
    assert tasks.len == 2
    assert tasks[0]["trace_id"].getStr() == "t_turn_one"
    assert tasks[1]["trace_id"].getStr() == "t_turn_two"
    for task in tasks:
      let turnId = task["turn_id"].getStr()
      assert turnId.startsWith("t_")
      assert turnId.len == 18
    assert tasks[0]["turn_id"].getStr() != tasks[1]["turn_id"].getStr()

  test "a missing trace id reader answers an empty id, never crashes":
    let doneLine = makeChildLine("done", "t_x", "t_y", "gather", 0,
        %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = makeLiveDelegateFn("gather", "waku", nil, fake)
    assert fn(%*{"message": "x", "route": "gather"}, nil)["reply"].getStr() ==
      "ok"

## T19 (S1,S2): the child line names the worker's model. Empty is the
## default and means "inherit the parent's model", so the line stays byte
## for byte what it was — an override is opt-in on the wire, never a new
## shape an old worker would choke on.

suite "delegate T19 worker model override":

  test "the task line carries a model only when one is asked for":
    let plain = delegateTaskLine("t_1", "t_2", "gather news", "", 30000, 8)
    assert not plain.hasKey("model")
    let asked = delegateTaskLine("t_1", "t_2", "gather news", "", 30000, 8,
      model = "worker-model")
    assert asked["model"].getStr() == "worker-model"
    var err = ""
    assert parseTaskLine(asked, err)  # the override never breaks the wire

  test "the binder puts the override on the child line it spawns":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake,
      model = "worker-model")
    discard fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 1
    assert tasks[0]["model"].getStr() == "worker-model"

  test "no override keeps the line free of a model key":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    discard fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 1
    assert not tasks[0].hasKey("model")

  test "the live seam forwards the override to every worker it holds":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let fn = liveDelegateFor(@["gather"], "waku", proc(): string = "t_1",
      fake, model = "worker-model")
    discard fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 1
    assert tasks[0]["model"].getStr() == "worker-model"

  test "one ledger row per delegated call, and it names the override":
    # T19 adds a name, not a charge: the override rides the same single
    # `cost` line L27 pinned, so the parent's mapping still yields one
    # cost pair and the tracer still books one row for it.
    let lines = @[
      makeChildLine("cost", "t_1", "t_2", "gather", 0,
        %*{"kind": "gather", "model": "worker-model", "in": 7,
           "out": 3}),
      makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "ok"}),
    ]
    let pairs = delegateTracePairs(lines)
    var costs = 0
    for pair in pairs:
      if pair.kind == "cost":
        inc costs
        assert pair.ev["model"].getStr() == "worker-model"
    assert costs == 1

suite "delegate error visibility":
  test "a failing worker notifies delegation_error with the reason":
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      (res: ProcResult(timedOut: false, code: 1, stdout: "",
        stderr: "boom"), pid: 0)
    var seen: seq[tuple[kind: string, ev: JsonNode]] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "gather"},
      proc(kind: string, ev: JsonNode) = seen.add((kind, copy(ev))))
    assert ans.hasKey("fail_open")
    assert seen.len == 2
    assert seen[0].kind == "delegation"
    assert seen[1].kind == "delegation_error"
    assert seen[1].ev["agent"].getStr() == "gather"
    assert seen[1].ev["turn_id"].getStr() == "t_2"
    assert seen[1].ev["error"].getStr() == "worker exit code 1"

  test "a route mismatch stays silent: no edge, no error":
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      assert false, "must never spawn"
      (res: ProcResult(timedOut: false, code: 1, stdout: "",
        stderr: ""), pid: 0)
    var kinds: seq[string] = @[]
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    let ans = fn(%*{"message": "gather news", "route": "brief"},
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert ans.hasKey("fail_open")
    assert kinds.len == 0

## T17 (S1,S2): one `DelegateFn` in front of N agents. The dispatcher is
## the mechanism `liveDelegateFor` builds, pinned here with fake delegates
## so no second productive worker exists: each route reaches its own
## closure, and a route nothing owns fails open without spawning.

suite "delegate T17 multi-agent dispatcher":

  test "the dispatcher answers through the delegate its route names":
    var ran: seq[string] = @[]
    let gather: DelegateFn = proc(s: JsonNode, n: Observer): JsonNode =
      ran.add("gather")
      %*{"reply": "digest", "tool_calls": [], "iterations": 1}
    let brief: DelegateFn = proc(s: JsonNode, n: Observer): JsonNode =
      ran.add("brief")
      %*{"reply": "briefing", "tool_calls": [], "iterations": 1}
    let dispatch = makeDelegateDispatcher(@[(agent: "gather", fn: gather),
                                            (agent: "brief", fn: brief)])
    assert dispatch(%*{"message": "x", "route": "brief"},
      nil)["reply"].getStr() == "briefing"
    assert dispatch(%*{"message": "x", "route": "gather"},
      nil)["reply"].getStr() == "digest"
    assert ran == @["brief", "gather"]

  test "a route with no delegate fails open instead of guessing":
    var ran: seq[string] = @[]
    let gather: DelegateFn = proc(s: JsonNode, n: Observer): JsonNode =
      ran.add("gather")
      %*{"reply": "digest", "tool_calls": [], "iterations": 1}
    for missing in [%*{"message": "x", "route": "brief"},
                    %*{"message": "x"}]:
      let ans = makeDelegateDispatcher(@[(agent: "gather", fn: gather)])(
        missing, nil)
      assert ans["fail_open"].getBool(false)
    assert ran.len == 0

  test "a nil delegate in the table is skipped, never called":
    let gather: DelegateFn = proc(s: JsonNode, n: Observer): JsonNode =
      %*{"reply": "digest", "tool_calls": [], "iterations": 1}
    let dispatch = makeDelegateDispatcher(@[(agent: "brief", fn: nil),
                                            (agent: "gather", fn: gather)])
    assert dispatch(%*{"message": "x", "route": "brief"},
      nil)["fail_open"].getBool(false)
    assert dispatch(%*{"message": "x", "route": "gather"},
      nil)["reply"].getStr() == "digest"

  test "T3: the worker list holds gather and brief":
    # T17 is the dispatch mechanism, not a worker — but every name here
    # needs a real `--role worker` half, or the gate would offer a route
    # that cannot answer. `brief` (T3) is the second such half.
    assert delegateWorkers == @["gather", "brief"]
    assert workerAgents(@["brief", "gather", "nope"]) == @["brief",
      "gather"]

## T21-D (S10): read-only memory via `context`. The orchestrator fills the
## task line from gated retrieval, truncated and marked; the worker reads
## it as `mem_text` without opening a store. Empty keeps today.

suite "delegate T21-D memory context":

  test "truncateContext keeps short text and marks long text":
    assert truncateContext("short") == "short"
    assert truncateContext("") == ""
    let longText = "m".repeat(delegateMaxContextChars + 10)
    let cut = truncateContext(longText)
    assert cut.len == delegateMaxContextChars + "\n[truncated]".len
    assert cut.endsWith("[truncated]")
    assert cut.startsWith("m".repeat(10))

  test "the binder puts truncated retrieval on the child line it spawns":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let ctx: ContextFn = proc(msg: string): string = "memory for " & msg
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake,
      contextFn = ctx)
    discard fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 1
    assert tasks[0]["context"].getStr() == "memory for gather news"

  test "a long retrieval truncates on the wire with its mark":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let ctx: ContextFn = proc(msg: string): string =
      "m".repeat(delegateMaxContextChars + 5)
    let fn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake,
      contextFn = ctx)
    discard fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 1
    let sent = tasks[0]["context"].getStr()
    assert sent.endsWith("[truncated]")
    assert sent.len == delegateMaxContextChars + "\n[truncated]".len

  test "empty retrieval sends empty context and no fn keeps today":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let emptyCtx: ContextFn = proc(msg: string): string = ""
    let withEmpty = makeDelegateFn("gather", "waku", "t_1", "t_2", fake,
      contextFn = emptyCtx)
    discard withEmpty(%*{"message": "gather news", "route": "gather"}, nil)
    let withoutFn = makeDelegateFn("gather", "waku", "t_1", "t_2", fake)
    discard withoutFn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 2
    assert tasks[0]["context"].getStr() == ""
    assert tasks[1]["context"].getStr() == ""

  test "the live seam forwards the context fn to the wire":
    var tasks: seq[JsonNode] = @[]
    let doneLine = makeChildLine("done", "t_1", "t_2", "gather", 0,
      %*{"reply": "ok"})
    let fake: WorkerRunner = proc(argv: seq[string], stdinText: string,
        timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.} =
      tasks.add(parseJson(stdinText))
      (res: ProcResult(timedOut: false, code: 0,
        stdout: $doneLine & "\n", stderr: ""), pid: 0)
    let ctx: ContextFn = proc(msg: string): string = "ctx for " & msg
    let fn = liveDelegateFor(@["gather"], "waku", proc(): string = "t_1",
      fake, contextFn = ctx)
    discard fn(%*{"message": "gather news", "route": "gather"}, nil)
    assert tasks.len == 1
    assert tasks[0]["context"].getStr() == "ctx for gather news"
