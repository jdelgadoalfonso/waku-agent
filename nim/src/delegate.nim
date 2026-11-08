## Productive caller, slices 1-2b: pure helpers, the triage
## `DelegateFn` (offline, no spawn in tests; live code injects
## `defaultWorkerRunner`), and the worker-role side of the same argv.
## Builds the stdin task line, the same-binary argv, and the supervisor
## timeout; maps supervised child lines to the answer and to the trace
## pairs the orchestrator emits on the graph `notify` (which already
## fans out to `Tracer.event`).

import std/json
import std/strutils

import ./aggregate
import ./delegation
import ./loop
import ./supervisor
import ./trace
import ./triage
import ./wire

const delegateDefaultTimeoutMs* = 30000
  ## Tests and the binder agree on one budget: 30s / 8 tool calls.
const delegateDefaultMaxToolCalls* = 8

const delegateWorkers* = @["gather"]
  ## The agents this binary can actually run headless as a worker. The
  ## gate is offered an agent route only when its worker exists: a route
  ## with nothing behind it would answer every such message with a
  ## fail-open rerun of the local loop.

proc workerAgents*(enabled: seq[string]): seq[string] =
  ## The enabled agents that can actually run, in order and deduped —
  ## what `triageGraphTurn` may offer as an agent route.
  for agent in enabled:
    if agent in delegateWorkers and agent notin result:
      result.add(agent)

proc workerRole*(args: seq[string]): tuple[isWorker: bool, agent: string] =
  ## Read a command line back: `--role worker` marks a worker process
  ## and `--agent <name>` names it. The same shape `delegateArgv`
  ## builds, arriving inside the child as `commandLineParams` (no binary
  ## at index 0), so the scan never assumes a position. The last
  ## `--role` wins, like any repeated flag.
  var i = 0
  while i < args.len:
    if args[i] == "--role" and i + 1 < args.len:
      result.isWorker = args[i + 1] == "worker"
      i += 2
    elif args[i] == "--agent" and i + 1 < args.len:
      result.agent = args[i + 1]
      i += 2
    else:
      inc i

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
      # A worker that ran and failed leaves its reason on the turn:
      # timeout, non-zero exit, or no valid child lines. Silent only
      # when no worker ran (route mismatch) or it answered without a
      # claim (empty reply) — those are routing, not failure.
      if outcome.error.len > 0 and not notify.isNil:
        notify("delegation_error",
          %*{"agent": agent, "route": route, "reason": reason,
             "error": outcome.error, "trace_id": traceId,
             "turn_id": turnId})
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

proc makeLiveDelegateFn*(agent, binary: string,
    getTraceId: proc(): string {.closure.},
    runner: WorkerRunner,
    timeoutMs = delegateDefaultTimeoutMs,
    maxToolCalls = delegateDefaultMaxToolCalls,
    timeoutSec = -1): DelegateFn =
  ## Per-call twin of `makeDelegateFn`, for a binder that outlives one
  ## turn (`buildCliApp` binds this at startup and every later turn runs
  ## through it): the trace id is READ on each call — `getTraceId` is the
  ## orchestrator's `tracer.turnId`, "" outside a turn — and the turn id
  ## is minted per delegation, so two delegated runs never share an id.
  ## `trace` owns the minting and does not import this module, so there
  ## is no cycle. Everything else is `makeDelegateFn`'s by construction:
  ## the route guard, the edge, the child pairs, and the fail-open.
  ## A nil reader answers an empty trace id instead of raising.
  result = proc(state: JsonNode, notify: Observer): JsonNode {.closure.} =
    let traceId = if getTraceId.isNil: "" else: getTraceId()
    makeDelegateFn(agent, binary, traceId, trace.mintTurnId(), runner,
      timeoutMs, maxToolCalls, timeoutSec)(state, notify)

proc liveDelegateFor*(enabled: seq[string], binary: string,
    getTraceId: proc(): string {.closure.},
    runner: WorkerRunner,
    timeoutMs = delegateDefaultTimeoutMs,
    maxToolCalls = delegateDefaultMaxToolCalls,
    timeoutSec = -1): DelegateFn =
  ## The seam the CLI binder passes to `triageGraphTurn`: nil unless an
  ## enabled agent has a real worker (today only `gather`), else one live
  ## `DelegateFn` for it. One `DelegateFn` serves one agent — its guard
  ## refuses every other route — so the first worker wins, which is exact
  ## while `delegateWorkers` holds one name.
  let workers = workerAgents(enabled)
  if workers.len == 0:
    return nil
  makeLiveDelegateFn(workers[0], binary, getTraceId, runner, timeoutMs,
    maxToolCalls, timeoutSec)
