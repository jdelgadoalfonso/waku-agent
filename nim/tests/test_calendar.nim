## Phase 2b tests: local calendar tools against a real temp state.db.
## Offline only: temp homes under getTempDir(), no network.

import std/json
import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/calendar
import ../src/db
import ../src/tools

proc freshDb(name: string): tuple[home: string, db: DbConn] =
  let home = getTempDir() / name
  if dirExists(home):
    removeDir(home)
  result = (home, connectDb(home))

suite "phase 2b create_event":
  test "creates the row, the ICS, and the exact message":
    let (home, db) = freshDb("waku-cal-create")
    let msg = db.createEvent(home, "Dentist", "2026-07-14T09:00", "",
                             "amy", "bring card")
    assert msg == "Event created: 'Dentist' 2026-07-14T09:00 → 2026-07-14T10:00" &
      " with amy. Saved to the local calendar (" & home / "calendar.ics" & ")." &
      " Not synced to any calendar app (enable with WAKU_APPLE_CALENDAR=1 " &
      "or WAKU_GOOGLE_CALENDAR=1, or import manually: open " &
      home / "calendar.ics" & ")."
    assert db.getValue(sql"SELECT COUNT(*) FROM calendar_events") == "1"
    let ics = readFile(home / "calendar.ics")
    assert "BEGIN:VCALENDAR" in ics
    assert "SUMMARY:Dentist" in ics
    assert "DTSTART:20260714T090000" in ics
    assert "DTEND:20260714T100000" in ics
    assert "DESCRIPTION:attendees: amy" in ics
    assert ics.endsWith("END:VCALENDAR\n")
    db.close()
    removeDir(home)

  test "missing title or start returns the recoverable message":
    let (home, db) = freshDb("waku-cal-guard")
    assert db.createEvent(home, "", "2026-07-14T09:00").startsWith(
      "create_event needs at least a title and a start time")
    assert db.createEvent(home, "X", "").startsWith(
      "create_event needs at least a title and a start time")
    assert db.getValue(sql"SELECT COUNT(*) FROM calendar_events") == "0"
    db.close()
    removeDir(home)

  test "same title+start is not duplicated":
    let (home, db) = freshDb("waku-cal-idem")
    discard db.createEvent(home, "Standup", "2026-07-14T09:00")
    assert db.createEvent(home, "Standup", "2026-07-14T09:00") ==
      "Event 'Standup' at 2026-07-14T09:00 already exists (not duplicated)."
    assert db.getValue(sql"SELECT COUNT(*) FROM calendar_events") == "1"
    db.close()
    removeDir(home)

  test "explicit end is kept, seconds are normalized away":
    let (home, db) = freshDb("waku-cal-end")
    let msg = db.createEvent(home, "Lunch", "2026-07-11T17:00:00",
                             "2026-07-11T18:30:00")
    assert "2026-07-11T17:00 → 2026-07-11T18:30" in msg
    db.close()
    removeDir(home)

suite "phase 2b list_events":
  test "windows, limits and formats match":
    let (home, db) = freshDb("waku-cal-list")
    discard db.createEvent(home, "Old", "2026-07-01T09:00")
    discard db.createEvent(home, "Mid", "2026-07-10T09:00", "", "bob", "")
    discard db.createEvent(home, "New", "2026-07-20T09:00")
    let one = db.listEventsLocal("2026-07-10", "2026-07-10")
    assert one == "From waku's local calendar (events waku created):\n" &
      "- Mid: 2026-07-10T09:00 → 2026-07-10T10:00 with bob"
    assert db.localEvents("", "", 2).splitLines().len == 2
    db.close()
    removeDir(home)

  test "empty calendar names the checked source":
    let (home, db) = freshDb("waku-cal-empty")
    assert db.listEventsLocal() ==
      "No events found. Checked: waku's local calendar."
    assert db.listEventsLocal("2026-07-01", "2026-07-31") ==
      "No events found between 2026-07-01 and 2026-07-31. Checked: waku's local calendar."
    db.close()
    removeDir(home)

suite "phase 2b registry wiring":
  test "tools run through the registry with JSON args":
    let (home, db) = freshDb("waku-cal-reg")
    var reg: ToolRegistry
    reg.register(makeCreateEventTool(db, home))
    reg.register(makeListEventsTool(db))
    assert reg.execute("create_event",
      %*{"title": "Dentist", "start": "2026-07-14T09:00"}).startsWith(
      "Event created: 'Dentist'")
    assert "Dentist" in reg.execute("list_events", %*{})
    assert reg.execute("create_event", %*{"title": "X"}).startsWith(
      "create_event needs at least")
    db.close()
    removeDir(home)
