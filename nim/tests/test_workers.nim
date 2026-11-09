## T2 RED: the worker side dispatches through a table, not a branch.
## `gather` is the first entry; anything the table does not name answers
## one `error` line and never runs. Pure and offline: injected fakes only.

import std/json
import std/strutils
import std/unittest

import ../src/delegation
import ../src/worker_gather
import ../src/delegate
import ../src/worker_brief
import ../src/workers

suite "T2 worker table":

  test "the table holds gather and answers through its body":
    let task = makeTaskLine("t_a", "t_b", "gather news", "", 1000, 1)
    let fake: GatherFn = proc(): JsonNode = %*{"digest": "five things",
      "draft_path": "/tmp/draft.md"}
    let table = workerTable(fake)
    assert table.len == 1
    assert table[0].agent == "gather"
    let lines = runWorkerLines("gather", $task, table)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "event"
    assert lines[1]["type"].getStr() == "done"
    assert lines[1]["payload"]["reply"].getStr() == "five things"

  test "a route the table does not name answers one error line":
    let task = makeTaskLine("t_a", "t_b", "brief me", "", 1000, 1)
    let fake: GatherFn = proc(): JsonNode =
      assert false, "must never run the wrong worker"
      newJObject()
    let lines = runWorkerLines("brief", $task, workerTable(fake))
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    assert "no worker" in lines[0]["payload"]["message"].getStr()

  test "the lookup decides, not the agent name":
    # The same task answers when the table names its agent: the branch
    # on `gather` is gone, only the table speaks.
    let task = makeTaskLine("t_a", "t_b", "hello", "", 1000, 1)
    let fake: GatherFn = proc(): JsonNode = %*{"digest": "hi",
      "draft_path": ""}
    let other: WorkerBody = proc(t: JsonNode): seq[JsonNode] =
      runGatherWorker(t, fake)
    let lines = runWorkerLines("other", $task, @[(agent: "other",
      body: other)])
    assert lines.len == 2
    assert lines[1]["payload"]["reply"].getStr() == "hi"

  test "an unreadable line answers one error line, never a raise":
    let fake: GatherFn = proc(): JsonNode = newJObject()
    let lines = runWorkerLines("gather", "not json", workerTable(fake))
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"

## T3 RED: `brief` is the second entry. Same child-line shape as gather
## (event, done — no cost without a reported usage), headless by the
## slice-9 rules: no outbox file, no store, silent tracer.

suite "T3 brief worker":

  test "the table holds brief beside gather":
    let gatherFake: GatherFn = proc(): JsonNode = newJObject()
    let briefFake: BriefFn = proc(): JsonNode = %*{"reply": "x",
      "draft_path": ""}
    let table = workerTable(gatherFake, briefFake)
    assert table.len == 2
    assert table[0].agent == "gather"
    assert table[1].agent == "brief"

  test "a gather-only table still answers brief with no worker":
    let gatherFake: GatherFn = proc(): JsonNode = newJObject()
    let lines = runWorkerLines("brief", "{\"v\":1}",
      workerTable(gatherFake))
    assert lines.len == 1
    assert "no worker" in lines[0]["payload"]["message"].getStr()

  test "a valid brief task answers event then done with the reply":
    let task = makeTaskLine("t_a", "t_b", "brief me", "", 1000, 1)
    let fake: BriefFn = proc(): JsonNode = %*{"reply": "week ahead",
      "draft_path": ""}
    let lines = runBriefWorker(task, fake)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "event"
    assert lines[0]["agent"].getStr() == "brief"
    assert lines[1]["type"].getStr() == "done"
    assert lines[1]["payload"]["reply"].getStr() == "week ahead"
    assert lines[1]["trace_id"].getStr() == "t_a"
    assert lines[1]["turn_id"].getStr() == "t_b"

  test "a brief table entry answers through the lookup":
    let task = makeTaskLine("t_a", "t_b", "brief me", "", 1000, 1)
    let gatherFake: GatherFn = proc(): JsonNode =
      assert false, "must never run the wrong worker"
      newJObject()
    let briefFake: BriefFn = proc(): JsonNode = %*{"reply": "week ahead",
      "draft_path": ""}
    let lines = runWorkerLines("brief", $task,
      workerTable(gatherFake, briefFake))
    assert lines.len == 2
    assert lines[1]["payload"]["reply"].getStr() == "week ahead"

  test "brief failure answers error, never raises":
    let task = makeTaskLine("t_a", "t_b", "brief me", "", 1000, 1)
    let fake: BriefFn = proc(): JsonNode =
      raise newException(CatchableError, "loop boom")
    let lines = runBriefWorker(task, fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"

  test "an invalid brief task answers one error line":
    let fake: BriefFn = proc(): JsonNode = %*{"reply": "unreachable",
      "draft_path": ""}
    let lines = runBriefWorker(%*{"v": 9}, fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"

  test "the table and the gate name the same workers":
    # Two lists, one truth: the gate offers a route only behind a real
    # worker, and the table runs only what the gate may offer. A name
    # on one side and not the other fails here, not in production.
    let gatherFake: GatherFn = proc(): JsonNode = newJObject()
    let briefFake: BriefFn = proc(): JsonNode = newJObject()
    var names: seq[string] = @[]
    for entry in workerTable(gatherFake, briefFake):
      names.add(entry.agent)
    assert names == delegateWorkers
