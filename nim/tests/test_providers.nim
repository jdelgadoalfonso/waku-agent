## Phase 0b tests: the providers.toml parser and the model-resolution rules.
## Offline only: no network calls, no `.waku/` writes. The real-registry
## test reads the repo file when the working directory allows it and skips
## gracefully otherwise.

import std/os
import std/strutils
import std/unittest

import ../src/providers

const fixture = """
[anthropic]
kind = "anthropic"
key_env = "ANTHROPIC_API_KEY"
model = "claude-sonnet-5"
small_model = "claude-haiku-4-5-20251001"
flagship = "claude-opus-4-8"
fast = "claude-sonnet-5"
key_url = "https://console.anthropic.com/settings/keys"
price = [3.0, 15.0]

[openai]
kind = "openai"
key_env = "OPENAI_API_KEY"
model = "gpt-5.5"
small_model = "gpt-4.1-mini"

[hosted]
kind = "anthropic"
key_env = "WAKU_PLATFORM_KEY"
model = "waku-free"
base_url_env = "WAKU_PLATFORM_URL"
hidden_unless_env = true
claims_families = false
scoped_credentials = true

[[hosted.endpoints]]
label = "region"
"""

proc saveEnv(keys: openArray[string]): seq[(string, bool, string)] =
  for name in keys:
    result.add((name, existsEnv(name), getEnv(name)))

proc restoreEnv(saved: seq[(string, bool, string)]) =
  for (name, wasSet, value) in saved:
    if wasSet:
      putEnv(name, value)
    else:
      delEnv(name)

suite "phase 0b provider parsing":
  test "parses rows, skips arrays and non-string values":
    let rows = parseProviders(fixture)
    assert rows.len == 3
    assert rows[0].name == "anthropic"
    assert rows[0].kind == "anthropic"
    assert rows[0].keyEnv == "ANTHROPIC_API_KEY"
    assert rows[0].model == "claude-sonnet-5"
    assert rows[0].keyUrl == "https://console.anthropic.com/settings/keys"
    assert rows[2].name == "hosted"
    assert rows[2].hiddenUnlessEnv
    assert not rows[2].claimsFamilies
    assert rows[2].scopedCredentials

  test "tolerates inline comments and commented headers":
    let rows = parseProviders("[solo] # a note\nmodel = \"m1\" # trailing\n" &
      "[bad header\nmodel = \"lost\"\n[solo2]\nmodel = \"m2\"\n")
    assert rows.len == 2
    assert rows[0].model == "m1"
    assert rows[1].model == "m2"

  test "loads the real registry when reachable":
    var found = ""
    for candidate in ["data/providers.toml", "../data/providers.toml",
                      "../../data/providers.toml"]:
      if fileExists(candidate):
        found = candidate
        break
    if found.len == 0:
      skip()
    else:
      let rows = loadProviders(found)
      assert rows.len >= 12, "expected at least 12 rows, got " & $rows.len
      var names: seq[string] = @[]
      for r in rows:
        names.add(r.name)
      assert "anthropic" in names
      assert "openai" in names

suite "phase 0b model resolution":
  test "drops an env-inherited model that belongs elsewhere":
    let saved = saveEnv(["WAKU_MODEL", "WAKU_SMALL_MODEL"])
    let rows = parseProviders(fixture)
    putEnv("WAKU_MODEL", "claude-sonnet-5")
    delEnv("WAKU_SMALL_MODEL")
    let (model, small) = modelsFor("openai", "claude-sonnet-5", "", rows)
    assert model == "gpt-5.5", "foreign model must fall back, got " & model
    assert small == "gpt-4.1-mini"
    restoreEnv(saved)

  test "keeps an unfamiliar model id instead of downgrading it":
    let saved = saveEnv(["WAKU_MODEL", "WAKU_SMALL_MODEL"])
    let rows = parseProviders(fixture)
    putEnv("WAKU_MODEL", "future-model-9")
    delEnv("WAKU_SMALL_MODEL")
    let (model, _) = modelsFor("openai", "future-model-9", "", rows)
    assert model == "future-model-9"
    restoreEnv(saved)

  test "hosted row owns no family but is still judged by the map":
    let rows = parseProviders(fixture)
    assert not belongsElsewhere("waku-free", "hosted", rows)
    assert belongsElsewhere("claude-sonnet-5", "hosted", rows)
    assert not belongsElsewhere("claude-sonnet-5", "anthropic", rows)
    assert not belongsElsewhere("anthropic/claude-3", "openai", rows)

  test "scoped row never falls back to the global key":
    let saved = saveEnv(["WAKU_PLATFORM_KEY"])
    let rows = parseProviders(fixture)
    putEnv("WAKU_PLATFORM_KEY", "plat-123")
    assert resolveApiKey(rows[2], "sk-global") == "plat-123"
    delEnv("WAKU_PLATFORM_KEY")
    assert resolveApiKey(rows[2], "sk-global") == ""
    assert resolveApiKey(rows[0], "sk-global") == "sk-global"
    # A whitespace-only global key is truthy pre-strip, so it yields ""
    # instead of falling through to the row key (mirrors Python).
    assert resolveApiKey(rows[0], "   ") == ""
    restoreEnv(saved)

suite "phase 0b missing-key message":
  test "names the key var, the key url and the dotenv path":
    let msg = missingKeyMessage("anthropic", "ANTHROPIC_API_KEY",
      "https://console.anthropic.com/settings/keys",
      "/home/u/proj/.env", @["anthropic", "openai"])
    assert "ANTHROPIC_API_KEY" in msg
    assert "https://console.anthropic.com/settings/keys" in msg
    assert "/home/u/proj/.env" in msg
    assert "openai" in msg

suite "nim-first t8 regional endpoints":
  ## `[[name.endpoints]]` tables, which `parseProviders` used to skip as
  ## "not registry data". The committed `.env.example` renders one Base URL
  ## choice row per endpoint (minimax, moonshot, zhipu), so a provider row
  ## that carries them has to come through the reader.
  test "a provider row keeps its endpoints in file order":
    let probed = parseProviders("""
[minimax]
kind = "anthropic"
key_env = "MINIMAX_API_KEY"
base_url = "https://api.minimaxi.com/anthropic"
base_url_env = "MINIMAX_BASE_URL"

[[minimax.endpoints]]
label = "China"
base_url = "https://api.minimaxi.com/anthropic"

[[minimax.endpoints]]
label = "Global"
base_url = "https://api.minimax.io/anthropic"
""")
    assert probed.len == 1
    assert probed[0].endpoints.len == 2
    assert probed[0].endpoints[0].label == "China"
    assert probed[0].endpoints[0].baseUrl == "https://api.minimaxi.com/anthropic"
    assert probed[0].endpoints[1].label == "Global"
    assert probed[0].endpoints[1].baseUrl == "https://api.minimax.io/anthropic"

  test "a row without endpoints carries none, and a later table starts clean":
    let probed = parseProviders("""
[anthropic]
kind = "anthropic"
key_env = "ANTHROPIC_API_KEY"

[[minimax.endpoints]]
label = "China"
base_url = "https://api.minimaxi.com/anthropic"

[openai]
kind = "openai"
key_env = "OPENAI_API_KEY"
""")
    assert probed.len == 3
    assert probed[0].endpoints.len == 0, "anthropic inherited minimax endpoints"
    assert probed[1].name == "minimax"
    assert probed[1].endpoints.len == 1
    assert probed[2].endpoints.len == 0, "openai inherited minimax endpoints"
