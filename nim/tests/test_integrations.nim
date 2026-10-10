## Phase 5d1 tests: pure integrations-registry core.
## Offline only: env travels as `Table[string, string]`, hostOs is injected,
## health/gateway arrive as closures. No network, no `.waku/` writes, and the
## tests never touch process env or spawn Python. Every temp dir this file
## creates is gone before the run ends.

import std/algorithm
import std/os
import std/sequtils
import std/strutils
import std/tables
import std/unittest

import ../src/integrations
import ../src/providers

proc envOf(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (k, v) in pairs:
    result[k] = v

proc findRow(rows: seq[Integration], key: string): Integration =
  for r in rows:
    if r.key == key:
      return r
  raise newException(AssertionDefect, "missing static row: " & key)

proc findView(views: seq[IntegrationView], key: string): IntegrationView =
  for v in views:
    if v.key == key:
      return v
  raise newException(AssertionDefect, "missing view: " & key)

const linuxOs = "linux"
const macOs = "macosx"

suite "phase 5d1 static registry":
  test "all 13 keys present in order with their groups":
    let got = INTEGRATIONS.mapIt((it.key, it.group))
    assert got == @[
      ("telegram", "Channels"),
      ("discord", "Channels"),
      ("whatsapp", "Channels"),
      ("google_calendar", "Calendar & Productivity"),
      ("apple_calendar", "Calendar & Productivity"),
      ("apple_tools", "Calendar & Productivity"),
      ("obsidian", "Memory & Storage"),
      ("mem0", "Memory & Storage"),
      ("zep", "Memory & Storage"),
      ("langmem", "Memory & Storage"),
      ("supabase", "Memory & Storage"),
      ("tavily", "Search & Observability"),
      ("otel", "Search & Observability"),
    ]

  test "whatsapp has 5 fields, 4 of them required":
    let row = findRow(INTEGRATIONS, "whatsapp")
    assert row.env.len == 5
    assert row.env.filterIt(it.required).len == 4
    assert row.env[4].name == "WHATSAPP_ALLOWED_PHONE"
    assert not row.env[4].required
    assert row.env[4].help == "Without '+' prefix. Empty = answer anyone."

  test "discord field kinds and normalize marker":
    let row = findRow(INTEGRATIONS, "discord")
    assert row.env.len == 6
    assert row.env[3].name == "DISCORD_REQUIRE_MENTION"
    assert row.env[3].kind == boolField
    for i in [0, 1, 2, 4, 5]:
      assert row.env[i].kind == textField
    assert row.normalize != nil

  test "obsidian choice options, defaults and no normalize hook":
    let row = findRow(INTEGRATIONS, "obsidian")
    assert row.env[0].kind == choiceField
    assert row.env[0].default == "sqlite"
    assert row.env[0].options == @["sqlite", "obsidian"]
    assert row.normalize == nil
    assert row.env[1].name == "WAKU_OBSIDIAN_VAULT"
    assert row.env[1].required
    assert findRow(INTEGRATIONS, "telegram").normalize == nil

  test "spot extras, imports, setup urls and reloads":
    let telegram = findRow(INTEGRATIONS, "telegram")
    assert telegram.extra == "telegram"
    assert telegram.importName == "telegram"
    assert telegram.setupUrl == "https://t.me/BotFather"
    assert telegram.reload == gateway
    assert findRow(INTEGRATIONS, "whatsapp").importName == "httpx"
    assert findRow(INTEGRATIONS, "tavily").reload == live
    assert findRow(INTEGRATIONS, "tavily").extra == ""
    assert findRow(INTEGRATIONS, "tavily").setupUrl == "https://tavily.com"
    assert findRow(INTEGRATIONS, "google_calendar").setupUrl ==
      "https://developers.google.com/calendar/api/quickstart/python"
    assert findRow(INTEGRATIONS, "apple_calendar").extra == ""
    assert findRow(INTEGRATIONS, "otel").importName == "opentelemetry"

suite "phase 5d1 enabled predicates":
  test "telegram toggles on its token":
    let row = findRow(INTEGRATIONS, "telegram")
    assert not row.enabled(envOf([]), linuxOs)
    assert row.enabled(envOf([("TELEGRAM_BOT_TOKEN", "tok")]), linuxOs)

  test "darwin rows gate on the injected hostOs":
    let cal = findRow(INTEGRATIONS, "apple_calendar")
    let tools = findRow(INTEGRATIONS, "apple_tools")
    let env = envOf([("WAKU_APPLE_CALENDAR", "1"), ("WAKU_APPLE_TOOLS", "1")])
    assert not cal.enabled(env, linuxOs)
    assert not tools.enabled(env, linuxOs)
    assert cal.enabled(env, macOs)
    assert tools.enabled(env, macOs)
    assert not cal.enabled(envOf([]), macOs)

  test "obsidian store selector compares the store var":
    let row = findRow(INTEGRATIONS, "obsidian")
    assert row.enabled(envOf([("WAKU_EPISODIC_STORE", "obsidian")]), linuxOs)
    assert not row.enabled(envOf([("WAKU_EPISODIC_STORE", "sqlite")]), linuxOs)
    assert not row.enabled(envOf([]), linuxOs)
    assert findRow(INTEGRATIONS, "mem0").enabled(
      envOf([("WAKU_SEMANTIC_STORE", "mem0")]), linuxOs)
    assert findRow(INTEGRATIONS, "supabase").enabled(
      envOf([("WAKU_SEMANTIC_STORE", "supabase")]), linuxOs)

  test "provider rows are visible only, with title-case labels":
    let seen = Provider(name: "seen", keyEnv: "SEEN_API_KEY")
    let hid = Provider(name: "hid_prov", keyEnv: "HID_API_KEY",
                       baseUrlEnv: "HID_URL", hiddenUnlessEnv: true)
    assert providerIntegrations(@[seen, hid], envOf([])).mapIt(it.key) == @["seen"]
    let rows = providerIntegrations(@[seen, hid],
      envOf([("HID_URL", "https://proxy.example")]))
    assert rows.mapIt(it.key) == @["seen", "hid_prov"]
    assert rows[0].name == "Seen"
    assert rows[1].name == "Hid Prov"
    assert rows[0].env.len == 1
    assert rows[0].env[0].name == "SEEN_API_KEY"
    assert rows[0].env[0].label == "API Key"
    assert rows[0].env[0].secret
    assert not rows[0].env[0].required
    let labeled = Provider(name: "waku_platform", keyEnv: "WAKU_PLATFORM_KEY",
                           label: "Waku Free")
    assert providerIntegrations(@[labeled], envOf([]))[0].name == "Waku Free"

suite "phase 5d1 status machine":
  test "empty env is not_configured with no message":
    let st = integrationStatus(findRow(INTEGRATIONS, "telegram"), envOf([]),
                               linuxOs)
    assert st.state == notConfigured
    assert st.message == ""
    assert st.checkedAt == ""

  test "apple rows report macOS only off darwin":
    let row = findRow(INTEGRATIONS, "apple_calendar")
    let off = integrationStatus(row, envOf([]), linuxOs)
    assert off.state == notConfigured
    assert off.message == "macOS only"
    let on = integrationStatus(row, envOf([]), macOs)
    assert on.state == notConfigured
    assert on.message == ""

  test "missing required names every missing field":
    let wa = findRow(INTEGRATIONS, "whatsapp")
    let st = integrationStatus(wa, envOf([("WHATSAPP_TOKEN", "tok")]), linuxOs)
    assert st.state == installedButUnconfigured
    assert st.message == "missing WHATSAPP_PHONE_NUMBER_ID, " &
      "WHATSAPP_APP_SECRET, WHATSAPP_VERIFY_TOKEN"
    let tg = integrationStatus(findRow(INTEGRATIONS, "telegram"),
      envOf([("TELEGRAM_ALLOWED_USER", "me")]), linuxOs)
    assert tg.state == installedButUnconfigured
    assert tg.message == "missing TELEGRAM_BOT_TOKEN"

  test "complete row falls back to configured, not tested yet":
    let st = integrationStatus(findRow(INTEGRATIONS, "telegram"),
      envOf([("TELEGRAM_BOT_TOKEN", "tok")]), linuxOs)
    assert st.state == configured
    assert st.message == "configured — not tested yet"

  test "health seam overrides the configured fallback":
    let health: HealthFn = proc(key: string): IntegrationStatus {.closure.} =
      IntegrationStatus(state: connected, message: "probe ok",
                        checkedAt: "2026-09-30")
    let st = integrationStatus(findRow(INTEGRATIONS, "telegram"),
      envOf([("TELEGRAM_BOT_TOKEN", "tok")]), linuxOs, health)
    assert st.state == connected
    assert st.message == "probe ok"
    assert st.checkedAt == "2026-09-30"

  test "gateway hook answers gateway rows, absence falls through":
    let row = findRow(INTEGRATIONS, "discord")
    let env = envOf([("DISCORD_BOT_TOKEN", "tok")])
    let failing: GatewayStatusFn =
      proc(key: string): (bool, IntegrationStatus) {.closure.} =
        (true, IntegrationStatus(state: error, message: "gateway down"))
    let err = integrationStatus(row, env, linuxOs, nil, failing)
    assert err.state == error
    assert err.message == "gateway down"
    let silent: GatewayStatusFn =
      proc(key: string): (bool, IntegrationStatus) {.closure.} =
        (false, IntegrationStatus(state: configured))
    let through = integrationStatus(row, env, linuxOs, nil, silent)
    assert through.state == configured
    assert through.message == "configured — not tested yet"

suite "phase 5d1 views":
  test "secret masking keeps last4 and leaks no value":
    let views = listIntegrations(@[], envOf([("TELEGRAM_BOT_TOKEN", "sk-abcdef1234")]),
                                 linuxOs)
    let tg = findView(views, "telegram")
    assert tg.fields[0].configured
    assert tg.fields[0].last4 == "1234"
    assert tg.fields[0].value == ""
    assert tg.fields[1].last4 == ""
    assert not tg.fields[1].configured

  test "plain fields read value-or-default":
    var views = listIntegrations(@[], envOf([]), linuxOs)
    assert findView(views, "google_calendar").fields[1].value == "primary"
    views = listIntegrations(@[],
      envOf([("WAKU_GOOGLE_CALENDAR_ID", "work")]), linuxOs)
    assert findView(views, "google_calendar").fields[1].value == "work"
    assert findView(views, "google_calendar").fields[1].last4 == ""

  test "install command only when extra set":
    let views = listIntegrations(@[], envOf([]), linuxOs)
    assert findView(views, "telegram").installCommand == "pip install -e '.[telegram]'"
    assert findView(views, "tavily").installCommand == ""
    assert findView(views, "telegram").setupUrl == "https://t.me/BotFather"

  test "listProviders and listConnections split on the group":
    let providers = @[Provider(name: "demo", keyEnv: "DEMO_API_KEY")]
    assert listProviders(providers, envOf([]), linuxOs).mapIt(it.key) == @["demo"]
    let conns = listConnections(providers, envOf([]), linuxOs)
    assert conns.len == INTEGRATIONS.len
    assert conns[0].key == "telegram"
    assert conns[^1].key == "otel"
    for v in conns:
      assert v.group != "AI Providers"

  test "registry puts provider rows first, statics after":
    let providers = @[Provider(name: "b_prov", keyEnv: "B_KEY"),
                      Provider(name: "a_prov", keyEnv: "A_KEY")]
    let reg = registry(providers, envOf([]))
    assert reg.len == 2 + INTEGRATIONS.len
    assert reg[0].key == "b_prov"
    assert reg[1].key == "a_prov"
    assert reg[2].key == "telegram"
    assert reg[^1].key == "otel"
    assert reg[0].group == "AI Providers"

const goldenExpected = """# BEGIN GENERATED CONNECTIONS
# Generated by scripts/generate_env_example.py; definitions live in waku/integrations.py

WAKU_PROVIDER=anthropic

# ── AI Providers ──

# ── Demo Ai ──
# Uses Demo Ai models.
# DEMO_AI_KEY=

# ── Thing ──
# Uses Thing models.
# WAKU_THING_KEY=

# ── Channels ──

# ── Telegram ──
# Lets Waku receive and send Telegram messages.
# Install: pip install -e '.[telegram]'
# Setup: https://t.me/BotFather
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_ALLOWED_USER=

# ── Discord ──
# Lets Waku answer in a Discord server.
# Install: pip install -e '.[discord]'
# DISCORD_BOT_TOKEN=
# DISCORD_ALLOWED_USER=
# DISCORD_ALLOWED_CHANNEL=
# Set to 1 to enable.
# DISCORD_REQUIRE_MENTION=
# DISCORD_MAX_TURNS_PER_HOUR=
# DISCORD_HOME=

# ── WhatsApp ──
# Lets Waku answer WhatsApp messages via the Meta Cloud API.
# Install: pip install -e '.[whatsapp]'
# Setup: https://developers.facebook.com/apps
# WHATSAPP_TOKEN=
# WHATSAPP_PHONE_NUMBER_ID=
# WHATSAPP_APP_SECRET=
# WHATSAPP_VERIFY_TOKEN=
# Without '+' prefix. Empty = answer anyone.
# WHATSAPP_ALLOWED_PHONE=

# ── Calendar & Productivity ──

# ── Google Calendar ──
# Lets Waku create and update Google Calendar events.
# Install: pip install -e '.[gcal]'
# Setup: https://developers.google.com/calendar/api/quickstart/python
# Set to 1 to enable.
# WAKU_GOOGLE_CALENDAR=
# WAKU_GOOGLE_CALENDAR_ID=primary

# ── Apple Calendar ──
# Lets Waku work with Apple Calendar on this Mac.
# Set to 1 to enable.
# WAKU_APPLE_CALENDAR=
# WAKU_APPLE_CALENDARS=

# ── Apple Tools ──
# Lets Waku use Apple Mail and other local Apple tools.
# Set to 1 to enable.
# WAKU_APPLE_TOOLS=

# ── Memory & Storage ──

# ── Obsidian ──
# Stores episodic memory as notes in your local Obsidian vault.
# Choices: sqlite, obsidian.
# WAKU_EPISODIC_STORE=sqlite
# Root of your local Obsidian vault. Episodes live under waku/episodes/.
# WAKU_OBSIDIAN_VAULT=

# ── Mem0 ──
# Stores semantic memory in the Mem0 service.
# Install: pip install -e '.[arena]'
# Choices: sqlite, mem0.
# WAKU_SEMANTIC_STORE=sqlite
# From app.mem0.ai. The adapter sends infer=False so add() always stores — a bake-off against it measures retrieval, not Mem0's own extraction step.
# MEM0_API_KEY=
# Defaults to 'waku'. Change it only if several people share one Mem0 account.
# MEM0_USER_ID=

# ── Zep ──
# Stores semantic memory in a Zep temporal graph.
# Install: pip install -e '.[arena]'
# Choices: sqlite, zep.
# WAKU_SEMANTIC_STORE=sqlite
# From getzep.com. Facts become graph edges with validity dates, so a correction supersedes the old value instead of ranking beside it — the one backend built for the update test.
# ZEP_API_KEY=
# Defaults to 'waku'. Zep scopes a graph per user.
# ZEP_USER_ID=
# Ingestion is asynchronous: graph.add returns in ~0.2s with the episode unprocessed, and the text is not searchable until Zep has turned it into nodes and edges. Waku polls until it has, up to this long. Default 120 — raise it if seeding times out, never lower it to make a benchmark finish.
# ZEP_MAX_WAIT_SECONDS=

# ── LangMem ──
# Stores semantic memory in a LangGraph store via LangMem.
# Install: pip install -e '.[arena]'
# Choices: sqlite, langmem.
# WAKU_SEMANTIC_STORE=sqlite
# Optional. Without it LangGraph's InMemoryStore is used, which its own docs describe as a reference implementation whose data dies with the process — fine for a benchmark run, not a persistence story.
# WAKU_LANGMEM_POSTGRES=
# LangMem has no key of its own; it bills through embeddings. Semantic search needs this or the store is a plain key-value dict.
# OPENAI_API_KEY=

# ── Supabase ──
# Stores semantic memory in Supabase pgvector.
# Install: pip install -e '.[supabase]'
# Choices: sqlite, supabase.
# WAKU_SEMANTIC_STORE=sqlite
# SUPABASE_URL=
# Embeddings also require OPENAI_API_KEY (optionally OPENAI_EMBED_MODEL).
# SUPABASE_SERVICE_KEY=

# ── Search & Observability ──

# ── Tavily ──
# Lets Waku search the web.
# Setup: https://tavily.com
# TAVILY_API_KEY=

# ── OpenTelemetry ──
# Exports traces to an OTLP collector.
# Install: pip install -e '.[tracing]'
# OTEL_EXPORTER_OTLP_ENDPOINT=

# END GENERATED CONNECTIONS
"""

suite "phase 5d1 env example":
  test "real render carries header, provider line and every static row":
    let blockText = renderEnvExampleBlock(@[])
    assert blockText.startsWith("# BEGIN GENERATED CONNECTIONS\n" &
      "# Generated by scripts/generate_env_example.py; " &
      "definitions live in waku/integrations.py\n\nWAKU_PROVIDER=anthropic")
    assert blockText.endsWith("# END GENERATED CONNECTIONS\n")
    for row in INTEGRATIONS:
      assert ("# ── " & row.name & " ──") in blockText
      assert ("# " & row.what) in blockText
    assert "# TELEGRAM_BOT_TOKEN=" in blockText
    assert "# Set to 1 to enable." in blockText
    assert "# Choices: sqlite, obsidian." in blockText
    assert "# Install: pip install -e '.[telegram]'" in blockText
    assert "# Setup: https://t.me/BotFather" in blockText
    assert "# WAKU_GOOGLE_CALENDAR_ID=primary" in blockText

  test "golden block for two hand-made providers":
    let providers = @[Provider(name: "demo_ai", keyEnv: "DEMO_AI_KEY"),
                      Provider(name: "waku_thing", keyEnv: "WAKU_THING_KEY",
                               label: "Thing")]
    assert renderEnvExampleBlock(providers) == goldenExpected

suite "phase 5d1 normalize":
  test "positiveInt accepts valid and empty values":
    assert positiveInt(envOf([])) == envOf([])
    assert positiveInt(envOf([("DISCORD_MAX_TURNS_PER_HOUR", "10")])) ==
      envOf([("DISCORD_MAX_TURNS_PER_HOUR", "10")])
    assert positiveInt(envOf([("DISCORD_MAX_TURNS_PER_HOUR", " 10 ")])) ==
      envOf([("DISCORD_MAX_TURNS_PER_HOUR", " 10 ")])

  test "positiveInt rejects non-positive values with the exact message":
    for bad in ["0", "-3", "abc"]:
      try:
        discard positiveInt(envOf([("DISCORD_MAX_TURNS_PER_HOUR", bad)]))
        assert false, "expected ValueError for " & bad
      except ValueError as e:
        assert e.msg == "DISCORD_MAX_TURNS_PER_HOUR must be a positive integer"

## Every temp home this file makes is recorded here and removed before the run
## ends. This suite used to leave all 37 of its `waku-5d2-*` dirs in /tmp on
## every run, with nothing to notice it, so the registry is what makes the
## cleanup possible and the pin at the end of this file is what keeps it.
var tempHomes: seq[string] = @[]

proc tmpDir5d2(name: string): string =
  ## Fresh scratch dir per test: health file, dotenv file and models.json
  ## all live under it, so tests never touch the real home or cwd.
  result = getTempDir() / ("waku-5d2-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)
  tempHomes.add(result)

proc wakuTempDirs(): seq[string] =
  ## Every `/tmp` dir whose name starts with `waku-`, sorted. The pin at the
  ## end of this file compares this against what it held when the run began.
  for kind, path in walkDir(getTempDir()):
    if kind == pcDir and extractFilename(path).startsWith("waku-"):
      result.add(extractFilename(path))
  result.sort()

proc removeTempHomes() =
  ## The run's teardown: it removes every home `tmpDir5d2` made, and it is
  ## the only code in this file that does. `removeDir` does not fail on a dir
  ## that is already gone, so a test that cleaned up early costs nothing. The
  ## registry is deliberately left intact: the pin after the sweep reads it to
  ## prove each home is really gone.
  for home in tempHomes:
    removeDir(home)

## What /tmp held before this run touched it: the pin compares against this.
let wakuTempDirsAtStart = wakuTempDirs()

proc emptyProbes(): Table[string, ProbeFn] =
  initTable[string, ProbeFn]()

proc okProbe(): ProbeFn =
  result = proc(values: Table[string, string]) {.closure.} =
    discard

proc failingProbe(message: string): ProbeFn =
  let msg = message
  result = proc(values: Table[string, string]) {.closure.} =
    raise newException(ValueError, msg)

const testProviders = @[
  Provider(name: "anthropic", keyEnv: "ANTHROPIC_API_KEY",
           model: "claude-x", smallModel: "claude-xs"),
  Provider(name: "openai", keyEnv: "OPENAI_API_KEY"),
  Provider(name: "minimax", keyEnv: "MINIMAX_API_KEY",
           baseUrlEnv: "MINIMAX_BASE_URL",
           baseUrl: "https://api.minimax.example"),
]

suite "phase 5d2 health store":
  test "miss falls back to configured, hit returns the stored status":
    let home = tmpDir5d2("health-hit")
    let store = newHealthStore(home)
    let row = findRow(INTEGRATIONS, "telegram")
    let env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let miss = integrationStatus(row, env, linuxOs, storeHealthFn(store))
    assert miss.state == configured
    recordHealth(store, "telegram", IntegrationStatus(state: connected,
      message: "probe ok", checkedAt: "2026-09-30T00:00:00Z"))
    let hit = integrationStatus(row, env, linuxOs, storeHealthFn(store))
    assert hit.state == connected
    assert hit.message == "probe ok"
    assert hit.checkedAt == "2026-09-30T00:00:00Z"

  test "checked_at defaults to the injected clock, explicit wins":
    let home = tmpDir5d2("health-clock")
    let store = newHealthStore(home)
    recordHealth(store, "tavily",
      IntegrationStatus(state: connected, message: "ok"), "2026-10-01T00:00:00Z")
    let (found, got) = storedHealth(store, "tavily")
    assert found
    assert got.checkedAt == "2026-10-01T00:00:00Z"
    recordHealth(store, "tavily",
      IntegrationStatus(state: connected, checkedAt: "keep-me"))
    let (found2, got2) = storedHealth(store, "tavily")
    assert found2
    assert got2.checkedAt == "keep-me"

  test "entries survive through the file with tmp+replace":
    let home = tmpDir5d2("health-file")
    let store = newHealthStore(home)
    recordHealth(store, "telegram", IntegrationStatus(state: connected,
      message: "ok", checkedAt: "2026-09-30T00:00:00Z"))
    assert fileExists(healthPath(home))
    assert not fileExists(healthPath(home) & ".tmp")
    let raw = readFile(healthPath(home))
    assert "\"telegram\"" in raw
    assert "\"connected\"" in raw
    let reloaded = newHealthStore(home)
    let (found, got) = storedHealth(reloaded, "telegram")
    assert found
    assert got.state == connected
    assert got.message == "ok"
    assert got.checkedAt == "2026-09-30T00:00:00Z"

  test "corrupt file, unknown state and null checked_at degrade gracefully":
    let home = tmpDir5d2("health-corrupt")
    writeFile(healthPath(home), "{nope")
    let broken = newHealthStore(home)
    let (found, gotBroken) = storedHealth(broken, "anything")
    assert not found
    assert gotBroken.state == notConfigured
    writeFile(healthPath(home),
      """{"a": {"state": "bogus", "message": ""}, """ &
      """"b": {"state": "connected", "message": "m", "checked_at": null}}""")
    let lenient = newHealthStore(home)
    let (foundA, gotA) = storedHealth(lenient, "a")
    assert not foundA
    assert gotA.state == notConfigured
    let (foundB, gotB) = storedHealth(lenient, "b")
    assert foundB
    assert gotB.state == connected
    assert gotB.checkedAt == ""

  test "invalidate drops the entry and persists the removal":
    let home = tmpDir5d2("health-invalidate")
    let store = newHealthStore(home)
    recordHealth(store, "telegram",
      IntegrationStatus(state: connected, checkedAt: "t"))
    invalidateHealth(store, "telegram")
    let (found, gotInv) = storedHealth(store, "telegram")
    assert not found
    assert gotInv.state == notConfigured
    assert "telegram" notin readFile(healthPath(home))
    let reloaded = newHealthStore(home)
    let (found2, gotInv2) = storedHealth(reloaded, "telegram")
    assert not found2
    assert gotInv2.state == notConfigured

  test "stores are isolated per home":
    let homeA = tmpDir5d2("health-iso-a")
    let homeB = tmpDir5d2("health-iso-b")
    let storeA = newHealthStore(homeA)
    recordHealth(storeA, "telegram",
      IntegrationStatus(state: connected, checkedAt: "t"))
    let storeB = newHealthStore(homeB)
    let (found, gotIso) = storedHealth(storeB, "telegram")
    assert not found
    assert gotIso.state == notConfigured

suite "phase 5d2 safeError":
  test "secret values are scrubbed, the rest passes through":
    let wa = findRow(INTEGRATIONS, "whatsapp")
    let values = envOf([("WHATSAPP_TOKEN", "secret-token-123"),
                        ("WHATSAPP_PHONE_NUMBER_ID", "pid-9")])
    assert safeError("call with secret-token-123 failed", values, wa) ==
      "call with *** failed"
    assert safeError("secret-token-123", values, wa) == "***"
    assert safeError("call with pid-9 failed", values, wa) ==
      "call with pid-9 failed"

  test "empty message becomes the generic failure":
    let wa = findRow(INTEGRATIONS, "whatsapp")
    assert safeError("", envOf([]), wa) == "connection test failed"

suite "phase 5d2 findIntegration":
  test "static rows resolve, provider rows follow visibility":
    let (found, row) = findIntegration("telegram", @[], envOf([]))
    assert found
    assert row.key == "telegram"
    let seen = @[Provider(name: "seen", keyEnv: "SEEN_API_KEY")]
    let (foundP, rowP) = findIntegration("seen", seen, envOf([]))
    assert foundP
    assert rowP.group == "AI Providers"
    let hid = @[Provider(name: "hid", keyEnv: "HID_API_KEY",
                         baseUrlEnv: "HID_URL", hiddenUnlessEnv: true)]
    let (foundH, _) = findIntegration("hid", hid, envOf([]))
    assert not foundH
    let (foundH2, _) = findIntegration("hid", hid,
      envOf([("HID_URL", "https://proxy.example")]))
    assert foundH2
    let (foundM, _) = findIntegration("missing", @[], envOf([]))
    assert not foundM

suite "phase 5d2 testIntegration":
  test "unknown key raises ValueError":
    let home = tmpDir5d2("test-unknown")
    expect ValueError:
      discard testIntegration("nope", @[], envOf([]),
        newHealthStore(home), emptyProbes(), linuxOs)

  test "disabled integrations keep not-ready states, else drop to configured":
    let home = tmpDir5d2("test-disabled")
    let store = newHealthStore(home)
    let nc = testIntegration("telegram", @[], envOf([]),
      store, emptyProbes(), linuxOs)
    assert nc.status.state == notConfigured
    assert nc.status.message == "integration is disabled"
    let env = envOf([("WAKU_EPISODIC_STORE", "sqlite"),
                     ("WAKU_OBSIDIAN_VAULT", "/vault")])
    let cfg = testIntegration("obsidian", @[], env,
      store, emptyProbes(), linuxOs)
    assert cfg.status.state == configured
    assert cfg.status.message == "integration is disabled"

  test "a row without a probe reports no test available":
    let home = tmpDir5d2("test-noprobe")
    let view = testIntegration("telegram", @[],
      envOf([("TELEGRAM_BOT_TOKEN", "tok")]),
      newHealthStore(home), emptyProbes(), linuxOs)
    assert view.status.state == configured
    assert view.status.message == "no test available"
    assert view.key == "telegram"

  test "a passing probe records connected health":
    let home = tmpDir5d2("test-pass")
    let store = newHealthStore(home)
    var probes = emptyProbes()
    probes["tavily"] = okProbe()
    let view = testIntegration("tavily", @[],
      envOf([("TAVILY_API_KEY", "k")]), store, probes, linuxOs)
    assert view.status.state == connected
    let (found, got) = storedHealth(store, "tavily")
    assert found
    assert got.state == connected

  test "a failing probe records a scrubbed error":
    let home = tmpDir5d2("test-fail")
    let store = newHealthStore(home)
    var probes = emptyProbes()
    probes["tavily"] = failingProbe("bad key SECRETXYZ")
    let view = testIntegration("tavily", @[],
      envOf([("TAVILY_API_KEY", "SECRETXYZ")]), store, probes, linuxOs)
    assert view.status.state == error
    assert view.status.message == "bad key ***"
    let (found, got) = storedHealth(store, "tavily")
    assert found
    assert got.message == "bad key ***"

  test "the probe receives values merged with field defaults":
    let home = tmpDir5d2("test-values")
    let store = newHealthStore(home)
    var seen = initTable[string, string]()
    var probes = emptyProbes()
    probes["obsidian"] = proc(values: Table[string, string]) {.closure.} =
      seen = values
    let env = envOf([("WAKU_EPISODIC_STORE", "obsidian"),
                     ("WAKU_OBSIDIAN_VAULT", "/vault")])
    discard testIntegration("obsidian", @[], env, store, probes, linuxOs)
    assert seen["WAKU_OBSIDIAN_VAULT"] == "/vault"
    assert seen["WAKU_EPISODIC_STORE"] == "obsidian"

suite "phase 5d2 applyIntegration":
  test "unknown key and provider rows are rejected":
    let home = tmpDir5d2("apply-unknown")
    var env = envOf([])
    var res = applyIntegration("nope", envOf([]), @[], env,
      newHealthStore(home), home / ".env", emptyProbes())
    assert not res.ok
    assert res.error == "unknown integration"
    assert not res.canForce
    res = applyIntegration("anthropic", envOf([]), testProviders, env,
      newHealthStore(home), home / ".env", emptyProbes())
    assert not res.ok
    assert res.error == "use apply_provider for AI Providers"

  test "unknown fields in values and clear are rejected":
    let home = tmpDir5d2("apply-fields")
    var env = envOf([])
    var res = applyIntegration("telegram", envOf([("NOPE", "1")]), @[], env,
      newHealthStore(home), home / ".env", emptyProbes())
    assert not res.ok
    assert res.error == "unknown configuration field"
    res = applyIntegration("telegram", envOf([]), @[], env,
      newHealthStore(home), home / ".env", emptyProbes(), @["NOPE"])
    assert not res.ok
    assert res.error == "unknown configuration field"

  test "choice fields validate against their options":
    let home = tmpDir5d2("apply-choice")
    var env = envOf([])
    let res = applyIntegration("obsidian",
      envOf([("WAKU_EPISODIC_STORE", "bogus")]), @[], env,
      newHealthStore(home), home / ".env", emptyProbes())
    assert not res.ok
    assert res.error == "WAKU_EPISODIC_STORE must be one of: sqlite, obsidian"
    assert not res.canForce

  test "normalize failures surface with force allowed":
    let home = tmpDir5d2("apply-normalize")
    var env = envOf([])
    let res = applyIntegration("discord",
      envOf([("DISCORD_BOT_TOKEN", "tok-discord"),
             ("DISCORD_MAX_TURNS_PER_HOUR", "0")]), @[], env,
      newHealthStore(home), home / ".env", emptyProbes())
    assert not res.ok
    assert res.error ==
      "DISCORD_MAX_TURNS_PER_HOUR must be a positive integer"
    assert res.canForce

  test "required fields are enforced only when enabled":
    let home = tmpDir5d2("apply-required")
    var env = envOf([])
    let res = applyIntegration("whatsapp",
      envOf([("WHATSAPP_TOKEN", "t")]), @[], env,
      newHealthStore(home), home / ".env", emptyProbes())
    assert not res.ok
    assert res.error == "missing WHATSAPP_PHONE_NUMBER_ID, " &
      "WHATSAPP_APP_SECRET, WHATSAPP_VERIFY_TOKEN"
    assert not res.canForce

  test "a disabled save writes dotenv and env, skipping required":
    let dir = tmpDir5d2("apply-disabled")
    var env = envOf([("TELEGRAM_ALLOWED_USER", "me")])
    let res = applyIntegration("telegram",
      envOf([("TELEGRAM_ALLOWED_USER", "you")]), @[], env,
      newHealthStore(dir), dir / ".env", emptyProbes(), @[], false, linuxOs)
    assert res.ok, res.error
    assert res.view.key == "telegram"
    assert env["TELEGRAM_ALLOWED_USER"] == "you"
    assert "TELEGRAM_ALLOWED_USER=you" in readFile(dir / ".env")

  test "empty secrets keep their old value, other fields update":
    let dir = tmpDir5d2("apply-secret")
    var env = envOf([("TELEGRAM_BOT_TOKEN", "old"),
                     ("TELEGRAM_ALLOWED_USER", "me")])
    let res = applyIntegration("telegram",
      envOf([("TELEGRAM_BOT_TOKEN", ""),
             ("TELEGRAM_ALLOWED_USER", "you")]), @[], env,
      newHealthStore(dir), dir / ".env", emptyProbes(), @[], false, linuxOs)
    assert res.ok, res.error
    assert env["TELEGRAM_BOT_TOKEN"] == "old"
    assert env["TELEGRAM_ALLOWED_USER"] == "you"
    let text = readFile(dir / ".env")
    assert "TELEGRAM_BOT_TOKEN" notin text
    assert "TELEGRAM_ALLOWED_USER=you" in text

  test "bool fields normalize 0 to empty":
    let dir = tmpDir5d2("apply-bool")
    var env = envOf([])
    let res = applyIntegration("google_calendar",
      envOf([("WAKU_GOOGLE_CALENDAR", "0")]), @[], env,
      newHealthStore(dir), dir / ".env", emptyProbes(), @[], false, linuxOs)
    assert res.ok, res.error
    assert env["WAKU_GOOGLE_CALENDAR"] == ""

  test "clear drops the field from env and dotenv":
    let dir = tmpDir5d2("apply-clear")
    writeFile(dir / ".env",
      "TELEGRAM_BOT_TOKEN=tok\nTELEGRAM_ALLOWED_USER=me\n")
    var env = envOf([("TELEGRAM_BOT_TOKEN", "tok"),
                     ("TELEGRAM_ALLOWED_USER", "me")])
    let res = applyIntegration("telegram", envOf([]), @[], env,
      newHealthStore(dir), dir / ".env", emptyProbes(), @["TELEGRAM_BOT_TOKEN"])
    assert res.ok, res.error
    assert "TELEGRAM_BOT_TOKEN" notin env
    assert "TELEGRAM_BOT_TOKEN" notin readFile(dir / ".env")
    assert "TELEGRAM_ALLOWED_USER=me" in readFile(dir / ".env")

  test "probe failure blocks, force saves with an untested health mark":
    let dir = tmpDir5d2("apply-probe")
    var probes = emptyProbes()
    probes["tavily"] = failingProbe("bad key SECRET1")
    var env = envOf([])
    let blocked = applyIntegration("tavily",
      envOf([("TAVILY_API_KEY", "SECRET1")]), @[], env,
      newHealthStore(dir), dir / ".env", probes, @[], false, linuxOs)
    assert not blocked.ok
    assert blocked.error == "bad key ***"
    assert blocked.canForce
    assert "TAVILY_API_KEY" notin env
    assert not fileExists(dir / ".env")
    let forced = applyIntegration("tavily",
      envOf([("TAVILY_API_KEY", "SECRET1")]), @[], env,
      newHealthStore(dir), dir / ".env", probes, @[], true, linuxOs)
    assert forced.ok, forced.error
    assert env["TAVILY_API_KEY"] == "SECRET1"
    assert forced.view.status.state == error
    assert forced.view.status.message == "Saved without a successful test"

  test "a passing probe records connected and returns the live view":
    let dir = tmpDir5d2("apply-pass")
    let store = newHealthStore(dir)
    var probes = emptyProbes()
    probes["tavily"] = okProbe()
    var env = envOf([])
    let res = applyIntegration("tavily",
      envOf([("TAVILY_API_KEY", "k")]), @[], env,
      store, dir / ".env", probes, @[], false, linuxOs)
    assert res.ok, res.error
    assert res.view.status.state == connected
    let (found, got) = storedHealth(store, "tavily")
    assert found
    assert got.state == connected

  test "agent rebuild failure rolls back file and env":
    let dir = tmpDir5d2("apply-rollback")
    writeFile(dir / ".env", "TELEGRAM_BOT_TOKEN=old\n")
    let store = newHealthStore(dir)
    var env = envOf([("TELEGRAM_BOT_TOKEN", "old")])
    let rebuild: AgentRebuildFn =
      proc(): string {.closure.} =
        "boom REBUILD-FAIL"
    let res = applyIntegration("google_calendar",
      envOf([("WAKU_GOOGLE_CALENDAR", "1")]), @[], env,
      store, dir / ".env", emptyProbes(), @[], false, linuxOs, rebuild)
    assert not res.ok
    assert res.error == "boom REBUILD-FAIL"
    assert readFile(dir / ".env") == "TELEGRAM_BOT_TOKEN=old\n"
    assert "WAKU_GOOGLE_CALENDAR" notin env
    let (found, got) = storedHealth(store, "google_calendar")
    assert found
    assert got.state == error
    assert got.message == "boom REBUILD-FAIL"

  test "gateway reload success records health, error fails and retries":
    let dir = tmpDir5d2("apply-gateway")
    var calls = 0
    let good: GatewayReloadFn =
      proc(keys: seq[string]): Table[string, IntegrationStatus] {.closure.} =
        assert keys == @["discord"]
        result = initTable[string, IntegrationStatus]()
        result["discord"] = IntegrationStatus(state: connected,
          message: "gateway up")
    var env = envOf([])
    let res = applyIntegration("discord",
      envOf([("DISCORD_BOT_TOKEN", "tok-discord")]), @[], env,
      newHealthStore(dir), dir / ".env", emptyProbes(),
      @[], false, linuxOs, nil, good)
    assert res.ok, res.error
    let bad: GatewayReloadFn =
      proc(keys: seq[string]): Table[string, IntegrationStatus] {.closure.} =
        inc calls
        result = initTable[string, IntegrationStatus]()
        result["discord"] = IntegrationStatus(state: error,
          message: "gateway down")
    writeFile(dir / ".env", "")
    var env2 = envOf([])
    let store2 = newHealthStore(dir)
    let failed = applyIntegration("discord",
      envOf([("DISCORD_BOT_TOKEN", "tok-discord")]), @[], env2,
      store2, dir / ".env", emptyProbes(), @[], false, linuxOs, nil, bad)
    assert not failed.ok
    assert failed.error == "gateway down"
    assert calls == 2
    assert "DISCORD_BOT_TOKEN" notin env2
    let (found, got) = storedHealth(store2, "discord")
    assert found
    assert got.state == error

suite "phase 5d2 providerCanServe and adoptable":
  test "canServe needs a known row with a key":
    assert not providerCanServe("nope", testProviders, envOf([]))
    assert not providerCanServe("anthropic", testProviders, envOf([]))
    assert providerCanServe("anthropic", testProviders,
      envOf([("ANTHROPIC_API_KEY", "k")]))

  test "adoptable takes a key while the current provider cannot serve":
    let provs = testProviders
    assert adoptable(provs[0], "k", envOf([]), provs)
    assert not adoptable(provs[0], "", envOf([]), provs)
    assert not adoptable(provs[0], "k",
      envOf([("WAKU_PROVIDER", "anthropic"),
             ("ANTHROPIC_API_KEY", "k")]), provs)

suite "phase 5d2 applyProvider":
  test "unknown provider is rejected":
    let dir = tmpDir5d2("prov-unknown")
    var env = envOf([])
    let res = applyProvider("nope", testProviders, env,
      newHealthStore(dir), dir / ".env", dir)
    assert not res.ok
    assert res.error == "unknown provider"

  test "a new key is probed before it is saved":
    let dir = tmpDir5d2("prov-probe")
    var probed: seq[Table[string, string]] = @[]
    let probe: ProbeFn =
      proc(values: Table[string, string]) {.closure.} =
        probed.add(values)
    var env = envOf([])
    let res = applyProvider("anthropic", testProviders, env,
      newHealthStore(dir), dir / ".env", dir, probe, key = "k1")
    assert res.ok, res.error
    assert env["WAKU_PROVIDER"] == "anthropic"
    assert env["ANTHROPIC_API_KEY"] == "k1"
    assert probed.len == 1
    assert probed[0]["ANTHROPIC_API_KEY"] == "k1"
    assert res.view.status.state == connected
    assert "ANTHROPIC_API_KEY=k1" in readFile(dir / ".env")

  test "reopening an unchanged provider probes nothing":
    let dir = tmpDir5d2("prov-unchanged")
    var probed = 0
    let probe: ProbeFn =
      proc(values: Table[string, string]) {.closure.} =
        inc probed
    var env = envOf([("WAKU_PROVIDER", "anthropic"),
                     ("ANTHROPIC_API_KEY", "k1")])
    let res = applyProvider("anthropic", testProviders, env,
      newHealthStore(dir), dir / ".env", dir, probe)
    assert res.ok, res.error
    assert probed == 0

  test "switching providers defaults the model from the pinned shortlist":
    let dir = tmpDir5d2("prov-switch")
    writeFile(dir / "models.json", """{"pinned": ["openai:gpt-new"]}""")
    var env = envOf([("WAKU_PROVIDER", "anthropic"),
                     ("ANTHROPIC_API_KEY", "k")])
    let res = applyProvider("openai", testProviders, env,
      newHealthStore(dir), dir / ".env", dir, okProbe(), key = "ok1")
    assert res.ok, res.error
    assert env["WAKU_PROVIDER"] == "openai"
    assert env["WAKU_MODEL"] == "gpt-new"
    assert env.getOrDefault("WAKU_SMALL_MODEL", "") == ""

  test "the first key is adopted even when the caller says not to":
    let dir = tmpDir5d2("prov-adopt")
    var env = envOf([])
    let res = applyProvider("anthropic", testProviders, env,
      newHealthStore(dir), dir / ".env", dir, okProbe(),
      key = "k1", activate = false)
    assert res.ok, res.error
    assert env["WAKU_PROVIDER"] == "anthropic"

  test "saving a second provider without activate keeps the current one":
    let dir = tmpDir5d2("prov-noadopt")
    var env = envOf([("WAKU_PROVIDER", "anthropic"),
                     ("ANTHROPIC_API_KEY", "k")])
    let res = applyProvider("openai", testProviders, env,
      newHealthStore(dir), dir / ".env", dir, okProbe(),
      key = "ok1", activate = false)
    assert res.ok, res.error
    assert env["WAKU_PROVIDER"] == "anthropic"
    assert env["OPENAI_API_KEY"] == "ok1"

  test "regional providers keep their endpoint beside the key":
    let dir = tmpDir5d2("prov-baseurl")
    var env = envOf([("WAKU_PROVIDER", "minimax")])
    let res = applyProvider("minimax", testProviders, env,
      newHealthStore(dir), dir / ".env", dir, okProbe(),
      baseUrl = "https://x.example")
    assert res.ok, res.error
    assert env["MINIMAX_BASE_URL"] == "https://x.example"
    assert env.getOrDefault("WAKU_BASE_URL", "") == ""

  test "probe failure keeps the old env and allows force":
    let dir = tmpDir5d2("prov-fail")
    var env = envOf([])
    let res = applyProvider("anthropic", testProviders, env,
      newHealthStore(dir), dir / ".env", dir,
      failingProbe("nope BADKEY"), key = "BADKEY")
    assert not res.ok
    assert res.error == "nope ***"
    assert res.canForce
    assert "WAKU_PROVIDER" notin env
    assert "ANTHROPIC_API_KEY" notin env

  test "force saves without a test and marks the health accordingly":
    let dir = tmpDir5d2("prov-force")
    let store = newHealthStore(dir)
    var env = envOf([("WAKU_PROVIDER", "anthropic"),
                     ("ANTHROPIC_API_KEY", "k1")])
    let res = applyProvider("anthropic", testProviders, env,
      store, dir / ".env", dir, failingProbe("must not run"), force = true)
    assert res.ok, res.error
    let (found, got) = storedHealth(store, "anthropic")
    assert found
    assert got.state == error
    assert got.message == "Saved without a successful test"

suite "phase 5d2 applyProviderDisabled":
  test "disable, re-enable and the current-provider guard":
    let dir = tmpDir5d2("prov-disabled")
    var env = envOf([("WAKU_PROVIDER", "anthropic")])
    let store = newHealthStore(dir)
    var res = applyProviderDisabled("openai", testProviders, env,
      store, dir / ".env", true)
    assert res.ok, res.error
    assert env["WAKU_DISABLED_PROVIDERS"] == "openai"
    assert "WAKU_DISABLED_PROVIDERS=openai" in readFile(dir / ".env")
    res = applyProviderDisabled("anthropic", testProviders, env,
      store, dir / ".env", true)
    assert not res.ok
    assert res.error ==
      "cannot disable the current provider — switch to another provider first"
    res = applyProviderDisabled("openai", testProviders, env,
      store, dir / ".env", false)
    assert res.ok, res.error
    assert env["WAKU_DISABLED_PROVIDERS"] == ""
    res = applyProviderDisabled("nope", testProviders, env,
      store, dir / ".env", true)
    assert not res.ok
    assert res.error == "unknown provider"

  test "the disabled set stays sorted":
    let dir = tmpDir5d2("prov-sorted")
    var env = envOf([("WAKU_PROVIDER", "openai")])
    let store = newHealthStore(dir)
    assert applyProviderDisabled("minimax", testProviders, env,
      store, dir / ".env", true).ok
    assert applyProviderDisabled("anthropic", testProviders, env,
      store, dir / ".env", true).ok
    assert env["WAKU_DISABLED_PROVIDERS"] == "anthropic,minimax"

suite "phase 5d2 connections text":
  test "render carries groups, labels and the checked stamp":
    let text = renderConnections(@[],
      envOf([("TELEGRAM_BOT_TOKEN", "tok")]), linuxOs)
    assert "Channels" in text
    assert "Telegram" in text
    assert "configured" in text
    assert "configured — not tested yet" in text

  test "checked health renders its stamp":
    let health: HealthFn =
      proc(key: string): IntegrationStatus {.closure.} =
        IntegrationStatus(state: connected, message: "probe ok",
                          checkedAt: "2026-09-30")
    let text = renderConnections(@[],
      envOf([("TELEGRAM_BOT_TOKEN", "tok")]), linuxOs, health)
    assert "(checked 2026-09-30)" in text
    assert "connected · probe ok" in text

  test "failed is true only for a configured error":
    assert not connectionsFailed(@[], envOf([]), linuxOs)
    let failing: HealthFn =
      proc(key: string): IntegrationStatus {.closure.} =
        IntegrationStatus(state: error, message: "down")
    assert connectionsFailed(@[],
      envOf([("TELEGRAM_BOT_TOKEN", "tok")]), linuxOs, failing)
    assert not connectionsFailed(@[], envOf([]), linuxOs, failing)

  test "cliMain returns the exit code for the surface":
    assert cliMain(@[], envOf([]), linuxOs) == 0
    let failing: HealthFn =
      proc(key: string): IntegrationStatus {.closure.} =
        IntegrationStatus(state: error, message: "down")
    assert cliMain(@[], envOf([("TELEGRAM_BOT_TOKEN", "tok")]),
                   linuxOs, failing) == 1

## The run's teardown, between the last suite that makes a home and the one
## that checks. It sits at module level so a --filter that skips suites still
## cleans up.
removeTempHomes()

suite "phase 5d2 temp homes":
  test "the run leaves no /tmp waku dir behind":
    # The contract is "no new name": every dir left must be a name that was
    # already there. A leftover this suite made shows up as a new name, and a
    # stale dir from an older run that this run removed is a cleanup, not a
    # failure. The registry loop after it is what still catches a leftover
    # whose name predates the run, which this comparison cannot see.
    for name in wakuTempDirs():
      check name in wakuTempDirsAtStart
    for home in tempHomes:
      check not dirExists(home)
