## Step 1 pins: the graph plugin registry is the source of truth.
## Builtins only, no dynamic libraries: triage+gather present, unique
## names, valid payloads, enable-list filtering, kind gate, and the
## `[plugins]` default (WAKU_PLUGINS). Pure and offline.

import std/json
import std/os
import std/unittest

import ../src/config
import ../src/graph/registry
import ../src/wire

suite "plugin registry step 1":

  test "builtins are triage then gather":
    assert workflowNames() == @["triage", "gather"]
    assert defaultPlugins == @["triage", "gather"]

  test "builtin topologies are valid describe() payloads":
    let wfs = builtinWorkflows()
    assert wfs.len == 2
    assert wfs[0].jget("name").getStr() == "triage"
    assert wfs[1].jget("name").getStr() == "gather"
    for wf in wfs:
      assert wf["nodes"].len > 0
      assert wf["edges"].len > 0

  test "enable list filters preserving dashboard order":
    let only = enabledWorkflows(@["gather", "triage"])
    assert only.len == 2
    assert only[0].jget("name").getStr() == "triage"
    assert only[1].jget("name").getStr() == "gather"
    let one = enabledWorkflows(@["triage"])
    assert one.len == 1
    assert one[0].jget("name").getStr() == "triage"
    assert enabledWorkflows(@[]).len == 0
    assert enabledWorkflows(@["nope"]).len == 0

  test "only the four declarable kinds pass":
    for kind in ["tool", "llm", "agent", "router"]:
      assert isKnownPluginKind(kind)
    assert not isKnownPluginKind("fn")
    assert not isKnownPluginKind("")
    assert not isKnownPluginKind("custom")

  test "plugin list parse trims, drops empties, dedupes":
    assert parsePluginList("triage, gather") == @["triage", "gather"]
    assert parsePluginList("") == newSeq[string]()
    assert parsePluginList("  ") == newSeq[string]()
    assert parsePluginList("triage,triage,,gather") == @["triage", "gather"]

  test "settings default enables both builtins":
    assert defaultSettings().plugins == @["triage", "gather"]

  test "WAKU_PLUGINS overrides, blank keeps the default":
    let saved = getEnv("WAKU_PLUGINS")
    putEnv("WAKU_PLUGINS", "gather")
    var a = defaultSettings()
    a.loadFromEnv()
    assert a.plugins == @["gather"]
    putEnv("WAKU_PLUGINS", "  ")
    var b = defaultSettings()
    b.loadFromEnv()
    assert b.plugins == @["triage", "gather"]
    putEnv("WAKU_PLUGINS", saved)
