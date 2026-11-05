## Lot 3 T3.4 tests: per-agent observability aggregates from the same trace.
## Offline only: pure JSON in temp homes, no network, no `.waku/` writes.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/observability

suite "lot 3 t3.4 per-agent observability":
  test "empty trace reads no agents":
    check agentsSummary(@[]) == newJArray()

  test "worker rows aggregate per agent with cost and last route":
    let events = @[
      %*{"type": "delegation", "workflow": "brief",
         "router": "orchestrator", "target": "full_agent",
         "agent": "brief", "trace_id": "tr1", "turn_id": "tu1"},
      %*{"type": "worker_done", "agent": "brief",
         "trace_id": "tr1", "turn_id": "tu1",
         "route": "full_agent", "reason": "cover loop",
         "path": ["full_agent"], "cost": 0.01}
    ]
    let rows = agentsSummary(events)
    check rows.len == 1
    check rows[0]["agent"].getStr() == "brief"
    check rows[0]["last_route"].getStr() == "full_agent"

  test "cost sums every event and turns count distinct turn ids":
    let events = @[
      %*{"type": "cost", "agent": "gather", "turn_id": "tu1",
         "cost": 0.25},
      %*{"type": "cost", "agent": "gather", "turn_id": "tu1",
         "cost_usd": 0.75},
      %*{"type": "cost", "agent": "gather", "turn_id": "tu2",
         "cost_usd": 1, "cost": "free"},
      # Both keys numeric name ONE charge: counted once, never twice.
      %*{"type": "cost", "agent": "gather", "turn_id": "tu2",
         "cost": 0.5, "cost_usd": 0.5}
    ]
    let rows = agentsSummary(events)
    check rows.len == 1
    check rows[0]["turns"].getInt() == 2
    check rows[0]["cost"].getFloat() == 2.5

  test "a message names the worker end, never the orchestrator":
    let events = @[
      %*{"type": "message", "from": "gather", "to": "orchestrator",
         "turn_id": "tu1", "kind": "partial"},
      %*{"type": "message", "from": "orchestrator", "to": "brief",
         "turn_id": "tu1", "kind": "task"}
    ]
    let rows = agentsSummary(events)
    check rows.len == 2
    check rows[0]["agent"].getStr() == "gather"
    check rows[1]["agent"].getStr() == "brief"

  test "plumbing and unnamed shapes earn no row":
    let events = @[
      %*{"type": "turn_start", "turn_id": "tu1"},
      %*{"type": "llm", "turn_id": "tu1"},
      %*{"type": "worker_done", "turn_id": "tu1"},
      newJNull()
    ]
    check agentsSummary(events) == newJArray()

  test "any stamped worker kind counts, not only worker_done":
    let events = @[
      %*{"type": "node_end", "agent": "gather", "turn_id": "tu1",
         "route": "quick"}
    ]
    let rows = agentsSummary(events)
    check rows.len == 1
    check rows[0]["agent"].getStr() == "gather"
    check rows[0]["turns"].getInt() == 1
    check rows[0]["last_route"].getStr() == "quick"

  test "the payload carries the rows and loses no key it served":
    let home = getTempDir() / "obs-t34-payload"
    if dirExists(home):
      removeDir(home)
    createDir(home / "traces")
    writeFile(home / "traces" / "2026-10-05.jsonl", @[
      $(%*{"type": "delegation", "workflow": "brief",
           "router": "orchestrator", "target": "full_agent",
           "turn_id": "tu1", "ts": "2026-10-05T10:00:00.000+00:00"}),
      $(%*{"type": "worker_done", "agent": "brief", "turn_id": "tu1",
           "route": "full_agent", "cost": 0.02,
           "ts": "2026-10-05T10:00:01.000+00:00"})
    ].join("\n") & "\n")
    let p = payload(home, "p", "m", "7d", 1760000000000'i64)
    check p["agents"].len == 1
    check p["agents"][0]["agent"].getStr() == "brief"
    check p["agents"][0]["turns"].getInt() == 1
    check p["agents"][0]["last_route"].getStr() == "full_agent"
    check p["agents"][0]["cost"].getFloat() == 0.02
    # Additive: every key the page already read is still served.
    for key in ["generated_at", "summary", "spend_by_day", "turns",
        "tools", "memory", "spend", "evals"]:
      check p.hasKey(key)
    removeDir(home)
