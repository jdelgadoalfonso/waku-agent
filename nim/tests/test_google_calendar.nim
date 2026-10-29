## `list_events` over Google Calendar: the URL, the window, the lines and the
## sentence for every failure. Offline only: the one HTTP seam is a recorder,
## so no socket exists.
##
## The rule these pin is the one the port got wrong: a calendar that was never
## read must never be reported as an empty one.

import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import db_connector/db_sqlite

import ../src/calendar
import ../src/db
import ../src/google_auth
import ../src/google_calendar

type
  Answer = proc(url: string): tuple[status: int, text: string] {.closure.}
  Recorder = ref object
    calls: seq[tuple[url, meth, body, bearer: string]]
    answer: Answer

proc newRecorder(answer: Answer): Recorder =
  Recorder(calls: @[], answer: answer)

proc fetchOf(rec: Recorder): GoogleHttpFn =
  result = proc(url, meth, body, bearer: string): tuple[status: int,
      text: string] {.closure.} =
    rec.calls.add((url, meth, body, bearer))
    rec.answer(url)

proc freshHome(name: string): tuple[home: string, db: DbConn] =
  let home = getTempDir() / name
  if dirExists(home):
    removeDir(home)
  createDir(home)
  result = (home, connectDb(home))

proc tokenFile(home: string, unixExpiry: int64) =
  ## The calendar's OWN file, in the shape `connect.nim` writes: an integer
  ## epoch. Never `gmail-token.json` — revoking mail must not break this.
  let record = %*{"token": "access-1", "refresh_token": "refresh-1",
    "token_uri": "https://oauth2.googleapis.com/token",
    "client_id": "cid", "client_secret": "secret",
    "scopes": ["https://www.googleapis.com/auth/calendar.events.readonly"],
    "expiry": unixExpiry}
  writeFile(home / "google-token.json", $record)

proc emptyAnswer(url: string): tuple[status: int, text: string] =
  (200, """{"items": []}""")

proc itemsBody(entries: seq[JsonNode]): string =
  $ %*{"items": entries}

# 2026-10-28T10:38:12Z, the instant the port's own connect wrote in the
# Gmail tests. Madrid is +01:00 then, so the local day is 2026-10-28 too.
const nowUnix = 1793183892'i64

suite "google calendar: the window and the URL":

  test "an empty start/end means the user's today, local midnight to midnight":
    let bounds = windowBounds("", "", nowUnix)
    assert bounds.s == "2026-10-28"
    assert bounds.e == "2026-10-28"
    assert bounds.lo == "2026-10-28T00:00:00+01:00"
    assert bounds.hi == "2026-10-29T00:00:00+01:00"

  test "a timestamp is cut to its day, and end defaults to start":
    let bounds = windowBounds("2026-07-10T09:00:00", "", nowUnix)
    assert bounds.s == "2026-07-10"
    assert bounds.e == "2026-07-10"
    assert bounds.hi == "2026-07-11T00:00:00+01:00"

  test "the request expands recurrences and orders by start":
    ## Without `singleEvents=true` a weekly meeting is one row and "what do I
    ## have today?" misses it — the exact question this tool answers.
    let url = eventsUrl("2026-10-28T00:00:00+01:00", "2026-10-29T00:00:00+01:00", 20)
    assert url.startsWith("https://www.googleapis.com/calendar/v3/calendars/primary/events?")
    assert "timeMin=2026-10-28T00%3A00%3A00%2B01%3A00" in url
    assert "timeMax=2026-10-29T00%3A00%3A00%2B01%3A00" in url
    assert "singleEvents=true" in url
    assert "orderBy=startTime" in url
    assert url.endsWith("maxResults=20")

suite "google calendar: the token refresh it shares with Gmail":

  test "the token endpoint is the one call that is not JSON":
    ## Sending `client_id=...&grant_type=refresh_token` as `application/json`
    ## is refused with "Invalid JSON payload received. Unexpected token.
    ## client_id=...". That is how EVERY refresh in this port failed, so a
    ## signed-in user with an expired access token was told to sign in again
    ## while a good refresh_token sat on disk — the calendar read and Gmail
    ## both. The live fetch picks the encoding from this rule.
    assert wantsFormBody("https://oauth2.googleapis.com/token")
    assert wantsFormBody("https://token.example.invalid/token")
    assert not wantsFormBody("https://www.googleapis.com/calendar/v3/calendars/primary/events")
    assert not wantsFormBody("https://gmail.googleapis.com/gmail/v1/users/me/messages")

  test "a refresh body is the form the endpoint wants, never JSON":
    let token = %*{"client_id": "cid", "client_secret": "sec",
      "refresh_token": "ref", "expiry": 1}
    let body = refreshBody(token)
    assert body == "client_id=cid&client_secret=sec&refresh_token=ref&" &
      "grant_type=refresh_token"
    assert not body.startsWith("{")


suite "google calendar: the lines the model reads":

  test "title | start | attendees, in that order":
    let line = eventLine(%*{"summary": "Reunión Tutores",
      "start": {"dateTime": "2026-10-29T20:00:00+01:00"},
      "attendees": @[%*{"email": "ana@example.com"},
        %*{"email": "bob@example.com"}]})
    assert line == "Reunión Tutores | 2026-10-29T20:00:00+01:00 | ana@example.com, bob@example.com"

  test "an all-day event has no dateTime and is still an answer":
    ## Gmail's sibling case: the field the line reads changes shape, and a
    ## blank "when" would make the model guess.
    let line = eventLine(%*{"summary": "Vacaciones", "start": {"date": "2026-10-29"}})
    assert line == "Vacaciones | 2026-10-29"

  test "an event with no title says so instead of printing nothing":
    assert eventLine(%*{"start": {"date": "2026-10-29"}}) == "(no title) | 2026-10-29"

  test "an attendee without an email is skipped, not rendered empty":
    let line = eventLine(%*{"summary": "X", "start": {"date": "2026-10-29"},
      "attendees": @[%*{"displayName": "Ana"}, %*{"email": "bob@example.com"}]})
    assert line == "X | 2026-10-29 | bob@example.com"

suite "google calendar: what each failure reads as":

  test "no token at all is the sign-in sentence, and spends no call":
    let (home, db) = freshHome("waku-gcal-notoken")
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (599, "must not be called"))
    let text = listGoogleEvents(rec.fetchOf(), home, nowUnix)
    assert text == googleCalendarHint
    assert "/connect google" in text
    assert rec.calls.len == 0
    db.close()
    removeDir(home)

  test "a signed-in calendar with nothing in it says which window was read":
    let (home, db) = freshHome("waku-gcal-empty")
    tokenFile(home, nowUnix + 3600)
    let rec = newRecorder(emptyAnswer)
    assert listGoogleEvents(rec.fetchOf(), home, nowUnix, "2026-10-28",
      "2026-10-28") == "No Google Calendar events between 2026-10-28 and 2026-10-28."
    assert rec.calls[0].bearer == "access-1"
    assert rec.calls[0].meth == "GET"
    db.close()
    removeDir(home)

  test "a disabled API keeps Google's own instruction":
    let (home, db) = freshHome("waku-gcal-apioff")
    tokenFile(home, nowUnix + 3600)
    const body = """{"error": {"code": 403, "message": "Google Calendar API has not been used in project 771409951767 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=771409951767 then retry."}}"""
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (403, body))
    let text = listGoogleEvents(rec.fetchOf(), home, nowUnix)
    assert text.startsWith(googleCalendarUnavailablePrefix)
    assert "https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=771409951767" in text
    db.close()
    removeDir(home)

  test "an expired token is refreshed from the calendar's own file":
    ## The shared loader, one file per capability: the refresh must write
    ## `google-token.json` and never touch Gmail's.
    let (home, db) = freshHome("waku-gcal-refresh")
    tokenFile(home, nowUnix - 10)
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      if "oauth2" in url:
        return (200, """{"access_token": "access-2", "expires_in": 3600}""")
      (200, """{"items": []}"""))
    discard listGoogleEvents(rec.fetchOf(), home, nowUnix)
    assert "oauth2.googleapis.com/token" in rec.calls[0].url.replace("%2F", "/").replace("%3A", ":")
    assert rec.calls[1].bearer == "access-2"
    let saved = parseJson(readFile(home / "google-token.json"))
    assert saved["token"].getStr() == "access-2"
    assert saved["expiry"].kind == JInt
    assert not fileExists(home / "gmail-token.json")
    db.close()
    removeDir(home)

  test "an expired token with no refresh_token is not connected, and spends no call":
    let (home, db) = freshHome("waku-gcal-norefresh")
    writeFile(home / "google-token.json", $ %*{"token": "access-1",
      "expiry": nowUnix - 10})
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (599, "must not be called"))
    assert listGoogleEvents(rec.fetchOf(), home, nowUnix) == googleCalendarHint
    assert rec.calls.len == 0
    db.close()
    removeDir(home)

suite "list_events: every connected source, labelled":

  test "Google and local rows arrive in their own sections":
    let (home, db) = freshHome("waku-gcal-both")
    tokenFile(home, nowUnix + 3600)
    discard db.createEvent(home, "Dentist", "2026-10-28T09:00")
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (200, itemsBody(@[%*{"summary": "Reunión",
        "start": {"dateTime": "2026-10-28T20:00:00+01:00"}}])))
    let text = listEventsComposed(db, home, rec.fetchOf(), nowUnix, "2026-10-28",
      "2026-10-28")
    assert text == "From Google Calendar:\n" &
      "Reunión | 2026-10-28T20:00:00+01:00\n\n" &
      "From waku's local calendar (events waku created):\n" &
      "- Dentist: 2026-10-28T09:00 → 2026-10-28T10:00"
    db.close()
    removeDir(home)

  test "an empty Google day is not a section, but the checked line names it":
    ## The bug this whole module exists for: the reply has to say whether
    ## Google was read, so "no events" is never mistaken for "not looked at".
    let (home, db) = freshHome("waku-gcal-checked")
    tokenFile(home, nowUnix + 3600)
    let rec = newRecorder(emptyAnswer)
    let text = listEventsComposed(db, home, rec.fetchOf(), nowUnix, "2026-10-28",
      "2026-10-28")
    assert text == "No events found between 2026-10-28 and 2026-10-28." &
      " Checked: Google Calendar, waku's local calendar."
    assert rec.calls.len == 1
    db.close()
    removeDir(home)

  test "without a token Google is not consulted and not claimed":
    let (home, db) = freshHome("waku-gcal-nosignin")
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (599, "must not be called"))
    let text = listEventsComposed(db, home, rec.fetchOf(), nowUnix)
    assert text == "No events found. Checked: waku's local calendar."
    assert rec.calls.len == 0
    db.close()
    removeDir(home)

  test "a Google failure is reported, never silently an empty day":
    let (home, db) = freshHome("waku-gcal-fail")
    tokenFile(home, nowUnix + 3600)
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (401, """{"error": {"message": "Invalid Credentials"}}"""))
    let text = listEventsComposed(db, home, rec.fetchOf(), nowUnix)
    assert text == "No events found. Checked: Google Calendar, waku's local calendar."
    # The section stays out (there are no rows to show), but the tool did look:
    # a broken token must not read as a clear calendar, and the model can see
    # the failure in the call's own reply only through this line's wording.
    assert not text.contains("Reunión")
    db.close()
    removeDir(home)

suite "list_events: the tool wiring":

  test "home decides whether Google is a candidate, and the clock is injected":
    let (home, db) = freshHome("waku-gcal-tool")
    tokenFile(home, nowUnix + 3600)
    let rec = newRecorder(proc(url: string): tuple[status: int, text: string] =
      (200, itemsBody(@[%*{"summary": "Reunión",
        "start": {"dateTime": "2026-10-28T20:00:00+01:00"}}])))
    let tool = makeListEventsTool(db, home, rec.fetchOf(),
      proc(): int64 = nowUnix)
    let text = tool.fn(%*{"start": "2026-10-28", "end": "2026-10-28"})
    assert text.startsWith("From Google Calendar:\nReunión")
    assert "timeMin=2026-10-28T00%3A00%3A00%2B01%3A00" in rec.calls[0].url
    db.close()
    removeDir(home)

  test "with no home the tool is exactly the local one it used to be":
    let (home, db) = freshHome("waku-gcal-tool-local")
    discard db.createEvent(home, "Dentist", "2026-10-28T09:00")
    let tool = makeListEventsTool(db)
    assert tool.fn(%*{}) == "From waku's local calendar (events waku created):\n" &
      "- Dentist: 2026-10-28T09:00 → 2026-10-28T10:00"
    db.close()
    removeDir(home)
