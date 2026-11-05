## Lot 3 T3.3 tests: inter-agent edges and message waves share the trace.
## Offline only: pure JSON, no network, no `.waku/` writes.

import std/json
import std/unittest

import ../src/aggregate

suite "lot 3 t3.3 edges and waves":
  test "delegation edge reuses route shape for graph.js":
    let ev = delegationEvent("orchestrator", "brief", "tr1", "tu1",
      "full_agent", "cover loop")
    check ev["workflow"].getStr() == "brief"
    check ev["router"].getStr() == "orchestrator"
    check ev["target"].getStr() == "full_agent"

  test "message wave carries from/to/kind for the live ticker":
    let ev = messageEvent("brief", "orchestrator", "tr1", "tu1", "partial")
    check ev["from"].getStr() == "brief"
    check ev["to"].getStr() == "orchestrator"
    check ev["kind"].getStr() == "partial"
