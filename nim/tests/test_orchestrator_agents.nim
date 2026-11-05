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
