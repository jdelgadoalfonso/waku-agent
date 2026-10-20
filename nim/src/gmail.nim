## Gmail, read side — search and read real mail with a sign-in the user can
## revoke.
##
## Port of the read half of `waku/tools/gmail.py`. Two things carry over
## unchanged, because they are the point rather than the plumbing:
##
##   * the token lives in its own `.waku/gmail-token.json`, never the
##     calendar's file, so revoking mail leaves the calendar alone;
##   * a machine that was never asked for Gmail makes NO network call. A
##     missing token returns the sentence that fixes it — an agent that says
##     "no messages" because it never got in is worse than one that says
##     nothing.
##
## Everything here is best-effort: a refused consent, an expired token and a
## quota error all come back as text the model can report. A mailbox hiccup
## must not take down a chat turn, so nothing below raises on the model's
## behalf — and no call opens a browser, because a chat turn cannot block on a
## consent screen the user cannot see.
##
## Python reaches Gmail through `googleapiclient`; the port speaks the same
## REST endpoints through one injected seam (`GmailHttpFn`), which is what
## keeps the tests offline and the real socket in the binary.

import std/base64
import std/httpclient
import std/json
import std/os
import std/strutils
import std/times
import std/uri

import ./http
import ./tools
import ./wire

const
  gmailApiBase* = "https://gmail.googleapis.com/gmail/v1/users/me"
  gmailTokenUri* = "https://oauth2.googleapis.com/token"
  gmailDefaultLimit* = 10
  gmailMaxLimit* = 25
    ## Both numbers exist because the model can pass any `limit` it likes:
    ## one caps what we ask Gmail for, the other what a single reply may
    ## dump into a prompt.
  gmailMaxBodyChars* = 8000
    ## One email must not be able to eat the turn's context; the cut is
    ## announced so the model can say the message was longer instead of
    ## summarising half of it.
  gmailSetupHint* = "Gmail is not connected yet. Type `/connect google` in " &
    "the dashboard chat, or run `waku connect google` in a terminal — either " &
    "opens your browser to sign in."

type
  GmailHttpFn* = proc(url, meth, body, bearer: string): tuple[status: int,
      text: string] {.closure.}
    ## One HTTP round trip. `meth` is `"GET"` (empty body) or `"POST"`.
    ## Status 0 means the transport failed, like Python's `urlopen` raising
    ## before an answer existed. `bearer` is empty when the call carries no
    ## credential (the token refresh).
  GmailClockFn* = proc(): int64 {.closure.}
    ## Injected "now", so the refresh decision is a pin and not a race.

proc gmailTokenPath*(home: string): string =
  ## Gmail's own file — never `google-token.json` (the calendar's).
  home / "gmail-token.json"

proc loadGmailToken*(home: string): JsonNode =
  ## The cached record, or nil when absent or unreadable. A torn or
  ## hand-edited file reads as "not connected", not as a crash mid-turn.
  let path = gmailTokenPath(home)
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

proc errorText(status: int, text: string): string =
  ## Python reports `{ExceptionName}: {first 120 chars}`; the port has no
  ## exception to name, so it reports the status it got instead — the same
  ## information in the one form both can produce.
  let detail = text.strip()
  let shown = if detail.len > 120: detail[0 ..< 120] else: detail
  "HTTP " & $status & (if shown.len > 0: ": " & shown else: "")

proc parseObject(text: string): JsonNode =
  ## `parseJson` without the raise: a body we cannot read is a failed call,
  ## not a crashed turn.
  try:
    let doc = parseJson(text)
    if doc.kind == JObject:
      return doc
  except CatchableError:
    discard
  return nil

proc refreshGmailToken*(fetch: GmailHttpFn, home: string, token: JsonNode,
    nowUnix: int64): JsonNode =
  ## Swap the stored `refresh_token` for a fresh access token and persist the
  ## answer; nil means "treat as not connected", exactly like Python's reader
  ## returning None when the refresh fails.
  if fetch == nil:
    return nil
  let refreshToken = token.jget("refresh_token").getStr()
  if refreshToken.len == 0:
    return nil
  let endpoint = block:
    let u = token.jget("token_uri").getStr()
    if u.len > 0: u else: gmailTokenUri
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
  record["refresh_token"] = %(if rotated.len > 0: rotated else: refreshToken)
  var expiresIn: int64 = 3600
  let ei = answer.jget("expires_in")
  if ei.kind == JInt:
    expiresIn = ei.getBiggestInt()
  elif ei.kind == JFloat:
    expiresIn = int64(ei.getFloat())
  record["expiry"] = %(nowUnix + expiresIn)
  try:
    writeFile(gmailTokenPath(home), $record)
  except IOError:
    return nil
  return record

proc gmailAccessToken*(fetch: GmailHttpFn, home: string,
    nowUnix: int64): string =
  ## The bearer for one call, or "" when the user never signed in (or the
  ## refresh was refused). Cached token → refresh if stale → nil, the order
  ## `_load_credentials` uses.
  let token = loadGmailToken(home)
  if token == nil:
    return ""
  var current = token
  if tokenStale(token, nowUnix) and token.jget("refresh_token").getStr().
      len > 0:
    let refreshed = refreshGmailToken(fetch, home, token, nowUnix)
    if refreshed == nil:
      return ""
    current = refreshed
  return current.jget("token").getStr()

proc searchCap*(limit: int): int =
  ## Python's `max(1, min(int(limit or DEFAULT), MAX))`: an explicit 0 means
  ## "use the default", a negative one still asks for one hit.
  if limit == 0:
    return gmailDefaultLimit
  if limit < 0:
    return 1
  if limit > gmailMaxLimit:
    return gmailMaxLimit
  limit

proc searchUrl*(query: string, cap: int): string =
  ## `messages.list`: the cap and the user's own Gmail query syntax.
  gmailApiBase & "/messages?maxResults=" & $cap &
    (if query.len > 0: "&q=" & encodeUrl(query) else: "")

proc metadataUrl*(messageId: string): string =
  ## Metadata only: the list call gives ids, and the model needs enough to
  ## choose one without pulling every full body into the prompt.
  gmailApiBase & "/messages/" & encodeUrl(messageId) &
    "?format=metadata&metadataHeaders=From&metadataHeaders=Subject" &
    "&metadataHeaders=Date"

proc fullUrl*(messageId: string): string =
  ## `format=full` carries the payload the body lives in.
  gmailApiBase & "/messages/" & encodeUrl(messageId) & "?format=full"

proc children*(node: JsonNode): seq[JsonNode] =
  ## The elements of an array field, or nothing when it is missing. Nim's
  ## `items` asserts on `JNull`, and Gmail omits `headers`/`parts` on the
  ## messages that have none — a real shape, not a corrupt one.
  if node.kind != JArray:
    return @[]
  for child in node:
    result.add(child)

proc headerValue*(payload: JsonNode, name: string): string =
  ## Case-insensitive header lookup, like `_header` (Gmail answers `From`
  ## with the decoded display name, never a raw RFC 822 header).
  for field in children(payload.jget("headers")):
    if cmpIgnoreCase(field.jget("name").getStr(), name) == 0:
      return field.jget("value").getStr()
  return ""

proc decodeBase64Url*(data: string): string =
  ## Gmail hands body data back as base64url WITHOUT padding, so pad it and
  ## translate to the standard alphabet before `std/base64` looks at it.
  var s = data.replace('-', '+').replace('_', '/')
  s.add(repeat('=', (4 - s.len mod 4) mod 4))
  try:
    return decode(s)
  except CatchableError:
    return ""

proc bodyText*(payload: JsonNode): string =
  ## The first text/plain part, depth-first. Gmail nests parts
  ## (multipart/alternative inside multipart/mixed), so a top-level read
  ## finds nothing on a real message.
  if payload.jget("mimeType").getStr() == "text/plain":
    let data = payload.jget("body").jget("data").getStr()
    if data.len > 0:
      return decodeBase64Url(data)
  for part in children(payload.jget("parts")):
    let text = bodyText(part)
    if text.len > 0:
      return text
  return ""

proc gmailSearch*(fetch: GmailHttpFn, home: string, nowUnix: int64,
    query: string, limit: int): string =
  ## Port of `_search`: one list call, then one metadata call per hit.
  let cap = searchCap(limit)
  let bearer = gmailAccessToken(fetch, home, nowUnix)
  if bearer.len == 0:
    return gmailSetupHint
  let (status, text) = fetch(searchUrl(query, cap), "GET", "", bearer)
  if status < 200 or status >= 300:
    return "Gmail search unavailable (" & errorText(status, text) & ")"
  let doc = parseObject(text)
  if doc == nil:
    return "Gmail search unavailable (" & errorText(status, text) & ")"
  let hits = doc.jget("messages")
  if hits.kind != JArray or hits.len == 0:
    return if query.len > 0: "No Gmail messages matched '" & query & "'."
           else: "No Gmail messages found."
  var lines: seq[string] = @[]
  for hit in hits:
    if lines.len >= cap:
      break
    let mid = hit.jget("id").getStr()
    let (mstatus, mtext) = fetch(metadataUrl(mid), "GET", "", bearer)
    if mstatus < 200 or mstatus >= 300:
      return "Gmail search unavailable (" & errorText(mstatus, mtext) & ")"
    let payload = parseObject(mtext).jget("payload")
    lines.add(mid & " | " & headerValue(payload, "From") & " | " &
      headerValue(payload, "Subject") & " | " & headerValue(payload, "Date"))
  return lines.join("\n")

proc gmailRead*(fetch: GmailHttpFn, home: string, nowUnix: int64,
    messageId: string): string =
  ## Port of `_read`: headers, a blank line, then the body — cut and
  ## announced when it is long.
  if messageId.len == 0:
    return "gmail_read needs a message_id — call gmail_search first to get one."
  let bearer = gmailAccessToken(fetch, home, nowUnix)
  if bearer.len == 0:
    return gmailSetupHint
  let (status, text) = fetch(fullUrl(messageId), "GET", "", bearer)
  if status < 200 or status >= 300:
    return "Gmail could not open " & messageId & " (" &
      errorText(status, text) & ")"
  let doc = parseObject(text)
  if doc == nil:
    return "Gmail could not open " & messageId & " (" &
      errorText(status, text) & ")"
  let payload = doc.jget("payload")
  var body = bodyText(payload)
  if body.len == 0:
    body = doc.jget("snippet").getStr()
  if body.len > gmailMaxBodyChars:
    body = body[0 ..< gmailMaxBodyChars] &
      "\n[... truncated at " & $gmailMaxBodyChars & " characters]"
  return "From: " & headerValue(payload, "From") & "\n" &
    "Date: " & headerValue(payload, "Date") & "\n" &
    "Subject: " & headerValue(payload, "Subject") & "\n\n" & body

proc safeRecipient*(to: string): string =
  ## The outbox filename carries the recipient, so a draft is findable by
  ## opening the folder. Anything that is not a letter or digit becomes a
  ## dash: an address is user data, never a path.
  for c in to:
    if result.len >= 40:
      break
    result.add(if c.isAlphaNumeric: c else: '-')

proc draftStamp*(nowUnix: int64): string =
  ## `%Y%m%dT%H%M%S` in UTC, Python's draft timestamp.
  format(fromUnix(nowUnix).utc, "yyyyMMdd'T'HHmmss")

proc draftPath*(home: string, to: string, nowUnix: int64): string =
  ## A second draft to the same person must never overwrite the first: the
  ## outbox holds the user's own words, not a cache we may drop.
  result = home / "outbox" / (draftStamp(nowUnix) & "-" & safeRecipient(to) &
    ".txt")
  var n = 1
  while fileExists(result):
    inc n
    result = home / "outbox" / (draftStamp(nowUnix) & "-" &
      safeRecipient(to) & "-" & $n & ".txt")

proc draftText*(to, subject, body, threadId, inReplyTo: string): string =
  ## Headers a person can read and edit, then send themselves.
  var headers = @["To: " & to, "Subject: " & subject]
  if threadId.len > 0:
    headers.add("X-Waku-Thread: " & threadId)
  if inReplyTo.len > 0:
    headers.add("In-Reply-To: " & inReplyTo)
  headers.join("\n") & "\n\n" & body & "\n"

proc writeDraft*(home: string, nowUnix: int64, to, subject, body, threadId,
    inReplyTo: string): string =
  ## Deliberately needs no token: nothing leaves the machine, so asking for
  ## credentials here would only hide the draft behind a sign-in.
  let path = draftPath(home, to, nowUnix)
  try:
    createDir(home / "outbox")
    writeFile(path, draftText(to, subject, body, threadId, inReplyTo))
  except IOError as exc:
    return "Gmail could not write the draft (" & exc.msg & ")."
  return "Draft to " & to & " placed in outbox (" & path.extractFilename() &
    "). Nothing was sent — review it there."

proc rawMessage*(to, subject, body, inReplyTo: string): string =
  ## RFC 822 as Gmail's API wants it: base64url, no line wrapping of our own.
  ## Only text/plain — an HTML body this tool never wrote would be a guess.
  var headers = @["To: " & to, "Subject: " & subject, "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=\"utf-8\""]
  if inReplyTo.len > 0:
    headers.add("In-Reply-To: " & inReplyTo)
  let message = headers.join("\n") & "\n\n" & body
  message.encode().replace('+', '-').replace('/', '_')

proc gmailSend*(fetch: GmailHttpFn, home: string, nowUnix: int64, send: bool,
    to, subject, body, threadId, inReplyTo: string): string =
  ## Port of `gmail_send`. Drafting first is not a fallback, it is the
  ## default: the switch has to be turned on deliberately before this repo
  ## can send mail in the user's name.
  if to.len == 0:
    return "gmail_send needs a recipient address — call it again with one."
  if not send:
    return writeDraft(home, nowUnix, to, subject, body, threadId, inReplyTo)
  let bearer = gmailAccessToken(fetch, home, nowUnix)
  if bearer.len == 0:
    return gmailSetupHint
  var payload = %*{"raw": rawMessage(to, subject, body, inReplyTo)}
  if threadId.len > 0:
    payload["threadId"] = %threadId
  let (status, text) = fetch(gmailApiBase & "/messages/send", "POST",
    $payload, bearer)
  if status < 200 or status >= 300:
    return "Gmail could not send to " & to & " (" & errorText(status, text) &
      ")"
  let doc = parseObject(text)
  let mid = block:
    let id = if doc == nil: "" else: doc.jget("id").getStr()
    if id.len > 0: id else: "?"
  return "Sent to " & to & " (message " & mid & ")."

proc liveGmailNow*(): int64 =
  ## The real clock, for the binary.
  getTime().toUnix

proc liveGmailFetch*(url, meth, body, bearer: string): tuple[status: int,
    text: string] =
  ## The live round trip over `http.nim`'s one TLS helper: `https://` gets
  ## the TLS context in a `-d:wakuTls` build and is refused before any byte
  ## goes out in the default one. Real socket — never in tests.
  var client = newTlsHttpClient(timeout = 20 * 1000)
  var headers = @[("Content-Type", "application/json")]
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

proc makeGmailTools*(home: string, fetch: GmailHttpFn, send = false,
    now: GmailClockFn = liveGmailNow): seq[Tool] =
  ## Registry wiring for the Gmail tools. `send` is the second switch
  ## (`WAKU_GMAIL_SEND`): with it off, sending means drafting locally and
  ## `gmail_send` is not registered at all, so an untouched machine carries
  ## no tool that could put mail in someone's name.
  result = @[Tool(name: "gmail_search",
      description: "Search the user's Gmail and list the matching " &
        "messages as id | from | subject | date, newest first. Use Gmail's " &
        "own query syntax (from:, subject:, newer_than:7d). Call gmail_read " &
        "with an id to open one.",
      inputSchema: %*{"type": "object",
        "properties": {
          "query": {"type": "string",
            "description": "Gmail search query, e.g. 'from:ana newer_than:7d'"},
          "limit": {"type": "integer",
            "description": "How many hits to list (default 10, max 25)"}},
        "required": ["query"]},
      fn: proc(args: JsonNode): string =
        gmailSearch(fetch, home, now(), strArg(args, "query"),
          intArg(args, "limit", gmailDefaultLimit))),
    Tool(name: "gmail_read",
      description: "Open one Gmail message by id and return its sender, " &
        "date, subject and body. Use after gmail_search when the user asks " &
        "what a message says.",
      inputSchema: %*{"type": "object",
        "properties": {
          "message_id": {"type": "string",
            "description": "The id from gmail_search"}},
        "required": ["message_id"]},
      fn: proc(args: JsonNode): string =
        gmailRead(fetch, home, now(), strArg(args, "message_id")))]
  if send:
    result.add(Tool(name: "gmail_send",
      description: "Write an email in the user's name. By default it is " &
        "placed in the local outbox as a draft and NOTHING IS SENT — say so " &
        "plainly and let the user review and send it. Only when " &
        "WAKU_GMAIL_SEND is on does it deliver, and then it returns the sent " &
        "message id. Pass thread_id and in_reply_to to answer an existing " &
        "thread instead of starting one.",
      inputSchema: %*{"type": "object",
        "properties": {
          "to": {"type": "string", "description": "Recipient address"},
          "subject": {"type": "string", "description": "Subject line"},
          "body": {"type": "string", "description": "Plain-text body"},
          "thread_id": {"type": "string",
            "description": "Optional: the thread to answer (from gmail_read)"},
          "in_reply_to": {"type": "string",
            "description": "Optional: the Message-ID being answered"}},
        "required": ["to", "body"]},
      fn: proc(args: JsonNode): string =
        gmailSend(fetch, home, now(), send, strArg(args, "to"),
          strArg(args, "subject"), strArg(args, "body"),
          strArg(args, "thread_id"), strArg(args, "in_reply_to"))))
