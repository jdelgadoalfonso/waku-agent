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
