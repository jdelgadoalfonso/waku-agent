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
## The live `ThreadingHTTPServer` (bind + serve_forever + the Waku turn
## behind the lock) stays a 7d follow-up behind the honest
## `serveWhatsappWebhook` seam: always answering 200 fast (Meta disables
## flapping webhooks) is a loop property 7d will own. Every side effect
## travels through `WhatsappHttpFn`: zero sockets in tests. `waku.nim`
## keeps its phase-4e `whatsapp` stub until 7d owns the live loop.

import std/httpclient
import std/httpcore
import std/json
import std/strutils

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

# ── webhook server (7d) ───────────────────────────────────────────────

proc serveWhatsappWebhook*() =
  ## Honest seam for the live webhook server (`ThreadingHTTPServer` on
  ## port 5000 + the locked Waku turn): binding a port and serialising
  ## turns have no synchronous single-threaded equivalent here, so 7d
  ## owns them. Raises until then instead of pretending to serve.
  raise newException(CatchableError,
    "whatsapp webhook server lives in 7d " &
    "(ThreadingHTTPServer, no stdlib port yet)")
