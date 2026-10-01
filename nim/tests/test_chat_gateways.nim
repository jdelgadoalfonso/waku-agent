## Phase 7b tests: discord + whatsapp chat gateways.
##
## Offline only: policy procs are pure, REST travels through injected
## `DiscordHttpFn`/`WhatsappHttpFn` fakes (recorded status ints, zero
## sockets), and the HMAC is pinned by RFC 4231 vectors plus one
## waku-shaped case cross-checked against Python's `hmac`. The live
## adapters (`liveDiscordPost`, `liveWhatsappPost`) are never called;
## the live end (`receiveDiscordEvent`) raises
## honestly naming 7d and are pinned doing exactly that.
##
## Split from `test_gateway.nim` on purpose: that file already covers
## three concerns (runner policy, supervisor lifecycle, telegram poll),
## and stuffing two more gateways into it would push it past 60 tests.
## Discord + whatsapp form one coherent unit — chat-gateway policy plus
## REST seams plus webhook HMAC — and 7c (voice) / 7d (live loops) will
## each deserve their own file. Call sites: `waku/gateway/discord.py`
## (`should_answer`, `_strip_mention`, `TurnBudget`, `describe_posture`,
## channel-message REST) and `waku/gateway/whatsapp.py` (GET verify,
## `X-Hub-Signature-256`, payload walk, Graph API send).

import std/json
import std/sets
import std/strutils
import std/unittest

import ../src/discord
import ../src/whatsapp

proc idsOf(items: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  for it in items:
    result.incl(it)

# ── discord: access policy (should_answer) ─────────────────────────────

suite "phase 7b discord policy":
  test "DMs are answered when nothing is configured":
    assert shouldAnswer(isDm = true, authorId = "1", channelId = "9",
      mentioned = false, allowedUsers = idsOf([]),
      allowedChannels = idsOf([]), requireMention = true)

  test "a user allowlist excludes strangers even in DMs":
    assert not shouldAnswer(isDm = true, authorId = "7", channelId = "9",
      mentioned = false, allowedUsers = idsOf(["42"]),
      allowedChannels = idsOf([]), requireMention = true)
    assert shouldAnswer(isDm = true, authorId = "42", channelId = "9",
      mentioned = false, allowedUsers = idsOf(["42"]),
      allowedChannels = idsOf([]), requireMention = true)

  test "empty channel allowlist answers no channel: deny by default":
    # The load-bearing line: UNSET means no channel, not every channel.
    assert not shouldAnswer(isDm = false, authorId = "1", channelId = "9",
      mentioned = true, allowedUsers = idsOf([]),
      allowedChannels = idsOf([]), requireMention = true)

  test "allowlisted channel plus mention is answered":
    assert shouldAnswer(isDm = false, authorId = "1", channelId = "9",
      mentioned = true, allowedUsers = idsOf([]),
      allowedChannels = idsOf(["9"]), requireMention = true)

  test "channels stay silent without the mention unless waived":
    assert not shouldAnswer(isDm = false, authorId = "1", channelId = "9",
      mentioned = false, allowedUsers = idsOf([]),
      allowedChannels = idsOf(["9"]), requireMention = true)
    assert shouldAnswer(isDm = false, authorId = "1", channelId = "9",
      mentioned = false, allowedUsers = idsOf([]),
      allowedChannels = idsOf(["9"]), requireMention = false)

  test "the user allowlist also gates channel traffic":
    assert not shouldAnswer(isDm = false, authorId = "7", channelId = "9",
      mentioned = true, allowedUsers = idsOf(["42"]),
      allowedChannels = idsOf(["9"]), requireMention = true)

# ── discord: mention strip + spend stop ────────────────────────────────

suite "phase 7b discord mention and budget":
  test "both mention forms are dropped and the rest trimmed":
    assert stripMention("<@123> hello", "123") == "hello"
    assert stripMention("hello <@!123>", "123") == "hello"
    assert stripMention("<@123>  <@!123> ", "123") == ""

  test "plain text and other ids pass through":
    assert stripMention("hello there", "123") == "hello there"
    assert stripMention("<@999> hello", "123") == "<@999> hello"

  test "the budget allows up to the cap, then goes silent":
    var b = newDiscordBudget(2)
    assert b.budgetAllow(1000.0)
    assert b.budgetAllow(1001.0)
    assert not b.budgetAllow(1002.0)

  test "turns older than an hour fall out of the window":
    var b = newDiscordBudget(1)
    assert b.budgetAllow(0.0)
    assert not b.budgetAllow(3599.0)
    assert b.budgetAllow(3600.0)

# ── discord: posture + env parsing ─────────────────────────────────────

suite "phase 7b discord posture and env":
  test "closed posture names counts, mention rule, home and cap":
    let got = describePosture(idsOf(["1", "2"]), idsOf(["9"]), "/bot/.waku",
      "30")
    assert got == "  reachable by: 2 allowlisted user(s)\n" &
      "  answers in:   1 allowlisted channel(s), @mention required\n" &
      "  memory:       /bot/.waku\n" &
      "  spend cap:    30 turns/hour"

  test "open posture warns DMs-only with the personal-memory line":
    let got = describePosture(idsOf([]), idsOf([]), "", "30")
    assert got == "  reachable by: anyone who can DM it\n" &
      "  answers in:   DMs only — no server channel will be answered\n" &
      "  memory:       .waku — YOUR personal memory\n" &
      "  spend cap:    30 turns/hour"

  test "id parsing trims and drops blanks":
    assert parseDiscordIds("") == idsOf([])
    assert parseDiscordIds("  123 ,, 456 ") == idsOf(["123", "456"])

  test "only empty and 0 waive the mention":
    assert parseRequireMention("1")
    assert parseRequireMention("yes")
    assert not parseRequireMention("0")
    assert not parseRequireMention("")
    assert not parseRequireMention(" 0 ")

  test "turn cap parses, garbage raises like Python int()":
    assert parseTurnCap("30") == 30
    assert parseTurnCap(" 45 ") == 45
    try:
      discard parseTurnCap("many")
      assert false, "must raise"
    except ValueError:
      discard

  test "the first env field is the token":
    assert discordEnvFields[0] == "DISCORD_BOT_TOKEN"

# ── discord: REST send seam ────────────────────────────────────────────

suite "phase 7b discord wire":
  test "send posts content to the channel endpoint with the bot token":
    var seenUrl, seenBody, seenToken = ""
    let http: DiscordHttpFn =
      proc(url, payload, token: string): int {.closure.} =
        seenUrl = url
        seenBody = payload
        seenToken = token
        return 201
    assert sendDiscordText(http, "tok123", "9", "hi")
    assert seenUrl ==
      "https://discord.com/api/v10/channels/9/messages"
    assert parseJson(seenBody)["content"].getStr() == "hi"
    assert seenToken == "tok123"

  test "an error status reads as delivery outcome, not a raise":
    let http: DiscordHttpFn =
      proc(url, payload, token: string): int {.closure.} = 429
    assert not sendDiscordText(http, "tok", "9", "hi")

  test "transport failure propagates to runGatewayTurn":
    let http: DiscordHttpFn =
      proc(url, payload, token: string): int {.closure.} =
        raise newException(IOError, "net down")
    try:
      discard sendDiscordText(http, "tok", "9", "hi")
      assert false, "must raise"
    except IOError:
      discard

  test "receive stays an honest 7d seam":
    try:
      receiveDiscordEvent()
      assert false, "must raise"
    except CatchableError as exc:
      assert "7d" in exc.msg

# ── whatsapp: HMAC-SHA256 ──────────────────────────────────────────────

suite "phase 7b whatsapp hmac":
  test "RFC 4231 case 1":
    var key = newString(20)
    for i in 0 ..< 20:
      key[i] = '\x0b'
    assert hmacSha256Hex(key, "Hi There") ==
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"

  test "RFC 4231 case 2":
    assert hmacSha256Hex("Jefe", "what do ya want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

  test "waku-shaped case matches Python hmac":
    assert hmacSha256Hex("secret", "{\"entry\":[]}") ==
      "97f0eaf4fb539301c758929abea22432a8fed44f5ce20d65c6af41ff15dfb115"

  test "keys longer than the block hash first":
    assert hmacSha256Hex(repeat('k', 100), "hello") ==
      "3fd578d761a4f6703009e92d2e8a0aea22ab9ab50d4ad250dc95d8c369dec3f5"

  test "empty key and message hash deterministically":
    assert hmacSha256Hex("", "") ==
      "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"

  test "signatures carry the prefix and verify, forgeries fail":
    let sig = whatsappSignature("secret", "{\"entry\":[]}")
    assert sig ==
      "sha256=97f0eaf4fb539301c758929abea22432a8fed44f5ce20d65c6af41ff15dfb115"
    assert verifyWhatsappSignature("secret", "{\"entry\":[]}", sig)
    assert not verifyWhatsappSignature("secret", "{\"entry\":[1]}", sig)
    assert not verifyWhatsappSignature("wrong", "{\"entry\":[]}", sig)
    assert not verifyWhatsappSignature("secret", "{\"entry\":[]}",
      "sha256=00")
    assert not signaturesEqual("abc", "abd")
    assert not signaturesEqual("abc", "abcd")

# ── whatsapp: GET verification ─────────────────────────────────────────

suite "phase 7b whatsapp verify":
  test "a matching challenge verifies with its own body":
    let res = verifyWhatsapp("/webhook", "subscribe", "tok123", "CH",
      "tok123")
    assert res.status == 200
    assert res.body == "CH"

  test "wrong token, wrong mode and missing challenge are forbidden":
    assert verifyWhatsapp("/webhook", "subscribe", "nope", "CH",
      "tok123").status == 403
    assert verifyWhatsapp("/webhook", "unsubscribe", "tok123", "CH",
      "tok123").status == 403
    assert verifyWhatsapp("/webhook", "subscribe", "tok123", "",
      "tok123").status == 403
    assert verifyWhatsapp("/webhook", "subscribe", "tok123", "CH",
      "tok123").body != "forbidden"

  test "forbidden carries the word, foreign paths are 404":
    assert verifyWhatsapp("/webhook", "subscribe", "nope", "CH",
      "tok123").body == "forbidden"
    assert verifyWhatsapp("/other", "subscribe", "tok123", "CH",
      "tok123").status == 404

  test "the first env field is the token":
    assert whatsappEnvFields[0] == "WHATSAPP_TOKEN"

# ── whatsapp: POST handling ────────────────────────────────────────────

suite "phase 7b whatsapp post":
  proc signed(body: string): string = whatsappSignature("secret", body)

  test "bad path, bad signature and bad json are answered fast":
    let body = """{"entry": []}"""
    var res = handleWhatsappPost("/other", signed(body), "secret", body,
      "")
    assert res.status == 404
    res = handleWhatsappPost("/webhook", "sha256=nope", "secret", body,
      "")
    assert res.status == 403
    assert res.messages.len == 0
    res = handleWhatsappPost("/webhook", signed("{oops"), "secret",
      "{oops", "")
    assert res.status == 400

  test "messages walk entry/changes/value and answer 200 fast":
    let body = """{"entry": [{"changes": [{"value": {"messages": [
      {"from": "15551234567", "text": {"body": "hello"}},
      {"from": "15557654321", "text": {"body": "hi"}}]}}]}]}"""
    let res = handleWhatsappPost("/webhook", signed(body), "secret",
      body, "")
    assert res.status == 200
    assert res.body == "{}"
    assert res.messages.len == 2
    assert res.messages[0].sender == "15551234567"
    assert res.messages[0].text == "hello"
    assert res.messages[1].sender == "15557654321"

  test "text-less entries are skipped, not answered":
    let body = """{"entry": [{"changes": [{"value": {"messages": [
      {"from": "15551234567"},
      {"from": "", "text": {"body": "no sender"}},
      {"from": "15551234567", "text": {"body": ""}},
      {"from": "15551234567", "text": {"body": "real"}}]}}]}]}"""
    let res = handleWhatsappPost("/webhook", signed(body), "secret",
      body, "")
    assert res.status == 200
    assert res.messages.len == 1
    assert res.messages[0].text == "real"

  test "the phone allowlist filters strangers but still answers 200":
    let body = """{"entry": [{"changes": [{"value": {"messages": [
      {"from": "15550000000", "text": {"body": "stranger"}}]}}]}]}"""
    let refused = handleWhatsappPost("/webhook", signed(body), "secret",
      body, "15551234567")
    assert refused.status == 200
    assert refused.messages.len == 0
    let allowed = handleWhatsappPost("/webhook", signed(body), "secret",
      body, "15550000000")
    assert allowed.messages.len == 1

  test "helpers walk and gate the same way":
    let node = parseJson("""{"entry": [{"changes": [{"value": {
      "messages": [{"from": "1", "text": {"body": "a"}}]}}]}]}""")
    assert parseWhatsappMessages(node) ==
      @[WhatsappMessage(sender: "1", text: "a")]
    assert parseWhatsappMessages(parseJson("""{"entry": []}""")).len == 0
    assert isWhatsappAllowed("", "anyone")
    assert isWhatsappAllowed("1", "1")
    assert not isWhatsappAllowed("1", "2")

# ── whatsapp: Graph API send seam ──────────────────────────────────────

suite "phase 7b whatsapp wire":
  test "send posts the Graph shape with the bearer token":
    var seenUrl, seenBody, seenToken = ""
    let http: WhatsappHttpFn =
      proc(url, payload, token: string): int {.closure.} =
        seenUrl = url
        seenBody = payload
        seenToken = token
        return 200
    assert sendWhatsappText(http, "bearer123", "PNID", "15551234567",
      "hi")
    assert seenUrl ==
      "https://graph.facebook.com/v21.0/PNID/messages"
    let payload = parseJson(seenBody)
    assert payload["messaging_product"].getStr() == "whatsapp"
    assert payload["to"].getStr() == "15551234567"
    assert payload["type"].getStr() == "text"
    assert payload["text"]["body"].getStr() == "hi"
    assert seenToken == "bearer123"

  test "an error status reads as outcome, transport raises":
    let bad: WhatsappHttpFn =
      proc(url, payload, token: string): int {.closure.} = 429
    assert not sendWhatsappText(bad, "t", "PNID", "1", "hi")
    let down: WhatsappHttpFn =
      proc(url, payload, token: string): int {.closure.} =
        raise newException(IOError, "net down")
    try:
      discard sendWhatsappText(down, "t", "PNID", "1", "hi")
      assert false, "must raise"
    except IOError:
      discard

  # The 7b "serving stays an honest 7d seam" test left with the seam:
  # 7d1 ships the server, and its pins live in test_live_gateways.nim
  # (the door, the GET verification, the 200-before-turn order).
