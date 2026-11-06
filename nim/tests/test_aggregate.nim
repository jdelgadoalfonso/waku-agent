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

  test "slice 10: cost is a cost kind with the worker identity":
    # The existing mapping already carries a delegated spend line; this
    # pin keeps the identity stamp (agent/pid/ids) on it, so the parent
    # never has to special-case a second shape.
    let child = makeChildLine("cost", "t_1", "t_2", "gather", 12,
        %*{"kind": "gather", "model": "m", "in": 7, "out": 3})
    let (kind, ev) = toTraceEvent(child)
    assert kind == "cost"
    assert ev["agent"].getStr() == "gather"
    assert ev["pid"].getInt() == 12
    assert ev["trace_id"].getStr() == "t_1"
    assert ev["turn_id"].getStr() == "t_2"
    assert ev["in"].getInt() == 7
    assert ev["out"].getInt() == 3

  test "delegation event carries from to route":
    let ev = delegationEvent("orchestrator", "gather", "t_1", "t_2",
        "full", "gather knows the shape")
    assert ev["router"].getStr() == "orchestrator"
    assert ev["target"].getStr() == "full"
