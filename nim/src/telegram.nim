## Telegram gateway, phase 7a — allowlist gate + Bot API wire.
##
## Port of the testable core of `waku/gateway/telegram.py`: `_allowed_ids`
## (comma parsing), `posture` (the startup stance, verbatim), the
## stranger-refusal in `_build_app`'s `handle`, and the Bot API itself
## (`getUpdates` long-poll + `sendMessage`) over HTTPS with an injected
## seam. There is no `python-telegram-bot` for Nim and rule 3 forbids new
## dependencies, so the wire is hand-rolled `std/httpclient` + `json`
## (precedent: MCP hand-rolled in phase 6, SSE in phase 3).
##
## Deliberately out (7d owns the live loop): the `Application` poller,
## `main`, `TelegramHandle` and `start_in_background` — asyncio, threads
## and the PTB SDK have no synchronous single-threaded equivalent here,
## and `nim/src/waku.nim` keeps its honest phase-4e `telegram` stub until
## the unit that owns the live loop wires it (precedent: `waku.nim`
## untouched in 6a). `nimble test` opens zero sockets: the live adapter
## `liveTelegramHttp` is never called in tests, which replay recorded
## payloads through `TelegramHttpFn`.

import std/httpclient
import std/json
import std/sets
import std/strutils

import ./wire

const
  telegramRefusal* = "This Waku serves someone else. Run your own!"
    ## Reply to a non-allowlisted sender (the `handle` branch verbatim).

# ── allowlist gate ────────────────────────────────────────────────────

proc parseAllowedIds*(raw: string): HashSet[string] =
  ## Parse `TELEGRAM_ALLOWED_USER` into a set. Empty means no restriction
  ## — which is why `posture` says so out loud on every start. Port of
  ## `_allowed_ids`; the raw value is a parameter (never `os.getenv`)
  ## so tests pin parsing without touching the process environment.
  result = initHashSet[string]()
  for part in raw.split(','):
    let id = part.strip()
    if id.len > 0:
      result.incl(id)

proc posture*(ids: HashSet[string]): string =
  ## Who can reach this bot, printed at startup (verbatim both stances:
  ## a silent default is how an assistant ends up serving strangers).
  if ids.len > 0:
    return "  reachable by: " & $ids.len & " allowlisted user(s)"
  return ("  reachable by: ANYONE who finds this bot — it will answer from your\n" &
    "                personal memory. Set TELEGRAM_ALLOWED_USER to lock it.")

proc isTelegramAllowed*(ids: HashSet[string], userId: string): bool =
  ## The gate in `handle`: an empty allowlist lets anyone in, otherwise
  ## only members.
  ids.len == 0 or userId in ids

# ── Bot API wire ──────────────────────────────────────────────────────

type
  TelegramUpdate* = object
    ## One answerable inbound message off `getUpdates`: who sent what to
    ## which chat, plus the entry id for offset bookkeeping.
    updateId*: int64
    chatId*: int64
    userId*: string
    text*: string
  TelegramAction* = enum
    ## What `handle` does with one update: answer it, refuse the stranger
    ## (with `telegramRefusal`), or skip it silently (nothing to answer).
    taAnswer, taRefuse, taSkip
  TelegramHttpFn* = proc(url, payload: string): string {.closure.}
    ## One Bot API call: full URL + JSON payload (`""` for `getUpdates`,
    ## which is a GET) → raw response body. Raises on transport failure,
    ## like `httpclient`; the binary passes `liveTelegramHttp`. Recorded
    ## bodies in tests, never a socket.

proc apiUrl*(token, meth: string): string =
  ## `https://api.telegram.org/bot<token>/<method>`, both calls share it.
  "https://api.telegram.org/bot" & token & "/" & meth

proc hasCommandEntity(message: JsonNode): bool =
  ## True when the message carries a `bot_command` entity at offset 0 —
  ## the Bot API shape of what PTB's `filters.COMMAND` matches. A
  ## `/`-leading text WITHOUT that entity is plain text (same as PTB:
  ## the entity is what makes it a command, not the slash).
  if message.jget("entities").kind != JArray:
    return false
  for ent in message["entities"]:
    if ent.jget("type").getStr() == "bot_command" and
        ent.jget("offset").getInt(-1) == 0:
      return true
  return false

proc parseUpdates*(body: string): seq[TelegramUpdate] =
  ## The `result` array of a `getUpdates` response as answerable updates.
  ## Entries without a text message are skipped (photos, stickers, edits
  ## never reach `handle`: PTB's `filters.TEXT` does the same), as are
  ## real bot commands (`TEXT & ~COMMAND` in `_build_app`). Malformed
  ## ENTRIES are skipped; a malformed ENVELOPE raises `JsonParsingError`
  ## (a transport-shaped failure the poll loop must see, not swallow).
  result = @[]
  let doc = parseJson(body)
  if doc.jget("result").kind != JArray:
    return result
  for entry in doc["result"]:
    let message = entry.jget("message")
    if message.kind != JObject:
      continue
    let text = message.jget("text")
    if text.kind != JString or text.getStr().len == 0:
      continue
    if hasCommandEntity(message):
      continue
    let chat = message.jget("chat")
    let fromUser = message.jget("from")
    if chat.kind != JObject or fromUser.kind != JObject:
      continue
    result.add(TelegramUpdate(updateId: entry.jget("update_id").getInt(0),
      chatId: chat.jget("id").getBiggestInt(0),
      userId: $fromUser.jget("id").getBiggestInt(0),
      text: text.getStr()))

proc buildSendBody*(chatId: int64, text: string): JsonNode =
  ## The `sendMessage` JSON body (`chat_id` + `text`).
  %*{"chat_id": chatId, "text": text}

proc sendTelegramText*(http: TelegramHttpFn, token: string, chatId: int64,
    text: string): bool =
  ## Deliver one reply through `sendMessage`. Returns the API `ok` flag —
  ## `false` (blocked bot, gone chat) is a delivery outcome, not a
  ## transport failure, so it returns instead of raising. Transport
  ## failures propagate to `runGatewayTurn`, which records them as
  ## `reply delivery` (see `gateway.nim`).
  let resp = parseJson(http(apiUrl(token, "sendMessage"),
    $buildSendBody(chatId, text)))
  resp.jget("ok").getBool(false)

proc fetchTelegramUpdates*(http: TelegramHttpFn, token: string,
    offset: int64, timeoutSecs = 30): seq[TelegramUpdate] =
  ## One `getUpdates` long-poll: entries at/after `offset`, waiting up to
  ## `timeoutSecs` server-side (your laptop calls Telegram — no public
  ## URL, no webhook, which is why this gateway needs no inbound port).
  http(apiUrl(token, "getUpdates") & "?offset=" & $offset & "&timeout=" &
    $timeoutSecs, "").parseUpdates()

proc nextTelegramOffset*(updates: seq[TelegramUpdate],
    current: int64): int64 =
  ## The offset acknowledging every update seen: past the highest id, or
  ## the current one when nothing arrived (never rewind the poll).
  var next = current
  for u in updates:
    if u.updateId + 1 > next:
      next = u.updateId + 1
  return next

proc classifyTelegram*(ids: HashSet[string],
    upd: TelegramUpdate): TelegramAction =
  ## The `handle` decision without the async: strangers get the refusal,
  ## empties are skipped silently, everything else is answered.
  if not isTelegramAllowed(ids, upd.userId):
    return taRefuse
  if upd.text.len == 0:
    return taSkip
  return taAnswer

proc liveTelegramHttp*(url, payload: string): string =
  ## The real Bot API call over `std/httpclient`: POST with a JSON body
  ## for `sendMessage`, GET for `getUpdates` (empty payload). The 45s
  ## timeout covers the 30s long-poll plus margin. Never called in tests.
  let client = newHttpClient(timeout = 45000)
  try:
    if payload.len > 0:
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      return client.postContent(url, payload)
    return client.getContent(url)
  finally:
    client.close()
