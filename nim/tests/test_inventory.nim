## Slice A RED: unified graphs+plugins inventory (read-only).
## Pure and offline: the union of builtins, plugin graphs, enrolled
## cards and on-disk skills, with gaps reported instead of emitted.

import std/json
import std/strutils
import std/unittest

import ../src/graph/inventory
import ../src/graph/registry
import ../src/graph/agents
import ../src/dashboard
import ../src/wire

suite "inventory slice A":

  test "builtins appear with graph kind and builtin source":
    let entries = inventoryEntries(@["triage", "gather"], @[])
    assert entries.len == 2
    let triage = inventoryFind(entries, "triage")
    assert triage != nil
    assert triage.jget("kind").getStr() == "graph"
    assert triage.jget("source").getStr() == "builtin"
    assert triage.jget("installed").getBool() == true
    assert triage.jget("fallback").getStr() == "plain-loop"

  test "closed set: builtin, installed plugin, uncompiled skill":
    registerPluginGraph("plugin:invtest",
      %*{"name": "plugin:invtest", "nodes": [], "edges": []})
    enrollAgent(%*{"name": "plugin:invtest", "kind": "graph",
      "when_to_use": "test routing", "cost": "low"})
    let entries = inventoryEntries(@["triage"],
      @[(name: "invtest", installed: true),
        (name: "invskill", installed: false)])
    assert entries.len == 3
    assert inventoryFind(entries, "triage") != nil
    let plug = inventoryFind(entries, "plugin:invtest")
    assert plug != nil
    assert plug.jget("when_to_use").getStr() == "test routing"
    assert plug.jget("installed").getBool() == true
    let skill = inventoryFind(entries, "invskill")
    assert skill != nil
    assert skill.jget("installed").getBool() == false
    assert skill.jget("source").getStr() == "skill-md"

  test "a card without a row is reported, not emitted":
    enrollAgent(%*{"name": "plugin:invghost", "kind": "graph",
      "when_to_use": "ghost", "cost": "low"})
    let entries = inventoryEntries(@["triage"], @[])
    assert inventoryFind(entries, "plugin:invghost") == nil
    var found = false
    for g in inventoryGaps(@["triage"], @[]):
      if "plugin:invghost" in g:
        found = true
    assert found

  test "graphSection carries the inventory beside workflows":
    let g = graphSection("/tmp/waku-invtest-nonexistent-home", false,
      @["triage"])
    assert g.jget("workflows").kind == JArray
    let inv = g.jget("inventory")
    assert inv.kind == JArray
    var foundTri = false
    for e in inv:
      if e.jget("name").getStr() == "triage":
        foundTri = true
    assert foundTri
