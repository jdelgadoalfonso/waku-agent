## Phase 7a tests: gateway infra (runner + supervisor) + Telegram Bot API.
##
## Offline only: every side effect travels through an injected seam
## (`RespondFn`/`SendFn` for turns, `TelegramHttpFn` for Bot API calls,
## `StarterFn`/`StopFn`/`StatusFn` for the supervisor, `env` as a `Table`).
## No socket, no subprocess, no audio, no real environment mutation beyond
## the caller-owned table the supervisor is given.

import std/json
import std/sets
import std/strutils
import std/tables
import std/unittest

import ../src/gateway
import ../src/telegram

proc envOf(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (k, v) in pairs:
    result[k] = v

proc idsOf(items: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  for it in items:
    result.incl(it)

# ── runner: safeException ──────────────────────────────────────────────

suite "phase 7a safeException":
  test "redacts configured secrets, longest first":
    let env = envOf([("OPENAI_API_KEY", "sk-abc"),
      ("TELEGRAM_BOT_TOKEN", "tok123"), ("PLAIN", "sk-abc")])
    let msg = safeException("RuntimeError", "call with sk-abc and tok123 failed",
      env)
    assert msg == "RuntimeError: call with *** and *** failed"

  test "only suffixed key names count, short values are ignored":
    let env = envOf([("MY_TOKEN_STORE", "tok123"), ("TINY_SECRET", "abc"),
      ("REAL_SECRET", "shhh-x")])
    let msg = safeException("ValueError", "leak tok123 abc shhh-x here", env)
    assert "tok123" in msg  # _STORE is not a secret suffix: untouched
    assert "abc" in msg     # shorter than 4 chars: untouched
    assert "shhh-x" notin msg

  test "empty message becomes no details, long messages truncate at 500":
    let env = initTable[string, string]()
    assert safeException("Oops", "", env) == "Oops: no details"
    let long = safeException("E", repeat('x', 600), env)
    assert long == "E: " & repeat('x', 500)

# ── runner: RunnerState + runGatewayTurn ───────────────────────────────

suite "phase 7a runner state":
  test "record shapes the dashboard status and returns the redacted detail":
    var r = newRunnerState("telegram")
    let env = envOf([("TELEGRAM_BOT_TOKEN", "tok123")])
    let detail = r.recordError("RuntimeError", "boom tok123", env,
      "message handling")
    assert detail == "RuntimeError: boom ***"
    assert r.errorStatus() ==
      "message handling failed (RuntimeError) — see dashboard terminal"
    r.clearError()
    assert r.errorStatus() == ""

  test "a closed runner refuses new turns naming its source":
    var r = newRunnerState("telegram")
    r.closeRunner()
    let respond: RespondFn = proc(text: string): string {.closure.} = "hi"
    let send: SendFn = proc(text: string) {.closure.} = discard
    let log: LogFn = proc(line: string) {.closure.} = discard
    try:
      discard runGatewayTurn(r, "hello", respond, send, log)
      assert false, "must raise"
    except CatchableError as exc:
      assert exc.msg == "telegram gateway runner is closed"

suite "phase 7a runGatewayTurn":
  test "success logs both sides, delivers the reply, clears stale errors":
    var r = newRunnerState("telegram")
    discard r.recordError("E", "old", initTable[string, string](), "x")
    var logs: seq[string] = @[]
    var sent: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} =
      assert text == "hello"
      return "hi there"
    let send: SendFn = proc(text: string) {.closure.} = sent.add(text)
    let log: LogFn = proc(line: string) {.closure.} = logs.add(line)
    assert runGatewayTurn(r, "hello", respond, send, log)
    assert logs == @["you › hello", "waku › hi there"]
    assert sent == @["hi there"]
    assert r.errorStatus() == ""

  test "empty replies deliver the no-reply placeholder":
    var r = newRunnerState("telegram")
    var sent: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} = ""
    let send: SendFn = proc(text: string) {.closure.} = sent.add(text)
    let log: LogFn = proc(line: string) {.closure.} = discard
    assert runGatewayTurn(r, "hello", respond, send, log)
    assert sent == @["(no reply)"]

  test "respond failure sends the error reply and logs the redacted cause":
    var r = newRunnerState("telegram")
    var logs: seq[string] = @[]
    var sent: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} =
      raise newException(CatchableError, "llm down")
    let send: SendFn = proc(text: string) {.closure.} = sent.add(text)
    let log: LogFn = proc(line: string) {.closure.} = logs.add(line)
    assert not runGatewayTurn(r, "hello", respond, send, log,
      envOf([("X_API_KEY", "k")]))
    assert sent == @[gatewayErrorReply]
    assert logs[1] ==
      "(telegram) message handling failed: CatchableError: llm down"

  test "send failure records reply delivery and keeps the turn failed":
    var r = newRunnerState("telegram")
    var logs: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} = "ok"
    let send: SendFn = proc(text: string) {.closure.} =
      raise newException(IOError, "net down")
    let log: LogFn = proc(line: string) {.closure.} = logs.add(line)
    assert not runGatewayTurn(r, "hello", respond, send, log,
      initTable[string, string]())
    assert r.errorStatus() ==
      "reply delivery failed (IOError) — see dashboard terminal"
    assert logs[^1] == "(telegram) reply delivery failed: IOError: net down"

  test "error-reply delivery failure records its own action":
    var r = newRunnerState("telegram")
    var logs: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} =
      raise newException(CatchableError, "llm down")
    let send: SendFn = proc(text: string) {.closure.} =
      raise newException(IOError, "net down")
    let log: LogFn = proc(line: string) {.closure.} = logs.add(line)
    assert not runGatewayTurn(r, "hello", respond, send, log,
      initTable[string, string]())
    assert r.errorStatus() ==
      "error reply delivery failed (IOError) — see dashboard terminal"
    assert logs[^1] ==
      "(telegram) error reply delivery failed: IOError: net down"

# ── supervisor ─────────────────────────────────────────────────────────

suite "phase 7a supervisor":
  test "unconfigured keys stay stopped and report nothing":
    var stopped: seq[string] = @[]
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} = true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = stopped.add(key)))
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    var env = initTable[string, string]()
    let res = sup.reconcile(env, @["tg"], statusOf)
    assert res.len == 0
    assert stopped.len == 0

  test "configured keys start once and reuse the handle while env is stable":
    var starts = 0
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} =
        inc starts
        return true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = discard))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    let first = sup.reconcile(env, @["tg"], statusOf)
    assert first["tg"].ok
    assert first["tg"].message == "connected"
    discard sup.reconcile(env, @["tg"], statusOf)
    assert starts == 1

  test "a token change restarts stop-then-start":
    var events: seq[string] = @[]
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} =
        events.add("start")
        return true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = events.add("stop")))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "one")])
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    discard sup.reconcile(env, @["tg"], statusOf)
    env["TELEGRAM_BOT_TOKEN"] = "two"
    discard sup.reconcile(env, @["tg"], statusOf)
    assert events == @["start", "stop", "start"]

  test "unsetting the token stops a running gateway":
    var stopped: seq[string] = @[]
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} = true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = stopped.add(key)))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    discard sup.reconcile(env, @["tg"], statusOf)
    env.del("TELEGRAM_BOT_TOKEN")
    let res = sup.reconcile(env, @["tg"], statusOf)
    assert res.len == 0
    assert stopped == @["tg"]

  test "a declined start reports gateway failed to start":
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} = false)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = discard))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    let res = sup.reconcile(env, @["tg"], statusOf)
    assert not res["tg"].ok
    assert res["tg"].message == "gateway failed to start"

  test "a failed restart restores the old instance and the desired env":
    var attempts = 0
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} =
        inc attempts
        if attempts == 2:
          raise newException(IOError, "port busy")
        return true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = discard))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "old")])
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    discard sup.reconcile(env, @["tg"], statusOf)
    env["TELEGRAM_BOT_TOKEN"] = "new"
    let res = sup.reconcile(env, @["tg"], statusOf)
    assert not res["tg"].ok
    assert res["tg"].message == "port busy"
    assert env["TELEGRAM_BOT_TOKEN"] == "new"  # desired env restored
    let (present, _) = sup.supervisorStatus("tg", statusOf)
    assert present  # the old instance is back

  test "status of an unknown key is absent, status errors are reports":
    let noStarters: seq[(string, StarterFn)] = @[]
    let noFields: seq[(string, seq[string])] = @[]
    var sup = newSupervisor(noStarters, noFields,
      StopFn(proc(key: string) {.closure.} = discard))
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      raise newException(ValueError, "boom")
    let (present, _) = sup.supervisorStatus("ghost", statusOf)
    assert not present
    var sup2 = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} = true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = discard))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    discard sup2.reconcile(env, @["tg"], statusOf)
    let (present2, rep) = sup2.supervisorStatus("tg", statusOf)
    assert present2
    assert not rep.ok
    assert rep.message == "boom"

  test "shutdown stops every handle and forgets fingerprints":
    var stopped: seq[string] = @[]
    var sup = newSupervisor({"tg": StarterFn(
      proc(): bool {.closure.} = true)},
      {"tg": @["TELEGRAM_BOT_TOKEN"]},
      StopFn(proc(key: string) {.closure.} = stopped.add(key)))
    var env = envOf([("TELEGRAM_BOT_TOKEN", "tok")])
    let statusOf: StatusFn = proc(key: string): GatewayReport {.closure.} =
      GatewayReport(ok: true, message: "connected")
    discard sup.reconcile(env, @["tg"], statusOf)
    sup.supervisorShutdown()
    assert stopped == @["tg"]
    let (present, _) = sup.supervisorStatus("tg", statusOf)
    assert not present

# ── telegram: allowlist + posture ─────────────────────────────────────

suite "phase 7a telegram gate":
  test "allowlist parsing drops blanks and trims":
    assert parseAllowedIds("") == idsOf([])  # empty means no restriction
    assert parseAllowedIds("  123 ,, 456 ") == idsOf(["123", "456"])

  test "posture names both stances verbatim":
    assert posture(idsOf(["1", "2"])) == "  reachable by: 2 allowlisted user(s)"
    let open = posture(idsOf([]))
    assert open.startsWith("  reachable by: ANYONE who finds this bot")
    assert "TELEGRAM_ALLOWED_USER" in open

  test "empty allowlist lets anyone in, otherwise only members":
    assert isTelegramAllowed(idsOf([]), "999")
    assert isTelegramAllowed(idsOf(["42"]), "42")
    assert not isTelegramAllowed(idsOf(["42"]), "7")

  test "classification refuses strangers, skips empties, answers the rest":
    let ids = idsOf(["42"])
    let stranger = TelegramUpdate(updateId: 1, chatId: 9, userId: "7",
      text: "hello")
    assert classifyTelegram(ids, stranger) == taRefuse
    assert classifyTelegram(ids,
      TelegramUpdate(updateId: 2, chatId: 9, userId: "42",
        text: "")) == taSkip
    assert classifyTelegram(ids,
      TelegramUpdate(updateId: 3, chatId: 9, userId: "42",
        text: "hello")) == taAnswer

  test "the refusal names running your own":
    assert telegramRefusal ==
      "This Waku serves someone else. Run your own!"

# ── telegram: Bot API wire ────────────────────────────────────────────

suite "phase 7a telegram wire":
  test "api urls carry the token and method":
    assert apiUrl("tok123", "sendMessage") ==
      "https://api.telegram.org/bottok123/sendMessage"

  test "send bodies carry chat and text":
    let body = buildSendBody(99, "hi")
    assert body["chat_id"].getInt() == 99
    assert body["text"].getStr() == "hi"

  test "updates parse text, skip commands-by-entity and non-text":
    let payload = """{"ok": true, "result": [
      {"update_id": 10, "message": {"chat": {"id": 5},
        "from": {"id": 42}, "text": "hello"}},
      {"update_id": 11, "message": {"chat": {"id": 5},
        "from": {"id": 42}, "text": "/start",
        "entities": [{"type": "bot_command", "offset": 0, "length": 6}]}},
      {"update_id": 12, "message": {"chat": {"id": 5},
        "from": {"id": 42}, "text": "/not-a-command"}},
      {"update_id": 13, "message": {"chat": {"id": 5},
        "from": {"id": 42}, "photo": []}}]}"""
    let updates = parseUpdates(payload)
    assert updates.len == 2
    assert updates[0].updateId == 10
    assert updates[0].chatId == 5
    assert updates[0].userId == "42"
    assert updates[0].text == "hello"
    assert updates[1].text == "/not-a-command"

  test "send posts to sendMessage and reads the ok flag":
    var seen: seq[(string, string)] = @[]
    let http: TelegramHttpFn = proc(url, payload: string): string {.closure.} =
      seen.add((url, payload))
      return """{"ok": true}"""
    assert sendTelegramText(http, "tok123", 5, "hi")
    assert seen.len == 1
    assert seen[0][0] ==
      "https://api.telegram.org/bottok123/sendMessage"
    let body = parseJson(seen[0][1])
    assert body["chat_id"].getInt() == 5
    assert body["text"].getStr() == "hi"

  test "send reports ok:false without raising":
    let http: TelegramHttpFn = proc(url, payload: string): string {.closure.} =
      return """{"ok": false, "description": "blocked"}"""
    assert not sendTelegramText(http, "tok", 5, "hi")

  test "fetch polls getUpdates with offset and timeout, offset advances":
    var seenUrl = ""
    let http: TelegramHttpFn = proc(url, payload: string): string {.closure.} =
      seenUrl = url
      assert payload == ""
      return """{"ok": true, "result": [
        {"update_id": 7, "message": {"chat": {"id": 1},
          "from": {"id": 2}, "text": "a"}},
        {"update_id": 9, "message": {"chat": {"id": 1},
          "from": {"id": 2}, "text": "b"}}]}"""
    let updates = fetchTelegramUpdates(http, "tok", 7, 30)
    assert seenUrl ==
      "https://api.telegram.org/bottok/getUpdates?offset=7&timeout=30"
    assert updates.len == 2
    assert nextTelegramOffset(updates, 7) == 10
    assert nextTelegramOffset(@[], 7) == 7
