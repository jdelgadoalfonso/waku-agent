## Delegation contract — lot 1 T1.1: parent <-> worker over stdio JSON.
##
## One user turn = one `trace_id`. The orchestrator mints it (reuse
## `trace.mintTurnId`) and passes it down. Only the orchestrator writes
## to `.waku/traces/`, `usage.jsonl`, and the DB; workers never touch
## runtime data directly. Workers emit events on stdout, the parent
## aggregates them into the turn `meta`.
##
## Wire format (one JSON object per line, raw UTF-8 with `$`, like the
## trace JSONL):
##
## parent -> child on stdin:
##   {"v":1,"trace_id":"t_..","turn_id":"t_..","task":"...","context":"",
##    "budget":{"timeout_ms":30000,"max_tool_calls":8}}
##
## child -> parent on stdout (`type` in `text|event|cost|done|error`):
##   {"v":1,"type":"event","trace_id":"t_..","turn_id":"t_..",
##    "agent":"gather","pid":0,"payload":{...}}
##
## `pid` is filled by the parent when it can observe the child pid; a
## worker may leave it 0. This module stays pure and offline: build,
## parse, and validate only. No spawning, no file IO, no `getpid`
## (that would widen the dependency surface), so tests stay
## deterministic.

import std/json

import ./wire

const delegationVersion* = 1

const childTypes* = @["text", "event", "cost", "done", "error"]

proc isKnownChildType*(t: string): bool =
  t in childTypes

proc makeTaskLine*(traceId, turnId, task, context: string, timeoutMs,
    maxToolCalls: int): JsonNode =
  ## One stdin line for the worker. Empty task is allowed here (the
  ## worker rejects it); transport must not lose the turn either way.
  %*{"v": delegationVersion, "trace_id": traceId, "turn_id": turnId,
      "task": task, "context": context,
      "budget": {"timeout_ms": timeoutMs, "max_tool_calls": maxToolCalls}}

proc taskMessage*(task: JsonNode): string =
  ## The user text of a well-formed task line (`task` on the wire, not
  ## to confuse with the triage state key `message`). Missing or
  ## non-string reads as "" — an empty task fails open downstream.
  task.jget("task").getStr("")

proc parseTaskLine*(node: JsonNode, err: var string): bool =
  ## Structural validation only. Returns true when the node is a
  ## well-formed task line; otherwise false with `err` naming the
  ## first missing or mistyped field.
  if node.kind != JObject:
    err = "task line must be an object"
    return false
  if node.jget("v").getInt(-1) != delegationVersion:
    err = "unsupported v"
    return false
  if node.jget("trace_id").getStr().len == 0:
    err = "missing trace_id"
    return false
  if node.jget("turn_id").getStr().len == 0:
    err = "missing turn_id"
    return false
  if node.jget("task").kind != JString:
    err = "missing task"
    return false
  let budget = node.jget("budget")
  if budget.kind != JObject:
    err = "missing budget"
    return false
  if budget.jget("timeout_ms").kind != JInt:
    err = "missing budget.timeout_ms"
    return false
  if budget.jget("max_tool_calls").kind != JInt:
    err = "missing budget.max_tool_calls"
    return false
  err = ""
  true

proc makeChildLine*(childType, traceId, turnId, agent: string, pid: int,
    payload: JsonNode): JsonNode =
  ## One stdout line from the worker. `payload` must be an object;
  ## non-object payloads become `{}` rather than a half-drawn row.
  var safe = payload
  if safe.kind != JObject:
    safe = %*{}
  %*{"v": delegationVersion, "type": childType, "trace_id": traceId,
      "turn_id": turnId, "agent": agent, "pid": pid, "payload": safe}

proc parseChildLine*(node: JsonNode, err: var string): bool =
  ## Structural validation only. `pid` may be 0 (unknown); `agent`
  ## must name the worker; `type` must be a known child type.
  if node.kind != JObject:
    err = "child line must be an object"
    return false
  if node.jget("v").getInt(-1) != delegationVersion:
    err = "unsupported v"
    return false
  if not isKnownChildType(node.jget("type").getStr()):
    err = "unknown type"
    return false
  if node.jget("trace_id").getStr().len == 0:
    err = "missing trace_id"
    return false
  if node.jget("turn_id").getStr().len == 0:
    err = "missing turn_id"
    return false
  if node.jget("agent").getStr().len == 0:
    err = "missing agent"
    return false
  if node.jget("pid").kind != JInt:
    err = "missing pid"
    return false
  if node.jget("payload").kind != JObject:
    err = "missing payload"
    return false
  err = ""
  true
