## Skill install (T5): a compiled skill joins the worker plugin channel.
##
## Installing copies the cached .so into `<home>/plugins/<manifest name>.so`
## — the one directory `pluginRunHeadless` and the worker resolver read —
## so a compiled skill runs headless with the same code path a hand-written
## plugin worker uses. The path stem MUST equal the manifest name: the
## worker route resolves `<home>/plugins/<name>.so` from the manifest name.
##
## Process lifetime is the plugin contract: replacing a file already
## mapped by a running process does not take effect until restart, which
## is why the result reports `replaced`.

import std/json
import std/os
import std/unittest

import ../src/graph/plugins
import ../src/graph/skillcache
import ../src/graph/skillinstall
import ../src/loop  # LlmClient
import ../src/worker_plugin

proc manifest(promptText = "Summarize: {{message}}"): JsonNode =
  %*{
    "name": "skillsum",
    "abi": 1,
    "nodes": [
      {"name": "summarize", "kind": "llm", "inKeys": ["message"],
       "outKey": "summary", "needs": ["llm"], "prompt": promptText}
    ]
  }

proc freshHome(tag: string): string =
  result = getTempDir() / ("waku-skillinstall-" & tag)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "skill install":

  test "installs a compiled skill into the plugin channel":
    let home = freshHome("ok")
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert res.ok, "install failed: " & res.error
    assert res.recentlyCompiled
    assert not res.replaced
    assert res.soPath == home / "plugins" / "skillsum.so"
    assert fileExists(res.soPath)
    removeDir(home)

  test "an installed skill runs headless through the worker path":
    let home = freshHome("headless")
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert res.ok, "install failed: " & res.error
    let client = LlmClient(create: proc(req: JsonNode): JsonNode {.closure.} =
      %*{"stop_reason": "end_turn", "usage": {"in": 4, "out": 2},
         "content": [{"type": "text", "text": "resumen"}]},
      stream: nil)
    let state = pluginRunHeadless(home, "skillsum", "texto largo", "m", "",
      client)
    assert state["reply"].getStr() == "resumen"
    assert state["usage"]["in"].getInt() == 4
    removeDir(home)

  test "an installed skill is worker-eligible by construction":
    let home = freshHome("eligible")
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert res.ok
    var host = nullHostFns()
    let plugin = loadPlugin(res.soPath, addr host)
    assert plugin.name == "skillsum"
    assert pluginWorkerEligible(plugin.nodes)
    removeDir(home)

  test "reinstalling the same graph is a cache hit, not a replacement":
    let home = freshHome("same")
    let first = installCompiledSkill(manifest(), home, home / "build")
    assert first.ok and first.recentlyCompiled and not first.replaced
    let second = installCompiledSkill(manifest(), home, home / "build")
    assert second.ok
    assert not second.recentlyCompiled
    assert not second.replaced
    removeDir(home)

  test "reinstalling a changed graph replaces the file and says so":
    let home = freshHome("changed")
    let first = installCompiledSkill(manifest(), home, home / "build")
    assert first.ok and not first.replaced
    let before = readFile(first.soPath)
    let second = installCompiledSkill(
      manifest("Other prompt: {{message}}"), home, home / "build")
    assert second.ok
    assert second.recentlyCompiled
    assert second.replaced
    assert second.soPath == first.soPath
    assert readFile(second.soPath) != before
    removeDir(home)

  test "an invalid graph installs nothing and touches no plugin":
    let home = freshHome("invalid")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "other.so", "not a library, just a file")
    var bad = manifest()
    bad["nodes"][0]["kind"] = %"tool"
    let res = installCompiledSkill(bad, home, home / "build")
    assert not res.ok
    assert res.soPath == ""
    assert not fileExists(home / "plugins" / "skillsum.so")
    # The neighbour is untouched: a refused skill never disturbs the set.
    assert readFile(home / "plugins" / "other.so") == "not a library, just a file"
    removeDir(home)

  test "the cache keeps the old version after a replacement":
    let home = freshHome("history")
    let first = installCompiledSkill(manifest(), home, home / "build")
    let oldCached = skillCachePath(home, manifest())
    assert fileExists(oldCached)
    discard installCompiledSkill(
      manifest("Changed: {{message}}"), home, home / "build")
    # The plugin channel holds one file per name; the cache still holds
    # every compiled version, so nothing is lost by the replacement.
    assert fileExists(oldCached)
    assert skillCachePath(home, manifest("Changed: {{message}}")) != oldCached
    assert fileExists(skillCachePath(home, manifest("Changed: {{message}}")))
    assert first.ok
    removeDir(home)
