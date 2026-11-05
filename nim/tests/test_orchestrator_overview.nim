## Lot 3 T3.1 tests: Overview dual mode from the last turn's graph.route.
## Offline only: pure JSON, no network, no `.waku/` writes.

import std/json
import std/unittest

import ../src/dashboard

suite "lot 3 t3.1 overview dual mode":
  test "no turns shows the harness loop":
    check overviewMode(newJArray()) == "loop"

  test "loop turn without graph route shows the harness loop":
    let turns = %*[{"user_message": "hi", "graph": newJNull()}]
    check overviewMode(turns) == "loop"

  test "graph-plugin turn with a route shows the graph panel":
    let turns = %*[{"user_message": "hi",
      "graph": {"workflow": "triage", "route": "full", "reason": ""}}]
    check overviewMode(turns) == "graph"
