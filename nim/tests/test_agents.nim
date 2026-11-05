## T2.1 RED: agent enrollment API beside the graph registry.
## Pure and offline: cards declare what the orchestrator matches on.

import std/json
import std/unittest

import ../src/graph/agents
import ../src/wire

suite "agents T2.1":

  test "builtins enroll as loop and graph kinds":
    assert agentKind("triage") == "graph"
    assert agentKind("gather") == "graph"

  test "enroll stores a card, replace-by-name wins":
    enrollAgent(%*{"name": "brief", "kind": "loop",
      "when_to_use": "morning routine", "inputs": ["none"],
      "cost": "low", "effects": "reads-only"})
    enrollAgent(%*{"name": "brief", "kind": "loop",
      "when_to_use": "morning routine v2", "inputs": ["none"],
      "cost": "low", "effects": "reads-only"})
    assert agentCard("brief").jget("when_to_use").getStr() ==
      "morning routine v2"

  test "nameless or non-object cards are ignored":
    let before = agentNames().len
    enrollAgent(%*{"kind": "loop"})
    enrollAgent(newJString("nope"))
    assert agentNames().len == before

  test "unknown kind is rejected":
    var err = ""
    assert not enrollAgentChecked(
      %*{"name": "weird", "kind": "daemon"}, err)
    assert err.len > 0

  test "enable list filters in enrollment order":
    enrollAgent(%*{"name": "zeta", "kind": "loop", "when_to_use": "z",
      "inputs": [], "cost": "low", "effects": "none"})
    let only = enabledAgents(@["zeta", "brief"])
    assert only.len == 2
    assert only[0].jget("name").getStr() == "brief"
    assert only[1].jget("name").getStr() == "zeta"
