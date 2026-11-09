## Worker brief — T3: the morning briefing as a headless worker turn.
##
## Pure turn logic for `waku --role worker --agent brief`, mirroring
## `worker_gather.nim`. The live entrypoint (stdin read,
## `buildWorkerApp`, `runBriefHeadless`, stdout write) stays in
## `waku.nim` so this module and its tests stay offline: inject
## `BriefFn`, get back the exact child lines to emit.
##
## - valid task -> `event` (briefing ready), then `done` (reply plus an
##   empty `draft_path`: the worker writes nothing, the parent files)
## - invalid task or brief raising -> single `error`, never raises
##
## No `cost` line: the loop does not report token counts through this
## seam, and no usage in the state means no model call happened — the
## same no-invented-charge rule as slice 10.

import std/json

import ./delegation
import ./wire

type
  BriefFn* = proc(): JsonNode {.closure.}
    ## Run one briefing and return its final state (`reply` and an
    ## empty `draft_path`). Tests inject recordings; live code passes a
    ## closure over `runBriefHeadless`.

proc runBriefWorker*(task: JsonNode, brief: BriefFn): seq[JsonNode] =
  ## One headless brief turn. `agent` is always "brief", `pid` is 0
  ## (the parent stamps the observed pid on receipt).
  var err = ""
  if not parseTaskLine(task, err):
    return @[makeChildLine("error", "", "", "brief", 0,
      %*{"message": "invalid task: " & err})]
  let traceId = task.jget("trace_id").getStr()
  let turnId = task.jget("turn_id").getStr()
  var state: JsonNode
  try:
    state = brief()
  except CatchableError as exc:
    return @[makeChildLine("error", traceId, turnId, "brief", 0,
      %*{"message": "brief failed: " & exc.msg})]
  let reply = state.jget("reply").getStr()
  let draft = state.jget("draft_path").getStr()
  @[
    makeChildLine("event", traceId, turnId, "brief", 0,
      %*{"kind": "node_end", "node": "brief",
          "reply_len": reply.len}),
    makeChildLine("done", traceId, turnId, "brief", 0,
      %*{"reply": reply, "draft_path": draft}),
  ]
