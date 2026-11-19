## In-app scheduler core (C2a/C2b/C2c): pure interval math, the tick,
## the atomic claim and the live brief runner.
##
## The loop injects `now` (Unix seconds) at every call — like
## `newRunFolder` takes `stamp` — so the math stays offline-testable.
## Persistence (`scheduled_tasks`) and the tool wiring live here (C2a);
## `tickDue` is the pure tick (C2b), `claimDueTasks` is what makes a
## firing at-most-once across loops (C2c), and `liveBriefRunner` binds
## the tick to the existing worker machinery. `waku/` is frozen: no
## Python change.

import std/json
import std/os
import std/strutils
import std/times

import db_connector/db_sqlite

import ./delegate
import ./supervisor
import ./tools
import ./trace

const
  scheduleMinSec* = 60
    ## Tight loops help nobody: one minute is the floor.
  scheduleMaxSec* = 7 * 24 * 3600
    ## One week is the ceiling for C2a.
  scheduleClaimLeaseSec* = 300
    ## How long one owner may hold a claim (C2c). A run that dies
    ## without rescheduling stops hiding its row after this many
    ## seconds, and the next tick reclaims it. Keep it above one
    ## tick's worst case (`scheduleMaxFire` x ~31s per brief turn),
    ## or a slow tick starts looking dead to the next one.

proc parseInterval*(raw: string): tuple[ok: bool, secs: int, msg: string] =
  ## Accept `90`, `90s`, `10m`, `1h`, `1d`, with an optional `every `
  ## prefix, any case. Anything else is refused with a usable example.
  const hint = "Use 'every <N>[s/m/h/d]', between 60s and 7d."
  var s = raw.strip().toLowerAscii()
  if s.startsWith("every "):
    s = s["every ".len .. ^1].strip()
  if s.len == 0:
    return (false, 0, "Empty interval. " & hint)
  var digits = ""
  var rest = ""
  for i, c in s:
    if c in {'0' .. '9'}:
      digits.add(c)
    else:
      rest = s[i .. ^1]
      break
  if digits.len == 0:
    return (false, 0, "'" & raw.strip() & "' has no number. " & hint)
  if rest.len > 0 and rest[0] == '-':
    return (false, 0, "'" & raw.strip() & "' is not positive. " & hint)
  let n =
    try: parseInt(digits)
    except ValueError: 0
  let mult =
    case rest
    of "", "s": 1
    of "m": 60
    of "h": 3600
    of "d": 86400
    else: 0
  if mult == 0:
    return (false, 0, "'" & raw.strip() &
      "' needs a unit s/m/h/d. " & hint)
  if rest.len == 0 and digits != s:
    return (false, 0, "'" & raw.strip() & "' is not a plain number. " &
      hint)
  let secs = n * mult
  if secs < scheduleMinSec or secs > scheduleMaxSec:
    return (false, 0, "'" & raw.strip() & "' is outside the range " &
      "between 60s and 7d. " & hint)
  return (true, secs, "")

proc nextRun*(nowUnix: int64, intervalSec: int): int64 =
  ## Pure addition: the next firing time. The caller owns the clock.
  nowUnix + int64(intervalSec)

proc isDue*(nowUnix, nextRunUnix: int64): bool =
  ## Fires when the clock has reached the stored time, inclusive.
  nowUnix >= nextRunUnix

type
  ScheduledTask* = object
    ## One row of `scheduled_tasks`. Times are Unix seconds; the
    ## caller owns the clock, the table only stores the next firing.
    id*: int64
    name*: string
    prompt*: string
    agent*: string
    intervalSec*: int
    nextRun*: int64
    createdAt*: string
    claimedAt*: int64
      ## When an owner last claimed the row; 0 means unclaimed.
    claimedBy*: string
      ## The owner holding it; "" means unclaimed.

const taskSelect =
  "SELECT id, name, prompt, agent, interval_sec, next_run, " &
  "created_at, claimed_at, claimed_by FROM scheduled_tasks"

proc toTask(row: Row): ScheduledTask =
  ## One row of `taskSelect`, in that order.
  ScheduledTask(id: parseBiggestInt(row[0]), name: row[1],
    prompt: row[2], agent: row[3], intervalSec: parseInt(row[4]),
    nextRun: parseBiggestInt(row[5]), createdAt: row[6],
    claimedAt: parseBiggestInt(row[7]), claimedBy: row[8])

proc addScheduledTask*(db: DbConn, name, prompt: string,
    intervalSec: int, nextRun: int64,
    agent = "brief"): int64 =
  ## Insert one task, return its row id. Thin layer like `addFact`.
  db.exec(sql("INSERT INTO scheduled_tasks " &
    "(name, prompt, agent, interval_sec, next_run) " &
    "VALUES (?,?,?,?,?)"),
    name, prompt, agent, $intervalSec, $nextRun)
  parseBiggestInt(db.getValue(sql"SELECT last_insert_rowid()"))

proc listScheduledTasks*(db: DbConn, limit = 50): seq[ScheduledTask] =
  ## Newest first, like `listFacts`.
  for row in db.getAllRows(sql(taskSelect & " ORDER BY id DESC LIMIT ?"),
      $limit):
    result.add(toTask(row))

proc dueScheduledTasks*(db: DbConn, nowUnix: int64, limit = 50,
    leaseSec = scheduleClaimLeaseSec): seq[ScheduledTask] =
  ## Everything whose time has come and that no live owner holds,
  ## earliest first. A claim past its lease counts as gone, so a
  ## crashed run comes back instead of being lost (C2c).
  for row in db.getAllRows(sql(taskSelect &
      " WHERE next_run <= ? " &
      "AND (claimed_at = 0 OR claimed_at < ?) " &
      "ORDER BY next_run ASC LIMIT ?"),
      $nowUnix, $(nowUnix - int64(leaseSec)), $limit):
    result.add(toTask(row))

proc claimDueTasks*(db: DbConn, nowUnix: int64, owner: string,
    leaseSec = scheduleClaimLeaseSec,
    limit = 10): seq[ScheduledTask] =
  ## The C2c claim: take up to `limit` due rows for `owner` in ONE
  ## conditional UPDATE, then read back the rows this owner stamped.
  ##
  ## Two loops racing the same row both run the UPDATE; the store
  ## serialises them, so the second one finds the row already claimed
  ## and takes nothing. A row is available when it is unclaimed or its
  ## claim is older than `leaseSec` (the owner that claimed it died),
  ## and earliest-first keeps the backlog draining in order.
  ##
  ## `owner` must be unique per call (production uses `tickOwner`):
  ## reusing the same owner in the same second reads back the rows it
  ## already stamped, so a repeated call would run them twice.
  if owner.len == 0:
    return @[]
  db.exec(sql("UPDATE scheduled_tasks SET claimed_at=?, claimed_by=? " &
    "WHERE id IN (SELECT id FROM scheduled_tasks " &
    "WHERE next_run <= ? AND (claimed_at = 0 OR claimed_at < ?) " &
    "ORDER BY next_run ASC LIMIT ?)"),
    $nowUnix, owner, $nowUnix, $(nowUnix - int64(leaseSec)), $limit)
  for row in db.getAllRows(sql(taskSelect &
      " WHERE claimed_by=? AND claimed_at=? " &
      "ORDER BY next_run ASC LIMIT ?"),
      owner, $nowUnix, $limit):
    result.add(toTask(row))

proc markScheduledDone*(db: DbConn, id, nextRun: int64): bool =
  ## Reschedule after a firing and release the claim, so the next tick
  ## can take the row again. True when a row moved.
  db.execAffectedRows(sql("UPDATE scheduled_tasks SET next_run=?, " &
    "claimed_at=0, claimed_by='' WHERE id=?"), $nextRun, $id) > 0

type
  TickRunner* = proc(task: ScheduledTask): string {.closure.}
    ## One headless run for one due task. Tests inject recordings; the
    ## live adapter binds the worker machinery.

  ScheduleSpawn* = WorkerRunner
    ## The supervisor-style spawn seam for one scheduled brief. Tests
    ## record the argv/stdin and script a `ProcResult`; production
    ## passes `defaultWorkerRunner`.

proc briefStderrSnippet(stderr: string, limit = 300): string =
  ## One display line from child stderr: trimmed, joined, bounded.
  var parts: seq[string]
  for raw in stderr.splitLines():
    let line = raw.strip()
    if line.len > 0:
      parts.add(line)
  result = parts.join(" ")
  if result.len > limit:
    result = result[0 ..< limit] & "..."

proc liveBriefRunner*(binary: string,
    spawn: ScheduleSpawn = defaultWorkerRunner,
    timeoutMs = delegateDefaultTimeoutMs): TickRunner =
  ## The live tick runner: one `--role worker --agent brief` turn per
  ## due task, through the supervisor-style spawn seam. Always answers
  ## one display string — timeout, non-zero exit, empty output and a
  ## raising spawner included — so one broken task never escapes as an
  ## exception or reads as a silent success.
  let timeoutSec = delegateTimeoutSec(timeoutMs)
  let argv = delegateArgv(binary, "brief")
  result = proc(task: ScheduledTask): string {.closure.} =
    try:
      let runId = mintTurnId()
      let taskLine = delegateTaskLine(runId, runId, task.prompt, "",
        timeoutMs)
      let run = spawn(argv, $taskLine, timeoutSec)
      let res = run.res
      if res.timedOut:
        return "task '" & task.name & "' timed out after " & $timeoutSec &
          "s and was killed"
      if res.code != 0:
        let detail = briefStderrSnippet(res.stderr)
        return "task '" & task.name & "' failed (exit " & $res.code &
          "): " & (if detail.len > 0: detail else: "no stderr")
      let collected = collectChildLines(res.stdout)
      if collected.lines.len == 0:
        return "task '" & task.name & "' produced no output"
      let reply = delegateLoopResult(collected.lines).reply.strip()
      if reply.len == 0:
        return "task '" & task.name & "' produced no reply"
      return "task '" & task.name & "': " & reply
    except CatchableError as exc:
      return "task '" & task.name & "' failed: " & exc.msg

proc tickOwner*(): string =
  ## A claim owner unique per process and per tick, so two loops never
  ## share a claim stamp and never read each other's rows (C2c).
  let t = getTime()
  "tick-" & $getCurrentProcessId() & "-" & $t.toUnix() & "-" &
    $t.nanosecond

proc tickDue*(db: DbConn, nowUnix: int64, run: TickRunner,
    limit = 10, owner = ""): seq[string] =
  ## Claim up to `limit` due tasks, earliest first, run only the ones
  ## this tick won, then move each to `now + interval`. The runner is
  ## injected, so this core owns no clock and no worker.
  ##
  ## The claim is what makes a firing at-most-once: a second loop
  ## reaching the same row at the same time loses the race in
  ## `claimDueTasks` and runs nothing. A failing runner becomes a line
  ## and still reschedules, so one bad task never hot-loops the ticker,
  ## and a run that dies before rescheduling leaves a claim that expires
  ## instead of a task that fires twice.
  let claimer = if owner.len == 0: tickOwner() else: owner
  for task in db.claimDueTasks(nowUnix, claimer, limit = limit):
    var line: string
    try:
      line = run(task)
    except CatchableError as exc:
      line = "task '" & task.name & "' failed: " & exc.msg
    if not db.markScheduledDone(task.id,
        nextRun(nowUnix, task.intervalSec)):
      line &= " (could not reschedule; it will fire again after the " &
        "claim expires)"
    result.add(line)

const
  scheduleMaxFire* = 3
    ## How many due tasks one tick may run. A backlog (the process was
    ## off for a while) drains a few per pass instead of turning one
    ## pass into a stampede of worker turns; the rest stay due, and the
    ## next tick picks them up.

proc tickIfDueWith*(db: DbConn, experimental: bool, nowUnix: int64,
    run: TickRunner, maxFire = scheduleMaxFire): seq[string] =
  ## The C2b gate with its runner injected: off, or no store, or no
  ## runner, and this answers `@[]` without touching the table. On, it
  ## is `tickDue` capped to `maxFire` tasks.
  ##
  ## Never raises: a tick that cannot read or reschedule (a locked store,
  ## a closed one) comes back as ONE honest line — the same shape the
  ## live runner gives its own failures — so a broken ticker is visible
  ## in the chat and in the dashboard log instead of silent, and the loop
  ## that called it keeps running.
  if not experimental or db.isNil or run.isNil:
    return @[]
  try:
    result = db.tickDue(nowUnix, run, limit = maxFire)
  except CatchableError as exc:
    result = @["scheduler tick failed: " & exc.msg]

proc tickIfDue*(db: DbConn, experimental: bool, nowUnix: int64,
    maxFire = scheduleMaxFire, binary = ""): seq[string] =
  ## The C2b gate the two loops call: one line per task that fired (each
  ## already a sentence), `@[]` when the feature is off or nothing was
  ## due. `binary` is the executable a due brief runs — the same
  ## `getAppFilename()` the delegating turns spawn — and `""` asks for
  ## it. Never raises; see `tickIfDueWith`.
  if not experimental:
    return @[]
  var bin = binary
  if bin.len == 0:
    try:
      bin = getAppFilename()
    except CatchableError:
      return @["scheduler misconfigured: cannot locate the worker " &
        "binary."]
  if bin.len == 0:
    return @["scheduler misconfigured: cannot locate the worker " &
      "binary."]
  result = tickIfDueWith(db, experimental, nowUnix,
    liveBriefRunner(bin), maxFire)

const
  scheduleAgents* = ["brief"]
    ## The scheduler runs headless brief turns only; other agents wait.

proc validTaskName*(name: string): bool =
  ## `1..40` of letters, digits, `-` and `_` — safe for logs and ids.
  if name.len == 0 or name.len > 40:
    return false
  for c in name:
    if c notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_'}:
      return false
  return true

proc scheduleTask*(db: DbConn, name, prompt, every, agent: string,
    nowUnix: int64): string =
  ## The single entry point the model reaches. Always returns text;
  ## every rejection happens before a row exists.
  if not validTaskName(name.strip()):
    return "schedule_task needs a 'name' — 1..40 letters, digits, " &
      "'-' or '_' (e.g. 'morning-brief')."
  if prompt.strip().len == 0:
    return "schedule_task needs a 'prompt' — what the scheduled run " &
      "should do (e.g. 'send the morning brief')."
  if prompt.strip().len > 2000:
    return "Refused: 'prompt' is over 2000 chars — keep it short."
  let useAgent = if agent.strip().len == 0: "brief"
                 else: agent.strip()
  if useAgent notin scheduleAgents:
    return "Unknown agent '" & useAgent & "'. Allowed agents: " &
      scheduleAgents.join(", ") & "."
  let (ok, secs, msg) = parseInterval(every)
  if not ok:
    return msg
  let next = nextRun(nowUnix, secs)
  let id = db.addScheduledTask(name.strip(), prompt.strip(), secs,
    next, useAgent)
  return "Scheduled '" & name.strip() & "' every " & every.strip() &
    " (id " & $id & ", next run at " & $next & "). It fires while " &
    "the orchestrator lives; a restart does not resume missed runs."

proc makeScheduleTaskTool*(db: DbConn): Tool =
  ## Registry wiring for `schedule_task`. The clock resolves at call
  ## time; tests call `scheduleTask` with a fixed `nowUnix` instead.
  Tool(name: "schedule_task",
    description: "Schedule a recurring headless brief. Give it a short " &
      "name, what it should do as prompt, and 'every' as N[s/m/h/d] " &
      "(60s..7d). It fires while the orchestrator lives.",
    inputSchema: %*{"type": "object",
      "properties": {
        "name": {"type": "string",
                   "description": "1..40 letters/digits/-/_, e.g. morning-brief"},
        "prompt": {"type": "string",
                     "description": "what the scheduled run should do"},
        "every": {"type": "string",
                    "description": "interval, e.g. '10m', '1h', '1d'"},
        "agent": {"type": "string",
                    "description": "C2a runs 'brief' only; omit for default"}},
      "required": ["name", "prompt", "every"]},
    fn: proc(args: JsonNode): string =
      scheduleTask(db, strArg(args, "name"), strArg(args, "prompt"),
        strArg(args, "every"), strArg(args, "agent"),
        getTime().toUnix()))
