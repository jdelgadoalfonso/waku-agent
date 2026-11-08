## Observability page — port of the page half of `waku/ops/observability.py`.
##
## Spec 012 page: turns as traces, tools by source and treg endpoint,
## memory, spend and evals — read from this home's traces and ledger
## only. The v2 event core (source/span/outcome/describe, GenAI names)
## lives in `observe.nim`; this module reads the files and builds what
## the page draws. `GET /api/observability` serves `payload`.
##
## Encoding errors are always empty here: trace files are read as bytes
## and bad lines skipped (the Linux-first rule — the GBK guard upstream
## keeps is skipped like `trace.nim` skips it). `parseTsMs` moved here
## from `dashboard.nim` so both readers share the one stamp parser.

import std/algorithm
import std/json
import std/math
import std/os
import std/strutils
import std/syncio
import std/times

import ./brain
import ./memory_live
import ./observe
import ./pricing
import ./skills
import ./turn_evals
import ./wire

proc parseTsMs*(raw: string): (bool, int64) =
  ## `"2026-10-01T12:00:01.123+00:00"` → unix millis. The tracer always
  ## writes `+00:00`, but any numeric `Z`/`±HH:MM` offset is honored, and
  ## the `T` may be a space (SQLite `datetime('now')` stamps) — Python's
  ## `fromisoformat` reads both. Anything else fails closed to
  ## `(false, 0)` — Python's `fromisoformat` → `None` path — so one bad
  ## stamp blanks a latency, never the page.
  let s = raw.strip()
  if s.len < 19 or (s[10] != 'T' and s[10] != ' ') or s[4] != '-' or
      s[7] != '-' or s[13] != ':' or s[16] != ':':
    return (false, 0)
  var nums: array[6, int]
  try:
    nums = [parseInt(s[0 .. 3]), parseInt(s[5 .. 6]), parseInt(s[8 .. 9]),
            parseInt(s[11 .. 12]), parseInt(s[14 .. 15]),
            parseInt(s[17 .. 18])]
  except ValueError:
    return (false, 0)
  if nums[1] notin 1 .. 12 or nums[2] notin 1 .. 31 or
      nums[3] notin 0 .. 23 or nums[4] notin 0 .. 59 or
      nums[5] notin 0 .. 60:
    return (false, 0)
  var rest = if s.len > 19: s[19 .. ^1] else: ""
  var millis = 0
  if rest.startsWith("."):
    var k = 1
    var digits = ""
    while k < rest.len and rest[k] in {'0' .. '9'}:
      if digits.len < 3:
        digits.add(rest[k])
      inc k
    if digits.len == 0:
      return (false, 0)
    while digits.len < 3:
      digits.add('0')
    try:
      millis = parseInt(digits)
    except ValueError:
      return (false, 0)
    rest = if k < rest.len: rest[k .. ^1] else: ""
  var offsetMin = 0
  if rest == "" or rest == "Z":
    discard
  elif (rest[0] == '+' or rest[0] == '-') and rest.len == 6 and
      rest[3] == ':':
    try:
      offsetMin = parseInt(rest[1 .. 2]) * 60 + parseInt(rest[4 .. 5])
      if rest[0] == '-':
        offsetMin = -offsetMin
    except ValueError:
      return (false, 0)
  else:
    return (false, 0)
  try:
    let dt = dateTime(nums[0], Month(nums[1]), MonthdayRange(nums[2]),
                      HourRange(nums[3]), MinuteRange(nums[4]),
                      SecondRange(nums[5]), zone = utc())
    return (true, toUnix(toTime(dt)) * 1000 + millis.int64 -
      offsetMin.int64 * 60000)
  except CatchableError:
    return (false, 0)

const
  windows* = ["today", "7d", "all"]
    ## The windows the page draws.

proc validWindow*(window: string): string =
  ## `window` when the page knows it, else the default `7d` — the route
  ## falls back the same way Python's `payload` does.
  if window in windows: window else: "7d"

proc localMidnightMs*(nowMs: int64): int64 =
  ## Local midnight before `nowMs`, in unix millis: the "today" window
  ## starts where the machine's day does, like Python's `window_start`.
  let lt = fromUnix(nowMs div 1000).local
  toUnix(toTime(dateTime(lt.year, lt.month, lt.monthday,
                         0, 0, 0, 0, lt.timezone))) * 1000

proc windowStartMs*(window: string, nowMs: int64): int64 =
  ## When a window starts, in unix millis: local midnight for "today",
  ## 168 hours back for "7d", -1 (the beginning) for "all".
  case validWindow(window)
  of "today":
    localMidnightMs(nowMs)
  of "7d":
    nowMs - 7 * 86400 * 1000
  else:
    -1

proc inStartMs*(ts: string, startMs: int64): bool =
  ## Whether one stamp falls at or after `startMs` (-1 matches all).
  ## Unparsable stamps never match — the `_ts` → None path.
  if startMs < 0:
    return true
  let (ok, ms) = parseTsMs(ts)
  ok and ms >= startMs

proc inWindow*(ts: string, window: string, nowMs: int64): bool =
  ## Whether one `ts` stamp falls in `window` at `nowMs`. Unparsable
  ## stamps never match (except under "all") — Python's `_ts` → None
  ## path, which fails the `>= start` comparison the same way.
  inStartMs(ts, windowStartMs(window, nowMs))

proc readEvents*(home: string): tuple[events: seq[JsonNode],
    errors: seq[JsonNode], files: seq[string]] =
  ## `(events, encoding errors, trace file names), oldest first`. Bad
  ## lines are skipped; a missing traces dir reads empty. Encoding
  ## errors stay empty (see the module header).
  result = (events: @[], errors: @[], files: @[])
  let dir = home / "traces"
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".jsonl"):
        result.files.add(extractFilename(path))
  result.files = sorted(result.files)
  for name in result.files:
    var text = ""
    try:
      text = readFile(dir / name)
    except IOError, OSError:
      continue
    for line in text.splitLines():
      if line.strip().len == 0:
        continue
      try:
        let ev = parseJson(line)
        if ev.kind == JObject:
          result.events.add(ev)
      except JsonParsingError:
        continue
  return result

proc groupTurns*(events: seq[JsonNode]): seq[JsonNode] =
  ## Events between `turn_start` and `turn_end`, one dict per turn,
  ## oldest first. A `turn_end` with no turn is ignored, `text` deltas
  ## never join, and an unclosed turn is kept as unfinished.
  result = @[]
  var current = newJNull()
  for ev in events:
    if ev.kind != JObject:
      continue
    let kind = ev.jget("type").getStr()
    if kind == "turn_start":
      if current.kind == JObject:
        current["unfinished"] = %true
        result.add(current)
      let msg = ev.jget("user_message")
      current = %*{"turn_id": ev.jget("turn_id").getStr(),
        "ts": ev.jget("ts"),
        "user_message": (if msg.kind == JString: msg.getStr() else: ""),
        "events": newJArray()}
    elif current.kind == JObject:
      if kind == "turn_end":
        current["end_ts"] = copy(ev.jget("ts"))
        current["iterations"] = copy(ev.jget("iterations"))
        let reply = ev.jget("reply")
        current["reply"] = if reply.kind == JString: copy(reply) else: %""
        result.add(current)
        current = newJNull()
      elif kind != "text":
        current["events"].add(copy(ev))
  if current.kind == JObject:
    current["unfinished"] = %true
    result.add(current)
  return result

const
  orchestratorAgent* = "orchestrator"
    ## The router's own name in `aggregate.delegationEvent`: it delegates,
    ## it is never a worker row, or every message would open one.

proc agentName(ev: JsonNode): string =
  ## The worker one event names, or "" when it names none: the child stamp
  ## `agent` first, then a delegation edge's worker (`workflow`, the
  ## `toAgent` of `delegationEvent`), then a message's worker end. The
  ## router side of a message (`from` when the orchestrator sent it) is
  ## skipped so orchestration traffic never reads as an agent of its own.
  ## A kind whitelist would be the wrong seam: every child line is stamped
  ## `agent`, so a worker's `node_end` or `research` counts exactly as its
  ## `worker_done` does.
  result = ev.jget("agent").getStr()
  if result.len > 0:
    return
  case ev.jget("type").getStr()
  of "delegation":
    result = ev.jget("workflow").getStr()
  of "message":
    let sender = ev.jget("from").getStr()
    result = if sender.len > 0 and sender != orchestratorAgent: sender
             else: ev.jget("to").getStr()
  else:
    discard

proc eventCost(ev: JsonNode): float =
  ## One event's dollars. `cost_usd` wins when both keys are numeric: they
  ## name the same charge, so adding both would bill one event twice.
  ## A non-numeric value (`"free"`) is ignored, so a hand-edited line costs
  ## a row 0, never an error.
  for key in ["cost_usd", "cost"]:
    let n = ev.jget(key)
    case n.kind
    of JFloat: return n.getFloat()
    of JInt: return float(n.getBiggestInt())
    else: discard

proc eventRoute(ev: JsonNode): string =
  ## One event's route: its own `route`, else the delegation `target`.
  ## Empty when it names neither, so `last_route` keeps the previous one.
  result = ev.jget("route").getStr()
  if result.len == 0:
    result = ev.jget("target").getStr()

proc rowIndex(names: openArray[string], name: string): int =
  ## Position of `name` in `names`, or -1. A plain scan keeps the rows in
  ## first-appearance order, which is stable across reads of one trace.
  for i in 0 ..< names.len:
    if names[i] == name:
      return i
  return -1

proc agentsSummary*(events: seq[JsonNode]): JsonNode =
  ## Lot 3 T3.4: per-agent observability from the same trace events, in
  ## first-appearance (oldest first) order. One row per worker
  ## `{agent, turns, cost, last_route, pid, state}`: `turns` counts distinct
  ## `turn_id`, `cost` sums each event's one dollar value (`cost_usd`, else
  ## `cost`), `last_route` keeps the newest `route`/`target` seen, `pid`
  ## keeps the newest non-zero stamped `pid` (null when no event names
  ## one), and `state` is `done` once a `worker_done`/`worker_error` is
  ## seen, else `running` (`cost` alone never flips it, so a late charge
  ## cannot resurrect a finished worker and a new delegation/message
  ## returns it to `running`). Pure and offline, so `/api/observability`
  ## aggregates per agent from the one trace read it already does — no new
  ## polling loop. A trace with no worker events reads `[]`, and unknown
  ## shapes are skipped, never an error.
  result = newJArray()
  var names: seq[string] = @[]
  var turnIds: seq[seq[string]] = @[]
  for ev in events:
    if ev.kind != JObject:
      continue
    let name = agentName(ev)
    if name.len == 0:
      continue
    var idx = rowIndex(names, name)
    if idx < 0:
      names.add(name)
      turnIds.add(@[])
      result.add(%*{"agent": name, "turns": 0, "cost": 0.0,
        "last_route": "", "pid": newJNull(), "state": "running"})
      idx = names.len - 1
    let turnId = ev.jget("turn_id").getStr()
    if turnId.len > 0 and turnId notin turnIds[idx]:
      turnIds[idx].add(turnId)
      result[idx]["turns"] = %turnIds[idx].len
    let route = eventRoute(ev)
    if route.len > 0:
      result[idx]["last_route"] = %route
    let p = ev.jget("pid")
    var pid = 0
    case p.kind
    of JInt:
      pid = int(p.getBiggestInt())
    of JFloat:
      pid = int(p.getFloat())
    else:
      discard
    if pid != 0:
      result[idx]["pid"] = %pid
    case ev.jget("type").getStr()
    of "worker_done", "worker_error":
      result[idx]["state"] = %"done"
    of "cost", "delegation_error", "turn_error":
      # Charges and error annotations ride the turn but never move it:
      # a late cost cannot resurrect a finished worker, and a recorded
      # failure must not flip a done worker back to running.
      discard
    else:
      result[idx]["state"] = %"running"
    result[idx]["cost"] = %(result[idx]["cost"].getFloat() + eventCost(ev))

const
  outputChars* = 200
    ## What a waterfall row keeps of a tool's answer.

  scoreSources* = ["code", "judge", "human"]
    ## Where a score may come from.

proc preview*(value: JsonNode, limit: int = argsChars): JsonNode =
  ## Redacted, one-line, at most `limit` characters: what the page shows.
  ## Strings that parse as JSON render as their redacted JSON (so a secret
  ## inside a JSON answer masks too); anything else renders as itself.
  var text: string
  if value.kind == JString:
    var parsed: JsonNode = nil
    try:
      parsed = parseJson(value.getStr())
    except JsonParsingError:
      discard
    text = if not parsed.isNil: $(redact(parsed))
           else: redact(value).getStr()
  else:
    text = $(redact(value))
  let flat = text.splitWhitespace().join(" ")
  if flat.len <= limit: %flat else: %(trimText(flat, limit))

proc stepRow*(ev: JsonNode, servers: openArray[string] = [],
    provider: string = "", model: string = ""): JsonNode =
  ## One waterfall row from one trace event, or null for an event the
  ## waterfall does not draw (graph bookkeeping, scores).
  if ev.kind != JObject:
    return newJNull()
  let kind = ev.jget("type").getStr()
  if kind notin ["gate", "llm", "tool", "consolidation", "report",
      "receipt", "triage", "route"]:
    return newJNull()
  let span = case kind
    of "gate": "gate"
    of "llm": "llm"
    of "consolidation", "report": "memory_write"
    of "receipt": "receipt"
    of "triage", "route": "route"
    else: ""
  result = %*{"kind": kind, "span": span, "ts": ev.jget("ts")}
  let node = ev.jget("node")
  result["node"] = if node.kind == JString: copy(node) else: newJNull()
  case kind
  of "gate":
    result["decision"] = copy(ev.jget("decision"))
    result["reason"] = %(trimText(ev.jget("reason").getStr(), 160))
  of "llm":
    let usage = ev.jget("usage")
    let usageObj = if usage.kind == JObject: usage else: newJObject()
    let callModel = ev.jget("model").getStr()
    let callModelName = if callModel.len > 0: callModel else: model
    proc usageNum(key: string): int =
      let v = usageObj.jget(key)
      if v.kind == JInt: max(int(v.getBiggestInt()), 0) else: 0
    let nIn = usageNum("in")
    let nOut = usageNum("out")
    let stamped = ev.jget("cost_usd")
    var usd = 0.0
    if stamped.kind == JFloat:
      usd = stamped.getFloat()
    elif stamped.kind == JInt:
      usd = float(stamped.getBiggestInt())
    else:
      let prov = ev.jget("provider").getStr()
      usd = llmCost(if prov.len > 0: prov else: provider,
                     callModelName, usageObj)
    let callKind = ev.jget("kind").getStr()
    result["call"] = %(if callKind.len > 0: callKind else: "loop")
    result["model"] = %callModelName
    result["in"] = %nIn
    result["out"] = %nOut
    result["usd"] = %(round(usd * 1e6) / 1e6)
    result["stop_reason"] = copy(ev.jget("stop_reason"))
    let fin = ev.jget("final_answer")
    result["final_answer"] = %(fin.kind == JBool and fin.getBool())
  of "tool":
    let info = describe(ev, servers)
    let src = info.jget("source").getStr()
    result["kind"] = %(if src == "waku_memory": "memory" else: "tool")
    result["span"] = copy(info.jget("span"))
    result["tool"] = %(ev.jget("tool").getStr())
    result["source"] = %src
    result["args"] = preview(ev.jget("args"), argsChars)
    result["output"] = preview(ev.jget("output"), outputChars)
    result["ok"] = copy(info.jget("ok"))
    if info.hasKey("error"):
      result["error"] = copy(info.jget("error"))
    let ms = ev.jget("duration_ms")
    result["duration_ms"] = if ms.kind == JInt: copy(ms) else: newJNull()
    if info.hasKey("cost_usd"):
      result["usd"] = copy(info.jget("cost_usd"))
    if info.hasKey("endpoint_id"):
      result["endpoint_id"] = copy(info.jget("endpoint_id"))
    if info.hasKey("provider"):
      result["provider"] = copy(info.jget("provider"))
    result["read_first"] = %(ev.jget("read_first").getBool())
    if src == "waku_memory":
      for key in ["query", "results", "retrieval_trace_id"]:
        if info.hasKey(key):
          result[key] = copy(info.jget(key))
  of "consolidation":
    var kept: seq[JsonNode] = @[]
    let keptEv = ev.jget("kept")
    if keptEv.kind == JArray:
      for k in keptEv:
        if k.kind == JObject:
          kept.add(k)
    let nf = ev.jget("new_facts")
    result["new_facts"] = if nf.kind == JInt: copy(nf) else: %kept.len
    var sent = 0
    var localOnly = 0
    var facts = newJArray()
    for k in kept:
      let sentFlag = k.jget("sent")
      if sentFlag.kind == JBool:
        if sentFlag.getBool():
          inc sent
        else:
          inc localOnly
      if facts.len < 5:
        facts.add(%(trimText(k.jget("content").getStr(), 160)))
    result["sent"] = %sent
    result["local_only"] = %localOnly
    result["facts"] = facts
  of "report":
    result["memory_id"] = copy(ev.jget("memory_id"))
    result["title"] = %(trimText(ev.jget("title").getStr(), 120))
  of "receipt":
    result["total_usd"] = copy(ev.jget("total_usd"))
    result["credits"] = copy(ev.jget("credits"))
    let m = ev.jget("model")
    result["estimate"] = if m.kind == JObject and m.hasKey("estimate"):
      copy(m.jget("estimate")) else: %true
  of "triage", "route":
    var detail = ev.jget("target").getStr()
    if detail.len == 0:
      detail = ev.jget("route").getStr()
    let reason = ev.jget("reason").getStr()
    if reason.len > 0:
      detail = detail & ": " & reason
    result["detail"] = %(trimText(detail, 160))
  else:
    return newJNull()
  return result

proc scoreOf*(ev: JsonNode): JsonNode =
  ## One score from a `score` trace event, or null when it names no
  ## numeric value. A judge score also says which model judged and what
  ## the call cost.
  if ev.kind != JObject or ev.jget("type").getStr() != "score":
    return newJNull()
  let value = ev.jget("value")
  if value.kind == JBool or (value.kind != JInt and value.kind != JFloat):
    return newJNull()
  let source = ev.jget("source").getStr()
  result = %*{"source": (if source in scoreSources: source else: "code"),
    "name": ev.jget("name").getStr(), "value": value, "note": ""}
  result["name"] = %(trimText(ev.jget("name").getStr(), 60))
  result["note"] = %(trimText(redact(%(ev.jget("note").getStr())).getStr(), 200))
  let judge = ev.jget("judge")
  if judge.kind == JString and judge.getStr().len > 0:
    result["judge"] = %(trimText(judge.getStr(), 80))
  let cost = ev.jget("cost_usd")
  if cost.kind == JInt or cost.kind == JFloat:
    result["cost_usd"] = copy(cost)
  let ts = ev.jget("ts")
  if ts.kind == JString:
    result["ts"] = copy(ts)
  return result

proc storedScores*(turn: JsonNode, extra: seq[JsonNode] = @[]): seq[JsonNode] =
  ## The turn's written scores (a judge's, a human's): those inside the
  ## turn that name no other turn, and those joined to it by turn_id.
  ## When one source scored one name twice, the newest wins. The five
  ## code checks (`turn_evals.run_checks`, spec 015) run first in
  ## `build_turn`; this list appends the scores written for the turn.
  let own = turn.jget("turn_id").getStr()
  var fresh: seq[tuple[key: string, ts: string, score: JsonNode]] = @[]
  proc consider(ev: JsonNode) =
    let s = scoreOf(ev)
    if s.kind == JNull:
      return
    let key = s.jget("source").getStr() & "\x00" & s.jget("name").getStr()
    let ts = s.jget("ts").getStr()
    for i in 0 ..< fresh.len:
      if fresh[i].key == key:
        if ts >= fresh[i].ts:
          fresh[i] = (key, ts, s)
        return
    fresh.add((key, ts, s))
  let events = turn.jget("events")
  if events.kind == JArray:
    for ev in events:
      if ev.kind == JObject and ev.jget("type").getStr() == "score" and
          (ev.jget("turn_id").getStr().len == 0 or
           ev.jget("turn_id").getStr() == own):
        consider(ev)
  for ev in extra:
    consider(ev)
  for (_, _, s) in fresh:
    result.add(s)

proc runsEndpoint*(name: string): bool =
  ## Whether a treg tool runs an endpoint: `treg_call` and every
  ## `treg_catalog_call_*`, failed calls included.
  let short = if name.startsWith(tregPrefix): name[tregPrefix.len .. ^1]
              else: ""
  short == "call" or short.startsWith("call_") or
    short.startsWith("catalog_call")

proc groupLoops*(steps: var seq[JsonNode]): int =
  ## Give every step its place in the loop: `loop` 0 and phase "before"
  ## for what runs before the model's first call, `loop` n and phase
  ## "loop" for iteration n, phase "after" for what follows the reply. A
  ## loop model call (kind "loop", or no kind on an old line) starts the
  ## next iteration; a side call never does. Returns the iterations.
  var n = 0
  var after = false
  for step in steps.mitems:
    let call = step.jget("call")
    let isLoopCall = step.jget("kind").getStr() == "llm" and
      (call.kind == JNull or
       (call.kind == JString and call.getStr() == "loop"))
    if isLoopCall:
      n += 1
      after = false
      step["loop"] = %n
      step["phase"] = %"loop"
      let sr = step.jget("stop_reason")
      after = not (sr.kind == JNull or
        (sr.kind == JString and sr.getStr() == "tool_use"))
      continue
    step["loop"] = %n
    let kind = step.jget("kind").getStr()
    step["phase"] = if after or
        (n > 0 and kind in ["consolidation", "report", "receipt"]):
      %"after"
    elif n > 0:
      %"loop"
    else:
      %"before"
  n

proc graphOf*(events: JsonNode): JsonNode =
  ## The graph workflow a turn ran through, when it ran through one.
  if events.kind != JArray:
    return newJNull()
  var start = newJNull()
  var finish = newJNull()
  var path: seq[string] = @[]
  for e in events:
    if e.kind != JObject:
      continue
    case e.jget("type").getStr()
    of "graph_start":
      start = e
    of "graph_end":
      finish = e
    of "node_start":
      let node = e.jget("node").getStr()
      if node.len > 0:
        path.add(node)
    else:
      discard
  if start.kind == JNull:
    return newJNull()
  var ms = newJNull()
  if finish.kind == JObject:
    let m = finish.jget("ms")
    if m.kind == JInt:
      ms = copy(m)
  var err = newJNull()
  if finish.kind == JObject:
    let e = finish.jget("error")
    if e.kind == JString and e.getStr().len > 0:
      err = %(trimText(e.getStr(), 160))
  var endPath: seq[string] = @[]
  if finish.kind == JObject:
    let p = finish.jget("path")
    if p.kind == JArray:
      for item in p:
        let s = if item.kind == JString: item.getStr() else: $item
        if s.len > 0:
          endPath.add(s)
  if endPath.len == 0:
    endPath = path
  %*{"workflow": start.jget("workflow").getStr(), "path": endPath,
     "ms": ms, "error": err}

proc storyOf*(turn: JsonNode): seq[JsonNode] =
  ## The turn in one line, in order: question, the gate, memories used,
  ## loops (and the final answer, when they hit the limit), treg
  ## endpoint calls and their dollars, a saved report. Each part names
  ## the row it opens.
  let steps = turn.jget("steps")
  proc first(kinds: openArray[string]): int =
    if steps.kind != JArray:
      return -1
    for i in 0 ..< steps.len:
      let s = steps[i]
      if s.kind != JObject:
        continue
      if s.jget("span").getStr() in kinds or s.jget("kind").getStr() in kinds:
        return i
    -1
  result = @[%*{"part": "question", "text": "question"}]
  let gate = turn.jget("gate").getStr()
  if gate.len > 0:
    result.add(%*{"part": "gate", "text": "gate " & gate,
      "step": first(["gate"])})
  let used = turn.jget("used")
  if used.kind == JInt and used.getBiggestInt() > 0:
    let n = used.getBiggestInt()
    result.add(%*{"part": "memories",
      "text": $n & " memor" & (if n == 1: "y" else: "ies"),
      "step": first(["retrieval"])})
  let loops = turn.jget("loops").getInt(0)
  if loops > 0:
    result.add(%*{"part": "loops",
      "text": $loops & " loop" & (if loops == 1: "" else: "s"),
      "loop": 1})
  if steps.kind == JArray:
    for i in 0 ..< steps.len:
      let s = steps[i]
      if s.kind == JObject and s.jget("final_answer").kind == JBool and
          s.jget("final_answer").getBool():
        result.add(%*{"part": "limit",
          "text": "limit reached → final answer", "step": i})
        break
  var treg: seq[int] = @[]
  var tregUsd = 0.0
  if steps.kind == JArray:
    for i in 0 ..< steps.len:
      let s = steps[i]
      if s.kind == JObject and s.jget("source").getStr() == "treg" and
          runsEndpoint(s.jget("tool").getStr()):
        treg.add(i)
        let u = s.jget("usd")
        if u.kind == JFloat:
          tregUsd += u.getFloat()
        elif u.kind == JInt:
          tregUsd += float(u.getBiggestInt())
  if treg.len > 0:
    result.add(%*{"part": "treg",
      "text": $treg.len & " treg call" &
        (if treg.len == 1: "" else: "s"),
      "usd": round(tregUsd * 1e6) / 1e6, "step": treg[0]})
  let report = first(["report"])
  if report >= 0:
    result.add(%*{"part": "report", "text": "report saved",
      "step": report})
  return result

proc hotspots*(steps: var seq[JsonNode]): JsonNode =
  ## The one slowest and the one most expensive leaf step, as indexes
  ## into `steps`, and a `hot` label on each. A tie goes to the earlier
  ## step; fewer than two leaves mark nothing.
  var leaves: seq[int] = @[]
  for i in 0 ..< steps.len:
    let s = steps[i]
    if s.kind == JObject and s.jget("kind").getStr() in
        ["llm", "tool", "memory"]:
      leaves.add(i)
  result = %*{"slowest": newJNull(), "most_usd": newJNull()}
  if leaves.len < 2:
    return result
  for (key, field, label) in
      [("slowest", "span_ms", "slowest"), ("most_usd", "usd", "most $")]:
    var best = -1
    for i in leaves:
      let v = steps[i].jget(field)
      let num = if v.kind == JFloat: v.getFloat()
                elif v.kind == JInt: float(v.getBiggestInt())
                else: 0.0
      if num > 0:
        if best < 0:
          best = i
        else:
          let b = steps[best].jget(field)
          let bnum = if b.kind == JFloat: b.getFloat()
                     elif b.kind == JInt: float(b.getBiggestInt())
                     else: 0.0
          if num > bnum:
            best = i
    if best >= 0:
      result[key] = %best
      if not steps[best].hasKey("hot"):
        steps[best]["hot"] = newJArray()
      steps[best]["hot"].add(%label)
  return result

proc turnErrors*(steps: seq[JsonNode]): seq[JsonNode] =
  ## Every failed step, with the loop it ran in and the first line of
  ## its error.
  for i in 0 ..< steps.len:
    let s = steps[i]
    if s.kind != JObject:
      continue
    let ok = s.jget("ok")
    if ok.kind == JBool and not ok.getBool():
      let err = s.jget("error").getStr()
      let firstLine = if err.len > 0: err.strip().split("\n", 1)[0]
                      else: "failed"
      result.add(%*{"step": i, "loop": s.jget("loop"),
        "phase": s.jget("phase"), "tool": s.jget("tool").getStr(),
        "endpoint_id": s.jget("endpoint_id"),
        "error": firstLine[0 ..< min(errorChars, firstLine.len)]})

proc buildTurn*(turn: JsonNode, servers: openArray[string] = [],
    provider: string = "", model: string = "",
    extraScores: seq[JsonNode] = @[], research = false): JsonNode =
  ## A turn with its steps in order, its time, its dollars and its
  ## scores: the five code checks (`turn_evals.run_checks`, spec 015),
  ## run on every read, then any score written for it (a judge's).
  var steps: seq[JsonNode] = @[]
  let events = turn.jget("events")
  if events.kind == JArray:
    for ev in events:
      let row = stepRow(ev, servers, provider, model)
      if row.kind != JNull:
        steps.add(row)
  let (okStart, startMs) = parseTsMs(turn.jget("ts").getStr())
  var endMs = startMs
  var hasEnd = false
  let (okEnd, endStamp) = parseTsMs(turn.jget("end_ts").getStr())
  if okEnd:
    endMs = endStamp
    hasEnd = okStart
  else:
    for s in steps:
      let (ok, ms) = parseTsMs(s.jget("ts").getStr())
      if ok and (not hasEnd or ms > endMs):
        endMs = ms
        hasEnd = true
  var previous = if okStart: startMs else: -1
  for s in steps.mitems:
    let (ok, ms) = parseTsMs(s.jget("ts").getStr())
    if ok and okStart:
      s["at_ms"] = %(ms - startMs)
    else:
      s["at_ms"] = newJNull()
    var spanMs = -1
    if ok and previous >= 0:
      spanMs = int(ms - previous)
    let own = s.jget("duration_ms")
    if own.kind == JInt:
      spanMs = int(own.getBiggestInt())
    s["span_ms"] = if spanMs >= 0: %spanMs else: newJNull()
    if ok:
      previous = ms
  let loops = groupLoops(steps)
  var receiptRow = newJNull()
  for s in steps:
    if s.jget("kind").getStr() == "receipt":
      receiptRow = s
  var stepsUsd = 0.0
  for s in steps:
    if s.jget("kind").getStr() in ["llm", "tool", "memory"]:
      let u = s.jget("usd")
      if u.kind == JFloat:
        stepsUsd += u.getFloat()
      elif u.kind == JInt:
        stepsUsd += float(u.getBiggestInt())
  var total = stepsUsd
  let rt = receiptRow.jget("total_usd")
  if receiptRow.kind != JNull and (rt.kind == JInt or rt.kind == JFloat):
    total = if rt.kind == JFloat: rt.getFloat()
            else: float(rt.getBiggestInt())
  var memory: JsonNode = newJNull()
  if events.kind == JArray:
    for ev in events:
      if ev.kind == JObject and ev.jget("type").getStr() == "receipt":
        let m = ev.jget("memory")
        if m.kind == JObject:
          memory = m
  var consolidation = newJNull()
  for s in steps:
    if s.jget("kind").getStr() == "consolidation":
      consolidation = s
      break
  let usedNode = if memory.kind == JObject: memory.jget("used")
                 else: newJNull()
  var kept: JsonNode = newJNull()
  if memory.kind == JObject and memory.hasKey("kept"):
    let k = memory.jget("kept")
    kept = if k.kind == JArray: %k.len else: newJNull()
  elif consolidation.kind != JNull:
    kept = copy(consolidation.jget("new_facts"))
  var gate = newJNull()
  for s in steps:
    if s.jget("kind").getStr() == "gate":
      gate = copy(s.jget("decision"))
      break
  var toolCalls = 0
  var tokensIn = 0
  var tokensOut = 0
  for s in steps:
    case s.jget("kind").getStr()
    of "tool", "memory":
      inc toolCalls
    of "llm":
      let ii = s.jget("in")
      let oo = s.jget("out")
      if ii.kind == JInt:
        tokensIn += int(ii.getBiggestInt())
      if oo.kind == JInt:
        tokensOut += int(oo.getBiggestInt())
    else:
      discard
  result = %*{"scores": runChecks(turn, usd = %round6(total),
      research = research, servers = servers) & storedScores(turn, extraScores),
    "turn_id": turn.jget("turn_id").getStr(),
    "ts": turn.jget("ts"),
    "user_message": turn.jget("user_message").getStr(),
    "unfinished": turn.jget("unfinished").kind == JBool and
      turn.jget("unfinished").getBool(),
    "latency_ms": (if okStart and hasEnd: %(endMs - startMs)
                   else: newJNull()),
    "usd": round(total * 1e6) / 1e6,
    "has_receipt": receiptRow.kind != JNull,
    "used": usedNode,
    "kept": kept,
    "gate": gate,
    "tool_calls": toolCalls,
    "loops": loops,
    "tokens_in": tokensIn,
    "tokens_out": tokensOut,
    "graph": graphOf(events),
    "hotspots": hotspots(steps),
    "errors": turnErrors(steps),
    "steps": steps}
  result["user_message"] = %(trimText(turn.jget("user_message").getStr(), 200))
  result["story"] = %storyOf(result)
  return result

const maxTurns* = 50
  ## At most this many turns ride a payload, newest first.


proc toolStats*(events: seq[JsonNode], servers: openArray[string] = [],
    window: string = "all", nowMs: int64 = 0): JsonNode =
  ## Tool calls in a window, grouped by source: treg (per tool and per
  ## endpoint), Waku Memory (per tool, with recent queries), and the rest.
  let startMs = windowStartMs(window, nowMs)
  var treg = newJObject()
  var endpoints = newJObject()
  var memory = newJObject()
  var other = newJObject()
  var otherSource = newJObject()
  var memorySpan = newJObject()
  var queries = newJArray()
  proc bucketOf(buckets: JsonNode, name: string): JsonNode =
    if not buckets.hasKey(name):
      buckets[name] = %*{"calls": 0, "errors": 0, "usd": 0.0,
        "priced": 0, "ms_total": 0, "ms_n": 0,
        "results_total": 0, "results_n": 0}
    buckets[name]
  for ev in events:
    if ev.kind != JObject or ev.jget("type").getStr() != "tool" or
        not inStartMs(ev.jget("ts").getStr(), startMs):
      continue
    let name = ev.jget("tool").getStr()
    let info = describe(ev, servers)
    let source = info.jget("source").getStr()
    let short = if source == "waku_memory" and
        name.len > wakuMemoryPrefix.len:
      name[wakuMemoryPrefix.len .. ^1] else: name
    let b = if source == "treg": bucketOf(treg, name)
            elif source == "waku_memory": bucketOf(memory, short)
            else: bucketOf(other, name)
    b["calls"] = %(b.jget("calls").getInt() + 1)
    if not info.jget("ok").getBool(true):
      b["errors"] = %(b.jget("errors").getInt() + 1)
    let cost = info.jget("cost_usd")
    if cost.kind == JInt or cost.kind == JFloat:
      let usd = if cost.kind == JFloat: cost.getFloat()
                else: float(cost.getBiggestInt())
      b["usd"] = %(b.jget("usd").getFloat() + usd)
      b["priced"] = %(b.jget("priced").getInt() + 1)
    let ms = ev.jget("duration_ms")
    if ms.kind == JInt and ms.getBiggestInt() >= 0:
      b["ms_total"] = %(b.jget("ms_total").getInt() +
        int(ms.getBiggestInt()))
      b["ms_n"] = %(b.jget("ms_n").getInt() + 1)
    let res = info.jget("results")
    if res.kind == JInt:
      b["results_total"] = %(b.jget("results_total").getInt() +
        int(res.getBiggestInt()))
      b["results_n"] = %(b.jget("results_n").getInt() + 1)
    if source == "treg":
      if info.hasKey("endpoint_id") and runsEndpoint(name):
        let eid = info.jget("endpoint_id").getStr()
        let eb = bucketOf(endpoints, eid)
        eb["calls"] = %(eb.jget("calls").getInt() + 1)
        eb["provider"] = copy(info.jget("provider"))
        if cost.kind == JInt or cost.kind == JFloat:
          let usd = if cost.kind == JFloat: cost.getFloat()
                    else: float(cost.getBiggestInt())
          eb["usd"] = %(eb.jget("usd").getFloat() + usd)
          eb["priced"] = %(eb.jget("priced").getInt() + 1)
        if ms.kind == JInt and ms.getBiggestInt() >= 0:
          eb["ms_total"] = %(eb.jget("ms_total").getInt() +
            int(ms.getBiggestInt()))
          eb["ms_n"] = %(eb.jget("ms_n").getInt() + 1)
    elif source == "waku_memory":
      memorySpan[short] = copy(info.jget("span"))
      if info.hasKey("query"):
        queries.add(%*{"tool": short,
          "query": info.jget("query"), "results": info.jget("results"),
          "retrieval_trace_id": info.jget("retrieval_trace_id"),
          "ok": info.jget("ok"), "ts": ev.jget("ts")})
    else:
      otherSource[name] = %source
  proc row(name: string, b: JsonNode): JsonNode =
    let priced = b.jget("priced").getInt() > 0
    let msN = b.jget("ms_n").getInt()
    let resN = b.jget("results_n").getInt()
    let usd = if priced: round(b.jget("usd").getFloat() * 1e6) / 1e6
              else: 0.0
    let avgMs = if msN > 0: int(round(b.jget("ms_total").getFloat() /
      msN.float)) else: -1
    let avgRes = if resN > 0:
      round(b.jget("results_total").getFloat() / resN.float * 10) / 10
    else: -1.0
    %*{"tool": name, "calls": b.jget("calls"),
      "errors": b.jget("errors"),
      "usd": (if priced: %usd else: newJNull()),
      "avg_ms": (if msN > 0: %avgMs else: newJNull()),
      "avg_results": (if resN > 0: %avgRes else: newJNull())}
  proc rowsOf(buckets: JsonNode): seq[JsonNode] =
    for name, b in pairs(buckets):
      if name == "":
        continue
      result.add(row(name, b))
    result.sort(proc(x, y: JsonNode): int =
      let c = cmp(y.jget("calls").getInt(), x.jget("calls").getInt())
      if c != 0: c else: cmp(x.jget("tool").getStr(),
                             y.jget("tool").getStr()))
  var endpointRows: seq[JsonNode] = @[]
  for eid, b in pairs(endpoints):
    var r = row(eid, b)
    r["endpoint_id"] = %eid
    r["provider"] = copy(b.jget("provider"))
    endpointRows.add(r)
  endpointRows.sort(proc(x, y: JsonNode): int =
    let xu = if x.jget("usd").kind == JNull: 0.0
             else: x.jget("usd").getFloat()
    let yu = if y.jget("usd").kind == JNull: 0.0
             else: y.jget("usd").getFloat()
    let c = cmp(yu, xu)
    if c != 0: c
    else:
      let d = cmp(y.jget("calls").getInt(), x.jget("calls").getInt())
      if d != 0: d
      else: cmp(x.jget("endpoint_id").getStr(),
                y.jget("endpoint_id").getStr()))
  var tregRows: seq[JsonNode] = @[]
  for r in rowsOf(treg):
    r["span"] = %"tool"
    tregRows.add(r)
  var memoryRows: seq[JsonNode] = @[]
  for r in rowsOf(memory):
    r["span"] = copy(memorySpan.jget(r.jget("tool").getStr()))
    memoryRows.add(r)
  var otherRows: seq[JsonNode] = @[]
  for r in rowsOf(other):
    r["source"] = copy(otherSource.jget(r.jget("tool").getStr()))
    r["span"] = %"tool"
    otherRows.add(r)
  var recent: seq[JsonNode] = @[]
  for i in countdown(queries.len - 1, max(0, queries.len - 5)):
    recent.add(copy(queries[i]))
  proc callsOf(rows: seq[JsonNode]): int =
    for r in rows:
      result += r.jget("calls").getInt()
  proc usdOf(rows: seq[JsonNode]): float =
    for r in rows:
      let u = r.jget("usd")
      if u.kind == JFloat:
        result += u.getFloat()
      elif u.kind == JInt:
        result += float(u.getBiggestInt())
  %*{"window": window,
    "treg": {"tools": %tregRows, "endpoints": %endpointRows,
      "calls": callsOf(tregRows), "usd": round(usdOf(tregRows) * 1e6) / 1e6},
    "waku_memory": {"tools": %memoryRows, "recent_queries": %recent,
      "calls": callsOf(memoryRows)},
    "other": {"tools": %otherRows, "calls": callsOf(otherRows)}}

proc safeNum(node: JsonNode): int =
  ## An int out of a ledger number, or 0 when it is anything else.
  if node.kind == JInt: max(int(node.getBiggestInt()), 0) else: 0

proc chargedReceipts*(events: seq[JsonNode]): JsonNode =
  ## turn_id -> the receipt of every turn the metering proxy priced
  ## exactly. A receipt that names no turn takes the turn it sits in.
  result = newJObject()
  var current = ""
  for n, ev in pairs(events):
    if ev.kind != JObject:
      continue
    let kind = ev.jget("type").getStr()
    if kind == "turn_start":
      current = ev.jget("turn_id").getStr()
    elif kind == "receipt":
      let m = ev.jget("model")
      if m.kind == JObject and m.jget("estimate").kind == JBool and
          not m.jget("estimate").getBool():
        let key = ev.jget("turn_id").getStr()
        result[if key.len > 0: key
               elif current.len > 0: current
               else: "receipt-" & $n] = copy(ev)
  return result

proc receiptModelUsd*(receipt: JsonNode): float =
  ## The exact model dollars on a charged receipt: its own model figure,
  ## or its total less the tools it priced when an old receipt has none.
  let usd = receipt.jget("model").jget("usd")
  if usd.kind == JFloat:
    return usd.getFloat()
  if usd.kind == JInt:
    return float(usd.getBiggestInt())
  var tools = 0.0
  let arr = receipt.jget("tools")
  if arr.kind == JArray:
    for t in arr:
      if t.kind == JObject:
        let u = t.jget("usd")
        if u.kind == JFloat:
          tools += u.getFloat()
        elif u.kind == JInt:
          tools += float(u.getBiggestInt())
  let total = receipt.jget("total_usd")
  let tot = if total.kind == JFloat: total.getFloat()
            elif total.kind == JInt: float(total.getBiggestInt())
            else: 0.0
  max(tot - tools, 0.0)

proc ledgerRows*(home: string): seq[JsonNode] =
  ## Every row of the spend ledger, oldest first; bad lines skipped.
  try:
    for line in lines(home / "usage.jsonl"):
      try:
        let row = parseJson(line)
        if row.kind == JObject:
          result.add(row)
      except JsonParsingError:
        discard
  except IOError, OSError:
    discard

proc rowCost*(row: JsonNode): float =
  ## One ledger row at list price.
  llmCost(row.jget("provider").getStr(), row.jget("model").getStr(),
    %*{"in": safeNum(row.jget("in")), "out": safeNum(row.jget("out"))})

proc spendItems*(home: string, events: seq[JsonNode],
    servers: openArray[string] = []): seq[JsonNode] =
  ## Every dollar this home spent, once: charged receipts at their exact
  ## figure, other ledger rows estimated, tool dollars from their answers.
  let charged = chargedReceipts(events)
  for _, ev in pairs(charged):
    result.add(%*{"ts": ev.jget("ts").getStr(), "bucket": "model",
      "usd": receiptModelUsd(ev), "charged": true})
  for row in ledgerRows(home):
    let tid = row.jget("turn_id").getStr()
    if tid.len > 0 and charged.hasKey(tid):
      continue
    result.add(%*{"ts": row.jget("ts").getStr(), "bucket": "model",
      "usd": rowCost(row), "charged": false})
  var current = ""
  for ev in events:
    if ev.kind != JObject:
      continue
    if ev.jget("type").getStr() == "turn_start":
      current = ev.jget("turn_id").getStr()
    if ev.jget("type").getStr() != "tool":
      continue
    let info = describe(ev, servers)
    let cost = info.jget("cost_usd")
    if cost.kind != JInt and cost.kind != JFloat:
      continue
    let usd = if cost.kind == JFloat: cost.getFloat()
              else: float(cost.getBiggestInt())
    let src = info.jget("source").getStr()
    let bucket = if src == "treg": "treg"
                 elif src == "waku_memory": "memory" else: "other"
    let tid = ev.jget("turn_id").getStr()
    result.add(%*{"ts": ev.jget("ts").getStr(), "bucket": bucket,
      "usd": usd,
      "charged": charged.hasKey(if tid.len > 0: tid else: current)})
  return result

proc spendTotals*(items: seq[JsonNode], startMs: int64 = -1,
    events: seq[JsonNode] = @[]): JsonNode =
  ## The window's dollars: by bucket, and as charged plus estimated.
  ## Both splits sum to `total_usd`.
  var modelUsd, tregUsd, memoryUsd, otherUsd, chargedUsd = 0.0
  for i in items:
    if not inStartMs(i.jget("ts").getStr(), startMs):
      continue
    let usd = i.jget("usd").getFloat(0.0)
    case i.jget("bucket").getStr()
    of "model": modelUsd += usd
    of "treg": tregUsd += usd
    of "memory": memoryUsd += usd
    of "other": otherUsd += usd
    else: discard
    if i.jget("charged").getBool():
      chargedUsd += usd
  let total = modelUsd + tregUsd + memoryUsd + otherUsd
  let charged = chargedReceipts(events)
  var inWin = 0
  for _, ev in pairs(charged):
    if inStartMs(ev.jget("ts").getStr(), startMs):
      inc inWin
  var credits = 0
  var hasCredits = false
  for _, ev in pairs(charged):
    if not inStartMs(ev.jget("ts").getStr(), startMs):
      continue
    let c = ev.jget("credits")
    if c.kind == JInt:
      credits += int(c.getBiggestInt())
      hasCredits = true
  proc r6(x: float): float =
    round(x * 1e6) / 1e6
  %*{"model_usd": r6(modelUsd), "treg_usd": r6(tregUsd),
    "memory_usd": r6(memoryUsd), "other_usd": r6(otherUsd),
    "total_usd": r6(total),
    "charged_usd": (if inWin > 0: %r6(chargedUsd) else: newJNull()),
    "estimated_usd": r6(total - (if inWin > 0: chargedUsd else: 0.0)),
    "charged_turns": inWin,
    "credits": (if hasCredits: %credits else: newJNull())}

proc byModel*(home: string): seq[JsonNode] =
  ## All-time model calls, tokens and estimated dollars per provider
  ## and model, most expensive first.
  var acc = newJObject()
  for row in ledgerRows(home):
    let prov = row.jget("provider").getStr()
    let provider = if prov.len > 0: prov else: "?"
    let modl = row.jget("model").getStr()
    let key = provider & "\x00" & modl
    if not acc.hasKey(key):
      acc[key] = %*{"provider": provider, "model": modl,
        "calls": 0, "in": 0, "out": 0, "usd": 0.0}
    let b = acc[key]
    b["calls"] = %(b.jget("calls").getInt() + 1)
    b["in"] = %(b.jget("in").getInt() + safeNum(row.jget("in")))
    b["out"] = %(b.jget("out").getInt() + safeNum(row.jget("out")))
    b["usd"] = %(b.jget("usd").getFloat(0.0) + rowCost(row))
  for _, b in pairs(acc):
    b["usd"] = %(round(b.jget("usd").getFloat(0.0) * 1e6) / 1e6)
    result.add(b)
  result.sort(proc(x, y: JsonNode): int =
    let c = cmp(y.jget("usd").getFloat(0.0), x.jget("usd").getFloat(0.0))
    if c != 0: c
    else:
      let d = cmp(y.jget("calls").getInt(), x.jget("calls").getInt())
      if d != 0: d
      else: cmp(x.jget("model").getStr(), y.jget("model").getStr()))
  return result

proc spendHome*(home: string, events: seq[JsonNode],
    servers: openArray[string] = []): JsonNode =
  ## All-time spend under the one rule `spendItems` keeps, with the
  ## ledger's tokens and the list-price estimate per model.
  let totals = spendTotals(spendItems(home, events, servers), -1, events)
  let ledger = usageSummary(home)
  result = copy(totals)
  result["ledger"] = %*{"calls": ledger.calls, "total_in": ledger.totalIn,
    "total_out": ledger.totalOut, "total_cost": ledger.totalCost,
    "by_day": ledger.byDay, "by_provider": ledger.byProvider}
  result["by_model"] = %byModel(home)
  return result

proc spendByDay*(home: string, events: seq[JsonNode], days: int = 14,
    servers: openArray[string] = []): seq[JsonNode] =
  ## Newest first, one row per day: the dollars `spendItems` counts, by
  ## bucket and as charged, with the ledger's tokens.
  var byDay = newJObject()
  proc day(key: string): JsonNode =
    if not byDay.hasKey(key):
      byDay[key] = %*{"date": key, "model": 0.0, "treg": 0.0,
        "memory": 0.0, "other": 0.0, "charged": 0.0, "in": 0, "out": 0}
    byDay[key]
  for row in ledgerRows(home):
    let key = row.jget("ts").getStr()[0 ..< min(10,
      row.jget("ts").getStr().len)]
    if key.len == 0:
      continue
    let d = day(key)
    d["in"] = %(d.jget("in").getInt() + safeNum(row.jget("in")))
    d["out"] = %(d.jget("out").getInt() + safeNum(row.jget("out")))
  for item in spendItems(home, events, servers):
    let key = item.jget("ts").getStr()[0 ..< min(10,
      item.jget("ts").getStr().len)]
    if key.len == 0:
      continue
    let d = day(key)
    let bucket = item.jget("bucket").getStr()
    if bucket in ["model", "treg", "memory", "other"]:
      d[bucket] = %(d.jget(bucket).getFloat(0.0) +
        item.jget("usd").getFloat(0.0))
    if item.jget("charged").getBool():
      d["charged"] = %(d.jget("charged").getFloat(0.0) +
        item.jget("usd").getFloat(0.0))
  var rows: seq[JsonNode] = @[]
  for _, d in pairs(byDay):
    for k in ["model", "treg", "memory", "other", "charged"]:
      d[k] = %(round(d.jget(k).getFloat(0.0) * 1e6) / 1e6)
    d["total"] = %(round((d.jget("model").getFloat(0.0) +
      d.jget("treg").getFloat(0.0) + d.jget("memory").getFloat(0.0) +
      d.jget("other").getFloat(0.0)) * 1e6) / 1e6)
    rows.add(d)
  rows.sort(proc(x, y: JsonNode): int =
    cmp(y.jget("date").getStr(), x.jget("date").getStr()))
  if rows.len > days:
    rows = rows[0 ..< days]
  return rows

proc summary*(home: string, events: seq[JsonNode], turns: seq[JsonNode],
    tools: JsonNode, window: string = "7d", nowMs: int64 = 0,
    servers: openArray[string] = []): JsonNode =
  ## The four cards at the top of the page, for one window, in the order
  ## of the tabs below them.
  let startMs = windowStartMs(window, nowMs)
  var ledgerIn, ledgerOut, ledgerCalls = 0
  for r in ledgerRows(home):
    if not inStartMs(r.jget("ts").getStr(), startMs):
      continue
    ledgerIn += safeNum(r.jget("in"))
    ledgerOut += safeNum(r.jget("out"))
    inc ledgerCalls
  var inWin: seq[JsonNode] = @[]
  for t in turns:
    if inStartMs(t.jget("ts").getStr(), startMs):
      inWin.add(t)
  var loops: seq[int] = @[]
  for t in inWin:
    if t.jget("loops").getInt(0) > 0:
      loops.add(t.jget("loops").getInt(0))
  let memTools = tools.jget("waku_memory").jget("tools")
  var reads, writes: seq[JsonNode] = @[]
  if memTools.kind == JArray:
    for r in memTools:
      if r.jget("span").getStr() == "retrieval":
        reads.add(r)
      elif r.jget("span").getStr() == "memory_write":
        writes.add(r)
  var weighted = 0.0
  var returned = 0
  for r in reads:
    let avg = r.jget("avg_results")
    if avg.kind == JFloat or avg.kind == JInt:
      let a = if avg.kind == JFloat: avg.getFloat()
              else: float(avg.getBiggestInt())
      weighted += a * r.jget("calls").getInt(0).float
      returned += r.jget("calls").getInt(0)
  proc callsOf(group: string): JsonNode =
    var calls, errors = 0
    let arr = tools.jget(group).jget("tools")
    if arr.kind == JArray:
      for r in arr:
        calls += r.jget("calls").getInt(0)
        errors += r.jget("errors").getInt(0)
    %*{"calls": calls, "errors": errors}
  var loopsSum = 0
  for n in loops:
    loopsSum += n
  var keptSum = 0
  var gateRetrieve, gateSkip = 0
  for t in inWin:
    keptSum += t.jget("kept").getInt(0)
    if t.jget("gate").getStr() == "retrieve":
      inc gateRetrieve
    elif t.jget("gate").getStr() == "skip":
      inc gateSkip
  %*{"window": window,
    "spend": spendTotals(spendItems(home, events, servers), startMs,
      events),
    "tokens": {"in": ledgerIn, "out": ledgerOut, "calls": ledgerCalls},
    "tools": {"treg": callsOf("treg"),
      "waku_memory": callsOf("waku_memory"), "other": callsOf("other")},
    "turns": {"count": inWin.len,
      "avg_loops": (if loops.len > 0:
        %(round(loopsSum.float / loops.len.float * 10) / 10)
      else: newJNull())},
    "memory": {"retrievals": block:
        var n = 0
        for r in reads: n += r.jget("calls").getInt(0)
        n,
      "avg_results": (if returned > 0:
        %(round(weighted / returned.float * 10) / 10) else: newJNull()),
      "writes": block:
        var n = 0
        for r in writes: n += r.jget("calls").getInt(0)
        n,
      "kept": keptSum, "gate_retrieve": gateRetrieve,
      "gate_skip": gateSkip}}

proc memoryPerTurn*(turns: seq[JsonNode]): seq[JsonNode] =
  ## Per turn, in order: the gate, memories used and facts kept.
  for t in turns:
    var localOnly = newJNull()
    var searches = 0
    let steps = t.jget("steps")
    if steps.kind == JArray:
      for s in steps:
        if s.kind != JObject:
          continue
        if s.jget("kind").getStr() == "consolidation" and
            localOnly.kind == JNull:
          localOnly = copy(s.jget("local_only"))
        if s.jget("kind").getStr() == "memory":
          inc searches
    result.add(%*{"turn_id": t.jget("turn_id"),
      "ts": t.jget("ts"), "user_message": t.jget("user_message"),
      "gate": t.jget("gate"), "used": t.jget("used"),
      "kept": t.jget("kept"), "local_only": localOnly,
      "searches": searches})
  return result

const judgePass* = turn_evals.judgePassMark
  ## A judge score passes at 0.7. One literal, in `turn_evals`: the page
  ## prints the row, the judge's own threshold is the same number.

proc yourTurns*(turns: seq[JsonNode], window: string = "7d",
    nowMs: int64 = 0): JsonNode =
  ## One row per check for the turns in a window: passed, failed, n/a,
  ## the pass rate, and the newest failing turn. The judge row counts
  ## the turns judged and their average score.
  let startMs = windowStartMs(window, nowMs)
  var inside: seq[JsonNode] = @[]
  for t in turns:
    if inStartMs(t.jget("ts").getStr(), startMs):
      inside.add(t)
  var rows = newJArray()
  for (name, what) in turnChecks:
    var passed, failed, na = 0
    var newest = newJNull()
    for t in inside:
      var value = newJNull()
      let scores = t.jget("scores")
      if scores.kind == JArray:
        for s in scores:
          if s.kind == JObject and
              s.jget("source").getStr() == "code" and
              s.jget("name").getStr() == name:
            value = s.jget("value")
            break
      if value.kind == JNull:
        inc na
      elif (value.kind == JInt or value.kind == JFloat) and
          (if value.kind == JFloat: value.getFloat()
           else: float(value.getBiggestInt())) >= 1:
        inc passed
      else:
        inc failed
        var note = ""
        if scores.kind == JArray:
          for s in scores:
            if s.kind == JObject and
                s.jget("source").getStr() == "code" and
                s.jget("name").getStr() == name:
              note = s.jget("note").getStr()
              break
        newest = %*{"turn_id": t.jget("turn_id").getStr(),
          "ts": t.jget("ts"), "user_message": t.jget("user_message"),
          "note": note}
    let scored = passed + failed
    rows.add(%*{"name": name, "what": what, "passed": passed,
      "failed": failed, "na": na,
      "pass_rate": (if scored > 0: %(passed.float / scored.float)
                    else: newJNull()),
      "newest_fail": newest})
  var judged: seq[JsonNode] = @[]
  var graded: seq[seq[float]] = @[]
  for t in inside:
    let scores = t.jget("scores")
    if scores.kind != JArray:
      graded.add(@[])
      continue
    for s in scores:
      if s.kind == JObject and s.jget("source").getStr() == "judge":
        let v = s.jget("value")
        if v.kind == JFloat or v.kind == JInt:
          judged.add(s)
    var g: seq[float] = @[]
    for s in scores:
      if s.kind == JObject and s.jget("source").getStr() == "code":
        let v = s.jget("value")
        if v.kind == JFloat:
          g.add(v.getFloat())
        elif v.kind == JInt:
          g.add(float(v.getBiggestInt()))
    graded.add(g)
  var judgedSum = 0.0
  var judgedPassed = 0
  for s in judged:
    let v = s.jget("value")
    let num = if v.kind == JFloat: v.getFloat()
              else: float(v.getBiggestInt())
    judgedSum += num
    if num >= judgePass:
      inc judgedPassed
  var turnsScored, turnsPassed = 0
  for g in graded:
    if g.len == 0:
      continue
    inc turnsScored
    var allPass = true
    for v in g:
      if v < 1:
        allPass = false
        break
    if allPass:
      inc turnsPassed
  %*{"window": window, "turns": inside.len, "checks": rows,
    "turns_scored": turnsScored, "turns_passed": turnsPassed,
    "judge": {"judged": judged.len,
      "average": (if judged.len > 0:
        %(round(judgedSum / judged.len.float * 100) / 100)
      else: newJNull()),
      "passed": judgedPassed}}

proc countTests(path: string): int =
  ## Test functions in one file: lines opening `def test_` (or
  ## `async def test_`), like upstream's `_TEST_DEF`.
  try:
    for line in lines(path):
      let s = line.strip()
      if s.startsWith("def test_") or s.startsWith("async def test_"):
        inc result
  except IOError, OSError:
    discard

proc releaseInfo*(path: string): JsonNode =
  ## The release the container runs, or null when no record says so.
  if path.len == 0:
    return newJNull()
  var record: JsonNode = nil
  try:
    record = parseJson(readFile(path))
  except IOError, OSError, JsonParsingError:
    return newJNull()
  if record.isNil or record.kind != JObject:
    return newJNull()
  let sha = record.jget("sha").getStr()
  if sha.len != 40:
    return newJNull()
  for c in sha:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return newJNull()
  let commitUrl = record.jget("commit_url").getStr()
  if not commitUrl.startsWith("https://github.com/"):
    return newJNull()
  let checksEv = record.jget("checks")
  if checksEv.kind != JArray or checksEv.len == 0:
    return newJNull()
  var checks = newJArray()
  for c in checksEv:
    if c.kind != JObject:
      return newJNull()
    let name = c.jget("name").getStr()
    let conclusion = c.jget("conclusion").getStr()
    let url = c.jget("url").getStr()
    if name.len == 0 or conclusion.len == 0 or
        not url.startsWith("https://github.com/"):
      return newJNull()
    let t = c.jget("tests")
    var tests = newJNull()
    if t.kind == JObject and t.jget("label").kind == JString:
      var okCounts = true
      for k in ["passed", "failed", "skipped"]:
        let n = t.jget(k)
        if n.kind != JInt or n.getBiggestInt() < 0:
          okCounts = false
      if okCounts:
        tests = %*{"label": t.jget("label").getStr(),
          "passed": t.jget("passed").getInt(),
          "failed": t.jget("failed").getInt(),
          "skipped": t.jget("skipped").getInt()}
    checks.add(%*{"name": name, "conclusion": conclusion, "url": url,
      "completed_at": (if c.jget("completed_at").kind == JString:
        c.jget("completed_at") else: newJNull()),
      "tests": tests})
  let deployed = record.jget("deployed_at")
  %*{"sha": sha, "short_sha": sha[0 ..< 7], "commit_url": commitUrl,
    "deployed_at": (if deployed.kind == JString: deployed
                    else: newJNull()),
    "checks": checks}

proc suiteCounts(value: JsonNode): JsonNode =
  ## {passed, failed} when both read as counts, else null.
  if value.kind != JObject:
    return newJNull()
  for k in ["passed", "failed"]:
    let n = value.jget(k)
    if n.kind != JInt:
      return newJNull()
  %*{"passed": value.jget("passed").getInt(),
     "failed": value.jget("failed").getInt()}

proc lastRun*(report: JsonNode, history: seq[JsonNode]): JsonNode =
  ## What the newest recorded gate run said, per suite. None when no
  ## run recorded suite counts.
  var runs: seq[JsonNode] = @[]
  if report.kind == JObject:
    runs.add(report)
  for h in history:
    runs.add(h)
  for run in runs:
    if run.kind != JObject or run.jget("suites").kind != JObject:
      continue
    let det = suiteCounts(run.jget("suites").jget("deterministic"))
    let judge = suiteCounts(run.jget("suites").jget("judge"))
    if det.kind != JNull or judge.kind != JNull:
      return %*{"ran_at": run.jget("ran_at"),
        "deterministic": det, "judge": judge,
        "verdict": {"deterministic": run.jget("deterministic"),
          "judge": run.jget("judge")}}
  newJNull()

proc evalsInfo*(home: string, repo: string = "",
    hosted: bool = false, releaseFile: string = ""): JsonNode =
  ## What evals exist and what the release gate said last. Counted from
  ## `evals/` beside the code; without a checkout both counts read null
  ## and the page says so.
  var deterministic = newJNull()
  var judgeSuites = newJNull()
  if repo.len > 0:
    let detDir = repo / "evals" / "deterministic"
    let judgeDir = repo / "evals" / "judge"
    if dirExists(detDir):
      var files, tests = 0
      for kind, path in walkDir(detDir):
        if kind == pcFile and extractFilename(path).startsWith("test_") and
            path.endsWith(".py"):
          files += 1
          tests += countTests(path)
      deterministic = %*{"files": files, "tests": tests}
    if dirExists(judgeDir):
      var suites = newJArray()
      var names: seq[string] = @[]
      for kind, path in walkDir(judgeDir):
        let base = extractFilename(path)
        if kind == pcFile and base.startsWith("test_") and
            base.endsWith(".py"):
          names.add(base[5 .. ^4])
      names.sort()
      for n in names:
        suites.add(%n)
      judgeSuites = suites
  var report = newJNull()
  try:
    let parsed = parseJson(readFile(home / "eval_report.json"))
    if parsed.kind == JObject:
      report = parsed
  except IOError, OSError, JsonParsingError:
    discard
  var history: seq[JsonNode] = @[]
  try:
    let lines = readFile(home / "eval_runs.jsonl").splitLines()
    let tail = if lines.len > 20: lines[lines.len - 20 .. ^1] else: lines
    for line in tail:
      try:
        let row = parseJson(line)
        history.add(row)
      except JsonParsingError:
        discard
  except IOError, OSError:
    discard
  var reversed = newJArray()
  for i in countdown(history.len - 1, 0):
    reversed.add(copy(history[i]))
  %*{"deterministic": deterministic, "judge_suites": judgeSuites,
    "hosted": hosted, "last": report, "history": reversed,
    "last_run": lastRun(report, history),
    "release": releaseInfo(releaseFile)}

proc buildTurns(events: seq[JsonNode], home: string,
    servers: openArray[string], provider, model: string): seq[JsonNode] =
  ## Every turn of one home, built the way the page and the CLI
  ## table both show it: grouped from the events, each turn's late
  ## score events joined in (by turn id, skipping copies the turn
  ## already holds), its research flag set and the five checks
  ## scored. `payload` and `turnsReport` share it, so the page and
  ## the table cannot drift apart.
  var late = newJObject()
  for ev in events:
    if ev.kind == JObject and ev.jget("type").getStr() == "score" and
        ev.jget("turn_id").getStr().len > 0:
      let tid = ev.jget("turn_id").getStr()
      if not late.hasKey(tid):
        late[tid] = newJArray()
      late[tid].add(copy(ev))
  let grouped = groupTurns(events)
  let skillDirs = bundledSkillDirs()
  result = @[]
  for t in grouped:
    let tid = t.jget("turn_id").getStr()
    var extra: seq[JsonNode] = @[]
    if late.hasKey(tid):
      let inside = t.jget("events")
      for ev in late[tid]:
        var found = false
        if inside.kind == JArray:
          for own in inside:
            if own == ev:
              found = true
              break
        if not found:
          extra.add(ev)
    let research = isResearch(matchingSkillNames(home, skillDirs,
      t.jget("user_message").getStr()))
    result.add(buildTurn(t, servers, provider, model, extra, research))

proc payload*(home: string, provider: string = "", model: string = "",
    window: string = "7d", nowMs: int64 = 0,
    servers: openArray[string] = [], repo: string = "",
    hosted: bool = false, releaseFile: string = "",
    judgeModel: string = "", generatedAt: string = ""): JsonNode =
  ## Everything the Observability page draws, in one answer. Without a
  ## judge model every turn's `judge_offer` reads null; with one it names
  ## the model and its estimated cost (`turn_evals.judge_offer`).
  ## `generatedAt` overrides the stamp for deterministic pins; ""
  ## computes it, like `nowIso`. `agents` (T3.4) is the per-worker roll-up
  ## from those same events — additive, so nothing a reader already
  ## expects is renamed or removed.
  let win = validWindow(window)
  let (events, errors, files) = readEvents(home)
  let grouped = groupTurns(events)
  let built = buildTurns(events, home, servers, provider, model)
  let tools = toolStats(events, servers, win, nowMs)
  let spend = spendHome(home, events, servers)
  let byDay = spendByDay(home, events, 14, servers)
  let info = evalsInfo(home, repo, hosted, releaseFile)
  var turnsArr: seq[JsonNode] = @[]
  for i in countdown(built.len - 1, max(0, built.len - maxTurns)):
    let b = copy(built[i])
    b["judge_offer"] = judgeOffer(grouped[i], provider, judgeModel)
    turnsArr.add(b)
  var memArr: seq[JsonNode] = @[]
  let mem = memoryPerTurn(built)
  for i in countdown(mem.len - 1, max(0, mem.len - maxTurns)):
    memArr.add(copy(mem[i]))
  var yourTurns = newJObject()
  for w in windows:
    yourTurns[w] = yourTurns(built, w, nowMs)
  let evals = %*{"deterministic": info.jget("deterministic"),
    "judge_suites": info.jget("judge_suites"), "hosted": info.jget("hosted"),
    "last": info.jget("last"), "history": info.jget("history"),
    "last_run": info.jget("last_run"), "release": info.jget("release"),
    "your_turns": yourTurns}
  %*{"generated_at": (if generatedAt.len > 0: generatedAt
      else: format(now().utc, "yyyy-MM-dd'T'HH:mm:ss'+00:00'")),
    "summary": summary(home, events, built, tools, win, nowMs, servers),
    "spend_by_day": %byDay,
    "trace_files": files.len, "trace_file": (if files.len > 0:
      %files[^1] else: newJNull()),
    "trace_errors": %errors,
    "turns": %turnsArr, "tools": tools, "memory": %memArr,
    "spend": spend, "evals": evals, "agents": agentsSummary(events)}

proc turnsReport*(home: string, window: string = "7d",
    nowMs: int64 = 0): string =
  ## The `waku evals turns` text: the Your turns table for one window,
  ## then every failing turn with the check that failed and its note.
  ## `nowMs` is the clock in unix millis; 0 means now. Turns are built
  ## exactly like the payload builds them (checks on every read, late
  ## scores joined by turn id), so the table never disagrees with the page.
  let win = validWindow(window)
  let clock = if nowMs > 0: nowMs
    else: int64(getTime().toUnix) * 1000
  let (events, _, _) = readEvents(home)
  let servers = mcpServerNames(home)
  let built = buildTurns(events, home, servers, "", "")
  let startMs = windowStartMs(win, clock)
  var inside: seq[JsonNode] = @[]
  for t in built:
    if inStartMs(t.jget("ts").getStr(), startMs):
      inside.add(t)
  turn_evals.reportText(home, win, %inside, yourTurns(built, win, clock))
