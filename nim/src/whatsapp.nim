## WhatsApp gateway, phase 7b — webhook verify + HMAC + payload parse + send seam.
##
## Port of the testable core of `waku/gateway/whatsapp.py`: the GET
## verification challenge (`hub.mode`/`hub.verify_token`/`hub.challenge`),
## the POST signature check (`X-Hub-Signature-256`, HMAC-SHA256), the
## `entry/changes/value/messages` walk with the single-phone allowlist,
## and the send path as an injected seam against the Graph API
## (`POST /{phone_number_id}/messages`).
##
## HMAC reuses the vendored SHA-256 in `mcp.nim` (`sha256Digest`): only
## the HMAC pads and the hex rendering live here — no duplicated digest.
##
## 7d1 replaces the honest 7b seam (`serveWhatsappWebhook`, which raised
## "the webhook server lives in 7d") with the server itself: the door
## (`serveWhatsappRequest` — decide, answer 200 fast, then turn),
## the socket framing (`readWhatsappRequest`/`writeWhatsappResponse`),
## the accept loop (`serveWhatsapp`) and the handle the supervisor reads
## (`whatsappStatus`/`whatsappStop` plus the three adapters). The
## `TakeConn` seam is where 7d2 plugs the webhook into the dashboard's
## single loop. Every other side effect still travels through
## `WhatsappHttpFn`: zero sockets in tests. `waku.nim` keeps its
## phase-4e `whatsapp` stub until 7d2 wires the dispatch.

import std/httpclient
import std/httpcore
import std/net
import std/uri
import std/json
import std/strutils
import std/tables

import ./gateway
import ./mcp
import ./wire

const whatsappEnvFields* = ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID",
  "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_APP_SECRET", "WHATSAPP_ALLOWED_PHONE"]
  ## Supervisor fields for 7d (token first: `isConfigured` reads the
  ## first field as the token). Port of the `settings` + `os.getenv`
  ## reads in `whatsapp.py`'s `main`/`start_in_background`.

# ── HMAC-SHA256 ───────────────────────────────────────────────────────

proc hmacSha256Hex*(key, message: string): string =
  ## HMAC-SHA256 as lowercase hex (what Meta's `X-Hub-Signature-256`
  ## carries after the `sha256=` prefix). The digest is `mcp.nim`'s
  ## vendored SHA-256; only the RFC 2104 pads live here. Pinned by the
  ## RFC 4231 vectors in `test_chat_gateways.nim`.
  var k = key
  if k.len > 64:
    let d = sha256Digest(k)
    k = newString(32)
    for i in 0 ..< 32:
      k[i] = char(d[i])
  while k.len < 64:
    k.add('\0')
  var ipad = newString(64)
  var opad = newString(64)
  for i in 0 ..< 64:
    ipad[i] = char(byte(k[i]) xor 0x36'u8)
    opad[i] = char(byte(k[i]) xor 0x5c'u8)
  let inner = sha256Digest(ipad & message)
  var innerStr = newString(32)
  for i in 0 ..< 32:
    innerStr[i] = char(inner[i])
  let outer = sha256Digest(opad & innerStr)
  for b in outer:
    result.add(toHex(int(b), 2).toLowerAscii())

proc signaturesEqual*(a, b: string): bool =
  ## Port of `hmac.compare_digest`: length-sensitive constant-time
  ## equality, so a forged webhook cannot learn the secret byte by byte.
  if a.len != b.len:
    return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (ord(a[i]) xor ord(b[i]))
  return diff == 0

proc whatsappSignature*(appSecret, body: string): string =
  ## The header value Meta sends: `"sha256=" & HMAC(body)`.
  "sha256=" & hmacSha256Hex(appSecret, body)

proc verifyWhatsappSignature*(appSecret, body, sig: string): bool =
  ## True when `sig` is Meta's signature for `body` under `appSecret`
  ## (port of the `compare_digest` gate in `do_POST`: without it anyone
  ## finding the webhook URL could forge payloads and drive the agent).
  signaturesEqual(sig, whatsappSignature(appSecret, body))

# ── GET verification ──────────────────────────────────────────────────

type WhatsappVerify* = object
  ## The answer to Meta's one-time verification challenge: an HTTP
  ## status plus the raw body (`challenge` on success).
  status*: int
  body*: string

proc verifyWhatsapp*(path, mode, verifyToken, challenge,
    expected: string): WhatsappVerify =
  ## Port of `do_GET`: only `/webhook` with `mode == "subscribe"`, the
  ## configured verify token and a non-empty challenge verifies (200
  ## echoing the challenge); anything else is 403 `forbidden`, and a
  ## foreign path is 404 (same as `do_POST`'s path gate).
  if path != "/webhook":
    return WhatsappVerify(status: 404, body: "{}")
  if mode == "subscribe" and verifyToken == expected and
      challenge.len > 0:
    return WhatsappVerify(status: 200, body: challenge)
  return WhatsappVerify(status: 403, body: "forbidden")

# ── POST payload ──────────────────────────────────────────────────────

type WhatsappMessage* = object
  ## One answerable inbound message: sender phone (no `+` prefix, kept
  ## as Meta sends it) plus the text body.
  sender*: string
  text*: string

proc parseWhatsappMessages*(node: JsonNode): seq[WhatsappMessage] =
  ## The `entry/changes/value/messages` walk in `do_POST`: every
  ## message with a non-empty sender AND body. Text-less entries
  ## (statuses, reactions) are skipped, like the `if not text` guard.
  result = @[]
  if node.jget("entry").kind != JArray:
    return result
  for entry in node["entry"]:
    if entry.jget("changes").kind != JArray:
      continue
    for change in entry["changes"]:
      let value = change.jget("value")
      if value.jget("messages").kind != JArray:
        continue
      for msg in value["messages"]:
        if msg.kind != JObject:
          continue
        let sender = msg.jget("from").getStr()
        let text = msg.jget("text").jget("body").getStr()
        if sender.len == 0 or text.len == 0:
          continue
        result.add(WhatsappMessage(sender: sender, text: text))

proc isWhatsappAllowed*(allowed, sender: string): bool =
  ## The single-phone allowlist (`WHATSAPP_ALLOWED_PHONE`): empty lets
  ## anyone in, otherwise only that exact number (port of the
  ## `if allowed and sender != allowed` gate).
  allowed.len == 0 or sender == allowed

type WhatsappPost* = object
  ## The whole POST answer: the HTTP status/body to return FAST (Meta
  ## retries on timeouts and disables flapping webhooks, so the 200
  ## always comes before any agent turn) plus the answerable messages
  ## 7d will turn after responding.
  status*: int
  body*: string
  messages*: seq[WhatsappMessage]

proc handleWhatsappPost*(path, sig, appSecret, rawBody,
    allowed: string): WhatsappPost =
  ## Port of `do_POST` without the socket or the agent: path gate
  ## (404), signature gate (403), JSON gate (400 `bad json`), then 200
  ## with the allowlisted messages attached. Malformed ENTRIES are
  ## skipped; a malformed ENVELOPE is the 400.
  if path != "/webhook":
    return WhatsappPost(status: 404, body: "{}", messages: @[])
  if not verifyWhatsappSignature(appSecret, rawBody, sig):
    return WhatsappPost(status: 403, body: "{}", messages: @[])
  var node: JsonNode
  try:
    node = parseJson(rawBody)
  except JsonParsingError:
    return WhatsappPost(status: 400, body: "bad json", messages: @[])
  var kept: seq[WhatsappMessage] = @[]
  for m in parseWhatsappMessages(node):
    if isWhatsappAllowed(allowed, m.sender):
      kept.add(m)
  return WhatsappPost(status: 200, body: "{}", messages: kept)

# ── Graph API send seam ───────────────────────────────────────────────

type WhatsappHttpFn* = proc(url, payload, token: string): int {.closure.}
  ## One Graph API call: full URL + JSON payload + bearer token → HTTP
  ## status. Raises on transport failure, like `httpclient`; tests
  ## inject recorded statuses.

proc graphMessageUrl*(phoneNumberId: string): string =
  ## The Meta Cloud API message endpoint (v21.0, as in `_send_message`).
  "https://graph.facebook.com/v21.0/" & phoneNumberId & "/messages"

proc buildWhatsappBody*(to, text: string): JsonNode =
  ## The Graph API text-message payload.
  %*{"messaging_product": "whatsapp", "to": to, "type": "text",
    "text": {"body": text}}

proc sendWhatsappText*(http: WhatsappHttpFn, token, phoneNumberId, to,
    text: string): bool =
  ## Deliver one reply through the Meta Cloud API (port of
  ## `_send_message` minus the socket): `true` on 2xx, `false` on an
  ## error status (Meta throttles at ~80 msg/s; a 429 is an outcome,
  ## logged by 7d's `(whatsapp) send failed` line). Transport failures
  ## propagate.
  http(graphMessageUrl(phoneNumberId), $buildWhatsappBody(to, text),
    token) in 200 .. 299

proc liveWhatsappPost*(url, payload, token: string): int =
  ## The real Graph API call over `std/httpclient`. Real socket —
  ## never called in tests (they inject `WhatsappHttpFn` fakes).
  var client = newHttpClient(timeout = 15000)
  try:
    client.headers = newHttpHeaders([("Content-Type", "application/json"),
      ("Authorization", "Bearer " & token)])
    let resp = client.post(url, payload)
    try:
      return parseInt(resp.status.split(' ')[0])
    except ValueError:
      return 0
  finally:
    try:
      client.close()
    except CatchableError:
      discard

# ── the live webhook door (7d1) ───────────────────────────────────────

const
  verifiedLine* = "(whatsapp) webhook verified"
  badSignatureLine* = "(whatsapp) rejected: bad signature"
  sendFailedLine* = "(whatsapp) send failed: "
  rejectedLine* = "(whatsapp) rejected message from "
  notAllowedLine* = "(not allowed)"
  webhookUrlLine* = "  Webhook URL: http://<your-public-url>/webhook"
  ctrlCLine* = "  Ctrl-C to stop."
  stoppedLine* = "Stopped."
  whatsappPort* = 5000
    ## The port `ThreadingHTTPServer(("0.0.0.0", 5000), …)` binds, and
    ## the one `ngrok http 5000` in the setup docstring points at. It is
    ## a constant like Python's, and a parameter of `serveWhatsapp` so a
    ## test or a second gateway can bind elsewhere.

type
  WriteFn* = proc(status: int, body: string) {.closure.}
    ## Write one HTTP answer (status + body) for the socket seam. The
    ## door takes it so the ORDER that keeps the webhook alive — answer
    ## 200 first, turn second — is testable offline: a test's `write` and
    ## `respond` write to one log, and the pins read the order out of it.
  WhatsappRequest* = object
    ## One inbound HTTP request, reduced to what the handler reads: the
    ## verb, the raw target (query included), the body exactly as it
    ## arrived, and Meta's signature header. The signature covers the
    ## RAW body, so nothing here may normalise it.
    verb*: string
    target*: string
    body*: string
    signature*: string
  WhatsappLive* = ref object
    ## One running webhook server: what `WhatsAppHandle` plus its
    ## `ThreadingHTTPServer` hold in Python. The socket itself lives in
    ## the owner's loop (7d2 multiplexes it with the dashboard's), so
    ## this handle is the accounting the supervisor sees.
    runner*: RunnerState
    stop*: bool
    running*: bool
    host*: string
    port*: int

proc newWhatsappLive*(source = "whatsapp"): WhatsappLive =
  ## A server that has not bound yet.
  WhatsappLive(runner: newRunnerState(source), stop: false, running: false,
    host: "0.0.0.0", port: whatsappPort)

# ── request bits (pure) ───────────────────────────────────────────────

proc requestPath*(target: string): string =
  ## `urlparse(self.path).path`: everything before the query string.
  let cut = target.find('?')
  if cut < 0: target else: target[0 ..< cut]

proc parseQueryParam*(target, name: string): string =
  ## One `hub.*` parameter, port of `parse_qs(...)` + `[0]`: the FIRST
  ## value wins for a repeated key, and an empty value reads as absent
  ## (which is what `parse_qs` does — it drops blanks). `decodeUrl` does
  ## the percent-decoding and the `+`-is-a-space rule, exactly as
  ## `parse_qs` does; it leaves an invalid escape alone instead of
  ## raising, which is the one place it is laxer than
  ## `urllib.parse.unquote`.
  let cut = target.find('?')
  if cut < 0:
    return ""
  for pair in target[cut + 1 .. ^1].split('&'):
    let eq = pair.find('=')
    if eq <= 0:
      continue
    if pair[0 ..< eq] != name:
      continue
    let value = decodeUrl(pair[eq + 1 .. ^1])
    if value.len > 0:
      return value
  return ""

proc senderLogLine*(sender, line: string): string =
  ## The handler's `print(f"you › [{sender}] {text}")` shape, applied to
  ## the shared turn logger: the sender appears on the inbound line only,
  ## every other line (`waku › …` and the failure lines) is shared
  ## verbatim with the other gateways.
  const prefix = "you › "
  if line.startsWith(prefix):
    return prefix & "[" & sender & "] " & line[prefix.len .. ^1]
  return line

proc whatsappRejected*(rawBody, allowed: string): seq[string] =
  ## The senders Python's handler logs and skips: every message in the
  ## payload that the single-phone allowlist refuses. The 7b decision
  ## returns only the ALLOWED messages, so this walks the same payload
  ## again to keep the rejection line — a person whose messages vanish
  ## needs to know why.
  result = @[]
  var node: JsonNode
  try:
    node = parseJson(rawBody)
  except JsonParsingError:
    return result
  for m in parseWhatsappMessages(node):
    if not isWhatsappAllowed(allowed, m.sender):
      result.add(m.sender)

# ── the door ──────────────────────────────────────────────────────────

proc serveWhatsappRequest*(req: WhatsappRequest, verifyToken, appSecret,
    allowed, token, phoneNumberId: string, http: WhatsappHttpFn,
    respond: RespondFn, logger: LogFn,
    env: Table[string, string] = initTable[string, string](),
    live: WhatsappLive = nil, write: WriteFn = nil): int =
  ## One request, end to end: decide, ANSWER 200 FAST, then run the turns
  ## behind it. Meta retries on timeouts and disables a flapping webhook,
  ## which is why the answer never waits on a model (Python's comment says
  ## the same). Returns the number of turns attempted. `live` is the
  ## handle the supervisor reads; nil means "no handle", and the turns
  ## still run with a throwaway runner.
  ##
  ## Divergence: a turn that blows up answers the shared
  ## `gatewayErrorReply` (through `runGatewayTurn`, the one turn policy
  ## the port has). Python's handler has no try/except at all: the
  ## exception escapes `do_POST`, the HTTP server prints a traceback and
  ## the sender sees nothing. A single-threaded server cannot afford that
  ## — one bad turn would take the whole gateway down — and a partner
  ## deserves the same answer the Telegram and Discord gateways give.
  # `var`, not `let`: `accountedRespond` takes the address of the
  # runner (a closure cannot capture a `var` parameter), and a `let` ref
  # would hand it a copy on this frame.
  var handle = if live.isNil: newWhatsappLive() else: live
  # a named proc, not a nil closure: calling a nil `{.closure.}` is a
  # segfault, and a nil `write` is the "no socket" case (7d2's dashboard
  # loop passes one, the standalone command passes the socket writer)
  proc answer(status: int, body: string) =
    if not write.isNil:
      write(status, body)
  if req.verb == "GET":
    let mode = parseQueryParam(req.target, "hub.mode")
    let challenge = parseQueryParam(req.target, "hub.challenge")
    let incoming = parseQueryParam(req.target, "hub.verify_token")
    let decided = verifyWhatsapp(requestPath(req.target), mode, incoming,
      challenge, verifyToken)
    if decided.status == 200:
      logger(verifiedLine)
    else:
      # Python prints the incoming token here; the port prints `***` (or
      # `none`), because that value is a credential and this line lands
      # in a terminal and a trace.
      logger("(whatsapp) verification failed: mode=" & mode & " token=" &
        (if incoming.len > 0: "***" else: "none"))
    answer(decided.status, decided.body)
    return 0
  let decided = handleWhatsappPost(requestPath(req.target), req.signature,
    appSecret, req.body, allowed)
  if decided.status == 403:
    logger(badSignatureLine)
  answer(decided.status, decided.body)
  if decided.status != 200:
    return 0
  for sender in whatsappRejected(req.body, allowed):
    logger(rejectedLine & sender & " " & notAllowedLine)
  let turn = accountedRespond(handle.runner, respond, env)
  for i in 0 ..< decided.messages.len:
    let msg = decided.messages[i]  # a value: both closures below keep it
    let send: SendFn =
      proc(text: string) {.closure.} =
        try:
          discard sendWhatsappText(http, token, phoneNumberId, msg.sender,
            text)
        except CatchableError as exc:
          # Python's `_send_message` prints this line and moves on; the
          # port prints it AND lets the failure reach the runner
          # accounting, or a webhook that keeps failing to deliver would
          # look healthy on the dashboard.
          logger(sendFailedLine & safeException($exc.name, exc.msg, env))
          raise
    let senderLog: LogFn =
      proc(line: string) {.closure.} = logger(senderLogLine(msg.sender, line))
    discard runGatewayTurn(handle.runner, msg.text, turn, send, senderLog,
      env)
    inc result
  return result

# ── the handle ────────────────────────────────────────────────────────

proc whatsappStatus*(live: WhatsappLive): GatewayReport =
  ## `WhatsAppHandle.status()`: a server that is not running reads as
  ## `gateway stopped unexpectedly` (Python's exact message), otherwise
  ## the runner's last turn error, otherwise healthy. Python's handle has
  ## no runner at all — the port reuses the shared one so a broken turn
  ## shows on the dashboard like it does for the other gateways. A nil
  ## handle (nothing started) reads as stopped, like Python's `None`.
  if live.isNil or not live.running:
    return GatewayReport(ok: false, message: "gateway stopped unexpectedly")
  let lastError = live.runner.errorStatus()
  if lastError.len > 0:
    return GatewayReport(ok: false, message: lastError)
  return GatewayReport(ok: true, message: "")

proc whatsappStop*(live: WhatsappLive) =
  ## Ask the server to stop (Python's `WhatsAppHandle.stop` calls
  ## `shutdown()` from the dashboard thread and joins the worker). The
  ## loop in `serveWhatsapp` leaves at its next turn around; the caller
  ## owns the socket, so the port closes it there.
  ##
  ## A nil handle stops nothing, exactly as `whatsappStatus` reads it as
  ## stopped: the supervisor's stop seam can be called for a gateway that
  ## never started, and a nil deref while shutting down would take the
  ## dashboard down at the worst possible moment.
  if live.isNil:
    return
  live.stop = true
  live.running = false
  closeRunner(live.runner)

proc whatsappStarter*(live: WhatsappLive, env: Table[string, string],
    respond: RespondFn, http: WhatsappHttpFn, logger: LogFn): StarterFn =
  ## The `starters["whatsapp"]` entry from `dashboard.main`, as one
  ## closure. All FOUR credentials are required, exactly like
  ## `start_in_background`'s early return: a token without the phone
  ## number id, verify token or app secret cannot serve the webhook at
  ## all (the signature cannot be checked without the secret, which is
  ## the whole reason it is required). A restart is a fresh server with a
  ## fresh runner, like Python's.
  result = proc(): bool {.closure.} =
    var missing = ""
    for field in ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID",
        "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_APP_SECRET"]:
      if env.getOrDefault(field, "").len == 0:
        if missing.len > 0: missing.add(", ")
        missing.add(field)
    if missing.len > 0:
      logger("(whatsapp) not configured: missing " & missing)
      return false
    live.stop = false
    live.runner = newRunnerState(live.runner.source)
    live.running = true
    return true

proc whatsappStatusFn*(live: WhatsappLive): StatusFn =
  ## Supervisor adapter for one `whatsapp` handle.
  result = proc(key: string): GatewayReport {.closure.} = whatsappStatus(live)

proc whatsappStopFn*(live: WhatsappLive): StopFn =
  ## Supervisor adapter for one `whatsapp` handle.
  result = proc(key: string) {.closure.} = whatsappStop(live)

proc listeningLine*(host: string, port: int): string =
  ## `WhatsApp gateway → listening on http://0.0.0.0:5000`, Python's
  ## startup line with the address the server actually bound (the
  ## default pair renders the exact same string).
  "WhatsApp gateway → listening on http://" & host & ":" & $port

# ── the live server (7d1) ─────────────────────────────────────────────

type
  TakeConn* = proc(): (bool, Socket) {.closure.}
    ## Hand over the next inbound connection, or `false` when there is
    ## none right now. Nil means "block in `accept`", which is what the
    ## standalone `waku whatsapp` command wants; the dashboard (7d2)
    ## injects a select-based take so the webhook and the browser share
    ## one loop — Python gave the webhook its own thread, and a
    ## single-threaded port pays for that with a seam instead.

proc readWhatsappRequest*(client: Socket): WhatsappRequest =
  ## Read one HTTP request off the wire: the request line, the headers
  ## (`X-Hub-Signature-256` is the only one the handler reads) and a
  ## `Content-Length` body. A request line that does not parse comes back
  ## with an empty verb, which the door answers 404 — the same shape the
  ## dashboard's `serveOne` uses for an unknown api path.
  result = WhatsappRequest(verb: "", target: "", body: "",
    signature: "")
  let line = client.recvLine().strip()
  if line.len == 0:
    return result
  let parts = line.split(' ')
  if parts.len < 2:
    return result
  result.verb = parts[0]
  result.target = parts[1]
  var length = 0
  while true:
    let header = client.recvLine()
    if header.strip().len == 0:
      break
    let colon = header.find(':')
    if colon <= 0:
      continue
    let name = header[0 ..< colon].strip().toLowerAscii()
    let value = header[colon + 1 .. ^1].strip()
    if name == "x-hub-signature-256":
      result.signature = value
    elif name == "content-length":
      try:
        length = parseInt(value)
      except ValueError:
        length = 0
  if length <= 0:
    return result
  var remaining = length
  while remaining > 0:
    let part = client.recv(remaining)
    if part.len == 0:
      break
    result.body.add(part)
    remaining -= part.len

proc writeWhatsappResponse*(client: Socket, status: int, body: string) =
  ## One answer, always `Content-Type: application/json` and always
  ## `Connection: close`. Python's `_set_json` sends that header for
  ## every branch, including the verification challenge and the `forbidden`
  ## / `bad json` bodies, so the port does the same instead of fixing it.
  let reason =
    if status == 200: "OK"
    elif status == 400: "Bad Request"
    elif status == 403: "Forbidden"
    elif status == 404: "Not Found"
    else: "OK"
  client.send("HTTP/1.1 " & $status & " " & reason & "\r\n" &
    "Content-Type: application/json\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body)

proc serveWhatsapp*(live: WhatsappLive, verifyToken, appSecret, allowed,
    token, phoneNumberId: string, http: WhatsappHttpFn, respond: RespondFn,
    logger: LogFn, take: TakeConn = nil) =
  ## The live webhook server (port of `_build_handler` +
  ## `ThreadingHTTPServer(..., 5000)` + `serve_forever`): bind, print
  ## Python's three startup lines, then answer every request and close
  ## it. It returns when `whatsappStop` is observed; the caller owns the
  ## socket, so the bind here is released on the way out.
  ##
  ## Divergences, both forced by one thread instead of a
  ## `ThreadingHTTPServer` with a lock: requests are served one at a time
  ## (so two webhooks arriving together queue instead of running turns in
  ## parallel — the port's stated posture everywhere else), and the
  ## listener is closed by this proc rather than by `server_close()` in
  ## the handle.
  ##
  ## A stop cannot interrupt a blocking `accept` here (no threads to
  ## interrupt it from), so a supervisor stop lands on the next accepted
  ## request and an idle `waku whatsapp` needs a second Ctrl-C. The
  ## dashboard does not pay that: an injected `TakeConn` returns on a
  ## timeout, which is where the stop is observed.
  var owned: Socket
  if take.isNil:
    owned = newSocket()
    owned.setSockOpt(OptReuseAddr, true)
    owned.bindAddr(Port(live.port), live.host)
    owned.listen()
  logger(listeningLine(live.host, live.port))
  logger(webhookUrlLine)
  logger(ctrlCLine)
  live.running = true
  try:
    while not live.stop:
      var client: Socket
      if take.isNil:
        owned.accept(client)
      else:
        let (got, sock) = take()
        if not got:
          continue
        client = sock
      try:
        let req = readWhatsappRequest(client)
        var status = 404
        var body = "{}"
        if req.verb.len > 0:
          proc write(status: int, body: string) =
            writeWhatsappResponse(client, status, body)
          discard serveWhatsappRequest(req, verifyToken, appSecret,
            allowed, token, phoneNumberId, http, respond, logger,
            live = live, write = write)
        else:
          writeWhatsappResponse(client, status, body)
      except CatchableError:
        discard  # a client that hung up mid-request: serve the next one
      try:
        client.close()
      except CatchableError:
        discard
  except OSError as exc:
    live.running = false
    raise newException(CatchableError, exc.msg)
  finally:
    if take.isNil:
      try:
        owned.close()
      except CatchableError:
        discard
    live.running = false
