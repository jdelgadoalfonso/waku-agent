## Google OAuth plumbing — the half Gmail and Google Calendar share.
##
## They are separate capabilities with separate token files on purpose
## (`gmail-token.json` and `google-token.json`): revoking one leaves the other
## working. What is NOT separate is the machinery around them, and it was wrong
## to let Gmail own it while the calendar had none:
##
##   * read a cached token, refresh it if stale, write it back
##   * carry Google's own `error.message` back as a sentence
##   * one live HTTPS seam, so tests stay offline and the socket stays in the
##     binary
##
## Python keeps this in each module, which worked only because a Python module
## can do anything. The port borrows the shape of `gmail.nim`'s plumbing and
## gives it a name both capabilities import.
##
## Nothing here raises on the model's behalf, and no call opens a browser: a
## chat turn cannot block on a consent screen the user cannot see.

import std/httpclient
import std/json
import std/os
import std/strutils
import std/times
import std/uri

import ./http
import ./wire

type
  GoogleHttpFn* = proc(url, meth, body, bearer: string): tuple[status: int,
      text: string] {.closure.}
    ## One HTTP round trip. `meth` is `"GET"` (empty body) or `"POST"`.
    ## Status 0 means the transport failed, like Python's `urlopen` raising
    ## before an answer existed. `bearer` is empty when the call carries no
    ## credential (the token refresh).
  GoogleClockFn* = proc(): int64 {.closure.}
    ## Injected "now", so a staleness or "today" decision is a pin and not a
    ## race against the wall clock.

const
  googleTokenUri* = "https://oauth2.googleapis.com/token"
  googleMaxErrorChars* = 420
    ## How much of Google's answer one failed call may put in a prompt. It is
    ## generous on purpose: the sentence that FIXES the call lives in there
    ## ("Gmail API has not been used in project N before or it is disabled.
    ## Enable it by visiting <console url> then retry"), and a tighter cut
    ## leaves the model able to say only that it failed.

proc parseObject*(text: string): JsonNode =
  ## `parseJson` without the raise: a body we cannot read is a failed call,
  ## not a crashed turn.
  try:
    let doc = parseJson(text)
    if doc.kind == JObject:
      return doc
  except CatchableError:
    discard
  return nil

proc errorText*(status: int, text: string): string =
  ## The status plus what the answer said. Google's own `error.message` wins
  ## over the raw body, because that field is where the instruction that fixes
  ## the call lives; the raw JSON only adds braces around it. A failed
  ## transport (status 0) carries its own sentence and gets the same treatment.
  let detail = block:
    let doc = parseObject(text)
    let message = if doc == nil: "" else: doc.jget("error").jget("message").getStr()
    if message.len > 0: message else: text.strip()
  let collapsed = strutils.splitWhitespace(detail).join(" ")
  let shown =
    if collapsed.len > googleMaxErrorChars: collapsed[0 ..< googleMaxErrorChars]
    else: collapsed
  "HTTP " & $status & (if shown.len > 0: ": " & shown else: "")

proc loadToken*(path: string): JsonNode =
  ## The cached record, or nil when absent or unreadable. A torn or
  ## hand-edited file reads as "not connected", not as a crash mid-turn.
  if not fileExists(path):
    return nil
  try:
    let doc = parseJson(readFile(path))
    if doc.kind == JObject:
      return doc
  except CatchableError:
    discard
  return nil

proc expirySeconds*(node: JsonNode): int64 =
  ## When the access token dies, in unix seconds; 0 means "unknown", which
  ## is not an error (Python's `Credentials` treats a missing expiry as
  ## valid).
  ##
  ## Two shapes exist in the wild and both must work, because Python and the
  ## port share one `.waku/`: this port's `connect.nim` writes an integer
  ## epoch, and Python's `google-auth` writes `"2026-10-19T22:00:00.123456Z"`.
  case node.kind
  of JInt:
    node.getBiggestInt()
  of JFloat:
    int64(node.getFloat())
  of JString:
    let raw = node.getStr()
    if raw.len < 19:
      return 0
    try:
      return parse(raw[0 ..< 19], "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime.
        toUnix
    except CatchableError:
      return 0
  else:
    0

proc tokenStale*(token: JsonNode, nowUnix: int64): bool =
  ## Expired, by our clock. An unknown expiry is never stale.
  let exp = expirySeconds(token.jget("expiry"))
  exp > 0 and exp <= nowUnix

proc refreshBody*(token: JsonNode): string =
  ## The `application/x-www-form-urlencoded` body Google's token endpoint
  ## wants for a refresh (no redirect, no code).
  "client_id=" & encodeUrl(token.jget("client_id").getStr()) &
    "&client_secret=" & encodeUrl(token.jget("client_secret").getStr()) &
    "&refresh_token=" & encodeUrl(token.jget("refresh_token").getStr()) &
    "&grant_type=refresh_token"

proc refreshToken*(fetch: GoogleHttpFn, tokenPath: string, token: JsonNode,
    nowUnix: int64): JsonNode =
  ## Swap the stored `refresh_token` for a fresh access token and persist the
  ## answer; nil means "treat as not connected", exactly like Python's reader
  ## returning None when the refresh fails.
  if fetch == nil:
    return nil
  let refreshTokenValue = token.jget("refresh_token").getStr()
  if refreshTokenValue.len == 0:
    return nil
  let endpoint = block:
    let u = token.jget("token_uri").getStr()
    if u.len > 0: u else: googleTokenUri
  let (status, text) = fetch(endpoint, "POST", refreshBody(token), "")
  if status < 200 or status >= 300:
    return nil
  let answer = parseObject(text)
  if answer == nil:
    return nil
  let access = answer.jget("access_token").getStr()
  if access.len == 0:
    return nil
  # The cached shape stays the one a later reader understands: where the
  # token came from and when it dies, so nobody reopens a browser to find
  # out. A refresh answer that omits `refresh_token` keeps the old one:
  # Google rotates access tokens far more eagerly than refresh tokens.
  var record = newJObject()
  for key in ["token_uri", "client_id", "client_secret", "scopes"]:
    if token.hasKey(key):
      record[key] = token[key]
  record["token"] = %access
  let rotated = answer.jget("refresh_token").getStr()
  record["refresh_token"] = %(if rotated.len > 0: rotated else: refreshTokenValue)
  var expiresIn: int64 = 3600
  let ei = answer.jget("expires_in")
  if ei.kind == JInt:
    expiresIn = ei.getBiggestInt()
  elif ei.kind == JFloat:
    expiresIn = int64(ei.getFloat())
  record["expiry"] = %(nowUnix + expiresIn)
  try:
    writeFile(tokenPath, $record)
  except IOError:
    return nil
  return record

proc accessToken*(fetch: GoogleHttpFn, tokenPath: string,
    nowUnix: int64): string =
  ## The bearer for one call, or "" when the user never signed in (or the
  ## refresh was refused). Cached token → refresh if stale → nil, the order
  ## `_load_credentials` uses.
  let token = loadToken(tokenPath)
  if token == nil:
    return ""
  var current = token
  if tokenStale(token, nowUnix):
    # Both halves or neither: an expired token we cannot refresh is a token
    # the user must replace, and spending the call to get its 401 would only
    # report a failure where `waku connect google` is the real answer.
    if token.jget("refresh_token").getStr().len == 0:
      return ""
    let refreshed = refreshToken(fetch, tokenPath, token, nowUnix)
    if refreshed == nil:
      return ""
    current = refreshed
  return current.jget("token").getStr()

proc wantsFormBody*(url: string): bool =
  ## Whether one call must be `application/x-www-form-urlencoded` instead of
  ## JSON. The token endpoint is the only Google call in this module that is
  ## not JSON: it takes `client_id=...&grant_type=refresh_token`. Sending that
  ## body as `application/json` is refused with "Invalid JSON payload
  ## received. Unexpected token. client_id=...", which is how EVERY refresh in
  ## this port failed — an expired token answered "not connected" while a
  ## perfectly good refresh_token sat on disk, and the user was told to sign in
  ## again for nothing.
  url.endsWith("/token")

proc liveGoogleFetch*(url, meth, body, bearer: string): tuple[status: int,
    text: string] =
  ## The live round trip over `http.nim`'s one TLS helper: `https://` gets
  ## the TLS context in a `-d:wakuTls` build and is refused before any byte
  ## goes out in the default one. Real socket — never in tests.
  var client = newTlsHttpClient(timeout = 20 * 1000)
  # The encoding follows the endpoint (`wantsFormBody`), not this function's
  # habit: one header for every call was the bug that broke the refresh.
  var headers = @[("Content-Type",
    if wantsFormBody(url): "application/x-www-form-urlencoded"
    else: "application/json")]
  if bearer.len > 0:
    headers.add(("Authorization", "Bearer " & bearer))
  client.headers = newHttpHeaders(headers)
  try:
    let resp = if meth == "POST":
      client.request(url, HttpPost, body)
    else:
      client.request(url, HttpGet)
    return (resp.code.int, resp.body)
  except CatchableError as exc:
    return (0, exc.msg)

proc googleToday*(nowUnix: int64): string =
  ## The user's own today, not UTC's: Python's `date.today()`.
  local(fromUnix(nowUnix)).format("yyyy-MM-dd")

proc rfc3339*(day: string, offsetSeconds: int): string =
  ## `2026-10-28` at local midnight as RFC3339 with an offset, which is what
  ## Google's `timeMin`/`timeMax` want: `2026-10-28T00:00:00+01:00`. Python
  ## builds the same string with `datetime.isoformat()`.
  let dt = parse(day & "T00:00:00", "yyyy-MM-dd'T'HH:mm:ss")
  let sign = if offsetSeconds < 0: "-" else: "+"
  let minutes = abs(offsetSeconds) div 60
  let two = proc(n: int): string = (if n < 10: "0" else: "") & $n
  format(dt, "yyyy-MM-dd'T'HH:mm:ss") & sign & two(minutes div 60) & ":" &
    two(minutes mod 60)
