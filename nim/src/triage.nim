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
full  — anything mentioning tasks, schedules, people, notes, memory, or that
        needs a tool. When unsure, choose full.

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

proc classifyMessage*(client: LlmClient, smallModel,
                      message: string,
                      notify: Observer = nil,
                      allowedRoutes: seq[string] = @["quick",
                        "full"]): tuple[route, reason: string] =
  ## `(route, reason)`, failing open to "full": a broken triage must cost
  ## latency, never capability. `allowedRoutes` is the model's answer
  ## domain — quick/full plus every enrolled agent the caller enables.
  ## Anything outside it fails open with the reason saying why.
  ## `text.index("{")` → `text.rindex("}")`; anything unparseable fails
  ## open with the reason saying why.
  try:
    let req = %*{"model": smallModel, "max_tokens": 600,
                 "messages": @[%*{"role": "user", "content":
                   formatTemplate(triagePrompt, %*{"message": message})}]}
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

proc buildTriageGraph*(classifyFn: ClassifyFn, calendarFn: CalendarFn,
                       quickFn: QuickFn, fullFn: FullFn,
                       agentRoutes: seq[string] = @[],
                       delegateFn: DelegateFn = nil): Graph =
  ## Callables injected so evals script them, the dashboard builds it with
  ## stubs just to describe(), and the app binder below binds the real
  ## client/loop. The router waits on BOTH parallel branches (via the
  ## `gather` join) before deciding. `agentRoutes` adds one
  ## `delegate_agent` node the router can reach per enabled agent; the
  ## router stays fail-open because its default is still "full", so an
  ## agent route with no delegate entry lands on the loop, never nowhere.
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
  if agentRoutes.len > 0 and not delegateFn.isNil:
    g.addNode(newNode("delegate_agent",
      proc(s: JsonNode, n: Observer): JsonNode =
        %*{"delegation": delegateFn(s, n)}, kind = "agent"))
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
               stream: bool): LoopResult {.closure.}): GraphTurn =
  ## The app binder: triage as a `Waku.graphTurn` seam. `stream` rides
  ## per call (like Python's closure over `respond`'s flag), not per
  ## bind. Returns `(answered, result)`; `(false, _)` whenever the graph
  ## produced no answer, so `respond` falls open to the plain loop.
  result = proc(userMessage: string, notify: Observer,
                stream: bool): tuple[answered: bool, res: LoopResult] =
    let g = buildTriageGraph(
      classifyFn = proc(m: string): tuple[route, reason: string] =
        classifyMessage(client, smallModel, m, notify),
      calendarFn = proc(): string = todaysEvents(home),
      quickFn = proc(s: JsonNode): string =
        quickReply(client, smallModel, s, notify),
      fullFn = proc(s: JsonNode, n: Observer): LoopResult =
        full(s, n, stream))
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
