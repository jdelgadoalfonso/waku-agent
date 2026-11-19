## `browse_navigate` session store — one JSON file per session.
##
## Sessions live under `<home>/browse_sessions/<id>.json` (same `home`
## the registry already threads: `.waku` in production, a tmp dir in
## tests). Cookies are minimal name=value pairs keyed by `host|name` so
## one session can visit several hosts without leaking one host's cookie
## to another. Retention is explicit: `pruneBrowseSessions` drops files
## older than `maxAgeSec` and caps the survivors at `maxCount`.
##
## Fail-closed on ids: anything outside `[a-z0-9-]{1,64}` is refused
## before touching disk, so `../x` can never escape the sessions dir.

import std/json
import std/os
import std/algorithm
import std/strutils
import std/tables

import ./wire

const
  browseSessionDirName* = "browse_sessions"
  browseSessionMaxAgeSec*: int64 = 7 * 24 * 3600
  browseSessionMaxCount* = 20
  browseHistoryMax* = 50

type
  BrowseSession* = object
    id*: string
    createdUnix*: int64
    updatedUnix*: int64
    lastUrl*: string
    history*: seq[string]
    cookies*: Table[string, string]

proc validBrowseSessionId*(id: string): bool =
  ## `[a-z0-9-]{1,64}` — the only ids that ever reach disk.
  if id.len == 0 or id.len > 64:
    return false
  for c in id:
    if c notin {'a' .. 'z', '0' .. '9', '-'}:
      return false
  return true

proc sessionDir*(home: string): string =
  home / browseSessionDirName

proc sessionFile*(home, id: string): string =
  ## "" when the id is invalid, so callers fail without a path.
  if not validBrowseSessionId(id):
    return ""
  return sessionDir(home) / id & ".json"

proc newBrowseSession*(id: string, nowUnix: int64,
    url: string): BrowseSession =
  BrowseSession(id: id, createdUnix: nowUnix, updatedUnix: nowUnix,
    lastUrl: url, history: @[], cookies: initTable[string, string]())

proc saveBrowseSession*(home: string, s: BrowseSession): bool =
  if not validBrowseSessionId(s.id):
    return false
  try:
    createDir(sessionDir(home))
    var cookies = newJObject()
    for k, v in s.cookies:
      cookies[k] = %v
    let doc = %*{"id": s.id, "created": s.createdUnix,
      "updated": s.updatedUnix, "lastUrl": s.lastUrl,
      "history": s.history, "cookies": cookies}
    writeFile(sessionFile(home, s.id), pretty(doc, 1) & "\n")
    try:
      setFilePermissions(sessionFile(home, s.id),
        {fpUserRead, fpUserWrite})
    except OSError, IOError:
      discard
    return true
  except OSError, IOError:
    return false

proc loadBrowseSession*(home, id: string): tuple[ok: bool,
    sess: BrowseSession] =
  if not validBrowseSessionId(id):
    return (false, BrowseSession())
  let path = sessionFile(home, id)
  var doc: JsonNode
  try:
    if not fileExists(path):
      return (false, BrowseSession())
    doc = parseJson(readFile(path))
  except OSError, IOError, JsonParsingError:
    return (false, BrowseSession())
  if doc.kind != JObject:
    return (false, BrowseSession())
  var s = BrowseSession(id: id, createdUnix: 0, updatedUnix: 0,
    lastUrl: "", history: @[], cookies: initTable[string, string]())
  try:
    s.createdUnix = doc.jget("created").getBiggestInt(0)
    s.updatedUnix = doc.jget("updated").getBiggestInt(0)
    s.lastUrl = doc.jget("lastUrl").getStr("")
    let h = doc.jget("history")
    if h.kind == JArray:
      for e in h:
        if e.kind == JString:
          s.history.add(e.getStr())
    let c = doc.jget("cookies")
    if c.kind == JObject:
      for k, v in c:
        if v.kind == JString:
          s.cookies[k] = v.getStr()
  except CatchableError:
    return (false, BrowseSession())
  return (true, s)

proc parseSetCookiePair*(header: string): tuple[name, value: string] =
  ## The pair before the first `;` (`sid=abc` from
  ## `sid=abc; Path=/; HttpOnly`). ("","") when there is no usable pair.
  let semi = header.find(';')
  let pair = (if semi >= 0: header[0 ..< semi] else: header).strip()
  let eq = pair.find('=')
  if eq <= 0:
    return ("", "")
  let name = pair[0 ..< eq].strip()
  let value = pair[eq + 1 .. ^1].strip()
  if name.len == 0 or ' ' in name or ';' in name or '=' in name:
    return ("", "")
  return (name, value)

proc cookieHeaderFor*(s: BrowseSession, host: string): string =
  ## `Cookie:` value for one host (`n=v; n2=v2`, sorted, "" when none).
  let h = host.strip().toLowerAscii()
  var pairs: seq[string] = @[]
  for k, v in s.cookies:
    let bar = k.find('|')
    if bar < 0:
      continue
    if k[0 ..< bar] == h and v.len > 0:
      pairs.add(k[bar + 1 .. ^1] & "=" & v)
  pairs.sort()
  return pairs.join("; ")

proc applySetCookies*(s: var BrowseSession, host: string,
    setCookies: seq[string]) =
  ## Fold `Set-Cookie` header values into the jar for `host`.
  ## Empty values and `Max-Age=0` delete instead of storing.
  let h = host.strip().toLowerAscii()
  if h.len == 0:
    return
  for header in setCookies:
    let (name, value) = parseSetCookiePair(header)
    if name.len == 0:
      continue
    let key = h & "|" & name
    let low = header.toLowerAscii()
    if value.len == 0 or "max-age=0" in low:
      s.cookies.del(key)
    else:
      s.cookies[key] = value

proc recordBrowseVisit*(s: var BrowseSession, url: string, nowUnix: int64) =
  s.lastUrl = url
  s.updatedUnix = nowUnix
  s.history.add(url)
  if s.history.len > browseHistoryMax:
    s.history = s.history[^browseHistoryMax .. ^1]

proc pruneBrowseSessions*(home: string, nowUnix: int64,
    maxAgeSec: int64 = browseSessionMaxAgeSec,
    maxCount: int = browseSessionMaxCount): int =
  ## Drop sessions older than `maxAgeSec` (by `updated`), then cap at
  ## `maxCount` oldest-first. Returns files removed. Missing dir is 0.
  let dir = sessionDir(home)
  if not dirExists(dir):
    return 0
  var entries: seq[(string, int64)] = @[]
  var invalid: seq[string] = @[]
  for kind, path in walkDir(dir):
    if kind != pcFile or not path.endsWith(".json"):
      continue
    var doc: JsonNode
    try:
      doc = parseJson(readFile(path))
    except OSError, IOError, JsonParsingError:
      invalid.add(path)
      continue
    if doc.kind != JObject:
      invalid.add(path)
      continue
    entries.add((path, doc.jget("updated").getBiggestInt(0)))
  for path in invalid:
    try:
      removeFile(path)
      inc result
    except OSError:
      discard
  entries.sort(proc(a, b: (string, int64)): int = cmp(a[1], b[1]))
  var alive: seq[(string, int64)] = @[]
  for (path, updated) in entries:
    if nowUnix - updated > maxAgeSec:
      try:
        removeFile(path)
        inc result
      except OSError:
        alive.add((path, updated))
    else:
      alive.add((path, updated))
  while alive.len > maxCount:
    let (path, _) = alive[0]
    alive.delete(0)
    try:
      removeFile(path)
      inc result
    except OSError:
      discard
