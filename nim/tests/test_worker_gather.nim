## T1.4 RED: gather as a headless worker turn.

import std/json
import std/unittest

import ../src/delegation
import ../src/worker_gather

suite "worker gather T1.4":

  test "valid task runs gather and emits done":
    let task = makeTaskLine("t_1", "t_2", "morning briefing", "", 30000, 8)
    let fake: GatherFn = proc(): JsonNode {.closure.} =
      %*{"digest": "briefing ok", "draft_path": "outbox/brief.md"}
    let lines = runGatherWorker(task, fake)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "event"
    assert lines[1]["type"].getStr() == "done"

  test "slice 10: the synth usage rides one cost line before done":
    # The worker's own tracer is silent, so the orchestrator can only
    # learn what the gather synthesis cost from this line. It must carry
    # the task's ids (the parent stamps the observed pid on receipt).
    let task = makeTaskLine("t_1", "t_2", "morning briefing", "", 30000, 8)
    let fake: GatherFn = proc(): JsonNode {.closure.} =
      %*{"digest": "briefing ok", "draft_path": "",
         "usage": {"kind": "gather", "model": "m", "in": 7, "out": 3}}
    let lines = runGatherWorker(task, fake)
    assert lines.len == 3
    assert lines[0]["type"].getStr() == "event"
    assert lines[1]["type"].getStr() == "cost"
    assert lines[1]["trace_id"].getStr() == "t_1"
    assert lines[1]["turn_id"].getStr() == "t_2"
    assert lines[1]["agent"].getStr() == "gather"
    assert lines[1]["payload"]["in"].getInt() == 7
    assert lines[1]["payload"]["out"].getInt() == 3
    assert lines[1]["payload"]["model"].getStr() == "m"
    assert lines[1]["payload"]["kind"].getStr() == "gather"
    assert lines[2]["type"].getStr() == "done"

  test "slice 10: no synth usage means no cost line":
    # A gather that never reported a usage (an injected fake, a run that
    # failed before the model call) must not invent a charge.
    let task = makeTaskLine("t_1", "t_2", "morning briefing", "", 30000, 8)
    let fake: GatherFn = proc(): JsonNode {.closure.} =
      %*{"digest": "briefing ok", "draft_path": ""}
    let lines = runGatherWorker(task, fake)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "event"
    assert lines[1]["type"].getStr() == "done"

  test "T19: the task's model override wins in the cost payload":
    # The parent names the model the worker must run on; the ledger
    # prices what the cost payload says, so the payload says the
    # override even when the gather state reports the app's own model.
    var task = makeTaskLine("t_1", "t_2", "morning briefing", "", 30000, 8)
    task["model"] = %"worker-model"
    var state = %*{"digest": "briefing ok", "draft_path": "",
      "usage": {"kind": "gather", "model": "parent-model", "in": 7,
                "out": 3}}
    let fake: GatherFn = proc(): JsonNode {.closure.} = state
    let lines = runGatherWorker(task, fake)
    assert lines.len == 3
    assert lines[1]["type"].getStr() == "cost"
    assert lines[1]["payload"]["model"].getStr() == "worker-model"
    assert lines[1]["payload"]["in"].getInt() == 7
    # the gather's own state is read, never rewritten
    assert state["usage"]["model"].getStr() == "parent-model"

  test "T19: no override keeps the model the gather reported":
    let task = makeTaskLine("t_1", "t_2", "morning briefing", "", 30000, 8)
    let fake: GatherFn = proc(): JsonNode {.closure.} =
      %*{"digest": "briefing ok", "draft_path": "",
         "usage": {"kind": "gather", "model": "parent-model", "in": 7,
                   "out": 3}}
    let lines = runGatherWorker(task, fake)
    assert lines[1]["payload"]["model"].getStr() == "parent-model"

  test "T19: taskLineModel reads the line, inherit otherwise":
    # The worker end of `delegateTaskLine`'s optional `model` key. A
    # hint it cannot read is no hint: inherit is always the safe answer,
    # and `workerChildLines` still answers the structural errors.
    assert taskLineModel("""{"v":1,"model":"worker-model"}""") ==
      "worker-model"
    assert taskLineModel("""{"v":1}""") == ""
    assert taskLineModel("not json") == ""
    assert taskLineModel("""{"model":7}""") == ""
    assert taskLineModel("""{"model":"  "}""") == ""

  test "invalid task emits a single error line":
    let fake: GatherFn = proc(): JsonNode {.closure.} =
      %*{"digest": "unreachable"}
    let lines = runGatherWorker(%*{"v": 1}, fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"

  test "gather exception emits error not raise":
    let task = makeTaskLine("t_1", "t_2", "morning briefing", "", 30000, 8)
    let fake: GatherFn = proc(): JsonNode {.closure.} =
      raise newException(CatchableError, "scan boom")
    let lines = runGatherWorker(task, fake)
    assert lines[^1]["type"].getStr() == "error"

## T21-D (S10): the worker reads `context` without opening a store.
## A hint it cannot read is no hint: missing, non-string, unreadable,
## and blank all mean inherit (empty), and `workerChildLines` still
## answers the structural errors.

suite "worker gather T21-D memory context":

  test "taskLineContext reads the line, inherit otherwise":
    assert taskLineContext("{\"v\":1,\"context\":\"memory here\"}") ==
      "memory here"
    assert taskLineContext("{\"v\":1}") == ""
    assert taskLineContext("not json") == ""
    assert taskLineContext("{\"context\":7}") == ""
    assert taskLineContext("{\"context\":\"  \"}") == ""

  test "taskContext mirrors taskLineContext over a parsed line":
    assert taskContext(%*{"context": "memory here"}) == "memory here"
    assert taskContext(%*{"v": 1}) == ""
    assert taskContext(%*{"context": 7}) == ""
