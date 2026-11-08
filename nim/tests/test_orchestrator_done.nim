## Lot 4 T4.1 tests: SSE done agents per delegation.
## Offline only: pure JSON, no network, no `.waku/` writes.

import std/json
import std/unittest

import ../src/aggregate

suite "lot 4 sse done agents per delegation":
  test "no delegations reads empty":
    check doneAgents(@[], @[]) == newJArray()

  test "delegation plus worker completion keeps route reason path cost":
    let ds = @[%*{"workflow": "brief", "router": "orchestrator",
      "target": "full_agent", "trace_id": "tr1", "turn_id": "tu1",
      "reason": "cover loop"}]
    let cs = @[%*{"agent": "brief", "trace_id": "tr1", "turn_id": "tu1",
      "route": "full_agent", "reason": "cover loop",
      "path": ["full_agent"], "cost": 0.02}]
    let rows = doneAgents(ds, cs)
    check rows.len == 1
    check rows[0]["agent"].getStr() == "brief"
    check rows[0]["route"].getStr() == "full_agent"
    check rows[0]["reason"].getStr() == "cover loop"
    check rows[0]["path"].len == 1
    check rows[0]["cost"].getFloat() == 0.02

  test "worker cost line fills the delegation row, worker_done carries none":
    let ds = @[%*{"workflow": "brief", "router": "orchestrator",
      "target": "full_agent", "trace_id": "tr1", "turn_id": "tu1",
      "reason": "cover loop"}]
    let cs = @[%*{"agent": "brief", "trace_id": "tr1", "turn_id": "tu1",
      "route": "full_agent", "reason": "cover loop",
      "path": ["full_agent"]}]
    let costs = @[%*{"agent": "brief", "trace_id": "tr1", "turn_id": "tu1",
      "cost_usd": 0.02}]
    let rows = doneAgents(ds, cs, costs)
    check rows.len == 1
    check rows[0]["cost"].getFloat() == 0.02

  test "completion dollars win, the cost line never double counts":
    let ds = @[%*{"workflow": "brief", "router": "orchestrator",
      "target": "full_agent", "trace_id": "tr1", "turn_id": "tu1",
      "reason": "cover loop"}]
    let cs = @[%*{"agent": "brief", "trace_id": "tr1", "turn_id": "tu1",
      "route": "full_agent", "reason": "cover loop",
      "path": ["full_agent"], "cost": 0.05}]
    let costs = @[%*{"agent": "brief", "trace_id": "tr1", "turn_id": "tu1",
      "cost_usd": 0.02}]
    let rows = doneAgents(ds, cs, costs)
    check rows.len == 1
    check rows[0]["cost"].getFloat() == 0.05
