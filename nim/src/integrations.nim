## Integrations registry plus stateful seams — port of `waku/integrations.py` (phases 5d1+5d2).
##
## Covers the registry types, the 13 static `INTEGRATIONS` rows, the provider
## row derivation, the `_configured`/`_status` state machine, the list views
## and the `.env.example` block renderer. Everything is pure: `env` travels
## as a `Table`, `hostOs` is injected, and health/gateway arrive as closures.
##
## Deliberate divergences from the Python source:
## - No Base URL choice field on provider rows: Nim `Provider` carries no
##   regional endpoints, so every provider row is the single secret key field.
## - No pip-extra installed check in `integrationStatus`: the single Nim
##   binary has no importable extras.
## - Python `None` for `extra`/`importName` is `""` here; `checked_at` None
##   is `""`.
## - Nim `hostOS` names the Mac target "macosx" (Python `sys.platform` says
##   "darwin"); the injected `hostOs` param defaults to `hostOS`.
## - `GatewayStatusFn` returns `(found, status)` because a value-returning
##   closure cannot express Python's `None` fallthrough; `HealthFn` returns
##   the status directly (`nil` = no stored health).
## - Provider visibility is evaluated against the injected `env`, not the
##   process environment `providers.isVisible` reads.
## - Health lives in an injected `HealthStore` (one per home dir) instead of
##   the process-global `_HEALTH`; probes, dotenv edits, the agent rebuild
##   and the gateway reloader all arrive as injected closures, so the whole
##   apply/test path runs offline. `Phase 5d2.`
## - Minimal dotenv writer: `NAME=value` lines, verbatim, no quoting and no
##   `export` preservation (python-dotenv quotes on write). Appended keys go
##   in sorted order for determinism.
## - No pip-extra installed check on the apply path either (single binary).
## - Provider probes are caller-injected per key; the built-in HTTP/catalog
##   probe bodies (`_tavily_probe`, `_provider_probe`, ...) are not ported —
##   wiring to a live client comes with a later phase.
## - `recordHealth` stamps `checked_at` as `%Y-%m-%dT%H:%M:%SZ` (no micros,
##   `Z` instead of `+00:00`); tests inject the clock anyway.
## - The corruption policy is per-entry (a bad row is skipped, the rest
##   loads) where Python aborts the loop mid-file; observable behavior only
##   differs for files with a bad row before good ones.
## - The `cliMain` Waku Memory line is absent: it needs the settings home
##   plus the `waku_memory.status` seam, both outside this unit's surfaces.
## - The apply-path tracer event (`config` provider switch) has no seam
##   and is skipped.
##
## Name mapping for the underscored Python helpers: `_configured` is
## `fieldConfigured`, `_status` is `integrationStatus`, `_positive_int` is
## `positiveInt`, `_notion_normalize` is `notionNormalize`, and
## `normalize_database_id` is `normalizeDatabaseId`. Nim identifiers cannot
## start with an underscore.

import std/algorithm
import std/json
import std/os
import std/strutils
import std/tables
import std/times

import ./catalog
import ./providers

type
  IntegrationState* = enum
    ## Where an integration stands, from empty to proven working.
    ## CONFIGURED exists because "missing its token" and "complete but never
    ## probed" previously collapsed into one state and the dashboard rendered
    ## both as "needs setup" (see the Python `IntegrationState` docstring).
    notConfigured = "not_configured"
    installedButUnconfigured = "installed_but_unconfigured"
    configured = "configured"
    connected = "connected"
    error = "error"

  ReloadMode* = enum
    live = "live"
    agent = "agent"
    gateway = "gateway"

  FieldKind* = enum
    textField = "text"
    boolField = "bool"
    choiceField = "choice"

  EnvField* = object
    name*: string
    label*: string
    kind*: FieldKind = textField
    required*: bool = false
    secret*: bool = false
    default*: string = ""
    options*: seq[string] = @[]
    placeholder*: string = ""
    help*: string = ""
    optionLabels*: seq[string] = @[]

  IntegrationStatus* = object
    state*: IntegrationState
    message*: string = ""
    checkedAt*: string = ""

  EnabledFn* = proc(env: Table[string, string], hostOs: string): bool {.closure.}
  NormalizeFn* = proc(values: Table[string, string]): Table[string, string] {.closure.}
  HealthFn* = proc(key: string): IntegrationStatus {.closure.}
  GatewayStatusFn* = proc(key: string): (bool, IntegrationStatus) {.closure.}

  Integration* = object
    key*: string
    group*: string
    name*: string
    what*: string
    env*: seq[EnvField]
    extra*: string = ""
    importName*: string = ""
    setupUrl*: string = ""
    reload*: ReloadMode = agent
    enabled*: EnabledFn = nil
    normalize*: NormalizeFn = nil

  FieldView* = object
    name*: string
    label*: string
    kind*: FieldKind = textField
    required*: bool = false
    secret*: bool = false
    configured*: bool = false
    last4*: string = ""
    options*: seq[string] = @[]
    value*: string = ""
    help*: string = ""
    optionLabels*: seq[string] = @[]

  IntegrationView* = object
    key*: string
    group*: string
    name*: string
    what*: string
    status*: IntegrationStatus
    fields*: seq[FieldView] = @[]
    installCommand*: string = ""
    setupUrl*: string = ""

  ApplyResult* = object
    ## Filled by `applyIntegration`/`applyProvider` in 5d2; carried here so
    ## the registry types land as one unit.
    ok*: bool
    view*: IntegrationView
    error*: string = ""
    canForce*: bool = false

proc keyEnabled(keyEnv: string): EnabledFn =
  ## Enabled while the row's key var is present, like the `bool(env.get(..))`
  ## lambdas in the Python table.
  let k = keyEnv
  result = proc(env: Table[string, string], hostOs: string): bool {.closure.} =
    env.getOrDefault(k, "").len > 0

proc storeEnabled(varName, backend: string): EnabledFn =
  ## Enabled while a store-selector var names this backend (notion, mem0,
  ## zep, langmem, supabase rows).
  let v = varName
  let b = backend
  result = proc(env: Table[string, string], hostOs: string): bool {.closure.} =
    env.getOrDefault(v, "") == b

proc darwinEnabled(varName: string): EnabledFn =
  ## The `_darwin`/`_darwin_tools` predicates: macOS-only rows that also need
  ## their toggle var. `hostOs` defaults to `hostOS` at the call sites.
  let v = varName
  result = proc(env: Table[string, string], hostOs: string): bool {.closure.} =
    hostOs == "macosx" and env.getOrDefault(v, "").len > 0

proc positiveInt*(values: Table[string, string]): Table[string, string] =
  ## Port of `_positive_int`: the discord row's normalize hook. Raises
  ## `ValueError` with the exact Python message on a non-positive
  ## `DISCORD_MAX_TURNS_PER_HOUR`; empty stays untouched. Strips first:
  ## Python's `int()` ignores surrounding whitespace.
  result = values
  let value = result.getOrDefault("DISCORD_MAX_TURNS_PER_HOUR", "").strip()
  if value.len > 0:
    var ok = false
    try:
      ok = parseInt(value) > 0
    except ValueError:
      ok = false
    if not ok:
      raise newException(ValueError,
        "DISCORD_MAX_TURNS_PER_HOUR must be a positive integer")

proc isHexChar(c: char): bool =
  c in {'0' .. '9', 'a' .. 'f'}

proc normalizeDatabaseId*(value: string): string =
  ## Port of `normalize_database_id` (`waku/memory/episodic/notion_store.py`):
  ## a URL with scheme+netloc yields the bounded 32-hex id from its path
  ## (case-insensitive); anything else passes through verbatim, stripped.
  ## Raises `ValueError` with the exact Python message when a URL has no id.
  let v = value.strip()
  let schemeEnd = v.find("://")
  if schemeEnd > 0 and schemeEnd + 3 < v.len:
    # Scheme + non-empty netloc is a URL, like Python's
    # `parsed.scheme and parsed.netloc` — the id must be in its path.
    let afterScheme = schemeEnd + 3
    let slash = v.find('/', afterScheme)
    if slash <= afterScheme:
      raise newException(ValueError,
        "Notion database link must include a database ID in its path")
    var pathEnd = v.len
    for i in slash ..< v.len:
      if v[i] == '?' or v[i] == '#':
        pathEnd = i
        break
    let path = v[slash ..< pathEnd].toLowerAscii()
    var i = 0
    while i + 32 <= path.len:
      var allHex = true
      for j in 0 ..< 32:
        if not isHexChar(path[i + j]):
          allHex = false
          break
      if allHex:
        let beforeOk = i == 0 or not isHexChar(path[i - 1])
        let afterOk = i + 32 >= path.len or not isHexChar(path[i + 32])
        if beforeOk and afterOk:
          return path[i ..< i + 32]
      inc i
    raise newException(ValueError,
      "Notion database link must include a database ID in its path")
  v

proc notionNormalize*(values: Table[string, string]): Table[string, string] =
  ## Port of `_notion_normalize`: runs the Notion database id through
  ## `normalizeDatabaseId`, leaves every other field alone.
  result = values
  let value = result.getOrDefault("NOTION_EPISODES_DATABASE_ID", "")
  if value.len > 0:
    result["NOTION_EPISODES_DATABASE_ID"] = normalizeDatabaseId(value)

let INTEGRATIONS*: seq[Integration] = @[
  Integration(key: "telegram", group: "Channels", name: "Telegram",
    what: "Lets Waku receive and send Telegram messages.",
    env: @[EnvField(name: "TELEGRAM_BOT_TOKEN", label: "Bot token",
              required: true, secret: true),
            EnvField(name: "TELEGRAM_ALLOWED_USER", label: "Allowed user")],
    extra: "telegram", importName: "telegram",
    setupUrl: "https://t.me/BotFather", reload: gateway,
    enabled: keyEnabled("TELEGRAM_BOT_TOKEN")),
  Integration(key: "discord", group: "Channels", name: "Discord",
    what: "Lets Waku answer in a Discord server.",
    env: @[EnvField(name: "DISCORD_BOT_TOKEN", label: "Bot token",
              required: true, secret: true),
            EnvField(name: "DISCORD_ALLOWED_USER", label: "Allowed user"),
            EnvField(name: "DISCORD_ALLOWED_CHANNEL", label: "Allowed channel"),
            EnvField(name: "DISCORD_REQUIRE_MENTION", label: "Require mention",
              kind: boolField),
            EnvField(name: "DISCORD_MAX_TURNS_PER_HOUR",
              label: "Max turns per hour"),
            EnvField(name: "DISCORD_HOME", label: "Workspace directory")],
    extra: "discord", importName: "discord", setupUrl: "", reload: gateway,
    enabled: keyEnabled("DISCORD_BOT_TOKEN"),
    normalize: (proc(v: Table[string, string]): Table[string, string] {.closure.} =
      positiveInt(v))),
  Integration(key: "whatsapp", group: "Channels", name: "WhatsApp",
    what: "Lets Waku answer WhatsApp messages via the Meta Cloud API.",
    env: @[EnvField(name: "WHATSAPP_TOKEN", label: "Access token",
              required: true, secret: true),
            EnvField(name: "WHATSAPP_PHONE_NUMBER_ID",
              label: "Phone number ID", required: true),
            EnvField(name: "WHATSAPP_APP_SECRET", label: "App secret",
              required: true, secret: true),
            EnvField(name: "WHATSAPP_VERIFY_TOKEN",
              label: "Webhook verify token", required: true, secret: true),
            EnvField(name: "WHATSAPP_ALLOWED_PHONE", label: "Allowed phone",
              help: "Without '+' prefix. Empty = answer anyone.")],
    extra: "whatsapp", importName: "httpx",
    setupUrl: "https://developers.facebook.com/apps", reload: gateway,
    enabled: keyEnabled("WHATSAPP_TOKEN")),
  Integration(key: "google_calendar", group: "Calendar & Productivity",
    name: "Google Calendar",
    what: "Lets Waku create and update Google Calendar events.",
    env: @[EnvField(name: "WAKU_GOOGLE_CALENDAR",
              label: "Enable Google Calendar", kind: boolField),
            EnvField(name: "WAKU_GOOGLE_CALENDAR_ID", label: "Calendar ID",
              default: "primary")],
    extra: "gcal", importName: "googleapiclient",
    setupUrl: "https://developers.google.com/calendar/api/quickstart/python",
    reload: agent, enabled: keyEnabled("WAKU_GOOGLE_CALENDAR")),
  Integration(key: "apple_calendar", group: "Calendar & Productivity",
    name: "Apple Calendar",
    what: "Lets Waku work with Apple Calendar on this Mac.",
    env: @[EnvField(name: "WAKU_APPLE_CALENDAR",
              label: "Enable Apple Calendar", kind: boolField),
            EnvField(name: "WAKU_APPLE_CALENDARS", label: "Calendars")],
    extra: "", importName: "", setupUrl: "", reload: agent,
    enabled: darwinEnabled("WAKU_APPLE_CALENDAR")),
  Integration(key: "apple_tools", group: "Calendar & Productivity",
    name: "Apple Tools",
    what: "Lets Waku use Apple Mail and other local Apple tools.",
    env: @[EnvField(name: "WAKU_APPLE_TOOLS", label: "Enable Apple tools",
              kind: boolField)],
    extra: "", importName: "", setupUrl: "", reload: agent,
    enabled: darwinEnabled("WAKU_APPLE_TOOLS")),
  Integration(key: "notion", group: "Memory & Storage", name: "Notion",
    what: "Stores episodic memory in a Notion database.",
    env: @[EnvField(name: "WAKU_EPISODIC_STORE", label: "Episodic store",
              kind: choiceField, default: "sqlite",
              options: @["sqlite", "notion"]),
            EnvField(name: "NOTION_TOKEN", label: "Integration token",
              required: true, secret: true),
            EnvField(name: "NOTION_EPISODES_DATABASE_ID",
              label: "Episodes database ID", required: true)],
    extra: "notion", importName: "notion_client",
    setupUrl: "https://www.notion.so/my-integrations", reload: agent,
    enabled: storeEnabled("WAKU_EPISODIC_STORE", "notion"),
    normalize: (proc(v: Table[string, string]): Table[string, string] {.closure.} =
      notionNormalize(v))),
  Integration(key: "mem0", group: "Memory & Storage", name: "Mem0",
    what: "Stores semantic memory in the Mem0 service.",
    env: @[EnvField(name: "WAKU_SEMANTIC_STORE", label: "Semantic store",
              kind: choiceField, default: "sqlite",
              options: @["sqlite", "mem0"]),
            EnvField(name: "MEM0_API_KEY", label: "API key", required: true,
              secret: true,
              help: "From app.mem0.ai. The adapter sends infer=False so add() " &
                "always stores — a bake-off against it measures retrieval, " &
                "not Mem0's own extraction step."),
            EnvField(name: "MEM0_USER_ID", label: "User id",
              help: "Defaults to 'waku'. Change it only if several people " &
                "share one Mem0 account.")],
    extra: "arena", importName: "mem0", setupUrl: "", reload: agent,
    enabled: storeEnabled("WAKU_SEMANTIC_STORE", "mem0")),
  Integration(key: "zep", group: "Memory & Storage", name: "Zep",
    what: "Stores semantic memory in a Zep temporal graph.",
    env: @[EnvField(name: "WAKU_SEMANTIC_STORE", label: "Semantic store",
              kind: choiceField, default: "sqlite",
              options: @["sqlite", "zep"]),
            EnvField(name: "ZEP_API_KEY", label: "API key", required: true,
              secret: true,
              help: "From getzep.com. Facts become graph edges with validity " &
                "dates, so a correction supersedes the old value instead of " &
                "ranking beside it — the one backend built for the update test."),
            EnvField(name: "ZEP_USER_ID", label: "User id",
              help: "Defaults to 'waku'. Zep scopes a graph per user."),
            EnvField(name: "ZEP_MAX_WAIT_SECONDS", label: "Max wait (s)",
              help: "Ingestion is asynchronous: graph.add returns in ~0.2s " &
                "with the episode unprocessed, and the text is not searchable " &
                "until Zep has turned it into nodes and edges. Waku polls " &
                "until it has, up to this long. Default 120 — raise it if " &
                "seeding times out, never lower it to make a benchmark finish.")],
    extra: "arena", importName: "zep_cloud", setupUrl: "", reload: agent,
    enabled: storeEnabled("WAKU_SEMANTIC_STORE", "zep")),
  Integration(key: "langmem", group: "Memory & Storage", name: "LangMem",
    what: "Stores semantic memory in a LangGraph store via LangMem.",
    env: @[EnvField(name: "WAKU_SEMANTIC_STORE", label: "Semantic store",
              kind: choiceField, default: "sqlite",
              options: @["sqlite", "langmem"]),
            EnvField(name: "WAKU_LANGMEM_POSTGRES", label: "Postgres URL",
              help: "Optional. Without it LangGraph's InMemoryStore is used, " &
                "which its own docs describe as a reference implementation " &
                "whose data dies with the process — fine for a benchmark run, " &
                "not a persistence story."),
            EnvField(name: "OPENAI_API_KEY", label: "OpenAI key",
              required: true, secret: true,
              help: "LangMem has no key of its own; it bills through " &
                "embeddings. Semantic search needs this or the store is a " &
                "plain key-value dict.")],
    extra: "arena", importName: "langmem", setupUrl: "", reload: agent,
    enabled: storeEnabled("WAKU_SEMANTIC_STORE", "langmem")),
  Integration(key: "supabase", group: "Memory & Storage", name: "Supabase",
    what: "Stores semantic memory in Supabase pgvector.",
    env: @[EnvField(name: "WAKU_SEMANTIC_STORE", label: "Semantic store",
              kind: choiceField, default: "sqlite",
              options: @["sqlite", "supabase"]),
            EnvField(name: "SUPABASE_URL", label: "Project URL",
              required: true),
            EnvField(name: "SUPABASE_SERVICE_KEY", label: "Service key",
              required: true, secret: true,
              help: "Embeddings also require OPENAI_API_KEY (optionally " &
                "OPENAI_EMBED_MODEL).")],
    extra: "supabase", importName: "supabase", setupUrl: "", reload: agent,
    enabled: storeEnabled("WAKU_SEMANTIC_STORE", "supabase")),
  Integration(key: "tavily", group: "Search & Observability", name: "Tavily",
    what: "Lets Waku search the web.",
    env: @[EnvField(name: "TAVILY_API_KEY", label: "API key", secret: true)],
    extra: "", importName: "", setupUrl: "https://tavily.com", reload: live,
    enabled: keyEnabled("TAVILY_API_KEY")),
  Integration(key: "otel", group: "Search & Observability",
    name: "OpenTelemetry", what: "Exports traces to an OTLP collector.",
    env: @[EnvField(name: "OTEL_EXPORTER_OTLP_ENDPOINT",
              label: "OTLP endpoint")],
    extra: "tracing", importName: "opentelemetry", setupUrl: "",
    reload: agent, enabled: keyEnabled("OTEL_EXPORTER_OTLP_ENDPOINT")),
]

proc titleCase*(name: string): string =
  ## Port of `name.replace("_", " ").title()` for provider row names.
  var words: seq[string] = @[]
  for w in name.split('_'):
    if w.len == 0:
      words.add("")
    else:
      words.add(w[0].toUpperAscii() & w[1 .. ^1].toLowerAscii())
  words.join(" ")

proc providerLabel*(p: Provider, name: string): string =
  ## Port of `Provider.label_text`: an explicit row label wins, otherwise the
  ## title-cased row name (only the hosted row sets a label).
  if p.label.len > 0: p.label else: titleCase(name)

proc integrationFromProvider*(p: Provider): Integration =
  ## Port of `_integration_from_provider`: one secret API Key field named
  ## after the row's key var. The Base URL choice field is deliberately
  ## absent — Nim `Provider` carries no regional endpoints.
  let label = providerLabel(p, p.name)
  let keyEnv = p.keyEnv
  Integration(key: p.name, group: "AI Providers", name: label,
    what: "Uses " & label & " models.",
    env: @[EnvField(name: keyEnv, label: "API Key", secret: true)],
    extra: "", importName: "", setupUrl: "", reload: agent,
    enabled: keyEnabled(keyEnv))

proc isVisibleIn*(p: Provider, env: Table[string, string]): bool =
  ## Pure port of `Provider.is_visible`: a `hidden_unless_env` row shows only
  ## while its endpoint var is set in the injected `env`.
  if not p.hiddenUnlessEnv:
    return true
  if p.baseUrlEnv.len == 0:
    return false
  env.getOrDefault(p.baseUrlEnv, "").strip().len > 0

proc providerIntegrations*(providers: seq[Provider],
    env: Table[string, string]): seq[Integration] =
  ## AI Provider rows for visible providers only, in registry order.
  for p in providers:
    if p.isVisibleIn(env):
      result.add(integrationFromProvider(p))

proc registry*(providers: seq[Provider],
    env: Table[string, string]): seq[Integration] =
  ## Provider rows first, then the static `INTEGRATIONS` rows.
  result = providerIntegrations(providers, env) & INTEGRATIONS

proc envExampleProviders*(providers: seq[Provider]): seq[Integration] =
  ## Like `providerIntegrations`, but for the committed `.env.example`, which
  ## must read the same on every machine: a `hidden_unless_env` row is
  ## skipped unconditionally, even one visible on this host right now.
  for p in providers:
    if not p.hiddenUnlessEnv:
      result.add(integrationFromProvider(p))

proc fieldConfigured*(field: EnvField, value: string): bool =
  ## Port of `_configured`: a bool field counts any non-empty, non-"0" value;
  ## every other kind counts any non-empty value.
  if field.kind == boolField:
    value != "" and value != "0"
  else:
    value.len > 0

proc integrationStatus*(integration: Integration, env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): IntegrationStatus =
  ## Port of `_status`: nothing filled in means NOT_CONFIGURED ("macOS only"
  ## for `apple_*` rows off darwin); a missing required field means
  ## INSTALLED_BUT_UNCONFIGURED; a gateway row asks the injected gateway
  ## hook; otherwise the injected health entry wins, defaulting to
  ## CONFIGURED ("configured — not tested yet"). There is intentionally no
  ## pip-extra check — the single binary has no importable extras.
  var anyConfigured = false
  for field in integration.env:
    if fieldConfigured(field, env.getOrDefault(field.name, "")):
      anyConfigured = true
      break
  let enabled = integration.enabled != nil and integration.enabled(env, hostOs)
  if not enabled and not anyConfigured:
    var message = ""
    if integration.key.startsWith("apple_") and hostOs != "macosx":
      message = "macOS only"
    return IntegrationStatus(state: notConfigured, message: message)
  var missing: seq[string] = @[]
  for field in integration.env:
    if field.required and env.getOrDefault(field.name, "").len == 0:
      missing.add(field.name)
  if missing.len > 0:
    return IntegrationStatus(state: installedButUnconfigured,
      message: "missing " & missing.join(", "))
  if integration.reload == gateway and gatewayStatus != nil:
    let (found, status) = gatewayStatus(integration.key)
    if found:
      return status
  if health != nil:
    return health(integration.key)
  IntegrationStatus(state: configured, message: "configured — not tested yet")

proc listIntegrations*(providers: seq[Provider], env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): seq[IntegrationView] =
  ## One view per registry row: secrets surface as `last4` plus the
  ## configured flag (never the value); plain fields surface value-or-default.
  for integration in registry(providers, env):
    var fields: seq[FieldView] = @[]
    for f in integration.env:
      let raw = env.getOrDefault(f.name, "")
      let last4 =
        if not f.secret: ""
        elif raw.len >= 4: raw[^4 .. ^1]
        else: raw
      fields.add(FieldView(name: f.name, label: f.label, kind: f.kind,
        required: f.required, secret: f.secret,
        configured: fieldConfigured(f, raw), last4: last4,
        options: f.options,
        value: (if f.secret: "" else: env.getOrDefault(f.name, f.default)),
        help: f.help, optionLabels: f.optionLabels))
    let installCommand =
      if integration.extra.len > 0:
        "pip install -e '.[" & integration.extra & "]'"
      else: ""
    result.add(IntegrationView(key: integration.key, group: integration.group,
      name: integration.name, what: integration.what,
      status: integrationStatus(integration, env, hostOs, health, gatewayStatus),
      fields: fields, installCommand: installCommand,
      setupUrl: integration.setupUrl))

proc listProviders*(providers: seq[Provider], env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): seq[IntegrationView] =
  ## AI Provider views only.
  for view in listIntegrations(providers, env, hostOs, health, gatewayStatus):
    if view.group == "AI Providers":
      result.add(view)

proc listConnections*(providers: seq[Provider], env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): seq[IntegrationView] =
  ## Every non-provider view: channels, memory, search, productivity.
  for view in listIntegrations(providers, env, hostOs, health, gatewayStatus):
    if view.group != "AI Providers":
      result.add(view)

proc renderEnvExampleBlock*(providers: seq[Provider]): string =
  ## Byte-parity port of `render_env_example_block`: the deterministic
  ## Connections section of `.env.example`, provider rows (hidden rows
  ## unconditionally skipped) then statics, in registry order.
  var lines: seq[string] = @[
    "# BEGIN GENERATED CONNECTIONS",
    "# Generated by scripts/generate_env_example.py; definitions live in waku/integrations.py",
    "",
    "WAKU_PROVIDER=anthropic",
  ]
  var group = ""
  for integration in envExampleProviders(providers) & INTEGRATIONS:
    if integration.group != group:
      group = integration.group
      lines.add("")
      lines.add("# ── " & group & " ──")
    lines.add("")
    lines.add("# ── " & integration.name & " ──")
    lines.add("# " & integration.what)
    if integration.extra.len > 0:
      lines.add("# Install: pip install -e '.[" & integration.extra & "]'")
    if integration.setupUrl.len > 0:
      lines.add("# Setup: " & integration.setupUrl)
    for field in integration.env:
      if field.help.len > 0:
        lines.add("# " & field.help)
      if field.kind == boolField:
        lines.add("# Set to 1 to enable.")
      elif field.kind == choiceField:
        lines.add("# Choices: " & field.options.join(", ") & ".")
      lines.add("# " & field.name & "=" & field.default)
  lines.add("")
  lines.add("# END GENERATED CONNECTIONS")
  lines.add("")
  lines.join("\n")

# ---------------------------------------------------------------------------
# Phase 5d2: stateful seams. Health on disk, injected probes, dotenv apply
# with rollback, provider save/disable and the plain-text connections CLI.
# Every process interaction the Python module hides (os.environ, the dotenv
# file, browser_agent.rebuild, the gateway hooks, the network probes) is an
# explicit parameter here, so tests run fully offline.

type
  ProbeFn* = proc(values: Table[string, string]) {.closure.}
    ## Injected connection test for one integration key. Raises
    ## `CatchableError` on failure. A missing table entry means the row has
    ## no test, like a Python row with `probe=None`. The built-in HTTP
    ## bodies are deliberately not ported: wiring to a live client comes
    ## with a later phase; callers pass stubs (tests) or a real client.

  AgentRebuildFn* = proc(): string {.closure.}
    ## Injected `browser_agent.rebuild`: "" is success, anything else is
    ## the error text (Python returns the error or `None`).

  GatewayReloadFn* = proc(
    keys: seq[string]): Table[string, IntegrationStatus] {.closure.}
    ## Injected `_gateway_reloader`: statuses for the reloaded keys.

  HealthStore* = ref object
    ## File-backed `connections_health.json`. Folds Python's lazy global
    ## `_HEALTH` into one explicit value per home dir, so tests stay
    ## isolated by construction instead of resetting module state.
    home*: string
    loaded*: bool
    entries*: Table[string, IntegrationStatus]

proc newHealthStore*(home: string): HealthStore =
  ## An unloaded store for `home`; the file is read on first access.
  HealthStore(home: home, loaded: false,
              entries: initTable[string, IntegrationStatus]())

proc healthPath*(home: string): string =
  ## Port of `_health_path` minus `load_settings`: the caller owns `home`.
  home / "connections_health.json"

proc parseHealthStatus(node: JsonNode): (bool, IntegrationStatus) =
  ## One decoded file entry. Unknown states and non-objects are skipped
  ## per-entry; a JSON `null`/missing `checked_at` reads back as "".
  var empty: IntegrationStatus
  if node.kind != JObject or not node.hasKey("state") or
      node["state"].kind != JString:
    return (false, empty)
  var state: IntegrationState
  try:
    state = parseEnum[IntegrationState](node["state"].getStr())
  except ValueError:
    return (false, empty)
  var message = ""
  if node.hasKey("message") and node["message"].kind == JString:
    message = node["message"].getStr()
  var checkedAt = ""
  if node.hasKey("checked_at") and node["checked_at"].kind == JString:
    checkedAt = node["checked_at"].getStr()
  (true, IntegrationStatus(state: state, message: message,
                           checkedAt: checkedAt))

proc loadHealth*(store: HealthStore) =
  ## Lazy read of the health file. Any failure (missing file, bad JSON,
  ## wrong shape) leaves the store empty, like `_health` swallowing
  ## `OSError`/`ValueError`/`KeyError`/`JSONDecodeError`.
  if store.loaded:
    return
  store.loaded = true
  var raw = ""
  try:
    raw = readFile(healthPath(store.home))
  except CatchableError:
    return
  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError:
    return
  if data.kind != JObject:
    return
  for key, node in data:
    let (ok, status) = parseHealthStatus(node)
    if ok:
      store.entries[key] = status

proc saveHealth*(store: HealthStore) =
  ## Tmp-file-plus-replace write, like `_save_health`; `OSError` is
  ## swallowed. `checked_at` writes back as JSON `null` when empty, so a
  ## Nim-written file still reads as "never checked" from Python.
  var data = newJObject()
  for key, status in store.entries:
    var node = newJObject()
    node["state"] = %($status.state)
    node["message"] = %status.message
    if status.checkedAt.len > 0:
      node["checked_at"] = %status.checkedAt
    else:
      node["checked_at"] = newJNull()
    data[key] = node
  try:
    createDir(store.home)
    let path = healthPath(store.home)
    let tmp = changeFileExt(path, "tmp")
    writeFile(tmp, $data)
    moveFile(tmp, path)
  except OSError:
    discard

proc nowUtcIso(): string =
  ## `checked_at` stamp for fresh records. Format differs from Python's
  ## `datetime.now(UTC).isoformat()` (no micros, `Z` suffix); tests inject
  ## the clock through `nowIso` instead of depending on this.
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss") & "Z"

proc recordHealth*(store: HealthStore, key: string, status: IntegrationStatus,
    nowIso = "") =
  ## Port of `record_health`: keeps an explicit `checked_at`, otherwise
  ## stamps now, then persists.
  store.loadHealth()
  let checkedAt =
    if status.checkedAt.len > 0: status.checkedAt
    elif nowIso.len > 0: nowIso
    else: nowUtcIso()
  store.entries[key] = IntegrationStatus(state: status.state,
    message: status.message, checkedAt: checkedAt)
  store.saveHealth()

proc invalidateHealth*(store: HealthStore, key: string) =
  ## Port of `invalidate_health`: drop the entry and persist.
  store.loadHealth()
  store.entries.del(key)
  store.saveHealth()

proc storedHealth*(store: HealthStore, key: string): (bool, IntegrationStatus) =
  ## Read one entry; `false` means no stored health for `key`.
  store.loadHealth()
  if key in store.entries:
    (true, store.entries[key])
  else:
    var empty: IntegrationStatus
    (false, empty)

proc storeHealthFn*(store: HealthStore): HealthFn =
  ## The store as the `HealthFn` seam `integrationStatus` already takes. A
  ## miss answers the CONFIGURED fallback itself, mirroring `_health().get`
  ## with its default — so a store-backed status never changes what 5d1
  ## renders for a fresh checkout.
  result = proc(key: string): IntegrationStatus {.closure.} =
    let (found, status) = storedHealth(store, key)
    if found:
      status
    else:
      IntegrationStatus(state: configured,
                        message: "configured — not tested yet")

proc safeError*(message: string, values: Table[string, string],
    integration: Integration): string =
  ## Port of `_safe_error`: every secret value is scrubbed to `***` before
  ## the message reaches a view. An empty message becomes the generic
  ## failure, like Python's `or "connection test failed"`.
  var scrubbed = message
  for field in integration.env:
    if field.secret:
      let secret = values.getOrDefault(field.name, "")
      if secret.len > 0:
        scrubbed = scrubbed.replace(secret, "***")
  if scrubbed.len > 0:
    scrubbed
  else:
    "connection test failed"

proc findIntegration*(key: string, providers: seq[Provider],
    env: Table[string, string]): (bool, Integration) =
  ## Port of `_find_integration`: registry lookup with provider visibility
  ## evaluated against the injected `env`.
  for integration in registry(providers, env):
    if integration.key == key:
      return (true, integration)
  var empty: Integration
  (false, empty)

proc currentView(key: string, providers: seq[Provider],
    env: Table[string, string], store: HealthStore, hostOs: string,
    gatewayStatus: GatewayStatusFn): IntegrationView =
  ## Port of `_current_view`: rebuild the row's view from the caller's
  ## (possibly just mutated) env and the store.
  for view in listIntegrations(providers, env, hostOs,
      storeHealthFn(store), gatewayStatus):
    if view.key == key:
      return view
  var empty: IntegrationView
  empty

proc failResult(error: string, canForce = false): ApplyResult =
  ## A failed apply: no view, just the message (and whether retrying with
  ## `force` could skip the failing test).
  var empty: IntegrationView
  ApplyResult(ok: false, view: empty, error: error, canForce: canForce)

proc dotenvKeyOf(line: string): string =
  ## The variable a dotenv line sets, or "" for blanks, comments and
  ## keyless lines. `export NAME=...` counts as NAME.
  var s = line.strip()
  if s.startsWith("export "):
    s = s[7 .. ^1].strip()
  if s.len == 0 or s.startsWith("#"):
    return ""
  let eq = s.find('=')
  if eq <= 0:
    return ""
  s[0 ..< eq].strip()

proc applyDotenvEdits(path: string, updates: Table[string, string],
    clear: seq[string]) =
  ## Minimal dotenv set/unset: rewrite matching `NAME=` lines in place,
  ## append missing names in sorted order, drop cleared names, keep every
  ## other byte. A no-op edit leaves the file (and its absence) alone.
  if updates.len == 0 and clear.len == 0:
    return
  var lines: seq[string] = @[]
  if fileExists(path):
    let text = readFile(path)
    lines = text.split('\n')
    if lines.len > 0 and lines[^1] == "":
      discard lines.pop()
  var seen: seq[string] = @[]
  var kept: seq[string] = @[]
  for line in lines:
    let name = dotenvKeyOf(line)
    if name.len > 0 and name in clear:
      continue
    if name.len > 0 and name in updates:
      if name notin seen:
        seen.add(name)
        kept.add(name & "=" & updates[name])
      continue
    kept.add(line)
  var missing: seq[string] = @[]
  for name in updates.keys:
    if name notin seen:
      missing.add(name)
  missing.sort()
  for name in missing:
    kept.add(name & "=" & updates[name])
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)
  var text = kept.join("\n")
  if kept.len > 0:
    text.add("\n")
  writeFile(path, text)

proc snapshotEnv(env: Table[string, string],
    names: seq[string]): (Table[string, string], seq[string]) =
  ## Pre-write env values plus the names that were absent, for rollback.
  var before = initTable[string, string]()
  var wasMissing: seq[string] = @[]
  for name in names:
    if name in env:
      before[name] = env[name]
    else:
      wasMissing.add(name)
  (before, wasMissing)

proc restoreEnv(env: var Table[string, string],
    before: Table[string, string], wasMissing: seq[string]) =
  ## Port of `_restore`'s environment half: put every touched var back.
  for name in wasMissing:
    env.del(name)
  for name, value in before:
    env[name] = value

proc testIntegration*(key: string, providers: seq[Provider],
    env: Table[string, string], store: HealthStore,
    probes: Table[string, ProbeFn], hostOs: string = hostOS,
    gatewayStatus: GatewayStatusFn = nil): IntegrationView =
  ## Port of `test_integration`. A disabled row keeps its not-ready states
  ## and otherwise drops to CONFIGURED; a row with no injected probe reports
  ## "no test available"; otherwise the probe runs against env-merged values
  ## and its outcome is recorded. Unknown keys raise `ValueError`.
  let (found, integration) = findIntegration(key, providers, env)
  if not found:
    raise newException(ValueError, "unknown integration")
  var values = initTable[string, string]()
  for field in integration.env:
    values[field.name] = env.getOrDefault(field.name, field.default)
  let enabled =
    integration.enabled != nil and integration.enabled(values, hostOs)
  if not enabled:
    let view = currentView(key, providers, env, store, hostOs, gatewayStatus)
    let state =
      if view.status.state == notConfigured or
          view.status.state == installedButUnconfigured:
        view.status.state
      else:
        configured
    return IntegrationView(key: view.key, group: view.group, name: view.name,
      what: view.what,
      status: IntegrationStatus(state: state,
        message: "integration is disabled",
        checkedAt: view.status.checkedAt),
      fields: view.fields, installCommand: view.installCommand,
      setupUrl: view.setupUrl)
  if key notin probes:
    let view = currentView(key, providers, env, store, hostOs, gatewayStatus)
    return IntegrationView(key: view.key, group: view.group, name: view.name,
      what: view.what,
      status: IntegrationStatus(state: view.status.state,
        message: "no test available", checkedAt: view.status.checkedAt),
      fields: view.fields, installCommand: view.installCommand,
      setupUrl: view.setupUrl)
  var probed = false
  try:
    probes[key](values)
    probed = true
  except CatchableError as exc:
    recordHealth(store, key, IntegrationStatus(state: error,
      message: safeError(exc.msg, values, integration)))
  if probed:
    recordHealth(store, key, IntegrationStatus(state: connected))
  currentView(key, providers, env, store, hostOs, gatewayStatus)

proc applyIntegration*(key: string, values: Table[string, string],
    providers: seq[Provider], env: var Table[string, string],
    store: HealthStore, dotenvPath: string, probes: Table[string, ProbeFn],
    clear: seq[string] = @[], force: bool = false, hostOs: string = hostOS,
    rebuild: AgentRebuildFn = nil, gatewayReload: GatewayReloadFn = nil,
    gatewayStatus: GatewayStatusFn = nil): ApplyResult =
  ## Port of `apply_integration`: validate names, fold values over
  ## env-plus-defaults (empty secrets keep their stored value, bools fold to
  ## "1"/"", choices validate), run the row normalize, enforce
  ## required-when-enabled, probe unless `force`, then write the minimal
  ## dotenv diff, run the reload hook and record health. Reload/rebuild
  ## failures restore the file and the env, record ERROR health and retry
  ## the gateway once — exactly the Python rollback shape.
  let (found, integration) = findIntegration(key, providers, env)
  if not found:
    return failResult("unknown integration")
  if integration.group == "AI Providers":
    return failResult("use apply_provider for AI Providers")
  var fields = initTable[string, EnvField]()
  for field in integration.env:
    fields[field.name] = field
  for name in values.keys:
    if name notin fields:
      return failResult("unknown configuration field")
  for name in clear:
    if name notin fields:
      return failResult("unknown configuration field")
  var merged = initTable[string, string]()
  for field in integration.env:
    merged[field.name] = env.getOrDefault(field.name, field.default)
  var updates = initTable[string, string]()
  for name, raw in values:
    let field = fields[name]
    var value = raw
    if field.secret and value.len == 0:
      continue
    if field.kind == boolField:
      let s = value.strip()
      value = if s.len > 0 and s != "0": "1" else: ""
    elif field.kind == choiceField and value notin field.options:
      return failResult(name & " must be one of: " & field.options.join(", "))
    merged[name] = value
    updates[name] = value
  for name in clear:
    merged[name] = ""
    updates.del(name)
  var tested = false
  try:
    if integration.normalize != nil:
      merged = integration.normalize(merged)
      var rekeyed = initTable[string, string]()
      for name in updates.keys:
        rekeyed[name] = merged.getOrDefault(name, "")
      updates = rekeyed
    let enabled =
      integration.enabled != nil and integration.enabled(merged, hostOs)
    if enabled:
      var missing: seq[string] = @[]
      for field in integration.env:
        if field.required and merged.getOrDefault(field.name, "").len == 0:
          missing.add(field.name)
      if missing.len > 0:
        return failResult("missing " & missing.join(", "))
    if enabled and key in probes and not force:
      probes[key](merged)
      tested = true
  except CatchableError as exc:
    return failResult(safeError(exc.msg, merged, integration), true)
  var changed: seq[string] = @[]
  for name in updates.keys:
    changed.add(name)
  for name in clear:
    if name notin changed:
      changed.add(name)
  let existed = fileExists(dotenvPath)
  let contents = if existed: readFile(dotenvPath) else: ""
  let (before, wasMissing) = snapshotEnv(env, changed)
  try:
    invalidateHealth(store, key)
    applyDotenvEdits(dotenvPath, updates, clear)
    for name, value in updates:
      env[name] = value
    for name in clear:
      env.del(name)
    if integration.reload == agent and rebuild != nil:
      let err = rebuild()
      if err.len > 0:
        raise newException(CatchableError, err)
    elif integration.reload == gateway and gatewayReload != nil:
      let statuses = gatewayReload(@[key])
      if key in statuses:
        let status = statuses[key]
        if status.state == error:
          raise newException(CatchableError,
            if status.message.len > 0: status.message
            else: "gateway failed to start")
        recordHealth(store, key, status)
    if force:
      recordHealth(store, key, IntegrationStatus(state: error,
        message: "Saved without a successful test"))
    elif tested or integration.reload == gateway:
      recordHealth(store, key, IntegrationStatus(state: connected))
  except CatchableError as exc:
    if existed:
      writeFile(dotenvPath, contents)
    else:
      try:
        removeFile(dotenvPath)
      except CatchableError:
        discard
    restoreEnv(env, before, wasMissing)
    recordHealth(store, key, IntegrationStatus(state: error,
      message: safeError(exc.msg, merged, integration)))
    if integration.reload == gateway and gatewayReload != nil:
      discard gatewayReload(@[key])
    return failResult(safeError(exc.msg, merged, integration))
  ApplyResult(ok: true,
    view: currentView(key, providers, env, store, hostOs, gatewayStatus))

proc providerCanServe*(name: string, providers: seq[Provider],
    env: Table[string, string]): bool =
  ## Port of `_provider_can_serve`: the row exists and its key var is set —
  ## the same test the Models grid colours a card with.
  for p in providers:
    if p.name == name:
      return env.getOrDefault(p.keyEnv, "").len > 0
  false

proc adoptable*(selected: Provider, key: string, env: Table[string, string],
    providers: seq[Provider]): bool =
  ## Port of `_adoptable`: a save carries a key while the current provider
  ## cannot serve a turn — the first working key becomes current.
  key.len > 0 and not providerCanServe(
    env.getOrDefault("WAKU_PROVIDER", ""), providers, env)

proc selectedBaseUrl(p: Provider, env: Table[string, string]): string =
  ## The provider-scoped endpoint against the injected env, falling back to
  ## the row default — like `catalog.configuredBaseUrl`, which reads the
  ## process env and so cannot serve this offline path.
  let override = env.getOrDefault(p.baseUrlEnv, "").strip()
  if override.len > 0:
    override
  else:
    p.baseUrl

proc stripSlash(s: string): string =
  var i = s.len
  while i > 0 and s[i - 1] == '/':
    dec i
  s[0 ..< i]

proc applyProvider*(provider: string, providers: seq[Provider],
    env: var Table[string, string], store: HealthStore,
    dotenvPath, home: string, probe: ProbeFn = nil,
    key = "", model = "", smallModel = "", baseUrl = "",
    customKey = "", force = false, activate = true,
    rebuild: AgentRebuildFn = nil, agentActive = false,
    hostOs: string = hostOS,
    gatewayStatus: GatewayStatusFn = nil): ApplyResult =
  ## Port of `apply_provider`: save provider fields and optionally make
  ## that provider active. A newly supplied key is probed before anything
  ## is persisted ("" means "argument absent" for every optional); a first
  ## working key is adopted even under `activate=false`; switching resets
  ## the model to `catalog.defaultModelFor` and clears the small model. The
  ## agent rebuild only runs for the live agent behind the `agentActive`
  ## seam, and the `config` tracer event has no seam here — it is skipped.
  var selected = Provider()
  var known = false
  for p in providers:
    if p.name == provider:
      selected = p
      known = true
      break
  if not known:
    return failResult("unknown provider")
  let previous = env.getOrDefault("WAKU_PROVIDER", "")
  var active = activate
  if not active and adoptable(selected, key, env, providers):
    active = true
  let switching = active and provider != previous
  var updates = initTable[string, string]()
  if active:
    updates["WAKU_PROVIDER"] = provider
  if model.len > 0:
    updates["WAKU_MODEL"] = model
  elif switching:
    updates["WAKU_MODEL"] = defaultModelFor(provider, home, providers)
  if smallModel.len > 0:
    updates["WAKU_SMALL_MODEL"] = smallModel
  elif switching:
    updates["WAKU_SMALL_MODEL"] = ""
  if key.len > 0 and selected.keyEnv.len > 0:
    updates[selected.keyEnv] = key
  if selected.baseUrlEnv.len > 0 and (baseUrl.len > 0 or switching):
    let legacy =
      if provider == previous: env.getOrDefault("WAKU_BASE_URL", "")
      else: ""
    var candidate = baseUrl
    if candidate.len == 0:
      candidate = legacy
    if candidate.len == 0:
      candidate = selectedBaseUrl(selected, env)
    candidate = candidate.strip()
    if candidate.len > 0:
      updates[selected.baseUrlEnv] = candidate
    updates["WAKU_BASE_URL"] = ""
  elif baseUrl.len > 0:
    updates["WAKU_BASE_URL"] = baseUrl
  if customKey.len > 0:
    updates["WAKU_API_KEY"] = customKey
  let currentKey = env.getOrDefault(selected.keyEnv, "")
  let legacyBase =
    if provider == previous: env.getOrDefault("WAKU_BASE_URL", "")
    else: ""
  var currentBase = legacyBase
  if currentBase.len == 0:
    currentBase = selectedBaseUrl(selected, env)
  var candidateBase = currentBase
  if selected.baseUrlEnv.len > 0:
    candidateBase = updates.getOrDefault(selected.baseUrlEnv, currentBase)
  elif "WAKU_BASE_URL" in updates:
    candidateBase = updates["WAKU_BASE_URL"]
  let keyChanged = key.len > 0 and key != currentKey
  let baseChanged = baseUrl.len > 0 and
    stripSlash(candidateBase) != stripSlash(currentBase)
  var changed = initTable[string, string]()
  for name, value in updates:
    if env.getOrDefault(name, "") != value:
      changed[name] = value
  let existed = fileExists(dotenvPath)
  let contents = if existed: readFile(dotenvPath) else: ""
  var changedNames: seq[string] = @[]
  for name in changed.keys:
    changedNames.add(name)
  let (before, wasMissing) = snapshotEnv(env, changedNames)
  try:
    let candidateKey =
      if key.len > 0: key
      else: currentKey
    if candidateKey.len > 0 and (keyChanged or baseChanged) and not force and
        probe != nil:
      var probeValues = initTable[string, string]()
      probeValues[selected.keyEnv] = candidateKey
      if selected.baseUrlEnv.len > 0 and selected.baseUrlEnv in updates:
        probeValues[selected.baseUrlEnv] = updates[selected.baseUrlEnv]
        probeValues["WAKU_BASE_URL"] = ""
      elif baseUrl.len > 0:
        probeValues["WAKU_BASE_URL"] = baseUrl
      probe(probeValues)
    if changed.len > 0:
      applyDotenvEdits(dotenvPath, changed, @[])
      for name, value in changed:
        env[name] = value
    let affectsAgent =
      changed.len > 0 and (provider == previous or active)
    if affectsAgent and agentActive and rebuild != nil:
      let err = rebuild()
      if err.len > 0:
        raise newException(CatchableError, err)
    if force:
      recordHealth(store, provider, IntegrationStatus(state: error,
        message: "Saved without a successful test"))
    else:
      recordHealth(store, provider, IntegrationStatus(state: connected))
  except CatchableError as exc:
    if existed:
      writeFile(dotenvPath, contents)
    else:
      try:
        removeFile(dotenvPath)
      except CatchableError:
        discard
    restoreEnv(env, before, wasMissing)
    let (okRow, row) = findIntegration(provider, providers, env)
    let scrubRow =
      if okRow: row
      elif providers.len > 0: integrationFromProvider(providers[0])
      else: INTEGRATIONS[0]
    return failResult(safeError(exc.msg, changed, scrubRow),
                      key.len > 0 or currentKey.len > 0)
  ApplyResult(ok: true,
    view: currentView(provider, providers, env, store, hostOs, gatewayStatus))

proc applyProviderDisabled*(provider: string, providers: seq[Provider],
    env: var Table[string, string], store: HealthStore, dotenvPath: string,
    disabled: bool, hostOs: string = hostOS,
    gatewayStatus: GatewayStatusFn = nil): ApplyResult =
  ## Port of `apply_provider_disabled`: hide a provider from pickers while
  ## keeping its key. The active provider cannot be disabled.
  var known = false
  for p in providers:
    if p.name == provider:
      known = true
      break
  if not known:
    return failResult("unknown provider")
  if disabled and env.getOrDefault("WAKU_PROVIDER", "") == provider:
    return failResult("cannot disable the current provider — " &
      "switch to another provider first")
  var current: seq[string] = @[]
  for part in env.getOrDefault("WAKU_DISABLED_PROVIDERS", "").split(','):
    let name = part.strip()
    if name.len > 0:
      current.add(name)
  if disabled:
    if provider notin current:
      current.add(provider)
  else:
    var kept: seq[string] = @[]
    for name in current:
      if name != provider:
        kept.add(name)
    current = kept
  current.sort()
  let joined = current.join(",")
  var updates = initTable[string, string]()
  updates["WAKU_DISABLED_PROVIDERS"] = joined
  applyDotenvEdits(dotenvPath, updates, @[])
  env["WAKU_DISABLED_PROVIDERS"] = joined
  ApplyResult(ok: true,
    view: currentView(provider, providers, env, store, hostOs, gatewayStatus))

proc renderConnections*(providers: seq[Provider], env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): string =
  ## Port of `cli_main`'s listing in plain text (the Nim CLI has no rich):
  ## groups as headers, one `name state · detail (checked …)` line per row.
  var lines: seq[string] = @[]
  var group = ""
  for view in listIntegrations(providers, env, hostOs, health, gatewayStatus):
    if view.group != group:
      group = view.group
      lines.add("")
      lines.add(group)
    let label = ($view.status.state).replace("_", " ")
    var detail = ""
    if view.status.state != notConfigured and
        view.status.message.len > 0:
      detail = " · " & view.status.message
    var checked = ""
    if view.status.checkedAt.len > 0:
      checked = " (checked " & view.status.checkedAt & ")"
    lines.add("  " & view.name.alignLeft(20) & " " & label & detail & checked)
  lines.join("\n")

proc connectionsFailed*(providers: seq[Provider], env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): bool =
  ## Port of `cli_main`'s exit rule: an ERROR row with configured fields
  ## fails the command.
  for view in listIntegrations(providers, env, hostOs, health, gatewayStatus):
    if view.status.state == error:
      for field in view.fields:
        if field.configured:
          return true
  false

proc cliMain*(providers: seq[Provider], env: Table[string, string],
    hostOs: string = hostOS, health: HealthFn = nil,
    gatewayStatus: GatewayStatusFn = nil): int =
  ## Print the connections surface; 1 when a configured row is in ERROR.
  ## The Waku Memory line is out of scope here (see the module header).
  echo renderConnections(providers, env, hostOs, health, gatewayStatus)
  if connectionsFailed(providers, env, hostOs, health, gatewayStatus):
    1
  else:
    0
