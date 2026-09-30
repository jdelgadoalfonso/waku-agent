## Phase 5c tests: model catalog — `listModels` parsing/caching/fallbacks
## and the pinned shortlist. Offline only: injected fetch stubs, temp dirs
## cleaned in finally, no network, no `.waku/` writes.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/catalog
import ../src/pricing
import ../src/providers

const catalogFixture = """
[orouter]
kind = "openai"
key_env = "WAKU_TEST_OR_KEY"
base_url = "https://openrouter.ai/api/v1"
model = "or-model"
small_model = "or-small"

[nocat]
kind = "anthropic"
key_env = "WAKU_TEST_NC_KEY"
model = "nc-model"
small_model = "nc-small"
flagship = "nc-flag"
fast = "nc-fast"

[catrow]
kind = "anthropic"
key_env = "WAKU_TEST_CAT_KEY"
model = "cat-model"
small_model = "cat-small"
catalog_url = "https://example.com/v1/models"

[scoped]
kind = "anthropic"
key_env = "WAKU_TEST_SCOPED_KEY"
model = "sc-model"
small_model = "sc-small"
flagship = "sc-flag"
fast = "sc-fast"
base_url_env = "WAKU_TEST_SCOPED_URL"
hidden_unless_env = true
scoped_credentials = true
catalog_from_base_url = true
model_env = "WAKU_TEST_SCOPED_MODEL"
small_model_env = "WAKU_TEST_SCOPED_SMALL"
"""

const catalogEnvKeys = ["WAKU_MODEL", "WAKU_SMALL_MODEL", "WAKU_TEST_OR_KEY",
  "WAKU_TEST_NC_KEY", "WAKU_TEST_CAT_KEY", "WAKU_TEST_SCOPED_KEY",
  "WAKU_TEST_SCOPED_URL", "WAKU_TEST_SCOPED_MODEL", "WAKU_TEST_SCOPED_SMALL"]

proc saveEnv(keys: openArray[string]): seq[(string, bool, string)] =
  for name in keys:
    result.add((name, existsEnv(name), getEnv(name)))

proc restoreEnv(saved: seq[(string, bool, string)]) =
  for (name, wasSet, value) in saved:
    if wasSet:
      putEnv(name, value)
    else:
      delEnv(name)

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc settingsFor(provider: string): CatalogSettings =
  CatalogSettings(home: "", provider: provider, model: "", smallModel: "",
                  baseUrl: "", apiKey: "")

proc modelIds(res: JsonNode): seq[string] =
  for m in res["models"]:
    result.add(m["id"].getStr())

suite "phase 5c catalog listing":
  setup:
    let savedEnv = saveEnv(catalogEnvKeys)
    clearModelsCache()
    clearPriceCache()
  teardown:
    restoreEnv(savedEnv)
    clearModelsCache()
    clearPriceCache()

  test "parses a full openrouter-style entry":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      assert url == "https://openrouter.ai/api/v1/models"
      assert key == "sk-or"
      return """{"data": [{"id": "pro-model",
        "pricing": {"prompt": "0.000002", "completion": "0.000006"},
        "supported_parameters": ["tools", "reasoning"],
        "context_length": 200000}]}"""
    let res = listModels(settingsFor("orouter"), rows, f)
    assert res["listed"].getBool()
    assert res["provider"].getStr() == "orouter"
    assert res["model"].getStr() == "or-model"
    assert res["small_model"].getStr() == "or-small"
    assert res["endpoint"].getStr() == "https://openrouter.ai/api/v1"
    assert res["models"].len == 1
    let e = res["models"][0]
    assert e["id"].getStr() == "pro-model"
    assert not e["free"].getBool()
    assert e["tools"].getBool()
    assert e["reasoning"].getBool()
    assert e["context"].getBiggestInt() == 200000
    assert e["price_in"].getFloat() == 2.0
    assert e["price_out"].getFloat() == 6.0

  test "free is detected by suffix and by zero prompt price":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      return """{"data": [{"id": "x:free"},
        {"id": "zero-price", "pricing": {"prompt": "0", "completion": "0"}}]}"""
    let res = listModels(settingsFor("orouter"), rows, f)
    assert res["models"].len == 2
    assert res["models"][0]["id"].getStr() == "x:free"
    assert res["models"][0]["free"].getBool()
    assert not res["models"][0].hasKey("price_in")
    assert res["models"][1]["id"].getStr() == "zero-price"
    assert res["models"][1]["free"].getBool()
    assert res["models"][1]["price_in"].getFloat() == 0.0

  test "absent supported_parameters omits tools and reasoning keys":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      return """{"data": [{"id": "plain", "context_length": 4096}]}"""
    let e = listModels(settingsFor("orouter"), rows, f)["models"][0]
    assert not e["free"].getBool()
    assert not e.hasKey("tools")
    assert not e.hasKey("reasoning")
    assert e["context"].getBiggestInt() == 4096

  test "parsed prices land in the pricing cache":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      return """{"data": [{"id": "paid-model",
        "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]}"""
    discard listModels(settingsFor("orouter"), rows, f)
    assert priceFor("orouter", "paid-model", rows) == (1.0, 2.0)

  test "sort is free first, tools-false last, id tiebreak":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      return """{"data": [
        {"id": "ooo-paid-notools", "supported_parameters": ["max_tokens"]},
        {"id": "alpha-paid", "supported_parameters": ["tools"]},
        {"id": "zeta:free", "supported_parameters": ["max_tokens"]},
        {"id": "mid-paid"}]}"""
    let res = listModels(settingsFor("orouter"), rows, f)
    assert modelIds(res) == @["zeta:free", "alpha-paid", "mid-paid",
      "ooo-paid-notools"]

  test "row without a catalog falls back to flagship fast active ids":
    let rows = parseProviders(catalogFixture)
    var calls = 0
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      inc calls
      return """{"data": []}"""
    let res = listModels(settingsFor("nocat"), rows, f)
    assert calls == 0
    assert not res["listed"].getBool()
    assert not res.hasKey("error")
    assert res["endpoint"].getStr() == "nocat"
    assert modelIds(res) == @["nc-model", "nc-small", "nc-flag", "nc-fast"]

  test "empty ids are skipped":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      return """{"data": [{"id": ""}, {}, {"id": "kept"}]}"""
    let res = listModels(settingsFor("orouter"), rows, f)
    assert modelIds(res) == @["kept"]

  test "unparsable prices are omitted without failing the entry":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      return """{"data": [{"id": "weird", "pricing": {"prompt": "abc"}},
        {"id": "half", "pricing": {"prompt": "0.000001"}}]}"""
    let res = listModels(settingsFor("orouter"), rows, f)
    assert res["models"].len == 2
    assert not res["models"][0].hasKey("price_in")
    assert not res["models"][1].hasKey("price_in")

  test "active custom base_url wins, ignored for other providers":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let rows = parseProviders(catalogFixture)
    var gotUrl = ""
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      gotUrl = url
      return """{"data": []}"""
    var s = settingsFor("orouter")
    s.baseUrl = "https://custom.example/v1"
    let active = listModels(s, rows, f)
    assert gotUrl == "https://custom.example/v1/models"
    assert active["endpoint"].getStr() == "https://custom.example/v1"
    var s2 = settingsFor("nocat")
    s2.baseUrl = "https://custom.example/v1"
    let other = listModels(s2, rows, f, "orouter")
    assert gotUrl == "https://openrouter.ai/api/v1/models"
    assert other["endpoint"].getStr() == "https://openrouter.ai/api/v1"

suite "phase 5c catalog caching":
  setup:
    let savedEnv = saveEnv(catalogEnvKeys)
    clearModelsCache()
    clearPriceCache()
  teardown:
    restoreEnv(savedEnv)
    clearModelsCache()
    clearPriceCache()

  test "fetch failure returns defaults with reason and caches briefly":
    putEnv("WAKU_TEST_CAT_KEY", "sk-cat")
    let rows = parseProviders(catalogFixture)
    var calls = 0
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      inc calls
      assert url == "https://example.com/v1/models"
      raise newException(CatchableError, "boom 403")
    let first = listModels(settingsFor("catrow"), rows, f)
    assert not first["listed"].getBool()
    assert "boom 403" in first["error"].getStr()
    assert modelIds(first) == @["cat-model", "cat-small"]
    let second = listModels(settingsFor("catrow"), rows, f)
    assert calls == 1
    assert not second["listed"].getBool()
    assert second["error"].getStr() == first["error"].getStr()
    assert modelIds(second) == modelIds(first)

  test "success is cached within the window":
    putEnv("WAKU_TEST_CAT_KEY", "sk-cat")
    let rows = parseProviders(catalogFixture)
    var calls = 0
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      inc calls
      return """{"data": [{"id": "cat-a"}]}"""
    let first = listModels(settingsFor("catrow"), rows, f)
    let second = listModels(settingsFor("catrow"), rows, f)
    assert calls == 1
    assert first["listed"].getBool() and second["listed"].getBool()
    assert modelIds(first) == @["cat-a"]
    assert modelIds(second) == @["cat-a"]

  test "useCache false bypasses a stored listing":
    putEnv("WAKU_TEST_CAT_KEY", "sk-cat")
    let rows = parseProviders(catalogFixture)
    var calls = 0
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      inc calls
      return """{"data": [{"id": "cat-a"}]}"""
    discard listModels(settingsFor("catrow"), rows, f)
    discard listModels(settingsFor("catrow"), rows, f, "", false)
    assert calls == 2

  test "entries expire through the explicit now seam":
    putEnv("WAKU_TEST_CAT_KEY", "sk-cat")
    let rows = parseProviders(catalogFixture)
    var calls = 0
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      inc calls
      return """{"data": [{"id": "cat-a"}]}"""
    const t0 = 1_000_000.0
    discard listModels(settingsFor("catrow"), rows, f, "", true, t0)
    discard listModels(settingsFor("catrow"), rows, f, "", true, t0 + 299.0)
    assert calls == 1
    discard listModels(settingsFor("catrow"), rows, f, "", true, t0 + 301.0)
    assert calls == 2

  test "non-latin1 key names the var and the fix":
    putEnv("WAKU_TEST_CAT_KEY", "sk-bad-\u2192-key")
    let rows = parseProviders(catalogFixture)
    var calls = 0
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      inc calls
      return """{"data": []}"""
    let res = listModels(settingsFor("catrow"), rows, f)
    assert calls == 0
    assert not res["listed"].getBool()
    assert "WAKU_TEST_CAT_KEY" in res["error"].getStr()
    assert "re-paste the key" in res["error"].getStr()
    assert modelIds(res) == @["cat-model", "cat-small"]

  test "scoped rows ignore the global key, others prefer it":
    putEnv("WAKU_TEST_SCOPED_URL", "https://proxy.example")
    delEnv("WAKU_TEST_SCOPED_KEY")
    delEnv("WAKU_TEST_OR_KEY")
    let rows = parseProviders(catalogFixture)
    var gotKey = "unset"
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      gotKey = key
      assert url == "https://proxy.example/v1/models"
      return """{"data": []}"""
    var scoped = settingsFor("scoped")
    scoped.apiKey = "sk-global"
    discard listModels(scoped, rows, f)
    assert gotKey == ""
    let g: FetchFn = proc(url, key: string): string {.closure.} =
      gotKey = key
      return """{"data": []}"""
    var plain = settingsFor("orouter")
    plain.apiKey = "sk-global"
    discard listModels(plain, rows, g)
    assert gotKey == "sk-global"

  test "a global base url never leaks into a scoped row":
    putEnv("WAKU_TEST_SCOPED_URL", "https://proxy.example")
    delEnv("WAKU_TEST_SCOPED_KEY")
    let rows = parseProviders(catalogFixture)
    var gotUrl = ""
    var gotKey = "unset"
    let f: FetchFn = proc(url, key: string): string {.closure.} =
      gotUrl = url
      gotKey = key
      return """{"data": []}"""
    var scoped = settingsFor("scoped")
    scoped.apiKey = "sk-global"
    scoped.baseUrl = "https://custom.example/v1"
    let res = listModels(scoped, rows, f)
    assert res["listed"].getBool()
    assert res["endpoint"].getStr() == "https://proxy.example"
    assert gotUrl == "https://proxy.example/v1/models"
    assert gotKey == ""

suite "phase 5c pinned shortlist":
  setup:
    let savedEnv = saveEnv(catalogEnvKeys)
    clearModelsCache()
    clearPriceCache()
  teardown:
    restoreEnv(savedEnv)
    clearModelsCache()
    clearPriceCache()

  test "save and load roundtrip in a temp home":
    let home = freshDir("waku-catalog-pins")
    try:
      let rows = parseProviders(catalogFixture)
      savePinned(home, @["orouter:or-model", "nocat:nc-flag"])
      assert pinnedSpecs(home, rows) == @["orouter:or-model", "nocat:nc-flag"]
      let saved = parseJson(readFile(home / "models.json"))
      assert saved["pinned"].len == 2
    finally:
      removeDir(home)

  test "defaults pin flagship fast per provider with a key":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    putEnv("WAKU_TEST_NC_KEY", "sk-nc")
    let rows = parseProviders(catalogFixture)
    assert defaultPinnedSpecs(rows) == @["orouter:or-model", "orouter:or-small",
      "nocat:nc-flag", "nocat:nc-fast"]

  test "stale platform placeholder is filtered after env override":
    putEnv("WAKU_TEST_SCOPED_MODEL", "sc-v2")
    let home = freshDir("waku-catalog-stale")
    try:
      let rows = parseProviders(catalogFixture)
      savePinned(home, @["scoped:sc-model", "scoped:sc-flag"])
      assert pinnedSpecs(home, rows) == @["scoped:sc-flag"]
    finally:
      removeDir(home)

  test "defaultModelFor returns the first pin for the provider":
    let home = freshDir("waku-catalog-default-for")
    try:
      let rows = parseProviders(catalogFixture)
      savePinned(home, @["orouter:b-model", "orouter:a-model", "nocat:x"])
      assert defaultModelFor("orouter", home, rows) == "b-model"
      assert defaultModelFor("nocat", home, rows) == "x"
    finally:
      removeDir(home)

  test "defaultModelFor is empty for unknown providers":
    let home = freshDir("waku-catalog-default-empty")
    try:
      let rows = parseProviders(catalogFixture)
      savePinned(home, @["orouter:b-model"])
      assert defaultModelFor("ghost", home, rows) == ""
    finally:
      removeDir(home)

  test "a present file without pinned keeps the empty choice":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let home = freshDir("waku-catalog-nopinned")
    try:
      let rows = parseProviders(catalogFixture)
      assert defaultPinnedSpecs(rows).len > 0
      writeFile(home / "models.json", """{"other": []}""")
      assert pinnedSpecs(home, rows) == @[]
    finally:
      removeDir(home)

  test "corrupt models.json falls back to defaults":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let home = freshDir("waku-catalog-corrupt")
    try:
      let rows = parseProviders(catalogFixture)
      writeFile(home / "models.json", "{nope")
      assert pinnedSpecs(home, rows) == defaultPinnedSpecs(rows)
      assert pinnedSpecs(home, rows) == @["orouter:or-model", "orouter:or-small"]
    finally:
      removeDir(home)

  test "missing models.json falls back to defaults":
    putEnv("WAKU_TEST_OR_KEY", "sk-or")
    let home = freshDir("waku-catalog-missing")
    try:
      let rows = parseProviders(catalogFixture)
      assert pinnedSpecs(home, rows) == defaultPinnedSpecs(rows)
    finally:
      removeDir(home)
