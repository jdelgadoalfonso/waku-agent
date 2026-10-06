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
import std/times

import ./observe
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

proc inWindow*(ts: string, window: string, nowMs: int64): bool =
  ## Whether one `ts` stamp falls in `window` at `nowMs`. Unparsable
  ## stamps never match (except under "all") — Python's `_ts` → None
  ## path, which fails the `>= start` comparison the same way.
  case validWindow(window)
  of "today":
    let (ok, ms) = parseTsMs(ts)
    ok and ms >= localMidnightMs(nowMs)
  of "7d":
    let (ok, ms) = parseTsMs(ts)
    ok and ms >= nowMs - 7 * 86400 * 1000
  else:
    true

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
  ## code checks (`run_checks`, spec 015 A) land with the turn-evals
  ## unit; until then this list is the whole `scores` of a built turn.
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
    extraScores: seq[JsonNode] = @[]): JsonNode =
  ## A turn with its steps in order, its time, its dollars and its
  ## stored scores. The five code checks (`run_checks`, spec 015 A)
  ## land with the turn-evals unit; until then `scores` holds stored
  ## scores only.
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
  result = %*{"scores": storedScores(turn, extraScores),
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
