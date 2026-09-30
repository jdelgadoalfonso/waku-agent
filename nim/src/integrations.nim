## Integrations registry, pure core — port of `waku/integrations.py` (phase 5d1).
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
## - Probes, dotenv apply, health on disk and the CLI surface arrive in 5d2.
##
## Name mapping for the underscored Python helpers: `_configured` is
## `fieldConfigured`, `_status` is `integrationStatus`, `_positive_int` is
## `positiveInt`, `_notion_normalize` is `notionNormalize`, and
## `normalize_database_id` is `normalizeDatabaseId`. Nim identifiers cannot
## start with an underscore.

import std/strutils
import std/tables

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
