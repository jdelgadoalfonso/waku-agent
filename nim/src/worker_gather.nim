## Worker gather — lot 1 T1.4: gather as a headless worker turn.
##
## Pure turn logic for `waku --role worker --agent gather`. The live
## entrypoint (stdin read, `buildWorkerApp`, `runGather`, stdout write)
## stays in `waku.nim` so this module and its tests stay offline:
## inject `GatherFn`, get back the exact child lines to emit.
##
## - valid task -> `event` (digest ready), a `cost` line when the
##   synthesis reported token counts (slice 10), then `done` (reply
##   plus an empty `draft_path`: the worker writes nothing, the parent
##   files)
## - invalid task or gather raising -> single `error`, never raises
##
## T19: a task line may name the model the worker must run on. The
## override is read here (`taskLineModel`, or `taskModel` on a parsed
## line) and the `cost` line names it, because the ledger prices what
## that payload says.
##
## T21-D: a task line may carry a read-only memory snapshot in
## `context`. The worker reads it back here (`taskLineContext`) and
## uses it as its memory scan without opening a store.

import std/json
import std/strutils

import ./delegation
import ./wire

type
  GatherFn* = proc(): JsonNode {.closure.}
    ## Run one gather and return its final state (`digest`,
    ## `draft_path`, and — slice 10 — `usage` when the synthesis
    ## reported token counts). Tests inject recordings; live code
    ## passes a closure over `runGather`.

proc taskModel(task: JsonNode): string =
  ## The model override a task line names (T19), `""` when it names
  ## none. Missing key, non-string value and blank string all mean
  ## "inherit the parent's model": a hint the worker cannot read must
  ## never break the wire, and `workerChildLines` already answers the
  ## structural errors with the one `error` line this turn gets.
  let asked = task.jget("model")
  if asked.kind == JString: asked.getStr().strip() else: ""

proc taskLineModel*(line: string): string =
  ## `taskModel` over the raw stdin line, for the entrypoint that must
  ## know the override before it can build the gather closure — so
  ## `runWorkerCmd` never re-implements the parse. An unreadable line
  ## answers `""` (inherit) instead of raising; the structural read
  ## stays `workerChildLines`'s, and it still answers the one `error`
  ## line that turn gets.
  var task: JsonNode
  try:
    task = parseJson(line.strip())
  except CatchableError:
    return ""
  taskModel(task)

proc taskContext*(task: JsonNode): string =
  ## The read-only memory snapshot a task line names (T21-D), `""` when
  ## it names none. Missing key, non-string value and blank string all
  ## mean inherit (empty): a hint the worker cannot read must never
  ## break the wire, and the structural read stays `workerChildLines`'s.
  let asked = task.jget("context")
  if asked.kind == JString and asked.getStr().strip().len > 0:
    return asked.getStr()
  return ""

proc taskLineContext*(line: string): string =
  ## `taskContext` over the raw stdin line, for the entrypoint that must
  ## know the snapshot before it can build the gather closure. An
  ## unreadable line answers `""` (inherit) instead of raising.
  var task: JsonNode
  try:
    task = parseJson(line.strip())
  except CatchableError:
    return ""
  taskContext(task)

proc runGatherWorker*(task: JsonNode, gather: GatherFn): seq[JsonNode] =
  ## One headless gather turn. `agent` is always "gather", `pid` is 0
  ## (the parent stamps the observed pid on receipt).
  var err = ""
  if not parseTaskLine(task, err):
    return @[makeChildLine("error", "", "", "gather", 0,
      %*{"message": "invalid task: " & err})]
  let traceId = task.jget("trace_id").getStr()
  let turnId = task.jget("turn_id").getStr()
  var state: JsonNode
  try:
    state = gather()
  except CatchableError as exc:
    return @[makeChildLine("error", traceId, turnId, "gather", 0,
      %*{"message": "gather failed: " & exc.msg})]
  let digest = state.jget("digest").getStr()
  let draft = state.jget("draft_path").getStr()
  result = @[
    makeChildLine("event", traceId, turnId, "gather", 0,
      %*{"kind": "node_end", "node": "gather",
          "digest_len": digest.len}),
  ]
  # Slice 10: the worker's tracer is silent, so its synthesis spend can
  # only reach the orchestrator as this line — before `done`, with the
  # task's ids, so the parent books it against the same turn. No usage
  # in the state means no model call happened: no invented charge.
  # T19: the payload names the model the ledger will price it with, so
  # the task line's override wins over whatever the state reports. Live
  # code cannot disagree — the same string reached the synth that wrote
  # this usage — and a state that reports none still gets named.
  let usage = state.jget("usage")
  if usage.kind == JObject:
    var payload = copy(usage)
    let override = taskModel(task)
    if override.len > 0:
      payload["model"] = %override
    result.add(makeChildLine("cost", traceId, turnId, "gather", 0,
      payload))
  result.add(makeChildLine("done", traceId, turnId, "gather", 0,
    %*{"reply": digest, "draft_path": draft}))
