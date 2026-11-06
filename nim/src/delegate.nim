## Productive caller, slice 1 — pure delegate helpers (offline, no spawn).
##
## The parent never trusts the network or the clock here: build the
## stdin task line, the same-binary argv, and the timeout the supervisor
## must wait, then map the supervised child lines to the answer and to
## the trace pairs the orchestrator emits. Live IO (runWorker with
## `defaultWorkerRunner`, `Tracer.event`, `notify`) stays in the binder
## slice; this module and its tests stay deterministic.

import std/json

import ./aggregate
import ./delegation
import ./loop
import ./supervisor
import ./triage
import ./wire

const delegateDefaultTimeoutMs* = 30000
  ## Tests and the binder agree on one budget: 30s / 8 tool calls.
const delegateDefaultMaxToolCalls* = 8

proc delegateArgv*(binary, agent: string): seq[string] =
  ## Same binary, worker role, named agent. `binary` is the running
  ## executable path; `agent` is e.g. "gather".
  @[binary, "--role", "worker", "--agent", agent]

proc delegateTaskLine*(traceId, turnId, task, context: string,
    timeoutMs = delegateDefaultTimeoutMs,
    maxToolCalls = delegateDefaultMaxToolCalls): JsonNode =
  ## One stdin line for the worker. Thin over `makeTaskLine` so the
  ## binder has one owner for productive defaults.
  makeTaskLine(traceId, turnId, task, context, timeoutMs, maxToolCalls)

proc delegateTimeoutSec*(timeoutMs: int): int =
  ## Supervisor seconds that never kill before the child votes
  ## fail-open: ceil(ms/1000) + 1s grace, minimum 1s. 30000ms -> 31s.
  max(1, timeoutMs div 1000 + 1)

proc delegateReply*(childLines: seq[JsonNode]): string =
  ## The answer is the last `done` payload's reply. Anything else
  ## (events, costs, errors) is trace, not chat — an error-only turn
  ## answers "" and the binder fails open to the local loop.
  for child in childLines:
    if child.kind == JObject and child.jget("type").getStr() == "done":
      let reply = child.jget("payload").jget("reply").getStr()
      if reply.len > 0:
        result = reply

proc delegateLoopResult*(childLines: seq[JsonNode]): LoopResult =
  ## One headless worker turn as a `LoopResult`: no tool calls, one
  ## iteration, reply from the last `done`.
  LoopResult(reply: delegateReply(childLines), toolCalls: @[],
    iterations: 1)

proc delegateTracePairs*(
    childLines: seq[JsonNode]): seq[tuple[kind: string, ev: JsonNode]] =
  ## Pure `toTraceEvent` mapping the binder fans out to `Tracer.event`
  ## (and `notify`). Order preserved; caller emits, never rewrites.
  for child in childLines:
    result.add(toTraceEvent(child))

proc delegateEdge*(fromAgent, toAgent, traceId, turnId, route,
    reason: string): JsonNode =
  ## One orchestrator -> worker edge, shaped like the engine `route`
  ## event so `graph.js` lights it with the same code path.
  delegationEvent(fromAgent, toAgent, traceId, turnId, route, reason)

proc makeDelegateFn*(agent, binary, traceId, turnId: string,
    runner: WorkerRunner, timeoutMs = delegateDefaultTimeoutMs,
    maxToolCalls = delegateDefaultMaxToolCalls,
    timeoutSec = -1): DelegateFn =
  ## Live `DelegateFn` for the triage binder. Builds the task line,
  ## emits the `delegation` edge on the graph `notify` (which already
  ## fans out to `Tracer.event`), supervises one worker, re-emits
  ## every child pair, and answers through the existing `result` path.
  ## `shouldFailOpen` answers `%*{"fail_open": true}` so the
  ## `delegate_agent` node emits an empty patch and the binder returns
  ## `(false, _)` — the plain loop answers, same as any broken graph.
  result = proc(state: JsonNode, notify: Observer): JsonNode {.closure.} =
    let task = state.jget("message").getStr()
    let route = state.jget("route").getStr(agent)
    let reason = state.jget("triage_reason").getStr("delegated")
    let secs = if timeoutSec > 0: timeoutSec
               else: delegateTimeoutSec(timeoutMs)
    if not notify.isNil:
      notify("delegation",
        delegateEdge("orchestrator", agent, traceId, turnId, route,
          reason))
    let outcome = runWorker(delegateArgv(binary, agent),
      delegateTaskLine(traceId, turnId, task, "", timeoutMs,
        maxToolCalls), secs, runner)
    for pair in delegateTracePairs(outcome.childLines):
      if not notify.isNil:
        notify(pair.kind, pair.ev)
    if outcome.shouldFailOpen:
      return %*{"fail_open": true}
    let res = delegateLoopResult(outcome.childLines)
    %*{"reply": res.reply, "tool_calls": %res.toolCalls,
        "iterations": res.iterations}
