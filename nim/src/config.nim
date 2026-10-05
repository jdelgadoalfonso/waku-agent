## Configuration — every knob is an env var, documented in `.env.example`.
##
## Phase 0 port of the `waku/config.py` subset: the `Settings` object, the
## `WAKU_*` env overrides and a small `.env` line parser. No settings
## framework: a plain object read once at startup. If you can read this file,
## you know everything the port can be configured to do so far.
##
## Phase 4b extends the loop/session subset (small_model, max_iterations,
## max_tokens, history_turns, graph_workflows). Gateway and store switches
## (telegram, whatsapp, apple_*, semantic/episodic stores) stay Python-only
## until their phases.

import std/os
import std/strutils
import std/syncio

const
  defaultMaxIterations* = 10
    ## Loop guardrail (`WAKU_MAX_ITERATIONS`).
  defaultMaxTokens* = 8192
    ## Output ceiling with headroom for reasoning models (`WAKU_MAX_TOKENS`).
  defaultHistoryTurns* = 12
    ## Sliding working-memory window in turns (`WAKU_HISTORY_TURNS`).

type
  Settings* = object
    ## Where the LLM, the keys and the state directory live.
    provider*: string
      ## LLM provider id (a row in `waku/providers.toml`, see `waku/loop/models.py`).
    apiKey*: string
      ## Explicit `WAKU_API_KEY` override. Empty means the provider's own
      ## key env var and default models are used.
    model*: string
      ## Explicit `WAKU_MODEL` override. Empty means the provider's
      ## default models are used.
    home*: string
      ## `WAKU_HOME`: where Waku keeps its state (memory DB, calendar,
      ## outbox, traces). Local-first means you can always look.
    smallModel*: string
      ## `WAKU_SMALL_MODEL`: cheap model for the retrieval gate and the
      ## consolidation summarizer. Empty means the provider default.
    baseUrl*: string
      ## `WAKU_BASE_URL`: global endpoint override for BYOK. Never leaks
      ## into a scoped-credentials row's own endpoint (see client.nim).
    maxIterations*: int
      ## `WAKU_MAX_ITERATIONS` (default 10): loop guardrail.
    maxTokens*: int
      ## `WAKU_MAX_TOKENS` (default 8192): output ceiling with headroom
      ## for reasoning models — a ceiling, not a target.
    historyTurns*: int
      ## `WAKU_HISTORY_TURNS` (default 12): working memory is a sliding
      ## window of the last N turns; older turns live in state.db.
    retrievalTopK*: int
      ## `WAKU_RETRIEVAL_TOP_K` (default 4): facts per gated retrieval.
    experimental*: bool
      ## `WAKU_EXPERIMENTAL`: register `delegate_task` (pi sub-agent)
      ## plus the coming-soon stubs. Trust this flag alone (never OR
      ## the env at registry time): the arena passes per-race values.
    appleTools*: bool
      ## `WAKU_APPLE_TOOLS` (macOS): Calendar/Mail/Reminders/Notes
      ## readers via osascript. First use triggers the system
      ## Automation prompts.
    ghTool*: bool
      ## `WAKU_GH_TOOL`: read-only GitHub via the `gh` CLI's own auth.
      ## Off by default on purpose: every registered tool ships in
      ## every prompt, and PR reading is maintainer capability.
    ghRepo*: string
      ## `WAKU_GH_REPO`: owner/name when a call omits it (running
      ## outside a checkout, where `gh` infers no remote).
    graphWorkflows*: bool
      ## `WAKU_GRAPH_WORKFLOWS`: route messages through the triage graph
      ## first (fail-open to the plain loop, so never worse).
    consolidateEvery*: int
      ## `WAKU_CONSOLIDATE_EVERY` (default 6): exchanges between memory
      ## consolidations; the dashboard shows it and doubles it as the
      ## trigger threshold.
    semanticStore*: string
      ## `WAKU_SEMANTIC_STORE`: where facts live. `sqlite` (default, zero
      ## setup), `mem0` or `zep` (the hosted services). Python reads the same
      ## var in `config.py` and dispatches in `waku/memory/__init__.py`.
    mem0UserId*: string
      ## `MEM0_USER_ID`: the person mem0 scopes memories to. Defaults to
      ## `waku`, and an EMPTY value falls back to the default rather than
      ## scoping the memory to "" — the Connections form writes optional
      ## fields even when you leave them blank, so `getenv(name, default)`
      ## is wrong here and Python's `env_or` is the port.
    zepUserId*: string
      ## `ZEP_USER_ID`: the person Zep scopes the graph to. Same empty-means-
      ## default rule as `mem0UserId`: a blank Connections field must fall
      ## back to `waku`, not scope the graph to "".
    otelEndpoint*: string
      ## `OTEL_EXPORTER_OTLP_ENDPOINT`: an OTLP collector as `host:port`
      ## (Python's `Settings.otel_endpoint`). Empty means JSONL traces
      ## only, which is the default: the exporter is opt-in and costs
      ## nothing until it is named. The port POSTs to
      ## `http://host:port/v1/traces`, so a Phoenix collector is 6006,
      ## not the 4317 the gRPC default in Python's SDK would use.

proc defaultSettings*(): Settings =
  ## Settings before any env var is read (the Python dataclass defaults).
  Settings(provider: "anthropic", apiKey: "", model: "", home: ".waku",
           smallModel: "", baseUrl: "",
           maxIterations: defaultMaxIterations,
           maxTokens: defaultMaxTokens, historyTurns: defaultHistoryTurns,
           graphWorkflows: false, consolidateEvery: 6, retrievalTopK: 4,
           experimental: false, appleTools: false, ghTool: false,
           ghRepo: "", semanticStore: "sqlite", mem0UserId: "waku",
           zepUserId: "waku", otelEndpoint: "")

proc envInt(name: string, default: int): int =
  ## `int(os.getenv(name, default))` with a fallback: a non-numeric value
  ## keeps the default instead of crashing startup (Python would raise).
  let raw = getEnv(name)
  if raw.len == 0:
    return default
  try:
    return parseInt(raw)
  except ValueError:
    return default

proc envOrDefault*(name, fallback: string): string =
  ## `os.getenv(name)` that treats an EMPTY value as absent, the port of
  ## `env_or` in `waku/memory/semantic/base.py`.
  ##
  ## The Connections form writes every optional field it is shown, so
  ## leaving one blank does not omit it: it stores `NAME=''`, and
  ## `getenv(name, default)` only falls back when the variable is MISSING.
  ## A blank "User id" would then scope somebody's memory to the empty
  ## string instead of the default, and nobody would notice until the memory
  ## was gone. Found the first time a real key was saved through the
  ## dashboard — a hand-edited .env just omits the line.
  let raw = getEnv(name).strip()
  if raw.len == 0: fallback else: raw

proc loadFromEnv*(s: var Settings) =
  ## Read the `WAKU_*` env vars into `s`, keeping the sensible default
  ## when a var is unset.
  s.provider = getEnv("WAKU_PROVIDER", "anthropic")
  s.apiKey = getEnv("WAKU_API_KEY")
  s.model = getEnv("WAKU_MODEL")
  s.home = getEnv("WAKU_HOME", ".waku")
  s.smallModel = getEnv("WAKU_SMALL_MODEL")
  s.baseUrl = getEnv("WAKU_BASE_URL")
  s.maxIterations = envInt("WAKU_MAX_ITERATIONS", defaultMaxIterations)
  s.maxTokens = envInt("WAKU_MAX_TOKENS", defaultMaxTokens)
  s.historyTurns = envInt("WAKU_HISTORY_TURNS", defaultHistoryTurns)
  s.retrievalTopK = envInt("WAKU_RETRIEVAL_TOP_K", 4)
  s.experimental = getEnv("WAKU_EXPERIMENTAL") in ["1", "true", "yes"]
  s.appleTools = getEnv("WAKU_APPLE_TOOLS") in ["1", "true", "yes"]
  s.ghTool = getEnv("WAKU_GH_TOOL") in ["1", "true", "yes"]
  s.ghRepo = getEnv("WAKU_GH_REPO")
  s.graphWorkflows = getEnv("WAKU_GRAPH_WORKFLOWS") in ["1", "true", "yes"]
  s.consolidateEvery = envInt("WAKU_CONSOLIDATE_EVERY", 6)
  s.otelEndpoint = getEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
  s.semanticStore = getEnv("WAKU_SEMANTIC_STORE", "sqlite")
  s.mem0UserId = envOrDefault("MEM0_USER_ID", "waku")
  s.zepUserId = envOrDefault("ZEP_USER_ID", "waku")

proc loadSettings*(): Settings =
  ## Port of `waku/config.py` `load_settings`: read the env vars once
  ## at startup.
  result = defaultSettings()
  result.loadFromEnv()

proc parseDotenvLine*(line: string): (string, string) =
  ## Parse one `.env` line as `KEY=VALUE`.
  ##
  ## Blank lines and `#` comments return `("" , "")`, and a line without `=`
  ## is ignored the same way. Quotes around the value are stripped when they
  ## wrap the whole value (single or double). A `=` inside the value survives.
  ##
  ## Known subset vs python-dotenv: no `export KEY=v` prefixes, no
  ## `${VAR}` interpolation, no trailing comments. Documented, not planned:
  ## the registry only needs plain `KEY=VALUE` lines.
  let trimmed = line.strip()
  if trimmed.len == 0 or trimmed.startsWith("#"):
    return ("", "")
  let eq = trimmed.find('=')
  if eq <= 0:
    return ("", "")
  let key = trimmed[0 ..< eq].strip()
  var value = trimmed[eq + 1 .. ^1].strip()
  if value.len >= 2 and
      ((value[0] == '"' and value[^1] == '"') or
       (value[0] == '\'' and value[^1] == '\'')):
    value = value[1 ..< ^1]
  return (key, value)

proc findDotenv*(startDir = ""): string =
  ## Walk upward from `startDir` (default: the process working directory)
  ## looking for a `.env` file, `git`/`npm`/`pytest` style.
  ##
  ## Port of `find_dotenv(usecwd=True)` in `waku/config.py`: the walk starts
  ## where the user IS, not where the binary lives, so running `waku` from
  ## a subdirectory of a project still finds the `.env` at its root.
  ## Returns the path found, or `""` when the filesystem root is reached.
  var dir = if startDir.len > 0: startDir else: getCurrentDir()
  while true:
    let candidate = dir / ".env"
    if fileExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      return ""
    dir = parent

proc loadDotenvFile*(path: string, override = false) =
  ## Load `KEY=VALUE` lines from `path` into the process environment.
  ## Existing vars win unless `override` is set (same default as
  ## `python-dotenv` `load_dotenv`). Missing file is a no-op, never fatal.
  if path.len == 0:
    return
  var f: File
  if not open(f, path, fmRead):
    return
  defer: close(f)
  for line in f.lines():
    let (key, value) = parseDotenvLine(line)
    if key.len == 0:
      continue
    if override or not existsEnv(key):
      putEnv(key, value)

proc loadDotenv*(startDir = ""): string =
  ## Find the user's `.env` upward from the working directory and load it.
  ## Port of `_load_env()` in `waku/config.py`. Returns the path loaded
  ## (empty when none) so errors can say WHICH file was read.
  let found = findDotenv(startDir)
  if found.len > 0:
    loadDotenvFile(found)
  return found
