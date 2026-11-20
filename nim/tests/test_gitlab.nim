## `gitlab_read` tests: the URL normalization, the closed allowlist, project
## validation, formatting, truncation, the probe and the registry gate.
##
## Offline only: the transport is a scripted `GitlabGetFn` that asserts the URL
## and the token it was handed, so a wrong endpoint or a leaked header fails the
## test instead of quietly passing. No socket is ever opened.

import std/json
import std/os
import std/strutils
import std/sequtils
import std/strtabs
import std/tables
import std/unittest

import db_connector/db_sqlite

import ../src/apple
import ../src/config
import ../src/db
import ../src/episodes
import ../src/experimental
import ../src/factstore
import ../src/gitlab
import ../src/integrations
import ../src/registry
import ../src/tools

proc scriptedGet(url, token, body: string,
    status = 200): GitlabGetFn =
  ## One recorded exchange, matched exactly. A call this stub did not expect
  ## raises, which is how "the request never happened" is checked.
  result = proc(askedUrl, askedToken: string): tuple[ok: bool, status: int,
      text: string] {.closure.} =
    if askedUrl != url:
      raise newException(ValueError, "unexpected URL: " & askedUrl)
    if askedToken != token:
      raise newException(ValueError, "unexpected token: " & askedToken)
    (true, status, body)

proc unreachableGet(message: string): GitlabGetFn =
  result = proc(url, token: string): tuple[ok: bool, status: int,
      text: string] {.closure.} =
    (false, 0, message)

proc mustNotRun(): GitlabGetFn =
  ## For the refusals: reaching the transport at all is the failure.
  result = proc(url, token: string): tuple[ok: bool, status: int,
      text: string] {.closure.} =
    raise newException(ValueError, "the transport must not be reached: " & url)

# The registry half: the same fresh home and stub seams `test_registry.nim`
# builds, so the gate is checked against the real `buildRegistry` rather than a
# rewritten copy of its condition.

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc baseSettings(home: string): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
    smallModel: "mini")

proc stubFetch(url, meth, body, agent: string): tuple[ok: bool, text: string] =
  (true, "{}")

proc stubGh(argv: seq[string]): tuple[ok: bool, text: string] =
  (true, "[]")

proc stubPi(): PiSeams =
  PiSeams(piBin: "", jsonMode: false,
    run: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
    runPy: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      ProcResult(timedOut: false, code: 0, stdout: "", stderr: ""),
    workspaceRoot: "", pythonBin: "python3", autorunOff: true,
    recordUsage: nil, projectFlags: @[])

proc stubApple(): AppleSeams =
  AppleSeams(hostOs: "linux",
    run: proc(script: string, timeoutSec: int): tuple[ok: bool,
        text: string] {.closure.} =
      raise newException(ValueError, "must not run"),
    isRunning: proc(app: string): bool = false,
    launch: proc(app: string) = discard)

proc toolNames(reg: ToolRegistry): seq[string] =
  for tool in reg.tools:
    result.add(tool.name)

suite "gitlab URL normalization":
  test "an empty value is gitlab.com's API":
    check normalizeUrl("") == "https://gitlab.com/api/v4"
    check normalizeUrl("   ") == "https://gitlab.com/api/v4"

  test "a self-hosted instance gains the scheme and the API suffix":
    check normalizeUrl("https://gitlab.example.com/") ==
      "https://gitlab.example.com/api/v4"
    check normalizeUrl("gitlab.example.com") ==
      "https://gitlab.example.com/api/v4"
    # A trailing path segment survives: a self-hosted instance served under
    # a prefix keeps it, and only `/api/v4` is appended. Spelled with `site`
    # and not another `gitlab` segment because the repo gate that forbids
    # `examples/` and `lab/` in a string literal would read the join as one.
    check normalizeUrl("https://gitlab.example.com/site") ==
      "https://gitlab.example.com/site/api/v4"

  test "a local instance may speak plain http":
    check normalizeUrl("http://localhost:8080") ==
      "http://localhost:8080/api/v4"

  test "the suffix is added once, so normalizing twice is normalizing once":
    let once = normalizeUrl("https://gitlab.example.com/api/v4/")
    check once == "https://gitlab.example.com/api/v4"
    check normalizeUrl(once) == once

suite "gitlab allowlist":
  test "unknown commands are refused before a URL exists":
    for bad in ["merge", "mr merge", "issue close", "push origin main", ""]:
      let (ok, path, refusal) = gitlabEndpoint(bad, 1, "group/project", 10)
      check ok == false
      check path == ""
      check "read-only" in refusal
      check "mr diff" in refusal

  test "the five read commands build the documented paths":
    check gitlabEndpoint("mr list", 0, "group/project", 10).path ==
      "/projects/group%2Fproject/merge_requests?state=opened&per_page=10"
    check gitlabEndpoint("mr view", 7, "group/project", 10).path ==
      "/projects/group%2Fproject/merge_requests/7"
    check gitlabEndpoint("mr diff", 7, "group/project", 10).path ==
      "/projects/group%2Fproject/merge_requests/7/changes"
    check gitlabEndpoint("issue list", 0, "group/project", 10).path ==
      "/projects/group%2Fproject/issues?state=opened&per_page=10"
    check gitlabEndpoint("issue view", 3, "group/project", 10).path ==
      "/projects/group%2Fproject/issues/3"

  test "a numeric project ID is used verbatim":
    check gitlabEndpoint("issue list", 0, "42", 5).path ==
      "/projects/42/issues?state=opened&per_page=5"

  test "list limits clamp like github's":
    check gitlabEndpoint("mr list", 0, "g/p", 999).path.endsWith("per_page=50")
    check gitlabEndpoint("mr list", 0, "g/p", 0).path.endsWith("per_page=10")
    check gitlabEndpoint("mr list", 0, "g/p", -4).path.endsWith("per_page=1")

  test "a hostile or malformed project is refused, not escaped":
    for bad in ["o/r; rm -rf ~", "../../etc/passwd", "group", "",
                "group/project/sub", "group/pro ject", "0", "12ab"]:
      let (ok, path, refusal) = gitlabEndpoint("mr list", 0, bad, 10)
      check ok == false
      check path == ""
      check "owner/name" in refusal

  test "views need a positive number":
    check "positive" in gitlabEndpoint("mr view", 0, "g/p", 10).refusal
    check "positive" in gitlabEndpoint("issue view", -2, "g/p", 10).refusal
    check gitlabEndpoint("mr list", 0, "g/p", 10).ok

suite "gitlab project validation":
  test "owner/name passes, with the github charset":
    check validRepo("group/project")
    check validRepo("group_1/project-2.sub")
    check validRepo("a/1")

  test "everything else fails":
    for bad in ["", "group", "group/", "/project", "group/project/",
                "group/project/extra", "-group/project", "g p/r"]:
      check validRepo(bad) == false

  test "a numeric ID is a project, zero and mixtures are not":
    check numericId("42")
    check numericId("0") == false
    check numericId("4a") == false
    check validProject("42")
    check validProject("group/project")
    check validProject("4a") == false

suite "gitlab_read":
  test "no token is answered with where to put one":
    let text = gitlabRead(mustNotRun(), "https://gitlab.com", "",
      "mr list", 0, "g/p", 10)
    check "not connected" in text
    check "GITLAB_TOKEN" in text

  test "a refusal never reaches the transport":
    let text = gitlabRead(mustNotRun(), "https://gitlab.com", "glpat-x",
      "mr merge", 0, "g/p", 10)
    check "read-only" in text

  test "mr list formats GitLab's rows":
    let get = scriptedGet(
      "https://gitlab.example.com/api/v4/projects/g%2Fp/merge_requests" &
        "?state=opened&per_page=10", "glpat-x",
      """[{"iid": 7, "title": "Fix it", "author": {"username": "ana"},
      "updated_at": "2026-10-01T08:30:00.000Z", "state": "opened"}]""")
    let text = gitlabRead(get, "https://gitlab.example.com/", "glpat-x",
      "mr list", 0, "g/p", 10)
    check text == "!7 Fix it — @ana (updated 2026-10-01)"

  test "issue list uses the issue sigil":
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/42/issues?state=opened&per_page=10",
      "glpat-x",
      """[{"iid": 3, "title": "Broken", "author": {"username": "bo"},
      "updated_at": "2026-09-30T23:59:59Z"}]""")
    let text = gitlabRead(get, "", "glpat-x", "issue list", 0, "42", 10)
    check text == "#3 Broken — @bo (updated 2026-09-30)"

  test "an empty list says none open":
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/issues?state=opened&per_page=10",
      "glpat-x", "[]")
    check gitlabRead(get, "", "glpat-x", "issue list", 0, "g/p", 10) ==
      "(none open)"

  test "a view is rendered as text, not as GitLab's envelope":
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/merge_requests/5", "glpat-x",
      """{"iid": 5, "title": "Add cache", "state": "opened",
      "author": {"username": "ana"}, "updated_at": "2026-10-02T10:00:00Z",
      "web_url": "https://gitlab.com/g/p/-/merge_requests/5",
      "description": "Why: it is slow."}""")
    let text = gitlabRead(get, "https://gitlab.com", "glpat-x", "mr view", 5,
      "g/p", 10)
    check "!5 Add cache [opened]" in text
    check "by @ana — updated 2026-10-02" in text
    check "https://gitlab.com/g/p/-/merge_requests/5" in text
    check "Why: it is slow." in text
    check "\"iid\"" notin text

  test "a diff is unwrapped into the patch a person reads":
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/merge_requests/5/changes",
      "glpat-x",
      """{"iid": 5, "title": "Add cache",
      "web_url": "https://gitlab.com/g/p/-/merge_requests/5",
      "changes": [{"old_path": "a.nim", "new_path": "a.nim",
      "diff": "@@ -1 +1 @@\n-old\n+new"}]}""")
    let text = gitlabRead(get, "https://gitlab.com", "glpat-x", "mr diff", 5,
      "g/p", 10)
    check "!5 Add cache" in text
    check "--- a/a.nim" in text
    check "+++ b/a.nim" in text
    check "+new" in text
    check "\"changes\"" notin text

  test "long output truncates and names where to read the rest":
    let patch = "@@ -1 +1 @@\n" & "-x\n+y\n".repeat(1500)
    let body = """{"iid": 5, "title": "Huge",
      "web_url": "https://gitlab.com/g/p/-/merge_requests/5",
      "changes": [{"old_path": "a.nim", "new_path": "a.nim",
      "diff": """ & $(%patch) & """}]}"""
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/merge_requests/5/changes",
      "glpat-x", body)
    let text = gitlabRead(get, "https://gitlab.com", "glpat-x", "mr diff", 5,
      "g/p", 10)
    check "truncated at 8000 chars" in text
    check "https://gitlab.com/g/p/-/merge_requests/5" in text
    check text.len < gitlabMaxChars + 300

  test "a 401 names the token and its scope":
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/issues?state=opened&per_page=10",
      "glpat-bad", "{\"message\":\"401 Unauthorized\"}", status = 401)
    let text = gitlabRead(get, "", "glpat-bad", "issue list", 0, "g/p", 10)
    check "401" in text
    check "GITLAB_TOKEN" in text
    check "read_api" in text

  test "a 404 names the project, a 500 keeps the code":
    let missing = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/merge_requests/9", "t",
      "{}", status = 404)
    check "no project 'g/p'" in gitlabRead(missing, "", "t", "mr view", 9,
      "g/p", 10)
    let broken = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/merge_requests/9", "t",
      "boom", status = 502)
    let text = gitlabRead(broken, "", "t", "mr view", 9, "g/p", 10)
    check "502" in text
    check "boom" in text

  test "an unreachable host says so, and mentions the TLS build":
    let text = gitlabRead(unreachableGet("no route to host"),
      "https://gitlab.example.com", "t", "mr list", 0, "g/p", 10)
    check "unreachable" in text
    check "no route to host" in text
    check "buildTls" in text

  test "an unreachable local http instance does not blame the TLS build":
    # The hint is only true for https://: a refused local port is a host or a
    # service that is not running, and pointing at a rebuild would send the
    # person the wrong way.
    let text = gitlabRead(unreachableGet("connection refused"),
      "http://localhost:8080", "t", "mr list", 0, "g/p", 10)
    check "connection refused" in text
    check "buildTls" notin text

  test "non-JSON from a list is reported with a sample":
    let get = scriptedGet(
      "https://gitlab.com/api/v4/projects/g%2Fp/issues?state=opened&per_page=10",
      "t", "<html>login</html>")
    check "not JSON" in gitlabRead(get, "", "t", "issue list", 0, "g/p", 10)

suite "gitlab probe":
  test "without a token the probe refuses instead of pretending":
    var raised = ""
    try:
      gitlabProbe(mustNotRun())(initTable[string, string]())
    except ValueError as error:
      raised = error.msg
    check "GITLAB_TOKEN" in raised

  test "the probe asks who the token is":
    let get = scriptedGet("https://gitlab.example.com/api/v4/user", "glpat-x",
      """{"username": "ana"}""")
    # Silent on success: a probe that returns text would read as a failure.
    gitlabProbe(get)({
      "GITLAB_URL": " https://gitlab.example.com/ ",
      "GITLAB_TOKEN": "glpat-x"}.toTable)

  test "a rejected token raises with the status":
    let get = scriptedGet("https://gitlab.com/api/v4/user", "glpat-x", "{}",
      status = 401)
    var raised = ""
    try:
      gitlabProbe(get)({"GITLAB_TOKEN": "glpat-x"}.toTable)
    except ValueError as error:
      raised = error.msg
    check "401" in raised

suite "the gitlab row":
  test "is a nim-only Calendar & Productivity row":
    let rows = loadIntegrations(findIntegrationsToml(), "nim", BEHAVIOUR)
    var row: IntegrationRow
    var found = false
    for candidate in parseIntegrationRows(readFile(findIntegrationsToml())):
      if candidate.key == "gitlab":
        row = candidate
        found = true
    check found
    check row.halves == @["nim"]
    check row.group == "Calendar & Productivity"
    check row.name == "GitLab"
    check row.reload == agent
    check row.env.len == 4
    check row.env[0].name == "WAKU_GITLAB_TOOL"
    check row.env[0].kind == boolField
    check row.env[1].name == "GITLAB_URL"
    check row.env[1].default == "https://gitlab.com"
    check row.env[2].name == "GITLAB_TOKEN"
    check row.env[2].secret
    check row.env[2].required
    check row.env[3].name == "WAKU_GITLAB_PROJECT"
    check "gitlab" in rows.mapIt(it.key)

  test "is on with the switch or with a stored token, off with neither":
    let enabled = BEHAVIOUR["gitlab"].enabled
    check enabled != nil
    check enabled({"GITLAB_TOKEN": "glpat-x"}.toTable, "linux")
    check enabled({"WAKU_GITLAB_TOOL": "1"}.toTable, "linux")
    check enabled(initTable[string, string](), "linux") == false

  test "without a token the row reports not configured":
    var gitlab: Integration
    for row in INTEGRATIONS:
      if row.key == "gitlab":
        gitlab = row
    check gitlab.key == "gitlab"
    let status = integrationStatus(gitlab, initTable[string, string](),
      hostOs = "linux")
    check status.state == notConfigured

  test "the constructor's normalize trims the URL it was pasted":
    let normalize = BEHAVIOUR["gitlab"].normalize
    check normalize != nil
    let values = {"GITLAB_URL": "  https://gitlab.example.com/  "}.toTable
    check normalize(values)["GITLAB_URL"] == "https://gitlab.example.com/"

suite "the registry gate":
  test "off registers no gitlab tool":
    let home = freshHome("waku-gitlab-off")
    let db = connectDb(home)
    let reg = buildRegistry(db, home, baseSettings(home), stubFetch, stubGh,
      stubPi(), stubApple(), sqliteFactStore(db), sqliteEpisodeStore(db))
    db.close()
    check "gitlab_read" notin toolNames(reg)
    removeDir(home)

  test "a stored token registers it, after github, and reaches the instance":
    let home = freshHome("waku-gitlab-on")
    let db = connectDb(home)
    var settings = baseSettings(home)
    settings.ghTool = true
    settings.gitlabToken = "glpat-x"
    settings.gitlabUrl = "https://gitlab.example.com/"
    settings.gitlabProject = "team/app"
    let get = scriptedGet(
      "https://gitlab.example.com/api/v4/projects/team%2Fapp/merge_requests" &
        "?state=opened&per_page=10", "glpat-x",
      """[{"iid": 4, "title": "Ship it", "author": {"username": "ana"},
      "updated_at": "2026-10-02T09:00:00Z"}]""")
    let reg = buildRegistry(db, home, settings, stubFetch, stubGh, stubPi(),
      stubApple(), sqliteFactStore(db), sqliteEpisodeStore(db),
      gitlabGet = get)
    db.close()
    let names = toolNames(reg)
    check "gitlab_read" in names
    check names.find("gitlab_read") == names.find("github_read") + 1
    let text = reg.execute("gitlab_read", %*{"command": "mr list"})
    check text == "!4 Ship it — @ana (updated 2026-10-02)"
    removeDir(home)

  test "the switch alone registers it, and every call says the token is missing":
    let home = freshHome("waku-gitlab-switch")
    let db = connectDb(home)
    var settings = baseSettings(home)
    settings.gitlabTool = true
    let reg = buildRegistry(db, home, settings, stubFetch, stubGh, stubPi(),
      stubApple(), sqliteFactStore(db), sqliteEpisodeStore(db),
      gitlabGet = mustNotRun())
    db.close()
    check "gitlab_read" in toolNames(reg)
    let text = reg.execute("gitlab_read", %*{"command": "mr list",
      "project": "g/p"})
    check "GITLAB_TOKEN" in text
    removeDir(home)
