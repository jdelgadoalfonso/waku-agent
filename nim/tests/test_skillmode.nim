## Skill execution mode (T6): compiled plugin or text fallback.
##
## The Nim toolchain is optional at runtime: a machine without it keeps
## running skills exactly as today. Every reason a compile cannot happen
## must fall back to text mode with a visible reason, never fail the turn.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/graph/skillmode

proc manifest(): JsonNode =
  %*{
    "name": "modefx",
    "abi": 1,
    "nodes": [
      {"name": "summarize", "kind": "llm", "inKeys": ["message"],
       "outKey": "summary", "needs": ["llm"],
       "prompt": "Summarize: {{message}}"}
    ]
  }

proc freshHome(tag: string): string =
  result = getTempDir() / ("waku-skillmode-" & tag)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "skill execution mode":

  test "a compilable skill resolves to plugin mode":
    let home = freshHome("plugin")
    let res = resolveSkillExecution(manifest(), home, home / "build")
    assert res.mode == smPlugin
    assert res.reason == ""
    assert res.pluginPath == home / "plugins" / "modefx.so"
    assert fileExists(res.pluginPath)
    removeDir(home)

  test "no compiler falls back to text mode with a visible reason":
    let home = freshHome("nonim")
    let savedPath = getEnv("PATH")
    putEnv("PATH", "")
    var res: SkillExecution
    try:
      res = resolveSkillExecution(manifest(), home, home / "build")
    finally:
      putEnv("PATH", savedPath)
    assert res.mode == smText
    assert res.pluginPath == ""
    assert res.reason.contains("nim")
    assert not fileExists(home / "plugins" / "modefx.so")
    removeDir(home)

  test "an invalid graph falls back to text mode, never raises":
    let home = freshHome("invalid")
    var bad = manifest()
    bad["nodes"][0]["kind"] = %"tool"
    let res = resolveSkillExecution(bad, home, home / "build")
    assert res.mode == smText
    assert res.reason.len > 0
    removeDir(home)

  test "a failing compiler falls back to text mode":
    let home = freshHome("badcc")
    let fake = home / "always-fail"
    writeFile(fake, "#!/bin/sh\nexit 3\n")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
    let res = resolveSkillExecution(manifest(), home, home / "build",
      nimExe = fake)
    assert res.mode == smText
    assert res.reason.len > 0
    removeDir(home)

  test "a cache hit resolves to plugin mode without a compiler":
    let home = freshHome("hit")
    let first = resolveSkillExecution(manifest(), home, home / "build")
    assert first.mode == smPlugin
    let fake = home / "always-fail"
    writeFile(fake, "#!/bin/sh\nexit 3\n")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
    let second = resolveSkillExecution(manifest(), home, home / "build",
      nimExe = fake)
    assert second.mode == smPlugin
    assert second.pluginPath == first.pluginPath
    removeDir(home)

  test "describeExecution never hides a fallback":
    let home = freshHome("describe")
    let ok = resolveSkillExecution(manifest(), home, home / "build")
    assert describeExecution(ok).contains("runs as plugin")
    var bad = manifest()
    bad["nodes"][0]["kind"] = %"tool"
    let text = resolveSkillExecution(bad, home, home / "build")
    let line = describeExecution(text)
    assert line.contains("text mode")
    assert line.contains("modefx")
    removeDir(home)
