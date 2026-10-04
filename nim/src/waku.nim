## Waku CLI entry point — Nim port, phase 4.
##
## Port target: the `waku/__main__.py` command dispatch. `connections` was
## phase 0c; phase 4e wires `chat` (default, the REPL), `brief` and
## `gather` against a real app (settings → providers → client → db);
## phase 5a wires `skill install` and `skill export`; phase 8b wires
## `dashboard` to the server loop (in-process callers validate only, so
## the dispatch test stays green without blocking on a socket). Phase 7d2
## wires the four gateway commands (`telegram`, `discord`, `whatsapp`,
## `voice`) to their real loops over one real agent each. `connect` is
## the only command still reporting not-yet-implemented.
##
## Exit codes follow Python: unknown command → 1 with the usage text.
## Two deliberate divergences: `--help`/`--version` exit 0 (Unix
## convention; Python has no such flags, so bare `waku --help` there is
## usage+1), and known-but-unported commands report to stderr and exit 0
## (phase scaffolding — Python has no such state).

import std/httpclient
import std/json
import std/os
import std/strutils
import std/syncio
import std/tables
import std/times

import ./apple
import ./brief
import ./cli
import ./client
import ./config
import ./connect
import ./dashboard
import ./db
import ./discord
import ./experimental
import ./gather
import ./gateway
import ./github
import ./http
import ./integrations
import ./mcp
import ./memory_live
import ./providers
import ./registry
import ./search
import ./skills
import ./telegram
import ./triage
import ./voice
import ./voiceio
import ./whatsapp
import ./wire

proc declaredVersion(manifest: string): string {.noSideEffect.} =
  ## The `version = "..."` value in a nimble manifest, read the way nimble
  ## reads it: the first `version` key, with its quotes stripped. Raises
  ## when the manifest declares no quoted version, because a build that
  ## cannot find the version should stop here rather than ship a blank
  ## `--version`.
  for line in manifest.splitLines():
    let text = line.strip()
    if not text.startsWith("version"):
      continue
    let first = text.find('"')
    let last = text.rfind('"')
    if first < 0 or last <= first:
      raise newException(ValueError, "no quoted version in: " & text)
    return text[first + 1 ..< last]
  raise newException(ValueError, "waku.nimble declares no version")

const
  nimbleManifest = staticRead("../waku.nimble")
    ## The package manifest, read while the compiler runs. Phase 9a-2 put
    ## the one editable version number in that file and made this module
    ## read it, so the binary and `nimble` read the same line instead of
    ## two literals a human had to keep equal. A build therefore needs the
    ## manifest beside `src/`, the same checkout the dashboard embed needs.
  version* = declaredVersion(nimbleManifest)
    ## What `waku --version` prints, taken from `waku.nimble`. The manifest
    ## keeps the literal because nimble also reads that file where `src/`
    ## is not beside it, and because nimble refreshes what it read from a
    ## manifest only when the manifest itself changes.
  cliCommands* = [
    "chat", "dashboard", "connections", "connect", "mcp", "voice",
    "telegram", "discord", "whatsapp", "brief", "gather", "skill",
  ]

  telegramMissingTokenLine = "Set TELEGRAM_BOT_TOKEN in .env " &
    "(message @BotFather to create a bot)."
    ## `telegram.py::main`'s `SystemExit`, verbatim. The dispatch owns
    ## this copy (and WhatsApp's four below) because those gateway
    ## modules have no such line; Discord's lives next to its starter as
    ## `discordMissingTokenLine`, where 7b put it.
  whatsappSetupLines: array[4, tuple[name, line: string]] = [
    # `whatsapp.py::main`'s four `SystemExit`s, verbatim and in Python's
    # order, which checks them one by one and exits on the first gap.
    ("WHATSAPP_TOKEN", "Set WHATSAPP_TOKEN in .env (Meta Cloud API access " &
      "token). See waku/gateway/whatsapp.py docstring for setup " &
      "instructions."),
    ("WHATSAPP_PHONE_NUMBER_ID", "Set WHATSAPP_PHONE_NUMBER_ID in .env " &
      "(from WhatsApp > Getting Started page)."),
    ("WHATSAPP_VERIFY_TOKEN", "Set WHATSAPP_VERIFY_TOKEN in .env (any " &
      "random string you'll enter in Meta's dashboard)."),
    ("WHATSAPP_APP_SECRET", "Set WHATSAPP_APP_SECRET in .env (from your " &
      "app's Settings → Basic → App Secret). This is required to verify " &
      "webhook signatures — without it, anyone who finds your webhook " &
      "URL can forge requests and drive the agent.")
  ]

proc findProvidersToml*(): string =
  ## Locate the provider registry, trying the caller's working directory
  ## first (repo checkout layout) and the binary directory last.
  ## Returns `""` when no candidate exists.
  for candidate in ["waku/providers.toml", "../waku/providers.toml",
                    "../../waku/providers.toml"]:
    if fileExists(candidate):
      return candidate
  let besideBin = getAppDir() / "providers.toml"
  if fileExists(besideBin):
    return besideBin
  return ""

proc processEnv(): Table[string, string] =
  ## The process environment as a `Table`, which is how every gateway
  ## seam takes it (never `os.environ` inside a module — 7a's rule).
  ## Read once per command, after the `.env` is loaded.
  result = initTable[string, string]()
  for key, value in envPairs():
    result[key] = value

proc runConnections*(): int =
  ## List every integration and its stored health, like
  ## `waku/integrations.py` `cli_main` in plain text (the Nim CLI has no
  ## rich): a stored ERROR on a configured row exits 1, else 0. A missing
  ## registry exits 1 (Nim reads `providers.toml`; Python reads the
  ## compiled `PROVIDERS`). No probes run here — health is read, never
  ## tested, so this stays offline.
  discard loadDotenv()
  let registryPath = findProvidersToml()
  if registryPath.len == 0:
    stderr.writeLine "providers.toml not found from " & getCurrentDir() &
      " upward or beside the binary"
    return 1
  let rows = loadProviders(registryPath)
  let store = newHealthStore(loadSettings().home)
  return cliMain(rows, processEnv(), hostOS, storeHealthFn(store), nil)

proc writeHelp*() =
  ## Print the command list the full port will implement.
  echo "waku - local-first personal assistant (Nim port, phase 0)"
  echo ""
  echo "Usage: waku <command>"
  echo ""
  echo "Commands:"
  for cmd in cliCommands:
    echo "  " & cmd
  echo ""
  echo "Run 'waku --version' for the port version."

proc writeVersion*() =
  ## Print the port version.
  echo version

proc buildCliApp*(dotenvStart = "", homeEnv = ""): Waku =
  ## Everything a CLI command runs against: env, registry, live client,
  ## state db. Raises `ClientConfigError` (message holds the fix) before
  ## touching the network or the filesystem beyond the `.env` read.
  ## `homeEnv` names an env var that overrides `WAKU_HOME` for this
  ## agent only — `DISCORD_HOME`, the difference between "a bot in my
  ## community" and "my private assistant, exposed" (port of
  ## `discord.py::_build_agent`, which reloads settings and repoints
  ## `home`). Empty (the default) is the plain `WAKU_HOME` agent.
  let dotenvPath = loadDotenv(dotenvStart)
  var settings = loadSettings()
  if homeEnv.len > 0:
    let home = getEnv(homeEnv).strip()
    if home.len > 0:
      settings.home = home
  let registryPath = findProvidersToml()
  if registryPath.len == 0:
    raise newException(ClientConfigError,
      "providers.toml not found from " & getCurrentDir() &
      " upward or beside the binary")
  let rows = loadProviders(registryPath)
  let client = clientFor(settings, rows, getEnv("WAKU_API_KEY"),
                         dotenvPath)
  let db = connectDb(settings.home)
  var w = newWaku(settings, client, db)
  w.tools = buildRegistry(db, settings.home, settings, liveSearchFetch,
    liveGhRun, livePiSeams(settings.home, settings.provider,
      settings.model),
    liveAppleSeams(), w.facts,
    mcpRegistryTools(settings.home, processEnv(),
      getTime().toUnix(), liveStdioFactory(), liveHttpPostFn()))
  wireMemory(w, settings, db, client, bundledSkillDirs())
  if settings.graphWorkflows:
    w.graphTurn = triageGraphTurn(client, settings.smallModel,
      settings.home,
      proc(st: JsonNode, n: Observer, strm: bool): LoopResult =
        w.runFullTurn(st.jget("message").getStr(), n, strm))
  return w

proc runChat*(dotenvStart = ""): int =
  ## Default command: talk in the terminal.
  var w: Waku
  try:
    w = buildCliApp(dotenvStart)
  except ClientConfigError as exc:
    stderr.writeLine(exc.msg)
    return 1
  runRepl(w)
  return 0

proc runBriefCmd*(dotenvStart = ""): int =
  ## Morning briefing as a loop turn, filed to the outbox.
  var w: Waku
  try:
    w = buildCliApp(dotenvStart)
  except ClientConfigError as exc:
    stderr.writeLine(exc.msg)
    return 1
  let (reply, path) = runBrief(w)
  echo reply
  echo "saved to " & path
  return 0

proc runGatherCmd*(dotenvStart = ""): int =
  ## Morning briefing as a graph, filed to the outbox.
  var w: Waku
  try:
    w = buildCliApp(dotenvStart)
  except ClientConfigError as exc:
    stderr.writeLine(exc.msg)
    return 1
  echo "gathering — github, web, calendar and memory, together…"
  let state = runGather(w)
  let digest = state.jget("digest").getStr()
  echo if digest.len > 0: digest else: "(no digest — every source was empty)"
  if state.jget("draft_path").kind == JString:
    echo "saved to " & state["draft_path"].getStr()
  if state.jget("errors").kind == JObject:
    for node, err in pairs(state["errors"]):
      echo node & ": " & err.getStr()
  return 0

proc writeUsage*() =
  ## What to run. Unknown commands land here with exit 1, like Python.
  echo "waku - local-first personal assistant (Nim port)"
  echo ""
  echo "Usage: waku <command>"
  echo ""
  echo "Commands:"
  for cmd in cliCommands:
    echo "  " & cmd

proc fetchHttp(url: string): string =
  ## The real fetch for `skill install`: stdlib httpclient GET with a
  ## 15s timeout (Python's `urlopen(raw, timeout=15)`). Non-2xx raises
  ## `HttpRequestError`, like urllib's HTTPError; the dispatch turns any
  ## fetch error into stderr + exit 1. The client comes from `http.nim`'s
  ## one helper, so a skill from an `https` URL gets the TLS context in
  ## a `-d:wakuTls` build and is refused before any byte goes out in the
  ## default one.
  let client = newTlsHttpClient(timeout = 15000)
  try:
    return client.getContent(url)
  finally:
    client.close()

proc runSkillInstall*(url: string): int =
  ## `skill install <url>`: fetch, validate, drop into WAKU_HOME/skills.
  ## Port of the `skill install` dispatch in `waku/__main__.py`; errors
  ## print to stderr and exit 1 (Python's SystemExit prints to stderr
  ## with exit 1; real fetch failures there are tracebacks).
  try:
    echo installSkill(loadSettings().home, url, fetchHttp)
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    return 1
  return 0

proc runSkillExport*(argv: seq[string]): int =
  ## `skill export [flags]`: copy skills into another agent's skills
  ## folder. Base is the OS home, or this folder with `--project`
  ## (Python's `Path.home()`/`Path.cwd()`); lines print to stdout with
  ## exit 0, arg/file errors print to stderr with exit 1.
  try:
    let (targets, project, force) = parseExportArgs(argv)
    let lines = exportSkills(targets, loadSettings().home,
        if project: getCurrentDir() else: getHomeDir(), force)
    echo if lines.len > 0: lines.join("\n") else: "No skills found to export."
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    return 1
  return 0

proc runDashboard(dotenvStart: string, serve: bool): int =
  ## The `dashboard` command: build live deps, then validate-only
  ## (in-process callers) or serve the loop (the real binary). Missing
  ## registry fails like `connections` does — offline, before any socket.
  let dotenvPath = loadDotenv(dotenvStart)
  let registryPath = findProvidersToml()
  if registryPath.len == 0:
    stderr.writeLine "providers.toml not found from " & getCurrentDir() &
      " upward or beside the binary"
    return 1
  let rows = loadProviders(registryPath)
  if serve:
    let dp = if dotenvPath.len > 0: dotenvPath else: ".env"
    return serveDashboardCmd(rows, loadSettings(), dp)
  return checkDashboardCmd(rows, loadSettings(), dotenvPath)

proc runConnectCmd*(dotenvStart: string, argv: seq[string]): int =
  ## Port of `connect.cli_main`: `connect` names the two doors, an
  ## unknown name says what is available (exit 1), a known one runs its
  ## sign-in over the live adapters and prints its reply (exit 0 — even
  ## a refusal sentence, like Python). `home` comes from settings
  ## (`WAKU_HOME`), like every command here.
  discard loadDotenv(dotenvStart)
  let home = loadSettings().home
  let env = processEnv()
  let nowUnix = getTime().toUnix()
  let google = GoogleSeams(
    openBrowser: openBrowserLive,
    waitLoopback: waitGoogleCallbackLive,
    exchange: exchangeGoogleLive,
    nowUnix: nowUnix)
  let livePost: HttpPostFn =
    proc(url, body, sessionId, bearer: string): HttpResult {.closure.} =
      liveHttpPost(url, body, sessionId, bearer)
  let liveFactory: StdioFactory =
    proc(spec: McpServerSpec): ExchangeFn {.closure.} =
      startStdioExchange(spec.command, spec.args, spec.env)
  let flow = oauthFlowWith(liveHttpPost, liveHttpGet, openBrowserLive,
    waitCallbackLive, liveRandInt)
  let signIn: MemorySignInFn =
    proc(home, name: string): tuple[ok: bool, msg: string,
        identity: string] {.closure.} =
      let (ok, msg) = mcpLogin(home, name, env, livePost, liveFactory,
        nowUnix, oauthFlow = flow)
      let identity =
        if ok: mcpIdentity(authFilePath(home, name), nowUnix)
        else: ""
      (ok, msg, identity)
  let (msg, code) = cliConnect(argv, home, google, signIn)
  echo msg
  return code

proc runMcpCmd*(argv: seq[string]): int =
  ## Port of `cli_main` in `mcp_cli.py`: `mcp` lists, `mcp login` forgets
  ## the token and reconnects, `mcp logout` forgets it. `home` comes from
  ## settings (`WAKU_HOME`), `env` from the process — the helpers take
  ## both by parameter, so tests pin them via `WAKU_HOME` + tmp homes.
  ## An `oauth` login refuses honestly naming 6c (no browser flow yet).
  let env = processEnv()
  let home = loadSettings().home
  let nowUnix = getTime().toUnix()
  if argv.len == 0:
    try:
      for line in mcpListLines(home, nowUnix):
        echo line
      return 0
    except ValueError as exc:
      stderr.writeLine(exc.msg)
      return 1
  if argv.len == 2 and argv[0] == "logout":
    let (msg, code) = mcpLogout(home, argv[1])
    echo msg
    return code
  if argv.len == 2 and argv[0] == "login":
    try:
      let livePost: HttpPostFn =
        proc(url, body, sessionId, bearer: string): HttpResult {.closure.} =
          liveHttpPost(url, body, sessionId, bearer)
      let liveFactory: StdioFactory =
        proc(spec: McpServerSpec): ExchangeFn {.closure.} =
          startStdioExchange(spec.command, spec.args, spec.env)
      let (ok, msg) = mcpLogin(home, argv[1], env, livePost,
        liveFactory, nowUnix, oauthFlow = oauthFlowWith(liveHttpPost,
          liveHttpGet, openBrowserLive, waitCallbackLive, liveRandInt))
      echo msg
      return if ok: 0 else: 1
    except ValueError as exc:
      stderr.writeLine(exc.msg)
      return 1
  echo "Usage: waku mcp / waku mcp login <name> / waku mcp logout <name>"
  return 1

# ── the gateway commands (7d2) ──────────────────────────────────────
#
# Python reaches these four through the `__main__.py` dispatch, and each
# of them reads its credentials from a process that already ran
# `_load_env()` at import time. The port has no import-time side effect,
# so every command here loads the `.env` itself before it reads a single
# var — and `dotenvStart` is how a test points that walk at a temp dir
# instead of the checkout's `.env`.

type
  GatewayAgent* = ref object
    ## One live agent behind a gateway command: Python's
    ## `GatewayAgentRunner(_build_agent, session_id="telegram")` pair.
    ## A `ref` because the `RespondFn` has to mutate the SAME agent on
    ## every turn (session history, tracer, ledger) — the dashboard's
    ## `WakuBox` is the same shape for the same reason.
    waku*: Waku
    source*: string

proc newGatewayAgent*(source: string, w: Waku): GatewayAgent =
  ## The agent one gateway command owns.
  GatewayAgent(waku: w, source: source)

proc gatewayRespond*(agent: GatewayAgent): RespondFn =
  ## One agent turn for a gateway: the real `Waku.respond`, tagged with
  ## the gateway the message arrived through (`source`, so the unified
  ## chat can show its origin) and mirrored to the terminal by the same
  ## `_observer` every Python gateway runner passes. The runner wraps this
  ## in `accountedRespond`, so a failed turn still lands on the handle's
  ## status.
  result = proc(text: string): string {.closure.} =
    agent.waku.respond(text, observer = liveObserver,
      source = agent.source).reply

proc buildGatewayAgent*(source, dotenvStart, homeEnv: string): (bool,
    GatewayAgent, string) =
  ## The agent behind one gateway command: the CLI app (settings →
  ## registry → client → db) on a session thread of its own, and the
  ## failure as a line instead of an exception — `chat` and `brief`
  ## print it and exit 1, and a gateway command does the same.
  try:
    var w = buildCliApp(dotenvStart, homeEnv)
    w.session.sessionId = source  # its own conversation thread
    return (true, newGatewayAgent(source, w), "")
  except ClientConfigError as exc:
    return (false, nil, exc.msg)

proc gatewayLog(logger: LogFn): LogFn =
  ## The terminal mirror for a gateway command: the injected one, else
  ## plain stdout — the same default `voiceMain` uses, and the same
  ## place Python's `print()` puts the banner and the posture.
  ## Divergence: a refusal (a missing credential, a missing engine)
  ## travels the same mirror, where Python's `SystemExit` would go to
  ## stderr; one stream per command keeps a person's terminal honest
  ## about what the command did.
  if logger.isNil:
    result = proc(line: string) = echo line
  else:
    result = logger

proc runTelegramCmd*(dotenvStart = "", logger: LogFn = nil): int =
  ## `waku telegram`: the live long-poll (port of `telegram.py::main`).
  ## The token check, then the runner's agent, then the blocking loop
  ## (`telegramRun` prints the banner and the posture itself, exactly
  ## where Python prints both). Returns 0 when the loop ends.
  let log = gatewayLog(logger)
  discard loadDotenv(dotenvStart)
  let token = getEnv("TELEGRAM_BOT_TOKEN")
  if token.len == 0:
    log(telegramMissingTokenLine)
    return 1
  let (ok, agent, why) = buildGatewayAgent("telegram", dotenvStart, "")
  if not ok:
    log(why)
    return 1
  telegramRun(newTelegramLive("telegram"), liveTelegramHttp,
    parseAllowedIds(getEnv("TELEGRAM_ALLOWED_USER")), token,
    gatewayRespond(agent), log, processEnv())
  return 0

proc runDiscordCmd*(dotenvStart = "", logger: LogFn = nil): int =
  ## `waku discord`: the gateway command (port of `discord.py::main`).
  ## Same order as Python: `.env`, token check, then `client.run(token)`.
  ## `discordServe` owns the dial and the reconnect, and it is where this
  ## port says honestly that the encrypted dial is missing (see
  ## `liveDiscordWire`); `DISCORD_HOME` gives the bot its own memory home.
  ## Returns 0 when the loop ran, 1 when it refused.
  let log = gatewayLog(logger)
  discard loadDotenv(dotenvStart)
  let token = getEnv("DISCORD_BOT_TOKEN")
  if token.len == 0:
    log(discordMissingTokenLine)
    return 1
  let (ok, agent, why) = buildGatewayAgent("discord", dotenvStart,
    "DISCORD_HOME")
  if not ok:
    log(why)
    return 1
  return discordServe(newDiscordLive("discord"), token, gatewayRespond(agent),
    log, processEnv())

proc runWhatsappCmd*(dotenvStart = "", logger: LogFn = nil): int =
  ## `waku whatsapp`: the webhook server (port of `whatsapp.py::main`).
  ## The four credentials are checked in Python's order, each with its own
  ## line, then the live server binds `0.0.0.0:5000` and blocks in
  ## `accept`: `take = nil` is the standalone command (a `TakeConn` is
  ## the dashboard's multiplexed loop, 7d2-3), which is why a stop here
  ## needs a second Ctrl-C — documented on `serveWhatsapp`. Returns 0
  ## when the server stops.
  let log = gatewayLog(logger)
  discard loadDotenv(dotenvStart)
  for field in whatsappSetupLines:
    if getEnv(field.name).len == 0:
      log(field.line)
      return 1
  let (ok, agent, why) = buildGatewayAgent("whatsapp", dotenvStart, "")
  if not ok:
    log(why)
    return 1
  serveWhatsapp(newWhatsappLive("whatsapp"), getEnv("WHATSAPP_VERIFY_TOKEN"),
    getEnv("WHATSAPP_APP_SECRET"), getEnv("WHATSAPP_ALLOWED_PHONE"),
    getEnv("WHATSAPP_TOKEN"), getEnv("WHATSAPP_PHONE_NUMBER_ID"),
    liveWhatsappPost, gatewayRespond(agent), log)
  return 0

proc runVoiceCmd*(dotenvStart = "", logger: LogFn = nil): int =
  ## `waku voice`: the live voice session (port of `voice.py::main`).
  ## No supervisor and no gateway handle: voice is a foreground command
  ## in Python too (there is no voice row in the integrations registry),
  ## so this is `voiceMain` over the real agent, the real recorder
  ## starter behind `WAKU_MIC_COMMAND` and Ctrl-C wired to both loops.
  ## Returns what `voiceMain` returns: 0 for a session that ended, 1 for
  ## an honest refusal (a missing engine, a mic that would not open).
  let log = gatewayLog(logger)
  discard loadDotenv(dotenvStart)
  let (ok, agent, why) = buildGatewayAgent("voice", dotenvStart, "")
  if not ok:
    log(why)
    return 1
  let env = processEnv()
  let openMic: MicOpenFn =
    proc(): ExternalMic {.closure.} =
      externalMic(startRecorderLive, env.getOrDefault("WAKU_MIC_COMMAND", ""))
  return voiceMain(env, gatewayRespond(agent), openMic, logger = log,
    stop = installVoiceInterrupt())

proc runCommand*(args: seq[string], dotenvStart = "",
                 serve = false): int =
  ## Dispatch one command line. `dotenvStart` pins the `.env` search for
  ## tests (default: the working directory, like a real run). `serve`
  ## is true only when this call owns the process (the real binary): the
  ## dashboard then serves its loop, otherwise it validates-only so
  ## in-process callers (tests, embedding) never block on a socket. The
  ## four gateway commands forward `dotenvStart` for the same reason: a
  ## gateway dispatch reads the `.env` before its credentials, so a test
  ## points it at a temp dir to keep the checkout's `.env` out.
  if args.len == 0 or args[0] == "chat":
    return runChat(dotenvStart)
  if args[0] == "dashboard":
    return runDashboard(dotenvStart, serve)
  if args[0] == "--help":
    writeHelp()
    return 0
  if args[0] == "--version":
    writeVersion()
    return 0
  if args[0] == "connections":
    return runConnections()
  if args[0] == "brief":
    return runBriefCmd(dotenvStart)
  if args[0] == "gather":
    return runGatherCmd(dotenvStart)
  if args[0] == "skill" and args.len >= 2 and args[1] == "export":
    return runSkillExport(args[2 .. ^1])
  if args[0] == "skill" and args.len >= 3 and args[1] == "install":
    return runSkillInstall(args[2])
  if args[0] == "skill":  # known subcommand, wrong shape: usage + exit 1, like Python
    writeUsage()
    return 1
  if args[0] == "mcp":  # phase 6b: real list/login/logout (oauth login names 6c)
    return runMcpCmd(if args.len > 1: args[1 .. ^1] else: @[])
  if args[0] == "connect":
    return runConnectCmd(dotenvStart,
      if args.len > 1: args[1 .. ^1] else: @[])
  if args[0] == "telegram":  # phase 7d2: the live long-poll
    return runTelegramCmd(dotenvStart)
  if args[0] == "discord":  # phase 7d2: the gateway loop (dial in discordServe)
    return runDiscordCmd(dotenvStart)
  if args[0] == "whatsapp":  # phase 7d2: the live webhook server
    return runWhatsappCmd(dotenvStart)
  if args[0] == "voice":  # phase 7d2: the live voice session
    return runVoiceCmd(dotenvStart)
  if args[0] in cliCommands:  # known but later phase: honest stub (connect)
    stderr.writeLine "nim port phase 4: " & args[0] & " not yet implemented"
    return 0
  writeUsage()  # unknown, like Python: usage + exit 1
  return 1

when isMainModule:
  quit(runCommand(commandLineParams(), serve = true))
