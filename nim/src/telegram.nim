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
## 7d1 adds the live half: the long-poll itself (`telegramPoll`),
## the poll-error policy (`telegramFault`), the blocking loop
## (`telegramRun`) and the handle `TelegramHandle` stands for
## (`telegramStatus`/`telegramStop` plus the three supervisor adapters).
## There is no `Application` poller, no `main` and no
## `start_in_background` here: 7d2 owns the dispatch that runs them, and
## `nim/src/waku.nim` keeps its honest phase-4e `telegram` stub until
## then (precedent: `waku.nim` untouched in 6a, 7a and 7b).
##
## Two deliberate divergences from the Python poller, both documented at
## the proc that owns them: the port prints every failed poll (redacted)
## where PTB's logger swallowed them, and it distinguishes a dead token
## (stop) from a network blip (retry) from a second poller (conflict).
##
## `nimble test` opens zero sockets: the live adapter `liveTelegramHttp`
## is never called in tests, which replay recorded payloads through
## `TelegramHttpFn`.

import std/httpclient
import std/json
import std/sets
import std/strutils
import std/tables

import ./gateway
import ./http
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
  ## The client comes from `http.nim`'s helper: `api.telegram.org` is
  ## `https://`, so a `-d:wakuTls` build needs the context, and the
  ## default build refuses the URL before the token is written anywhere.
  let client = newTlsHttpClient(timeout = 45000)
  try:
    if payload.len > 0:
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      return client.postContent(url, payload)
    return client.getContent(url)
  finally:
    client.close()

# ── the live long-poll (7d1) ───────────────────────────────────────────

const
  conflictLine* = "(telegram) another instance is already running this " &
    "bot — the dashboard's Telegram stays idle. Stop the other " &
    "`waku telegram` and restart to use it here."
    ## `on_poll_error`'s one warning, verbatim: another bot is already
    ## polling this token, which is the one poll error a person can act
    ## on. Said once, never with a traceback (Python's exact policy).
  listeningBanner* = "Waku is listening on Telegram — message your bot. " &
    "Ctrl-C to stop."
    ## `main`'s one-line banner, verbatim. `telegramRun` prints it with
    ## the posture, exactly where Python prints both.
  pollerStoppedLine* = "(telegram) background poller stopped: "
    ## What a dead poller prints, like Python's `run` except arm.
  pollFailedLine* = "(telegram) poll failed: "
    ## A poll that failed and will be retried. Divergence: PTB handed
    ## every error to its own logger and the port printed only the
    ## conflict, so a laptop that quietly stopped reaching Telegram
    ## looked identical to a bot nobody was talking to. Redacted like
    ## every other terminal line here.

type
  TelegramLive* = ref object
    ## One running long-poll: what `TelegramHandle` plus PTB's background
    ## thread hold in Python. `runner` is the shared turn policy (one
    ## agent per gateway, 7a), `offset` is the acknowledgement PTB keeps
    ## per process, `conflict` is the `warned["conflict"]` flag's
    ## outcome and `warned` is that flag itself. `running` is the thread
    ## `is_alive()` test, and `stop` is Python's `shutdown()` seen from a
    ## single-threaded port: the loop stops at the next poll edge.
    runner*: RunnerState
    offset*: int64
    stop*: bool
    running*: bool
    polling*: bool
    conflict*: bool
    warned*: bool

proc newTelegramLive*(source = "telegram"): TelegramLive =
  ## A poller that has not started yet. `source` names the gateway in
  ## every log line and in the closed-runner error.
  TelegramLive(runner: newRunnerState(source), offset: 0, stop: false,
    running: false, polling: false, conflict: false, warned: false)

type PollFault* = enum
  ## What a failed poll means. Python only names one of them (the
  ## conflict) and lets the library decide the rest; the port decides
  ## here, because the difference is whether the gateway keeps working:
  ## `pfRetry` is a blip, `pfConflict` is a second poller on the same
  ## token (warn once, keep polling), and `pfFatal` is a token the API
  ## refuses (Python's `InvalidToken` kills the thread, which its handle
  ## then reports as "gateway stopped unexpectedly").
  pfRetry, pfConflict, pfFatal

proc telegramFault*(message: string): PollFault =
  ## Classify a transport error into the three faults above. Divergence:
  ## the decision reads the STATUS LINE, not the body, because
  ## `std/httpclient` raises `HttpRequestError` with `409 Conflict` and
  ## friends and drops the response body — the `!raise409` scripts in
  ## `test_live_gateways.nim` are exactly those messages. "conflict" is
  ## matched too, so a proxy or wrapper that words it differently still
  ## lands in the same bucket.
  let lowered = message.toLowerAscii()
  if "409" in lowered or "conflict" in lowered:
    return pfConflict
  if "401" in lowered or "unauthorized" in lowered or "404" in lowered or
      "not found" in lowered:
    return pfFatal
  return pfRetry

proc telegramPoll*(live: TelegramLive, http: TelegramHttpFn,
    ids: HashSet[string], token: string, respond: RespondFn, logger: LogFn,
    env: Table[string, string] = initTable[string, string](),
    timeoutSecs = 30): int =
  ## ONE long-poll cycle (port of PTB's poller + `handle`): ask
  ## `getUpdates` from the current offset, answer every update the
  ## allowlist admits, and acknowledge what was seen. Returns the number
  ## of AGENT turns run — a stranger's refusal is a delivery, not a turn.
  ## `timeoutSecs` is a parameter because the dashboard drives this loop
  ## between browser requests and shortens it there, while the
  ## standalone command keeps Python's 30.
  if live.stop:
    return 0
  live.running = true
  live.polling = true
  defer:
    live.polling = false
  var updates: seq[TelegramUpdate]
  try:
    updates = fetchTelegramUpdates(http, token, live.offset, timeoutSecs)
  except CatchableError as exc:
    let detail = safeException($exc.name, exc.msg, env)
    case telegramFault(exc.msg)
    of pfConflict:
      live.conflict = true
      if not live.warned:
        live.warned = true
        logger(conflictLine)
    of pfFatal:
      live.running = false
      logger(pollerStoppedLine & detail)
    of pfRetry:
      logger(pollFailedLine & detail)
    return 0
  # the agent call, wrapped in the runner's accounting (Python's
  # `_respond`): a failed turn is recorded where the dashboard reads it
  let turn = accountedRespond(live.runner, respond, env)
  result = 0
  for i in 0 ..< updates.len:
    let upd = updates[i]  # a value: the send closure below outlives the
                          # iterator's `lent` copy of the update
    let send: SendFn =
      proc(text: string) {.closure.} =
        discard sendTelegramText(http, token, upd.chatId, text)
    case classifyTelegram(ids, upd)
    of taRefuse:
      # Python replies to the stranger in the handler, outside
      # `run_gateway_turn`; a delivery that fails is recorded as one
      # (`reply delivery`) instead of vanishing into PTB's log.
      try:
        send(telegramRefusal)
      except CatchableError as exc:
        let detail = live.runner.recordError($exc.name, exc.msg, env,
          "reply delivery")
        logger("(" & live.runner.source & ") reply delivery failed: " &
          detail)
    of taAnswer:
      discard runGatewayTurn(live.runner, upd.text, turn, send, logger, env)
      inc result
    of taSkip:
      discard
  live.offset = nextTelegramOffset(updates, live.offset)
  if live.stop:
    # a stop that arrived while this poll was in flight: the turns of
    # THIS poll still ran (Python lets an in-flight handler finish), the
    # poller is done after it, and the runner retires here.
    live.running = false
    closeRunner(live.runner)

proc telegramRun*(live: TelegramLive, http: TelegramHttpFn,
    ids: HashSet[string], token: string, respond: RespondFn, logger: LogFn,
    env: Table[string, string] = initTable[string, string](),
    timeoutSecs = 30) =
  ## The blocking poll loop (Python's `app.run_polling` on the poller
  ## thread). It returns when `stop` is observed or the token dies; a
  ## transport blip is not an exit, that is the retry in `telegramPoll`.
  ## It prints Python's two startup lines first (the banner and the
  ## posture), because this is the standalone command's loop; the
  ## dashboard prints its own `(telegram) starting:` line instead and
  ## pumps `telegramPoll` itself.
  logger(listeningBanner)
  logger(posture(ids))
  live.running = not live.stop
  while live.running and not live.stop:
    discard telegramPoll(live, http, ids, token, respond, logger, env,
      timeoutSecs)

proc telegramStatus*(live: TelegramLive): GatewayReport =
  ## The handle's `status()` as one report for `Supervisor.statusOf`:
  ## a conflict first (it is the error a person can fix), then a poller
  ## that is not running (`gateway stopped unexpectedly`, exactly
  ## Python's message for a dead thread), then the runner's last error,
  ## else healthy. The conflict wins over the runner because Python's
  ## handle checks it first, and a nil handle (nothing started) reads as
  ## stopped, which is what Python's `status()` gives for a key with no
  ## handle.
  if live.isNil:
    return GatewayReport(ok: false, message: "gateway stopped unexpectedly")
  if live.conflict:
    return GatewayReport(ok: false,
      message: "another instance is polling this token")
  if not live.running:
    return GatewayReport(ok: false, message: "gateway stopped unexpectedly")
  let lastError = live.runner.errorStatus()
  if lastError.len > 0:
    return GatewayReport(ok: false, message: lastError)
  return GatewayReport(ok: true, message: "")

proc telegramStop*(live: TelegramLive) =
  ## Ask the poller to stop (Python's `TelegramHandle.stop` runs an async
  ## shutdown on the poller thread, joins it and then closes the runner).
  ## Divergence: one thread in this port, so a stop asked for DURING a
  ## poll is honoured at the end of that poll — the turns of the poll
  ## still land, like Python's in-flight handler, and the runner retires
  ## there; asked for between polls it takes effect at once.
  ##
  ## A nil handle stops nothing, exactly as `telegramStatus` reads it as
  ## stopped: the supervisor's stop seam can be called for a gateway that
  ## never started, and a nil deref while shutting down would take the
  ## dashboard down at the worst possible moment.
  if live.isNil:
    return
  live.stop = true
  if not live.polling:
    live.running = false
    closeRunner(live.runner)

proc telegramStarter*(live: TelegramLive, env: Table[string, string],
    respond: RespondFn, http: TelegramHttpFn,
    logger: LogFn): StarterFn =
  ## The `starters["telegram"]` entry Python builds in `dashboard.main`,
  ## as one closure: no token means `None` there and `false` here. The
  ## status line (`(telegram) starting:` plus `posture`) is printed by
  ## the dashboard wiring in 7d2, next to the other gateways' banners, so
  ## this proc stays about the lifecycle.
  ##
  ## A restart is a FRESH poller, fresh runner included: that is exactly
  ## what Python gets from calling `start_in_background()` again, and it
  ## is why a stale conflict, warning, offset or turn error never survives
  ## one.
  ##
  ## OBLIGATION ON THE CALLER: the starter re-arms the handle, it does not
  ## poll. Python's `start_in_background` returns a handle whose daemon
  ## thread is already running; a single-threaded port has no thread to
  ## leave running, so whoever started it must keep calling
  ## `telegramPoll` (the dashboard's tick in 7d2) or `telegramRun` (the
  ## standalone `waku telegram`). A started handle nobody pumps would
  ## report itself healthy while doing nothing — the one shape this port
  ## must not ship.
  result = proc(): bool {.closure.} =
    let token = env.getOrDefault("TELEGRAM_BOT_TOKEN", "")
    if token.len == 0:
      return false
    live.stop = false
    live.runner = newRunnerState(live.runner.source)
    live.conflict = false
    live.warned = false
    live.offset = 0
    live.running = true
    return true

proc telegramStatusFn*(live: TelegramLive): StatusFn =
  ## Supervisor adapter for one `telegram` handle.
  result = proc(key: string): GatewayReport {.closure.} = telegramStatus(live)

proc telegramStopFn*(live: TelegramLive): StopFn =
  ## Supervisor adapter for one `telegram` handle.
  result = proc(key: string) {.closure.} = telegramStop(live)
