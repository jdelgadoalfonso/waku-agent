## Read-only GitHub via the `gh` CLI's own auth — no token here.
##
## Port of `waku/tools/github.py`. The subprocess is injected
## (`GhRunner`, defaulting to `runProcess`), so tests replay recordings
## and the binary shells to the real `gh`. Every rejection happens
## before a subprocess exists: unknown commands are refused outright,
## and `repo` must match `owner/name`, never escaped.

import std/json
import std/os
import std/strutils

import ./tools
import ./wire

const
  ghCommands* = ["issue list", "issue view", "pr diff", "pr list", "pr view"]
    ## Sorted allowlist, like `sorted(_ALLOWED)`.
  ghNeedsNumber* = ["issue view", "pr diff", "pr view"]
  ghIsList* = ["issue list", "pr list"]
  ghJsonFields* = "number,title,author,updatedAt,url"
  ghMaxChars* = 8000
  ghTimeoutSec* = 20

  ghRefusal* = "Waku's GitHub tool is read-only. Allowed commands: " &
    "issue list, issue view, pr diff, pr list, pr view. It cannot merge, " &
    "comment, close, edit or push — do those yourself."

type
  GhRunner* = proc(argv: seq[string]): tuple[ok: bool,
      text: string] {.closure.}
    ## One `gh` invocation: `(true, stdout)` or `(false, explanation)`.
    ## The live adapter maps `runProcess` (missing binary, timeouts and
    ## auth failures become the same sentences Python returns).

proc validRepo*(repo: string): bool =
  ## `owner/name`, each side starting alnum — Python's `_REPO_RE`.
  ## Anything else (flags, `;`, spaces) is refused, never escaped.
  let parts = repo.split('/')
  if parts.len != 2:
    return false
  for side in parts:
    if side.len == 0:
      return false
    if side[0] notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9'}:
      return false
    for c in side:
      if c notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '.', '-'}:
        return false
  return true

proc ghArgv*(command: string, number: int, repo: string,
    limit: int): tuple[ok: bool, argv: seq[string], refusal: string] =
  ## Validate, then BUILD. Mirrors `_argv` (limit clamps to 1..50).
  if command notin ghCommands:
    return (false, @[], ghRefusal)
  if repo.len > 0 and not validRepo(repo):
    return (false, @[],
      "'" & repo & "' is not a valid repo — use the owner/name form, " &
      "e.g. octocat/Hello-World.")
  var argv = @["gh"]
  for word in command.split(' '):
    argv.add(word)
  if command in ghNeedsNumber:
    if number <= 0:
      return (false, @[], "'" & command & "' needs a positive PR/issue number.")
    argv.add($number)
  if repo.len > 0:
    argv.add("--repo")
    argv.add(repo)
  if command in ghIsList:
    let n = max(1, min(if limit <= 0: 10 else: limit, 50))
    argv.add("--limit")
    argv.add($n)
    argv.add("--json")
    argv.add(ghJsonFields)
  return (true, argv, "")

proc ghFormat*(rows: JsonNode): string =
  ## `#number title — @author (updated YYYY-MM-DD)`, or `(none open)`.
  if rows.kind != JArray or rows.len == 0:
    return "(none open)"
  var lines: seq[string] = @[]
  for r in rows:
    let who = r.jget("author").jget("login").getStr("?")
    lines.add("#" & $r.jget("number").getInt(0) & " " &
      r.jget("title").getStr() & " — @" & who &
      " (updated " & r.jget("updatedAt").getStr()[0 ..< min(10,
        r.jget("updatedAt").getStr().len)] & ")")
  return lines.join("\n")

proc ghRead*(run: GhRunner, command: string, number: int, repo: string,
    limit: int): string =
  ## The single entry point the model reaches. Always returns text —
  ## long output truncates with a pointer to the terminal, like Python.
  let (ok, argv, refusal) = ghArgv(command, number, repo, limit)
  if not ok:
    return refusal
  let (ran, text) = run(argv)
  if not ran:
    return text
  if command in ghIsList:
    var rows: JsonNode
    try:
      rows = parseJson(if text.len > 0: text else: "[]")
    except JsonParsingError:
      return "gh returned something that was not JSON: " & text[0 ..< min(200,
        text.len)]
    return ghFormat(rows)
  if text.len > ghMaxChars:
    return text[0 ..< ghMaxChars] & "\n\n… truncated at " &
      $ghMaxChars & " chars. Run `gh " & command & " " & $number &
      "` in a terminal to read the rest."
  return text

proc liveGhRun*(argv: seq[string]): tuple[ok: bool, text: string] =
  ## The live `gh` invocation. Real subprocess — never in tests (they
  ## inject `GhRunner` recordings).
  if findExe("gh").len == 0:
    return (false, "The gh CLI is not installed. Install it " &
      "(brew install gh) and run `gh auth login`.")
  let res = runProcess(argv, timeoutSec = ghTimeoutSec)
  if res.timedOut:
    return (false, "gh timed out after " & $ghTimeoutSec & "s — GitHub or " &
      "the network is slow. Try again, or check status.github.com.")
  if res.code != 0:
    let err = (if res.stderr.strip().len > 0: res.stderr.strip()
               else: "gh failed")[0 ..< min(200,
                 (if res.stderr.strip().len > 0: res.stderr.strip()
                  else: "gh failed").len)]
    if "auth" in err.toLowerAscii() or "logged in" in err.toLowerAscii():
      return (false, "gh is not authenticated. Run `gh auth login`. (" &
        err & ")")
    return (false, err)
  return (true, res.stdout.strip())

proc makeGithubTool*(run: GhRunner,
    defaultRepo = ""): Tool =
  ## Registry wiring for `github_read`. `defaultRepo` fills in when a
  ## call omits `repo` (running outside a checkout, where `gh` infers
  ## no remote).
  Tool(name: "github_read",
    description: "Read pull requests and issues from GitHub via the gh " &
      "CLI. command must be one of: " &
      "issue list, issue view, pr diff, pr list, pr view. " &
      "READ-ONLY — it cannot merge, comment, close, edit or push, and " &
      "will refuse if asked to. Use it to review what is open and what " &
      "changed.",
    inputSchema: %*{"type": "object",
      "properties": {
        "command": {"type": "string",
                    "description": "one of: issue list, issue view, pr diff, pr list, pr view"},
        "number": {"type": "integer",
                   "description": "PR/issue number (required for view and diff)"},
        "repo": {"type": "string",
                 "description": "owner/name; omit to use the current repo"},
        "limit": {"type": "integer",
                  "description": "max rows for list commands, default 10"}},
      "required": ["command"]},
    fn: proc(args: JsonNode): string =
      ghRead(run, strArg(args, "command"), intArg(args, "number"),
        (let r = strArg(args, "repo"); if r.len > 0: r else: defaultRepo),
        intArg(args, "limit", 10)))
