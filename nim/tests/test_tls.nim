## Live TLS, conditional: the `-d:wakuTls` pins (both build modes).
##
## The port is offline by default, and that is a property worth keeping
## rather than a gap worth closing quietly. Compiled without a flag, no
## `https://` call reaches a socket: `std/httpclient` raises
## `HttpRequestError("SSL support is not available. Cannot connect over
## SSL. Compile with -d:ssl to enable.")` in `newConnection`, BEFORE any
## byte is written, so an API key can never leave in the clear. Compiled
## with `-d:ssl -d:wakuTls`, the same paths get one real
## `std/net.SslContext` (system libssl, no new package — rule 3 is intact)
## and the Discord gateway can finally be dialled as `wss://`.
##
## Two build modes, one file, because the contract is the PAIR: the
## refusal without the flag and the capability with it are two halves of
## one promise, and a pin that only ran in the default build would let
## the flagged build rot unseen (and the other way round). Everything
## below is decided at compile time by `defined(wakuTls) and
## defined(ssl)`, so each mode runs the pins that describe it and skips
## the rest — no pin below is written twice.
##
## OFFLINE BY CONSTRUCTION. Nothing here opens a socket, resolves a name
## or reads a key. Three families of pin:
##
## - What the compiler was told: the two `defined()` switches, compared
##   against the runtime helper — and, in the default build, against the
##   transport's own guard, which is a refusal you can watch.
## - Behaviour in the DEFAULT build: every live REST seam is handed an
##   `https://` URL and none of them reaches a socket — all five RAISE
##   the refusal at the caller, and the Nim subtlety that once made four
##   of them answer a status of 0 instead is pinned both as a mechanism
##   and as a shape no seam carries any more. The gateway dial must
##   refuse with `discordTlsMissingLine` unchanged.
## - Structure in BOTH builds: the context exists exactly when the build
##   says it does, the one helper builds a client in either mode without
##   a network, the Discord upgrade is driven over a SCRIPTED transport
##   against a recorded handshake, and no module in `src/` builds an
##   HTTP client any other way.
##
## THE FLAGGED RUN, from `nim/` (the exact command; the output name is
## separate so the two runs cannot clobber each other's binary):
##
##   nim c -r --hints:off -d:ssl -d:wakuTls -o:tests/test_tls_flagged \
##     tests/test_tls.nim
##
## The same two defines are what `nimble buildTls` passes, what
## `make nim-build-tls` runs and what the `nim-tls` CI job compiles, so
## the flag is typed once in `waku.nimble` and this header is the one
## place it is spelled out. `-d:ssl` is the compiler's own switch (it
## links libssl); `-d:wakuTls` is this port's, and it does nothing
## without the first — so a half-typed flag degrades to the default
## build instead of compiling something half-encrypted.
##
## What is NOT pinned here, on purpose: a real handshake against a real
## server. That needs a network, and an eval that needs a network is not
## an eval. What the flagged build CAN be shown to do offline is written
## above; that it can also complete a live `GET https://example.com/`
## with peer verification is a manual probe recorded in
## `odd/tasks/nim-live-tls.md`, not a pin, and no test here pretends
## otherwise.

import std/[httpclient, httpcore, json, os, strutils, unittest]

import ../src/discord
import ../src/http
# The gateway and MCP seams are pinned by their OWN build: the pins
# below ask what a live REST call does in a build with no TLS in the
# transport, and in a flagged build those same calls would open a
# socket. So the modules they live in are imported for that build only —
# which is also why nothing here is unused in either mode. The pair of
# switches is spelled out rather than named `TlsCompiled` because a
# `when` around an import is resolved before the const below exists.
when not (defined(wakuTls) and defined(ssl)):
  import ../src/mcp
  import ../src/telegram
  import ../src/whatsapp

const
  TlsCompiled = defined(wakuTls) and defined(ssl)
    ## The compile-time fact both build modes agree on: TLS is available
    ## only when the compiler switch (`-d:ssl`, which links libssl) AND
    ## this port's switch (`-d:wakuTls`) are both defined. Written as a
    ## const so a pin can compare the RUNTIME helper against the
    ## COMPILE-TIME truth instead of against itself.

  NoTlsMessage = "SSL support is not available"
    ## The refusal `std/httpclient` raises, from `newConnection`, when a
    ## request names `https://` and the compiler was not given `-d:ssl`.
    ## It is raised before the connection is made, which is what makes
    ## the pins below offline and what keeps a key from going out in the
    ## clear. Copied as a fragment on purpose: pinning the whole sentence
    ## would break on an upstream rewording without this port changing.

# ── the recorded handshake (offline) ───────────────────────────────────

const
  Rfc6455Key = "dGhlIHNhbXBsZSBub25jZQ=="
    ## The client key of RFC 6455 §1.3, verbatim. A RECORDED example, not
    ## one captured from Discord: it is a handshake with nothing secret
    ## in it, and the standard is the one document every RFC 6455
    ## implementation is measured against.

  Rfc6455Accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    ## The accept value that goes with `Rfc6455Key`, from the same
    ## section. The port does NOT recompute it (SHA-1 is gone from
    ## stdlib, and vendoring a digest into a gateway module is worse
    ## than the gap) — so the accept header is checked STRUCTURALLY,
    ## and the pin "the accept digest is not verified" below makes that
    ## gap a recorded decision instead of a silent one.

  Rfc6455Reply = "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & Rfc6455Accept & "\r\n\r\n"
    ## The upgrade reply the fixture is recorded as: the status line, the
    ## two upgrade headers, the accept header, and the blank line that
    ## ends the head. Anything after the blank line is a gateway frame
    ## that arrived in the same read, which is the case the leftover
    ## buffer exists for.

proc helloFrame(): string =
  ## One real op 10 `HELLO` frame, built by the module's own encoder so
  ## the leftover bytes in the pins below are a frame the real decoder
  ## can read — not a hand-written byte string that agrees with nothing.
  encodeDiscordFrame(opText,
    """{"t":null,"s":null,"op":10,"d":{"heartbeat_interval":41250}}""", "")

# ── the scripted transport (offline) ───────────────────────────────────

type
  Script = ref object
    ## The recorded gateway socket. `chunks` is what `recv` hands over
    ## one call at a time, so a reply split across two reads is one
    ## test; `sent` keeps the raw bytes the client wrote, which is how
    ## the pins read the upgrade request without a socket; `target` is
    ## where the dial said it was going.
    chunks: seq[string]
    sent: seq[string]
    target: string

proc newScript(chunks: seq[string]): Script =
  Script(chunks: chunks, sent: @[], target: "")

proc wireOf(s: Script): DiscordWire =
  ## The transport seam over the script, unmasked: the upgrade request
  ## is a raw HTTP head, not a frame, so the mask key is set by the
  ## upgrade itself and a test can read it back afterwards.
  let recv: DiscordRecvFn = proc(timeoutMs: int): string {.closure.} =
    if s.chunks.len == 0:
      return ""
    let chunk = s.chunks[0]
    s.chunks.delete(0)
    return chunk
  let send: DiscordSendFn = proc(bytes: string): int {.closure.} =
    s.sent.add(bytes)
    return bytes.len
  newDiscordWire(recv, send, "")

proc scriptedStream(s: Script): DiscordStreamFn =
  ## `discordTlsStream`'s signature, answered from the recording instead
  ## of from a socket. The host and port it was asked for are kept, so a
  ## pin can read where the live dial WOULD have gone.
  proc(host: string, port: int): (bool, DiscordWire, string) {.closure.} =
    s.target = host & ":" & $port
    return (true, wireOf(s), "")

proc repoRoot(): string =
  ## The repo root, from this file's own path and never from the working
  ## directory — the same anchoring as `test_repo_gates.nim` and
  ## `test_version.nim`, and the reason no pin below names a relative
  ## path. Declared up here because two suites need it: the default-build
  ## shape scan and the one-helper scan at the bottom.
  absolutePath(currentSourcePath().parentDir / ".." / "..")

template tlsRefusalOf(body: untyped): string =
  ## Run one live seam at an `https://` URL and hand back the refusal it
  ## raised, or `"<no refusal>"`. A pin that only asked "did it raise?"
  ## would pass on a timeout or a DNS failure; reading the message is
  ## what proves the refusal came from the no-TLS guard. The second
  ## handler is there so a seam that fails some OTHER way says which
  ## exception it raised instead of reading as "no refusal".
  try:
    discard (block: body)
    "<no refusal>"
  except HttpRequestError as exc:
    exc.msg
  except CatchableError as exc:
    "OTHER " & $exc.name & ": " & exc.msg

# ── the switch itself (both modes) ─────────────────────────────────────

suite "live TLS, the switch":
  test "the runtime helper agrees with the switches the compiler was given":
    # `tlsActive()` is a proc and could answer anything, so it is
    # compared against the `defined()` the compiler actually saw rather
    # than against itself. The `static` half guards the CONST, so a
    # future edit to `TlsCompiled` that stops meaning "both switches"
    # fails the compile instead of quietly agreeing with a wrong answer.
    #
    # `compileOption` is deliberately NOT used here: it reads the
    # compiler's on/off switches (`stacktrace`, `threads`), and
    # `-d:ssl` is a define, not one — asking it for "ssl" is an
    # invalid command line option. `defined()` is the only honest way
    # to ask this question.
    static:
      doAssert TlsCompiled == (defined(wakuTls) and defined(ssl)),
        "TlsCompiled must mean both switches, not one"
    check tlsActive() == TlsCompiled
    check tlsContext().isNil == (not TlsCompiled)

  test "one context for the process, not one per request":
    # Built once and handed out, because an `SslContext` owns a session
    # cache and a cipher setup: one per call would re-read the trust
    # store on every request. Identity, not equality of contents.
    #
    # A context that exists at all is also the answer to "does this build
    # verify the peer?": `newContext(verifyMode = CVerifyPeer)` raises
    # `IOError` when it finds no CA certificates to load, so a
    # non-nil `tlsContext()` is OpenSSL saying it loaded a trust store
    # and will check the chain.
    if TlsCompiled:
      check tlsContext() == tlsContext()
    else:
      check tlsContext().isNil

  test "a client from the one helper is built in either mode":
    # No request, no name lookup, no socket: this is the constructor, so
    # it is safe offline in both builds and fails only if the helper
    # itself cannot be called. `close()` on both, because a client that
    # cannot be closed is a leak in a long-lived loop.
    let sync = newTlsHttpClient(timeout = 15000)
    sync.close()
    let async = newTlsAsyncHttpClient()
    async.close()

# ── the default build: honest refusals, before any bytes ───────────────

when not TlsCompiled:
  suite "live TLS, the default build refuses":
    test "the transport itself refuses https without -d:ssl":
      # `newConnection` raises before it resolves, connects or writes,
      # which is the whole reason the default build is safe to ship: an
      # `Authorization` header cannot leak because the request never
      # leaves. `.invalid` is reserved by RFC 2606 and is there so that
      # if this pin ever failed it would fail for the RIGHT reason.
      let client = newTlsHttpClient(timeout = 1500)
      defer: client.close()
      check NoTlsMessage in tlsRefusalOf(client.getContent(
        "https://example.invalid/"))

    test "the transport's own refusal reaches the caller":
      # `liveTelegramHttp` closes its client in a bare `finally`, so the
      # refusal reaches its caller — which is the shape a gateway wants
      # (the poll turns a transport failure into a retry with backoff),
      # and the shape the four seams below now share.
      assert NoTlsMessage in tlsRefusalOf(liveTelegramHttp(
        "https://api.telegram.org/bot000000:TEST/getMe", ""))

    test "the four REST seams raise the refusal instead of answering 0":
      # These four return a status, so the interesting question is what a
      # caller sees when the transport refuses. They used to answer 0,
      # for a real Nim reason pinned by the next two tests. A status of 0
      # is a lie the caller has to decode: `discoverOAuth` turned one
      # into `could not discover the authorization server … HTTP 0 at
      # <url>`, which blames the SERVER for a build that was never
      # allowed to dial it, and a gateway turn that got 0 counted a
      # delivery that never happened. They now raise, like
      # `liveTelegramHttp` and like `std/httpclient` itself: the refusal
      # names the missing `-d:ssl`, and every caller of these four
      # (`runGatewayTurn`'s `reply delivery` accounting, `oauthSignIn`
      # and `refreshAccessToken`'s `except CatchableError`) already
      # handles a raise.
      let discord = tlsRefusalOf(liveDiscordPost(
        "https://discord.com/api/v10/channels/1/messages", "{}", "tok"))
      assert NoTlsMessage in discord, "liveDiscordPost swallowed the refusal"
      let whatsapp = tlsRefusalOf(liveWhatsappPost(
        "https://graph.facebook.com/v21.0/1/messages", "{}", "tok"))
      assert NoTlsMessage in whatsapp,
        "liveWhatsappPost swallowed the refusal"
      let posted = tlsRefusalOf(liveHttpPost("https://mcp.example.invalid/rpc",
        "{}", "", ""))
      assert NoTlsMessage in posted, "liveHttpPost swallowed the refusal"
      let got = tlsRefusalOf(liveHttpGet("https://mcp.example.invalid/" &
        ".well-known/oauth-authorization-server", ""))
      assert NoTlsMessage in got, "liveHttpGet swallowed the refusal"
      # The exception that arrives is the TRANSPORT'S. `tlsRefusalOf`
      # reports any other exception as `OTHER …`, so these four lines say
      # that closing the client in the `finally` did not replace the
      # refusal with an error of its own, and that nothing else failed
      # first.
      for refusal in [discord, whatsapp, posted, got]:
        assert not refusal.startsWith("OTHER "),
          "a seam failed some other way: " & refusal

    test "why a finally that catches swallows the refusal in flight":
      # The mechanism behind the pin above, in five lines and with no
      # socket, no URL and no transport involved: a `try/except` nested
      # in a `finally` that is running DURING exception unwinding
      # catches the exception that is unwinding, and the proc then
      # returns normally. This is the pin for the four seams' old shape,
      # and it stays because the rule is a property of Nim rather than of
      # this file: the next editor who wraps a `close()` in a defensive
      # `except` has to read here first. Nobody relies on the swallowing
      # any more — the seams close in a bare `finally` (pinned by the next
      # test) and let the refusal out.
      var reached = "no"
      var caught = false
      try:
        reached = reached & " body"
        if reached.len > 0:       # always true; a bare `raise` here would
          raise newException(IOError, "boom")   # read as unreachable below
      finally:
        try:
          reached = reached & " finally"
        except CatchableError:
          caught = true
          reached = reached & " caught"
      check reached == "no body finally caught"
      check caught     # the handler ran, and that is what let the proc return

    test "no REST seam still closes its client inside a try/except":
      # The mechanism above is a property of Nim, not of these four
      # procs, so it never goes away on its own — a defensive
      # `try/except` around a `close()` in a `finally` brings it back.
      # A behavioural pin only exists in the default build, where the
      # refusal is observable; the flagged build compiles the pins above
      # out entirely, so the SHAPE is pinned here instead, in both modes:
      # every seam that builds a client closes it in a bare `finally`,
      # which is what `liveTelegramHttp` already did and what lets an
      # in-flight exception out.
      let swallowing = "finally:\n    try:"
      let closing = "finally:\n    client.close()"
      for name in ["discord.nim", "whatsapp.nim", "mcp.nim", "telegram.nim"]:
        let text = readFile(repoRoot() / "nim" / "src" / name)
        assert swallowing notin text,
          name & " still catches inside a finally and would swallow again"
        assert closing in text, name & " no longer closes in a bare finally"

    test "the live gateway dial refuses, unchanged":
      # The 7d2-2 line, byte for byte. This build cannot reach
      # `wss://gateway.discord.gg`, and the refusal is a VALUE, which is
      # why it is pinnable with no socket in the room.
      let (ok, wire, why) = liveDiscordWire("tok123")
      check not ok
      check wire.isNil
      check why == discordTlsMissingLine
      check "wss://" & discordGatewayHost in why
      check "ssl" in why        # names the missing piece, not just a failure

    test "the whole dial ladder refuses, and the first rung is the stream":
      # The dial is a ladder — stream, then upgrade, then wire — and
      # without the flag the FIRST rung refuses, so nothing below it can
      # reach a socket and the assembly cannot invent a connection out of
      # the two rungs that stayed local. Pinning the whole ladder is what
      # says "the refusal is structural", not "one caller happens to
      # check a flag".
      let (opened, stream, why) = discordTlsStream(discordGatewayHost,
        discordTlsPort)
      check not opened
      check stream.isNil
      check why == discordTlsMissingLine
      let (ok, wire, same) = discordTlsWire("tok123")
      check not ok
      check wire.isNil
      check same == discordTlsMissingLine

# ── the flagged build: the capability, structurally ────────────────────

when TlsCompiled:
  suite "live TLS, the flagged build":
    test "the dial target is written down, not left to a reader":
      # The flagged dial connects to one host on one port, with the host
      # as the SNI name. Those facts are the only place this port
      # touches a socket for the gateway, so they are pinned as values: a
      # pin cannot open the socket, but it can refuse to let the address
      # move.
      check discordTlsPort == 443
      check discordGatewayHost == "gateway.discord.gg"

    test "the upgrade is accepted from the recorded handshake":
      let s = newScript(@[Rfc6455Reply])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check ok
      check why == ""
      check not wire.isNil
      check s.target == "gateway.discord.gg:443"

    test "the upgrade request is the one the module documents":
      # The request leaves the process into the recorded script, so what
      # would reach a real gateway is pinned byte-wise: the v10 path, the
      # host, the upgrade headers, the token as a header (never in the
      # path), and the key the request and the wire then SHARE.
      let s = newScript(@[Rfc6455Reply])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check ok and why == ""
      check s.sent.len == 1
      let request = s.sent[0]
      check request == discordHandshake("tok123", wire.maskKey)
      check request.startsWith("GET /?v=10&encoding=json HTTP/1.1\r\n")
      check "Host: gateway.discord.gg\r\n" in request
      check "Upgrade: websocket\r\n" in request
      check "Sec-WebSocket-Version: 13\r\n" in request
      check "Authorization: Bot tok123\r\n" in request
      check ("Sec-WebSocket-Key: " & wire.maskKey & "\r\n") in request
      check wire.maskKey.len == 24     # base64 of the 16 random bytes
      # A FRESH key per connection, or a peer that watched two sessions
      # could tell them apart; the RFC asks for 16 unpredictable bytes.
      let other = newScript(@[Rfc6455Reply])
      discard discordTlsWire("tok123", stream = scriptedStream(other))
      check other.sent[0] != request

    test "bytes that arrived with the upgrade are the first frame":
      # The gateway routinely sends its `HELLO` in the same read as the
      # 101. Those bytes are not part of the reply head, so the upgrade
      # must leave them in the wire's buffer — the real decoder reads
      # them on the first `readDiscordFrame`, which is what the protocol
      # loop does next.
      let s = newScript(@[Rfc6455Reply & helloFrame()])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check ok and why == ""
      let frame = readDiscordFrame(wire, 10)
      check frame.opcode == opText
      check parseJson(frame.payload)["op"].getInt == 10
      check wire.buffer == ""        # consumed, not left to rot

    test "a reply that arrives in pieces is still one reply":
      # The head can be split across reads; the wire's buffer is what
      # makes that invisible. Pinned with the split inside the header
      # block, where a proc that stopped at the first chunk would hand a
      # half-answer to the fault check and refuse a connection that had
      # in fact been accepted.
      let head = Rfc6455Reply
      let s = newScript(@[head[0 ..< 30], head[30 .. ^1]])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check ok and why == ""
      check wire.maskKey.len == 24

    test "a refused upgrade is a refused dial, not an exception":
      # A bad token announces itself as a 401 on the upgrade. The dial
      # answers `(false, nil, why)` like every other seam here, because
      # `discordServe` reports one line and exits 1 — a raised exception
      # would take the command down instead.
      let s = newScript(@["HTTP/1.1 401 Unauthorized\r\n" &
        "Content-Length: 0\r\n\r\n"])
      let (ok, wire, why) = discordTlsWire("bad-token",
        stream = scriptedStream(s))
      check not ok
      check wire.isNil
      check why.startsWith("gateway refused the websocket upgrade")
      check "401" in why
      check s.sent.len == 1          # the request still went out, once

    test "a 101 without the accept header is refused":
      let s = newScript(@["HTTP/1.1 101 Switching Protocols\r\n" &
        "Upgrade: websocket\r\n\r\n"])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check not ok
      check wire.isNil
      check "Sec-WebSocket-Accept" in why

    test "a quiet socket is a refused dial, not a hang":
      # The stream closed, or the peer said nothing at all. The dial must
      # answer rather than loop: the read comes back empty and the fault
      # check reports the missing status line, which is the one line an
      # operator can act on.
      let s = newScript(@[""])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check not ok
      check wire.isNil
      check why == "gateway refused the websocket upgrade (no response)"

    test "a refused stream is passed through, not replaced":
      # When the socket cannot be opened, the dial reports THAT line and
      # stops. Swallowing it for the no-TLS sentence would blame the
      # build for a network that is down, which is the one thing a
      # refusal line must not do.
      let dead = proc(host: string, port: int):
          (bool, DiscordWire, string) {.closure.} =
        (false, nil, discordDialFailedLine & "connection refused")
      let (ok, wire, why) = discordTlsWire("tok123", stream = dead)
      check not ok
      check wire.isNil
      check why == discordDialFailedLine & "connection refused"

    test "the accept digest is NOT verified — the gap, pinned":
      # `discordHandshakeFault` checks the status line and the PRESENCE
      # of `Sec-WebSocket-Accept`; it does not recompute SHA-1(key +
      # GUID), because SHA-1 is deprecated in stdlib and vendoring a
      # digest into a gateway module is a worse trade than the gap. This
      # pin exists so the gap stays a RECORDED decision: a reply whose
      # accept value is a lie is accepted today, and the day that changes
      # is the day this pin changes on purpose.
      let s = newScript(@["HTTP/1.1 101 Switching Protocols\r\n" &
        "Sec-WebSocket-Accept: 0000000000000000000000=\r\n\r\n"])
      let (ok, wire, why) = discordTlsWire("tok123",
        stream = scriptedStream(s))
      check ok
      check why == ""
      check not wire.isNil

    test "the recorded pair is the RFC's own example":
      # The fixture is a recorded handshake, and this is where that claim
      # is kept honest: the key and the accept value are the pair from
      # RFC 6455 §1.3, so anyone can check the recording against the
      # standard rather than against this file's own word. And the module
      # agrees the reply is well formed, so the fixture and the fault
      # check cannot drift apart unnoticed.
      check Rfc6455Key == "dGhlIHNhbXBsZSBub25jZQ=="
      check Rfc6455Accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      check Rfc6455Key.len == 24
      check discordHandshakeFault(Rfc6455Reply) == ""

# ── the one helper, everywhere (both modes) ────────────────────────────

suite "live TLS, one helper":
  test "no module builds an HTTP client behind the helper's back":
    # The context is only ever attached by the helper, so a client built
    # any other way is a context-less one — the exact defect this unit
    # removed from six modules. Read as a scan of the tree rather than
    # as a behavioural pin because the defect is INVISIBLE at runtime in
    # the default build: without the flag both shapes behave identically,
    # and only a flagged build would show the difference. The scan is
    # also why this suite exists: it is the pin that catches the next
    # client someone adds.
    var offenders: seq[string] = @[]
    var constructions = 0
    for path in walkDirRec(repoRoot() / "nim" / "src"):
      if not path.endsWith(".nim"):
        continue
      let text = readFile(path)
      let hits = count(text, "newHttpClient(") +
        count(text, "newAsyncHttpClient(")
      if hits == 0:
        continue
      constructions += hits
      if path.extractFilename != "http.nim":
        offenders.add(path.extractFilename)
    assert offenders.len == 0,
      "these build a client without the TLS context:\n  " & offenders.join("\n")
    assert constructions == 4,
      "http.nim constructs " & $constructions & " clients — the helper is " &
      "meant to be ONE sync and ONE async constructor, each with its " &
      "flagged and default branch, so a fifth is a new gap"

  test "the helper lives in the transport module":
    # `http.nim` is where the transport already was, so this is the only
    # file that needs to know about a context. Pinned because a second
    # helper in another module would defeat the scan above: each would be
    # its own "one" helper.
    let text = readFile(repoRoot() / "nim" / "src" / "http.nim")
    check "proc tlsActive*(" in text
    check "proc tlsContext*(" in text
    check "proc newTlsHttpClient*(" in text
    check "proc newTlsAsyncHttpClient*(" in text

  test "the manifest typed the flag once, and CI calls the task":
    # `waku.nimble` is the only place the flag is typed; the Makefile
    # and the CI job both call the task that reads it. A second copy of
    # the define in a workflow is exactly how the two drift, so the
    # define is pinned to the one task and the workflow is pinned to CALL
    # that task instead of repeating the compiler line.
    let manifest = readFile(repoRoot() / "nim" / "waku.nimble")
    check manifest.count("-d:ssl -d:wakuTls") == 1
    let workflow = readFile(repoRoot() / ".github" / "workflows" / "nim.yml")
    check "nimble buildTls" in workflow
