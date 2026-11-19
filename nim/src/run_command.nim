## Read-only terminal via an argv-only allowlist — no shell, no writes.
##
## Port shape follows `github.nim`: a closed allowlist (`runCommands*`),
## validate-then-build (`runArgv`), a single entry point (`runRead`) that
## always returns text, a live adapter over `tools.runProcess`, and
## registry wiring (`makeRunCommandTool`). Every rejection happens before
## a subprocess exists. `waku/` is frozen: no Python change here.

import std/json
import std/os
import std/strtabs
import std/strutils

import ./tools
import ./wire

const
  runCommands* = ["cat", "git", "grep", "ls"]
    ## Sorted allowlist of argv[0]. Bare names only, resolved via PATH.
  runGitCommands* = ["diff", "log", "status"]
    ## Only read-only git subcommands.
  runGitSafeFlags* = ["--branch", "--check", "--name-only", "--oneline",
    "--porcelain", "--short", "--stat"]
    ## Closed flag set for git. Anything else is refused honestly.
  runMaxChars* = 8000
  runTimeoutSec* = 20

  runRefusal* = "Waku's terminal tool is read-only. Allowed commands: " &
    "cat, git (diff/log/status), grep, ls. It runs without a shell " &
    "(argv only) and cannot install or reach the network — " &
    "git may still refresh its own index. Do writes yourself."

type
  RunRunner* = proc(argv: seq[string], workdir: string,
      timeoutSec: int): ProcResult {.closure.}
    ## One command invocation. Tests inject recordings; the live
    ## adapter calls `runProcess` with the deny-filtered environment.

proc runDelegateEnv*(): StringTableRef =
  ## Copy of the process environment minus `WAKU_DELEGATE_ENV_DENY`
  ## (comma-separated, exact names). Mirrors `experimental.delegateEnv`
  ## without the import cycle (experimental will own the tool wiring).
  result = newStringTable()
  var denied: seq[string] = @[]
  for name in getEnv("WAKU_DELEGATE_ENV_DENY").split(','):
    if name.strip().len > 0:
      denied.add(name.strip())
  for key, value in envPairs():
    if key notin denied:
      result[key] = value

proc isSafePath*(arg: string): bool =
  ## Relative paths only: no absolute, no parent escape, no home.
  if arg.len == 0:
    return false
  if arg.startsWith("/") or arg.startsWith("~"):
    return false
  if ".." in arg:
    return false
  if '\0' in arg:
    return false
  return true

proc runArgv*(command: string, args: seq[string]): tuple[ok: bool,
    argv: seq[string], refusal: string] =
  ## Validate, then BUILD. No shell ever: `argv` goes straight to
  ## `startProcess` via `runProcess`.
  if command notin runCommands:
    return (false, @[], runRefusal)
  if command == "git":
    if args.len == 0 or args[0] notin runGitCommands:
      return (false, @[], runRefusal)
    for a in args[1 .. ^1]:
      if a.startsWith("-"):
        if a in ["-c", "-C"] or a.startsWith("--exec-path") or
            a.startsWith("--git-dir") or a.startsWith("--work-tree") or
            a.startsWith("--upload-pack"):
          return (false, @[], runRefusal & " That git flag can escape " &
            "the workspace.")
        if a notin runGitSafeFlags and not a.startsWith("--max-count"):
          return (false, @[], runRefusal & " Git flags are limited to " &
            runGitSafeFlags.join(", ") & " (+ --max-count=N).")
      elif not isSafePath(a):
        return (false, @[], "Refused path '" & a &
          "' — relative paths inside the workspace only, no .. or " &
          "absolute paths.")
    return (true, @["git"] & args, "")
  for a in args:
    if a.startsWith("-"):
      if '\0' in a or ".." in a:
        return (false, @[], "Refused flag '" & a &
          "' — no `..` in flags.")
      if a == "-f" or a.startsWith("-f") and a.len > 2 or
          a.startsWith("--file"):
        return (false, @[], "Refused flag '" & a &
          "' — grep file-input flags can read outside the workspace.")
      continue
    if not isSafePath(a):
      return (false, @[], "Refused path '" & a &
        "' — relative paths inside the workspace only, no .. or " &
        "absolute paths.")
  return (true, @[command] & args, "")

proc canonDir*(path: string): string =
  ## Lexical normalization plus symlink resolution when the path
  ## exists. `absolutePath` alone only joins — it never resolves `..` —
  ## so the containment check below must run on the normalized form,
  ## and on the canonical form when the directory is really there.
  let n = normalizedPath(path)
  try:
    result = expandFilename(n)
  except CatchableError:
    result = n

proc validWorkdir*(workspaceRoot, cwd: string): tuple[ok: bool, dir: string,
    refusal: string] =
  ## Pin execution inside the workspace. Empty `cwd` means the root.
  ## Relative `cwd` resolves against the root, never the process CWD.
  if '\0' in cwd or '\0' in workspaceRoot:
    return (false, "", "Refused: NUL byte in path.")
  let rawRoot = if workspaceRoot.len > 0: workspaceRoot
                else: getCurrentDir()
  let rootAbs = absolutePath(rawRoot)
  let rootNorm = normalizedPath(rootAbs)
  let rawWant = if cwd.len == 0: rootAbs
                elif isAbsolute(cwd): cwd
                else: rootAbs / cwd
  let wantNorm = normalizedPath(rawWant)
  if not dirExists(wantNorm):
    return (false, "", "The working directory '" & cwd &
      "' doesn't exist inside the workspace '" & rootNorm & "'.")
  let rootCanon = canonDir(rootNorm)
  let wantCanon = canonDir(wantNorm)
  if wantCanon != rootCanon and
      not wantCanon.startsWith(rootCanon & $DirSep):
    return (false, "", "Refused: '" & cwd &
      "' is outside the workspace '" & rootNorm &
      "'. Stay inside the workspace.")
  return (true, wantNorm, "")

proc runRead*(run: RunRunner, workspaceRoot, command: string,
    args: seq[string], cwd: string, timeoutSec: int): string =
  ## The single entry point the model reaches. Always returns text —
  ## long output truncates with a pointer to the terminal.
  let (ok, argv, refusal) = runArgv(command, args)
  if not ok:
    return refusal
  let (wok, dir, wrefusal) = validWorkdir(workspaceRoot, cwd)
  if not wok:
    return wrefusal
  let timeout = if timeoutSec <= 0: runTimeoutSec
                else: max(1, min(timeoutSec, 30))
  let res = run(argv, dir, timeout)
  if res.timedOut:
    return "The command timed out after " & $timeout &
      "s and was killed — try a smaller scope."
  if res.code != 0:
    let body = if res.stderr.strip().len > 0: res.stderr.strip()
               elif res.stdout.strip().len > 0: res.stdout.strip()
               else: "command failed"
    let snippet = body[0 ..< min(500, body.len)]
    return "command failed (exit " & $res.code & "): " & snippet
  let text = res.stdout.strip()
  if text.len > runMaxChars:
    return text[0 ..< runMaxChars] & "\n\n… truncated at " &
      $runMaxChars & " chars. Run the same command in a terminal " &
      "to read the rest."
  if text.len == 0:
    return "(no output)"
  return text

proc liveRunCommand*(argv: seq[string], workdir: string,
    timeoutSec: int): ProcResult =
  ## The live invocation. Real subprocess — never in tests (they
  ## inject `RunRunner` recordings).
  runProcess(argv, workdir, timeoutSec, runDelegateEnv())

proc makeRunCommandTool*(workspaceRoot: string): Tool =
  ## Registry wiring for `run_command`. `workspaceRoot` pins every
  ## call (`WAKU_WORKSPACE`, default `waku_workspace` at the call site).
  Tool(name: "run_command",
    description: "Run a READ-ONLY command and read its output. " &
      "command must be one of: cat, git (diff/log/status), grep, ls. " &
      "No shell, no writes, paths stay inside the workspace. " &
      "Use it to inspect files and history.",
    inputSchema: %*{"type": "object",
      "properties": {
        "command": {"type": "string",
                    "description": "one of: cat, git, grep, ls"},
        "args": {"type": "array",
                 "description": "argv without shell, e.g. [\"status\"]",
                 "items": {"type": "string"}},
        "cwd": {"type": "string",
                "description": "working dir inside the workspace; omit for root"},
        "timeout_seconds": {"type": "integer",
                            "description": "max seconds, default 20, max 30"}},
      "required": ["command"]},
    fn: proc(args: JsonNode): string =
      var cli: seq[string] = @[]
      let node = args.jget("args")
      if node.kind == JArray:
        for item in node:
          cli.add(item.getStr())
      runRead(liveRunCommand, workspaceRoot, strArg(args, "command"),
        cli, strArg(args, "cwd"), intArg(args, "timeout_seconds", 20)))
