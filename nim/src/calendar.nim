## Calendar tools — port of the LOCAL paths of `waku/tools/calendar.py`.
##
## `createEvent` writes SQLite + `calendar.ics` and returns the exact local-only
## strings. The Apple/Google sync branches (opt-in subprocess/HTTP) are OUT of
## phase 2 and land with the gateway phases; the local-only output below IS the
## exact Python output when both sync flags are off, so parity holds for the
## ported scope. `localEvents`/`listEventsLocal` port the read side minus the
## Google section (same reason).
##
## Known subset: the default `end` (start + 1h) is computed on the wall clock
## as naive local time. Python computes it tz-aware and then truncates to
## `[:16]`, so both agree on every naive input (the only kind the model and
## the evals produce); a tz-aware start across a DST transition could differ
## by the transition amount. Documented, not planned.

import std/json
import std/os
import std/strutils
import std/times

import db_connector/db_sqlite

import ./tools

proc compactDt*(s: string): string =
  ## `2026-07-14T09:00` -> `20260714T090000`. Port of `_write_ics.dt`.
  result = s.replace("-", "").replace(":", "")
  if s.len == 16:
    result.add("00")

proc writeIcs*(home, title, start, finish, attendees: string) =
  ## Append a minimal VEVENT, keeping the file a valid VCALENDAR.
  ## Port of `_write_ics` (notes are NOT in the ICS, same as Python).
  let icsPath = home / "calendar.ics"
  let event = "BEGIN:VEVENT\n" &
    "SUMMARY:" & title & "\n" &
    "DTSTART:" & compactDt(start) & "\n" &
    "DTEND:" & compactDt(finish) & "\n" &
    "DESCRIPTION:attendees: " & attendees & "\n" &
    "END:VEVENT\n"
  var body: string
  if fileExists(icsPath):
    body = readFile(icsPath).replace("END:VCALENDAR\n", "")
  else:
    body = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//waku-agent//EN\n"
  writeFile(icsPath, body & event & "END:VCALENDAR\n")

proc defaultEnd*(start: string): string =
  ## Start + 1h formatted back to minute precision. Port of the `end`
  ## default in `create_event`.
  format(parse(start[0 ..< min(16, start.len)], "yyyy-MM-dd'T'HH:mm") +
    initDuration(hours = 1), "yyyy-MM-dd'T'HH:mm")

proc createEvent*(db: DbConn, home, title, start: string, finish = "",
                  attendees = "", notes = ""): string =
  ## Port of `create_event` with both sync flags off: title/start guard,
  ## `[:16]` normalization, title+start idempotence, SQLite + ICS write,
  ## and the exact local-only return strings.
  if title.len == 0 or start.len == 0:
    return "create_event needs at least a title and a start time " &
      "(ISO 8601, e.g. 2026-07-14T09:00). Please call it again with both."
  var endTime = if finish.len == 0: defaultEnd(start) else: finish
  let startNorm = start[0 ..< min(16, start.len)]
  endTime = endTime[0 ..< min(16, endTime.len)]
  let existing = db.getValue(sql"SELECT id FROM calendar_events WHERE title = ? AND start = ?",
                             title, startNorm)
  if existing.len > 0:
    return "Event '" & title & "' at " & startNorm & " already exists (not duplicated)."
  db.exec(sql"""INSERT INTO calendar_events (title, start, "end", attendees, notes)
                VALUES (?,?,?,?,?)""",
          title, startNorm, endTime, attendees, notes)
  writeIcs(home, title, startNorm, endTime, attendees)
  let icsPath = home / "calendar.ics"
  let where = "Saved to the local calendar (" & icsPath & ")." &
    " Not synced to any calendar app (enable with WAKU_APPLE_CALENDAR=1 " &
    "or WAKU_GOOGLE_CALENDAR=1, or import manually: open " & icsPath & ")."
  return "Event created: '" & title & "' " & startNorm & " → " & endTime &
    (if attendees.len > 0: " with " & attendees else: "") & ". " & where

proc localEvents*(db: DbConn, start = "", finish = "", limit = 20): string =
  ## Port of `local_events`: date-windowed rows oldest-first by start,
  ## `""` when nothing matches (the caller frames the empty case).
  ## Four branch queries instead of one dynamic string: `db_sqlite` binds
  ## varargs, not a param sequence, so the filter combination is explicit.
  let effective = $(max(1, min(if limit == 0: 20 else: limit, 100)))
  let base = """SELECT title, start, "end", attendees FROM calendar_events"""
  var rows: seq[Row]
  if start.len > 0 and finish.len > 0:
    rows = db.getAllRows(sql(base & " WHERE start >= ? AND start <= ? ORDER BY start LIMIT ?"),
      start[0 ..< min(10, start.len)], finish[0 ..< min(10, finish.len)] & "T23:59", effective)
  elif start.len > 0:
    rows = db.getAllRows(sql(base & " WHERE start >= ? ORDER BY start LIMIT ?"),
      start[0 ..< min(10, start.len)], effective)
  elif finish.len > 0:
    rows = db.getAllRows(sql(base & " WHERE start <= ? ORDER BY start LIMIT ?"),
      finish[0 ..< min(10, finish.len)] & "T23:59", effective)
  else:
    rows = db.getAllRows(sql(base & " ORDER BY start LIMIT ?"), effective)
  if rows.len == 0:
    return ""
  var lines: seq[string] = @[]
  for r in rows:
    lines.add("- " & r[0] & ": " & r[1] & " → " & r[2] &
      (if r[3].len > 0: " with " & r[3] else: ""))
  return lines.join("\n")

proc listEventsLocal*(db: DbConn, start = "", finish = "",
                      limit = 20): string =
  ## Port of `list_events` with no Google source signed in: the local
  ## section, or the honest no-events sentence naming the checked source.
  let local = localEvents(db, start, finish, limit)
  if local.len > 0:
    return "From waku's local calendar (events waku created):\n" & local
  let window = if start.len > 0 or finish.len > 0:
    " between " & start & " and " & finish
  else: ""
  return "No events found" & window & ". Checked: waku's local calendar."

proc makeCreateEventTool*(db: DbConn, home: string): Tool =
  ## Registry wiring for `create_event` (local-only scope).
  Tool(name: "create_event",
    description: "Create a calendar event on the user's local calendar. Use whenever the user " &
      "wants to schedule, book, or plan something at a specific time.",
    inputSchema: %*{"type": "object",
      "properties": {
        "title": {"type": "string", "description": "Short event title"},
        "start": {"type": "string", "description": "Start time, ISO 8601, e.g. 2026-07-14T09:00"},
        "end": {"type": "string", "description": "End time, ISO 8601. Defaults to start + 1h."},
        "attendees": {"type": "string", "description": "Comma-separated names/emails"},
        "notes": {"type": "string", "description": "Optional context for the event"}},
      "required": ["title", "start"]},
    fn: proc(args: JsonNode): string =
      createEvent(db, home, strArg(args, "title"), strArg(args, "start"),
                  strArg(args, "end"), strArg(args, "attendees"), strArg(args, "notes")))

proc makeListEventsTool*(db: DbConn): Tool =
  ## Registry wiring for `list_events` (local source only).
  Tool(name: "list_events",
    description: "Read the user's local calendar (events waku created). " &
      "Use whenever the user asks what's on their calendar / schedule for a day, " &
      "week, yesterday, etc. Dates are ISO (e.g. 2026-07-10); omit both to list " &
      "everything upcoming.",
    inputSchema: %*{"type": "object",
      "properties": {
        "start": {"type": "string", "description": "earliest date to include, ISO (e.g. 2026-07-10)"},
        "end": {"type": "string", "description": "latest date to include, ISO (e.g. 2026-07-10)"},
        "limit": {"type": "integer", "description": "max events to return (default 20)"}},
      "required": []},
    fn: proc(args: JsonNode): string =
      listEventsLocal(db, strArg(args, "start"), strArg(args, "end"), intArg(args, "limit", 20)))
