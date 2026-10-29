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
import std/json
import std/os
import std/strutils
import std/times
import std/unicode
import std/uri

import ./google_auth
import ./tools
import ./wire

const
  gmailApiBase* = "https://gmail.googleapis.com/gmail/v1/users/me"
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
  GmailHttpFn* = GoogleHttpFn
    ## The same one round trip Google Calendar uses (`google_auth`). Kept as
    ## its own name because this module's callers and tests read better with
    ## it, and the alias keeps every existing signature compiling.
  GmailClockFn* = GoogleClockFn
    ## The shared clock, under the name this module's callers already use.

proc liveGmailFetch*(url, meth, body, bearer: string): tuple[status: int,
    text: string] =
  ## The live socket, named for Gmail's callers. One implementation lives in
  ## `google_auth`, because a second TLS helper would be a second place to get
  ## certificate verification wrong.
  liveGoogleFetch(url, meth, body, bearer)

proc gmailTokenPath*(home: string): string =
  ## Gmail's own file — never `google-token.json` (the calendar's).
  home / "gmail-token.json"

proc gmailAccessToken*(fetch: GoogleHttpFn, home: string,
    nowUnix: int64): string =
  ## Gmail's own token file, read through the shared loader: cached → refresh
  ## if stale → "" (not connected), never a browser and never a raise.
  accessToken(fetch, gmailTokenPath(home), nowUnix)

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
  ## dash: an address is user data, never a path. Rune-wise, like Python's
  ## `str.isalnum`, so a name like `josé@example.com` survives as a name —
  ## `std/unicode` has no digit predicate, so digits are checked by code
  ## point (ASCII `0`-`9`), which is what an address uses them for anyway.
  var kept = 0
  for rune in to.runes:
    if kept >= 40:
      break
    inc kept
    result.add(if rune.isAlpha or rune.ord in 0x30 .. 0x39: $rune else: "-")

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
  except IOError, OSError:
    # Both classes, deliberately: `createDir` raises `IOError` when
    # something (a file) is in the way and the broader `OSError` when the
    # system refuses (a read-only home). An outbox we cannot write is
    # exactly the case where the user must still read "nothing was sent".
    return "Gmail could not write the draft (" & getCurrentExceptionMsg() &
      ")."
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

proc makeGmailTools*(home: string, fetch: GmailHttpFn, send = false,
    now: GmailClockFn = liveGmailNow): seq[Tool] =
  ## Registry wiring for the Gmail tools. All three register together, like
  ## Python: with `send` off — `WAKU_GMAIL_SEND` unset — `gmail_send` is what
  ## writes a draft, so a tool the model cannot see would make "draft an
  ## email" impossible. Only the switch decides whether a call leaves the
  ## machine.
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
