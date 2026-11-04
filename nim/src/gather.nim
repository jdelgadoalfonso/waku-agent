## Gather — port of `waku/graph/workflows/gather.py` plus the real
## callables from `waku/ops/gather.py`.
##
## The morning gather is genuinely a graph: four scans with no dependencies
## (one wave), one model call, one router, one file a human opens.
##
## TWO RULES, both load-bearing (ported with the file):
##
## 1. IT PROPOSES, IT NEVER ACTS. No `agentNode`, no `runLoop`, no
##    `ToolRegistry` anywhere in this module — the one model call is a
##    bare `create` with no tools, so the model is never handed a schema
##    it could use to send, merge, or create anything. The only write in
##    the entire graph is a markdown file in the outbox. (Enforced by
##    topology: no node here has kind "agent".)
## 2. EVERY BRANCH CATCHES ITS OWN FAILURE (`safeScan`, not the engine's
##    `on_error` — a re-shaped topology must not silently break the
##    guarantee; same surface-don't-crash rule as `ToolRegistry.execute`).
##
## Binders (the `buildBoundGraph` half): calendar reuses triage's `.ics`
## reader, memory opens its OWN short-lived connection per scan (Python's
## thread-ownership discipline, kept verbatim), the draft resolves inside
## the outbox. GitHub stays stubbed as "unavailable" until its tool lands
## (phase 5); web is wired to a real search (Tavily when keyed, DuckDuckGo
## otherwise). A gather without live sources goes `quiet`, honestly.

import std/json
import std/os
import std/strutils
import std/times

import db_connector/db_sqlite

import ./app
import ./db
import ./graph/engine
import ./graph/nodes
import ./loop
import ./memory
import ./search
import ./trace
import ./triage
import ./wire

export app

const
  digestPrompt* = """You are preparing a morning briefing for the maintainer of an
open-source project. Below is everything gathered a moment ago.

OPEN PULL REQUESTS AND ISSUES:
{gh_text}

WHAT THE WEB SAYS:
{web_text}

TODAY'S CALENDAR:
{cal_text}

WHAT YOU ALREADY KNOW:
{mem_text}

Write a short briefing in markdown:
- Lead with the two or three things that actually matter today, and say why.
- Then anything waiting on the maintainer, grouped, one line each.
- End with a single suggested focus for the day.

You are DRAFTING A PROPOSAL for a human to act on. You have not done anything
and cannot do anything — never write as if you have replied, merged, or sent.
Be brief. If a section gathered nothing, say so in a few words and move on."""

  scanBranches* = ["scan_github", "scan_web", "scan_calendar", "scan_memory"]

type
  GithubFn* = proc(): JsonNode {.closure.}
  WebFn* = proc(): string {.closure.}
  CalFn* = proc(): JsonNode {.closure.}
  MemFn* = proc(): string {.closure.}
  SynthFn* = proc(state: JsonNode): string {.closure.}
  DraftFn* = proc(state: JsonNode): string {.closure.}

proc scanKeys*(branch: string): seq[string] =
  ## Each scan writes only keys carrying its own prefix — the convention a
  ## reviewer checks by eye (the engine's collision raise is the backstop).
  case branch
  of "scan_github": @["gh_text", "gh_open_prs", "gh_open_issues"]
  of "scan_web": @["web_text"]
  of "scan_calendar": @["cal_text", "cal_event_count"]
  of "scan_memory": @["mem_text"]
  else: @[]

proc safeScan*(fallback: JsonNode, fn: proc(): JsonNode {.closure.}): JsonNode =
  ## Run a scan, or return honest text saying why it could not. Silence is
  ## the worst failure mode for a morning routine.
  try:
    return fn()
  except CatchableError as exc:
    result = copy(fallback)
    for key, value in pairs(result):
      if value.kind == JString:
        result[key] = %("unavailable (" & $exc.name & ": " & exc.msg & ")")

proc needsAction*(state: JsonNode): string =
  ## The router: CODE, over counts the scans wrote — never the digest's
  ## prose. (Routing on model wording would hand control flow to the model
  ## AND need a scripted response per test case.) Counts arrive as ints
  ## from the bound scans; a non-numeric count reads 0 (`getInt`), which
  ## only differs from Python's truthiness for string values the bound
  ## graph never writes.
  if state.jget("gh_open_prs").getInt(0) != 0 or
     state.jget("gh_open_issues").getInt(0) != 0 or
     state.jget("cal_event_count").getInt(0) != 0:
    "propose"
  else:
    "quiet"

proc buildGatherGraph*(githubFn: GithubFn, webFn: WebFn, calendarFn: CalFn,
                       memoryFn: MemFn, synthFn: SynthFn,
                       draftFn: DraftFn): Graph =
  ## Callables injected exactly as triage does it: evals script them,
  ## `gatherTopology` stubs them to draw the shape, `buildBoundGraph`
  ## binds the real ones.
  var g = Graph(name: "gather")
  g.addNode(newNode("scan_github",
    proc(s: JsonNode, n: Observer): JsonNode =
      safeScan(%*{"gh_text": "", "gh_open_prs": 0, "gh_open_issues": 0},
               githubFn), kind = "tool"))
  g.addNode(newNode("scan_web",
    proc(s: JsonNode, n: Observer): JsonNode =
      safeScan(%*{"web_text": ""},
               proc(): JsonNode = %*{"web_text": webFn()}), kind = "tool"))
  g.addNode(newNode("scan_calendar",
    proc(s: JsonNode, n: Observer): JsonNode =
      safeScan(%*{"cal_text": "", "cal_event_count": 0},
               calendarFn), kind = "tool"))
  g.addNode(newNode("scan_memory",
    proc(s: JsonNode, n: Observer): JsonNode =
      safeScan(%*{"mem_text": ""},
               proc(): JsonNode = %*{"mem_text": memoryFn()}), kind = "tool"))
  g.addNode(newNode("synthesize",
    proc(s: JsonNode, n: Observer): JsonNode =
      %*{"digest": synthFn(s)}, kind = "llm"))
  g.addNode(newNode("draft_digest",
    proc(s: JsonNode, n: Observer): JsonNode =
      %*{"draft_path": draftFn(s)}, kind = "tool"))
  for scan in scanBranches:  # no deps between scans -> one wave
    g.addEdge(START, scan)
    g.addEdge(scan, "synthesize")  # synthesize waits for all four
  # The router lives on synthesize: it IS the barrier, so triage's
  # separate join node would be dead weight here.
  g.addRouter("synthesize", needsAction,
              @[(label: "propose", dst: "draft_digest"),
                (label: "quiet", dst: END)])
  g.addEdge("draft_digest", END)
  return g

proc gatherTopology*(): JsonNode =
  ## The topology as data, for the dashboard — built with stubs, never run.
  buildGatherGraph(
    githubFn = proc(): JsonNode =
      %*{"gh_text": "", "gh_open_prs": 0, "gh_open_issues": 0},
    webFn = proc(): string = "",
    calendarFn = proc(): JsonNode =
      %*{"cal_text": "", "cal_event_count": 0},
    memoryFn = proc(): string = "",
    synthFn = proc(s: JsonNode): string = "",
    draftFn = proc(s: JsonNode): string = "").describe()

# ---- binders: the pure workflow, wired to this machine -------------------

proc unavailableGithub*(): GithubFn =
  ## Until the GitHub tool lands (phase 5): honest text, zero counts.
  result = proc(): JsonNode =
    %*{"gh_text": "unavailable (github tool not yet ported)",
       "gh_open_prs": 0, "gh_open_issues": 0}

proc unavailableWeb*(): WebFn =
  ## Until web search lands (phase 5): honest text.
  result = proc(): string = "unavailable (web search not yet ported)"

proc webBinder*(): WebFn =
  ## Real web search for the morning briefing: one query about the project,
  ## honest failure if the network or the search backend is down.
  result = proc(): string =
    searchWeb(liveSearchFetch, searchApiKey(), "waku-agent", 5)

proc calendarBinder*(home: string): CalFn =
  ## Reuses triage's `.ics` reader — one parser means the two workflows
  ## can never disagree. `(no calendar)` / `(nothing today)` start with
  ## `(`, anything else counts `;` + 1 events.
  result = proc(): JsonNode =
    let text = todaysEvents(home)
    let empty = text.startsWith("(")
    %*{"cal_text": text,
       "cal_event_count": (if empty: 0 else: text.count(";") + 1)}

proc memoryBinder*(home: string): MemFn =
  ## Straight fact search, deliberately NOT the retrieval gate (a briefing
  ## already knows memory is relevant). Opens its OWN short-lived
  ## connection per scan — a connection belongs to the thread that made
  ## it, and parallel nodes sharing a mutable handle is the hazard, not
  ## the thread check that reports it.
  result = proc(): string =
    var conn: DbConn = nil
    try:
      conn = connectDb(home)
      let found = conn.searchFacts("project repo contributors release", 8)
      if found.len == 0: "(nothing relevant)" else: found.join("\n")
    except CatchableError as exc:
      "(memory unavailable: " & exc.msg & ")"
    finally:
      if not conn.isNil:
        conn.close()

proc synthBinder*(client: LlmClient, model: string): SynthFn =
  ## One model call, NO tools parameter. That absence is the
  ## propose-never-act guarantee.
  result = proc(state: JsonNode): string =
    let prompt = formatTemplate(digestPrompt, %*{
      "gh_text": state.jget("gh_text").getStr(),
      "web_text": state.jget("web_text").getStr(),
      "cal_text": state.jget("cal_text").getStr(),
      "mem_text": state.jget("mem_text").getStr()})
    let req = %*{"model": model, "max_tokens": 1500,
                 "messages": @[%*{"role": "user", "content": prompt}]}
    textOf(client.create(req)["content"])

proc draftBinder*(home: string): DraftFn =
  ## Write the digest where a human will find it. Resolves the path and
  ## checks it stays inside the outbox before writing — drafts, never
  ## sends. (The filename is fixed, so the check is defense-in-depth,
  ## exactly like Python's.)
  result = proc(state: JsonNode): string =
    createDir(home / "outbox")
    let outbox = expandFilename(home / "outbox")
    let dest = outbox / ("gather-" & format(now(), "yyyy-MM-dd") & ".md")
    if not dest.startsWith(outbox & DirSep):
      return "refused: draft path escaped the outbox"
    writeFile(dest, state.jget("digest").getStr() & "\n")
    return dest

proc buildBoundGraph*(w: Waku): Graph =
  ## Exactly one definition of what a gather may touch: reads (github —
  ## stubbed, web — stubbed, calendar, memory), one toolless synthesis,
  ## one outbox file.
  let home = w.settings.home
  let client = w.client
  let model = w.settings.model
  buildGatherGraph(
    githubFn = unavailableGithub(),
    webFn = webBinder(),
    calendarFn = calendarBinder(home),
    memoryFn = memoryBinder(home),
    synthFn = synthBinder(client, model),
    draftFn = draftBinder(home))

proc runGather*(w: var Waku, observer: Observer = nil): JsonNode =
  ## Run one gather to completion. Returns the final state; never raises
  ## (every scan fails into honest text). Composed with the tracer, so a
  ## gather lands in traces/*.jsonl like any turn. Unlike Python's
  ## `run_gather(waku=None)` this never builds its own Waku (implicit
  ## network construction arrives with phase 5): the caller owns the app
  ## lifecycle and closes it.
  let notify = compose(observer, w.tracer.tracerEvent())
  var state = newJObject()
  discard runGraph(buildBoundGraph(w), state, notify)
  return state

proc gatherGraphTurn*(w: Waku): GraphTurn =
  ## Gather as a `Waku.graphTurn` seam: one message triggers the morning
  ## briefing. `userMessage` and `stream` are ignored — the digest prompt
  ## is a fixed shape over the four scans. Returns `(false, _)` when no
  ## digest was produced, so `respond` fails open to the plain loop.
  result = proc(userMessage: string, notify: Observer,
                stream: bool): tuple[answered: bool, res: LoopResult] =
    var cw = w
    let state = runGather(cw, notify)
    let digest = state.jget("digest").getStr()
    if digest.len == 0:
      return (false, LoopResult())
    var reply = digest
    let draft = state.jget("draft_path").getStr()
    if draft.len > 0:
      reply = reply & "\n\n*saved to " & draft & "*"
    return (true, LoopResult(reply: reply, toolCalls: @[], iterations: 1))
