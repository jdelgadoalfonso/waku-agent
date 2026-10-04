## Apple tools tests: date parsing, window filtering, creation
## messages and the platform guard — the `osascript` runner is always a
## stub here. Offline only: nothing macOS ever executes.

import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import ../src/apple
import ../src/tools

proc stubSeams(scripts: openArray[(string,
    tuple[ok: bool, text: string])]): AppleSeams =
  var table: seq[(string, tuple[ok: bool, text: string])] = @[]
  for (k, v) in scripts:
    table.add((k, v))
  # `hostOs` follows Nim's `hostOS` vocabulary (`macosx`, like the
  # integrations status check) — not Python's `sys.platform`.
  AppleSeams(hostOs: "macosx",
    run: proc(script: string, timeoutSec: int): tuple[ok: bool,
        text: string] {.closure.} =
      for (k, v) in table:
        if k in script:
          return v
      raise newException(ValueError, "unstubbed osascript: " &
        script[0 ..< min(80, script.len)]),
    isRunning: proc(app: string): bool = true,
    launch: proc(app: string) = discard)

suite "apple dates":
  test "a calendar stamp parses to sortable form":
    assert parseAppleDate("Thursday, July 30, 2026 at 1:00:00 PM") ==
      (true, "2026-07-30 13:00")

  test "midnight and noon do not flip":
    assert parseAppleDate("Friday, July 31, 2026 at 12:00:00 AM") ==
      (true, "2026-07-31 00:00")
    assert parseAppleDate("Friday, July 31, 2026 at 12:00:00 PM") ==
      (true, "2026-07-31 12:00")

  test "garbage parses to nothing":
    assert parseAppleDate("whenever")[0] == false
    assert parseAppleDate("July 30 at teatime")[0] == false

suite "apple calendar":
  test "rows outside the window are dropped":
    let seams = stubSeams([("Calendar", (true,
      "Work\tStandup\tThursday, July 30, 2026 at 9:00:00 AM\n" &
      "Work\tOld news\tMonday, July 20, 2026 at 9:00:00 AM\n" &
      "broken line without tabs\n"))])
    let now = parse("2026-07-30T00:00:00", "yyyy-MM-dd'T'HH:mm:ss")
    let text = readAppleCalendar(seams, "Work", 7, now)
    assert "Standup" in text
    assert "Old news" notin text
    assert "2026-07-30 09:00" in text

  test "no calendars names the env var":
    let seams = stubSeams([])
    assert "WAKU_APPLE_CALENDARS" in readAppleCalendar(seams, "", 7)

  test "an empty window says so":
    let seams = stubSeams([("Calendar", (true, ""))])
    let now = parse("2026-07-30T00:00:00", "yyyy-MM-dd'T'HH:mm:ss")
    assert readAppleCalendar(seams, "Work", 7, now) ==
      "No events in that window."

suite "apple mail, reminders, notes":
  test "mail passes the raw listing through":
    let seams = stubSeams([("Mail", (true, "Hi | ana | today"))])
    assert readAppleMail(seams) == "Hi | ana | today"

  test "mail failures carry the sync note":
    let seams = stubSeams([("Mail", (false, "boom"))])
    assert "Mail unavailable: boom" in readAppleMail(seams)

  test "creations answer in one line":
    let seams = stubSeams([("Reminders", (true, "")),
      ("Notes", (true, ""))])
    assert createAppleReminder(seams, "Swim", "Monday") ==
      "Reminder created: Swim"
    assert createAppleNote(seams, "List", "eggs") == "Note created: List"

  test "off darwin everything is macOS-only before any seam runs":
    let seams = AppleSeams(hostOs: "linux",
      run: proc(script: string, timeoutSec: int): tuple[ok: bool,
          text: string] {.closure.} =
        raise newException(ValueError, "must not run"),
      isRunning: proc(app: string): bool = false,
      launch: proc(app: string) = discard)
    assert "macOS-only" in readAppleCalendar(seams, "Work", 7)
    assert "macOS-only" in readAppleMail(seams)
    assert "macOS-only" in createAppleReminder(seams, "x")
    assert "macOS-only" in createAppleNote(seams, "x")

suite "apple tool wiring":
  test "reads cache behind their TTL keys":
    putEnv("WAKU_APPLE_CALENDARS", "Work")
    var calls = 0
    let seams = AppleSeams(hostOs: "macosx",
      run: proc(script: string, timeoutSec: int): tuple[ok: bool,
          text: string] {.closure.} =
        inc calls
        (true, ""),
      isRunning: proc(app: string): bool = true,
      launch: proc(app: string) = discard)
    let tools = makeAppleTools(seams)
    assert tools.len == 4
    discard tools[0].fn(%*{"days_ahead": 7})
    discard tools[0].fn(%*{"days_ahead": 7})
    delEnv("WAKU_APPLE_CALENDARS")
    assert calls == 1
