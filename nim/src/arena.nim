## The model arena — port of `waku/ops/compare_history.py` (the
## benchmark's OWN append-only log) plus the `history_response`,
## `compare_clear`, `compare_regrade`, `compare_delete_run` and
## `compare_stream` entry points of `waku/ops/arena.py`.
##
## Why a separate module instead of more `dashboard.nim`: the dashboard owns
## the HTTP/SSE plumbing; this module owns the race — the store on disk, the
## reprice-at-read scoreboard and the race/judge seams. That mirrors the
## Python split (`dashboard.py` calls into `arena.py`, never the reverse) and
## keeps `dashboard.nim` from growing past its 8b size. `dashboard.nim`
## imports this module for the five 8c routes; nothing here imports the
## dashboard, so there is no cycle.
##
## Every proc stays pure over injected values: the history root is a `home`
## parameter (never the process home), the referee is a `JudgeFn`, the race
## itself is a `RaceFn`, and the clock is an explicit `ts` string (the
## dashboard passes its `nowIso` override when set). No network, no process
## globals — tests run 100% offline with stubs.
##
## Two divergences from Python, both seam-shaped:
##
## - The live race (`arena.compare_stream`'s harness turns in throwaway
##   homes) has no Nim harness to drive yet, so `compareStreamRun` runs the
##   injected `RaceFn` instead. A nil runner is an honest done error, the
##   same shape as 8b's unwired graph runner. The judge routing also moves
##   into the seam: the payload's `judge_model` still reaches the runner as
##   an opaque spec string (and names the `grading` frame), but model
##   selection inside the referee belongs to the injected `JudgeFn`.
## - `judgeDisplayName` falls back to `WAKU_JUDGE_MODEL`, then the ported
##   `JUDGE_MODEL` default — read from the injected env table, never the
##   process environment directly.

import std/algorithm
import std/json
import std/math
import std/os
import std/strutils
import std/tables
import std/times

import ./pricing
import ./providers

export providers.Provider

const
  maxRuns* = 50
    ## `compare_history.MAX_RUNS`: the log stays small, older races roll off.
  replyCap* = 1000
    ## `compare_history.REPLY_CAP`: stored replies are capped so the file
    ## never bloats.
  defaultJudgeModel* = "gpt-5.6-sol"
    ## Port of `judge.JUDGE_MODEL`'s default: the referee when neither the
    ## payload nor `WAKU_JUDGE_MODEL` names one.

type
  SseEmit* = proc(kind: string, ev: JsonNode) {.closure.}
    ## One harness event into an SSE stream. Defined here (not in the
    ## dashboard) so the race pipeline shares the exact type the dashboard
    ## streams with; `dashboard.nim` re-exports it.
  JudgeFn* = proc(task, reply, judgeSpec: string,
                  tools: JsonNode): JsonNode {.closure.}
    ## One referee grade (`judge.judge_reply`): the task, the contestant's
    ## reply, the opaque `judge_model` spec from the payload, and the tools
    ## as stored (a `[names]` array). Returns the grade object, or `JNull`
    ## when the referee abstains (Python's `None` — the card stays ungraded).
  RaceFn* = proc(message: string, specs: seq[string], coding: bool,
                 emit: SseEmit): JsonNode {.closure.}
    ## One model race (`arena.compare_stream`'s harness loop): streams live
    ## frames through `emit` and returns the collected per-model results.
    ## `coding` registers `delegate_task` (the pi sub-agent) in every
    ## column, like Python's `coding` parameter — the frontend sends it.
    ## The pipeline persists, grades and closes the stream around it.

proc fieldOf(node: JsonNode, key: string): JsonNode =
  ## `getOrDefault` that never returns nil: std/json yields nil for a
  ## missing key, and `$` on nil segfaults. Absent reads as JNull.
  if node.isNil or node.kind != JObject:
    return newJNull()
  let v = node.getOrDefault(key)
  if v.isNil: newJNull() else: v

proc strOf(node: JsonNode, key: string): string =
  ## A payload string field; anything non-string reads as absent.
  let v = fieldOf(node, key)
  if v.kind == JString: v.getStr() else: ""

proc jInt(node: JsonNode, key: string): int =
  ## A ledger number defaulting to 0 when missing or mistyped, like
  ## Python's `r.get("in", 0)` (the log is append-only and hand-editable).
  let v = fieldOf(node, key)
  case v.kind
  of JInt: int(v.getBiggestInt())
  of JFloat: int(v.getFloat())
  else: 0

proc jFloat(node: JsonNode, key: string): float =
  let v = fieldOf(node, key)
  case v.kind
  of JFloat: v.getFloat()
  of JInt: v.getBiggestInt().float
  else: 0.0

proc isTruthy(node: JsonNode): bool =
  ## Python truthiness for the shapes this module meets: empty
  ## strings/objects/arrays and null are false, zero numbers are false.
  case node.kind
  of JNull: false
  of JBool: node.getBool()
  of JInt: node.getBiggestInt() != 0
  of JFloat: node.getFloat() != 0.0
  of JString: node.getStr().len > 0
  of JArray: node.len > 0
  of JObject: node.len > 0

proc round4(x: float): float =
  round(x * 10000.0) / 10000.0

proc nowTs*(): string =
  ## `datetime.now(UTC).isoformat(timespec="seconds")`, for callers with
  ## no injected clock.
  format(now().utc, "yyyy-MM-dd'T'HH:mm:ss'+00:00'")

# ---------------------------------------------------------------------------
# The store: `<home>/compare/history.jsonl`, newest last, capped.

proc arenaPath*(home: string): string =
  home / "compare" / "history.jsonl"

proc loadRuns*(home: string): JsonNode =
  ## Recent races, oldest first. Bad JSON lines are skipped, like Python.
  result = newJArray()
  let path = arenaPath(home)
  if not fileExists(path):
    return
  for line in lines(path):
    let text = line.strip()
    if text.len == 0:
      continue
    try:
      result.add(parseJson(text))
    except JsonParsingError:
      continue

proc saveRuns*(home: string, runs: JsonNode) =
  ## Rewrite the (capped) history file — used by append and by re-grading,
  ## which mutates an existing race's stored results in place.
  let path = arenaPath(home)
  createDir(parentDir(path))
  var capped = newJArray()
  let start = max(0, runs.len - maxRuns)
  for i in start ..< runs.len:
    capped.add(runs[i])
  var parts: seq[string] = @[]
  for r in capped:
    parts.add($r)
  writeFile(path, parts.join("\n") & "\n")

proc clearRuns*(home: string) =
  ## Wipe the compare history (the Clear button). Only the arena's own
  ## log; nothing else is touched.
  let path = arenaPath(home)
  if fileExists(path):
    removeFile(path)

proc toolNamesOf*(r: JsonNode): JsonNode =
  ## The tools of one result as a `[names]` array: race output carries
  ## `[{tool}]`, stored rows already carry `[names]` — both read the same.
  result = newJArray()
  let rawTools = fieldOf(r, "tools")
  if rawTools.kind == JArray:
    for item in rawTools:
      if item.kind == JObject:
        result.add(fieldOf(item, "tool"))
      else:
        result.add(item)

proc slimResult*(r: JsonNode): JsonNode =
  ## Port of `compare_history._slim`: keep only what the history list +
  ## scoreboard need, and cap the reply. Accepts a per-model result as the
  ## race produces it (gate as a `{decision, reason}` object, tools as
  ## `[{tool}]`); stored rows already slimmed pass through unchanged
  ## (gate as a plain string, tools as `[names]`).
  var spec = strOf(r, "spec")
  if spec.len == 0:
    spec = strOf(r, "provider") & ":" & strOf(r, "model")
  var gateOut: JsonNode
  let gate = fieldOf(r, "gate")
  if gate.kind == JObject:
    let decision = fieldOf(gate, "decision")
    gateOut = if decision.kind == JString: decision else: newJNull()
  else:
    gateOut = gate
  let tools = toolNamesOf(r)
  let reply = strOf(r, "reply")
  let kept = if reply.len > replyCap: reply[0 ..< replyCap] else: reply
  result = newJObject()
  result["spec"] = %spec
  result["provider"] = fieldOf(r, "provider")
  result["model"] = fieldOf(r, "model")
  result["latency_ms"] = fieldOf(r, "latency_ms")
  result["tokens_in"] = fieldOf(r, "tokens_in")
  result["tokens_out"] = fieldOf(r, "tokens_out")
  result["cost_usd"] = fieldOf(r, "cost_usd")
  result["iterations"] = fieldOf(r, "iterations")
  result["gate"] = gateOut
  result["tools"] = tools
  result["error"] = fieldOf(r, "error")
  result["completion"] = fieldOf(r, "completion")
  result["quality"] = fieldOf(r, "quality")
  result["reply"] = %kept

proc appendRun*(home, message: string, results: JsonNode, ts = "") =
  ## Append one finished race and trim to the most recent `maxRuns`. An
  ## empty `ts` stamps now; tests and the dashboard pass an explicit one.
  let stamp = if ts.len > 0: ts else: nowTs()
  var slimmed = newJArray()
  if results.kind == JArray:
    for r in results:
      slimmed.add(slimResult(r))
  let runs = loadRuns(home)
  var record = newJObject()
  record["ts"] = %stamp
  record["message"] = %message
  record["results"] = slimmed
  runs.add(record)
  saveRuns(home, runs)

proc appendRun*(home, message: string, results: seq[JsonNode],
                 ts = "") =
  ## Convenience overload for literal result lists.
  var arr = newJArray()
  for r in results:
    arr.add(r)
  appendRun(home, message, arr, ts)

# ---------------------------------------------------------------------------
# The scoreboard: reprice at read time, then aggregate.

proc aggregateRuns*(runs: JsonNode): JsonNode =
  ## Port of `compare_history.aggregate`: per-model scoreboard across the
  ## given races — run count, successful count, and CUMULATIVE totals over
  ## the successful runs (errored runs count against `runs` but add nothing
  ## to the totals). Cheapest total first.
  var acc = initTable[string, JsonNode]()
  var order: seq[string] = @[]
  for run in runs:
    let results = fieldOf(run, "results")
    if results.kind != JArray:
      continue
    for r in results:
      var spec = strOf(r, "spec")
      if spec.len == 0:
        spec = strOf(r, "provider") & ":" & strOf(r, "model")
      if spec notin acc:
        acc[spec] = %*{"spec": spec, "provider": strOf(r, "provider"),
          "model": strOf(r, "model"), "runs": 0, "ok": 0, "lat": 0,
          "tin": 0, "tout": 0, "cost": 0.0, "passed": 0, "scored": 0,
          "qsum": 0.0, "qn": 0}
        order.add(spec)
      let a = acc[spec]
      a["runs"] = %(a["runs"].getInt() + 1)
      if not isTruthy(fieldOf(r, "error")):
        a["ok"] = %(a["ok"].getInt() + 1)
        a["lat"] = %(a["lat"].getInt() + jInt(r, "latency_ms"))
        a["tin"] = %(a["tin"].getInt() + jInt(r, "tokens_in"))
        a["tout"] = %(a["tout"].getInt() + jInt(r, "tokens_out"))
        a["cost"] = %(a["cost"].getFloat() + jFloat(r, "cost_usd"))
      let completion = fieldOf(r, "completion")
      if completion.kind == JObject:
        a["scored"] = %(a["scored"].getInt() + 1)
        if isTruthy(fieldOf(completion, "passed")):
          a["passed"] = %(a["passed"].getInt() + 1)
      let quality = fieldOf(r, "quality")
      if quality.kind == JObject:
        let score = fieldOf(quality, "score")
        if score.kind == JFloat or score.kind == JInt:
          a["qsum"] = %(a["qsum"].getFloat() + jFloat(quality, "score"))
          a["qn"] = %(a["qn"].getInt() + 1)
  var rows: seq[JsonNode] = @[]
  for spec in order:
    let a = acc[spec]
    let qn = a["qn"].getInt()
    var avg: JsonNode = newJNull()
    if qn > 0:
      avg = %(round(a["qsum"].getFloat() / qn.float * 10.0) / 10.0)
    rows.add(%*{"spec": a["spec"], "provider": a["provider"],
      "model": a["model"], "runs": a["runs"], "ok": a["ok"],
      "total_latency_ms": a["lat"], "total_tokens_in": a["tin"],
      "total_tokens_out": a["tout"],
      "total_tokens": %(a["tin"].getInt() + a["tout"].getInt()),
      "cases_passed": a["passed"], "cases_scored": a["scored"],
      "quality_n": a["qn"], "quality_avg": avg,
      "total_cost_usd": %(round4(a["cost"].getFloat()))})
  rows.sort(proc(x, y: JsonNode): int =
    cmp(x["total_cost_usd"].getFloat(), y["total_cost_usd"].getFloat()))
  result = newJArray()
  for row in rows:
    result.add(row)

proc historyResponse*(runs: JsonNode,
                      providers: seq[Provider]): JsonNode =
  ## Port of `arena.history_response`: reprice each stored result from its
  ## tokens with the CURRENT price table (so a pricing fix corrects past
  ## races), aggregate, and tag each row with the rate and knowledge cutoff
  ## (also current, so a cutoff fix corrects past races too). The shared
  ## shape returned by `/api/compare/history` and the re-grade endpoint.
  ## `runs` is repriced in place, like Python's loop.
  for run in runs:
    let results = fieldOf(run, "results")
    if results.kind != JArray:
      continue
    for r in results:
      r["cutoff"] = %cutoffFor(strOf(r, "model"))
      if isTruthy(fieldOf(r, "error")):
        continue
      let (pin, pout) = priceFor(strOf(r, "provider"), strOf(r, "model"),
        providers)
      r["cost_usd"] = %(round4(jInt(r, "tokens_in").float / 1e6 * pin +
        jInt(r, "tokens_out").float / 1e6 * pout))
  let agg = aggregateRuns(runs)
  for row in agg:
    let (pin, pout) = priceFor(row["provider"].getStr(),
      row["model"].getStr(), providers)
    row["rate_in"] = %pin
    row["rate_out"] = %pout
    row["cutoff"] = %cutoffFor(row["model"].getStr())
  var recent = newJArray()
  let start = max(0, runs.len - 20)
  for i in countdown(runs.len - 1, start):
    recent.add(runs[i])
  result = newJObject()
  result["runs"] = recent
  result["aggregate"] = agg

# ---------------------------------------------------------------------------
# The three POST entry points.

proc compareClear*(home: string): JsonNode =
  ## Port of `arena.compare_clear`: wipe the scoreboard, answer empty.
  clearRuns(home)
  %*{"ok": true, "runs": [], "aggregate": []}

proc compareDeleteRun*(home, ts: string,
                       providers: seq[Provider]): JsonNode =
  ## Port of `arena.compare_delete_run`: delete ONE race by timestamp,
  ## leaving every other race intact, and return the refreshed history.
  var kept = newJArray()
  for r in loadRuns(home):
    if strOf(r, "ts") != ts:
      kept.add(r)
  saveRuns(home, kept)
  historyResponse(kept, providers)

proc compareRegrade*(home: string, payload: JsonNode,
                     providers: seq[Provider], judge: JudgeFn): JsonNode =
  ## Port of `arena.compare_regrade`: re-run the referee on the most
  ## recent race — for models the grader skipped the first time.
  ## `only_missing` (default true) grades only the ungraded ones; a
  ## `spec` grades just one card. Returns the refreshed history +
  ## scoreboard, same shape as `/api/compare/history`.
  let runs = loadRuns(home)
  if runs.len == 0:
    return %*{"runs": [], "aggregate": []}
  let hasSpec = fieldOf(payload, "spec").kind == JString
  let spec = strOf(payload, "spec")
  let onlyMissing =
    if payload.hasKey("only_missing"): isTruthy(payload["only_missing"])
    else: true
  let judgeSpec = strOf(payload, "judge_model")
  let last = runs[runs.len - 1]
  let message = strOf(last, "message")
  let results = fieldOf(last, "results")
  if results.kind == JArray:
    for r in results:
      if isTruthy(fieldOf(r, "error")):
        continue
      if strOf(r, "reply").strip().len == 0:
        continue
      var rspec = strOf(r, "spec")
      if rspec.len == 0:
        rspec = strOf(r, "provider") & ":" & strOf(r, "model")
      if hasSpec and rspec != spec:
        continue
      if not hasSpec and onlyMissing and
          fieldOf(r, "quality").kind != JNull:
        continue
      if judge.isNil:
        raise newException(CatchableError,
          "compare judging is not wired in this dashboard build")
      let q = judge(message, strOf(r, "reply"), judgeSpec,
        toolNamesOf(r))
      if q.kind != JNull:
        r["quality"] = q
  saveRuns(home, runs)
  historyResponse(runs, providers)

# ---------------------------------------------------------------------------
# The stream entry point.

proc judgeDisplayName*(payload: JsonNode,
                       env: Table[string, string]): string =
  ## Who graded this race, for the `grading` frame: the model half of the
  ## payload's `judge_model` spec, else `WAKU_JUDGE_MODEL`, else the ported
  ## `JUDGE_MODEL` default — the same precedence as Python.
  let spec = strOf(payload, "judge_model")
  let idx = spec.find(':')
  let jm = if idx >= 0: spec[idx + 1 .. ^1] else: ""
  if jm.len > 0:
    return jm
  if "WAKU_JUDGE_MODEL" in env:
    return env["WAKU_JUDGE_MODEL"]
  return defaultJudgeModel

proc compareStreamRun*(home: string, payload: JsonNode,
                       providers: seq[Provider], race: RaceFn,
                       judge: JudgeFn, judgeName, ts: string,
                       emit: SseEmit) =
  ## Port of `arena.compare_stream` around the injected seams: validate,
  ## run the race (live frames pass through), grade AFTER the race as one
  ## gentle pass (so the referee never sees a burst), persist, close.
  ## A history-write hiccup never fails the race, like Python.
  let message = strOf(payload, "message").strip()
  var specs: seq[string] = @[]
  let models = fieldOf(payload, "models")
  if models.kind == JArray:
    for item in models:
      if item.kind == JString and item.getStr().strip().len > 0:
        specs.add(item.getStr())
  if message.len == 0 or specs.len == 0:
    emit("done", %*{"error": "message and models required"})
    return
  if race.isNil:
    emit("done", %*{"error":
      "compare racing is not wired in this dashboard build"})
    return
  var collected: JsonNode
  try:
    let coding = fieldOf(payload, "coding").kind == JBool and
      fieldOf(payload, "coding").getBool()
    collected = race(message, specs, coding, emit)
  except CatchableError as exc:
    emit("done", %*{"error": exc.msg})
    return
  if collected.kind != JArray:
    collected = newJArray()
  if isTruthy(fieldOf(payload, "judge")):
    var gradable: seq[JsonNode] = @[]
    for r in collected:
      if isTruthy(fieldOf(r, "error")):
        continue
      if strOf(r, "reply").strip().len == 0:
        continue
      gradable.add(r)
    if gradable.len > 0 and judge.isNil:
      emit("done", %*{"error":
        "compare judging is not wired in this dashboard build"})
      return
    if gradable.len > 0:
      let name = if judgeName.len > 0: judgeName else: defaultJudgeModel
      emit("grading", %*{"n": gradable.len, "judge": name})
      let judgeSpec = strOf(payload, "judge_model")
      try:
        for r in gradable:
          let q = judge(message, strOf(r, "reply"), judgeSpec,
            toolNamesOf(r))
          r["quality"] = q
          var rspec = strOf(r, "spec")
          if rspec.len == 0:
            rspec = strOf(r, "provider") & ":" & strOf(r, "model")
          emit("grade", %*{"spec": rspec, "quality": q})
      except CatchableError as exc:
        emit("done", %*{"error": exc.msg})
        return
  try:
    appendRun(home, message, collected, ts)
  except CatchableError:
    discard
  emit("done", newJObject())
