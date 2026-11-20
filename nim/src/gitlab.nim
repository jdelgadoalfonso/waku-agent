## Read-only GitLab over the REST API — the self-hosted case `gh` cannot
## reach.
##
## Same shape as `github.nim`: a closed allowlist, every rejection before a
## request exists, and one injected transport (`GitlabGetFn`) so tests replay
## recordings and the binary dials the real instance. The difference is the
## auth: `gh` carries its own token for github.com, while a GitLab instance
## answers to a `Private-Token` header and a URL the person owns
## (`GITLAB_URL`, default `https://gitlab.com`).
##
## Read-only is a closed set, not a promise: `gitlabCommands` names the five
## calls that exist, anything else is refused before a URL is built, and the
## HTTP method is hard-coded to GET. There is no flag, no body and no method
## the model can supply.

import std/httpclient
import std/json
import std/strutils
import std/tables

import ./http
import ./tools
import ./wire

const
  gitlabCommands* = ["issue list", "issue view", "mr diff", "mr list",
      "mr view"]
    ## Sorted allowlist, like `ghCommands` in `github.nim`.
  gitlabNeedsNumber* = ["issue view", "mr diff", "mr view"]
  gitlabIsList* = ["issue list", "mr list"]
  gitlabMaxChars* = 8000
    ## One reply's ceiling: a diff or a long description must not be able to
    ## eat the turn's context. The cut is announced so the model can say the
    ## thing was longer instead of summarising half of it.
  gitlabTimeoutSec* = 20
  gitlabDefaultLimit* = 10
  gitlabMaxLimit* = 50
  gitlabDefaultUrl* = "https://gitlab.com"
    ## `GITLAB_URL`'s safe default. A self-hosted instance is the same
    ## setting with its own host; nothing else changes.

  gitlabRefusal* = "Waku's GitLab tool is read-only. Allowed commands: " &
    "issue list, issue view, mr diff, mr list, mr view. It cannot comment, " &
    "close, merge, edit or push — do those in GitLab yourself."

type
  GitlabGetFn* = proc(url, token: string): tuple[ok: bool, status: int,
      text: string] {.closure.}
    ## One read-only GET: `(true, status, body)` when GitLab answered at all,
    ## `(false, 0, explanation)` when it did not (network, DNS, TLS). A 401
    ## is an answer and arrives as `true` with its own sentence.

  GitlabProbe* = proc(values: Table[string, string]) {.closure.}
    ## Structural twin of `integrations.ProbeFn`: the row's values in, a
    ## raise on failure, silence on success. Spelled here so this tool module
    ## never imports the registry module.

proc normalizeUrl*(url: string): string =
  ## What the person typed -> the API base. Trailing slashes are noise, a
  ## missing scheme means `https://`, and `/api/v4` is appended exactly once:
  ## `normalizeUrl(normalizeUrl(u)) == normalizeUrl(u)`, so a value saved by
  ## the Connections form and a value typed at the shell reach the same
  ## endpoint.
  var base = url.strip()
  while base.endsWith("/"):
    base.setLen(base.len - 1)
  if base.len == 0:
    base = gitlabDefaultUrl
  if not (base.startsWith("https://") or base.startsWith("http://")):
    base = "https://" & base
  if not base.endsWith("/api/v4"):
    base.add("/api/v4")
  base

proc validRepo*(repo: string): bool =
  ## `owner/name`, each side starting alnum — the same rule (and the same
  ## charset) as `github.validRepo`. Anything else — flags, `;`, spaces, a
  ## third path segment — is refused before a URL exists, so the project can
  ## never become a path injection.
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

proc numericId*(project: string): bool =
  ## GitLab's other spelling: the project's numeric ID.
  if project.len == 0:
    return false
  for c in project:
    if c notin {'0' .. '9'}:
      return false
  return project != "0"

proc validProject*(project: string): bool =
  ## The two spellings GitLab accepts for a project: `owner/name` or a
  ## positive numeric ID. Nested subgroups (`group/sub/project`) are refused
  ## by name; the numeric ID is the workaround, and widening this guard is a
  ## deliberate change to the allowlist rather than a surprise.
  validRepo(project) or numericId(project)

proc projectPath*(project: string): string =
  ## The path segment GitLab wants: the ID as-is, or the full path with `/`
  ## percent-encoded (`/projects/group%2Fproject/...`). Safe because
  ## `validProject` already refused every character a URL would have to quote.
  if numericId(project):
    project
  else:
    project.replace("/", "%2F")

proc listCap*(limit: int): int =
  ## Python's `max(1, min(int(limit or DEFAULT), MAX))`: an explicit 0 means
  ## "use the default", a negative one still asks for one row.
  if limit == 0:
    return gitlabDefaultLimit
  if limit < 0:
    return 1
  if limit > gitlabMaxLimit:
    return gitlabMaxLimit
  limit

proc gitlabEndpoint*(command: string, number: int, project: string,
    limit: int): tuple[ok: bool, path: string, refusal: string] =
  ## Validate, then BUILD the API path. Nothing is fetched here: refusal
  ## happens before any transport exists.
  if command notin gitlabCommands:
    return (ok: false, path: "", refusal: gitlabRefusal)
  if not validProject(project):
    return (ok: false, path: "",
      refusal: "'" & project & "' is not a valid GitLab project — use the " &
        "owner/name form (e.g. group/project) or its numeric ID.")
  if command in gitlabNeedsNumber and number <= 0:
    return (ok: false, path: "",
      refusal: "'" & command & "' needs a positive merge request or issue " &
        "number.")
  let pid = projectPath(project)
  case command
  of "mr list":
    (ok: true, path: "/projects/" & pid & "/merge_requests?state=opened" &
      "&per_page=" & $listCap(limit), refusal: "")
  of "mr view":
    (ok: true, path: "/projects/" & pid & "/merge_requests/" & $number,
      refusal: "")
  of "mr diff":
    # `/changes` rather than `/diffs`: every GitLab that answers `/api/v4`
    # answers `/changes` (newer releases deprecate it in favour of `/diffs`,
    # which 15.7+ only).
    (ok: true, path: "/projects/" & pid & "/merge_requests/" & $number &
      "/changes", refusal: "")
  of "issue list":
    (ok: true, path: "/projects/" & pid & "/issues?state=opened&per_page=" &
      $listCap(limit), refusal: "")
  of "issue view":
    (ok: true, path: "/projects/" & pid & "/issues/" & $number, refusal: "")
  else:
    (ok: false, path: "", refusal: gitlabRefusal)

proc day(raw: string): string =
  ## `2026-10-01T12:00:00.000Z` -> `2026-10-01`: the date is all a list row
  ## has room for, and all the model needs to say "recently".
  if raw.len >= 10:
    raw[0 ..< 10]
  else:
    raw

proc sigil(kind: string): string =
  ## GitLab's own marks: `!` is a merge request, `#` an issue.
  if kind == "mr": "!" else: "#"

proc gitlabFormatList*(rows: JsonNode, kind: string): string =
  ## `!12 title — @user (updated YYYY-MM-DD)`, or `(none open)`.
  if rows.kind != JArray or rows.len == 0:
    return "(none open)"
  var lines: seq[string] = @[]
  for row in rows:
    lines.add(sigil(kind) & $row.jget("iid").getInt(0) & " " &
      row.jget("title").getStr() & " — @" &
      row.jget("author").jget("username").getStr("?") &
      " (updated " & day(row.jget("updated_at").getStr()) & ")")
  lines.join("\n")

proc gitlabFormatOne*(node: JsonNode, kind: string): string =
  ## One merge request or issue as text a person could read: the header, who
  ## and when, the web address, then the description. The raw JSON stays out
  ## of the prompt — it is mostly fields nothing here needs.
  var lines: seq[string] = @[]
  lines.add(sigil(kind) & $node.jget("iid").getInt(0) & " " &
    node.jget("title").getStr() & " [" & node.jget("state").getStr() & "]")
  lines.add("by @" & node.jget("author").jget("username").getStr("?") &
    " — updated " & day(node.jget("updated_at").getStr()))
  let web = node.jget("web_url").getStr()
  if web.len > 0:
    lines.add(web)
  let body = node.jget("description").getStr().strip()
  if body.len > 0:
    lines.add("")
    lines.add(body)
  lines.join("\n")

proc gitlabFormatChanges*(node: JsonNode): string =
  ## The `/changes` answer -> the diff a person reads: one `---`/`+++` pair
  ## per file and its hunks, with the merge request named above it. GitLab's
  ## JSON envelope is not the text of a change, so unwrapping it is this
  ## tool's job rather than the model's.
  var lines: seq[string] = @[]
  if node.kind == JObject:
    lines.add(sigil("mr") & $node.jget("iid").getInt(0) & " " &
      node.jget("title").getStr())
  let changes = node.jget("changes")
  if changes.kind != JArray or changes.len == 0:
    return "(no changes)"
  for change in changes:
    let oldPath = change.jget("old_path").getStr("?")
    let newPath = change.jget("new_path").getStr(oldPath)
    lines.add("--- a/" & oldPath)
    lines.add("+++ b/" & newPath)
    let body = change.jget("diff").getStr()
    if body.len > 0:
      lines.add(body)
  lines.join("\n")

proc capText*(text: string, hint = ""): string =
  ## `gitlabMaxChars` is the ceiling for every reply; `hint` names where to
  ## read the rest, so a truncated answer is still honest about the whole.
  if text.len <= gitlabMaxChars:
    return text
  result = text[0 ..< gitlabMaxChars] & "\n\n… truncated at " &
    $gitlabMaxChars & " chars."
  if hint.len > 0:
    result.add(" " & hint)

proc httpSentence(status: int, text: string, project: string): string =
  ## The statuses a person can act on get their own sentence; everything else
  ## keeps the code and a sample of what GitLab said.
  if status == 401:
    return "GitLab refused the token (401). Check GITLAB_TOKEN, and that the " &
      "token has the read_api scope."
  if status == 403:
    return "GitLab says this token cannot read project '" & project &
      "' (403)."
  if status == 404:
    return "GitLab has no project '" & project & "' visible to this token " &
      "(404)."
  "GitLab answered HTTP " & $status & ": " & text[0 ..< min(200, text.len)]

proc gitlabRead*(get: GitlabGetFn, baseUrl, token: string, command: string,
    number: int, project: string, limit: int): string =
  ## The single entry point the model reaches. Always returns text: a
  ## refusal, the formatted answer, or the sentence that explains why not.
  let secret = token.strip()
  if secret.len == 0:
    return "GitLab is not connected: set GITLAB_TOKEN in .env or in the " &
      "Connections panel, then restart waku."
  let (ok, path, refusal) = gitlabEndpoint(command, number, project, limit)
  if not ok:
    return refusal
  let url = normalizeUrl(baseUrl) & path
  let (reached, status, text) = get(url, secret)
  if not reached:
    result = "GitLab is unreachable (network or TLS): " &
      text[0 ..< min(200, text.len)]
    # Only an https:// target can be the TLS gap: a local http:// instance
    # failing means the host or the port, and naming TLS there would send the
    # person to rebuild a binary that was never the problem.
    if url.startsWith("https://"):
      result.add(" — the default binary cannot dial https://, so a TLS " &
        "build (nimble buildTls) is what reads a real instance.")
    return result
  if status < 200 or status >= 300:
    return httpSentence(status, text, project)
  let kind = if command.startsWith("mr"): "mr" else: "issue"
  if command in gitlabIsList:
    var rows: JsonNode
    try:
      rows = parseJson(if text.len > 0: text else: "[]")
    except JsonParsingError:
      return "GitLab returned something that was not JSON: " &
        text[0 ..< min(200, text.len)]
    return capText(gitlabFormatList(rows, kind))
  var node: JsonNode
  try:
    node = parseJson(text)
  except JsonParsingError:
    return capText(text)
  if command == "mr diff":
    let web = node.jget("web_url").getStr()
    let hint = if web.len > 0:
        "Open " & web & " to read the whole diff."
      else:
        "Open the merge request in GitLab to read the whole diff."
    return capText(gitlabFormatChanges(node), hint)
  capText(gitlabFormatOne(node, kind))

proc liveGitlabGet*(url, token: string): tuple[ok: bool, status: int,
    text: string] =
  ## The live GET over `http.nim`'s one TLS helper: `https://` gets the TLS
  ## context in a `-d:wakuTls` build and is refused before any byte goes out
  ## in the default one. Real socket — never in tests (they inject
  ## `GitlabGetFn` recordings).
  var client = newTlsHttpClient(timeout = gitlabTimeoutSec * 1000)
  client.headers = newHttpHeaders([("Private-Token", token),
                                   ("Accept", "application/json")])
  try:
    let resp = client.request(url, HttpGet)
    return (true, resp.code.int, resp.body)
  except CatchableError as exc:
    return (false, 0, exc.msg)

proc gitlabProbe*(get: GitlabGetFn): GitlabProbe =
  ## `GET $base/user` — the cheapest call that proves the URL and the token
  ## together, and the one GitLab documents for "who am I". Missing token
  ## raises rather than returning quietly: silence here would read as
  ## "connected".
  result = proc(values: Table[string, string]) {.closure.} =
    let token = values.getOrDefault("GITLAB_TOKEN", "").strip()
    if token.len == 0:
      raise newException(ValueError, "GITLAB_TOKEN is not set.")
    let base = normalizeUrl(values.getOrDefault("GITLAB_URL", ""))
    let (reached, status, text) = get(base & "/user", token)
    if not reached:
      raise newException(ValueError, "GitLab is unreachable (network or " &
        "TLS): " & text[0 ..< min(200, text.len)])
    if status == 401:
      raise newException(ValueError, httpSentence(401, text, ""))
    if status != 200:
      # Not a credential problem this tool can name: the host answered, and
      # the address the person typed is what to look at.
      raise newException(ValueError, "GitLab answered HTTP " & $status &
        " for " & base & "/user: " & text[0 ..< min(200, text.len)])

proc makeGitlabTool*(get: GitlabGetFn, baseUrl, token: string,
    defaultProject = ""): Tool =
  ## Registry wiring for `gitlab_read`. `defaultProject` fills in when a call
  ## omits `project`, the same way `WAKU_GH_REPO` does for GitHub.
  Tool(name: "gitlab_read",
    description: "Read merge requests and issues from a GitLab instance " &
      "(including a self-hosted one) with a personal access token. command " &
      "must be one of: issue list, issue view, mr diff, mr list, mr view. " &
      "READ-ONLY — it cannot comment, close, merge, edit or push, and " &
      "will refuse if asked to. Use it to review what is open and what " &
      "changed.",
    inputSchema: %*{"type": "object",
      "properties": {
        "command": {"type": "string",
                    "description": "one of: issue list, issue view, mr diff, mr list, mr view"},
        "number": {"type": "integer",
                   "description": "merge request/issue number (required for view and diff)"},
        "project": {"type": "string",
                    "description": "owner/name or numeric project ID; omit to use WAKU_GITLAB_PROJECT"},
        "limit": {"type": "integer",
                  "description": "max rows for list commands, default 10"}},
      "required": ["command"]},
    fn: proc(args: JsonNode): string =
      let asked = strArg(args, "project")
      gitlabRead(get, baseUrl, token, strArg(args, "command"),
        intArg(args, "number"),
        (if asked.len > 0: asked else: defaultProject),
        intArg(args, "limit", gitlabDefaultLimit)))
