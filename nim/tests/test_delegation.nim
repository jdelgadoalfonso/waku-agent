## T1.1 pins: the parent <-> worker stdio contract is pure and offline.
## Task lines carry trace/turn/budget; child lines carry a known type,
## trace/turn/agent/pid/object payload. Malformed rows are rejected
## with a named reason, never stored half-drawn.

import std/json
import std/unittest

import ../src/delegation

suite "delegation contract T1.1":

  test "task line round-trips with budget":
    let line = makeTaskLine("t_abc", "t_def", "gather news", "ctx",
        30000, 8)
    var err = ""
    assert parseTaskLine(line, err)
    assert err == ""
    assert line["budget"]["timeout_ms"].getInt() == 30000
    assert line["budget"]["max_tool_calls"].getInt() == 8

  test "task line rejects missing trace, turn, budget":
    var err = ""
    assert not parseTaskLine(%*{"v": 1}, err)
    assert err.len > 0
    assert not parseTaskLine(
        %*{"v": 1, "trace_id": "t_1", "turn_id": "t_2", "task": "x"}, err)

  test "child line round-trips, non-object payload becomes {}":
    let line = makeChildLine("event", "t_abc", "t_def", "gather", 0,
        %*{"route": "full"})
    var err = ""
    assert parseChildLine(line, err)
    assert err == ""
    let coerced = makeChildLine("text", "t_abc", "t_def", "gather", 0,
        newJString("nope"))
    assert coerced["payload"].kind == JObject

  test "child line rejects unknown type and missing agent":
    var err = ""
    assert not parseChildLine(%*{"v": 1, "type": "wave", "trace_id": "t_1",
        "turn_id": "t_2", "agent": "gather", "pid": 0, "payload": {}}, err)
    assert err == "unknown type"
    assert not parseChildLine(%*{"v": 1, "type": "done", "trace_id": "t_1",
        "turn_id": "t_2", "agent": "", "pid": 0, "payload": {}}, err)

  test "only the five child types pass":
    for kind in ["text", "event", "cost", "done", "error"]:
      assert isKnownChildType(kind)
    assert not isKnownChildType("route")
    assert not isKnownChildType("")
