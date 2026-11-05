## Phase 7d2 tests: the dashboard's gateway supervisor — reconcile,
## shutdown, the status/reload seams the connections panel reads, the
## telegram tick and the one multiplexed serve loop.
##
## What replaced what: `buildDashboardDeps` left `gatewayReload`/
## `gatewayStatus` nil (so `waku dashboard` never supervised a bot) and
## `serveDashboardCmd` served the stdlib accept loop with no gateway tick
## at all. `dashboard.py::main` builds one `GatewaySupervisor` over the
## three `start_in_background` adapters, registers its status provider and
## reloader, reconciles before `serve_forever()` and shuts down after.
##
## Offline only: the Bot API, the Graph API, the Discord REST client, the
## gateway dial and the webhook bind are all injected seams (recorded
## `http` fixtures, a scripted wire, and a bind that fails on demand), the
## agent turn is a stub, the "terminal" is a log, and the serve loop is
## driven through its own step seams. Zero sockets, like every other suite
## here: the loop's socket halves (`bind`, `takeConn`, `waitForListener`)
## are the ones `defaultServe` never had a test for either.
##
## The idle backoff suite at the end pins the one place the loop decides how
## long to wait: the `wait` seam takes the window as an argument, so a test
## reads the cadence this dashboard would run at instead of sleeping
## through it.
##
## Split from `test_dashboard.nim` (handlers + deps, every gateway seam
## nil) on purpose: this file pins the LIVE wiring the process builds,
## which is where 7d2-3 changed the code. Call site:
## `waku/ops/dashboard.py::main`.

import std/httpclient
import std/json
import std/net
import std/os
import std/strutils
import std/tables
import std/unittest

import ../src/dashboard
import ../src/discord
import ../src/gateway
import ../src/integrations
import ../src/telegram

# ── offline doubles ───────────────────────────────────────────────────

type
  Rig = ref object
    ## One rig plus everything the seams wrote to, so a test reads the
    ## order and the payloads instead of guessing.
    log: seq[string]
    turns: seq[string]
    posts: seq[string]
    dials: seq[string]
    chunks: seq[string]
    answers: seq[string]
    env: Table[string, string]
      ## The credentials the LIVE-env seam reads. It lives on the rig (a
      ## `ref`) because a closure cannot capture a `var` parameter — which
      ## is exactly why the production wiring reads the env through a seam
      ## too.

proc newRig(): Rig =
  Rig(log: @[], turns: @[], posts: @[], dials: @[], chunks: @[], answers: @[],
    env: initTable[string, string]())

proc envOf(rows: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (name, value) in rows:
    result[name] = value

proc loggerOf(r: Rig): LogFn =
  result = proc(line: string) {.closure.} = r.log.add(line)

proc respondOf(r: Rig): proc(source: string): RespondFn {.closure.} =
  ## One agent per gateway, named like Python's session ids. The stub
  ## answers with the gateway that asked, so a test can see WHICH gateway
  ## answered without threading the source through the gateway modules.
  result = proc(source: string): RespondFn {.closure.} =
    let r = r
    proc turn(text: string): string {.closure.} =
      r.turns.add(source & ": " & text)
      return "re:" & text
    turn

proc updatesBody(count: int, text: string): string =
  ## `count` answerable updates, rising ids (so the offset bookkeeping has
  ## something to move to). The `from` user is `7`, the one the allowlist
  ## tests admit.
  var entries = newJArray()
  for i in 0 ..< count:
    let id = i + 1
    entries.add(%*{"update_id": id, "message": {
      "message_id": id, "text": text,
      "chat": {"id": 4242}, "from": {"id": 7}}})
  $(%*{"ok": true, "result": entries})

proc telegramHttpOf(r: Rig): TelegramHttpFn =
  ## `getUpdates` answers with the next scripted envelope and drains it
  ## (a long-poll keeps returning the same updates until the offset moves,
  ## so a script that did not drain would answer forever);
  ## `sendMessage` records the delivery.
  result = proc(url, payload: string): string {.closure.} =
    if url.contains("getUpdates"):
      let body = if r.answers.len > 0: r.answers[0]
                 else: """{"ok": true, "result": []}"""
      if r.answers.len > 0:
        r.answers.delete(0)
      return body
    r.posts.add(parseJson(payload)["text"].getStr())
    return """{"ok": true}"""

proc wireOf(r: Rig): DiscordWire =
  ## The scripted gateway socket: `recv` pops one queued chunk and answers
  ## `""` when the script runs dry (the silence of an idle gateway).
  result = newDiscordWire(
    proc(timeoutMs: int): string {.closure.} =
      if r.chunks.len == 0:
        return ""
      let chunk = r.chunks[0]
      r.chunks.delete(0)
      chunk,
    proc(bytes: string): int {.closure.} = bytes.len,
    "AaBb")

proc feed(r: Rig, payloads: openArray[string]) =
  ## Queue one server text frame per gateway payload (a server never
  ## masks, RFC 6455 §5.1).
  for payload in payloads:
    r.chunks.add(encodeDiscordFrame(opText, payload, ""))

proc testHooks(r: Rig, wire: DiscordWire = nil, dialOk = true,
    dialWhy = "(discord) no TLS in this build",
    respond: proc(source: string): RespondFn = nil): GatewayHooks =
  ## The seams a test owns: the credentials table (read LIVE through the
  ## `envOf` seam, the same path the process uses), the Bot API script, a
  ## refused-or-scripted gateway dial, a stub agent and the log. Nothing
  ## here reaches a socket, a clock or the process environment.
  result = GatewayHooks(
    envOf: proc(): Table[string, string] {.closure.} = r.env,
    logger: r.loggerOf(),
    respond: (if respond != nil: respond else: r.respondOf()),
    telegramHttp: r.telegramHttpOf(),
    whatsappHttp: proc(url, payload, token: string): int {.closure.} =
      r.posts.add(url)
      200,
    discordHttp: proc(url, payload, token: string): int {.closure.} =
      r.posts.add(parseJson(payload)["content"].getStr())
      200,
    discordDial: proc(token: string): (bool, DiscordWire, string) {.closure.} =
      r.dials.add(token)
      if not dialOk:
        return (false, nil, dialWhy)
      (true, wire, ""),
    now: proc(): float = 1.0,
    webhookHost: "127.0.0.1",
    webhookPort: 0)

proc bareServer(home: string): DashboardServer =
  ## A server the loop never binds: `multiplexPass` reads nothing from it
  ## except the deps a test wants to keep out of the way.
  DashboardServer(host: "127.0.0.1", port: 7777,
    deps: DashboardDeps(home: home, staticDir: home,
      env: initTable[string, string]()))

proc panelDeps(home: string, dotenvPath: string): DashboardDeps =
  ## The deps the connections panel needs and nothing else: a temp home,
  ## a temp `.env`, no providers and no probes (both are seams the panel
  ## tests inject when they need them).
  DashboardDeps(home: home, staticDir: home, provider: "anthropic",
    model: "test-model", providers: @[], env: initTable[string, string](),
    fetch: proc(url, key: string): string =
      raise newException(CatchableError, "network is stubbed: " & url),
    today: "2026-10-01", nowIso: "2026-10-01T00:00:00+00:00",
    dotenvPath: dotenvPath, hostOs: "linux",
    probes: initTable[string, ProbeFn]())

# ── registry fields ───────────────────────────────────────────────────

suite "phase 7d2 supervisor env fields":
  test "the three gateway rows come from the registry, token first":
    let fields = gatewayEnvFields()
    check fields.len == 3
    check fields[0] == ("telegram", @["TELEGRAM_BOT_TOKEN",
      "TELEGRAM_ALLOWED_USER", "WAKU_GRAPH_TELEGRAM"])
    check fields[1] == ("discord", @["DISCORD_BOT_TOKEN",
      "DISCORD_ALLOWED_USER", "DISCORD_ALLOWED_CHANNEL",
      "DISCORD_REQUIRE_MENTION", "DISCORD_MAX_TURNS_PER_HOUR",
      "DISCORD_HOME", "WAKU_GRAPH_DISCORD"])
    check fields[2] == ("whatsapp", @["WHATSAPP_TOKEN",
      "WHATSAPP_PHONE_NUMBER_ID", "WHATSAPP_APP_SECRET",
      "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_ALLOWED_PHONE",
      "WAKU_GRAPH_WHATSAPP"])

  test "the first field of each row is the token isConfigured reads":
    # `isConfigured` declares "token present" as the FIRST field, so a
    # registry row reordered by accident would silently unconfigure its
    # gateway — the one failure the fingerprint cannot see.
    for (key, fields) in gatewayEnvFields():
      check fields.len > 0
      case key
      of "telegram": check fields[0] == "TELEGRAM_BOT_TOKEN"
      of "discord": check fields[0] == "DISCORD_BOT_TOKEN"
      of "whatsapp": check fields[0] == "WHATSAPP_TOKEN"
      else: check "unexpected gateway " & key == ""

  test "a non-gateway row never joins the supervisor":
    # `google_calendar` reloads the agent and `obsidian` reloads nothing,
    # so both are none of the supervisor's business — the same filter
    # Python applies with `item.reload.value == "gateway"`.
    for (key, _) in gatewayEnvFields():
      check key != "google_calendar"
      check key != "obsidian"

# ── reconcile, shutdown and the two panel seams ───────────────────────

suite "phase 7d2 supervisor reconcile":
  test "startup starts the configured gateway and prints its posture":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok"),
                     ("TELEGRAM_ALLOWED_USER", "7")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    check rig.sup.running.getOrDefault("telegram", false)
    check not rig.sup.running.getOrDefault("discord", false)
    check not rig.sup.running.getOrDefault("whatsapp", false)
    check "(telegram) starting:" in r.log
    check r.log.join("\n").contains("reachable by: 1 allowlisted user(s)")

  test "an unconfigured gateway is neither started nor reported":
    # Python's `status()` returns `None` for a key with no handle, which
    # `_status` then reads as "not proven": `found` is that `None`.
    let r = newRig()
    r.env = envOf([("WAKU_HOME", "/tmp")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    let (found, _) = rig.gatewayStatusFn()("telegram")
    check not found

  test "the status seam answers the panel's shape":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    let (found, status) = rig.gatewayStatusFn()("telegram")
    check found
    check status.state == connected
    check status.message == ""
    # a second poller on the same token is the error a person can fix,
    # and it outranks every other report (Python checks it first)
    rig.telegram.conflict = true
    let (_, conflicted) = rig.gatewayStatusFn()("telegram")
    check conflicted.state == error
    check conflicted.message == "another instance is polling this token"
    # a handle the supervisor forgot reads as absent, like `None`
    rig.telegram.conflict = false
    rig.sup.running["telegram"] = false
    let (gone, _) = rig.gatewayStatusFn()("telegram")
    check not gone

  test "a broken turn shows up on the panel, not only in the terminal":
    # 7d1's `accountedRespond` records the failure on the runner the
    # handle owns; this is the seam that makes the dashboard read it.
    let r = newRig()
    r.answers = @[updatesBody(1, "hello")]
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r, respond =
      proc(source: string): RespondFn {.closure.} =
        proc(text: string): string =
          raise newException(CatchableError, "model refused")))
    rig.reconcileHook()()
    discard rig.gatewayTick()
    let (_, status) = rig.gatewayStatusFn()("telegram")
    check status.state == error
    check "message handling" in status.message
    check r.posts == @[gatewayErrorReply]

  test "a changed token restarts the gateway, an unchanged one does not":
    # `reconcile` fingerprints the env, so a save that rewrites the same
    # value must not bounce a live bot. Observable offline through the
    # poller state a fresh starter resets — and through the fact that the
    # rig reads the env LIVE, so the edit reaches the next reconcile.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    rig.telegram.offset = 99
    discard rig.reloadHook()(@["telegram"])
    check rig.telegram.offset == 99      # same fingerprint: still running
    r.env["TELEGRAM_BOT_TOKEN"] = "tok2"
    let statuses = rig.reloadHook()(@["telegram"])
    check rig.telegram.offset == 0       # fresh handle: a new poll offset
    check statuses["telegram"].state == connected

  test "clearing the token stops the gateway instead of failing":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    r.env["TELEGRAM_BOT_TOKEN"] = ""
    discard rig.reloadHook()(@["telegram"])
    check not rig.sup.running.getOrDefault("telegram", false)
    let (found, _) = rig.gatewayStatusFn()("telegram")
    check not found

  test "shutdown stops every gateway and forgets them":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok"),
                     ("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, dialOk = false))
    rig.reconcileHook()()
    check rig.sup.running.len == 2
    rig.shutdownHook()()
    check rig.sup.running.len == 0
    check rig.sup.fingerprints.len == 0
    check rig.sup.snapshots.len == 0
    check not rig.telegram.running
    check not rig.discord.running

# ── the tick between browser requests ─────────────────────────────────

suite "phase 7d2 supervisor tick":
  test "one tick answers the queued telegram update":
    let r = newRig()
    r.answers = @[updatesBody(1, "hello there")]
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    check rig.gatewayTick()               # it answered something
    check r.turns == @["telegram: hello there"]
    check "you › hello there" in r.log
    check "waku › re:hello there" in r.log
    check r.posts == @["re:hello there"]

  test "a tick with nothing queued reports no work":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    check not rig.gatewayTick()
    check r.turns.len == 0

  test "an unconfigured gateway is never polled":
    # No token means no long-poll: the dashboard must not call the Bot API
    # for a gateway nobody configured, which is what PTB's missing-token
    # guard exists to avoid.
    let r = newRig()
    r.env = envOf([("WAKU_HOME", "/tmp")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    check not rig.gatewayTick()
    check r.turns.len == 0

  test "a stranger gets the refusal and no turn":
    let r = newRig()
    r.answers = @[updatesBody(1, "let me in")]
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok"),
                     ("TELEGRAM_ALLOWED_USER", "9")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    discard rig.gatewayTick()
    check r.turns.len == 0
    check r.posts == @[telegramRefusal]

  test "a dead token stops the poller and shows on the panel":
    # `telegramPoll`'s own policy: an `HttpRequestError` the API refused
    # is fatal, and the handle reports itself stopped — which is what the
    # dashboard then shows instead of a bot that looks alive. The tick
    # after it must not re-poll: a dead token stays dead until a save.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    var hooks = testHooks(r)
    hooks.telegramHttp = proc(url, payload: string): string {.closure.} =
      raise newException(HttpRequestError, "HttpRequestError: 401")
    let rig = newGatewayRig(hooks)
    rig.reconcileHook()()
    check not rig.gatewayTick()
    let (found, status) = rig.gatewayStatusFn()("telegram")
    check found
    check status.state == error
    check status.message == "gateway stopped unexpectedly"
    check r.log.join("\n").contains("(telegram) background poller stopped")

  test "the poll shortens its long-poll so the browser is never parked":
    # Python runs the poller on a thread, where its `timeout=10` never
    # reaches a browser request; the port polls between requests, so the
    # server-side wait has to be the zero that answers immediately.
    check gatewayTickPollTimeout == 0

# ── the supervised discord gateway ────────────────────────────────────

suite "phase 7d2 supervised discord":
  test "a refused dial is reported once and reads as stopped":
    let r = newRig()
    r.env = envOf([("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, dialOk = false,
      dialWhy = "(discord) no TLS in this build"))
    rig.reconcileHook()()
    check "(discord) starting:" in r.log
    check not rig.gatewayTick()
    check "(discord) no TLS in this build" in r.log
    let (found, status) = rig.gatewayStatusFn()("discord")
    check found
    check status.state == error
    check status.message == "gateway stopped unexpectedly"
    # and it stays reported instead of hot-looping the dial every pass
    discard rig.gatewayTick()
    check r.dials == @["dtok"]

  test "the panel reads 'starting' until the gateway is ready":
    let r = newRig()
    r.env = envOf([("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    let (_, status) = rig.gatewayStatusFn()("discord")
    check status.state == error
    check status.message == "starting"

  test "a message off the wire runs a turn through the shared runner":
    let r = newRig()
    r.env = envOf([("DISCORD_BOT_TOKEN", "dtok"),
                     ("DISCORD_ALLOWED_USER", "7")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    r.feed([$(%*{"op": 10, "d": {"heartbeat_interval": 41250}})])
    discard rig.gatewayTick()              # hello: identify + first beat
    r.feed([$(%*{"op": 0, "t": "READY", "s": 1, "d": {
      "session_id": "sess-1", "user": {"id": "42"}}})])
    discard rig.gatewayTick()              # ready
    var msg = %*{"op": 0, "t": "MESSAGE_CREATE", "s": 2, "d": {
      "id": "99", "content": "ping <@42>", "channel_id": "c1",
      "author": {"id": "7"}}}
    msg["d"]["mentions"] = %*[{"id": "42"}]
    r.feed([$msg])
    discard rig.gatewayTick()
    check r.turns == @["discord: ping"]
    check "you › ping" in r.log
    check r.posts == @["re:ping"]
    let (_, status) = rig.gatewayStatusFn()("discord")
    check status.state == connected

  test "a gateway stop drops the socket instead of dialling again":
    let r = newRig()
    r.env = envOf([("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    r.feed([$(%*{"op": 10, "d": {"heartbeat_interval": 41250}})])
    discard rig.gatewayTick()
    rig.stopHook()("discord")
    discard rig.gatewayTick()
    check r.dials.len == 1

  test "a gateway that keeps asking to reconnect eventually gives up":
    # op 7 in a row is the shape a flapping connection has. Python's
    # library retries forever; this port caps the consecutive dials (the
    # same cap `discordServe` documents) so the dashboard does not spend
    # its life dialling, and says so once on the terminal.
    let r = newRig()
    r.env = envOf([("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    for _ in 0 .. 8:
      r.feed([$(%*{"op": 7, "d": {}})])
      discard rig.gatewayTick()
    check r.dials.len == discordDialBudget
    check discordDialBudgetLine in r.log
    let (found, status) = rig.gatewayStatusFn()("discord")
    check found
    check status.state == error
    check status.message == "gateway stopped unexpectedly"

  test "a connection that worked pays no debt to the ones that failed":
    let r = newRig()
    r.env = envOf([("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    r.feed([$(%*{"op": 7, "d": {}})])
    discard rig.gatewayTick()              # one failed session
    r.feed([$(%*{"op": 10, "d": {"heartbeat_interval": 41250}})])
    discard rig.gatewayTick()
    r.feed([$(%*{"op": 0, "t": "READY", "s": 1, "d": {
      "session_id": "s", "user": {"id": "42"}}})])
    discard rig.gatewayTick()              # ready: the budget is fresh
    r.feed([$(%*{"op": 7, "d": {}})])
    discard rig.gatewayTick()
    r.feed([$(%*{"op": 10, "d": {"heartbeat_interval": 41250}})])
    discard rig.gatewayTick()
    check r.dials.len == 3
    check discordDialBudgetLine notin r.log

# ── the one serve loop ────────────────────────────────────────────────

suite "phase 7d2 the one serve loop":
  test "one pass answers the browser, then the webhook, then the gateways":
    # The order IS the point of the single loop: a person waiting on the
    # page is served before a gateway asks its own network.
    let r = newRig()
    r.answers = @[updatesBody(1, "hi")]
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    var order: seq[string] = @[]
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var srv = bareServer("/tmp")
    check multiplexPass(srv, rig, MultiplexSeams(
      browser: proc(s: var DashboardServer): bool {.closure.} =
        order.add("browser")
        true,
      webhook: proc(s: var DashboardServer): bool {.closure.} =
        order.add("webhook")
        false,
      wait: proc(timeoutMs: int) {.closure.} = discard))
    check order == @["browser", "webhook"]
    check r.turns == @["telegram: hi"]

  test "an idle pass waits, a pass that served something does not":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var served = 0
    var idle = false
    var waits = 0
    var srv = bareServer("/tmp")
    let seams = MultiplexSeams(
      browser: proc(s: var DashboardServer): bool {.closure.} =
        if idle:
          return false
        inc served
        return true,
      wait: proc(timeoutMs: int) {.closure.} = inc waits)
    for _ in 0 ..< 3:
      check multiplexStep(srv, rig, seams)   # a request was served
    check served == 3
    check waits == 0                        # never idle: never waited
    idle = true
    for _ in 0 ..< 3:
      check not multiplexStep(srv, rig, seams)
    check waits == 3                        # idle passes pay the wait

  test "a nil seams object is the plain loop, not a crash":
    let r = newRig()
    r.env = envOf([("WAKU_HOME", "/tmp")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var srv = bareServer("/tmp")
    check not multiplexPass(srv, rig, MultiplexSeams())

  test "the webhook channel is silent while the row is off":
    # A dashboard with whatsapp not configured has no listener bound, and
    # the channel must answer "nothing waiting" rather than try to take
    # from a socket nobody opened.
    let r = newRig()
    r.env = envOf([("WAKU_HOME", "/tmp")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var srv = bareServer("/tmp")
    check not rig.webhookStep()(srv)

# ── the idle backoff ──────────────────────────────────────────────────

suite "phase 7d2 idle telegram backoff":
  test "an idle dashboard stops calling getUpdates four times a second":
    # THE pin for L4. One pass with nothing on it used to pay the same
    # 250 ms forever, so an idle bot asked Telegram about updates four
    # times a second all day. The window an idle pass pays now grows with
    # the empty polls behind it, and the ceiling is a constant a reader
    # can point at.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var windows: seq[int] = @[]
    var srv = bareServer("/tmp")
    let seams = MultiplexSeams(
      wait: proc(timeoutMs: int) {.closure.} = windows.add(timeoutMs))
    for _ in 0 ..< 6:
      discard multiplexStep(srv, rig, seams)
    check windows == @[250, 500, 1000, 2000, 2000, 2000]

  test "the window is the base wait doubled per empty poll, up to the cap":
    # The pure policy, pinned apart from the loop: one empty poll pays the
    # cadence the loop already paid (a burst arrives one update at a time,
    # so the first silence is not yet idleness), and every empty poll after
    # it doubles — to the ceiling and no further, however long the
    # dashboard stays idle.
    check telegramIdleWaitMs(0) == dashboardIdleWaitMs
    check telegramIdleWaitMs(1) == dashboardIdleWaitMs
    check telegramIdleWaitMs(2) == dashboardIdleWaitMs * telegramBackoffFactor
    check telegramIdleWaitMs(3) == dashboardIdleWaitMs * 4
    check telegramIdleWaitMs(4) == telegramBackoffMaxMs
    check telegramIdleWaitMs(64) == telegramBackoffMaxMs
    # the guard against walking an int off the end: the wait doubles at most
    # until the cap, so however absurd the count the answer is the cap
    check telegramIdleWaitMs(high(int)) == telegramBackoffMaxMs

  test "a dashboard with no bot never backs off":
    # Nothing to back off: no poller runs, so no empty poll is ever counted
    # and a dashboard with no gateways left keeps the cadence it had.
    let r = newRig()
    r.env = envOf([("WAKU_HOME", "/tmp")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var windows: seq[int] = @[]
    var srv = bareServer("/tmp")
    let seams = MultiplexSeams(
      wait: proc(timeoutMs: int) {.closure.} = windows.add(timeoutMs))
    for _ in 0 ..< 4:
      discard multiplexStep(srv, rig, seams)
    check rig.telegramEmptyPolls == 0
    check windows == @[250, 250, 250, 250]

  test "an update puts the cadence back where it started":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var windows: seq[int] = @[]
    var srv = bareServer("/tmp")
    let seams = MultiplexSeams(
      wait: proc(timeoutMs: int) {.closure.} = windows.add(timeoutMs))
    for _ in 0 ..< 4:                        # four empty polls: at the cap
      discard multiplexStep(srv, rig, seams)
    check windows[^1] == telegramBackoffMaxMs
    r.answers = @[updatesBody(1, "back again")]
    discard multiplexStep(srv, rig, seams)   # the update answers
    check rig.telegramEmptyPolls == 0
    windows.setLen(0)
    for _ in 0 ..< 2:
      discard multiplexStep(srv, rig, seams)
    check windows == @[250, 500]             # growing from the base again

  test "a webhook hit resets the backoff before the gateways are asked":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    for _ in 0 ..< 3:
      discard rig.gatewayTick()
    check rig.telegramEmptyPolls == 3
    var srv = bareServer("/tmp")
    check multiplexPass(srv, rig, MultiplexSeams(
      webhook: proc(s: var DashboardServer): bool {.closure.} = true))
    # the webhook cleared it, and this pass's own empty poll is the first
    # again — the same pass order the loop documents
    check rig.telegramEmptyPolls == 1

  test "a frame off the discord wire resets the backoff too":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok"),
                     ("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    for _ in 0 ..< 3:
      discard rig.gatewayTick()
    check rig.telegramEmptyPolls == 3
    r.feed([$(%*{"op": 10, "d": {"heartbeat_interval": 41250}})])
    discard rig.gatewayTick()               # hello: something arrived
    check rig.telegramEmptyPolls == 0

  test "a stopped poller is no evidence either way":
    # The dead-token pin from 7d2-3, asked the backoff's question. The poll
    # that failed DID run no turn, so it counts; the two ticks after it ran
    # nothing at all, and a poller that cannot ask Telegram must neither
    # keep feeding the count nor clear it.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    var hooks = testHooks(r)
    hooks.telegramHttp = proc(url, payload: string): string {.closure.} =
      raise newException(HttpRequestError, "HttpRequestError: 401")
    let rig = newGatewayRig(hooks)
    rig.reconcileHook()()
    for _ in 0 ..< 3:
      check not rig.gatewayTick()
    check rig.telegramEmptyPolls == 1

  test "a silent discord socket does not clear it":
    # Only a frame off the wire is activity: a Discord gateway with nothing
    # to say (`deTimeout` every tick) leaves the telegram counter alone, so
    # one quiet bot cannot hold another bot at four polls a second.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok"),
                     ("DISCORD_BOT_TOKEN", "dtok")])
    let rig = newGatewayRig(testHooks(r, wire = r.wireOf()))
    rig.reconcileHook()()
    for _ in 0 ..< 3:
      discard rig.gatewayTick()
    check rig.telegramEmptyPolls == 3

  test "a browser request is not the bot's business":
    # Deliberate: the browser channel is what this loop SERVES, not what the
    # bot is doing, so a person refreshing the panel must not reset the
    # poll cadence. The wait's select still wakes for their request the
    # moment it lands, which is why nothing here costs them latency.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    for _ in 0 ..< 3:
      discard rig.gatewayTick()
    check rig.telegramEmptyPolls == 3
    var srv = bareServer("/tmp")
    check multiplexPass(srv, rig, MultiplexSeams(
      browser: proc(s: var DashboardServer): bool {.closure.} = true))
    check rig.telegramEmptyPolls == 4       # no reset, just this pass's poll

  test "a pass that served the browser skips the wait but keeps the count":
    # The two halves of the rule together: a busy pass does not sleep (the
    # burst rule the loop already had), and the next idle pass pays the
    # window the silence behind it earned, browser traffic or not.
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    var windows: seq[int] = @[]
    var srv = bareServer("/tmp")
    let seams = MultiplexSeams(
      wait: proc(timeoutMs: int) {.closure.} = windows.add(timeoutMs))
    for _ in 0 ..< 4:                        # grow to the ceiling
      discard multiplexStep(srv, rig, seams)
    let busy = MultiplexSeams(
      browser: proc(s: var DashboardServer): bool {.closure.} = true,
      wait: proc(timeoutMs: int) {.closure.} =
        windows.add(-timeoutMs))
    check multiplexStep(srv, rig, busy)      # served: no wait at all
    windows.setLen(0)
    discard multiplexStep(srv, rig, seams)
    check windows == @[telegramBackoffMaxMs]

  test "a restarted poller starts from the base cadence":
    let r = newRig()
    r.env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let rig = newGatewayRig(testHooks(r))
    rig.reconcileHook()()
    for _ in 0 ..< 5:
      discard rig.gatewayTick()
    check rig.telegramEmptyPolls == 5
    r.env["TELEGRAM_BOT_TOKEN"] = "tok2"
    discard rig.reloadHook()(@["telegram"])
    check rig.telegramEmptyPolls == 0

# ── the panel driving the supervisor ──────────────────────────────────

suite "phase 7d2 the panel drives the supervisor":
  test "saving a token starts the bot, with no dashboard restart":
    # THE pin for the wiring. Python's dashboard reads `os.environ`, the
    # same mapping a settings save writes, so `reconcile` sees the new
    # token. This port's rig reads the panel's env through a seam instead
    # of holding a copy of it — a Nim `Table` is a value whose assignment
    # copies its buffer, so a rig that stored one would reconcile against
    # the env it was built with and this test would fail with the bot
    # never starting.
    let r = newRig()
    let root = getTempDir() / "waku-sup-hookup-save"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    var d = panelDeps(root, root / ".env")
    proc envLive(): Table[string, string] = d.env
    var hooks = testHooks(r)
    hooks.envOf = envLive
    let rig = newGatewayRig(hooks)
    d.gatewayStatus = rig.gatewayStatusFn()
    d.gatewayReload = rig.reloadHook()
    rig.reconcileHook()()
    check not rig.sup.running.getOrDefault("telegram", false)
    let (status, _, body) = handlePost(d, "/api/connections",
      """{"key": "telegram", "values": {"TELEGRAM_BOT_TOKEN": "tok123"}}""")
    check status == 200
    check rig.sup.running.getOrDefault("telegram", false)
    # the save's own answer carries the status the seam reported, which is
    # what the panel renders beside the row (the GET status subset is 8a's
    # shape and predates the supervisor, so the save answer is the pin)
    check parseJson(body)["view"]["status"]["state"].getStr == "connected"
    removeDir(root)

  test "a refused gateway start fails the save and stays off":
    let r = newRig()
    let root = getTempDir() / "waku-sup-hookup-fail"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    var d = panelDeps(root, root / ".env")
    proc envLive(): Table[string, string] = d.env
    var hooks = testHooks(r)
    hooks.envOf = envLive
    # a bind the OS refuses — the webhook port already taken, which is the
    # failure Python's `start_in_background` also raises. Injected, so this
    # suite still opens no socket.
    hooks.openWebhook = proc(host: string, port: int): Socket {.closure.} =
      raise newException(OSError, "Address already in use")
    let rig = newGatewayRig(hooks)
    d.gatewayStatus = rig.gatewayStatusFn()
    d.gatewayReload = rig.reloadHook()
    d.env["WHATSAPP_TOKEN"] = "t"
    d.env["WHATSAPP_PHONE_NUMBER_ID"] = "p"
    d.env["WHATSAPP_APP_SECRET"] = "s"
    d.env["WHATSAPP_VERIFY_TOKEN"] = "v"
    let (status, _, body) = handlePost(d, "/api/connections",
      """{"key": "whatsapp", "values": {"WHATSAPP_ALLOWED_PHONE": "1555"}}""")
    # Python raises out of `start_in_background` on a bind failure and the
    # save fails with it; the port keeps that: the row's credentials are
    # rolled back and the panel answers `ok: false`, not a 500 and not a
    # green "saved" with a gateway nobody is serving.
    check status == 200          # the API answers 200 with ok:false
    check not parseJson(body)["ok"].getBool(true)
    check not rig.sup.running.getOrDefault("whatsapp", false)
    check d.env.getOrDefault("WHATSAPP_ALLOWED_PHONE", "") == ""
    removeDir(root)