## `gmail_search` / `gmail_read` tests: the token file, the refresh, the
## wire shapes and the sentence for every failure. Offline only: the one
## HTTP seam is a recorder, so no socket exists.

from std/base64 import decode, encode
import std/json
import std/os
import std/strutils
import std/unittest

import ../src/gmail

type
  Answer = proc(url: string): tuple[status: int, text: string] {.closure.}
  Recorder = ref object
    calls: seq[tuple[url, meth, body, bearer: string]]
    answer: Answer

proc newRecorder(answer: Answer): Recorder =
  Recorder(calls: @[], answer: answer)

proc fetchOf(rec: Recorder): GmailHttpFn =
  ## Every round trip lands in `rec.calls`; `answer` decides the reply.
  result = proc(url, meth, body, bearer: string): tuple[status: int,
      text: string] {.closure.} =
    rec.calls.add((url, meth, body, bearer))
    rec.answer(url)

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc tokenFile(home: string, unixExpiry: int64) =
  ## The shape `connect.nim` writes: an integer epoch.
  let record = %*{"token": "access-1", "refresh_token": "refresh-1",
    "token_uri": "https://oauth2.googleapis.com/token",
    "client_id": "cid", "client_secret": "secret",
    "scopes": ["https://www.googleapis.com/auth/gmail.readonly"],
    "expiry": unixExpiry}
  writeFile(home / "gmail-token.json", $record)

proc metadata(mid, sender, subject, date: string): string =
  $ %*{"id": mid,
    "payload": {"headers": @[%*{"name": "From", "value": sender},
      %*{"name": "Subject", "value": subject},
      %*{"name": "Date", "value": date}]}}

proc urlSafe(text: string): string =
  ## Gmail's body data: base64url WITHOUT the trailing padding.
  encode(text).replace("+", "-").replace("/", "_").replace("=", "")

proc message(mid, body: string): string =
  $ %*{"id": mid, "snippet": "a snippet",
    "payload": {"mimeType": "text/plain",
      "body": {"data": urlSafe(body)}}}

suite "gmail read: the token gate":
  test "no token file answers the sign-in sentence, without a network call":
    let home = freshHome("waku-gmail-notoken")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    let text = gmailSearch(rec.fetchOf(), home, 1_700_000_000, "from:ana", 10)
    assert text == gmailSetupHint
    assert rec.calls.len == 0
    removeDir(home)

  test "an unreadable token file is not connected either":
    let home = freshHome("waku-gmail-badtoken")
    writeFile(home / "gmail-token.json", "{not json")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    assert gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 10) ==
      gmailSetupHint
    assert rec.calls.len == 0
    removeDir(home)

  test "a token with no access token is not connected":
    let home = freshHome("waku-gmail-empty")
    writeFile(home / "gmail-token.json", """{"refresh_token": "r"}""")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    assert gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 10) ==
      gmailSetupHint
    assert rec.calls.len == 0
    removeDir(home)

suite "gmail_search":
  test "a query with no hits quotes it back":
    let home = freshHome("waku-gmail-nohits")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, """{"resultSizeEstimate": 0}"""))
    assert gmailSearch(rec.fetchOf(), home, 1_700_000_000, "from:ana", 10) ==
      "No Gmail messages matched 'from:ana'."
    removeDir(home)

  test "an empty query with no hits says so plainly":
    let home = freshHome("waku-gmail-nohits-empty")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, """{"messages": []}"""))
    assert gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 10) ==
      "No Gmail messages found."
    removeDir(home)

  test "hits list id | from | subject | date, metadata only":
    let home = freshHome("waku-gmail-hits")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] =
      if "format=metadata" in url:
        return (200, metadata("18f", "Ana <a@x>", "Hola", "Mon, 19 Oct 2026"))
      (200, """{"messages": [{"id": "18f"}]}"""))
    let text = gmailSearch(rec.fetchOf(), home, 1_700_000_000, "from:ana", 10)
    assert text == "18f | Ana <a@x> | Hola | Mon, 19 Oct 2026"
    assert rec.calls.len == 2
    assert "maxResults=10" in rec.calls[0].url
    assert "q=from%3Aana" in rec.calls[0].url
    assert rec.calls[0].bearer == "access-1"
    assert "format=metadata" in rec.calls[1].url
    assert "metadataHeaders=From" in rec.calls[1].url
    removeDir(home)

  test "limit clamps to the 25 hits and 10 default the proposal promises":
    let home = freshHome("waku-gmail-limit")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, """{"messages": []}"""))
    discard gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 500)
    discard gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 0)
    discard gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", -4)
    assert "maxResults=25" in rec.calls[0].url
    assert "maxResults=10" in rec.calls[1].url
    assert "maxResults=1" in rec.calls[2].url
    removeDir(home)

  test "an API error becomes a sentence, never an exception":
    let home = freshHome("waku-gmail-searchfail")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (401, "Invalid Credentials"))
    let text = gmailSearch(rec.fetchOf(), home, 1_700_000_000, "x", 10)
    assert text.startsWith("Gmail search unavailable (")
    assert "401" in text
    assert "Invalid Credentials" in text
    removeDir(home)

suite "gmail_read":
  test "without an id it asks for one before touching the network":
    let home = freshHome("waku-gmail-noid")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    assert gmailRead(rec.fetchOf(), home, 1_700_000_000, "") ==
      "gmail_read needs a message_id — call gmail_search first to get one."
    assert rec.calls.len == 0
    removeDir(home)

  test "read returns headers, a blank line, then the decoded body":
    let home = freshHome("waku-gmail-read")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, message("18f", "hi")))
    let text = gmailRead(rec.fetchOf(), home, 1_700_000_000, "18f")
    assert "format=full" in rec.calls[0].url
    assert text == "From: \nDate: \nSubject: \n\nhi"
    removeDir(home)

  test "nested text/plain parts are found depth-first":
    let home = freshHome("waku-gmail-nested")
    tokenFile(home, 1_700_003_600)
    let doc = %*{"id": "18f", "payload": {"mimeType": "multipart/mixed",
      "parts": @[%*{"mimeType": "multipart/alternative",
        "parts": @[%*{"mimeType": "text/plain",
          "body": {"data": urlSafe("the real body")}}]},
        %*{"mimeType": "text/html", "body": {"data": "aWdub3JlZA"}}]}}
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, $doc))
    assert gmailRead(rec.fetchOf(), home, 1_700_000_000, "18f") ==
      "From: \nDate: \nSubject: \n\nthe real body"
    removeDir(home)

  test "a body over 8000 characters is cut and the cut is announced":
    let home = freshHome("waku-gmail-truncate")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, message("18f", repeat('x', 9000))))
    let text = gmailRead(rec.fetchOf(), home, 1_700_000_000, "18f")
    assert "x".repeat(8000) in text
    assert text.endsWith("\n[... truncated at 8000 characters]")
    assert "x".repeat(8001) notin text
    removeDir(home)

  test "a message with no text part falls back to the snippet":
    let home = freshHome("waku-gmail-snippet")
    tokenFile(home, 1_700_003_600)
    let doc = %*{"id": "18f", "snippet": "just a snippet",
      "payload": {"mimeType": "text/html"}}
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, $doc))
    assert gmailRead(rec.fetchOf(), home, 1_700_000_000, "18f").endsWith(
      "\n\njust a snippet")
    removeDir(home)

  test "an unreadable message is reported, not raised":
    let home = freshHome("waku-gmail-readfail")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (404, "Not Found"))
    let text = gmailRead(rec.fetchOf(), home, 1_700_000_000, "nope")
    assert text.startsWith("Gmail could not open nope (")
    assert "404" in text
    removeDir(home)

suite "the token refresh":
  test "a stale token is refreshed, stored, and the new one is used":
    let home = freshHome("waku-gmail-refresh")
    tokenFile(home, 1_600_000_000)  # dies long before "now"
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] =
      if url == "https://oauth2.googleapis.com/token":
        return (200, """{"access_token": "access-2", "expires_in": 3600}""")
      (200, """{"messages": []}"""))
    discard gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 10)
    assert rec.calls.len == 2
    assert rec.calls[0].url == "https://oauth2.googleapis.com/token"
    assert rec.calls[0].meth == "POST"
    assert "grant_type=refresh_token" in rec.calls[0].body
    assert "refresh_token=refresh-1" in rec.calls[0].body
    assert rec.calls[1].bearer == "access-2"
    let stored = parseJson(readFile(home / "gmail-token.json"))
    assert stored["token"].getStr() == "access-2"
    assert stored["refresh_token"].getStr() == "refresh-1"
    assert stored["expiry"].getBiggestInt() == 1_700_003_600
    removeDir(home)

  test "a fresh RFC3339 expiry, as Python writes it, is not refreshed":
    let home = freshHome("waku-gmail-rfc3339")
    let record = %*{"token": "access-1", "refresh_token": "refresh-1",
      "token_uri": "https://oauth2.googleapis.com/token",
      "expiry": "2026-10-19T22:00:00.123456Z"}
    writeFile(home / "gmail-token.json", $record)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, """{"messages": []}"""))
    discard gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 10)
    assert rec.calls.len == 1
    assert rec.calls[0].bearer == "access-1"
    removeDir(home)

  test "a refused refresh means not connected, not a half-used token":
    let home = freshHome("waku-gmail-refuserefresh")
    tokenFile(home, 1_600_000_000)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (400, """{"error": "invalid_grant"}"""))
    assert gmailSearch(rec.fetchOf(), home, 1_700_000_000, "", 10) ==
      gmailSetupHint
    assert rec.calls.len == 1
    removeDir(home)

suite "the tools":
  test "they carry Python's names, descriptions and schemas":
    let home = freshHome("waku-gmail-tools")
    let tools = makeGmailTools(home, proc(url, meth, body, bearer: string):
        tuple[status: int, text: string] = (200, ""), now = proc(): int64 =
      1_700_000_000)
    assert tools.len == 2
    assert tools[0].name == "gmail_search"
    assert tools[1].name == "gmail_read"
    assert tools[0].inputSchema["required"][0].getStr() == "query"
    assert tools[1].inputSchema["required"][0].getStr() == "message_id"
    assert "Use Gmail's own query syntax" in tools[0].description
    assert "Use after gmail_search" in tools[1].description
    assert tools[0].fn(%*{"query": "x"}) == gmailSetupHint
    removeDir(home)

proc decodeUrlSafe(text: string): string =
  ## Gmail's `raw` is base64url; decode it to read what would be sent.
  var s = text.replace('-', '+').replace('_', '/')
  s.add(repeat('=', (4 - s.len mod 4) mod 4))
  decode(s)

suite "gmail_send: the draft default":
  test "no recipient is refused before any file or network call":
    let home = freshHome("waku-gmail-norecipient")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    assert gmailSend(rec.fetchOf(), home, 1_700_000_000, false, "", "s", "b",
      "", "") ==
      "gmail_send needs a recipient address — call it again with one."
    assert rec.calls.len == 0
    assert not dirExists(home / "outbox")
    removeDir(home)

  test "the default writes a draft and says nothing was sent":
    let home = freshHome("waku-gmail-draft")
    # No token file at all: drafting needs none, because nothing leaves the
    # machine and a sign-in wall would only lose the user's words.
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    let text = gmailSend(rec.fetchOf(), home, 1_700_000_000, false,
      "ana@example.com", "Hola", "cuerpo", "", "")
    assert text == "Draft to ana@example.com placed in outbox (" &
      "20231114T221320-ana-example-com.txt). Nothing was sent — review it there."
    assert rec.calls.len == 0
    let written = readFile(home / "outbox" / "20231114T221320-ana-example-com.txt")
    assert written == "To: ana@example.com\nSubject: Hola\n\ncuerpo\n"
    removeDir(home)

  test "a second draft to the same person never overwrites the first":
    let home = freshHome("waku-gmail-draft-collide")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    discard gmailSend(rec.fetchOf(), home, 1_700_000_000, false,
      "ana@example.com", "Uno", "primero", "", "")
    let second = gmailSend(rec.fetchOf(), home, 1_700_000_000, false,
      "ana@example.com", "Dos", "segundo", "", "")
    assert "-2.txt)" in second
    assert "primero" in readFile(
      home / "outbox" / "20231114T221320-ana-example-com.txt")
    assert "segundo" in readFile(
      home / "outbox" / "20231114T221320-ana-example-com-2.txt")
    removeDir(home)

  test "a draft for a thread carries both reply headers":
    let home = freshHome("waku-gmail-draft-reply")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    discard gmailSend(rec.fetchOf(), home, 1_700_000_000, false,
      "ana@example.com", "Re: Hola", "gracias", "thread-9", "<m1@x>")
    let written = readFile(home / "outbox" / "20231114T221320-ana-example-com.txt")
    assert written.startsWith("To: ana@example.com\nSubject: Re: Hola\n" &
      "X-Waku-Thread: thread-9\nIn-Reply-To: <m1@x>\n\n")
    removeDir(home)

suite "gmail_send: the real switch":
  test "with the switch on it posts the base64url RFC 822 message":
    let home = freshHome("waku-gmail-send")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (200, """{"id": "sent-1"}"""))
    let text = gmailSend(rec.fetchOf(), home, 1_700_000_000, true,
      "ana@example.com", "Hola", "cuerpo", "thread-9", "<m1@x>")
    assert text == "Sent to ana@example.com (message sent-1)."
    assert rec.calls.len == 1
    assert rec.calls[0].url == gmailApiBase & "/messages/send"
    assert rec.calls[0].meth == "POST"
    assert rec.calls[0].bearer == "access-1"
    let payload = parseJson(rec.calls[0].body)
    assert payload["threadId"].getStr() == "thread-9"
    assert decodeUrlSafe(payload["raw"].getStr()) ==
      "To: ana@example.com\nSubject: Hola\nMIME-Version: 1.0\n" &
      "Content-Type: text/plain; charset=\"utf-8\"\nIn-Reply-To: <m1@x>\n\n" &
      "cuerpo"
    assert not dirExists(home / "outbox")
    removeDir(home)

  test "sending without a usable token does not fall back to a draft":
    let home = freshHome("waku-gmail-send-notoken")
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (599, "must not be called"))
    assert gmailSend(rec.fetchOf(), home, 1_700_000_000, true,
      "ana@example.com", "Hola", "cuerpo", "", "") == gmailSetupHint
    assert rec.calls.len == 0
    assert not dirExists(home / "outbox")
    removeDir(home)

  test "a refused send is a sentence, not a raise":
    let home = freshHome("waku-gmail-send-fail")
    tokenFile(home, 1_700_003_600)
    let rec = newRecorder(proc(url: string): tuple[status: int,
        text: string] = (403, "insufficient scope"))
    let text = gmailSend(rec.fetchOf(), home, 1_700_000_000, true,
      "ana@example.com", "Hola", "cuerpo", "", "")
    assert text.startsWith("Gmail could not send to ana@example.com (")
    assert "403" in text
    removeDir(home)

suite "gmail_send: the tool":
  test "it is registered only when the send switch is on":
    let home = freshHome("waku-gmail-send-tool")
    let off = makeGmailTools(home, proc(url, meth, body, bearer: string):
        tuple[status: int, text: string] = (200, ""), false,
      now = proc(): int64 = 1_700_000_000)
    let on = makeGmailTools(home, proc(url, meth, body, bearer: string):
        tuple[status: int, text: string] = (200, ""), true,
      now = proc(): int64 = 1_700_000_000)
    assert off.len == 2
    assert on.len == 3
    assert on[2].name == "gmail_send"
    assert on[2].inputSchema["required"][0].getStr() == "to"
    assert on[2].inputSchema["required"][1].getStr() == "body"
    assert "Nothing was sent" notin on[2].description
    assert "NOTHING IS SENT" in on[2].description
    removeDir(home)
