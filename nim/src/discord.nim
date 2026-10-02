## Discord gateway, phase 7b — access policy + REST send seam,
## phase 7d2 — the gateway WebSocket receive and the command loop.
##
## Port of the testable core of `waku/gateway/discord.py`: `should_answer`
## (deny-by-default: an empty channel allowlist answers NO channel),
## `_strip_mention` (`<@id>`/`<@!id>`), `TurnBudget` (hourly ceiling with
## `now` as a parameter), `describe_posture` (four lines, verbatim), and
## the send path as an injected REST seam (`POST
## /channels/{id}/messages` with `Authorization: Bot …`).
##
## 7d2 replaces the honest 7b seam (`receiveDiscordEvent`, which raised
## "the gateway WebSocket receive lives in 7d") with the receive itself,
## hand-rolled on stdlib the way the Telegram Bot API and MCP wire were:
## the RFC 6455 opening handshake, frames with masking, the Discord
## gateway payloads (op 10 `HELLO`, op 2 `IDENTIFY`, op 1 `HEARTBEAT`,
## op 11 ack, op 7/9 reconnect, and `MESSAGE_CREATE`), the `on_message`
## policy port and the handle the supervisor reads (`discordStatus` /
## `discordStop` plus the three adapters), plus 7d2-2's dial seam and the
## `waku discord` command loop.
##
## No SDK exists for Nim and rule 3 forbids new dependencies, so there is
## no `discord.py`-style client object here: every byte travels through
## an injected `DiscordWire` (`recv`/`send` plus the client mask key),
## every REST call through `DiscordHttpFn`, and `env` is a `Table` — zero
## sockets, zero randomness and zero wall time in tests. This module
## owns the protocol, not the dial: `liveDiscordWire` (7d2-2) is where
## the encrypted socket would be opened, and it refuses honestly today,
## because Nim ships TLS separately (`ssl`, OpenSSL) and rule 3 keeps
## that package out; `discordServe` is the `waku discord` command loop,
## which dials, runs and re-dials.
##
## Two documented divergences: the port does not recompute the
## `Sec-WebSocket-Accept` digest (SHA-1 is deprecated in stdlib — see
## `discordHandshakeFault`), and zlib-stream compression is not
## implemented (Discord accepts its absence; `IDENTIFY` sends no
## `compress` flag).

import std/base64
import std/httpclient
import std/httpcore
import std/json
import std/random
import std/sets
import std/strutils
import std/tables
import std/times

import ./gateway

const discordEnvFields* = ["DISCORD_BOT_TOKEN", "DISCORD_ALLOWED_USER",
  "DISCORD_ALLOWED_CHANNEL", "DISCORD_REQUIRE_MENTION",
  "DISCORD_MAX_TURNS_PER_HOUR", "DISCORD_HOME"]
  ## Supervisor fields for 7d (token first: `isConfigured` reads the
  ## first field as the token, same precedent as telegram). Port of the
  ## six `os.getenv` names in `discord.py`.

const
  discordListeningLine* = "Waku is listening on Discord. Ctrl-C to stop."
    ## `main`'s one-line banner, verbatim, printed before the posture —
    ## exactly where Python prints both.
  discordMissingTokenLine* = "Set DISCORD_BOT_TOKEN in .env " &
    "(create a bot in the Discord Developer Portal)."
    ## `main`'s refusal when the token is unset, verbatim. The dispatch
    ## (7d2-2) prints it; the starter only declines.
  discordBudgetSpentLine* = "(discord) hourly turn budget spent — ignoring "
    ## `on_message`'s one budget line, verbatim but for the author: Python
    ## interpolates the message object, the port the author id.
  discordSocketClosedLine* = "(discord) gateway socket closed: "
    ## What a closed socket prints on the way out (Python's client logs
    ## this inside the library; the port owns its own socket here).
  discordReconnectLine* = "(discord) gateway asked us to reconnect: "
    ## op 7 or op 9 — this run ends and the caller re-dials.
  discordQuietLine* = "(discord) gateway went quiet — stopping"
    ## The transport stopped answering. Python's client reconnects on its
    ## own; a single-threaded port stops and lets the caller decide.

# ── allowlist parsing ─────────────────────────────────────────────────

proc parseDiscordIds*(raw: string): HashSet[string] =
  ## Port of `_ids`: comma-split, trimmed, blanks dropped. Empty means
  ## an empty set — and for CHANNELS that means no channel, not every
  ## channel (the load-bearing line of `should_answer`). Twin of
  ## `parseAllowedIds` in `telegram.nim`, duplicated like Python
  ## duplicates `_ids`/`_allowed_ids` per gateway file, so each gateway
  ## module stays self-contained.
  result = initHashSet[string]()
  for part in raw.split(','):
    let id = part.strip()
    if id.len > 0:
      result.incl(id)

proc parseRequireMention*(raw: string): bool =
  ## Port of the `DISCORD_REQUIRE_MENTION` read: everything except `""`
  ## and `"0"` (after strip) requires the @-mention. Callers pass `"1"`
  ## when the var is unset (Python's default).
  raw.strip() notin ["", "0"]

proc parseTurnCap*(raw: string): int =
  ## Port of `int(os.getenv("DISCORD_MAX_TURNS_PER_HOUR", "30"))`:
  ## garbage raises `ValueError`, like Python's `int()`.
  parseInt(raw.strip())

# ── access policy ─────────────────────────────────────────────────────

proc shouldAnswer*(isDm: bool, authorId, channelId: string, mentioned: bool,
    allowedUsers, allowedChannels: HashSet[string],
    requireMention: bool): bool =
  ## The whole access policy as one pure function (port of
  ## `should_answer`, deny-by-default at every branch): a user allowlist
  ## excludes strangers everywhere; DMs are then answered; channels only
  ## when explicitly allowlisted AND (@-mentioned OR mentions waived).
  if allowedUsers.len > 0 and authorId notin allowedUsers:
    return false
  if isDm:
    return true
  if channelId notin allowedChannels:
    return false
  return mentioned or not requireMention

proc stripMention*(content, botId: string): string =
  ## Drop the `@Waku` ping so the model sees the question, not the ping
  ## (port of `_strip_mention`: both `<@id>` and `<@!id>` forms).
  content.replace("<@" & botId & ">", " ").replace("<@!" & botId & ">",
    " ").strip()

# ── spend stop ─────────────────────────────────────────────────────────

type DiscordBudget* = object
  ## Port of `TurnBudget`: a hard ceiling on agent turns per rolling
  ## hour, across every user. At the limit the bot goes SILENT (the
  ## caller drops the message), because even an error reply invites
  ## another billed turn.
  perHour*: int
  turns*: seq[float]

proc newDiscordBudget*(perHour: int): DiscordBudget =
  ## A fresh ceiling: no turns spent yet.
  DiscordBudget(perHour: perHour, turns: @[])

proc budgetAllow*(b: var DiscordBudget, now: float): bool =
  ## Port of `TurnBudget.allow`: prune turns older than an hour, refuse
  ## past the cap, else record and allow. Divergence: `now` is required
  ## (Python defaults it to `time.time()`) — the live loop passes
  ## `epochTime()`, tests pin it, so the ceiling stays deterministic.
  var fresh: seq[float] = @[]
  for t in b.turns:
    if now - t < 3600:
      fresh.add(t)
  b.turns = fresh
  if b.turns.len >= b.perHour:
    return false
  b.turns.add(now)
  return true

# ── posture ───────────────────────────────────────────────────────────

proc describePosture*(users, channels: HashSet[string], home,
    cap: string): string =
  ## Who can reach this bot and whose memory it uses, printed at startup
  ## (port of `describe_posture`, four lines verbatim: a silent default
  ## is how a bot ends up answering a whole server unnoticed). Pure
  ## parameters instead of `os.getenv` reads (precedent: telegram's
  ## `posture`); the caller resolves `""` home to the personal-memory
  ## line and an unset cap to `"30"`.
  let who = if users.len > 0: $users.len & " allowlisted user(s)"
            else: "anyone who can DM it"
  let where = if channels.len > 0:
      $channels.len & " allowlisted channel(s), @mention required"
    else: "DMs only — no server channel will be answered"
  let mem = if home.len > 0: home else: ".waku — YOUR personal memory"
  "  reachable by: " & who & "\n" &
    "  answers in:   " & where & "\n" &
    "  memory:       " & mem & "\n" &
    "  spend cap:    " & cap & " turns/hour"

# ── REST send seam ────────────────────────────────────────────────────

type DiscordHttpFn* = proc(url, payload, token: string): int {.closure.}
  ## One Discord REST call: full URL + JSON payload + bot token → HTTP
  ## status. The token travels separately so the live adapter sets it as
  ## an `Authorization: Bot …` header (never in the URL, unlike
  ## Telegram's path token). Raises on transport failure, like
  ## `httpclient`; tests inject recorded statuses.

proc discordMessageUrl*(channelId: string): string =
  ## The channel-message endpoint both the library and this seam post to.
  "https://discord.com/api/v10/channels/" & channelId & "/messages"

proc buildDiscordBody*(text: string): JsonNode =
  ## The message JSON body (`content` carries the reply text).
  %*{"content": text}

proc sendDiscordText*(http: DiscordHttpFn, token, channelId,
    text: string): bool =
  ## Deliver one reply through `POST /channels/{id}/messages`. `true`
  ## on 2xx; a 4xx/5xx reads as a delivery outcome (`false`, like
  ## telegram's `ok:false`), while transport failures propagate to
  ## `runGatewayTurn` as `reply delivery` (see `gateway.nim`).
  http(discordMessageUrl(channelId), $buildDiscordBody(text),
    token) in 200 .. 299

proc liveDiscordPost*(url, payload, token: string): int =
  ## The real Discord REST call over `std/httpclient`. Real socket —
  ## never called in tests (they inject `DiscordHttpFn` fakes).
  var client = newHttpClient(timeout = 15000)
  try:
    client.headers = newHttpHeaders([("Content-Type", "application/json"),
      ("Authorization", "Bot " & token)])
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

# ── gateway constants (7d2) ───────────────────────────────────────────

const
  discordGatewayHost* = "gateway.discord.gg"
    ## The gateway host the v10 handshake asks for.
  discordApiVersion* = 10
    ## The gateway query version (`?v=10&encoding=json`). API v8 moved
    ## intents out of the URL and into `IDENTIFY`, which is why
    ## `discordIdentify` carries them.
  discordMessageContentIntent* = 32768
    ## MESSAGE CONTENT alone (1 shl 15): the one intent `discord.py`
    ## turns on (`intents.message_content = True`), and without it every
    ## message arrives with an empty body.
  discordTlsMissingLine* = "(discord) no TLS in this build: the gateway " &
    "is wss://" & discordGatewayHost & ". Nim ships its TLS separately " &
    "(the `ssl` package) and this port takes no new dependency, so the " &
    "gateway protocol is implemented and only the encrypted dial is " &
    "missing."
    ## What `liveDiscordWire` says instead of dialling, named after the
    ## host it cannot reach. Same policy as 7b's raising seams: say the
    ## one thing that is missing, never pretend to be connected.

# ── the opening handshake (RFC 6455 §4.1) ─────────────────────────────

proc newDiscordKey*(): string =
  ## A fresh 16-byte `Sec-WebSocket-Key` in base64, as the RFC asks for.
  ## Live only: tests pin frames against a fixed key so nothing they
  ## assert depends on the RNG.
  randomize()
  var raw = newString(16)
  for i in 0 ..< 16:
    raw[i] = char(rand(0 .. 255))
  result = encode(raw)

proc discordHandshake*(token, wsKey: string): string =
  ## The upgrade request Discord answers with `101 Switching Protocols`.
  ## The token travels as a header (never in the path, unlike Telegram's
  ## path token), and the intents do NOT travel here — they go in the
  ## `IDENTIFY` payload, the v8+ shape.
  "GET /?v=" & $discordApiVersion & "&encoding=json HTTP/1.1\r\n" &
    "Host: " & discordGatewayHost & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & wsKey & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n" &
    "Authorization: Bot " & token & "\r\n" &
    "User-Agent: DiscordBot (waku, 1.0)\r\n\r\n"

proc discordHandshakeFault*(reply: string): string =
  ## The other half of the handshake: `""` means the socket is open for
  ## business, anything else is the one line to say instead. A refused
  ## upgrade is how a bad token announces itself, so the status line is
  ## worth showing verbatim.
  ##
  ## Divergence: the port checks the `101` status line and that a
  ## `Sec-WebSocket-Accept` header came back, but it does not recompute
  ## the accept digest — that is SHA-1, deprecated in stdlib, and no
  ## vendored copy belongs in a gateway module. The trust boundary here
  ## is the token in the `Authorization` header over the TLS dial the
  ## 7d2-2 dispatch opens, not this digest.
  var status = ""
  for line in reply.split("\r\n"):
    if line.len > 0:
      status = line
      break
  if not status.startsWith("HTTP/1.1 101"):
    return "gateway refused the websocket upgrade" &
      (if status.len > 0: ": " & status else: " (no response)")
  if "sec-websocket-accept:" notin reply.toLowerAscii():
    return "gateway answered 101 without a Sec-WebSocket-Accept header"
  return ""

# ── frames (RFC 6455 §5) ──────────────────────────────────────────────

const
  opContinuation* = 0x00    ## a fragment's tail; Discord sends none
  opText* = 0x01            ## the only payload kind the gateway uses
  opBinary* = 0x02          ## not used by the gateway protocol
  opClose* = 0x08           ## either side is closing
  opPing* = 0x09            ## the gateway's liveness probe
  opPong* = 0x0A            ## the answer; a ping's payload is echoed
  noFrame* = -1
    ## The read timeout's sentinel (`readDiscordFrame` has no frame to
    ## hand back), so callers never test for an empty payload.

type DiscordFrame* = object
  ## One decoded frame. `masked` is worth keeping: a client frame MUST
  ## be masked (RFC 6455 §5.1) and a server frame never is, so the two
  ## directions are told apart by this bit alone.
  fin*: bool
  opcode*: int
  masked*: bool
  payload*: string

proc applyDiscordMask*(payload, maskKey: string): string =
  ## XOR the payload with the four-byte key, cycling (RFC 6455 §5.3).
  ## The operation is its own inverse, so this one proc both masks a
  ## client frame and unmasks a server one.
  if maskKey.len != 4:
    raise newException(ValueError, "websocket mask key must be 4 bytes")
  result = newString(payload.len)
  for i in 0 ..< payload.len:
    result[i] = char(ord(payload[i]) xor ord(maskKey[i mod 4]))

proc encodeDiscordFrame*(opcode: int, payload, maskKey: string,
    fin = true): string =
  ## One frame on the wire. An empty `maskKey` writes it unmasked (the
  ## server's shape, and what the tests build their fixtures with); any
  ## four-byte key masks the payload, which is what a client must do.
  var head = opcode and 0x0F
  if fin:
    head = head or 0x80
  let length = payload.len
  var lengthBits = length
  if length > 65535:
    lengthBits = 127
  elif length > 125:
    lengthBits = 126
  result = newString(2)
  result[0] = char(head)
  result[1] = char(if maskKey.len > 0: lengthBits or 0x80 else: lengthBits)
  if lengthBits == 126:
    result.add char((length shr 8) and 0xFF)
    result.add char(length and 0xFF)
  elif lengthBits == 127:
    for i in countdown(7, 0):
      result.add char((length shr (8 * i)) and 0xFF)
  if maskKey.len > 0:
    result.add maskKey
    result.add applyDiscordMask(payload, maskKey)
  else:
    result.add payload

proc discordFrameSize*(raw: string): int =
  ## How many bytes the frame at the front of `raw` occupies, or `-1`
  ## while its header (or mask key) is still incomplete. This is the
  ## one number the reader needs: it says whether to keep waiting.
  if raw.len < 2:
    return -1
  let second = ord(raw[1])
  let masked = (second and 0x80) != 0
  var length = second and 0x7F
  var offset = 2
  if length == 126:
    if raw.len < 4:
      return -1
    length = (ord(raw[2]) shl 8) or ord(raw[3])
    offset = 4
  elif length == 127:
    if raw.len < 10:
      return -1
    length = 0
    for i in 0 .. 7:
      length = (length shl 8) or ord(raw[2 + i])
    offset = 10
  if masked:
    if raw.len < offset + 4:
      return -1
    offset += 4
  result = offset + length

proc decodeDiscordFrame*(raw: string): DiscordFrame =
  ## The frame at the front of `raw`, unasked. Raises `ValueError` on a
  ## truncated frame: a caller that wants partial input asks
  ## `discordFrameSize` first, exactly like the reader below does.
  let size = discordFrameSize(raw)
  if size < 0 or raw.len < size:
    raise newException(ValueError, "truncated websocket frame")
  let head = ord(raw[0])
  result.fin = (head and 0x80) != 0
  result.opcode = head and 0x0F
  let second = ord(raw[1])
  result.masked = (second and 0x80) != 0
  var length = second and 0x7F
  var offset = 2
  if length == 126:
    length = (ord(raw[2]) shl 8) or ord(raw[3])
    offset = 4
  elif length == 127:
    length = 0
    for i in 0 .. 7:
      length = (length shl 8) or ord(raw[2 + i])
    offset = 10
  var key = ""
  if result.masked:
    key = raw[offset ..< offset + 4]
    offset += 4
  result.payload = raw[offset ..< offset + length]
  if result.masked:
    result.payload = applyDiscordMask(result.payload, key)

# ── the injected transport ────────────────────────────────────────────

type
  DiscordRecvFn* = proc(timeoutMs: int): string {.closure.}
    ## Read what has arrived, waiting up to `timeoutMs` for the first
    ## byte. `""` means nothing came in that window — a heartbeat tick,
    ## not an error. A closed peer answers `""` too, which is why the
    ## loop counts quiet ticks instead of trusting the socket to say so.
  DiscordSendFn* = proc(bytes: string): int {.closure.}
    ## Write raw frame bytes, returning how many went out.
  DiscordWire* = ref DiscordWireObj
    ## The socket as one value, so a caller hands the protocol a
    ## transport instead of threading two closures through every proc.
    ## It is a `ref` because it also owns the read buffer: a gateway
    ## batches several frames into one TCP read, so the bytes after the
    ## frame just handed back must survive to the next read.
    ## `maskKey` is the connection's client key — every outbound frame
    ## is masked with it, as RFC 6455 §5.1 requires of a client.
  DiscordWireObj = object
    recv*: DiscordRecvFn
    send*: DiscordSendFn
    maskKey*: string
    buffer*: string

proc newDiscordWire*(recv: DiscordRecvFn, send: DiscordSendFn,
    maskKey = ""): DiscordWire =
  ## One connection's transport. An empty `maskKey` writes unmasked
  ## frames (the server's shape, and what tests read fixtures with).
  DiscordWire(recv: recv, send: send, maskKey: maskKey, buffer: "")

proc discordSendFrame*(wire: DiscordWire, opcode: int, payload = ""): int =
  ## One frame out, masked with the connection's client key.
  wire.send(encodeDiscordFrame(opcode, payload, wire.maskKey))

proc discordSendJson*(wire: DiscordWire, text: string): int =
  ## One text frame carrying a gateway payload (`IDENTIFY`,
  ## `HEARTBEAT`).
  discordSendFrame(wire, opText, text)

proc readDiscordFrame*(wire: DiscordWire, timeoutMs: int): DiscordFrame =
  ## One WHOLE frame, however many reads it takes (a frame split across
  ## packets is normal). Whatever is left of a read stays in the wire's
  ## buffer for the next call, so a batch of two frames is two events,
  ## not one event and one lost socket. `opcode == noFrame` means the
  ## transport had nothing within `timeoutMs`.
  while true:
    let size = discordFrameSize(wire.buffer)
    if size >= 0 and wire.buffer.len >= size:
      result = decodeDiscordFrame(wire.buffer)
      wire.buffer = wire.buffer[size .. ^1]
      return
    let chunk = wire.recv(timeoutMs)
    if chunk.len == 0:
      return DiscordFrame(fin: false, opcode: noFrame, masked: false,
        payload: "")
    wire.buffer.add(chunk)

# ── gateway payloads (Discord v10) ────────────────────────────────────

const
  gatewayDispatch* = 0        ## op 0: a named event in `t`
  gatewayHeartbeat* = 1       ## op 1: beat (and the answer to op 1)
  gatewayIdentify* = 2        ## op 2: who we are, what intents we want
  gatewayReconnect* = 7       ## op 7: drop this socket, dial again
  gatewayInvalidSession* = 9  ## op 9: the session is gone
  gatewayHello* = 10          ## op 10: hello, here is the heartbeat rate
  gatewayHeartbeatAck* = 11   ## op 11: our beat arrived

proc discordIdentify*(token: string,
    intents = discordMessageContentIntent): string =
  ## op 2, sent once the `HELLO` interval is known. The properties
  ## triple is the identity every Discord client declares (OS, browser,
  ## device); the token authorizes the session. `compress` is left out
  ## on purpose — zlib-stream compression is not implemented and
  ## Discord accepts its absence.
  $(%*{"op": gatewayIdentify, "d": {"token": token, "intents": intents,
    "properties": {"os": "linux", "browser": "waku", "device": "waku"}}})

proc discordHeartbeat*(seqNo: int): string =
  ## op 1: the beat, carrying the sequence number so a resuming client
  ## can tell Discord what it missed.
  $(%*{"op": gatewayHeartbeat, "d": seqNo})

type
  DiscordPayload* = object
    ## One gateway payload, split the way `receiveDiscordEvent` reads
    ## it: `op` says what kind, `t` names the event inside a dispatch,
    ## `d` is the data, `seq` is the stream position (Discord's `s`).
    ## `ok` is false when the bytes were not a payload at all — the
    ## reader ignores those rather than dying on them.
    op*: int
    seq*: int
    name*: string
    data*: JsonNode
    ok*: bool

proc parseDiscordPayload*(raw: string): DiscordPayload =
  ## Read one payload. A malformed frame body comes back with
  ## `ok == false`: a proxy, a truncated body or a future Discord op
  ## must not take the gateway down.
  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError:
    return
  if node.kind != JObject or not node.hasKey("op"):
    return
  result.ok = true
  result.op = node["op"].getInt(-1)
  result.seq = node{"s"}.getInt(0)
  result.name = node{"t"}.getStr("")
  result.data = node{"d"}

type DiscordMessage* = object
  ## What `on_message` gets in place of a `discord.Message`. `isDm` is
  ## the `message.guild is None` test (an absent `guild_id`), and
  ## `mentioned` is `client.user in message.mentions` — read from the
  ## `mentions` array, falling back to the two `<@id>` forms in the body
  ## when the array is missing, which are the very forms
  ## `stripMention` removes.
  id*: string
  authorId*: string
  channelId*: string
  content*: string
  mentioned*: bool
  isDm*: bool

proc parseDiscordMessage*(data: JsonNode, botId: string): DiscordMessage =
  ## One `MESSAGE_CREATE` payload's `d`, as the message the policy reads.
  if data.kind != JObject:
    return
  result.id = data{"id"}.getStr("")
  result.authorId = data{"author"}{"id"}.getStr("")
  result.channelId = data{"channel_id"}.getStr("")
  result.content = data{"content"}.getStr("")
  result.isDm = not data.hasKey("guild_id")
  if data.hasKey("mentions"):
    for mention in data["mentions"].items:
      if mention{"id"}.getStr("") == botId:
        result.mentioned = true
  if not result.mentioned and botId.len > 0:
    result.mentioned = ("<@" & botId & ">" in result.content) or
      ("<@!" & botId & ">" in result.content)

# ── the live handle (7d2) ─────────────────────────────────────────────

type
  DiscordNowFn* = proc(): float {.closure.}
    ## Seconds since the epoch, injected so the heartbeat cadence and the
    ## spend cap are pinnable without wall time.
  DiscordLive* = ref object
    ## One gateway connection: what `DiscordHandle` plus the `discord.py`
    ## client's daemon thread hold in Python. `runner` is the shared turn
    ## policy (one agent per gateway, 7a) and `budget` is the hourly
    ## spend stop. The session fields (`seq`, `botId`, `sessionId`,
    ## `heartbeatMs`, `lastHeartbeat`, `acked`) are what the payloads
    ## teach the client; `ready` is Python's `client.is_ready()` and
    ## `running` is Python's `thread.is_alive()` seen from a
    ## single-threaded port. A handshake the caller could not open is
    ## NOT a field here: the caller stops the handle instead, because a
    ## connection that never existed must read as stopped, not starting.
    runner*: RunnerState
    budget*: DiscordBudget
    seq*: int
    botId*: string
    sessionId*: string
    heartbeatMs*: int
    lastHeartbeat*: float
    acked*: bool
    ready*: bool
    running*: bool
    stop*: bool
    intents*: int

proc newDiscordLive*(source = "discord", cap = 30): DiscordLive =
  ## A connection that has not started yet: no session, no budget spent.
  DiscordLive(runner: newRunnerState(source), budget: newDiscordBudget(cap),
    seq: 0, botId: "", sessionId: "", heartbeatMs: 0, lastHeartbeat: 0.0,
    acked: false, ready: false, running: false,
    stop: false, intents: discordMessageContentIntent)

proc discordHeartbeatDue*(live: DiscordLive, now: float): bool =
  ## Whether the interval `HELLO` handed over has elapsed since the last
  ## beat. False before the first `HELLO`: there is no rate to keep yet.
  live.heartbeatMs > 0 and
    (now - live.lastHeartbeat) * 1000.0 >= float(live.heartbeatMs)

type
  DiscordEventKind* = enum
    ## What one read of the socket meant. Python's client library turns
    ## every op into its own typed event and re-raises the rest; the
    ## port names the ones that change what the loop does and collapses
    ## the rest into `deNone` (with `detail` saying what it skipped).
    deNone,          ## answered a ping, or an event nobody acts on
    deTimeout,       ## the transport had nothing within the timeout
    deStopped,       ## a stop was asked for before the read
    deHello,         ## op 10: the heartbeat interval is in `intervalMs`
    deReady,         ## op 0 `READY`: bot id and session id are in
    deHeartbeat,     ## op 1: Discord asked for a beat
    deAck,           ## op 11: our beat landed
    deMessage,       ## op 0 `MESSAGE_CREATE`: `message` is filled in
    deReconnect,     ## op 7
    deInvalidSession,## op 9
    deClosed         ## op 8 from either side
  DiscordEvent* = object
    ## One read of the gateway, decoded. `intervalMs` carries the
    ## `HELLO` heartbeat rate, `message` the parsed dispatch, `detail`
    ## whatever else is worth naming (a close payload, a skipped event
    ## name, whether an invalid session was resumable).
    kind*: DiscordEventKind
    intervalMs*: int
    message*: DiscordMessage
    detail*: string

proc receiveDiscordEvent*(live: DiscordLive, wire: DiscordWire,
    timeoutMs = 5000): DiscordEvent =
  ## ONE read of the gateway (the seam 7b left raising). Answers the
  ## control frames inline — a ping gets its pong, a close gets its echo
  ## and drops the connection flags — because those must happen even
  ## when the caller is only after messages.
  if live.stop:
    return DiscordEvent(kind: deStopped)
  let frame = readDiscordFrame(wire, timeoutMs)
  if frame.opcode == noFrame:
    return DiscordEvent(kind: deTimeout)
  case frame.opcode
  of opPing:
    discard discordSendFrame(wire, opPong, frame.payload)
    return DiscordEvent(kind: deNone, detail: "ping answered")
  of opClose:
    discard discordSendFrame(wire, opClose, frame.payload)
    live.ready = false
    return DiscordEvent(kind: deClosed, detail: frame.payload)
  of opText:
    discard  # the only kind with a payload
  else:
    return DiscordEvent(kind: deNone, detail: "ignored opcode " & $frame.opcode)
  let payload = parseDiscordPayload(frame.payload)
  if not payload.ok:
    return DiscordEvent(kind: deNone, detail: "unreadable gateway payload")
  if payload.seq > live.seq:
    live.seq = payload.seq
  case payload.op
  of gatewayHello:
    live.heartbeatMs = payload.data{"heartbeat_interval"}.getInt(0)
    return DiscordEvent(kind: deHello, intervalMs: live.heartbeatMs)
  of gatewayHeartbeatAck:
    live.acked = true
    return DiscordEvent(kind: deAck)
  of gatewayHeartbeat:
    return DiscordEvent(kind: deHeartbeat)
  of gatewayDispatch:
    case payload.name
    of "READY":
      live.botId = payload.data{"user"}{"id"}.getStr("")
      live.sessionId = payload.data{"session_id"}.getStr("")
      live.ready = true
      return DiscordEvent(kind: deReady, detail: live.sessionId)
    of "MESSAGE_CREATE":
      return DiscordEvent(kind: deMessage,
        message: parseDiscordMessage(payload.data, live.botId))
    else:
      return DiscordEvent(kind: deNone, detail: payload.name)
  of gatewayReconnect:
    return DiscordEvent(kind: deReconnect)
  of gatewayInvalidSession:
    return DiscordEvent(kind: deInvalidSession,
      detail: (if payload.data.getBool(false): "resumable" else: "new session"))
  else:
    return DiscordEvent(kind: deNone, detail: "gateway op " & $payload.op)

# ── on_message (discord.py:141-164) ───────────────────────────────────

proc discordHandleMessage*(live: DiscordLive, msg: DiscordMessage,
    http: DiscordHttpFn, token: string, allowedUsers,
    allowedChannels: HashSet[string], requireMention: bool, respond: RespondFn,
    logger: LogFn, now: float,
    env: Table[string, string] = initTable[string, string]()): bool =
  ## One message through the whole policy (port of `on_message`):
  ## the bot's own words and empty bodies are ignored, the allowlist
  ## decides, the hourly cap turns spending off, the @-mention comes off
  ## the text, and what is left runs one turn through the shared runner
  ## and lands in the channel by REST.
  ## Returns whether an agent turn ran — a stranger's silence and a spent
  ## cap are both `false`.
  ## Divergence: Python wraps the turn in a typing indicator
  ## (`message.channel.typing()`); the port has no seam for it and the
  ## turn's `you › …` / `waku › …` lines say the same thing here.
  if msg.authorId == live.botId or msg.content.len == 0:
    return false
  if not shouldAnswer(isDm = msg.isDm, authorId = msg.authorId,
      channelId = msg.channelId, mentioned = msg.mentioned,
      allowedUsers = allowedUsers, allowedChannels = allowedChannels,
      requireMention = requireMention):
    return false   # silence, not a refusal reply
  if not live.budget.budgetAllow(now):
    logger(discordBudgetSpentLine & msg.authorId)
    return false
  let text = stripMention(msg.content, live.botId)
  if text.len == 0:
    return false
  let channelId = msg.channelId
  let send: SendFn =
    proc(reply: string) {.closure.} =
      discard sendDiscordText(http, token, channelId, reply)
  return runGatewayTurn(live.runner, text,
    accountedRespond(live.runner, respond, env), send, logger, env)

# ── the run loop ──────────────────────────────────────────────────────

proc discordRun*(live: DiscordLive, wire: DiscordWire, token: string,
    http: DiscordHttpFn, allowedUsers, allowedChannels: HashSet[string],
    requireMention: bool, respond: RespondFn, logger: LogFn,
    env: Table[string, string] = initTable[string, string](),
    now: DiscordNowFn = nil, maxIdleTicks = 3) =
  ## The blocking gateway loop: Python's two startup lines, then beat on
  ## the interval `HELLO` asked for, identify, and answer every message
  ## the policy admits. It returns when the socket ends, when a reconnect
  ## is asked for, or when the transport goes quiet for `maxIdleTicks`
  ## ticks — a closed peer reads as silence on this seam, and a loop that
  ## spun on it would burn CPU forever on a dead socket.
  ## Reconnecting belongs to `discordServe` below, the `waku discord`
  ## dispatch: it is the only caller that knows how the socket was
  ## dialled, so op 7 and op 9 end this run and it dials again.
  let clock: DiscordNowFn = if now.isNil:
    proc(): float = epochTime()
  else:
    now
  logger(discordListeningLine)
  logger(describePosture(allowedUsers, allowedChannels,
    env.getOrDefault("DISCORD_HOME", ""),
    env.getOrDefault("DISCORD_MAX_TURNS_PER_HOUR", "30")))
  live.running = true
  var idle = 0
  while live.running and not live.stop:
    if discordHeartbeatDue(live, clock()):
      live.lastHeartbeat = clock()
      live.acked = false
      discard discordSendJson(wire, discordHeartbeat(live.seq))
    let event = receiveDiscordEvent(live, wire,
      timeoutMs = (if live.heartbeatMs > 0: live.heartbeatMs else: 5000))
    case event.kind
    of deTimeout:
      inc idle
      if idle > maxIdleTicks:
        logger(discordQuietLine)
        live.running = false
    of deHello:
      idle = 0
      discard discordSendJson(wire, discordIdentify(token, live.intents))
      live.lastHeartbeat = clock()
      discard discordSendJson(wire, discordHeartbeat(live.seq))
    of deHeartbeat:
      idle = 0
      live.lastHeartbeat = clock()
      discard discordSendJson(wire, discordHeartbeat(live.seq))
    of deReady, deAck:
      idle = 0
    of deMessage:
      idle = 0
      discard discordHandleMessage(live, event.message, http, token,
        allowedUsers, allowedChannels, requireMention, respond, logger,
        clock(), env)
    of deReconnect:
      idle = 0
      logger(discordReconnectLine)
      live.running = false
    of deInvalidSession:
      idle = 0
      logger(discordReconnectLine & "session invalid (" & event.detail & ")")
      live.running = false
    of deClosed:
      idle = 0
      logger(discordSocketClosedLine & event.detail)
      live.running = false
    of deStopped, deNone:
      idle = 0
  live.running = false
  live.ready = false
  closeRunner(live.runner)

# ── the handle (discord.py:212-283) ───────────────────────────────────

proc discordStatus*(live: DiscordLive): GatewayReport =
  ## `DiscordHandle.status()` as one report for `Supervisor.statusOf`, in
  ## Python's order: a handle that is not running reads as `gateway
  ## stopped unexpectedly` (Python's exact message for a dead thread),
  ## then the runner's last turn error, then a ready client is
  ## connected, else the client is still starting.
  ## Divergence: Python's `INSTALLED_BUT_UNCONFIGURED` "starting" is not
  ## `ok` here — a gateway that never becomes ready must show on the
  ## dashboard, exactly like a dead poller does. A handshake the 7d2-2
  ## dispatch could not open therefore has to stop the handle
  ## (`discordStop`), or it would read as "starting" forever.
  if live.isNil or not live.running:
    return GatewayReport(ok: false, message: "gateway stopped unexpectedly")
  let lastError = live.runner.errorStatus()
  if lastError.len > 0:
    return GatewayReport(ok: false, message: lastError)
  if live.ready:
    return GatewayReport(ok: true, message: "")
  return GatewayReport(ok: false, message: "starting")

proc discordStop*(live: DiscordLive) =
  ## Ask the gateway to stop (Python's `DiscordHandle.stop` closes the
  ## client, joins its thread and then closes the runner). Divergence:
  ## one thread in this port, so the loop leaves at its next read and the
  ## runner retires here; a nil handle (nothing started) is a no-op,
  ## because a supervisor stop can reach a gateway that never started.
  if live.isNil:
    return
  live.stop = true
  live.running = false
  live.ready = false
  closeRunner(live.runner)

proc discordRearm*(live: DiscordLive,
    env: Table[string, string]) =
  ## Put a handle back to "started, never connected": a fresh runner, a
  ## fresh spend cap from `DISCORD_MAX_TURNS_PER_HOUR`, and none of the
  ## session facts a previous connection taught it (sequence number, bot
  ## id, session id, heartbeat cadence, turn error).
  ##
  ## Both callers need it and neither invents it: the supervisor's
  ## starter (`discordStarter`) and `discordServe`'s re-dial are the same
  ## act — a brand-new session against the same bot, which is exactly
  ## what Python's `start_in_background()` and its library reconnect are.
  ## A cap that does not parse raises `ValueError`, like Python's
  ## `int()` does in `_build_client`.
  ##
  ## `stop` is NOT touched here: the starter clears it explicitly, and
  ## `discordServe` must keep honouring a stop it was asked for.
  live.runner = newRunnerState(live.runner.source)
  live.budget = newDiscordBudget(parseTurnCap(
    env.getOrDefault("DISCORD_MAX_TURNS_PER_HOUR", "30")))
  live.seq = 0
  live.botId = ""
  live.sessionId = ""
  live.heartbeatMs = 0
  live.lastHeartbeat = 0.0
  live.acked = false
  live.ready = false

proc discordStarter*(live: DiscordLive,
    env: Table[string, string]): StarterFn =
  ## The `starters["discord"]` entry Python builds in `dashboard.main`,
  ## as one closure: no token means `None` there and `false` here.
  ## Python's `import discord` guard has no counterpart here: the port
  ## has no extra to install.
  ## The startup lines (`(discord) starting:` plus the posture) are
  ## printed by the dashboard wiring in 7d2-3, next to the other
  ## gateways' banners, so this proc stays about the lifecycle.
  ##
  ## A restart is a FRESH connection (`discordRearm`), which is what
  ## calling `start_in_background()` again gets in Python.
  ##
  ## OBLIGATION ON THE CALLER: the starter re-arms the handle, it does not
  ## listen. Only `discordRun` (or `discordServe`, which owns the socket)
  ## pumps the gateway; a started handle nobody pumps would report itself
  ## healthy while doing nothing.
  result = proc(): bool {.closure.} =
    if env.getOrDefault("DISCORD_BOT_TOKEN", "").len == 0:
      return false
    live.stop = false
    discordRearm(live, env)
    live.running = true
    return true

proc discordStatusFn*(live: DiscordLive): StatusFn =
  ## Supervisor adapter for one `discord` handle.
  result = proc(key: string): GatewayReport {.closure.} = discordStatus(live)

proc discordStopFn*(live: DiscordLive): StopFn =
  ## Supervisor adapter for one `discord` handle.
  result = proc(key: string) {.closure.} = discordStop(live)

# ── the dial and the command loop (7d2-2) ────────────────────────────

type
  DiscordDialFn* = proc(token: string): (bool, DiscordWire, string) {.closure.}
    ## Open one gateway connection: `(ok, wire, why)`. `why` is the single
    ## line to say when `ok` is false — a refused dial is an outcome the
    ## caller reports, not an exception it has to catch. The command
    ## injects `liveDiscordWire`; tests inject a scripted dial, so the
    ## re-dial policy below is pinnable without a socket.

proc liveDiscordWire*(token: string): (bool, DiscordWire, string) =
  ## The real dial to `wss://gateway.discord.gg`: the one thing this port
  ## cannot do yet, and it says so instead of pretending.
  ##
  ## Honest refusal, in the shape every 7b seam used: `(false, nil,
  ## discordTlsMissingLine)`. Nim moved TLS out of the compiler
  ## distribution at 1.6 (the `ssl` package, which links OpenSSL), so
  ## there is no standard-library TLS to import; taking that package is a
  ## new dependency, which rule 3 forbids, and it could not be fetched
  ## offline anyway. Nothing else is missing: `discordHandshake`,
  ## `discordHandshakeFault` and the framing above are the whole
  ## protocol, and they speak over any `DiscordWire`.
  ##
  ## What a future build fills in, so the shape of the seam is already
  ## the right one: connect TCP 443, wrap it in TLS with
  ## `gateway.discord.gg` as the SNI name, send `discordHandshake(token,
  ## newDiscordKey())`, read the upgrade reply (keeping any bytes that
  ## arrived with it for `wire.buffer`), refuse on a non-empty
  ## `discordHandshakeFault`, and hand back `newDiscordWire` over that
  ## socket with the same key as the client mask. `discordServe` below
  ## then needs no change at all.
  discard token   # the seam's shape, until the dial lands
  return (false, nil, discordTlsMissingLine)

proc discordServe*(live: DiscordLive, token: string, respond: RespondFn,
    logger: LogFn, env: Table[string, string], http: DiscordHttpFn = nil,
    dial: DiscordDialFn = nil, maxDials = 5): int =
  ## The `waku discord` command: dial, run the gateway loop, dial again
  ## when the run ends. Port of `discord.py::main`'s
  ## `client.run(token)`, with the reconnect Python's library does on its
  ## own moved here — only the caller knows how the socket was dialled.
  ##
  ## The access policy comes from `env` exactly as `_build_client` reads
  ## it: `DISCORD_ALLOWED_USER` / `DISCORD_ALLOWED_CHANNEL` /
  ## `DISCORD_REQUIRE_MENTION`, plus the spend cap `discordRearm` takes
  ## from `DISCORD_MAX_TURNS_PER_HOUR` — which raises `ValueError` on
  ## garbage, like Python's `int()` in the same place. `http` is the REST
  ## seam (nil means the live `liveDiscordPost`); `dial` is the socket
  ## seam (nil means the live `liveDiscordWire`).
  ##
  ## Two documented divergences, both from giving up a thread Python has:
  ## a REFUSED dial is reported once and exits 1 instead of being retried
  ## forever (a refused dial is the same refusal every time — no TLS in
  ## this build, a bad token, a network that is down — and a hot retry
  ## loop would bury that one line); and the number of connections one
  ## process opens is capped at `maxDials`, so a gateway that accepts and
  ## then drops every session ends the command instead of reconnecting
  ## forever. Returns 0 once a connection has run, 1 when the dial was
  ## refused.
  let dialFn: DiscordDialFn = if dial.isNil: liveDiscordWire else: dial
  let post: DiscordHttpFn = if http.isNil: liveDiscordPost else: http
  let allowedUsers = parseDiscordIds(env.getOrDefault("DISCORD_ALLOWED_USER", ""))
  let allowedChannels = parseDiscordIds(
    env.getOrDefault("DISCORD_ALLOWED_CHANNEL", ""))
  let requireMention = parseRequireMention(
    env.getOrDefault("DISCORD_REQUIRE_MENTION", "1"))
  var opened = 0
  discordRearm(live, env)   # the env's policy, before the first socket
  while not live.stop and opened < maxDials:
    let (ok, wire, why) = dialFn(token)
    if not ok:
      logger(why)
      return 1
    inc opened
    discordRun(live, wire, token, post, allowedUsers,
      allowedChannels, requireMention, respond, logger, env)
    # The run ended without a stop, so the gateway asked for a reconnect
    # (op 7/9), the socket closed or the transport went quiet — each of
    # those already logged itself above. Python's library reconnects here
    # on its own; this loop owns the dial, so it dials again, and the
    # re-arm is what makes the second run a new session: `discordRun`
    # retired the runner on the way out, as `discord.py`'s
    # `finally: runner.close()` does.
    if live.stop:
      return 0
    discordRearm(live, env)
  return 0
