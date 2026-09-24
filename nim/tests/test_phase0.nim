## Phase 0 tests: the config defaults, the `.env` parser and the CLI
## command table. Offline only: no network calls, no `.waku/` writes.

import std/os
import std/unittest

import ../src/config
import ../src/waku

const wakuEnvNames = ["WAKU_PROVIDER", "WAKU_API_KEY", "WAKU_MODEL", "WAKU_HOME"]

proc saveEnv(): array[4, (string, bool, string)] =
  ## Snapshot the covered vars so tests restore, never clobber, the
  ## developer's exported environment.
  for i, name in wakuEnvNames:
    result[i] = (name, existsEnv(name), getEnv(name))

proc restoreEnv(saved: array[4, (string, bool, string)]) =
  for (name, wasSet, value) in saved:
    if wasSet:
      putEnv(name, value)
    else:
      delEnv(name)

suite "phase 0 config":
  test "loadFromEnv keeps the sensible defaults when vars are unset":
    let saved = saveEnv()
    for name in wakuEnvNames:
      delEnv(name)
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.provider == "anthropic"
    assert s.apiKey == ""
    assert s.model == ""
    assert s.home == ".waku"
    restoreEnv(saved)

  test "loadFromEnv respects every WAKU_* override":
    let saved = saveEnv()
    putEnv("WAKU_PROVIDER", "openai")
    putEnv("WAKU_API_KEY", "sk-test")
    putEnv("WAKU_MODEL", "kimi-k3")
    putEnv("WAKU_HOME", "/tmp/waku-test")
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.provider == "openai"
    assert s.apiKey == "sk-test"
    assert s.model == "kimi-k3"
    assert s.home == "/tmp/waku-test"
    restoreEnv(saved)

suite "phase 0 dotenv parser":
  test "parseDotenvLine skips blanks and # comments":
    assert parseDotenvLine("") == ("", "")
    assert parseDotenvLine("   ") == ("", "")
    assert parseDotenvLine("# a comment") == ("", "")

  test "parseDotenvLine strips single and double quotes":
    assert parseDotenvLine("WAKU_PROVIDER=\"anthropic\"") ==
      ("WAKU_PROVIDER", "anthropic")
    assert parseDotenvLine("WAKU_MODEL='kimi-k3'") == ("WAKU_MODEL", "kimi-k3")
    assert parseDotenvLine("WAKU_HOME=.waku") == ("WAKU_HOME", ".waku")

  test "parseDotenvLine ignores a line without = and keeps a value with =":
    assert parseDotenvLine("just a word") == ("", "")
    assert parseDotenvLine("WAKU_URL=http://x?a=b") ==
      ("WAKU_URL", "http://x?a=b")

suite "phase 0 CLI command table":
  test "cliCommands contains all 12 command names":
    let expected = [
      "chat", "dashboard", "connections", "connect", "mcp", "voice",
      "telegram", "discord", "whatsapp", "brief", "gather", "skill",
    ]
    assert cliCommands.len == 12
    for cmd in expected:
      assert cmd in cliCommands, "missing command: " & cmd
