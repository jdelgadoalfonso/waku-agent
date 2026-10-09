## key_locations tests (spec 013): the setup page
## says where Waku looked for a model key, in the
## order the places win, with no value ever shown.
## Offline: temp layouts only, the same cases as
## the Python eval `evals/deterministic/test_key_locations.py`.

import std/json
import std/os
import std/sequtils
import std/strutils
import std/tables
import std/unittest

when defined(posix):
  import std/posix

import ../src/config
import ../src/integrations
import ../src/key_locations
import ../src/providers

const Secret = "sk-ant-never-shown-0123456789"

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc keyProviders(): seq[Provider] =
  ## The visible rows the gate is built from: the
  ## two key_envs the report counts as model keys.
  @[Provider(name: "anthropic", kind: "anthropic",
      keyEnv: "ANTHROPIC_API_KEY"),
    Provider(name: "openai", kind: "openai",
      keyEnv: "OPENAI_API_KEY")]

proc seansLayout(tmp: string): tuple[userHome: string,
                                     main: string,
                                     worktree: string] =
  ## A worktree with no .env, a ~/.waku/.env without
  ## a provider key, and a main checkout whose .env
  ## holds one: Sean's machine on 2026-10-04.
  result.userHome = tmp / "u"
  let harness = result.userHome / "Developer" / "waku-agent-harness"
  result.main = harness / "waku-agent"
  result.worktree = harness / "waku-agent-local7777"
  createDir(result.main / ".git" / "worktrees" /
    "waku-agent-local7777")
  writeFile(result.main / ".env", "ANTHROPIC_API_KEY=" & Secret & "\n")
  createDir(result.worktree)
  writeFile(result.worktree / ".git",
    "gitdir: " & result.main / ".git" / "worktrees" /
      "waku-agent-local7777" & "\n")
  createDir(result.userHome / ".waku")
  writeFile(result.userHome / ".waku" / ".env",
    "TYPESAFE_API_KEY=not-a-model-key\n")

proc report(layout: tuple[userHome: string, main: string,
                          worktree: string],
            env: Table[string, string] = initTable[string, string](),
            startup: seq[string] = @[]): JsonNode =
  modelKeyLocations(layout.worktree, env, layout.userHome,
    startup, keyProviders())

suite "key_locations (spec 013)":
  test "places come in the order they win":
    let tmp = freshDir("waku-kl-order")
    let layout = seansLayout(tmp)
    let wheres = report(layout)["places"].elems.mapIt(
      it["where"].getStr())
    check wheres == @["Environment variables",
      "~/Developer/waku-agent-harness/waku-agent-local7777/.env",
      "~/.waku/.env"]

  test "sean's layout reads as it was":
    let tmp = freshDir("waku-kl-seans")
    let layout = seansLayout(tmp)
    let r = report(layout)
    let states = r["places"].elems.mapIt(it["state"].getStr())
    check states == @["no model key.",
      "not found, and no folder above it has a .env.",
      "found, with no model key in it."]
    check r["intro"].getStr().endsWith("and found none:")
    # The main checkout's .env is named, and so is
    # where to copy the line.
    check r["unread"].elems.len == 1
    let hint = r["unread"].elems[0].getStr()
    check "git worktree" in hint
    check "~/Developer/waku-agent-harness/waku-agent/.env" in hint
    check "~/.waku/.env" in hint
    # Nothing was found, so the paste goes to the home .env.
    check r["save_to"].getStr() == "~/.waku/.env"
    check "from any folder" in r["save_note"].getStr()

  test "presence is reported without the value":
    let tmp = freshDir("waku-kl-secret")
    let layout = seansLayout(tmp)
    writeFile(layout.userHome / ".waku" / ".env",
      "ANTHROPIC_API_KEY=" & Secret & "\n")
    var env = initTable[string, string]()
    env["ANTHROPIC_API_KEY"] = Secret
    let r = report(layout, env)
    check r["places"].elems[2]["state"].getStr() ==
      "found, with a model key in it."
    check r["places"].elems[2]["has_key"].getBool()
    check Secret notin $(r)
    check Secret notin cliLines(r).join("\n")

  test "the environment counts only names set before any env loaded":
    let tmp = freshDir("waku-kl-startup")
    let layout = seansLayout(tmp)
    var env = initTable[string, string]()
    env["ANTHROPIC_API_KEY"] = "x"
    let fromShell = report(layout, env, @["ANTHROPIC_API_KEY"])
    check fromShell["places"].elems[0] == %*{"where":
      "Environment variables", "path": false,
      "state": "a model key is set.", "has_key": true}
    let fromFile = report(layout, env)
    check not fromFile["places"].elems[0]["has_key"].getBool()

  test "a file waku does not read is only said to exist":
    let tmp = freshDir("waku-kl-unread")
    let layout = seansLayout(tmp)
    let r = report(layout)
    let hint = r["unread"].elems[0].getStr()
    check "If your key is in that file" in hint
    check "has a model key" notin hint
    check "with a model key" notin hint
    for place in r["places"].elems:
      check not place["has_key"].getBool()

  test "a legacy folder env is named when home is elsewhere":
    let tmp = freshDir("waku-kl-legacy")
    let layout = seansLayout(tmp)
    createDir(layout.worktree / ".waku")
    writeFile(layout.worktree / ".waku" / ".env",
      "OPENAI_API_KEY=x\n")
    let r = report(layout)
    check r["unread"].elems.anyIt(".waku/.env exists" in it.getStr() and
      "~/.waku" in it.getStr())

  test "a key edited in after start asks for a restart":
    let tmp = freshDir("waku-kl-restart")
    let layout = seansLayout(tmp)
    writeFile(layout.userHome / ".waku" / ".env",
      "ANTHROPIC_API_KEY=x\n")
    check "Restart Waku" in report(layout)["restart"].getStr()
    var env = initTable[string, string]()
    env["ANTHROPIC_API_KEY"] = "x"
    check report(layout, env)["restart"].getStr() == ""

  test "the gate shows only when no place holds a key":
    let tmp = freshDir("waku-kl-gate")
    let layout = seansLayout(tmp)
    # No place holds a key: the report says so.
    check "found none" in report(layout)["intro"].getStr()
    # A key in the home .env is the one the gate reads.
    writeFile(layout.userHome / ".waku" / ".env",
      "ANTHROPIC_API_KEY=sk-home\n")
    let r = report(layout)
    check r["places"].elems[2]["has_key"].getBool()
    check "found none" notin r["intro"].getStr()

  test "cli_lines renders the places and the target":
    let tmp = freshDir("waku-kl-cli")
    let layout = seansLayout(tmp)
    let lines = cliLines(report(layout))
    check lines.anyIt(it.startsWith("Environment variables:"))
    check lines.anyIt(it.startsWith("~/.waku/.env:"))
    check lines[^1].startsWith(
      "A key saved from the dashboard is written to ~/.waku/.env.")

suite "resolve_home (spec 013)":
  test "WAKU_HOME wins":
    let tmp = freshDir("waku-kl-home")
    var env = initTable[string, string]()
    env["WAKU_HOME"] = tmp / "elsewhere"
    let choice = resolveHome(env, tmp, tmp / "u")
    check choice.path == tmp / "elsewhere"
    check choice.rule == "WAKU_HOME"

  test "a folder's .waku wins only while it holds the state db":
    let tmp = freshDir("waku-kl-legacyhome")
    createDir(tmp / "work" / ".waku")
    writeFile(tmp / "work" / ".waku" / "state.db", "x")
    let legacy = resolveHome(initTable[string, string](),
      tmp / "work", tmp / "u")
    check legacy.path == tmp / "work" / ".waku"
    check legacy.rule == "legacy"
    # Once ~/.waku holds state, the global folder wins:
    # a ~/.waku of unrelated files must not hide real memory.
    createDir(tmp / "u" / ".waku")
    writeFile(tmp / "u" / ".waku" / "state.db", "x")
    let global = resolveHome(initTable[string, string](),
      tmp / "work", tmp / "u")
    check global.path == tmp / "u" / ".waku"
    check global.rule == "global"

suite "env_write_target (spec 013)":
  test "a save with no folder env goes to the home env":
    let tmp = freshDir("waku-kl-savehome")
    let target = envWriteTarget(initTable[string, string](),
      tmp, tmp / "u")
    check target.path == tmp / "u" / ".waku" / ".env"
    check target.isHome

  test "a save with a folder env goes to that file":
    let tmp = freshDir("waku-kl-savefolder")
    let folder = tmp / "project"
    createDir(folder)
    writeFile(folder / ".env", "WAKU_PROVIDER=anthropic\n")
    let target = envWriteTarget(initTable[string, string](),
      folder, tmp / "u")
    check target.path == folder / ".env"
    check not target.isHome

  test "a new .env is written with mode 600":
    let tmp = freshDir("waku-kl-mode")
    let target = tmp / ".env"
    var env = initTable[string, string]()
    let store = newHealthStore(tmp)
    let res = applyProvider("anthropic", keyProviders(), env,
      store, target, tmp, key = "sk-test-mode")
    check res.ok
    check fileExists(target)
    when defined(posix):
      var st: Stat
      discard stat(target.cstring, st)
      check (st.st_mode and 0o777) == 0o600
