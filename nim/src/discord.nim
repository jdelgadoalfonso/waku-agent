## Discord gateway, phase 7b — access policy + REST send seam.
##
## Port of the testable core of `waku/gateway/discord.py`: `should_answer`
## (deny-by-default: an empty channel allowlist answers NO channel),
## `_strip_mention` (`<@id>`/`<@!id>`), `TurnBudget` (hourly ceiling with
## `now` as a parameter), `describe_posture` (four lines, verbatim), and
## the send path as an injected REST seam (`POST
## /channels/{id}/messages` with `Authorization: Bot …`).
##
## The receive half (gateway WebSocket via the `discord` SDK) is NOT
## ported: no SDK exists for Nim and rule 3 forbids new dependencies, so
## the live socket stays a 7d follow-up (or an external process) behind
## the honest `receiveDiscordEvent` seam. The `discord.py` client itself
## hides the REST shape inside the library; the URL/body/header contract
## below is the documented Discord API surface, hand-rolled like the
## Telegram Bot API in phase 7a. Every side effect travels through
## `DiscordHttpFn`: zero sockets in tests. `waku.nim` keeps its phase-4e
## `discord` stub until 7d owns the live loop.

import std/httpclient
import std/httpcore
import std/json
import std/sets
import std/strutils

const discordEnvFields* = ["DISCORD_BOT_TOKEN", "DISCORD_ALLOWED_USER",
  "DISCORD_ALLOWED_CHANNEL", "DISCORD_REQUIRE_MENTION",
  "DISCORD_MAX_TURNS_PER_HOUR", "DISCORD_HOME"]
  ## Supervisor fields for 7d (token first: `isConfigured` reads the
  ## first field as the token, same precedent as telegram). Port of the
  ## six `os.getenv` names in `discord.py`.

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

# ── receive (7d) ──────────────────────────────────────────────────────

proc receiveDiscordEvent*() =
  ## Honest seam for the gateway WebSocket receive: the live socket
  ## (the `discord` SDK's event loop) has no stdlib equivalent, so 7d
  ## owns it. Raises until then instead of pretending to listen.
  raise newException(CatchableError,
    "discord gateway receive lives in 7d (websocket, no SDK in stdlib)")
