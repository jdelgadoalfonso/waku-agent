## Waku CLI entry point — Nim port, phase 0.
##
## Port target: the `waku/__main__.py` command dispatch (which delegates to
## `waku/gateway/cli.py`). Phase 0 only lists the commands the port will
## implement and reports what is not yet implemented.

const
  version* = "0.0.1-phase0"  # keep in sync with `version` in waku.nimble
  cliCommands* = [
    "chat", "dashboard", "connections", "connect", "mcp", "voice",
    "telegram", "discord", "whatsapp", "brief", "gather", "skill",
  ]

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
  else:
    stderr.writeLine "nim port phase 0: " & args[0] & " not yet implemented"
    # Exit 0: phase 0 has nothing to fail on yet.
