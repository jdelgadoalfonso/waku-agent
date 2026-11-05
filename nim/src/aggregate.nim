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

proc messageEvent*(fromAgent, toAgent, traceId, turnId,
    kind: string): JsonNode =
  ## One live wave worker <-> orchestrator for the existing tickers.
  ## `kind` is the closed set `task|partial|done|error`; anything else
  ## is stored as-is and the dashboard treats unknown kinds as `partial`.
  ## Same `trace_id`/`turn_id` stamp as `delegationEvent` so a turn reads
  ## across processes with no new polling loop.
  %*{"from": fromAgent, "to": toAgent, "trace_id": traceId,
      "turn_id": turnId, "kind": kind}

proc doneAgents*(delegations, completions: seq[JsonNode]): JsonNode =
  ## Lot 4: SSE `done` agents per delegation, in delegation order.
  ## One row `{agent, route, reason, path, cost}` per delegation edge:
  ## `agent` is the delegated `workflow`, `route` its `target`, `reason`
  ## its reason; the matching `worker_done` (same agent+turn) fills
  ## `path` and `cost` (numeric `cost`/`cost_usd`, one charge wins).
  ## Pure and offline; no delegation reads empty, never an error.
  result = newJArray()
  for d in delegations:
    if d.kind != JObject:
      continue
    let agent = d.jget("workflow").getStr()
    if agent.len == 0:
      continue
    var route = d.jget("target").getStr()
    var reason = d.jget("reason").getStr()
    var path = newJArray()
    var cost = 0.0
    for c in completions:
      if c.kind != JObject:
        continue
      if c.jget("agent").getStr() != agent:
        continue
      if d.jget("turn_id").getStr().len > 0 and
         c.jget("turn_id").getStr().len > 0 and
         c.jget("turn_id").getStr() != d.jget("turn_id").getStr():
        continue
      if c.jget("route").getStr().len > 0:
        route = c.jget("route").getStr()
      elif c.jget("target").getStr().len > 0:
        route = c.jget("target").getStr()
      if c.jget("reason").getStr().len > 0:
        reason = c.jget("reason").getStr()
      let p = c.jget("path")
      if p.kind == JArray:
        path = copy(p)
      let v = c.jget("cost_usd")
      let w = c.jget("cost")
      if v.kind == JFloat:
        cost = v.getFloat()
      elif v.kind == JInt:
        cost = float(v.getBiggestInt())
      elif w.kind == JFloat:
        cost = w.getFloat()
      elif w.kind == JInt:
        cost = float(w.getBiggestInt())
      break
    result.add(%*{"agent": agent, "route": route, "reason": reason,
                   "path": path, "cost": cost})
