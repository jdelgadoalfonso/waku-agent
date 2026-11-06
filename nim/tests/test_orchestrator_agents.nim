## Lot 3 T3.2 tests: agents panel payload from the registry describe.
## Offline only: pure JSON, no network, no `.waku/` writes.

import std/json
import std/unittest

import ../src/dashboard

suite "lot 3 t3.2 agents panel":
  test "no enabled agents reads empty":
    check agentsOverview(@[]) == newJArray()

  test "enabled agent card carries kind loop|graph with live defaults":
    let cards = agentsOverview(@["triage"])
    check cards.len == 1
    check cards[0]["name"].getStr() == "triage"
    check cards[0]["kind"].getStr() == "graph"
    check cards[0]["state"].getStr() == "idle"
    check cards[0]["last_route"].getStr() == ""

  test "live merge overlays pid and state without second parse":
    let rows = agentsOverview(@["triage"])
    let live = %*[
      {"agent": "triage", "cost": 0.02, "last_route": "full",
       "pid": 4321, "state": "running"}
    ]
    let merged = mergeLiveAgents(rows, live)
    check merged[0]["pid"].getInt() == 4321
    check merged[0]["state"].getStr() == "running"
    check merged[0]["cost"].getFloat() == 0.02
    check merged[0]["last_route"].getStr() == "full"

  test "live merge keeps defaults when pid unnamed":
    let rows = agentsOverview(@["triage"])
    let live = %*[
      {"agent": "triage", "cost": 0.0, "last_route": "",
       "pid": newJNull(), "state": "running"}
    ]
    let merged = mergeLiveAgents(rows, live)
    check merged[0]["pid"].kind == JNull
    check merged[0]["state"].getStr() == "running"
