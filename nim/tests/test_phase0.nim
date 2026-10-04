## Phase 0 tests: the config defaults, the `.env` parser and the CLI
## command table. Offline only: no network calls, no `.waku/` writes.

import std/os
import std/unittest

import ../src/config
import ../src/waku

const wakuEnvNames = ["WAKU_PROVIDER", "WAKU_API_KEY", "WAKU_MODEL", "WAKU_HOME",
  # Not a `WAKU_*` var, but it lands in Settings the same way and the
  # snapshot has to cover it or a developer's real collector endpoint
  # would leak into the "unset" pin below.
  "OTEL_EXPORTER_OTLP_ENDPOINT", "WAKU_SEMANTIC_STORE", "MEM0_USER_ID",
  "MEM0_API_KEY"]

proc saveEnv(): array[8, (string, bool, string)] =
  ## Snapshot the covered vars so tests restore, never clobber, the
  ## developer's exported environment.
  for i, name in wakuEnvNames:
    result[i] = (name, existsEnv(name), getEnv(name))

proc restoreEnv(saved: array[8, (string, bool, string)]) =
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
    assert s.otelEndpoint == "", "no collector unless one is named"
    restoreEnv(saved)

  test "OTEL_EXPORTER_OTLP_ENDPOINT names the collector, as in config.py":
    # Python: `field(default_factory=lambda: os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", ""))`.
    # The port POSTs OTLP/HTTP rather than gRPC, so the VALUE is the same
    # `host:port` but the collector is Phoenix's 6006, not the 4317 the
    # gRPC exporter would dial — `otel.nim` owns that half.
    let saved = saveEnv()
    for name in wakuEnvNames:
      delEnv(name)
    putEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:6006")
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.otelEndpoint == "localhost:6006"
    restoreEnv(saved)

  test "WAKU_SEMANTIC_STORE names the backend, MEM0_USER_ID the person":
    # Python: `semantic_store` from `WAKU_SEMANTIC_STORE` (config.py) and the
    # mem0 adapter's `env_or("MEM0_USER_ID", "waku")`. The BLANK case is the
    # one that matters: the Connections form writes optional fields even when
    # you leave them empty, so a bare getenv would scope somebody's memory to
    # "" and the memory would be gone with no error anywhere.
    let saved = saveEnv()
    for name in wakuEnvNames:
      delEnv(name)
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.semanticStore == "sqlite", "no store named means the local one"
    assert s.mem0UserId == "waku", "and the default person"
    putEnv("WAKU_SEMANTIC_STORE", "mem0")
    putEnv("MEM0_USER_ID", "   ")
    s.loadFromEnv()
    assert s.semanticStore == "mem0"
    assert s.mem0UserId == "waku", "a blank user id is absent, not a scope"
    putEnv("MEM0_USER_ID", "jose")
    s.loadFromEnv()
    assert s.mem0UserId == "jose"
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
