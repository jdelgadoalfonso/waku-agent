## Full agent registry — port of `build_registry` in `waku/tools/__init__.py`.
##
## Registration order matches Python, so `to_api` lists tools in the same
## order: calendar create/list, notes, messages, web search, the three
## memory self-management tools, then the opt-ins (experimental, apple,
## gmail, github) and the already-connected MCP tools.
##
## Two deliberate divergences: `register` replaces by name (Python's dict
## does the same), and memory tools need no `memory is not None` gate —
## the Nim builders always hand over an open db, so they always register
## (like a Python agent whose `Memory` built successfully).

import std/strutils
import std/tables

import db_connector/db_sqlite

import ./apple
import ./calendar
import ./config
import ./episodes
import ./experimental
import ./factstore
import ./github
import ./gitlab
import ./gmail
import ./run_command
import ./schedule
import ./google_auth
import ./mcp
import ./memory_admin
import ./notes
import ./search
import ./tools

proc liveStdioFactory*(): StdioFactory =
  ## The live stdio spawner for registry MCP servers, like `runMcpCmd`.
  result = proc(spec: McpServerSpec): ExchangeFn {.closure.} =
    startStdioExchange(spec.command, spec.args, spec.env)

proc liveHttpPostFn*(): HttpPostFn =
  ## The live streamable-HTTP transport, like `runMcpCmd`.
  result = proc(url, body, sessionId, bearer: string): HttpResult {.closure.} =
    liveHttpPost(url, body, sessionId, bearer)

proc mcpRegistryTools*(home: string, env: Table[string, string],
    nowUnix: int64, makeExchange: StdioFactory,
    httpPost: HttpPostFn): seq[Tool] =
  ## The MCP half of the registry: connect what's connectable NOW and
  ## map their tools. An oauth server with no token and no `auth_env`
  ## needs `waku connect`/`mcp login` first — it is skipped, never
  ## waited on: an agent build must not block on a browser nobody
  ## opened. Warnings stay with the bridge log, like Python's prints.
  var specs: seq[McpServerSpec] = @[]
  try:
    specs = loadMcpServers(home)
  except ValueError:
    return @[]
  var ready: seq[McpServerSpec] = @[]
  for s in specs:
    if s.oauth and not hasToken(home, s) and s.authEnv.len == 0:
      continue
    ready.add(s)
  if ready.len == 0:
    return @[]
  return connectAll(ready, env, home, 30.0, makeExchange, httpPost,
    nowUnix).tools

proc buildRegistry*(db: DbConn, home: string, settings: Settings,
    searchFetch: SearchFetchFn, ghRun: GhRunner, pi: PiSeams,
    apple: AppleSeams, facts: FactStore, episodes: EpisodeStore,
    mcpTools: seq[Tool] = @[], remember: notes.Remember = nil,
    gmailFetch: GmailHttpFn = liveGmailFetch,
    googleCalendarFetch: GoogleHttpFn = liveGoogleFetch,
    clock: GoogleClockFn = nil,
    browseFetch: BrowseFetchFn = nil,
    gitlabGet: GitlabGetFn = liveGitlabGet): ToolRegistry =
  ## Port of `build_registry`. Every side effect rides an injected seam
  ## (`searchFetch`, `ghRun`, `pi`, `apple`) plus pre-connected
  ## `mcpTools` — tests record them all, the builders pass the live
  ## adapters. `settings` alone gates the opt-ins (never OR the env at
  ## registry time): the arena passes per-race values. `remember` is
  ## the Waku Memory send (spec 018); nil, as in every Nim build
  ## today, means save_note answers "not connected" honestly.
  result.register(makeCreateEventTool(db, home))
  result.register(makeListEventsTool(db, home, googleCalendarFetch, clock))
  result.register(makeSaveNoteTool(db, remember))
  result.register(makeSendMessageTool(home))
  result.register(makeSearchTool(searchFetch))
  result.register(makeManageMemoryTool(db, facts, episodes))
  result.register(makeUpdateSoulTool(home))
  result.register(makeCreateSkillTool(home))
  if settings.experimental:
    result.register(makeFetchTool(searchFetch))
    let bf = if browseFetch.isNil: adaptSearchFetch(searchFetch)
             else: browseFetch
    result.register(makeBrowseNavigateTool(bf, home))
    for t in makeExperimentalTools(pi, settings.provider, settings.model,
        home):
      result.register(t)
    result.register(makeRunCommandTool(pi.workspaceRoot))
    result.register(makeScheduleTaskTool(db))
  if settings.appleTools:
    for t in makeAppleTools(apple):
      result.register(t)
  if settings.gmail:
    for t in makeGmailTools(home, gmailFetch, settings.gmailSend):
      result.register(t)
  if settings.ghTool:
    result.register(makeGithubTool(ghRun, settings.ghRepo))
  # GitLab rides after GitHub. The two switches match the row's own `enabled`
  # closure: the explicit flag OR a stored token. Either one is the person
  # saying they want GitLab in the prompt; with neither, the tool is absent and
  # costs nothing. A flag-only build registers it and every call answers that
  # GITLAB_TOKEN is missing, which is the honest reply to a half-done setup.
  let gitlabToken = settings.gitlabToken.strip()
  if settings.gitlabTool or gitlabToken.len > 0:
    result.register(makeGitlabTool(gitlabGet, settings.gitlabUrl, gitlabToken,
      settings.gitlabProject))
  for t in mcpTools:
    result.register(t)
