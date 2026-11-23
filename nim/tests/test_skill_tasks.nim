## Skill `tasks:` end to end (S1-S3): SKILL.md frontmatter, the compiled
## manifest, and the agent card the loader enrolls from it.
##
## The user chose frontmatter as the tasks source: a skill declares `tasks:`,
## the compiler carries it into the plugin manifest, and loading the plugin
## enrolls the card Slice B's per-turn filter matches against. Every case
## here is offline and deterministic: the libraries are built from source
## this suite writes into a temp dir with the local compiler, and no socket
## is opened.
##
## The manifest — not the frontmatter — is what the loader trusts (S3): a
## SKILL.md that declares tasks while its manifest does not enrolls nothing,
## so a skill whose install predates the field cannot change routing just by
## being re-read.

import std/json
import std/os
import std/osproc
import std/strutils
import std/unittest

import ../src/graph/agents
import ../src/graph/plugins
import ../src/graph/registry
import ../src/graph/skillgen
import ../src/graph/skillgraph
import ../src/memory_admin
import ../src/skills
import ../src/wire

proc skillDoc(tasksLine: string): string =
  ## A minimal valid SKILL.md carrying `tasksLine` (already newline-ended)
  ## in its frontmatter.
  "---\nname: weekly-brief\ndescription: summarize the week\n" &
    tasksLine & "---\n\nbody\n"

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc buildSkillSo(dir, name: string, tasks: seq[string]): string =
  ## Write a skill manifest (with `tasks` when given), generate its Nim,
  ## compile it, and return the .so path: the same chain `skill_graph_approve`
  ## runs, minus the install lock.
  var manifest = %*{
    "name": name,
    "abi": 1,
    "nodes": [
      {"name": "answer", "kind": "llm", "inKeys": ["message"],
       "outKey": "reply", "needs": ["llm"],
       "prompt": "Answer: {{message}}"}
    ]
  }
  if tasks.len > 0:
    manifest["tasks"] = %tasks
  let source = generateSkillNim(validateSkillGraph(manifest))
  # Nim refuses a source file whose stem is not an identifier, so the temp
  # file uses underscores; the manifest name (and the .so stem) keep the
  # skill's real slug.
  let nimFile = dir / name.replace("-", "_") & ".nim"
  writeFile(nimFile, source)
  let soFile = dir / name & ".so"
  let nim = findExe("nim")
  assert nim.len > 0, "nim must be on PATH"
  let (output, code) = execCmdEx(nim &
    " c --app:lib --panics:off --hints:off -o:" & soFile & " " & nimFile)
  assert code == 0, "skill fixture build failed: " & output
  soFile

const badCardPluginSource = """## Fixture: a plugin whose manifest declares `tasks` in a shape the host
## cannot read. Written and compiled by tests/test_skill_tasks.nim.
proc NimMain() {.importc, cdecl.}

var runtimeStarted = false

proc retText(text: string): cstring =
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc waku_plugin_abi_version(): uint32
    {.exportc: "waku_plugin_abi_version", cdecl, dynlib.} =
  1'u32

proc waku_plugin_init(host: pointer): int32
    {.exportc: "waku_plugin_init", cdecl, dynlib.} =
  if host.isNil:
    return 1
  if not runtimeStarted:
    NimMain()
    runtimeStarted = true
  return 0

proc waku_plugin_describe(): cstring
    {.exportc: "waku_plugin_describe", cdecl, dynlib.} =
  retText("{\"name\": \"badtasks\", \"abi\": 1, \"tasks\": 5, \"nodes\": [{\"name\": \"step\", \"kind\": \"llm\", \"inKeys\": [\"message\"], \"outKey\": \"reply\", \"needs\": [\"llm\"]}]}")

proc waku_plugin_node_run(node, stateJson: cstring, handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  retText("{\"ok\": false, \"error\": \"unused\"}")

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
"""

suite "S1 SKILL.md frontmatter tasks":
  ## The one parser: `validSkillText` gates on it, so the installer, the
  ## loader and `create_skill` all read the same shape.

  test "an absent tasks line means no tasks, never an error":
    let t = skillTasks(frontmatterOf(skillDoc("")))
    check not t.present
    check t.ok
    check t.items.len == 0

  test "an inline list is read entry by entry":
    let t = skillTasks(frontmatterOf(skillDoc("tasks: [research, brief]\n")))
    check t.present
    check t.ok
    check t.items == @["research", "brief"]

  test "a comma-separated line is read the same way":
    let t = skillTasks(frontmatterOf(skillDoc("tasks: research, brief\n")))
    check t.ok
    check t.items == @["research", "brief"]

  test "quotes and spacing around entries are stripped":
    let t = skillTasks(frontmatterOf(
      skillDoc("tasks: [ 'research' , \"brief\" ]\n")))
    check t.ok
    check t.items == @["research", "brief"]

  test "an empty list is no tasks, not an error":
    let t = skillTasks(frontmatterOf(skillDoc("tasks: []\n")))
    check t.present
    check t.ok
    check t.items.len == 0

  test "a non-string entry is refused":
    let t = skillTasks(frontmatterOf(skillDoc("tasks: [research, [brief]]\n")))
    check t.present
    check not t.ok

  test "a mapping entry is refused":
    let t = skillTasks(frontmatterOf(skillDoc("tasks: [research, {tag: brief}]\n")))
    check not t.ok

  test "an unclosed bracket is refused":
    check not skillTasks(frontmatterOf(skillDoc("tasks: [research\n"))).ok

  test "a block list is refused instead of silently dropped":
    # The parser reads one line per key, like every other frontmatter field
    # here. A block list would parse as "no tasks" and lose what the author
    # wrote, so it is refused instead.
    check not skillTasks(frontmatterOf(
      skillDoc("tasks:\n  - research\n  - brief\n"))).ok

  test "the tasks gate is what validSkillText refuses":
    check validSkillText(skillDoc("tasks: [research, brief]\n"))
    check not validSkillText(skillDoc("tasks: [research, [brief]]\n"))

suite "S2/S3 a loaded plugin enrolls the card its manifest describes":

  test "a manifest with tasks enrolls a graph card carrying them":
    let home = freshDir("waku-skill-tasks-home")
    let build = freshDir("waku-skill-tasks-build")
    createDir(home / "plugins")
    copyFile(buildSkillSo(build, "weekly-brief", @["research", "brief"]),
             home / "plugins" / "weekly-brief.so")
    createDir(home / "skills" / "weekly-brief")
    writeFile(home / "skills" / "weekly-brief" / "SKILL.md",
      skillDoc("tasks: [research, brief]\n"))
    var host = nullHostFns()
    let loaded = loadPluginGraphs(home / "plugins", addr host)
    check loaded.len == 1
    check loaded[0].tasks == @["research", "brief"]
    check "plugin:weekly-brief" in pluginGraphNames()
    let card = agentCard("plugin:weekly-brief")
    assert not card.isNil, "a plugin whose manifest declares tasks must enroll"
    check agentKind("plugin:weekly-brief") == "graph"
    check cardTasks(card) == @["research", "brief"]
    check card.jget("when_to_use").getStr() == "summarize the week"
    removeDir(home)
    removeDir(build)

  test "a manifest without tasks enrolls nothing, and still loads":
    # The frontmatter may declare tasks; the manifest is what the loader
    # trusts, so a skill installed before the field existed keeps today's
    # text-match path (S3).
    let home = freshDir("waku-skill-notasks-home")
    let build = freshDir("waku-skill-notasks-build")
    createDir(home / "plugins")
    copyFile(buildSkillSo(build, "plain-skill", @[]),
             home / "plugins" / "plain-skill.so")
    createDir(home / "skills" / "plain-skill")
    writeFile(home / "skills" / "plain-skill" / "SKILL.md",
      skillDoc("tasks: [research, brief]\n"))
    var host = nullHostFns()
    let loaded = loadPluginGraphs(home / "plugins", addr host)
    check loaded.len == 1
    check loaded[0].tasks.len == 0
    check "plugin:plain-skill" in pluginGraphNames()
    check agentCard("plugin:plain-skill").isNil
    removeDir(home)
    removeDir(build)

  test "an unreadable tasks value never breaks the load":
    # The .so is the plugin; a card field the host cannot read costs the
    # card, never the library (fail-open).
    let home = freshDir("waku-skill-badtasks-home")
    let build = freshDir("waku-skill-badtasks-build")
    createDir(home / "plugins")
    let nimFile = build / "badtasks.nim"
    writeFile(nimFile, badCardPluginSource)
    let soFile = build / "badtasks.so"
    let nim = findExe("nim")
    assert nim.len > 0, "nim must be on PATH"
    let (output, code) = execCmdEx(nim &
      " c --app:lib --panics:off --hints:off -o:" & soFile & " " & nimFile)
    assert code == 0, "bad-card fixture build failed: " & output
    copyFile(soFile, home / "plugins" / "badtasks.so")
    var host = nullHostFns()
    let loaded = loadPluginGraphs(home / "plugins", addr host)
    check loaded.len == 1
    check loaded[0].name == "badtasks"
    check loaded[0].tasks.len == 0
    check "plugin:badtasks" in pluginGraphNames()
    check agentCard("plugin:badtasks").isNil
    removeDir(home)
    removeDir(build)
