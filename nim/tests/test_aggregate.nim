## T1.3 RED: single-writer aggregation of worker child lines.

import std/json
import std/unittest

import ../src/aggregate
import ../src/delegation

suite "aggregate T1.3":

  test "event child stamps agent and trace ids":
    let child = makeChildLine("event", "t_1", "t_2", "gather", 12,
        %*{"kind": "node_end", "node": "fetch"})
    let (kind, ev) = toTraceEvent(child)
    assert kind == "node_end"
    assert ev["agent"].getStr() == "gather"
    assert ev["trace_id"].getStr() == "t_1"

  test "done and error map to worker kinds":
    let doneChild = makeChildLine("done", "t_1", "t_2", "gather", 0,
        %*{"reply": "ok"})
    let (k1, _) = toTraceEvent(doneChild)
    assert k1 == "worker_done"
    let errChild = makeChildLine("error", "t_1", "t_2", "gather", 0,
        %*{"message": "boom"})
    let (k2, _) = toTraceEvent(errChild)
    assert k2 == "worker_error"

  test "delegation event carries from to route":
    let ev = delegationEvent("orchestrator", "gather", "t_1", "t_2",
        "full", "gather knows the shape")
    assert ev["router"].getStr() == "orchestrator"
    assert ev["target"].getStr() == "full"
