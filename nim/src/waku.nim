## Waku CLI entry point — Nim port, phase 0.
##
## Port target: the `waku/__main__.py` command dispatch. Phase 0c wires the
## real `connections` output (provider rows with key presence, no network
## probes) and loads the user's `.env` upward from the working directory
## before dispatch. Every other command still reports not-yet-implemented.

import std/os

import ./config
import ./providers

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

when isMainModule:
  import std/os
  import std/syncio

  let args = commandLineParams()
  if args.len == 0 or args[0] == "--help":
    writeHelp()
  elif args[0] == "--version":
    writeVersion()
  elif args[0] == "connections":
    quit(runConnections())
  else:
    stderr.writeLine "nim port phase 0: " & args[0] & " not yet implemented"
    # Exit 0: phase 0 has nothing to fail on yet.
