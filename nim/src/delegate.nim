## Productive caller, slices 1-2a: pure helpers plus the triage
## `DelegateFn` (offline, no spawn in tests; live code injects
## `defaultWorkerRunner`). Builds the stdin task line, the same-binary
## argv, and the supervisor timeout; maps supervised child lines to the
## answer and to the trace pairs the orchestrator emits on the graph
## `notify` (which already fans out to `Tracer.event`).

import std/json
import std/strutils

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
  max(1, (timeoutMs + 999) div 1000 + 1)

proc delegateReply*(childLines: seq[JsonNode]): string =
  ## The answer is the last `done` payload's reply. Anything else
  ## (events, costs, errors) is trace, not chat — an error-only turn
  ## answers "" and the binder fails open to the local loop.
  for child in childLines:
    if child.kind == JObject and child.jget("type").getStr() == "done":
      let reply = child.jget("payload").jget("reply").getStr()
      if reply.strip().len > 0:
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
  ## An empty reply (error-only or text-only with exit 0) also fails
  ## open: an answered turn with no reply would read as success.
  ## A route that is not this delegate's agent never spawns: one
  ## `makeDelegateFn` serves one agent, and the live binder must bind
  ## one per enabled agent.
  result = proc(state: JsonNode, notify: Observer): JsonNode {.closure.} =
    let wanted = state.jget("route").getStr(agent)
    if wanted != agent:
      # Never run the wrong worker: no edge, no spawn, fail open to
      # the loop — the same answer as if no delegate were bound.
      return %*{"fail_open": true}
    let task = state.jget("message").getStr()
    let route = wanted
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
    if res.reply.strip().len == 0:
      # Covers error-only, text-only, done-without-reply, and
      # whitespace-only: answering any of those would read as success.
      # Known cost: a worker that already ran tools and then ends
      # empty reruns the full local loop (fail-open duplicates work
      # instead of dropping the turn). No reply, no claim.
      return %*{"fail_open": true}
    %*{"reply": res.reply, "tool_calls": %res.toolCalls,
        "iterations": res.iterations}
