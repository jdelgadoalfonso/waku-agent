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

const delegateMaxContextChars* = 5000
  ## Bound for the read-only memory snapshot the orchestrator may place
  ## on the task line (T21-D, approved 2026-11-09). The snapshot is
  ## gated retrieval truncated with a `[truncated]` mark, so a turn with
  ## a large store still sends one bounded line.

const delegateWorkers* = @["gather"]
  ## The agents this binary can actually run headless as a worker. The
  ## gate is offered an agent route only when its worker exists: a route
  ## with nothing behind it would answer every such message with a
  ## fail-open rerun of the local loop. A name here is a real worker: the
  ## N-agent dispatch below (slice T17) needs no new entry, and adding
  ## one without its `--role worker` behaviour would offer a route that
  ## cannot answer.

proc workerAgents*(enabled: seq[string]): seq[string] =
  ## The enabled agents that can actually run, in order and deduped —
  ## what `triageGraphTurn` may offer as an agent route.
  for agent in enabled:
    if agent in delegateWorkers and agent notin result:
      result.add(agent)

type ContextFn* = proc(message: string): string {.closure.}
  ## Read-only memory for one delegation (T21-D): the orchestrator's
  ## gated retrieval for the task message. Empty means no memory, so
  ## the wire keeps today's empty `context`. Nil keeps today too.

proc truncateContext*(s: string): string =
  ## Bound the memory snapshot (T21-D): short text passes through, long
  ## text keeps the first `delegateMaxContextChars` chars and names the
  ## cut so the worker knows it read a recorte, not the whole store.
  if s.len <= delegateMaxContextChars:
    return s
  result = s[0 ..< delegateMaxContextChars] & "\n[truncated]"

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
    maxToolCalls = delegateDefaultMaxToolCalls,
    model = ""): JsonNode =
  ## One stdin line for the worker. Thin over `makeTaskLine` so the
  ## binder has one owner for productive defaults.
  ##
  ## `model` is the child's model override (T19): the parent names the
  ## model it wants this worker to run, and the worker reads the key
  ## back off the line (`worker_gather.taskLineModel`) before its one
  ## model call. The channel is the task line, not the argv, because it
  ## is already the turn's contract: it carries the ids and the budget,
  ## and a second parent never has to remember a flag. Empty (the
  ## default) puts no key on the wire at all, so the line is byte for
  ## byte what it was: an old worker ignores the key, and a new worker
  ## reading an old line reads "inherit the parent's model".
  result = makeTaskLine(traceId, turnId, task, context, timeoutMs,
    maxToolCalls)
  if model.len > 0:
    result["model"] = %model

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
    timeoutSec = -1, model = "",
    contextFn: ContextFn = nil): DelegateFn =
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
  ## one per enabled agent. `model` (T19) rides the task line as the
  ## child's model override; empty keeps the parent's model, which is
  ## what every caller gets today. `contextFn` (T21-D) fills the task
  ## line from gated retrieval, truncated and marked; nil keeps today's
  ## empty `context`.
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
      delegateTaskLine(traceId, turnId, task, if contextFn.isNil: "" else: truncateContext(contextFn(task)), timeoutMs,
        maxToolCalls, model), secs, runner)
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
    timeoutSec = -1, model = "",
    contextFn: ContextFn = nil): DelegateFn =
  ## Per-call twin of `makeDelegateFn`, for a binder that outlives one
  ## turn (`buildCliApp` binds this at startup and every later turn runs
  ## through it): the trace id is READ on each call — `getTraceId` is the
  ## orchestrator's `tracer.turnId`, "" outside a turn — and the turn id
  ## is minted per delegation, so two delegated runs never share an id.
  ## `trace` owns the minting and does not import this module, so there
  ## is no cycle. Everything else is `makeDelegateFn`'s by construction:
  ## the route guard, the edge, the child pairs, and the fail-open.
  ## A nil reader answers an empty trace id instead of raising.
  ## `model` (T19) is forwarded verbatim: the override belongs to the
  ## agent this fn runs, exactly like its route guard. `contextFn`
  ## (T21-D) is forwarded the same way: the snapshot belongs to the
  ## message this call carries.
  result = proc(state: JsonNode, notify: Observer): JsonNode {.closure.} =
    let traceId = if getTraceId.isNil: "" else: getTraceId()
    makeDelegateFn(agent, binary, traceId, trace.mintTurnId(), runner,
      timeoutMs, maxToolCalls, timeoutSec, model, contextFn)(state, notify)

proc makeDelegateDispatcher*(delegates: Delegates): DelegateFn =
  ## One `DelegateFn` in front of N agents (slice T17). The state's
  ## `route` picks the delegate that owns it — `delegateForRoute` is the
  ## one owner of that rule, shared with the graph node — so a binder can
  ## hand the graph ONE seam while every enabled agent still runs its own
  ## worker. Order is the caller's and the first match wins (the table
  ## comes from `workerAgents`, already ordered and deduped). A route no
  ## entry owns answers `%*{"fail_open": true}` — the same answer as no
  ## delegate at all, never another agent's worker. A nil entry is
  ## skipped, so an unwired agent fails open instead of raising.
  result = proc(state: JsonNode, notify: Observer): JsonNode {.closure.} =
    let fn = delegateForRoute(state.jget("route").getStr(), delegates, nil)
    if fn.isNil:
      return %*{"fail_open": true}
    fn(state, notify)

proc liveDelegateFor*(enabled: seq[string], binary: string,
    getTraceId: proc(): string {.closure.},
    runner: WorkerRunner,
    timeoutMs = delegateDefaultTimeoutMs,
    maxToolCalls = delegateDefaultMaxToolCalls,
    timeoutSec = -1, model = "",
    contextFn: ContextFn = nil): DelegateFn =
  ## The seam the CLI binder passes to `triageGraphTurn`: nil unless an
  ## enabled agent has a real worker, else ONE dispatcher holding a live
  ## `DelegateFn` per worker, so the state's `route` decides which agent
  ## runs instead of the first one always winning. `delegateWorkers` holds
  ## one name today, so production binds a single live fn and the table is
  ## what a second worker inherits; every live fn keeps its own route
  ## guard as the last line of defence. `model` (T19) reaches every
  ## worker in the table: one binder, one override, no per-agent flag to
  ## keep in sync. Empty is today's behaviour — each child inherits the
  ## parent's model. `contextFn` (T21-D) reaches every worker the same
  ## way; nil keeps today's empty `context`.
  let workers = workerAgents(enabled)
  if workers.len == 0:
    return nil
  var delegates: Delegates = @[]
  for agent in workers:
    delegates.add((agent: agent,
      fn: makeLiveDelegateFn(agent, binary, getTraceId, runner, timeoutMs,
        maxToolCalls, timeoutSec, model, contextFn)))
  makeDelegateDispatcher(delegates)
