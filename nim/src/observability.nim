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
import std/os
import std/strutils
import std/times

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
