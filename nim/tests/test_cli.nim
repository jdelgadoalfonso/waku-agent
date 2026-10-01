## Phase 4e tests: CLI dispatch, snapshot, client config errors.
## Offline only: temp homes, scrubbed env, no network (every clientFor
## failure happens before any socket; runCommand paths tested never pass
## config).

import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/cli
import ../src/client
import ../src/config
import ../src/db
import ../src/integrations
import ../src/memory
import ../src/providers
import ../src/waku

const scrubNames = ["WAKU_PROVIDER", "WAKU_API_KEY", "WAKU_MODEL",
  "WAKU_SMALL_MODEL", "WAKU_BASE_URL", "WAKU_HOME", "WAKU_MAX_ITERATIONS",
  "WAKU_MAX_TOKENS", "WAKU_HISTORY_TURNS", "WAKU_GRAPH_WORKFLOWS",
  "ANTHROPIC_API_KEY"]

proc scrubEnv(): seq[(string, string, bool)] =
  for n in scrubNames:
    result.add((n, getEnv(n), existsEnv(n)))
    delEnv(n)

proc restoreEnv(saved: seq[(string, string, bool)]) =
  for (n, v, was) in saved:
    if was: putEnv(n, v)
    else: delEnv(n)

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc registryPath(): string =
  ## The real `waku/providers.toml` from the repo checkout layout.
  result = parentDir(getCurrentDir()) / "waku" / "providers.toml"

proc anthropicKeyEnv(): string =
  for p in loadProviders(registryPath()):
    if p.name == "anthropic":
      return p.keyEnv
  raise newException(ValueError, "no anthropic row in providers.toml")

suite "phase 4e memory snapshot":
  test "empty memory renders counts and nones":
    let home = freshHome("waku-cli-empty")
    let db = connectDb(home)
    let snap = memorySnapshot(db)
    assert "Semantic facts (0)" in snap
    assert "Recent episodes (0)" in snap
    assert "Unconsolidated chat messages: 0" in snap
    assert snap.count("- none yet") == 2
    db.close()
    removeDir(home)

  test "seeded memory renders rows verbatim":
    let home = freshHome("waku-cli-seed")
    let db = connectDb(home)
    db.addFact("Alex", "likes sailing")
    db.addEpisode("shipped the loop", "2026-09-28 10:00")
    db.logChat("hi", "hello")
    let snap = memorySnapshot(db)
    assert "Semantic facts (1)" in snap
    assert "- [alex] likes sailing" in snap
    assert "Recent episodes (1)" in snap
    assert "- 2026-09-28 10:00 - shipped the loop" in snap
    assert "Unconsolidated chat messages: 2" in snap
    db.close()
    removeDir(home)

suite "phase 4e client config":
  test "unknown provider names the visible ones":
    let saved = scrubEnv()
    var s = defaultSettings()
    s.provider = "nope"
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert "Unknown WAKU_PROVIDER 'nope'" in exc.msg
      assert "anthropic" in exc.msg
    restoreEnv(saved)

  test "no key says what to set":
    let saved = scrubEnv()
    var s = defaultSettings()  # provider anthropic, no keys anywhere
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert "No API key for provider 'anthropic'" in exc.msg
      assert anthropicKeyEnv() in exc.msg
      assert "Other providers: " in exc.msg
      assert "anthropic" in exc.msg  # the full visible list, like Python
    restoreEnv(saved)

  test "a key builds the client and fills default models":
    let saved = scrubEnv()
    putEnv(anthropicKeyEnv(), "sk-ant-test")
    var s = defaultSettings()
    let client = clientFor(s, loadProviders(registryPath()), "", "")
    assert not client.create.isNil  # wired, no socket touched
    assert s.model.len > 0  # row defaults applied via models_for
    assert s.smallModel.len > 0
    restoreEnv(saved)

  test "a hidden row names its variable":
    let saved = scrubEnv()
    delEnv("WAKU_PLATFORM_BASE_URL")
    var s = defaultSettings()
    s.provider = "waku-platform"
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert exc.msg == "'waku-platform' is not configured: set " &
        "WAKU_PLATFORM_BASE_URL to enable it."
    restoreEnv(saved)

  test "a pasted smart quote is called out":
    let saved = scrubEnv()
    putEnv(anthropicKeyEnv(), "sk-ant-\u201C")
    var s = defaultSettings()
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert "non-ASCII character" in exc.msg
    restoreEnv(saved)

suite "phase 4e dispatch":
  test "unknown command prints usage and exits 1":
    assert runCommand(@["bogus"]) == 1

  test "known-but-later commands are honest stubs with exit 0":
    assert runCommand(@["dashboard"]) == 0
    assert runCommand(@["telegram"]) == 0

  test "chat without keys exits 1 before touching disk or net":
    let saved = scrubEnv()
    let home = freshHome("waku-cli-nokey")
    putEnv("WAKU_HOME", home)
    removeDir(home)  # must stay absent: config must fail first
    assert runCommand(@["chat"], home) == 1
    assert not dirExists(home)
    restoreEnv(saved)
    if dirExists(home):
      removeDir(home)

suite "phase 5d2 connections dispatch":
  test "connections exits 0 on a fresh health store":
    if findProvidersToml().len == 0:
      skip()
    else:
      let saved = scrubEnv()
      let home = freshHome("waku-conn-fresh")
      putEnv("WAKU_HOME", home)
      assert runCommand(@["connections"]) == 0
      restoreEnv(saved)
      removeDir(home)

  test "connections exits 1 when a configured row has stored ERROR":
    if findProvidersToml().len == 0:
      skip()
    else:
      let saved = scrubEnv()
      let tgWasSet = existsEnv("TELEGRAM_BOT_TOKEN")
      let tgValue = getEnv("TELEGRAM_BOT_TOKEN")
      let home = freshHome("waku-conn-error")
      putEnv("WAKU_HOME", home)
      putEnv("TELEGRAM_BOT_TOKEN", "sk-tg-test")
      let store = newHealthStore(home)
      recordHealth(store, "telegram",
        IntegrationStatus(state: error, message: "synthetic outage"))
      assert runCommand(@["connections"]) == 1
      if tgWasSet:
        putEnv("TELEGRAM_BOT_TOKEN", tgValue)
      else:
        delEnv("TELEGRAM_BOT_TOKEN")
      restoreEnv(saved)
      removeDir(home)

## Phase 6b: `mcp` dispatch is real (list/login/logout); every other
## later-phase command stays an honest stub (pin 4e). Offline only:
## tmp homes via `WAKU_HOME`, no subprocess, no socket — the login
## paths exercised here fail before any transport (unknown server,
## oauth-needs-6c), and success paths live in `test_mcp.nim` with
## injected `HttpPostFn` fakes.

suite "phase 6b mcp dispatch":
  test "mcp with no config lists empty with exit 0":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-empty")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["mcp"]) == 0
    restoreEnv(saved)
    removeDir(home)

  test "mcp logout of an unknown account exits 0":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-logout")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["mcp", "logout", "ghost"]) == 0
    restoreEnv(saved)
    removeDir(home)

  test "mcp login on unknown and oauth servers exits 1 without transport":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-login")
    putEnv("WAKU_HOME", home)
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://h2/m", "oauth": true}]}""")
    assert runCommand(@["mcp", "login", "nope"]) == 1
    assert runCommand(@["mcp", "login", "o"]) == 1
    restoreEnv(saved)
    removeDir(home)

  test "mcp with the wrong shape exits 1 (no longer a stub)":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-shape")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["mcp", "login"]) == 1
    assert runCommand(@["mcp", "bogus", "extra", "args"]) == 1
    restoreEnv(saved)
    removeDir(home)
