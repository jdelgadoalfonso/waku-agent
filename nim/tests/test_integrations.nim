## Phase 5d1 tests: pure integrations-registry core.
## Offline only: env travels as `Table[string, string]`, hostOs is injected,
## health/gateway arrive as closures. No network, no `.waku/` writes, and the
## tests never touch process env or spawn Python.

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
      ("notion", "Memory & Storage"),
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

  test "notion choice options, defaults and normalize marker":
    let row = findRow(INTEGRATIONS, "notion")
    assert row.env[0].kind == choiceField
    assert row.env[0].default == "sqlite"
    assert row.env[0].options == @["sqlite", "notion"]
    assert row.normalize != nil
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

  test "notion store selector compares the store var":
    let row = findRow(INTEGRATIONS, "notion")
    assert row.enabled(envOf([("WAKU_EPISODIC_STORE", "notion")]), linuxOs)
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

# ── Notion ──
# Stores episodic memory in a Notion database.
# Install: pip install -e '.[notion]'
# Setup: https://www.notion.so/my-integrations
# Choices: sqlite, notion.
# WAKU_EPISODIC_STORE=sqlite
# NOTION_TOKEN=
# NOTION_EPISODES_DATABASE_ID=

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
    assert "# Choices: sqlite, notion." in blockText
    assert "# Install: pip install -e '.[telegram]'" in blockText
    assert "# Setup: https://t.me/BotFather" in blockText
    assert "# WAKU_GOOGLE_CALENDAR_ID=primary" in blockText

  test "golden block for two hand-made providers":
    let providers = @[Provider(name: "demo_ai", keyEnv: "DEMO_AI_KEY"),
                      Provider(name: "waku_thing", keyEnv: "WAKU_THING_KEY",
                               label: "Thing")]
    assert renderEnvExampleBlock(providers) == goldenExpected

suite "phase 5d1 normalize":
  test "plain notion id passes through verbatim, stripped":
    assert normalizeDatabaseId("  abc123  ") == "abc123"

  test "notion url extracts the lowercase 32-hex path id":
    assert normalizeDatabaseId(
      "https://www.notion.so/My-Db-ABCDEF1234567890abcdef1234567890?v=1234") ==
      "abcdef1234567890abcdef1234567890"

  test "notion url without an id raises the exact message":
    for url in ["https://www.notion.so/no-id-here", "https://notion.so"]:
      try:
        discard normalizeDatabaseId(url)
        assert false, "expected ValueError for " & url
      except ValueError as e:
        assert e.msg == "Notion database link must include a database ID in its path"

  test "notionNormalize rewrites only the database field":
    var values = envOf([("NOTION_EPISODES_DATABASE_ID",
      "https://www.notion.so/x-ABCDEF1234567890abcdef1234567890"),
      ("NOTION_TOKEN", "tok")])
    values = notionNormalize(values)
    assert values["NOTION_EPISODES_DATABASE_ID"] ==
      "abcdef1234567890abcdef1234567890"
    assert values["NOTION_TOKEN"] == "tok"
    assert notionNormalize(envOf([])) == envOf([])

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
