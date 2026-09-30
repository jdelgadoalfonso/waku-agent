## Waku CLI entry point — Nim port, phase 4.
##
## Port target: the `waku/__main__.py` command dispatch. `connections` was
## phase 0c; phase 4e wires `chat` (default, the REPL), `brief` and
## `gather` against a real app (settings → providers → client → db);
## phase 5a wires `skill install` and `skill export`. Every other
## command still reports not-yet-implemented.
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

import ./brief
import ./cli
import ./client
import ./config
import ./db
import ./gather
import ./providers
import ./skills
import ./triage
import ./wire

const
  version* = "0.0.1-phase0"  # keep in sync with `version` in waku.nimble
  cliCommands* = [
    "chat", "dashboard", "connections", "connect", "mcp", "voice",
    "telegram", "discord", "whatsapp", "brief", "gather", "skill",
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

proc connectionsOutput*(rows: seq[Provider], globalKey,
                        dotenvPath: string): string =
  ## Render the `connections` provider list without network probes.
  ## One line per visible row: `configured` when its key resolves,
  ## otherwise the `set VAR` hint. Hidden rows (hosted tier without its
  ## endpoint) never appear. Pure — no I/O, so tests call this directly.
  result = "AI Providers\n"
  for p in rows:
    if not p.isVisible():
      continue
    if p.resolveApiKey(globalKey).len > 0:
      result &= "  " & p.name & " — configured (" & p.keyEnv & " set)\n"
    else:
      result &= "  " & p.name & " — missing key (set " & p.keyEnv & ")\n"
  if dotenvPath.len > 0:
    result &= "\nLoaded .env from " & dotenvPath & "\n"
  else:
    result &= "\nNo .env found from " & getCurrentDir() & " upward\n"

proc runConnections*(): int =
  ## Load env, locate the registry, print the provider list. Exit 0:
  ## phase 0c has no probes, so nothing can report ERROR yet.
  let dotenvPath = loadDotenv()
  let registryPath = findProvidersToml()
  if registryPath.len == 0:
    stderr.writeLine "providers.toml not found from " & getCurrentDir() &
      " upward or beside the binary"
    return 1
  let rows = loadProviders(registryPath)
  echo connectionsOutput(rows, getEnv("WAKU_API_KEY"), dotenvPath)
  return 0

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

proc buildCliApp*(dotenvStart = ""): Waku =
  ## Everything a CLI command runs against: env, registry, live client,
  ## state db. Raises `ClientConfigError` (message holds the fix) before
  ## touching the network or the filesystem beyond the `.env` read.
  let dotenvPath = loadDotenv(dotenvStart)
  var settings = loadSettings()
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
  ## fetch error into stderr + exit 1.
  let client = newHttpClient(timeout = 15000)
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

proc runCommand*(args: seq[string], dotenvStart = ""): int =
  ## Dispatch one command line. `dotenvStart` pins the `.env` search for
  ## tests (default: the working directory, like a real run).
  if args.len == 0 or args[0] == "chat":
    return runChat(dotenvStart)
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
  if args[0] in cliCommands:  # known but later phase: honest stub
    stderr.writeLine "nim port phase 4: " & args[0] & " not yet implemented"
    return 0
  writeUsage()  # unknown, like Python: usage + exit 1
  return 1

when isMainModule:
  quit(runCommand(commandLineParams()))
