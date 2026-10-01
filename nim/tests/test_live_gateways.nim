## Phase 7d1 tests: the live loops of the chat gateways.
##
## 7a/7b pinned the pure halves (policy, wire, supervisor). This file pins
## the half 7d adds: a long-poll that answers updates through the shared
## `runGatewayTurn`, the poll-error policy (retry / conflict / fatal), the
## handle's stop + status, and the WhatsApp webhook server that answers
## 200 fast and then runs the turns behind it.
##
## Offline only. The Telegram loop is driven by a scripted `TelegramHttpFn`
## (recorded Bot API bodies) and the WhatsApp one by a scripted
## `WhatsappHttpFn` plus a `take` seam that hands over a fake connection:
## no socket is opened, no subprocess is spawned, and `waku.nim` keeps its
## phase-4e stubs (7d2 wires the dispatch).

import std/json
import std/sets
import std/strutils
import std/tables
import std/unittest

import ../src/gateway
import ../src/wire
import ../src/telegram
import ../src/whatsapp

# ── offline doubles ───────────────────────────────────────────────────

type
  Script = ref object
    ## The scripted Bot API: one queued body per call plus the URLs it
    ## saw, so a test can pin the long-poll's offset and timeout. A body
    ## of `"!raise"` fails the call the way a transport failure does.
    queue: seq[string]
    polls: seq[string]
    log: seq[string]
    turns: seq[string]
    sent: seq[string]
    sendFails: bool

proc newScript(): Script =
  Script(queue: @[], polls: @[], log: @[], turns: @[], sent: @[],
    sendFails: false)

proc enqueue(s: Script, body: string) =
  s.queue.add(body)

proc httpOf(s: Script): (TelegramHttpFn, Script) =
  ## The `TelegramHttpFn` seam over the script. Only `getUpdates` is
  ## queued (one recorded body per poll); `sendMessage` is answered with
  ## the API's `ok`, or raises when the test asked for a broken delivery.
  ## A queued `!raise…` body models the transport failure `httpclient`
  ## raises on a non-2xx status, message included.
  let seam: TelegramHttpFn =
    proc(url, payload: string): string {.closure.} =
      if "getUpdates" in url:
        s.polls.add(url)
        if s.queue.len == 0:
          raise newException(IOError, "script exhausted")
        let body = s.queue[0]
        s.queue.delete(0)
        if body == "!raise409":
          raise newException(IOError, "HTTP request failed: 409 Conflict")
        if body == "!raise401":
          raise newException(IOError, "HTTP request failed: 401 Unauthorized")
        if body == "!raise404":
          raise newException(IOError, "HTTP request failed: 404 Not Found")
        if body == "!raise":
          raise newException(IOError, "connection reset")
        return body
      if s.sendFails:
        raise newException(IOError, "connection reset")
      s.sent.add(parseJson(payload).jget("text").getStr())
      return $(%*{"ok": true, "result": newJObject()})
  return (seam, s)

proc respondOf(s: Script, reply = "answer"): RespondFn =
  result = proc(text: string): string {.closure.} =
    s.turns.add(text)
    return reply

proc loggerOf(s: Script): LogFn =
  result = proc(line: string) {.closure.} = s.log.add(line)

proc envOf(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (k, v) in pairs:
    result[k] = v

proc same(a, b: GatewayReport): bool =
  ## `GatewayReport` has no `==` (7a shipped it as a plain object), so
  ## the report pins compare both fields instead.
  a.ok == b.ok and a.message == b.message

proc noIds(): HashSet[string] =
  ## An empty allowlist: everyone gets in (and every channel/message
  ## reaches the agent), which is what a token with no lock configured
  ## means for Telegram.
  initHashSet[string]()

proc idsOf(items: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  for it in items:
    result.incl(it)

proc updatesBody(items: openArray[(int, string)]): string =
  ## A `getUpdates` body: `(update_id, text)`. The user id is 42 for
  ## every entry, so one allowlist covers them.
  var arr = newJArray()
  for (uid, text) in items:
    arr.add(%*{"update_id": uid,
      "message": {"message_id": uid, "text": text,
                  "from": {"id": 42},
                  "chat": {"id": 100}}})
  result = $(%*{"ok": true, "result": arr})

# ── telegram: the long-poll ────────────────────────────────────────────

suite "phase 7d1 telegram poll":
  test "one poll answers every allowlisted update and advances the offset":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(7, "hello"), (8, "again")]))
    let live = newTelegramLive()
    let turns = telegramPoll(live, http, idsOf(["42"]), "tok123",
      respondOf(s, "hi there"), loggerOf(s))
    check turns == 2
    check s.turns == ["hello", "again"]
    check s.sent == ["hi there", "hi there"]
    check live.offset == 9
    check s.log == ["you › hello", "waku › hi there",
      "you › again", "waku › hi there"]

  test "the poll asks for the current offset and its own timeout":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(3, "hi")]))
    let live = newTelegramLive()
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s),
      loggerOf(s), timeoutSecs = 0)
    check "offset=0" in s.polls[0]
    check "timeout=0" in s.polls[0]
    s.enqueue(updatesBody([(4, "hi")]))
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s),
      loggerOf(s), timeoutSecs = 7)
    check "offset=4" in s.polls[1]
    check "timeout=7" in s.polls[1]

  test "a stranger gets the refusal and no agent turn":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(1, "let me in")]))
    let live = newTelegramLive()
    let turns = telegramPoll(live, http, idsOf(["7"]), "tok123",
      respondOf(s), loggerOf(s))
    check turns == 0
    check s.turns.len == 0
    check s.sent == [telegramRefusal]
    check live.offset == 2  # the update is still acknowledged

  test "an update with no text is skipped without a turn":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(5, "x")]))
    let live = newTelegramLive()
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s),
      loggerOf(s))
    check s.turns == ["x"]

  test "a failed turn sends the shared error reply and records it":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(1, "boom")]))
    let live = newTelegramLive()
    let respond: RespondFn =
      proc(text: string): string {.closure.} =
        raise newException(ValueError, "model exploded")
    let turns = telegramPoll(live, http, noIds(), "tok123", respond,
      loggerOf(s), envOf([("TELEGRAM_BOT_TOKEN", "tok123")]))
    check turns == 1
    check s.sent == [gatewayErrorReply]
    check s.log[1].startsWith("(telegram) message handling failed:")
    check "model exploded" in s.log[1]
    check live.runner.errorStatus ==
      "message handling failed (ValueError) — see dashboard terminal"

  test "a failed delivery is recorded as reply delivery, not a turn":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(1, "hi")]))
    s.sendFails = true
    let live = newTelegramLive()
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s),
      loggerOf(s))
    check live.runner.errorStatus ==
      "reply delivery failed (IOError) — see dashboard terminal"

  test "the offset never rewinds on an empty poll":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(11, "hi")]))
    discard telegramPoll(newTelegramLive(), http, noIds(), "t", respondOf(s),
      loggerOf(s))
    s.enqueue(updatesBody([]))
    let live = newTelegramLive()
    live.offset = 12
    let turns = telegramPoll(live, http, noIds(), "t", respondOf(s), loggerOf(s))
    check turns == 0
    check live.offset == 12

suite "phase 7d1 telegram poll failures":
  test "the fault table reads the status the transport reported":
    check telegramFault("HTTP request failed: 409 Conflict") == pfConflict
    check telegramFault("Conflict: terminated by other getUpdates " &
      "request") == pfConflict
    check telegramFault("HTTP request failed: 401 Unauthorized") == pfFatal
    check telegramFault("HTTP request failed: 404 Not Found") == pfFatal
    check telegramFault("connection reset") == pfRetry
    check telegramFault("") == pfRetry

  test "a network failure retries, loudly, and keeps the poller alive":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue("!raise")
    let live = newTelegramLive()
    live.running = true
    let turns = telegramPoll(live, http, noIds(), "tok123", respondOf(s),
      loggerOf(s))
    check turns == 0
    check live.running
    check s.log.len == 1
    check s.log[0].startsWith("(telegram) poll failed:")

  test "a conflict is warned about once and reported as an error status":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue("!raise409")
    s.enqueue("!raise409")
    let live = newTelegramLive()
    live.running = true
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s), loggerOf(s))
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s), loggerOf(s))
    check s.log.len == 1
    check "another instance is already running this bot" in s.log[0]
    check same(telegramStatus(live), GatewayReport(ok: false,
      message: "another instance is polling this token"))

  test "a dead token stops the poller the way Python's InvalidToken does":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue("!raise401")
    let live = newTelegramLive()
    live.running = true
    discard telegramPoll(live, http, noIds(), "tok123", respondOf(s), loggerOf(s))
    check not live.running
    check s.log[0].startsWith("(telegram) background poller stopped:")
    check same(telegramStatus(live), GatewayReport(ok: false,
      message: "gateway stopped unexpectedly"))

suite "phase 7d1 telegram handle":
  test "the status prefers the runner error, then healthy":
    let s = newScript()
    let live = newTelegramLive()
    live.running = true
    check same(telegramStatus(live), GatewayReport(ok: true, message: ""))
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(1, "boom")]))
    discard telegramPoll(live, http, noIds(), "t",
      proc(text: string): string {.closure.} =
        raise newException(ValueError, "nope"), loggerOf(s))
    check not telegramStatus(live).ok
    check "message handling failed" in telegramStatus(live).message

  test "stop ends the run loop and reads as stopped":
    let s = newScript()
    let (http, _) = httpOf(s)
    var polls = 0
    let live = newTelegramLive()
    live.running = true
    while live.running and polls < 5:
      inc polls
      s.enqueue(updatesBody([(polls, "hi")]))
      discard telegramPoll(live, http, noIds(), "t", respondOf(s), loggerOf(s))
      if polls == 2:
        telegramStop(live)
    # one thread in this port: the supervisor can only stop the poller
    # between polls, so the loop leaves right after the stop
    check polls == 2
    check same(telegramStatus(live), GatewayReport(ok: false,
      message: "gateway stopped unexpectedly"))

  test "a stop requested mid-poll still answers that poll, then leaves":
    let s = newScript()
    let live = newTelegramLive()
    let stopLive = live
    let http: TelegramHttpFn =
      proc(url, payload: string): string {.closure.} =
        telegramStop(stopLive)  # the supervisor's stop, mid-flight
        return updatesBody([(1, "answer me")])
    live.running = true
    discard telegramPoll(live, http, noIds(), "t", respondOf(newScript()),
      loggerOf(newScript()))
    check not live.running
    check live.offset == 2  # the update was still acknowledged

  test "the blocking run loop returns when the poller dies":
    let s = newScript()
    let (http, _) = httpOf(s)
    s.enqueue(updatesBody([(1, "hi")]))
    s.enqueue("!raise401")  # the second poll finds a dead token
    let live = newTelegramLive()
    telegramRun(live, http, noIds(), "t", respondOf(s), loggerOf(s))
    check not live.running
    check s.turns == ["hi"]  # the first poll still answered
    check same(telegramStatus(live), GatewayReport(ok: false,
      message: "gateway stopped unexpectedly"))

  test "the starter declines without a token and starts with one":
    let s = newScript()
    let (http, _) = httpOf(s)
    let live = newTelegramLive()
    let start = telegramStarter(live, envOf([]), respondOf(s), http,
      loggerOf(s))
    check not start()
    check not live.running
    let withToken = telegramStarter(live,
      envOf([("TELEGRAM_BOT_TOKEN", "tok123")]), respondOf(s), http,
      loggerOf(s))
    check withToken()
    check live.running
    let status = telegramStatusFn(live)
    check status("telegram").ok
    let stop = telegramStopFn(live)
    stop("telegram")
    check not live.running
    # a restart is a fresh poller: a stale conflict, warning and runner
    # error never survive one
    live.conflict = true
    live.warned = true
    live.offset = 99
    discard withToken()
    check not live.conflict
    check not live.warned
    check live.offset == 0
    check live.runner.errorStatus().len == 0

# ── whatsapp: the webhook door ────────────────────────────────────────

type
  Wire = ref object
    ## The scripted Graph API plus the event log both seams write to, so
    ## a test can pin the ORDER that matters here: the 200 goes out
    ## before any agent turn, or Meta disables the webhook.
    sent: seq[string]
    events: seq[string]
    log: seq[string]
    turns: seq[string]
    status: int
    failSend: bool

proc newWire(): Wire =
  Wire(sent: @[], events: @[], log: @[], turns: @[], status: 200,
    failSend: false)

proc httpOf(w: Wire): (WhatsappHttpFn, Wire) =
  let seam: WhatsappHttpFn =
    proc(url, payload, token: string): int {.closure.} =
      w.events.add("send")
      if w.failSend:
        raise newException(IOError, "429 Too Many Requests")
      w.sent.add(parseJson(payload).jget("text").jget("body").getStr())
      return w.status
  return (seam, w)

proc loggerOf(w: Wire): LogFn =
  result = proc(line: string) {.closure.} = w.log.add(line)

proc postReq(rawBody: string, appSecret = "shhh",
    sig = ""): WhatsappRequest =
  ## A signed POST by default: the signature is computed over the raw
  ## body, like Meta's. A test that wants a forged one passes `sig`.
  WhatsappRequest(verb: "POST", target: "/webhook", body: rawBody,
    signature: if sig.len > 0: sig else: whatsappSignature(appSecret, rawBody))

proc getReq(target = "/webhook?hub.mode=subscribe" &
  "&hub.verify_token=letmein&hub.challenge=9182"): WhatsappRequest =
  WhatsappRequest(verb: "GET", target: target, body: "", signature: "")

proc inbound(sender, text: string): string =
  ## A `messages` webhook body with one text message.
  result = $(%*{"entry": [{"changes": [{"value": {"messages": [
    {"from": sender, "text": {"body": text}}]}}]}]})

suite "phase 7d1 whatsapp query":
  test "parse_qs takes the first value of each hub parameter":
    check parseQueryParam(getReq().target, "hub.mode") == "subscribe"
    check parseQueryParam(getReq().target, "hub.challenge") == "9182"
    check parseQueryParam(getReq().target, "hub.verify_token") == "letmein"
    check parseQueryParam("/webhook", "hub.mode") == ""
    check parseQueryParam("/webhook?other=1", "hub.mode") == ""
    check parseQueryParam("/webhook?hub.mode=a&hub.mode=b",
      "hub.mode") == "a"
    check parseQueryParam("/webhook?hub.verify_token=", "hub.verify_token") == ""

suite "phase 7d1 whatsapp GET verification":
  test "the right token and a challenge get the challenge back":
    let w = newWire()
    let (http, _) = httpOf(w)
    var wrote: seq[string] = @[]
    let write: WriteFn =
      proc(status: int, body: string) {.closure.} =
        wrote.add($status & " " & body)
    let turns = serveWhatsappRequest(getReq(), "letmein", "shhh", "", "tok",
      "12345", http, respondOf(newScript(), "hi"), loggerOf(w),
      write = write)
    check turns == 0
    check wrote == ["200 9182"]
    check w.log == ["(whatsapp) webhook verified"]

  test "a wrong token, a missing challenge or a foreign path never verifies":
    let w = newWire()
    let (http, _) = httpOf(w)
    var wrote: seq[string] = @[]
    let write: WriteFn =
      proc(status: int, body: string) {.closure.} =
        wrote.add($status & " " & body)
    discard serveWhatsappRequest(
      getReq("/webhook?hub.mode=subscribe&hub.verify_token=nope" &
        "&hub.challenge=9182"), "letmein", "shhh", "", "tok", "12345", http,
      respondOf(newScript()), loggerOf(w), write = write)
    discard serveWhatsappRequest(
      getReq("/webhook?hub.mode=subscribe&hub.verify_token=letmein"),
      "letmein", "shhh", "", "tok", "12345", http,
      respondOf(newScript()), loggerOf(w), write = write)
    discard serveWhatsappRequest(getReq("/other?hub.mode=subscribe"),
      "letmein", "shhh", "", "tok", "12345", http, respondOf(newScript()),
      loggerOf(w), write = write)
    check wrote == ["403 forbidden", "403 forbidden", "404 {}"]
    # the failed line names the mode and never echoes the token back
    check w.log[0] ==
      "(whatsapp) verification failed: mode=subscribe token=***"
    check w.log[1] == "(whatsapp) verification failed: mode=subscribe token=***"
    check w.log[2] == "(whatsapp) verification failed: mode=subscribe " &
      "token=none"

suite "phase 7d1 whatsapp POST door":
  test "the door answers exactly what the 7b decision answered":
    let w = newWire()
    let (http, _) = httpOf(w)
    let s = newScript()
    var wrote: seq[string] = @[]
    let write: WriteFn =
      proc(status: int, body: string) {.closure.} =
        wrote.add($status & " " & body)
    # 404: a foreign path. 403: a bad signature. 400: bad json.
    discard serveWhatsappRequest(postReq("{}", "shhh", "sha256=nope"), "vt", "shhh",
      "", "tok", "12345", http, respondOf(s), loggerOf(w), write = write)
    discard serveWhatsappRequest(WhatsappRequest(verb: "POST",
      target: "/other", body: inbound("15551234567", "hi"), signature: "x"),
      "vt", "shhh", "", "tok", "12345", http, respondOf(s), loggerOf(w),
      write = write)
    discard serveWhatsappRequest(postReq("not json at all", "shhh",
      "sha256=nope"),
      "vt", "shhh", "", "tok", "12345", http, respondOf(s), loggerOf(w),
      write = write)
    check wrote == ["403 {}", "404 {}", "403 {}"]
    check "(whatsapp) rejected: bad signature" in w.log

  test "a signed POST answers 200 first, then turns every message":
    let w = newWire()
    let (http, _) = httpOf(w)
    let s = newScript()
    var wrote: seq[string] = @[]
    let write: WriteFn =
      proc(status: int, body: string) {.closure.} =
        w.events.add("write " & $status)
        wrote.add($status & " " & body)
    let turns = serveWhatsappRequest(
      postReq(inbound("15551234567", "what is on today")), "vt", "shhh",
      "", "tok", "12345", http, respondOf(s, "three meetings"), loggerOf(w),
      write = write)
    check turns == 1
    check wrote == ["200 {}"]
    check s.turns == ["what is on today"]
    check w.sent == ["three meetings"]
    # the load-bearing order: the 200 is out before the agent is called
    check w.events == ["write 200", "send"]
    check w.log == ["you › [15551234567] what is on today",
      "waku › three meetings"]

  test "a signed POST is verified against the raw body":
    let w = newWire()
    let (http, _) = httpOf(w)
    let s = newScript()
    let body = inbound("15551234567", "hi")
    let sig = whatsappSignature("shhh", body)
    let turns = serveWhatsappRequest(postReq(body, "shhh", sig), "vt",
      "shhh", "", "tok", "12345", http, respondOf(s), loggerOf(w))
    check turns == 1
    # one byte of tampering invalidates the signature: it covers the body
    let tampered = serveWhatsappRequest(postReq(body & " ", "shhh", sig),
      "vt", "shhh", "", "tok", "12345", http, respondOf(s), loggerOf(w))
    check tampered == 0
    check w.log[^1] == badSignatureLine

  test "a sender outside the allowlist is rejected and logged":
    let w = newWire()
    let (http, _) = httpOf(w)
    let s = newScript()
    let turns = serveWhatsappRequest(
      postReq(inbound("15550000000", "let me in")), "vt", "shhh",
      "15551234567", "tok", "12345", http, respondOf(s), loggerOf(w))
    check turns == 0
    check s.turns.len == 0
    check w.log == ["(whatsapp) rejected message from 15550000000 " &
      "(not allowed)"]

  test "a failed turn answers the shared error reply and records it":
    let w = newWire()
    let (http, _) = httpOf(w)
    let s = newScript()
    let live = newWhatsappLive()
    let turns = serveWhatsappRequest(postReq(inbound("15551234567", "boom")),
      "vt", "shhh", "", "tok", "12345", http,
      proc(text: string): string {.closure.} =
        s.turns.add(text)
        raise newException(ValueError, "model exploded"), loggerOf(w),
      env = envOf([("WHATSAPP_TOKEN", "tok")]), live = live)
    check turns == 1
    check w.sent == [gatewayErrorReply]
    check live.runner.errorStatus ==
      "message handling failed (ValueError) — see dashboard terminal"

  test "a failed send is logged and does not stop the loop":
    let w = newWire()
    let (http, _) = httpOf(w)
    w.failSend = true
    let s = newScript()
    let turns = serveWhatsappRequest(postReq(inbound("15551234567", "hi")),
      "vt", "shhh", "", "tok", "12345", http, respondOf(s, "answer"),
      loggerOf(w))
    check turns == 1
    check w.log[1] == "waku › answer"
    check w.log[2].startsWith("(whatsapp) send failed:")
    check "429" in w.log[2]

suite "phase 7d1 whatsapp handle":
  test "the status reads healthy, then the last turn error":
    let w = newWire()
    let live = newWhatsappLive()
    live.running = true
    check same(whatsappStatus(live), GatewayReport(ok: true, message: ""))
    let (http, _) = httpOf(w)
    let s = newScript()
    discard live.runner.recordError("ValueError", "boom", envOf([]),
      "message handling")
    check same(whatsappStatus(live), GatewayReport(ok: false,
      message: "message handling failed (ValueError) — see dashboard terminal"))
    discard serveWhatsappRequest(postReq(inbound("15551234567", "hi")), "vt",
      "shhh", "", "tok", "12345", http, respondOf(s), loggerOf(w),
      live = live)
    check whatsappStatus(live).ok
    discard serveWhatsappRequest(postReq(inbound("15551234567", "hi")), "vt",
      "shhh", "", "tok", "12345", http, respondOf(s), loggerOf(w),
      live = live)
    whatsappStop(live)
    check same(whatsappStatus(live), GatewayReport(ok: false,
      message: "gateway stopped unexpectedly"))

  test "the starter needs all four credentials, like Python":
    let live = newWhatsappLive()
    let w = newWire()
    let (http, _) = httpOf(w)
    let s = newScript()
    let start = whatsappStarter(live, envOf([]), respondOf(s), http,
      loggerOf(w))
    check not start()
    check not live.running
    let partial = whatsappStarter(live,
      envOf([("WHATSAPP_TOKEN", "tok"), ("WHATSAPP_PHONE_NUMBER_ID", "1"),
        ("WHATSAPP_VERIFY_TOKEN", "vt")]), respondOf(s), http, loggerOf(w))
    check not partial()
    let full = whatsappStarter(live,
      envOf([("WHATSAPP_TOKEN", "tok"), ("WHATSAPP_PHONE_NUMBER_ID", "12345"),
        ("WHATSAPP_VERIFY_TOKEN", "vt"), ("WHATSAPP_APP_SECRET", "shhh")]),
      respondOf(s), http, loggerOf(w))
    check full()
    check live.running
    check whatsappStatusFn(live)("whatsapp").ok
    whatsappStopFn(live)("whatsapp")
    check not live.running
    # a restart is a fresh server
    discard live.runner.recordError("ValueError", "boom", envOf([]),
      "reply delivery")
    check full()
    check live.runner.errorStatus().len == 0

suite "phase 7d1 whatsapp startup lines":
  test "the listening line says the address that was bound":
    assert listeningLine("0.0.0.0", 5000) ==
      "WhatsApp gateway → listening on http://0.0.0.0:5000"
    assert listeningLine("127.0.0.1", 5001) ==
      "WhatsApp gateway → listening on http://127.0.0.1:5001"
    assert webhookUrlLine == "  Webhook URL: http://<your-public-url>/webhook"
    assert ctrlCLine == "  Ctrl-C to stop."
