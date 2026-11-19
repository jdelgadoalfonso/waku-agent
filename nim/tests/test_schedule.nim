## `schedule_task` C2a tests: pure interval math, no clock, no ticker.
## The store lands here too (C2a) with the tick (C2b) and its claim
## (C2c). Offline only: no subprocess, no network.

import std/json
import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/schedule
import ../src/tools

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "schedule intervals":
  test "plain seconds and suffixed units parse":
    let (okS, secsS, _) = parseInterval("90")
    assert okS and secsS == 90
    let (okM, secsM, _) = parseInterval("10m")
    assert okM and secsM == 600
    let (okH, secsH, _) = parseInterval("1h")
    assert okH and secsH == 3600
    let (okD, secsD, _) = parseInterval("1d")
    assert okD and secsD == 86400

  test "an every prefix is accepted and case is ignored":
    let (ok, secs, _) = parseInterval("Every 5M")
    assert ok and secs == 300

  test "garbage, zero and out-of-range are refused honestly":
    for bad in ["", "every", "0", "-5m", "10x", "100d", "every hour"]:
      let (ok, _, msg) = parseInterval(bad)
      assert not ok, bad
      assert "every" in msg.toLowerAscii() or "between" in msg.toLowerAscii()

  test "next run is pure addition and due is a comparison":
    assert nextRun(1000, 60) == 1060
    assert isDue(1060, 1060)
    assert isDue(2000, 1060)
    assert not isDue(1059, 1060)

suite "schedule store":
  test "add, list, due and reschedule round-trip":
    let home = freshHome("waku-sched-store")
    let db = connectDb(home)
    let id = db.addScheduledTask("morning", "send brief", 3600, 2000)
    assert id > 0
    let all = db.listScheduledTasks()
    assert all.len == 1
    assert all[0].name == "morning"
    assert all[0].intervalSec == 3600
    assert all[0].nextRun == 2000
    assert db.dueScheduledTasks(1999).len == 0
    assert db.dueScheduledTasks(2000).len == 1
    assert db.markScheduledDone(id, 5600)
    assert db.dueScheduledTasks(5599).len == 0
    assert db.dueScheduledTasks(5600).len == 1
    db.close()
    removeDir(home)

suite "schedule tool":
  test "empty name, prompt and bad interval are refused before DB":
    let home = freshHome("waku-sched-tool")
    let db = connectDb(home)
    assert "name" in db.scheduleTask("", "do it", "10m", "brief",
      1000).toLowerAscii()
    assert "prompt" in db.scheduleTask("nightly", "", "10m", "brief",
      1000).toLowerAscii()
    let before = db.listScheduledTasks().len
    assert "every" in db.scheduleTask("nightly", "do it", "hour",
      "brief", 1000).toLowerAscii()
    assert db.listScheduledTasks().len == before
    db.close()
    removeDir(home)

  test "unknown agent is refused, brief schedules honestly":
    let home = freshHome("waku-sched-tool2")
    let db = connectDb(home)
    assert "agent" in db.scheduleTask("nightly", "do it", "10m",
      "worker", 1000).toLowerAscii()
    let msg = db.scheduleTask("nightly", "send brief", "10m", "brief",
      1000)
    assert "scheduled" in msg.toLowerAscii()
    assert "nightly" in msg
    let due = db.dueScheduledTasks(1600)
    assert due.len == 1 and due[0].name == "nightly"
    db.close()
    removeDir(home)

suite "schedule tick core":
  test "no due tasks runs nothing and reschedules nothing":
    let home = freshHome("waku-sched-tick-empty")
    let db = connectDb(home)
    discard db.addScheduledTask("later", "do later", 600, 5000)
    var calls: seq[string]
    let outputs = db.tickDue(1000, proc(task: ScheduledTask): string =
      calls.add(task.name)
      "ran")
    assert calls.len == 0
    assert outputs.len == 0
    assert db.listScheduledTasks()[0].nextRun == 5000
    db.close()
    removeDir(home)

  test "one due task runs once, reschedules and returns its output":
    let home = freshHome("waku-sched-tick-one")
    let db = connectDb(home)
    let id = db.addScheduledTask("morning", "send brief", 60, 1000)
    var calls = 0
    let outputs = db.tickDue(1000, proc(task: ScheduledTask): string =
      calls.inc
      assert task.id == id and task.name == "morning"
      "brief text")
    assert calls == 1
    assert outputs.len == 1 and outputs[0] == "brief text"
    assert db.dueScheduledTasks(1059).len == 0
    assert db.dueScheduledTasks(1060).len == 1
    assert db.listScheduledTasks()[0].nextRun == 1060
    db.close()
    removeDir(home)

  test "two due tasks run in next_run order and both reschedule":
    let home = freshHome("waku-sched-tick-order")
    let db = connectDb(home)
    discard db.addScheduledTask("late", "late prompt", 120, 1000)
    discard db.addScheduledTask("early", "early prompt", 60, 900)
    var calls: seq[string]
    let outputs = db.tickDue(1100, proc(task: ScheduledTask): string =
      calls.add(task.name)
      task.name & ": " & task.prompt)
    assert calls == @["early", "late"]
    assert outputs == @["early: early prompt", "late: late prompt"]
    assert db.dueScheduledTasks(1159).len == 0
    assert db.dueScheduledTasks(1160).len == 1
    assert db.dueScheduledTasks(1220).len == 2
    db.close()
    removeDir(home)

  test "runner failure reports the error and still reschedules":
    let home = freshHome("waku-sched-tick-fail")
    let db = connectDb(home)
    discard db.addScheduledTask("broken", "explode", 60, 1000)
    var calls = 0
    let outputs = db.tickDue(1000, proc(task: ScheduledTask): string =
      calls.inc
      raise newException(ValueError, "boom"))
    assert calls == 1
    assert outputs.len == 1
    assert "broken" in outputs[0]
    assert "boom" in outputs[0]
    assert db.dueScheduledTasks(1059).len == 0
    assert db.dueScheduledTasks(1060).len == 1
    db.close()
    removeDir(home)

suite "schedule tick gate":
  test "off runs nothing even when a task is due":
    let home = freshHome("waku-sched-gate-off")
    let db = connectDb(home)
    let id = db.addScheduledTask("morning", "send brief", 60, 1000)
    var calls: seq[string]
    let outputs = db.tickIfDueWith(false, 5000,
      proc(task: ScheduledTask): string =
        calls.add(task.name)
        "ran")
    assert calls.len == 0
    assert outputs.len == 0
    # Still due, still at its own time: the gate changed nothing.
    let due = db.dueScheduledTasks(5000)
    assert due.len == 1 and due[0].id == id and due[0].nextRun == 1000
    db.close()
    removeDir(home)

  test "the production gate is inert with the feature off":
    # No store and no spawn: off is a gate, not a try.
    assert tickIfDue(nil, false, 1000).len == 0

  test "on runs due tasks and caps one pass at maxFire":
    let home = freshHome("waku-sched-gate-cap")
    let db = connectDb(home)
    for i in 1 .. 5:
      discard db.addScheduledTask("task" & $i, "do it", 60, 1000)
    var calls: seq[string]
    let outputs = db.tickIfDueWith(true, 1000,
      proc(task: ScheduledTask): string =
        calls.add(task.name)
        "ran " & task.name, maxFire = 2)
    assert calls.len == 2
    assert outputs.len == 2
    # The two that ran moved to now + interval; the other three wait.
    assert db.dueScheduledTasks(1000).len == 3
    assert db.dueScheduledTasks(1059).len == 3
    assert db.dueScheduledTasks(1060).len == 5
    db.close()
    removeDir(home)

  test "a broken store is one line, never an escaped exception":
    let home = freshHome("waku-sched-gate-broken")
    let db = connectDb(home)
    db.exec(sql"DROP TABLE scheduled_tasks")
    let outputs = db.tickIfDueWith(true, 1000,
      proc(task: ScheduledTask): string = "ran")
    assert outputs.len == 1
    assert "failed" in outputs[0]
    db.close()
    removeDir(home)

suite "schedule claim":
  test "two owners racing the same due row: the second claims nothing":
    let home = freshHome("waku-sched-claim-race")
    let db = connectDb(home)
    discard db.addScheduledTask("morning", "send brief", 60, 1000)
    let first = db.claimDueTasks(1000, "owner-a")
    assert first.len == 1
    assert first[0].name == "morning"
    assert first[0].claimedBy == "owner-a"
    assert first[0].claimedAt == 1000
    # Second loop reaches the same row at the same second: nothing to take.
    assert db.claimDueTasks(1000, "owner-b").len == 0
    db.close()
    removeDir(home)

  test "a stale claim is reclaimable, a live one holds the row":
    let home = freshHome("waku-sched-claim-lease")
    let db = connectDb(home)
    discard db.addScheduledTask("morning", "send brief", 60, 1000)
    assert db.claimDueTasks(1000, "owner-a").len == 1
    # Inside the lease the row belongs to owner-a.
    assert db.claimDueTasks(1000 + scheduleClaimLeaseSec - 1,
      "owner-b").len == 0
    # Past the lease (a crashed run) the next owner takes it over.
    let taken = db.claimDueTasks(1000 + scheduleClaimLeaseSec + 1,
      "owner-b")
    assert taken.len == 1
    assert taken[0].name == "morning"
    assert taken[0].claimedBy == "owner-b"
    db.close()
    removeDir(home)

  test "reschedule clears the claim":
    let home = freshHome("waku-sched-claim-clear")
    let db = connectDb(home)
    let id = db.addScheduledTask("morning", "send brief", 60, 1000)
    assert db.claimDueTasks(1000, "owner-a").len == 1
    assert db.markScheduledDone(id, 1060)
    let row = db.listScheduledTasks()[0]
    assert row.nextRun == 1060
    assert row.claimedAt == 0
    assert row.claimedBy.len == 0
    db.close()
    removeDir(home)

  test "a row a live owner claimed is invisible to the due listing":
    let home = freshHome("waku-sched-claim-hidden")
    let db = connectDb(home)
    discard db.addScheduledTask("morning", "send brief", 60, 1000)
    assert db.dueScheduledTasks(1000).len == 1
    assert db.claimDueTasks(1000, "owner-a").len == 1
    assert db.dueScheduledTasks(1000).len == 0
    # Once the lease expires the row is due (and claimable) again.
    assert db.dueScheduledTasks(1000 + scheduleClaimLeaseSec + 1).len == 1
    db.close()
    removeDir(home)

  test "a tick skips a row another live owner already claimed":
    let home = freshHome("waku-sched-claim-tick-skip")
    let db = connectDb(home)
    discard db.addScheduledTask("morning", "send brief", 60, 1000)
    # Loop 1 wins the claim and is still running; loop 2 ticks meanwhile.
    assert db.claimDueTasks(1000, "loop-1").len == 1
    var calls: seq[string]
    let outputs = db.tickDue(1000, proc(task: ScheduledTask): string =
      calls.add(task.name)
      "ran")
    assert calls.len == 0
    assert outputs.len == 0
    db.close()
    removeDir(home)

  test "a tick claims only its rows and releases them after the run":
    let home = freshHome("waku-sched-claim-tick-own")
    let db = connectDb(home)
    discard db.addScheduledTask("a", "do a", 60, 900)
    discard db.addScheduledTask("b", "do b", 60, 1000)
    var calls: seq[string]
    let outputs = db.tickDue(1000, proc(task: ScheduledTask): string =
      calls.add(task.name)
      task.name & " ran", limit = 1)
    assert calls.len == 1 and calls[0] == "a"
    assert outputs == @["a ran"]
    # The claimed row moved and its claim is gone; the untouched row
    # is still due and claimable by the next tick.
    let rest = db.claimDueTasks(1000, "next-loop")
    assert rest.len == 1 and rest[0].name == "b"
    for task in db.listScheduledTasks():
      if task.name == "a":
        assert task.claimedAt == 0
        assert task.claimedBy.len == 0
        assert task.nextRun == 1060
    db.close()
    removeDir(home)

  test "an empty owner claims nothing and leaves the row free":
    let home = freshHome("waku-sched-claim-no-owner")
    let db = connectDb(home)
    discard db.addScheduledTask("morning", "send brief", 60, 1000)
    assert db.claimDueTasks(1000, "").len == 0
    let row = db.listScheduledTasks()[0]
    assert row.claimedAt == 0 and row.claimedBy.len == 0
    assert db.dueScheduledTasks(1000).len == 1
    db.close()
    removeDir(home)

  test "an older database gains the claim columns and keeps its rows":
    # A store created before C2c: the table has no claim columns yet.
    let home = freshHome("waku-sched-claim-migrate")
    createDir(home)
    block:
      let old = open(home / "state.db", "", "", "")
      old.exec(sql("CREATE TABLE scheduled_tasks (" &
        "id INTEGER PRIMARY KEY, name TEXT NOT NULL, " &
        "prompt TEXT NOT NULL, agent TEXT DEFAULT 'brief', " &
        "interval_sec INTEGER NOT NULL, next_run INTEGER NOT NULL, " &
        "created_at TEXT DEFAULT (datetime('now')))"))
      old.exec(sql("INSERT INTO scheduled_tasks " &
        "(name, prompt, agent, interval_sec, next_run) " &
        "VALUES ('legacy', 'old prompt', 'brief', 60, 1000)"))
      old.close()
    let db = connectDb(home)
    assert "claimed_at" in db.scheduledTaskColumns()
    assert "claimed_by" in db.scheduledTaskColumns()
    let rows = db.listScheduledTasks()
    assert rows.len == 1 and rows[0].name == "legacy"
    assert rows[0].claimedAt == 0
    assert rows[0].claimedBy.len == 0
    assert db.claimDueTasks(1000, "owner-a").len == 1
    db.close()
    # Opening it again is idempotent: no duplicate column, no lost row.
    let again = connectDb(home)
    assert again.listScheduledTasks().len == 1
    again.close()
    removeDir(home)

suite "schedule live runner":
  test "live runner builds the brief worker argv and returns its reply":
    var seenArgv: seq[string]
    var seenInput = ""
    var seenTimeout = 0
    let run = liveBriefRunner("/opt/waku",
      proc(argv: seq[string], stdinText: string,
          timeoutSec: int): tuple[res: ProcResult, pid: int] =
        seenArgv = argv
        seenInput = stdinText
        seenTimeout = timeoutSec
        let done = %*{"v": 1, "type": "done", "trace_id": "t",
          "turn_id": "u", "agent": "brief", "pid": 0,
          "payload": {"reply": "All clear.", "draft_path": ""}}
        (res: ProcResult(timedOut: false, code: 0, stdout: $done,
          stderr: ""), pid: 42))
    let line = run(ScheduledTask(id: 7, name: "morning",
      prompt: "send the brief", agent: "brief", intervalSec: 60,
      nextRun: 1000))
    assert seenArgv == @["/opt/waku", "--role", "worker", "--agent",
      "brief"]
    assert seenTimeout >= 1
    let wire = parseJson(seenInput)
    assert wire["task"].getStr() == "send the brief"
    assert wire["trace_id"].getStr().len > 0
    assert wire["turn_id"].getStr().len > 0
    assert wire["budget"]["timeout_ms"].getInt() > 0
    assert "morning" in line
    assert "All clear." in line

  test "a timeout is one honest killed line":
    let run = liveBriefRunner("/opt/waku",
      proc(argv: seq[string], stdinText: string,
          timeoutSec: int): tuple[res: ProcResult, pid: int] =
        (res: ProcResult(timedOut: true, code: 124, stdout: "",
          stderr: ""), pid: 1))
    let line = run(ScheduledTask(id: 1, name: "slow", prompt: "do it",
      agent: "brief", intervalSec: 60, nextRun: 1000))
    assert "slow" in line
    assert "timed out" in line
    assert "killed" in line

  test "a nonzero exit reports the code and a stderr snippet":
    let run = liveBriefRunner("/opt/waku",
      proc(argv: seq[string], stdinText: string,
          timeoutSec: int): tuple[res: ProcResult, pid: int] =
        (res: ProcResult(timedOut: false, code: 2, stdout: "",
          stderr: "provider key missing\nstack trace"), pid: 1))
    let line = run(ScheduledTask(id: 1, name: "nightly", prompt: "do it",
      agent: "brief", intervalSec: 60, nextRun: 1000))
    assert "nightly" in line
    assert "exit 2" in line
    assert "provider key missing" in line

  test "empty output is a no-output line, not a silent success":
    let run = liveBriefRunner("/opt/waku",
      proc(argv: seq[string], stdinText: string,
          timeoutSec: int): tuple[res: ProcResult, pid: int] =
        (res: ProcResult(timedOut: false, code: 0, stdout: "",
          stderr: ""), pid: 1))
    let line = run(ScheduledTask(id: 1, name: "quiet", prompt: "do it",
      agent: "brief", intervalSec: 60, nextRun: 1000))
    assert "quiet" in line
    assert "no output" in line.toLowerAscii()

  test "a spawn exception becomes a line, never an escaped exception":
    let run = liveBriefRunner("/opt/waku",
      proc(argv: seq[string], stdinText: string,
          timeoutSec: int): tuple[res: ProcResult, pid: int] =
        raise newException(OSError, "spawn denied"))
    let line = run(ScheduledTask(id: 1, name: "denied", prompt: "do it",
      agent: "brief", intervalSec: 60, nextRun: 1000))
    assert "denied" in line
    assert "spawn denied" in line
