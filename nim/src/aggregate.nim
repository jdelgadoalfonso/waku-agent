## Aggregate — lot 1 T1.3: single-writer trace aggregation.
##
## Workers never touch runtime data. They emit child lines on stdout
## (see `delegation.nim`); only the orchestrator writes to
## `.waku/traces/`, `usage.jsonl`, and the DB via its own `Tracer`.
## This module is the pure mapping from a child line to the
## `(kind, ev)` pair the parent passes to `Tracer.event`, plus the
## `delegation` edge the dashboard lights like `route`.
##
## Mapping (child `type` -> trace `kind`):
## - text -> "text" (the tracer skips it; it is SSE-only)
## - event -> payload["kind"] when present, else "agent_event"
## - cost -> "cost"
## - done -> "worker_done"
## - error -> "worker_error"
## Every mapped `ev` is the payload stamped with
## `{agent, pid, trace_id, turn_id}` so a turn reads across processes.

import std/json

import ./wire

proc stampChild*(child: JsonNode): JsonNode =
  ## Payload copy stamped with the worker identity and turn ids.
  ## Non-object payloads become `{}` before stamping, like the
  ## contract's coercion.
  var ev = child.jget("payload")
  if ev.kind != JObject:
    ev = %*{}
  else:
    ev = copy(ev)
  ev["agent"] = %child.jget("agent").getStr()
  ev["pid"] = %child.jget("pid").getInt(0)
  ev["trace_id"] = %child.jget("trace_id").getStr()
  ev["turn_id"] = %child.jget("turn_id").getStr()
  ev

proc traceKindFor*(child: JsonNode): string =
  ## Trace kind for one validated child line.
  let t = child.jget("type").getStr()
  case t
  of "text":
    "text"
  of "event":
    let k = child.jget("payload").jget("kind").getStr()
    if k.len > 0: k else: "agent_event"
  of "cost":
    "cost"
  of "done":
    "worker_done"
  of "error":
    "worker_error"
  else:
    "agent_event"

proc toTraceEvent*(child: JsonNode): tuple[kind: string, ev: JsonNode] =
  ## The pair the parent hands to `Tracer.event`.
  (kind: traceKindFor(child), ev: stampChild(child))

proc delegationEvent*(fromAgent, toAgent, traceId, turnId, route,
    reason: string): JsonNode =
  ## One edge orchestrator -> worker, shaped like the engine's
  ## `route` event (`workflow/router/target`) so `graph.js` can light
  ## it with the same code path.
  %*{"workflow": toAgent, "router": fromAgent, "target": route,
      "trace_id": traceId, "turn_id": turnId, "reason": reason}
