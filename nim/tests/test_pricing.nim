## Phase 5b tests: pricing — `priceFor` layering, `cutoffFor` coverage,
## provider `price` parsing and `usageSummary` over a temp ledger.
## Offline only: temp dirs, no network, no `.waku/` writes.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import ../src/pricing
import ../src/providers

const priceFixture = """
[anthropic]
kind = "anthropic"
key_env = "ANTHROPIC_API_KEY"
model = "claude-sonnet-5"
small_model = "claude-haiku-4-5-20251001"
price = [3.0, 15.0]

[kimi]
kind = "anthropic"
key_env = "MOONSHOT_API_KEY"
model = "kimi-k3"
small_model = "kimi-k2.6"
price = [0.6, 2.5]

[broken]
kind = "openai"
key_env = "BROKEN_KEY"
model = "b-model"
small_model = "b-small"
price = [nope]
"""

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "phase 5b priceFor":
  setup:
    clearPriceCache()
  teardown:
    clearPriceCache()

  test "known model rate wins over the provider row":
    let rows = parseProviders(priceFixture)
    assert priceFor("kimi", "kimi-k3", rows) == (3.0, 15.0)

  test "unknown model falls back to the provider row":
    let rows = parseProviders(priceFixture)
    assert priceFor("kimi", "some-future-model", rows) == (0.6, 2.5)

  test "unknown provider without rows gives the default estimate":
    assert priceFor("nope", "nope-model", @[]) == (3.0, 15.0)

  test "colon-free ids always cost zero":
    let rows = parseProviders(priceFixture)
    assert priceFor("openrouter", "whatever:free", rows) == (0.0, 0.0)
    assert priceFor("kimi", "kimi-k3:free", rows) == (0.0, 0.0)

  test "remembered rate wins over the tables":
    let rows = parseProviders(priceFixture)
    rememberPrice("kimi-k3", 9.0, 8.0)
    assert priceFor("kimi", "kimi-k3", rows) == (9.0, 8.0)

  test "remembered rate is checked before the free suffix":
    rememberPrice("custom:free", 1.0, 2.0)
    assert priceFor("openrouter", "custom:free", @[]) == (1.0, 2.0)

  test "spot model rates match the vendor tables":
    assert priceFor("anthropic", "claude-fable-5", @[]) == (10.0, 50.0)
    assert priceFor("anthropic", "claude-opus-4-8", @[]) == (5.0, 25.0)
    assert priceFor("kimi", "kimi-k2.7", @[]) == (0.95, 4.0)

suite "phase 5b cutoffFor":
  test "every priced model has a cutoff entry":
    for model in modelPricing.keys:
      assert model in modelCutoff, "missing cutoff for " & model

  test "cutoffs are YYYY-MM or unpublished":
    for model, cutoff in modelCutoff.pairs:
      assert cutoff.len == 0 or
        (cutoff.len == 7 and cutoff[4] == '-' and
          cutoff[0 .. 3].allCharsInSet({'0' .. '9'}) and
          cutoff[5 .. 6].allCharsInSet({'0' .. '9'})),
        "bad cutoff for " & model & ": " & cutoff

  test "spot cutoffs match the vendor cards":
    assert cutoffFor("claude-opus-4-8") == "2026-01"
    assert cutoffFor("claude-fable-5") == "2026-01"
    assert cutoffFor("gpt-5.6-sol") == "2026-02"
    assert cutoffFor("kimi-k3") == "2026-01"
    assert cutoffFor("kimi-k2.7") == ""
    assert cutoffFor("kimi-k2.7-code-highspeed") == ""
    assert cutoffFor("unknown-model-9") == ""

suite "phase 5b provider price parsing":
  test "parses price lists and skips malformed ones":
    let rows = parseProviders(priceFixture)
    assert rows.len == 3
    assert rows[0].priceIn == 3.0
    assert rows[0].priceOut == 15.0
    assert rows[1].priceIn == 0.6
    assert rows[1].priceOut == 2.5
    assert rows[2].priceIn == 3.0
    assert rows[2].priceOut == 15.0

  test "parses integer price literals":
    let rows = parseProviders("[x]\nkind = \"openai\"\nprice = [3, 15]\n")
    assert rows.len == 1
    assert rows[0].priceIn == 3.0
    assert rows[0].priceOut == 15.0

  test "loads the real registry prices when reachable":
    var found = ""
    for candidate in ["waku/providers.toml", "../waku/providers.toml",
                      "../../waku/providers.toml"]:
      if fileExists(candidate):
        found = candidate
        break
    if found.len == 0:
      skip()
    else:
      let rows = loadProviders(found)
      var kimiIdx = -1
      var anthropicIdx = -1
      for i, r in rows:
        if r.name == "kimi":
          kimiIdx = i
        if r.name == "anthropic":
          anthropicIdx = i
      assert kimiIdx >= 0, "kimi row missing"
      assert anthropicIdx >= 0, "anthropic row missing"
      assert rows[kimiIdx].priceIn == 0.6
      assert rows[kimiIdx].priceOut == 2.5
      assert rows[anthropicIdx].priceIn == 3.0
      assert rows[anthropicIdx].priceOut == 15.0
      assert priceFor("kimi", "some-future-model", rows) == (0.6, 2.5)

suite "phase 5b usageSummary":
  setup:
    clearPriceCache()
  teardown:
    clearPriceCache()

  test "aggregates a temp ledger and skips bad lines":
    let home = freshDir("waku-pricing-usage")
    try:
      writeFile(home / "usage.jsonl", [
        """{"ts": "2026-09-30T10:00:00.000+00:00", "provider": "anthropic", """ &
          """"model": "claude-opus-4-8", "kind": "loop", "in": 1000000, "out": 1000000}""",
        """{"ts": "2026-09-29T10:00:00.000+00:00", "provider": "openrouter", """ &
          """"model": "whatever:free", "kind": "loop", "in": 500000, "out": 500000}""",
        "this line is not json",
        """{"ts": "2026-09-29T12:00:00.000+00:00", "provider": "kimi", """ &
          """"model": "some-future-model", "kind": "loop", "in": 1000000, "out": 0}""",
      ].join("\n") & "\n")
      let rows = parseProviders(priceFixture)
      let s = usageSummary(home, rows)
      assert s.calls == 3
      assert s.totalIn == 2500000
      assert s.totalOut == 1500000
      assert abs(s.totalCost - 30.6) < 1e-9
      assert s.byDay.len == 2
      assert s.byDay[0]["date"].getStr() == "2026-09-30"
      assert s.byDay[0]["calls"].getBiggestInt() == 1
      assert s.byDay[1]["date"].getStr() == "2026-09-29"
      assert s.byDay[1]["calls"].getBiggestInt() == 2
      assert s.byProvider.len == 3
      assert s.byProvider[0]["provider"].getStr() == "anthropic"
      assert abs(s.byProvider[0]["cost"].getFloat() - 30.0) < 1e-9
      assert s.byProvider[1]["provider"].getStr() == "kimi"
      assert s.byProvider[2]["provider"].getStr() == "openrouter"
    finally:
      removeDir(home)

  test "explicit empty provider stays empty like python":
    let home = freshDir("waku-pricing-empty-prov")
    try:
      writeFile(home / "usage.jsonl",
        """{"ts": "2026-09-30T10:00:00.000+00:00", "provider": "", """ &
          """"model": "m", "kind": "loop", "in": 10, "out": 5}""" & "\n")
      let s = usageSummary(home, @[])
      assert s.calls == 1
      assert s.byProvider.len == 1
      assert s.byProvider[0]["provider"].getStr() == ""
    finally:
      removeDir(home)

  test "missing ledger gives zeros":
    let home = freshDir("waku-pricing-empty")
    try:
      let s = usageSummary(home, @[])
      assert s.calls == 0
      assert s.totalIn == 0
      assert s.totalOut == 0
      assert s.totalCost == 0.0
      assert s.byDay.len == 0
      assert s.byProvider.len == 0
    finally:
      removeDir(home)
