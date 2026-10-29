## Google Calendar — read the user's real schedule.
##
## The port shipped `list_events` reading only its sqlite (`calendar.nim`),
## which was honest in the reply but not in the product: the Connections row
## promised Google Calendar and the tool answered "no events" for a calendar it
## never looked at. This module is the read half Python has had all along
## (`waku/tools/google_calendar.py` plus `list_google_events` in
## `waku/tools/calendar.py`).
##
## Read-only, like Python's default: `calendar.events.readonly`. Creating and
## syncing events (Python's `sync_to_google_calendar`) is a WRITE path behind
## its own switch and is deliberately not here — the blast radius of a stolen
## token stays "someone can see your day", not "someone can move your life".
##
## Its own token file (`google-token.json`), never Gmail's, so revoking one
## leaves the other working. Sign-in stays where Python put it: one `connect`
## consent writes both files (see `connect.nim`).
##
## Nothing here raises on the model's behalf; every failure is a sentence.

import std/json
import std/os
import std/strutils
import std/times
import std/uri

import ./google_auth
import ./wire

const
  googleCalendarApiBase* = "https://www.googleapis.com/calendar/v3"
  googleCalendarReadScope* =
    "https://www.googleapis.com/auth/calendar.events.readonly"
    ## The scope this read path needs, and the one the sign-in asks for.
    ## Documented here rather than passed around: the token file already
    ## records which scopes it was granted, exactly like Python's reader.
  googleCalendarId* = "primary"
    ## Python's `list_google_events` reads `primary` regardless of
    ## `WAKU_GOOGLE_CALENDAR_ID`; that setting is for create/sync, which this
    ## module does not do.
  googleCalendarHint* = "Google Calendar is not connected yet." &
    " Type `/connect google` in the dashboard chat, or run" &
    " `waku connect google` in a terminal — either opens your browser to" &
    " sign in."
  googleCalendarUnavailablePrefix* = "Google Calendar unavailable"
  noGoogleEventsPrefix* = "No Google Calendar events"

proc googleCalendarTokenPath*(home: string): string =
  ## The calendar's own file — never `gmail-token.json`. Revoking mail must
  ## not break the calendar, and signing out of one must not silently break
  ## the other.
  home / "google-token.json"

proc isGoogleConnected*(home: string): bool =
  ## True when a token file exists. Cheap and side-effect free: callers use it
  ## to decide whether to even mention Google, so it must never open a socket.
  ## Port of Python's `is_connected`.
  fileExists(googleCalendarTokenPath(home))

proc googleCalendarAccessToken*(fetch: GoogleHttpFn, home: string,
    nowUnix: int64): string =
  ## The bearer for one read, or "" when the user never signed in.
  accessToken(fetch, googleCalendarTokenPath(home), nowUnix)

proc trimDay*(s: string): string =
  ## `(start or today)[:10]`: a bare date, even when the model passes a full
  ## timestamp.
  s[0 ..< min(10, s.len)]

proc nextDay*(day: string): string =
  ## The exclusive upper bound Python builds with `timedelta(days=1)`.
  format(parse(day, "yyyy-MM-dd") + initDuration(days = 1), "yyyy-MM-dd")

proc windowBounds*(start, finish: string, nowUnix: int64): tuple[
    lo, hi, s, e: string] =
  ## The ISO days the tool was asked about, plus the two RFC3339 instants
  ## Google wants. Local midnight to local midnight+1d, so "today" means the
  ## user's today and not UTC's; the offset is today's, the same approximation
  ## Python's `replace(tzinfo=tz)` makes.
  let today = googleToday(nowUnix)
  result.s = trimDay(if start.len > 0: start else: today)
  result.e = trimDay(if finish.len > 0: finish else: result.s)
  let offset = -local(fromUnix(nowUnix)).utcOffset
  result.lo = rfc3339(result.s, offset)
  result.hi = rfc3339(nextDay(result.e), offset)

proc eventsUrl*(lo, hi: string, cap: int): string =
  ## `events.list`. `singleEvents=true` expands a recurring series into the
  ## instances that fall inside the window — without it a weekly meeting is one
  ## row and "what do I have today?" misses it.
  googleCalendarApiBase & "/calendars/" & googleCalendarId & "/events?" &
    "timeMin=" & encodeUrl(lo) & "&timeMax=" & encodeUrl(hi) &
    "&singleEvents=true&orderBy=startTime&maxResults=" & $cap

proc eventLine*(ev: JsonNode): string =
  ## `title | start | attendees`, the line the model reads. An all-day event
  ## carries `start.date` and no `dateTime`; both are the answer to "when".
  let at = block:
    let withTime = ev.jget("start").jget("dateTime").getStr()
    if withTime.len > 0: withTime else: ev.jget("start").jget("date").getStr()
  var who: seq[string] = @[]
  let attendees = ev.jget("attendees")
  if attendees.kind == JArray:
    for a in attendees:
      let email = a.jget("email").getStr()
      if email.len > 0:
        who.add(email)
  # Python's `ev.get('summary', '(no title)')`: the placeholder is for a
  # MISSING title, so an event that has one (even empty) says what it has.
  let title = if ev.hasKey("summary"): ev["summary"].getStr() else: "(no title)"
  title & " | " & (if at.len > 0: at else: "?") &
    (if who.len > 0: " | " & who.join(", ") else: "")

proc listGoogleEvents*(fetch: GoogleHttpFn, home: string, nowUnix: int64,
    start = "", finish = "", limit = 20): string =
  ## One event per line, or the sentence saying why there are none. Port of
  ## `list_google_events`, including which failures read as "not signed in"
  ## rather than as an empty day.
  let bearer = googleCalendarAccessToken(fetch, home, nowUnix)
  if bearer.len == 0:
    return googleCalendarHint
  let bounds = windowBounds(start, finish, nowUnix)
  let cap = max(1, min(if limit == 0: 20 else: limit, 100))
  let (status, text) = fetch(eventsUrl(bounds.lo, bounds.hi, cap), "GET", "",
    bearer)
  if status < 200 or status >= 300:
    return googleCalendarUnavailablePrefix & " (" & errorText(status, text) & ")"
  let doc = parseObject(text)
  if doc == nil:
    return googleCalendarUnavailablePrefix & " (" & errorText(status, text) & ")"
  let items = doc.jget("items")
  if items.kind != JArray or items.len == 0:
    return noGoogleEventsPrefix & " between " & bounds.s & " and " &
      bounds.e & "."
  var lines: seq[string] = @[]
  for ev in items:
    lines.add(eventLine(ev))
  return lines.join("\n")

proc googleCalendarSection*(fetch: GoogleHttpFn, home: string, nowUnix: int64,
    start = "", finish = "", limit = 20): string =
  ## The Google section for `list_events`, or "" when there is nothing to add.
  ## Python's filter lives here once instead of at every call site: a "no
  ## events" sentence is not a section, and neither is a failure to reach the
  ## API — those belong to the summary line, not to a fake empty list.
  if not isGoogleConnected(home):
    return ""
  let found = listGoogleEvents(fetch, home, nowUnix, start, finish, limit)
  if found.startsWith(noGoogleEventsPrefix) or
      found.startsWith(googleCalendarUnavailablePrefix):
    return ""
  return found
