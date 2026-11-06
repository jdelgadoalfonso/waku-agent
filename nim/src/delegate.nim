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
