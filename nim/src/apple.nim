## Apple Calendar/Mail/Reminders/Notes via osascript (macOS only).
##
## Port of `waku/tools/apple.py`. The subprocess rides an injected
## `OsaRunner` (script + timeout → text), `ensure_running`'s launch
## check rides two more tiny seams — tests replay all three, the binary
## shells to `pgrep`/`open`/`osascript`. Off Darwin everything answers
## "macOS-only" before any seam runs, like Python's `_osa` guard.
##
## Reads carry the same TTL caches keyed like Python (`cal:<days>`,
## `mail:<hours>:<limit>`); the cache lives in the tool closure, so one
## agent reuses it across turns without a process global.

import std/algorithm
import std/json
import std/monotimes
import std/os
import std/strutils
import std/tables
import std/times

import ./tools

const
  osaTimeoutSec* = 30
  osaProbeTimeoutSec* = 8
  osaSlowTimeoutSec* = 25
  probeApps* = ["Calendar", "Mail", "Reminders", "Notes"]

type
  OsaRunner* = proc(script: string, timeoutSec: int): tuple[ok: bool,
      text: string] {.closure.}
    ## One `osascript -e` run: `(true, stdout)` or `(false, explanation)`.
  AppleSeams* = object
    hostOs*: string
    run*: OsaRunner
    isRunning*: proc(app: string): bool {.closure.}
    launch*: proc(app: string) {.closure.}

proc appleGuard*(seams: AppleSeams): string =
  ## "" when tools may run, else the macOS-only sentence — the `_osa`
  ## platform guard, checked before any seam runs. `hostOs` speaks Nim
  ## (`hostOS`: `"macosx"`), like the integrations status check — not
  ## Python's `sys.platform` (`"darwin"`).
  if seams.hostOs == "macosx":
    return ""
  return "Apple tools are macOS-only."

proc ensureRunning*(seams: AppleSeams, app: string,
    timeoutSec = 12.0) =
  ## Cold-start `app` behind the user's windows (`open -gj -a`), because
  ## AppleScript cannot — then wait until `pgrep` sees it. No-op off
  ## Darwin or when it is already up. Mirrors `ensure_running`,
  ## including the swallowed launch failure (`_osa` reports the truth).
  if seams.hostOs != "macosx":
    return
  if seams.isRunning(app):
    return
  try:
    seams.launch(app)
  except CatchableError:
    return
  let deadline = getMonoTime() + initDuration(milliseconds = int(
    timeoutSec * 1000.0))
  while getMonoTime() < deadline:
    if seams.isRunning(app):
      return
    sleep(250)

proc osa*(seams: AppleSeams, script: string, timeoutSec = osaTimeoutSec,
    app = ""): tuple[ok: bool, text: string] =
  ## Port of `_osa`: the guard, the launch, then the script. Timeouts
  ## name the permission dialog, like Python.
  let denied = appleGuard(seams)
  if denied.len > 0:
    return (false, denied)
  if app.len > 0:
    ensureRunning(seams, app)
  try:
    return seams.run(script, timeoutSec)
  except CatchableError as exc:
    return (false, exc.msg)

const appleMonths = ["january", "february", "march", "april", "may",
  "june", "july", "august", "september", "october", "november",
  "december"]

proc parseAppleDate*(raw: string): tuple[ok: bool, stamp: string] =
  ## `'Thursday, July 30, 2026 at 1:00:00 PM'` → `(true, "2026-07-30
  ## 13:00")`. Naive wall-clock on purpose (AppleScript gives no
  ## offset, every comparison below is local too). `(false, "")` on
  ## anything else — one bad row must not lose the whole calendar.
  var text = raw.strip()
  let at = text.find(" at ")
  if at < 0:
    return (false, "")
  let dayPart = text[0 ..< at].strip()
  var timePart = text[at + 4 .. ^1].strip().replace("\u8239", " ")
  let comma = dayPart.rfind(',')
  if comma < 0:
    return (false, "")
  let year = dayPart[comma + 1 .. ^1].strip()
  # The weekday prefix is locale-dependent noise: the regex in Python
  # anchors on the LAST `Month day, year` group, so take the tail too.
  let monthDay = dayPart[0 ..< comma].strip().split(' ')
  if monthDay.len < 2:
    return (false, "")
  var month = 0
  for i, name in appleMonths:
    if name == monthDay[^2].toLowerAscii():
      month = i + 1
  if month == 0:
    return (false, "")
  var day = 0
  try:
    day = parseInt(monthDay[^1])
  except ValueError:
    return (false, "")
  let upper = timePart.toUpperAscii()
  var pm = false
  if upper.endsWith("PM"):
    pm = true
    timePart = timePart[0 ..< ^2].strip()
  elif upper.endsWith("AM"):
    timePart = timePart[0 ..< ^2].strip()
  else:
    return (false, "")
  let parts = timePart.split(':')
  if parts.len != 3:
    return (false, "")
  var hour, minute, second: int
  try:
    hour = parseInt(parts[0])
    minute = parseInt(parts[1])
    second = parseInt(parts[2])
  except ValueError:
    return (false, "")
  if hour < 1 or hour > 12 or minute > 59 or second > 60:
    return (false, "")
  if pm and hour != 12:
    hour += 12
  if not pm and hour == 12:
    hour = 0
  var yearNum = 0
  try:
    yearNum = parseInt(year)
  except ValueError:
    return (false, "")
  result = (true, $yearNum & "-" & (if month < 10: "0" else: "") &
    $month & "-" & (if day < 10: "0" else: "") & $day & " " &
    (if hour < 10: "0" else: "") & $hour & ":" &
    (if minute < 10: "0" else: "") & $minute)

proc readAppleCalendar*(seams: AppleSeams, calendars: string,
    daysAhead = 7, now = now()): string =
  ## Events between now and `daysAhead`, like `read_apple_calendar`.
  ## Without `WAKU_APPLE_CALENDARS` this refuses with the setup
  ## instructions: enumerating 30+ calendars takes minutes, and a wall
  ## of silence is worse than an instruction.
  var cals: seq[string] = @[]
  for c in calendars.split(','):
    if c.strip().len > 0:
      cals.add(c.strip())
  if cals.len == 0:
    return "Calendar not configured. Set WAKU_APPLE_CALENDARS to the " &
      "calendars you actually use (e.g. " &
      "WAKU_APPLE_CALENDARS=Work,Home) — a typical Mac has 30+ once " &
      "holiday and subscribed calendars pile up, and reading them all " &
      "takes minutes. Run `osascript -e 'tell application \"Calendar\" " &
      "to return name of every calendar'` to see the names."
  var blocks: seq[string] = @[]
  for c in cals:
    blocks.add("  try\n    tell calendar \"" & c & "\"\n" &
      "      set _su to summary of every event\n" &
      "      set _st to start date of every event\n" &
      "      repeat with i from 1 to (count of _su)\n" &
      "        set out to out & \"" & c &
      "\" & \"\\t\" & (item i of _su) & \"\\t\" & ((item i of _st) as " &
      "string) & linefeed\n" &
      "      end repeat\n    end tell\n  end try")
  let script = "set out to \"\"\ntell application \"Calendar\"\n" &
    blocks.join("\n") & "\nend tell\nreturn out"
  let (ok, res) = osa(seams, script, 20 + 12 * cals.len, "Calendar")
  if not ok:
    return "Calendar unavailable: " & res
  let lo = now
  let hi = now + initDuration(days = daysAhead)
  var rows: seq[(string, string)] = @[]
  for line in res.splitLines():
    let parts = line.split('\t')
    if parts.len != 3:
      continue
    let (parsed, stamp) = parseAppleDate(parts[2])
    if not parsed:
      continue
    if stamp[0 .. 9] >= format(lo, "yyyy-MM-dd") and
        stamp[0 .. 9] <= format(hi, "yyyy-MM-dd"):
      rows.add((stamp, parts[0] & " | " & parts[1] & " | " & stamp[0 .. 15]))
  rows.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  if rows.len == 0:
    return "No events in that window."
  var lines: seq[string] = @[]
  for (_, text) in rows:
    lines.add(text)
  return lines.join("\n")

proc readAppleMail*(seams: AppleSeams, hours = 48,
    limit = 20): string =
  ## Subject/sender/date plus a `message://` link per mail, verbatim.
  let script = "set out to \"\"\nset cutoff to (current date) - (" &
    $hours & " * hours)\ntell application \"Mail\"\n" &
    "  set box to inbox\n  set msgs to messages of box\n" &
    "  set n to 0\n  repeat with m in msgs\n" &
    "    if n ≥ " & $limit & " then exit repeat\n" &
    "    set out to out & (subject of m) & \" | \" & (sender of m) & " &
    "\" | \" & ((date received of m) as string) & \" | message://%3c\" " &
    "& (message id of m) & \"%3e\" & linefeed\n" &
    "    set n to n + 1\n  end repeat\nend tell\nreturn out"
  let (ok, res) = osa(seams, script, 20, "Mail")
  if ok:
    return res
  return "Mail unavailable: " & res & " Note: on this machine Mail.app " &
    "could not even count its own inbox within two minutes, which " &
    "usually means a very large mailbox or an in-progress sync. Apple " &
    "Mail reading is effectively unavailable until that settles."

proc createAppleReminder*(seams: AppleSeams, title: string;
    due = ""): string =
  ## One reminder in Apple Reminders, like `create_reminder`.
  var props = "name:\"" & title & "\""
  if due.len > 0:
    props &= ", due date:(date \"" & due & "\")"
  let (ok, res) = osa(seams,
    "tell application \"Reminders\" to make new reminder with properties {" &
    props & "}", osaSlowTimeoutSec, "Reminders")
  if ok:
    return "Reminder created: " & title
  return "Reminder failed: " & res

proc createAppleNote*(seams: AppleSeams, title: string;
    body = ""): string =
  ## One note in Apple Notes, like `create_note`.
  let safe = (title & "\n" & body).replace("\"", "'")
  let (ok, res) = osa(seams,
    "tell application \"Notes\" to make new note at folder \"Notes\" " &
    "with properties {body:\"" & safe & "\"}", osaSlowTimeoutSec, "Notes")
  if ok:
    return "Note created: " & title
  return "Note failed: " & res

proc liveOsaRun*(script: string, timeoutSec: int): tuple[ok: bool,
    text: string] =
  ## The live `osascript -e` run. Real subprocess — never in tests (they
  ## inject `OsaRunner` recordings).
  let res = runProcess(@["osascript", "-e", script],
    timeoutSec = timeoutSec)
  if res.timedOut:
    return (false, "timed out after " & $timeoutSec & "s. The app is " &
      "either slow (Reminders and large synced calendars routinely take " &
      "20s+) or waiting on a macOS permission dialog — check for one, " &
      "approve it, and ask again.")
  if res.code != 0:
    let err = res.stderr.strip()
    return (false, (if err.len > 0: err else: "failed")[0 ..< min(200,
      (if err.len > 0: err else: "failed").len)])
  return (true, res.stdout.strip())

proc liveAppleSeams*(): AppleSeams =
  ## The live seams: real `pgrep`/`open`/`osascript` on this machine.
  AppleSeams(hostOs: hostOS,
    run: proc(script: string, timeoutSec: int): tuple[ok: bool,
        text: string] {.closure.} = liveOsaRun(script, timeoutSec),
    isRunning: proc(app: string): bool {.closure.} =
      runProcess(@["pgrep", "-x", app], timeoutSec = 5).code == 0,
    launch: proc(app: string) {.closure.} =
      discard runProcess(@["open", "-gj", "-a", app], timeoutSec = 15))

proc makeAppleTools*(seams: AppleSeams): seq[Tool] =
  ## Registry wiring for the four Apple readers/writers. Reads carry
  ## their TTL caches (`cal:<days>`, `mail:<hours>:<limit>`) in the
  ## closure — one agent reuses them across turns, no process global.
  var calCache = initTable[string, tuple[at: float, text: string]]()
  var mailCache = initTable[string, tuple[at: float, text: string]]()
  result.add(Tool(name: "read_apple_calendar",
    description: "Read the user's real macOS Calendar for the next N " &
      "days (includes events invited by email). Use for weekly/daily " &
      "briefings and 'what's on my calendar'.",
    inputSchema: %*{"type": "object",
      "properties": {"days_ahead": {"type": "integer",
                                    "description": "default 7"}}},
    fn: proc(args: JsonNode): string =
      let days = intArg(args, "days_ahead", 7)
      let key = "cal:" & $days
      if calCache.hasKey(key) and
          epochTime() - calCache[key].at < 600.0:
        return calCache[key].text
      let text = readAppleCalendar(seams, getEnv("WAKU_APPLE_CALENDARS"),
        days)
      calCache[key] = (epochTime(), text)
      return text))
  result.add(Tool(name: "read_apple_mail",
    description: "Read the user's recent Apple Mail (subject, sender, " &
      "date, and a message:// link to open each). Use to brief the user " &
      "on what needs attention.",
    inputSchema: %*{"type": "object",
      "properties": {"hours": {"type": "integer",
                               "description": "look-back window, default 48"}}},
    fn: proc(args: JsonNode): string =
      let hours = intArg(args, "hours", 48)
      let limit = 20
      let key = "mail:" & $hours & ":" & $limit
      if mailCache.hasKey(key) and
          epochTime() - mailCache[key].at < 300.0:
        return mailCache[key].text
      let text = readAppleMail(seams, hours, limit)
      mailCache[key] = (epochTime(), text)
      return text))
  result.add(Tool(name: "create_reminder",
    description: "Create a reminder in Apple Reminders.",
    inputSchema: %*{"type": "object",
      "properties": {"title": {"type": "string"},
                     "due": {"type": "string",
                             "description": "optional, e.g. \"Monday 9:00 AM\""}},
      "required": ["title"]},
    fn: proc(args: JsonNode): string =
      createAppleReminder(seams, strArg(args, "title"),
        strArg(args, "due"))))
  result.add(Tool(name: "create_note",
    description: "Create a note in Apple Notes.",
    inputSchema: %*{"type": "object",
      "properties": {"title": {"type": "string"},
                     "body": {"type": "string"}},
      "required": ["title"]},
    fn: proc(args: JsonNode): string =
      createAppleNote(seams, strArg(args, "title"),
        strArg(args, "body"))))
