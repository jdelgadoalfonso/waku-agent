## Phase 4e tests: CLI dispatch, snapshot, client config errors.
## Offline only: temp homes, scrubbed env, no network (every clientFor
## failure happens before any socket; runCommand paths tested never pass
## config).
##
## Phase 7d2 changed four of those pins: `telegram`, `discord`,
## `whatsapp` and `voice` are real dispatches now, so they refuse
## honestly (exit 1, a credential or a missing build piece) where the
## phase-4e stub printed "not yet implemented" and exited 0. Every pin
## below passes a temp home as `dotenvStart`, which keeps the `.env`
## walk (now part of a gateway dispatch, as in Python's import-time
## `_load_env`) away from the repo checkout.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import db_connector/db_sqlite

import ../src/cli
import ../src/client
import ../src/config
import ../src/db
import ../src/delegation
import ../src/gateway
import ../src/integrations
import ../src/mcp
import ../src/memory
import ../src/providers
import ../src/waku
import ../src/worker_gather

const scrubNames = ["WAKU_PROVIDER", "WAKU_API_KEY", "WAKU_MODEL",
  "WAKU_SMALL_MODEL", "WAKU_BASE_URL", "WAKU_HOME", "WAKU_MAX_ITERATIONS",
  "WAKU_MAX_TOKENS", "WAKU_HISTORY_TURNS", "WAKU_GRAPH_WORKFLOWS",
  "ANTHROPIC_API_KEY"]

proc scrubEnv(extra: openArray[string] = []): seq[(string, string, bool)] =
  ## Every var the test pins against, gone for the duration of the test.
  ## `extra` carries the per-suite names (a gateway token lives outside
  ## the `WAKU_*` list) with the same save/restore contract.
  for n in scrubNames:
    result.add((n, getEnv(n), existsEnv(n)))
    delEnv(n)
  for n in extra:
    result.add((n, getEnv(n), existsEnv(n)))
    delEnv(n)

proc restoreEnv(saved: seq[(string, string, bool)]) =
  for (n, v, was) in saved:
    if was: putEnv(n, v)
    else: delEnv(n)

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc registryPath(): string =
  ## The real `data/providers.toml` from the repo checkout layout.
  result = parentDir(getCurrentDir()) / "data" / "providers.toml"

proc anthropicKeyEnv(): string =
  for p in loadProviders(registryPath()):
    if p.name == "anthropic":
      return p.keyEnv
  raise newException(ValueError, "no anthropic row in providers.toml")

suite "phase 4e memory snapshot":
  test "empty memory renders counts and nones":
    let home = freshHome("waku-cli-empty")
    let db = connectDb(home)
    let snap = memorySnapshot(db)
    assert "Semantic facts (0)" in snap
    assert "Recent episodes (0)" in snap
    assert "Unconsolidated chat messages: 0" in snap
    assert snap.count("- none yet") == 2
    db.close()
    removeDir(home)

  test "seeded memory renders rows verbatim":
    let home = freshHome("waku-cli-seed")
    let db = connectDb(home)
    db.addFact("Alex", "likes sailing")
    db.addEpisode("shipped the loop", "2026-09-28 10:00")
    db.logChat("hi", "hello")
    let snap = memorySnapshot(db)
    assert "Semantic facts (1)" in snap
    assert "- [alex] likes sailing" in snap
    assert "Recent episodes (1)" in snap
    assert "- 2026-09-28 10:00 - shipped the loop" in snap
    assert "Unconsolidated chat messages: 2" in snap
    db.close()
    removeDir(home)

suite "phase 4e client config":
  test "unknown provider names the visible ones":
    let saved = scrubEnv()
    var s = defaultSettings()
    s.provider = "nope"
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert "Unknown WAKU_PROVIDER 'nope'" in exc.msg
      assert "anthropic" in exc.msg
    restoreEnv(saved)

  test "no key says what to set":
    let saved = scrubEnv()
    var s = defaultSettings()  # provider anthropic, no keys anywhere
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert "No API key for provider 'anthropic'" in exc.msg
      assert anthropicKeyEnv() in exc.msg
      assert "Other providers: " in exc.msg
      assert "anthropic" in exc.msg  # the full visible list, like Python
    restoreEnv(saved)

  test "a key builds the client and fills default models":
    let saved = scrubEnv()
    putEnv(anthropicKeyEnv(), "sk-ant-test")
    var s = defaultSettings()
    let client = clientFor(s, loadProviders(registryPath()), "", "")
    assert not client.create.isNil  # wired, no socket touched
    assert s.model.len > 0  # row defaults applied via models_for
    assert s.smallModel.len > 0
    restoreEnv(saved)

  test "a hidden row names its variable":
    let saved = scrubEnv()
    delEnv("WAKU_PLATFORM_BASE_URL")
    var s = defaultSettings()
    s.provider = "waku-platform"
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert exc.msg == "'waku-platform' is not configured: set " &
        "WAKU_PLATFORM_BASE_URL to enable it."
    restoreEnv(saved)

  test "a pasted smart quote is called out":
    let saved = scrubEnv()
    putEnv(anthropicKeyEnv(), "sk-ant-\u201C")
    var s = defaultSettings()
    try:
      discard clientFor(s, loadProviders(registryPath()), "", "")
      assert false, "must raise"
    except ClientConfigError as exc:
      assert "non-ASCII character" in exc.msg
    restoreEnv(saved)

suite "phase 4e dispatch":
  test "unknown command prints usage and exits 1":
    assert runCommand(@["bogus"]) == 1

  test "dashboard and connect answer their real dispatches":
    # 7d2 moved telegram/discord/whatsapp/voice into the suite below,
    # `connect` runs its real sign-in dispatch (usage with exit 1 when
    # no door is named, like Python), and `dashboard` validates in
    # process, so it answers 0 without serving a socket.
    assert runCommand(@["dashboard"]) == 0
    assert runCommand(@["connect"]) == 1

  test "chat without keys exits 1 before touching disk or net":
    let saved = scrubEnv()
    let home = freshHome("waku-cli-nokey")
    putEnv("WAKU_HOME", home)
    removeDir(home)  # must stay absent: config must fail first
    assert runCommand(@["chat"], home) == 1
    assert not dirExists(home)
    restoreEnv(saved)
    if dirExists(home):
      removeDir(home)

suite "phase 5d2 connections dispatch":
  test "connections exits 0 on a fresh health store":
    if findProvidersToml().len == 0:
      skip()
    else:
      let saved = scrubEnv()
      let home = freshHome("waku-conn-fresh")
      putEnv("WAKU_HOME", home)
      assert runCommand(@["connections"]) == 0
      restoreEnv(saved)
      removeDir(home)

  test "connections exits 1 when a configured row has stored ERROR":
    if findProvidersToml().len == 0:
      skip()
    else:
      let saved = scrubEnv()
      let tgWasSet = existsEnv("TELEGRAM_BOT_TOKEN")
      let tgValue = getEnv("TELEGRAM_BOT_TOKEN")
      let home = freshHome("waku-conn-error")
      putEnv("WAKU_HOME", home)
      putEnv("TELEGRAM_BOT_TOKEN", "sk-tg-test")
      let store = newHealthStore(home)
      recordHealth(store, "telegram",
        IntegrationStatus(state: error, message: "synthetic outage"))
      assert runCommand(@["connections"]) == 1
      if tgWasSet:
        putEnv("TELEGRAM_BOT_TOKEN", tgValue)
      else:
        delEnv("TELEGRAM_BOT_TOKEN")
      restoreEnv(saved)
      removeDir(home)

## Phase 6b: `mcp` dispatch is real (list/login/logout); every other
## later-phase command stays an honest stub (pin 4e). Offline only:
## tmp homes via `WAKU_HOME`, no subprocess, no socket — the login
## paths exercised here fail before any transport (unknown server,
## oauth-needs-6c), and success paths live in `test_mcp.nim` with
## injected `HttpPostFn` fakes.

## Phase 7d2: `waku telegram|discord|whatsapp|voice` are real dispatches
## now, so the phase-4e "honest stub, exit 0" pin above no longer
## applies to them: each command refuses the way Python's `SystemExit`
## did (a sentence on the terminal, exit 1) or, for voice, the way a
## missing key already made `chat` fail.
##
## Offline only: every pin below stops at a refusal that happens BEFORE
## any socket — an unset credential, the missing TLS build piece, a
## missing provider key — so nothing here reaches Telegram, Discord,
## Meta or an LLM. `dotenvStart` is the temp home, which keeps the `.env`
## walk out of the repo checkout (Python loads it at import time).

suite "phase 7d2 gateway dispatch":
  test "telegram without a token refuses like Python, not like the stub":
    let saved = scrubEnv(["TELEGRAM_BOT_TOKEN"])
    let home = freshHome("waku-cli-tg-notoken")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["telegram"], home) == 1
    restoreEnv(saved)
    removeDir(home)

  test "discord without a token refuses like Python, not like the stub":
    let saved = scrubEnv(["DISCORD_BOT_TOKEN"])
    let home = freshHome("waku-cli-discord-notoken")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["discord"], home) == 1
    restoreEnv(saved)
    removeDir(home)

  test "whatsapp without credentials refuses like Python, not the stub":
    let saved = scrubEnv(["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID",
      "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_APP_SECRET"])
    let home = freshHome("waku-cli-wa-notoken")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["whatsapp"], home) == 1
    restoreEnv(saved)
    removeDir(home)

  test "voice without keys exits 1 before it opens a recorder":
    let saved = scrubEnv(["WAKU_STT_COMMAND", "WAKU_MIC_COMMAND"])
    let home = freshHome("waku-cli-voice-nokeys")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["voice"], home) == 1
    restoreEnv(saved)
    removeDir(home)

suite "phase 7d2 gateway refusals":
  # The dispatch pins above go through `runCommand` with the default
  # terminal; these inject a logger so the SENTENCE is pinned too, which
  # is the half a person reads. Python raises `SystemExit` with these
  # words, so they are pinned verbatim.

  test "a missing credential is refused with Python's own wording":
    let saved = scrubEnv(["TELEGRAM_BOT_TOKEN", "DISCORD_BOT_TOKEN",
      "WHATSAPP_TOKEN"])
    let home = freshHome("waku-cli-gw-words")
    putEnv("WAKU_HOME", home)
    var log: seq[string] = @[]
    let record: LogFn = proc(line: string) {.closure.} = log.add(line)
    check runTelegramCmd(home, record) == 1
    check log[^1] == "Set TELEGRAM_BOT_TOKEN in .env (message @BotFather " &
      "to create a bot)."
    log.setLen(0)
    check runDiscordCmd(home, record) == 1
    check log[^1] == "Set DISCORD_BOT_TOKEN in .env (create a bot in the " &
      "Discord Developer Portal)."
    log.setLen(0)
    check runWhatsappCmd(home, record) == 1
    check log[^1].startsWith("Set WHATSAPP_TOKEN in .env (Meta Cloud API " &
      "access token).")
    restoreEnv(saved)
    removeDir(home)

  test "whatsapp names the FIRST missing credential, in Python's order":
    let names = ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID",
      "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_APP_SECRET"]
    let saved = scrubEnv(names)
    let home = freshHome("waku-cli-wa-order")
    putEnv("WAKU_HOME", home)
    for i in 0 ..< names.len:
      var log: seq[string] = @[]
      let record: LogFn = proc(line: string) {.closure.} = log.add(line)
      for j in 0 ..< i:
        putEnv(names[j], "set")
      check runWhatsappCmd(home, record) == 1
      check log.len == 1   # one line, the gap, then it stops
      check ("Set " & names[i] & " in .env") in log[0]
      for j in 0 ..< i:
        delEnv(names[j])
    restoreEnv(saved)
    removeDir(home)

  test "voice with a key but no engines names the first missing engine":
    # A real agent (a key builds a client and touches no socket) in front
    # of `voiceMain`, which is where Python's `sounddevice` check became
    # the three external commands. The session never opens a mic.
    let saved = scrubEnv(["WAKU_STT_COMMAND", "WAKU_MIC_COMMAND",
      "WAKU_TTS_COMMAND"])
    let home = freshHome("waku-cli-voice-noengines")
    putEnv("WAKU_HOME", home)
    putEnv(anthropicKeyEnv(), "sk-ant-test")
    var log: seq[string] = @[]
    let record: LogFn = proc(line: string) {.closure.} = log.add(line)
    check runVoiceCmd(home, record) == 1
    check log.len == 1
    check "WAKU_STT_COMMAND" in log[0]
    restoreEnv(saved)
    removeDir(home)

suite "phase 6b mcp dispatch":
  test "mcp with no config lists empty with exit 0":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-empty")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["mcp"]) == 0
    restoreEnv(saved)
    removeDir(home)

  test "mcp logout of an unknown account exits 0":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-logout")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["mcp", "logout", "ghost"]) == 0
    restoreEnv(saved)
    removeDir(home)

  test "mcp login on unknown and oauth servers exits 1 without transport":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-login")
    putEnv("WAKU_HOME", home)
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://h2/m", "oauth": true}]}""")
    assert runCommand(@["mcp", "login", "nope"]) == 1
    assert runCommand(@["mcp", "login", "o"]) == 1
    restoreEnv(saved)
    removeDir(home)

  test "mcp with the wrong shape exits 1 (no longer a stub)":
    let saved = scrubEnv()
    let home = freshHome("waku-mcp-cli-shape")
    putEnv("WAKU_HOME", home)
    assert runCommand(@["mcp", "login"]) == 1
    assert runCommand(@["mcp", "bogus", "extra", "args"]) == 1
    restoreEnv(saved)
    removeDir(home)

## Phase 6c wiring: `runMcpCmd` passes `oauthFlowWith` over the live
## adapters, so an oauth login reaches the browser flow instead of the
## honest no-seam refusal. Offline only: the flow below is the exact
## `oauthFlowWith` constructor the binary passes, over recorded seams
## (no socket, no browser, no clock) — the live adapters are never
## called here.

suite "phase 6c oauth wiring":
  test "oauthFlowWith over recorded seams signs in without the seam error":
    let home = freshHome("waku-cli-oauth-wired")
    writeFile(home / "mcp.json", """{"servers": [
      {"name": "o", "url": "https://rs.example/mcp", "oauth": true}]}""")
    let get: HttpGetFn = proc(url, bearer: string): tuple[status: int,
        body: string] {.closure.} =
      if url.endsWith("/.well-known/oauth-protected-resource/mcp"):
        return (200,
          """{"authorization_servers": ["https://idp.example"]}""")
      if url == "https://idp.example/.well-known/oauth-authorization-server":
        return (200,
          """{"authorization_endpoint": "https://idp.example/authorize",
          "token_endpoint": "https://idp.example/token",
          "registration_endpoint": "https://idp.example/register"}""")
      return (404, "{}")
    let post: HttpPostFn = proc(url, body, sessionId,
        bearer: string): HttpResult {.closure.} =
      if url == "https://idp.example/register":
        return HttpResult(status: 201,
          body: """{"client_id": "cid123"}""", sessionId: "")
      assert url == "https://idp.example/token"
      return HttpResult(status: 200,
        body: """{"access_token": "tok"}""", sessionId: "")
    var browserUrl = ""
    let browser: BrowserFn = proc(url: string): bool {.closure.} =
      browserUrl = url
      return true
    let wait: CallbackWaitFn = proc(port: int, path: string,
        maxAttempts: int): string {.closure.} =
      var state = ""
      let q = browserUrl.split('?')
      if q.len > 1:
        for part in q[1].split('&'):
          if part.startsWith("state="):
            state = part[6 .. ^1]
      return "/callback?code=authcode123&state=" & state
    let rng: RandIntFn = proc(maxExclusive: int): int {.closure.} =
      7 mod maxExclusive
    var env = initTable[string, string]()
    let flow = oauthFlowWith(post, get, browser, wait, rng)
    let (ok, msg) = mcpLogin(home, "o", env, nil, nil, 1700000000'i64,
      30.0, flow)
    assert ok
    assert "unknown account" in msg
    assert "OAuthFlowFn" notin msg
    assert browserUrl.startsWith("https://idp.example/authorize?")
    removeDir(home)

suite "phase 15 evals turns command":
  test "a bad window names the choices and exits 2":
    let saved = scrubEnv()
    let home = freshHome("waku-cli-evals-badwin")
    assert runEvalsTurnsCmd(home, @["--window", "fortnight"]) == 2
    restoreEnv(saved)
    removeDir(home)

  test "a dangling --window names the choices and exits 2":
    let saved = scrubEnv()
    let home = freshHome("waku-cli-evals-dangwin")
    assert runEvalsTurnsCmd(home, @["--window"]) == 2
    restoreEnv(saved)
    removeDir(home)

  test "turns print offline from the home's traces":
    let saved = scrubEnv()
    let home = freshHome("waku-cli-evals-turns")
    createDir(home / "traces")
    putEnv("WAKU_HOME", home)
    assert runEvalsTurnsCmd(home, @[]) == 0
    assert runEvalsTurnsCmd(home, @["--window", "all"]) == 0
    restoreEnv(saved)
    removeDir(home)

  test "evals routes to turns, bare evals prints usage":
    assert runCommand(@["evals"]) == 1

suite "slice 2b worker role":
  test "a gather task answers with the worker's child lines":
    let task = makeTaskLine("t_a", "t_b", "gather news", "", 1000, 1)
    let fake: GatherFn = proc(): JsonNode = %*{"digest": "five things",
      "draft_path": "/tmp/draft.md"}
    let lines = workerChildLines("gather", $task, fake)
    assert lines.len == 2
    assert lines[0]["type"].getStr() == "event"
    assert lines[1]["type"].getStr() == "done"
    assert lines[1]["payload"]["reply"].getStr() == "five things"
    assert lines[1]["trace_id"].getStr() == "t_a"
    assert lines[1]["turn_id"].getStr() == "t_b"

  test "an agent with no worker answers one error line and never gathers":
    var called = false
    let fake: GatherFn = proc(): JsonNode =
      called = true
      newJObject()
    let lines = workerChildLines("brief", "", fake)
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    assert "no worker" in lines[0]["payload"]["message"].getStr()
    assert not called

  test "an unreadable line answers one error line, never a raise":
    let lines = workerChildLines("gather", "not json",
      proc(): JsonNode = newJObject())
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    assert "not JSON" in lines[0]["payload"]["message"].getStr()

  test "a structurally invalid task answers one error line":
    let lines = workerChildLines("gather", """{"v": 9}""",
      proc(): JsonNode = newJObject())
    assert lines.len == 1
    assert lines[0]["type"].getStr() == "error"
    assert "invalid task" in lines[0]["payload"]["message"].getStr()

  test "dispatch: a worker for an unknown agent exits 0 without an app":
    let saved = scrubEnv()
    let home = freshHome("waku-cli-worker-unknown")
    # No app, no stdin read: the line is the answer, and an error line
    # carries no reply so the parent fails open to its own loop.
    assert runCommand(@["--role", "worker", "--agent", "brief"], home) == 0
    assert not fileExists(home / ".env")
    restoreEnv(saved)
    removeDir(home)

  test "dispatch: a non-worker role prints usage and exits 1":
    assert runCommand(@["--role", "orchestrator"]) == 1
