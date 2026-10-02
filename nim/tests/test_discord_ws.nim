## Phase 7d2 tests: the Discord gateway WebSocket receive.
##
## `test_chat_gateways.nim` pinned the 7b policy and REST seams and left
## the receive half raising honestly; this file pins what replaced that
## seam: the RFC 6455 handshake and frames, masking, the identify/heartbeat
## payloads, op 10/11/1/7/9, `READY` and `MESSAGE_CREATE` parsing, the
## `on_message` policy port, and the handle the supervisor reads.
##
## Offline only. The transport is an injected `DiscordWire` (a scripted
## `recv`/`send` pair plus the client mask key), REST is a recorded
## `DiscordHttpFn`, and the clock is a counter — zero sockets, zero
## randomness, zero wall time.
##
## Split from `test_chat_gateways.nim` (7b policy, both gateways) and
## `test_live_gateways.nim` (telegram + whatsapp loops) on purpose: this
## is the gateway whose receive is a byte protocol, and pinning bytes
## deserves its own file. Call sites: `waku/gateway/discord.py`
## (`on_message`, `DiscordHandle.stop/status`, `start_in_background`)
## and the documented Discord gateway protocol (v10, JSON encoding).

import std/json
import std/sets
import std/sequtils
import std/strutils
import std/tables
import std/unittest

import ../src/discord
import ../src/gateway

# ── offline doubles ───────────────────────────────────────────────────

type
  Pump = ref object
    ## The scripted gateway socket plus everything both seams write to.
    ## `chunks` is what `recv` hands over one call at a time, so a test
    ## can pin a frame that arrives in pieces. `sent` keeps the raw
    ## client frames (decoded below with the same mask key, which is
    ## also how the tests prove the client masks its frames).
    chunks: seq[string]
    sent: seq[string]
    log: seq[string]
    turns: seq[string]
    replies: seq[string]
    maskKey: string
    status: int
    failPost: bool

proc newPump(): Pump =
  Pump(chunks: @[], sent: @[], log: @[], turns: @[], replies: @[],
    maskKey: "AaBb", status: 200, failPost: false)

proc wireOf(p: Pump): DiscordWire =
  ## The `DiscordWire` seam over the script. `recv` pops one chunk and
  ## answers `""` when the script runs dry — the same silence a closed
  ## peer gives, which is what the loop's idle counter is for.
  let recv: DiscordRecvFn = proc(timeoutMs: int): string {.closure.} =
    if p.chunks.len == 0:
      return ""
    let chunk = p.chunks[0]
    p.chunks.delete(0)
    return chunk
  let send: DiscordSendFn = proc(bytes: string): int {.closure.} =
    p.sent.add(bytes)
    return bytes.len
  newDiscordWire(recv, send, p.maskKey)

proc sentPayloads(p: Pump): seq[string] =
  ## What the client actually put on the wire, unmasked by the decoder.
  for raw in p.sent:
    result.add(decodeDiscordFrame(raw).payload)

proc loggerOf(p: Pump): LogFn =
  result = proc(line: string) {.closure.} = p.log.add(line)

proc respondOf(p: Pump, reply = "answer"): RespondFn =
  result = proc(text: string): string {.closure.} =
    p.turns.add(text)
    return reply

proc postOf(p: Pump): DiscordHttpFn =
  ## The REST seam: records the reply text, answers `status`, or raises
  ## the way `httpclient` does when the send itself fails.
  result = proc(url, payload, token: string): int {.closure.} =
    if p.failPost:
      raise newException(IOError, "connection reset")
    p.replies.add(parseJson(payload)["content"].getStr())
    return p.status

proc envOf(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (k, v) in pairs:
    result[k] = v

proc noIds(): HashSet[string] =
  initHashSet[string]()

proc idsOf(items: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  for it in items:
    result.incl(it)

proc serverFrame(payload: string): string =
  ## One unmasked text frame, the way Discord sends them (a server never
  ## masks, RFC 6455 §5.1).
  encodeDiscordFrame(opText, payload, "")

proc feed(p: Pump, payloads: openArray[string]) =
  ## Queue one server text frame per gateway payload.
  for payload in payloads:
    p.chunks.add(serverFrame(payload))

proc helloPayload(intervalMs = 41250): string =
  $(%*{"op": 10, "d": {"heartbeat_interval": intervalMs}})

proc readyPayload(botId = "123"): string =
  $(%*{"op": 0, "t": "READY", "s": 1, "d": {
    "session_id": "sess-1", "user": {"id": botId}}})

proc messagePayload(content: string, authorId = "7", channelId = "9";
    guildId = "", botId = "123"): string =
  ## A `MESSAGE_CREATE` dispatch. An empty `guildId` means a DM (the
  ## field is absent, like Discord sends it for a direct message).
  var node = %*{"op": 0, "t": "MESSAGE_CREATE", "s": 2, "d": {
    "id": "99", "content": content, "channel_id": channelId,
    "author": {"id": authorId}}}
  node["d"]["mentions"] = %*[{"id": botId}]
  if guildId.len > 0:
    node["d"]["guild_id"] = %guildId
  $node

proc liveWith(cap = 30): DiscordLive =
  ## A started, ready handle with the bot id `READY` would have filled
  ## in, so a test can pin message handling without replaying the
  ## handshake.
  result = newDiscordLive("discord", cap)
  result.botId = "123"
  result.running = true
  result.ready = true

# ── the handshake (RFC 6455 §4.1, Discord v10) ────────────────────────

suite "phase 7d2 discord handshake":
  test "the upgrade request carries key, version, host and bot token":
    let req = discordHandshake("tok123", "dGhlIHNhbXBsZSBub25jZQ==")
    let lines = req.split("\r\n")
    check lines[0] == "GET /?v=10&encoding=json HTTP/1.1"
    check "Host: gateway.discord.gg" in lines
    check "Upgrade: websocket" in lines
    check "Connection: Upgrade" in lines
    check "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" in lines
    check "Sec-WebSocket-Version: 13" in lines
    check "Authorization: Bot tok123" in lines
    check "User-Agent: DiscordBot" in req
    check req.endsWith("\r\n\r\n")

  test "a 101 with an accept header opens the socket":
    check discordHandshakeFault("HTTP/1.1 101 Switching Protocols\r\n" &
      "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
      "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n") == ""

  test "a refused upgrade names the status without the token":
    let fault = discordHandshakeFault("HTTP/1.1 401 Unauthorized\r\n" &
      "WWW-Authenticate: Bot\r\n\r\n")
    check "401 Unauthorized" in fault
    check "tok123" notin fault

  test "an upgrade without the accept header is not a websocket":
    check "Sec-WebSocket-Accept" in
      discordHandshakeFault("HTTP/1.1 101 Switching Protocols\r\n" &
        "Upgrade: websocket\r\n\r\n")
    check discordHandshakeFault("") != ""
    check discordHandshakeFault("garbage") != ""

  test "the generated key is 16 random bytes in base64":
    let key = newDiscordKey()
    check key.len == 24
    check key != newDiscordKey()

# ── frames (RFC 6455 §5) ──────────────────────────────────────────────

suite "phase 7d2 discord frames":
  test "the RFC's masked Hello frame unmasks to Hello":
    let frame = decodeDiscordFrame(
      "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58")
    check frame.fin
    check frame.opcode == opText
    check frame.masked
    check frame.payload == "Hello"

  test "the RFC's unmasked Hello frame needs no key":
    let frame = decodeDiscordFrame("\x81\x05\x48\x65\x6c\x6c\x6f")
    check not frame.masked
    check frame.payload == "Hello"
    # only the bytes the header declares are read, trailing bytes wait
    check decodeDiscordFrame("\x81\x05\x48\x65\x6c\x6c\x6fNEXT").payload ==
      "Hello"

  test "a client frame masks its payload and round-trips":
    let raw = encodeDiscordFrame(opText, "hello there", "AaBb")
    check (ord(raw[1]) and 0x80) != 0    # MASK set, as a client must
    let frame = decodeDiscordFrame(raw)
    check frame.opcode == opText
    check frame.masked
    check frame.payload == "hello there"
    check encodeDiscordFrame(opText, "x", "").len == 3  # 2 header + 1 byte

  test "the mask is its own inverse and needs four bytes":
    check applyDiscordMask(applyDiscordMask("abc", "AaBb"), "AaBb") == "abc"
    check applyDiscordMask("", "AaBb") == ""
    try:
      discard applyDiscordMask("abc", "short")
      assert false, "must raise"
    except ValueError:
      discard

  test "the size probe tells the reader how long to wait":
    check discordFrameSize("") == -1
    check discordFrameSize("\x81") == -1
    check discordFrameSize("\x81\x05") == 7
    check discordFrameSize("\x81\x85") == -1       # mask key not in yet
    # 2 header + 4 mask key + 5 payload
    let masked = "\x81\x85\x41\x41\x42\x42\x48\x65\x6c\x6c\x6f"
    check discordFrameSize(masked) == 11
    let medium = encodeDiscordFrame(opText, repeat("x", 300), "AaBb")
    check discordFrameSize(medium) == medium.len
    check discordFrameSize(medium[0 ..< 3]) == -1   # 126 header incomplete
    let huge = encodeDiscordFrame(opText, repeat("x", 70000), "")
    check discordFrameSize(huge) == huge.len
    check discordFrameSize(huge[0 ..< 9]) == -1    # 127 header incomplete

  test "a truncated frame refuses to decode":
    try:
      discard decodeDiscordFrame("\x81\x05abc")
      assert false, "must raise"
    except ValueError:
      discard

  test "continuation and binary frames carry their payload":
    let cont = decodeDiscordFrame(encodeDiscordFrame(opContinuation, "more",
      "", fin = false))
    check not cont.fin
    check cont.opcode == opContinuation
    check cont.payload == "more"
    check decodeDiscordFrame(encodeDiscordFrame(opBinary, "b", "")).opcode ==
      opBinary

# ── identify, hello, heartbeat (ops 2, 10, 1, 11) ─────────────────────

suite "phase 7d2 discord payload ops":
  test "identify is op 2 with the token, the intents and the properties":
    let node = parseJson(discordIdentify("tok123"))
    check node["op"].getInt == gatewayIdentify
    check node["d"]["token"].getStr == "tok123"
    check node["d"]["intents"].getInt == discordMessageContentIntent
    check discordMessageContentIntent == 32768   # 1 shl 15, message content
    check node["d"]["properties"].hasKey("os")
    check node["d"]["properties"].hasKey("browser")
    check node["d"]["properties"].hasKey("device")

  test "the heartbeat payload is op 1 carrying the sequence number":
    let node = parseJson(discordHeartbeat(7))
    check node["op"].getInt == gatewayHeartbeat
    check node["d"].getInt == 7

  test "op 10 hands over the heartbeat interval":
    let p = newPump()
    feed(p, [helloPayload()])
    let live = liveWith()
    let event = receiveDiscordEvent(live, wireOf(p))
    check event.kind == deHello
    check event.intervalMs == 41250
    check live.heartbeatMs == 41250

  test "the cadence asks for a heartbeat once the interval elapsed":
    let live = newDiscordLive()
    check not discordHeartbeatDue(live, 0.0)     # no HELLO yet
    live.heartbeatMs = 1000
    live.lastHeartbeat = 10.0
    check not discordHeartbeatDue(live, 10.5)
    check discordHeartbeatDue(live, 11.0)
    check discordHeartbeatDue(live, 99.0)

  test "an unreadable payload is ignored, not fatal":
    let p = newPump()
    p.chunks.add(serverFrame("{not json"))
    p.chunks.add(serverFrame(""))
    p.chunks.add(serverFrame("[1,2]"))
    p.chunks.add(serverFrame("""{"d":null}"""))
    let live = liveWith()
    let wire = wireOf(p)
    for _ in 0 .. 3:
      check receiveDiscordEvent(live, wire).kind == deNone
    check not parseDiscordPayload("[1,2]").ok
    check not parseDiscordPayload("""{"d":null}""").ok
    check parseDiscordPayload("""{"op":0}""").ok

  test "a binary frame is ignored and answered with nothing":
    let p = newPump()
    p.chunks.add(encodeDiscordFrame(opBinary, """{"op":11}""", ""))
    let event = receiveDiscordEvent(liveWith(), wireOf(p))
    check event.kind == deNone
    check event.detail == "ignored opcode 2"
    check p.sent.len == 0

  test "the refusal a person can act on is Python's own wording":
    check discordMissingTokenLine ==
      "Set DISCORD_BOT_TOKEN in .env (create a bot in the Discord Developer " &
      "Portal)."

# ── the receive loop ───────────────────────────────────────────────────

suite "phase 7d2 discord receive":
  test "hello, READY and MESSAGE_CREATE arrive as three events":
    let p = newPump()
    feed(p, [helloPayload(), readyPayload(), messagePayload("hi")])
    let live = liveWith()
    let wire = wireOf(p)
    var events: seq[DiscordEvent] = @[]
    for _ in 0 .. 2:
      events.add(receiveDiscordEvent(live, wire))
    check events[0].kind == deHello
    check events[1].kind == deReady
    check events[2].kind == deMessage
    check events[2].message.content == "hi"
    check live.botId == "123"
    check live.sessionId == "sess-1"
    check live.seq == 2
    # the script is dry now, which is a tick and not an error
    check receiveDiscordEvent(live, wire).kind == deTimeout

  test "READY is what makes the handle report connected":
    let p = newPump()
    feed(p, [readyPayload("999")])
    let live = newDiscordLive()
    live.running = true
    check discordStatus(live).message == "starting"
    check receiveDiscordEvent(live, wireOf(p)).kind == deReady
    check live.botId == "999"
    check discordStatus(live).ok

  test "a message is parsed with its dm flag, ids and mention":
    let p = newPump()
    let msg = parseDiscordPayload(messagePayload("<@123> hi",
      authorId = "7", channelId = "9"))
    check msg.op == gatewayDispatch
    check msg.seq == 2
    check msg.name == "MESSAGE_CREATE"
    let dm = parseDiscordMessage(msg.data, "123")
    check dm.id == "99"
    check dm.authorId == "7"
    check dm.channelId == "9"
    check dm.content == "<@123> hi"
    check dm.mentioned
    check dm.isDm           # no guild_id
    # a channel message has a guild, and mentions only another user
    let guild = parseDiscordPayload(messagePayload("hi", guildId = "55",
      botId = "999")).data
    let channel = parseDiscordMessage(guild, "123")
    check not channel.isDm
    check not channel.mentioned

  test "both mention forms count, another user's ping does not":
    check parseDiscordMessage(parseDiscordPayload(
      messagePayload("<@!123> yo")).data, "123").mentioned
    check not parseDiscordMessage(parseDiscordPayload(
      messagePayload("<@999> yo", botId = "999")).data, "123").mentioned

  test "the mentions array decides when there is one":
    var node = parseDiscordPayload(messagePayload("no ping here")).data
    node["mentions"] = %*[{"id": "123"}]
    check parseDiscordMessage(node, "123").mentioned
    node["mentions"] = %*[{"id": "999"}]
    check not parseDiscordMessage(node, "123").mentioned

  test "a ping is answered with a masked pong carrying the payload":
    let p = newPump()
    p.chunks.add(encodeDiscordFrame(opPing, "ping-1", "", fin = false))
    let event = receiveDiscordEvent(liveWith(), wireOf(p))
    check event.kind == deNone
    check p.sent.len == 1
    check decodeDiscordFrame(p.sent[0]).opcode == opPong
    check decodeDiscordFrame(p.sent[0]).payload == "ping-1"

  test "a close frame is echoed and ends the stream":
    let p = newPump()
    p.chunks.add(encodeDiscordFrame(opClose, "\x03\xe8bye", ""))
    let live = liveWith()
    let event = receiveDiscordEvent(live, wireOf(p))
    check event.kind == deClosed
    check "bye" in event.detail
    check not live.ready
    check decodeDiscordFrame(p.sent[0]).opcode == opClose

  test "nothing within the timeout is a tick, not an error":
    let p = newPump()
    let live = liveWith()
    let event = receiveDiscordEvent(live, wireOf(p), timeoutMs = 1)
    check event.kind == deTimeout
    check live.running                      # still alive, still ready
    check discordStatus(live).ok

  test "a frame split over two reads still decodes":
    let p = newPump()
    let whole = serverFrame("""{"op":11,"d":null}""")
    p.chunks.add(whole[0 .. 3])
    p.chunks.add(whole[4 .. ^1])
    check receiveDiscordEvent(liveWith(), wireOf(p)).kind == deAck

  test "two frames in one read are read one at a time":
    let p = newPump()
    p.chunks.add(serverFrame("""{"op":11}""") & serverFrame("""{"op":11}"""))
    let live = liveWith()
    let wire = wireOf(p)
    check receiveDiscordEvent(live, wire).kind == deAck
    check receiveDiscordEvent(live, wire).kind == deAck

  test "op 11 acks and op 1 asks for a heartbeat":
    let p = newPump()
    feed(p, ["""{"op":11,"d":null}""", """{"op":1,"d":9}"""])
    let live = liveWith()
    live.seq = 9
    let wire = wireOf(p)
    let ack = receiveDiscordEvent(live, wire)
    check ack.kind == deAck
    check live.acked
    check receiveDiscordEvent(live, wire).kind == deHeartbeat
    check p.sentPayloads().len == 0   # the run loop owns sending

  test "op 7 and op 9 surface without touching the socket":
    let p = newPump()
    feed(p, ["""{"op":7}""", """{"op":9,"d":true}""",
      """{"op":9,"d":false}"""])
    let live = liveWith()
    let wire = wireOf(p)
    check receiveDiscordEvent(live, wire).kind == deReconnect
    check receiveDiscordEvent(live, wire).detail == "resumable"
    check receiveDiscordEvent(live, wire).detail == "new session"
    check p.sent.len == 0

  test "an unknown dispatch is ignored and the sequence still moves":
    let p = newPump()
    feed(p, ["""{"op":0,"t":"TYPING_START","s":5}"""])
    let live = liveWith()
    let event = receiveDiscordEvent(live, wireOf(p))
    check event.kind == deNone
    check event.detail == "TYPING_START"
    check live.seq == 5

  test "a stop asked for before the read is honoured":
    let p = newPump()
    let live = liveWith()
    live.stop = true
    check receiveDiscordEvent(live, wireOf(p)).kind == deStopped
    check p.chunks.len == 0 and p.sent.len == 0

# ── on_message (discord.py:141-164) ───────────────────────────────────

suite "phase 7d2 discord message handling":
  proc handle(live: DiscordLive, p: Pump, msg: DiscordMessage, users,
      channels: HashSet[string], requireMention = true,
      now = 1000.0): bool =
    ## One message through `discordHandleMessage`. The handle comes IN,
    ## not out: the hourly cap is state, so a test that pins it has to
    ## keep the same connection across two messages.
    discordHandleMessage(live, msg, postOf(p), "tok123", users, channels,
      requireMention, respondOf(p), loggerOf(p), now)

  test "an allowlisted DM runs one turn and posts the reply":
    let p = newPump()
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "hi there", isDm: true)
    check handle(liveWith(), p, msg, idsOf(["7"]), noIds())
    check p.turns == ["hi there"]
    check p.replies == ["answer"]
    check p.log == ["you › hi there", "waku › answer"]

  test "an unallowlisted channel is silent, not a refusal":
    let p = newPump()
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "<@123> hi", mentioned: true)
    check not handle(liveWith(), p, msg, noIds(), noIds())
    check p.turns.len == 0
    check p.replies.len == 0

  test "the mention is stripped before the model sees it":
    let p = newPump()
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "<@!123> what is up", mentioned: true)
    check handle(liveWith(), p, msg, noIds(), idsOf(["9"]))
    check p.turns == ["what is up"]

  test "an unmentioned channel message is the operator's choice":
    let p = newPump()
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "hi there")
    check not handle(liveWith(), p, msg, noIds(), idsOf(["9"]))
    check p.turns.len == 0
    check handle(liveWith(), p, msg, noIds(), idsOf(["9"]),
      requireMention = false)
    check p.turns == ["hi there"]

  test "the bot's own message and an empty message are ignored":
    let p = newPump()
    let live = liveWith()
    check not handle(live, p, DiscordMessage(id: "1", authorId: "123",
      channelId: "9", content: "echo", isDm: true), noIds(), noIds())
    check not handle(live, p, DiscordMessage(id: "2", authorId: "7",
      channelId: "9", content: "", isDm: true), noIds(), noIds())
    # a mention-only message strips to nothing, so no turn either
    check not handle(live, p, DiscordMessage(id: "3", authorId: "7",
      channelId: "9", content: "<@123> ", mentioned: true), noIds(),
      idsOf(["9"]))
    check p.turns.len == 0

  test "the hourly cap goes silent with the exact line":
    let p = newPump()
    let live = liveWith(cap = 1)
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "hi", isDm: true)
    check handle(live, p, msg, noIds(), noIds(), now = 10.0)
    check not handle(live, p, msg, noIds(), noIds(), now = 11.0)
    check p.turns.len == 1
    check p.log[^1] == discordBudgetSpentLine & "7"

  test "the cap window rolls over after an hour":
    let p = newPump()
    let live = liveWith(cap = 1)
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "hi", isDm: true)
    check handle(live, p, msg, noIds(), noIds(), now = 10.0)
    check not handle(live, p, msg, noIds(), noIds(), now = 11.0)
    check handle(live, p, msg, noIds(), noIds(), now = 3711.0)
    check p.turns.len == 2

  test "a failed turn is recorded on the runner as message handling":
    let p = newPump()
    let live = liveWith()
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "hi", isDm: true)
    let respond: RespondFn =
      proc(text: string): string {.closure.} =
        raise newException(ValueError, "model exploded")
    check not discordHandleMessage(live, msg, postOf(p), "tok123", noIds(),
      noIds(), true, respond, loggerOf(p), 1.0,
      envOf([("DISCORD_BOT_TOKEN", "tok123")]))
    check p.replies == [gatewayErrorReply]
    check live.runner.errorStatus ==
      "message handling failed (ValueError) — see dashboard terminal"
    check not discordStatus(live).ok

  test "a failed delivery is recorded as reply delivery":
    let p = newPump()
    p.failPost = true
    let live = liveWith()
    let msg = DiscordMessage(id: "99", authorId: "7", channelId: "9",
      content: "hi", isDm: true)
    check not discordHandleMessage(live, msg, postOf(p), "tok123", noIds(),
      noIds(), true, respondOf(p), loggerOf(p), 1.0)
    check live.runner.errorStatus ==
      "reply delivery failed (IOError) — see dashboard terminal"

# ── the handle (discord.py:212-283) ────────────────────────────────────

suite "phase 7d2 discord handle":
  test "status follows the four states of Python's handle":
    check discordStatus(nil).message == "gateway stopped unexpectedly"
    let stopped = newDiscordLive()
    check not discordStatus(stopped).ok
    let starting = newDiscordLive()
    starting.running = true
    check discordStatus(starting).message == "starting"
    discard starting.runner.recordError("ValueError", "boom", initTable[string,
      string](), "message handling")
    check discordStatus(starting).message ==
      "message handling failed (ValueError) — see dashboard terminal"
    let ready = newDiscordLive()
    ready.running = true
    ready.ready = true
    check discordStatus(ready).ok

  test "stop retires the runner and stays safe on a nil handle":
    let live = newDiscordLive()
    live.running = true
    live.ready = true
    discordStop(live)
    check live.stop
    check not live.running
    check not live.ready
    check live.runner.closed
    discordStop(nil)   # must not raise

  test "the starter declines without a token and re-arms with one":
    let live = newDiscordLive()
    let start = discordStarter(live, envOf([]))
    check not start()
    check not live.running
    let withToken = discordStarter(live,
      envOf([("DISCORD_BOT_TOKEN", "tok123")]))
    check withToken()
    check live.running
    check not live.ready
    check live.runner.errorStatus.len == 0
    # a restart is a fresh session: stale ids, cap and errors do not survive
    live.botId = "999"
    live.sessionId = "old"
    live.heartbeatMs = 41250
    live.budget = newDiscordBudget(1)
    discard live.budget.budgetAllow(1.0)
    discard live.runner.recordError("ValueError", "boom",
      initTable[string, string](), "message handling")
    check withToken()
    check live.botId == ""
    check live.sessionId == ""
    check live.heartbeatMs == 0
    check live.budget.turns.len == 0

  test "the starter reads the cap, and garbage raises like Python int()":
    let live = newDiscordLive()
    discard discordStarter(live,
      envOf([("DISCORD_BOT_TOKEN", "t"), ("DISCORD_MAX_TURNS_PER_HOUR",
      "5")]))()
    check live.budget.perHour == 5
    try:
      discard discordStarter(live, envOf([("DISCORD_BOT_TOKEN", "t"),
        ("DISCORD_MAX_TURNS_PER_HOUR", "many")]))()
      assert false, "must raise"
    except ValueError:
      discard

  test "the supervisor adapters read and stop the one handle":
    let live = newDiscordLive()
    let status = discordStatusFn(live)
    let stop = discordStopFn(live)
    live.running = true
    live.ready = true
    check status("discord").ok
    stop("discord")
    check not status("discord").ok

  test "a stopped handle restarts, because a supervisor reloads it":
    let live = newDiscordLive()
    let start = discordStarter(live,
      envOf([("DISCORD_BOT_TOKEN", "tok123")]))
    check start()
    discordStop(live)
    check not live.running
    check live.runner.closed
    check start()
    check not live.stop
    check live.running
    check not live.runner.closed   # a fresh runner, or no turn can run
    check live.budget.turns.len == 0

suite "phase 7d2 discord run loop":
  proc runLoop(p: Pump, users, channels: HashSet[string],
      maxIdleTicks = 3): DiscordLive =
    ## The blocking loop over a scripted transport, driven by a clock
    ## that never moves: heartbeats therefore fire once and then wait,
    ## which is exactly what a cadence pin needs to be stable.
    let live = liveWith()
    live.running = false        # the starter's answer, not a running loop
    live.heartbeatMs = 1000
    let clock: DiscordNowFn = proc(): float = 0.0
    discordRun(live, wireOf(p), "tok123", postOf(p), users, channels, true,
      respondOf(p), loggerOf(p), envOf([("DISCORD_HOME", "/bot/.waku")]),
      now = clock, maxIdleTicks = maxIdleTicks)
    return live

  test "the startup lines come first, then hello answers with identify":
    let p = newPump()
    p.chunks.add(serverFrame(helloPayload(1000)))
    feed(p, [readyPayload(), messagePayload("hi", authorId = "7")])
    discard runLoop(p, noIds(), noIds())
    check p.log[0] == discordListeningLine
    check p.log[1] == describePosture(noIds(), noIds(), "/bot/.waku", "30")
    let texts = p.sentPayloads()
    check parseJson(texts[0])["op"].getInt == gatewayIdentify
    check parseJson(texts[0])["d"]["token"].getStr == "tok123"
    check parseJson(texts[1])["op"].getInt == gatewayHeartbeat
    check parseJson(texts[1])["d"].getInt == 0
    # the message ran one turn; then the scripted socket went quiet
    check p.turns == ["hi"]

  test "a silent socket stops the loop instead of spinning forever":
    let p = newPump()
    discard runLoop(p, noIds(), noIds(), maxIdleTicks = 2)
    check p.log[^1] == discordQuietLine
    check p.turns.len == 0

  test "a close frame ends the loop with the socket line":
    let p = newPump()
    p.chunks.add(encodeDiscordFrame(opClose, "", ""))
    let live = runLoop(p, noIds(), noIds())
    check discordQuietLine != p.log[^1]
    check p.log[^1].startsWith(discordSocketClosedLine)
    check not live.running
    check discordStatus(live).message == "gateway stopped unexpectedly"
    check live.runner.closed

  test "a reconnect request ends the run for the transport to re-dial":
    let p = newPump()
    p.chunks.add(serverFrame("""{"op":7}"""))
    let live = runLoop(p, noIds(), noIds())
    check p.log[^1] == discordReconnectLine
    check not live.running

  test "the cadence keeps beating between events":
    let p = newPump()
    let live = liveWith()
    live.heartbeatMs = 1000
    var now = 100.0
    let clock: DiscordNowFn = proc(): float = now
    # no events queued: the loop beats, then the idle counter stops it
    discordRun(live, wireOf(p), "tok123", postOf(p), noIds(), noIds(), true,
      respondOf(p), loggerOf(p), now = clock, maxIdleTicks = 1)
    check parseJson(p.sentPayloads()[0])["op"].getInt == gatewayHeartbeat
    check live.running == false
# ── the dial seam and the command loop (7d2-2) ────────────────────────

suite "phase 7d2 discord dial":
  test "the live dial refuses honestly instead of pretending to connect":
    # The one thing this port cannot do: `wss://gateway.discord.gg` needs
    # TLS, and Nim ships TLS as a separate package (`ssl`, OpenSSL) that
    # rule 3 keeps out of this build. There is no socket here — the
    # refusal is a value, which is why it is pinnable offline.
    let (ok, wire, why) = liveDiscordWire("tok123")
    check not ok
    check wire.isNil
    check why == discordTlsMissingLine
    check "wss://" & discordGatewayHost in why
    check "ssl" in why       # names the missing piece, not just a failure

suite "phase 7d2 discord serve loop":
  proc scriptedDial(p: Pump, why = ""): DiscordDialFn =
    ## A dial that answers with a scripted transport instead of a socket:
    ## a `why` makes it refuse, an empty one opens a wire over the pump.
    proc(token: string): (bool, DiscordWire, string) {.closure.} =
      p.log.add("dial " & token)
      if why.len > 0:
        return (false, nil, why)
      return (true, wireOf(p), "")

  test "a refused dial says its line once and exits 1":
    let p = newPump()
    let dial = scriptedDial(p, "(discord) no route to the gateway")
    let live = liveWith()
    live.running = false
    check discordServe(live, "tok123", respondOf(p), loggerOf(p), envOf([]),
      postOf(p), dial) == 1
    check p.log == ["dial tok123", "(discord) no route to the gateway"]

  test "a refused dial is the same refusal every time, so it is not retried":
    # One line, not `maxDials` of them: the reason names the gap, and a
    # hot retry would bury it.
    let p = newPump()
    let live = liveWith()
    live.running = false
    discard discordServe(live, "tok123", respondOf(p), loggerOf(p),
      envOf([]), postOf(p), scriptedDial(p, "no tls"), maxDials = 5)
    check p.log.filterIt(it == "no tls").len == 1

  test "a run that ends without a stop dials again, up to maxDials":
    let p = newPump()
    let dial = scriptedDial(p)   # each wire goes quiet after 1 tick
    let live = liveWith()
    live.running = false
    live.heartbeatMs = 1000
    check discordServe(live, "tok123", respondOf(p), loggerOf(p),
      envOf([("DISCORD_ALLOWED_USER", "7")]), postOf(p), dial,
      maxDials = 3) == 0
    check p.log.filterIt(it == "dial tok123").len == 3
    check p.log.filterIt(it == discordQuietLine).len == 3  # each run said why
    check p.turns.len == 0                     # no message ever arrived

  test "a stop asked before the first dial opens no socket at all":
    let p = newPump()
    let live = liveWith()
    live.running = false
    discordStop(live)
    check discordServe(live, "tok123", respondOf(p), loggerOf(p), envOf([]),
      postOf(p), scriptedDial(p)) == 0
    check p.log.len == 0

  test "the policy reaches the loop from env, like _build_client reads it":
    # A server message from an ALLOWLISTED user in a channel that is NOT
    # allowlisted is silent (the deny-by-default line), so the run ends
    # without a turn — which is only true if `discordServe` handed the
    # env's ids down to the loop.
    let p = newPump()
    p.chunks.add(serverFrame(helloPayload(1000)))
    p.chunks.add(serverFrame(readyPayload()))
    p.chunks.add(serverFrame(messagePayload("hi", authorId = "7",
      guildId = "42")))
    let dial = scriptedDial(p)
    let live = liveWith()
    live.running = false
    live.heartbeatMs = 1000
    discard discordServe(live, "tok123", respondOf(p), loggerOf(p),
      envOf([("DISCORD_ALLOWED_USER", "7"), ("DISCORD_REQUIRE_MENTION", "1")]),
      postOf(p), dial, maxDials = 1)
    check p.turns.len == 0
    # the same message in a DM is answered, so the silence above was the
    # channel policy and not a dead turn
    let q = newPump()
    q.chunks.add(serverFrame(helloPayload(1000)))
    q.chunks.add(serverFrame(readyPayload()))
    q.chunks.add(serverFrame(messagePayload("hi", authorId = "7")))
    let live2 = liveWith()
    live2.running = false
    live2.heartbeatMs = 1000
    discard discordServe(live2, "tok123", respondOf(q), loggerOf(q),
      envOf([("DISCORD_ALLOWED_USER", "7")]), postOf(q), scriptedDial(q),
      maxDials = 1)
    check q.turns == ["hi"]

  test "a re-dial is a fresh session, so the second connection can answer":
    # `discordRun` retires the runner on the way out (`finally:
    # runner.close()`), so without a re-arm between connections the next
    # message would hit "discord gateway runner is closed" and take the
    # command down. The env's spend cap lands on the same re-arm.
    let p = newPump()
    p.chunks.add(serverFrame(helloPayload(1000)))
    p.chunks.add(serverFrame(readyPayload()))
    p.chunks.add(serverFrame(messagePayload("second", authorId = "7")))
    let live = liveWith()
    live.running = false
    live.heartbeatMs = 1000
    discard discordServe(live, "tok123", respondOf(p), loggerOf(p),
      envOf([("DISCORD_MAX_TURNS_PER_HOUR", "7")]), postOf(p),
      scriptedDial(p), maxDials = 2)
    check p.turns == ["second"]
    check p.replies == ["answer"]        # the reply landed in the channel
    check live.budget.perHour == 7
