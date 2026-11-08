## Triage — port of `waku/graph/workflows/triage.py`: the front door.
##
## Two things happen AT THE SAME TIME (a small model classifies the
## message; today's calendar loads from disk), then a code router picks
## the path: quick → quick_reply (small model) → END, full → full_agent
## (THE loop) → END. "thanks!" never wakes the big model. Every seam
## fails open: a broken classifier, a broken engine, anything → the plain
## loop answers, same as if the flag were off.
##
## The app binder (`triageGraphTurn`) plugs this into `Waku.graphTurn`
## (the seam 4c left): 4e wires it with the real client and loop. The
## full path calls the SAME `runFullTurn` the flag-off default runs —
## loop-as-a-node can never drift from loop-as-default.

import std/json
import std/os
import std/strutils
import std/times

import ./app
import ./graph/engine
import ./graph/nodes
import ./loop
import ./wire

export app

const
  triagePrompt* = """You are a triage gate for a personal assistant. Given the user's message,
decide which brain should answer it.

Reply with ONLY this JSON, nothing else:
{{"route": "quick" or "full", "reason": "<5 words>"}}

quick — greetings, thanks, acknowledgements, pure small talk: nothing to do,
        nothing to look up.
full  — anything mentioning tasks, schedules, people, notes, memory, identity,
        or personal preferences, and any chat that needs a tool or a memory
        to answer. "What do you remember about me?", "who am I?" and
        "qué recuerdas de mí" are memory questions, not small talk: full.
        When unsure, choose full.

User message: {message}"""

  quickReplyPrompt* = """You are Waku, a warm, concise personal assistant. The user's message needs no
tools or memory — reply in one or two short, natural sentences. If today's
calendar (below) is clearly relevant, you may mention it; otherwise ignore it.

Today's calendar: {calendar}

User message: {message}"""

type
  ClassifyFn* = proc(message: string): tuple[route, reason: string] {.closure.}
  CalendarFn* = proc(): string {.closure.}
  QuickFn* = proc(state: JsonNode): string {.closure.}
  FullFn* = proc(state: JsonNode, notify: Observer): LoopResult {.closure.}
  DelegateFn* = proc(state: JsonNode, notify: Observer): JsonNode {.closure.}
  Delegates* = seq[tuple[agent: string, fn: DelegateFn]]
    ## One delegate per agent, in the order the caller binds them: the
    ## graph's single `delegate_agent` node picks the entry whose `agent`
    ## matches the state's `route`. A seq (not a table) keeps that order
    ## explicit and matches `workerAgents`, which already dedupes.

proc agentRoutesIn(allowedRoutes: seq[string]): seq[string] =
  ## The agent routes an allow-list enables, in order and deduped.
  ## `quick`/`full` are the gate's own paths, never agents, so a name that
  ## collides with one is dropped instead of forking the same label onto a
  ## quick reply AND a delegate.
  for route in allowedRoutes:
    if route.len > 0 and route notin ["quick", "full"] and
        route notin result:
      result.add(route)

proc triagePromptFor*(allowedRoutes: seq[string] = @[]): string =
  ## The gate's prompt. With no enabled agent it IS `triagePrompt`, byte
  ## for byte — the quick/full wording is never rebuilt here. Every
  ## enabled agent route joins the JSON route line and a short legend, so
  ## a small model that only echoes what it reads can emit that route.
  let agents = agentRoutesIn(allowedRoutes)
  if agents.len == 0:
    return triagePrompt
  var routes = "\"quick\" or \"full\""
  for agent in agents:
    routes.add(" or \"" & agent & "\"")
  var legend = "\n" & agents.join(", ") & " — enrolled agent routes. Hand the\n" &
    "        message to the agent whose job it clearly is: it runs its own\n" &
    "        turn and answers. A memory or identity question is never an\n" &
    "        agent route: an agent holds no memory of this conversation,\n" &
    "        so it could only answer blind. Those go to full.\n"
  if "gather" in agents:
    # The live misrouting (S10): `gather` answering identity questions
    # with a generic briefing, because the worker is blind to memory by
    # design (slice 9). Naming the boundary in the prompt is the fix the
    # small model can actually read.
    legend.add "        gather — only an explicit digest, briefing or report that it\n" &
      "        builds with its own tools: never a memory or identity question,\n" &
      "        never plain chat.\n"
  result = triagePrompt.replace("\"quick\" or \"full\"", routes)
  result = result.replace("\n\nUser message: {message}",
    "\n" & legend & "\nUser message: {message}")

proc classifyMessage*(client: LlmClient, smallModel,
                      message: string,
                      notify: Observer = nil,
                      allowedRoutes: seq[string] = @["quick",
                        "full"]): tuple[route, reason: string] =
  ## `(route, reason)`, failing open to "full": a broken triage must cost
  ## latency, never capability. `allowedRoutes` is the model's answer
  ## domain — quick/full plus every enrolled agent the caller enables —
  ## and it is also what the prompt offers the model, so the answer domain
  ## and the question can never disagree.
  ## Anything outside it fails open with the reason saying why.
  ## `text.index("{")` → `text.rindex("}")`; anything unparseable fails
  ## open with the reason saying why.
  try:
    let req = %*{"model": smallModel, "max_tokens": 600,
                 "messages": @[%*{"role": "user", "content":
                   formatTemplate(triagePromptFor(allowedRoutes),
                     %*{"message": message})}]}
    let text = textOf(meteredClient(client, "triage", smallModel,
      notify).create(req)["content"])
    let a = text.find('{')
    if a < 0:
      return ("full", "no JSON — failing open")
    let b = text.rfind('}')
    if b < a:
      # Python's `rindex` raises ValueError here and fails open as
      # "triage failed open (ValueError)"; a slice with no closing
      # brace holds no JSON at all (truncated reply), so this says so.
      # Either way the turn costs latency, never capability.
      return ("full", "no JSON — failing open")
    let decision = parseJson(text[a .. b])
    let route = decision.jget("route").getStr()
    if route notin allowedRoutes:
      return ("full", "bad route '" & route & "' — failing open")
    return (route, decision.jget("reason").getStr())
  except CatchableError as exc:
    return ("full", "triage failed open (" & $exc.name & ")")

proc todaysEvents*(home: string): string =
  ## Today's event titles straight from calendar.ics — a local file read,
  ## which is exactly why it can run beside the classifier's network call.
  ## One parser for "what is on today" shared with the gather binder, so
  ## the two workflows can never disagree.
  let ics = home / "calendar.ics"
  if not fileExists(ics):
    return "(no calendar)"
  let today = format(now(), "yyyyMMdd")
  var lines: seq[string] = @[]
  var title = ""
  for line in lines(ics):
    if line.startsWith("SUMMARY:"):
      title = line[len("SUMMARY:") .. ^1]
    elif line.startsWith("DTSTART") and today in line and title.len > 0:
      lines.add(title)
  if lines.len == 0: "(nothing today)" else: lines.join("; ")

proc delegateForRoute*(route: string, delegates: Delegates,
                       delegateFn: DelegateFn): DelegateFn =
  ## The delegate that owns `route`, or nil when nothing does. With no
  ## per-agent table this is the caller's single `delegateFn`, which keeps
  ## T2.2's shape byte for byte (its own guard still refuses other
  ## routes). With a table, only the matching entry answers — the table
  ## wins over `delegateFn`, and an unowned route answers nil: falling
  ## back to another agent's delegate would run the wrong worker.
  if delegates.len > 0:
    for d in delegates:
      if d.agent == route and not d.fn.isNil:
        return d.fn
    return nil
  delegateFn

proc buildTriageGraph*(classifyFn: ClassifyFn, calendarFn: CalendarFn,
                       quickFn: QuickFn, fullFn: FullFn,
                       agentRoutes: seq[string] = @[],
                       delegateFn: DelegateFn = nil,
                       delegates: Delegates = @[]): Graph =
  ## Callables injected so evals script them, the dashboard builds it with
  ## stubs just to describe(), and the app binder below binds the real
  ## client/loop. The router waits on BOTH parallel branches (via the
  ## `gather` join) before deciding. `agentRoutes` adds the route the
  ## router can reach per enabled agent, and only when a delegate is bound
  ## — one `delegateFn` or a per-agent `delegates` table: with no delegate
  ## there is nothing to spread a route over, so the graph is the plain
  ## five-node quick|full one. One node serves every agent route and looks
  ## the worker up by `route`, so N agents cost N router labels, not N
  ## nodes. (`keyRouter`'s default covers only a missing or empty route
  ## key; an unknown label is recorded as a router error instead, so a
  ## caller must never offer a route the graph cannot reach — the binder
  ## below keeps its answer domain equal to what it builds.)
  var g = Graph(name: "triage")

  proc classify(state: JsonNode, notify: Observer): JsonNode =
    let (route, reason) = classifyFn(state.jget("message").getStr())
    if not notify.isNil:  # the human-readable "why" — traced and carded
      notify("triage", %*{"route": route, "reason": reason})
    return %*{"route": route, "triage_reason": reason}

  g.addNode(newNode("classify", classify, kind = "llm"))
  g.addNode(newNode("check_calendar",
    proc(s: JsonNode, n: Observer): JsonNode =
      %*{"calendar": calendarFn()}, kind = "tool"))
  g.addNode(newNode("quick_reply",
    proc(s: JsonNode, n: Observer): JsonNode =
      %*{"reply": quickFn(s)}, kind = "llm"))
  g.addNode(newNode("full_agent",
    proc(s: JsonNode, n: Observer): JsonNode =
      let turn = fullFn(s, n)
      # nested under "result" so the binder can tell a full turn from a
      # quick reply — Python keeps the LoopResult OBJECT there instead
      %*{"result": {"reply": turn.reply,
                      "tool_calls": %turn.toolCalls,
                      "iterations": turn.iterations}}, kind = "agent"))
  g.addNode(newNode("gather",
    proc(s: JsonNode, n: Observer): JsonNode = newJObject(), kind = "fn"))
  g.addEdge(START, "classify")
  g.addEdge(START, "check_calendar")
  g.addEdge("classify", "gather")
  g.addEdge("check_calendar", "gather")
  var routes = @[(label: "quick", dst: "quick_reply"),
    (label: "full", dst: "full_agent")]
  if agentRoutes.len > 0 and (not delegateFn.isNil or delegates.len > 0):
    g.addNode(newNode("delegate_agent",
      proc(s: JsonNode, n: Observer): JsonNode =
        # One node, N routes: the route names the worker, so a second
        # enabled agent reaches its own delegate instead of failing open
        # on the first one's guard. A route nothing owns fails open the
        # same way a missing delegate does.
        let fn = delegateForRoute(s.jget("route").getStr(), delegates,
          delegateFn)
        if fn.isNil:
          return newJObject()
        let d = fn(s, n)
        # Fail-open is an empty patch: no `result`, no `reply`, so the
        # binder returns (false, _) and `respond` runs the plain loop.
        # Anything else answers through the existing `result` path.
        if d.kind == JObject and d.jget("fail_open").getBool(false):
          newJObject()
        else:
          %*{"result": d}, kind = "agent"))
    for agent in agentRoutes:
      routes.add((label: agent, dst: "delegate_agent"))
    g.addEdge("delegate_agent", END)
  g.addRouter("gather", keyRouter("route", "full"), routes)
  g.addEdge("quick_reply", END)
  g.addEdge("full_agent", END)
  return g

proc triageTopology*(): JsonNode =
  ## The topology as data, for the dashboard — built with stubs, never run.
  buildTriageGraph(
    classifyFn = proc(m: string): tuple[route, reason: string] = ("full", ""),
    calendarFn = proc(): string = "",
    quickFn = proc(s: JsonNode): string = "",
    fullFn = proc(s: JsonNode, n: Observer): LoopResult =
      LoopResult(reply: "", toolCalls: @[], iterations: 0)).describe()

proc quickReply*(client: LlmClient, smallModel: string,
                 state: JsonNode, notify: Observer = nil): string =
  ## One small-model call, no tools: the fast path's whole brain.
  ## Metered like the gate — the fast path is a side call too.
  let req = %*{"model": smallModel, "max_tokens": 600,
               "messages": @[%*{"role": "user", "content": formatTemplate(
                 quickReplyPrompt, %*{"calendar": state.jget("calendar"),
                                      "message": state.jget("message")})}]}
  textOf(meteredClient(client, "quick", smallModel,
    notify).create(req)["content"])

proc triageGraphTurn*(client: LlmClient, smallModel, home: string,
    full: proc(state: JsonNode, notify: Observer,
               stream: bool): LoopResult {.closure.},
    agents: seq[string] = @[],
    delegateFn: DelegateFn = nil,
    delegates: Delegates = @[]): GraphTurn =
  ## The app binder: triage as a `Waku.graphTurn` seam. `stream` rides
  ## per call (like Python's closure over `respond`'s flag), not per
  ## bind. Returns `(answered, result)`; `(false, _)` whenever the graph
  ## produced no answer, so `respond` falls open to the plain loop.
  ##
  ## `agents` is the enabled agent list (`Settings.agents`) and the
  ## delegate seam that runs them is either one `delegateFn` or one entry
  ## per agent in `delegates`. All three default empty/nil, so every
  ## existing caller binds exactly the quick|full graph it binds today: no
  ## agents, no delegate node.
  ##
  ## A route is offered to the model only when something can receive it,
  ## so with no delegate at all the gate keeps today's quick|full answer
  ## domain: enabling `WAKU_AGENTS` before the delegate is wired changes
  ## nothing (the model's agent route fails open to full), and the gate can
  ## never ask the graph for a label the router has no target for.
  let agentRoutes = if delegateFn.isNil and delegates.len == 0:
                      newSeq[string]()
                    else:
                      agentRoutesIn(agents)
  result = proc(userMessage: string, notify: Observer,
                stream: bool): tuple[answered: bool, res: LoopResult] =
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        classifyMessage(client, smallModel, m, notify,
                        @["quick", "full"] & agentRoutes),
      calendarFn = proc(): string = todaysEvents(home),
      quickFn = proc(s: JsonNode): string =
        quickReply(client, smallModel, s, notify),
      fullFn = proc(s: JsonNode, n: Observer): LoopResult =
        full(s, n, stream),
      agentRoutes = agentRoutes,
      delegateFn = delegateFn,
      delegates = delegates)
    var state = %*{"message": userMessage}
    discard runGraph(g, state, notify)
    if state.jget("result").kind == JObject:
      let r = state["result"]
      var calls: seq[JsonNode] = @[]
      if r.jget("tool_calls").kind == JArray:
        for c in items(r["tool_calls"]):
          calls.add(c)
      return (true, LoopResult(reply: r.jget("reply").getStr(),
                               toolCalls: calls,
                               iterations: r.jget("iterations").getInt(1)))
    if state.jget("reply").kind == JString:
      return (true, LoopResult(reply: state["reply"].getStr(),
                               toolCalls: @[], iterations: 1))
    return (false, LoopResult())
