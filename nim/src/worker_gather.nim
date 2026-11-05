## Worker gather — lot 1 T1.4: gather as a headless worker turn.
##
## Pure turn logic for `waku --role worker --agent gather`. The live
## entrypoint (stdin read, `buildCliApp`, `runGather`, stdout write)
## stays in `waku.nim` so this module and its tests stay offline:
## inject `GatherFn`, get back the exact child lines to emit.
##
## - valid task -> `event` (digest ready) then `done` (reply + draft)
## - invalid task or gather raising -> single `error`, never raises

import std/json

import ./delegation
import ./wire

type
  GatherFn* = proc(): JsonNode {.closure.}
    ## Run one gather and return its final state (`digest`,
    ## `draft_path`). Tests inject recordings; live code passes a
    ## closure over `runGather`.

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
    makeChildLine("done", traceId, turnId, "gather", 0,
      %*{"reply": digest, "draft_path": draft}),
  ]
