## `waku connect` tests: dispatcher exit codes plus both connectors with
## stubbed seams. Offline only: temp homes, no browser, no outside socket —
## the live listeners run on 127.0.0.1 when a test asks for one.

import std/httpclient
import std/json
import std/os
import std/strutils
import std/typedthreads
import std/unittest
import std/uri

import ../src/connect
import ../src/mcp

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc googleSeams(exchangeDoc: JsonNode, target = "/?code=abc"): GoogleSeams =
  GoogleSeams(
    openBrowser: proc(url: string): bool = true,
    listenLoopback: proc(): GoogleLoopback = GoogleLoopback(port: 45678,
      wait: proc(): string = target),
    exchange: proc(tokenUri, body: string): tuple[ok: bool,
      doc: JsonNode] = (true, exchangeDoc),
    nowUnix: 1700000000)

var browserThread: Thread[string]

proc hitLoopback(url: string) {.thread.} =
  ## Play the browser: one request to the redirect URI, like the real click.
  var client = newHttpClient(timeout = 5000)
  try:
    discard client.getContent(url)
  except CatchableError:
    discard
  client.close()

proc memorySignIn(ok: bool, msg = "", identity = ""): MemorySignInFn =
  result = proc(home, name: string): tuple[ok: bool, msg: string,
    identity: string] = (ok, msg, identity)

suite "connect dispatcher":
  test "no args prints usage and exits 1":
    let (msg, code) = cliConnect(@[], freshHome("waku-connect-noargs"),
      googleSeams(newJNull()), memorySignIn(true))
    assert "google" in msg and "waku-memory" in msg and "treg" in msg
    assert code == 1

  test "unknown names say what is available and exit 1":
    let (msg, code) = cliConnect(@["nope"], freshHome("waku-connect-unknown"),
      googleSeams(newJNull()), memorySignIn(true))
    assert "Nothing called 'nope'" in msg
    assert "google" in msg
    assert code == 1

  test "names match case-insensitively":
    let (msg, code) = cliConnect(@["Google"],
      freshHome("waku-connect-case"), googleSeams(newJNull()),
      memorySignIn(true))
    assert code == 0
    assert "bundled OAuth client is not configured" in msg

suite "connect google":
  test "without credentials.json the bundled client answers honestly":
    let home = freshHome("waku-connect-google-bare")
    let msg = googleConnect(home, googleSeams(newJNull()))
    assert "bundled OAuth client is not configured" in msg
    assert "credentials.json" in msg
    assert not fileExists(home / "google-token.json")
    assert not fileExists(home / "gmail-token.json")

  test "a cancelled browser saves nothing":
    let home = freshHome("waku-connect-google-cancel")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    var seams = googleSeams(newJNull(), "/?error=access_denied")
    let msg = googleConnect(home, seams)
    assert "cancelled" in msg
    assert "access_denied" in msg
    assert "Nothing was saved" in msg
    assert not fileExists(home / "google-token.json")
    assert not fileExists(home / "gmail-token.json")

  test "a refused exchange saves nothing":
    let home = freshHome("waku-connect-google-refused")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    let seams = GoogleSeams(
      openBrowser: proc(url: string): bool = true,
      listenLoopback: proc(): GoogleLoopback = GoogleLoopback(port: 45678,
        wait: proc(): string = "/?code=abc"),
      exchange: proc(tokenUri, body: string): tuple[ok: bool,
        doc: JsonNode] = (false, newJNull()),
      nowUnix: 1700000000)
    let msg = googleConnect(home, seams)
    assert "token refused" in msg
    assert not fileExists(home / "google-token.json")
    assert not fileExists(home / "gmail-token.json")

  test "consent caches the token and names the source":
    let home = freshHome("waku-connect-google-ok")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    let doc = %*{"access_token": "ya", "refresh_token": "rt",
                  "expires_in": 3600}
    let msg = googleConnect(home, googleSeams(doc))
    assert "connected (via credentials.json override)" in msg
    assert "google-token.json" in msg
    let cached = parseJson(readFile(home / "google-token.json"))
    assert cached["token"].getStr() == "ya"
    assert cached["refresh_token"].getStr() == "rt"
    assert cached["client_id"].getStr() == "cid"
    assert cached["expiry"].getBiggestInt() == 1700003600
    # One consent covers the calendar and, for parity, Gmail's two scopes.
    var asked: seq[string]
    for scope in cached["scopes"]:
      asked.add(scope.getStr())
    assert asked == googleConsentScopes()

  test "mail gets its own token copy, which the Gmail tools read":
    let home = freshHome("waku-connect-google-mail")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    let msg = googleConnect(home, googleSeams(%*{"access_token": "ya",
      "refresh_token": "rt", "expires_in": 3600}))
    assert "gmail-token.json" in msg
    let mail = parseJson(readFile(home / "gmail-token.json"))
    assert mail["token"].getStr() == "ya"
    assert mail["refresh_token"].getStr() == "rt"
    assert mail["expiry"].getBiggestInt() == 1700003600
    # Deleting the mail copy revokes mail alone: the calendar file stays.
    removeFile(home / "gmail-token.json")
    assert fileExists(home / "google-token.json")

  test "one consent opens exactly one browser window":
    # The loop this pins: a failed wait used to retry, and every retry asked
    # Google for the same consent again. A sign-in asks once.
    let home = freshHome("waku-connect-google-one-window")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    var opened = 0
    let seams = GoogleSeams(
      openBrowser: proc(url: string): bool = (inc opened; true),
      listenLoopback: proc(): GoogleLoopback = GoogleLoopback(port: 45678,
        wait: proc(): string = ""),
      exchange: proc(tokenUri, body: string): tuple[ok: bool,
        doc: JsonNode] = (true, newJNull()),
      nowUnix: 1700000000)
    let msg = googleConnect(home, seams)
    assert opened == 1
    assert "cancelled" in msg
    assert "Nothing was saved" in msg
    assert not fileExists(home / "google-token.json")

  test "the browser is sent to the port the listener already holds":
    let home = freshHome("waku-connect-google-url-port")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    var seen = ""
    let seams = GoogleSeams(
      openBrowser: proc(url: string): bool = (seen = url; true),
      listenLoopback: proc(): GoogleLoopback = GoogleLoopback(port: 39393,
        wait: proc(): string = "/?error=access_denied"),
      exchange: proc(tokenUri, body: string): tuple[ok: bool,
        doc: JsonNode] = (true, newJNull()),
      nowUnix: 1700000000)
    discard googleConnect(home, seams)
    assert encodeUrl("http://localhost:39393") in seen

  test "a refused listener opens no browser and saves nothing":
    let home = freshHome("waku-connect-google-no-port")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    var opened = 0
    let seams = GoogleSeams(
      openBrowser: proc(url: string): bool = (inc opened; true),
      listenLoopback: proc(): GoogleLoopback = raise newException(IOError,
        "no free loopback port for the sign-in redirect"),
      exchange: proc(tokenUri, body: string): tuple[ok: bool,
        doc: JsonNode] = (true, newJNull()),
      nowUnix: 1700000000)
    let msg = googleConnect(home, seams)
    assert opened == 0
    assert "no free loopback port" in msg
    assert not fileExists(home / "google-token.json")
    assert not fileExists(home / "gmail-token.json")

  test "the live listener keeps the code a real redirect brings":
    # The defect this pins: the live waiter closed its server after serving
    # the redirect, that close came back as an OSError, and the flow reported
    # "port is in use" AFTER a successful sign-in — saving nothing.
    let listener = listenGoogleLoopbackLive()
    assert listener.port > 0
    let other = listenGoogleLoopbackLive()
    assert other.port != listener.port
    createThread(browserThread, hitLoopback,
      "http://127.0.0.1:" & $listener.port & "/?code=abc")
    let target = listener.wait()
    joinThread(browserThread)
    assert target == "/?code=abc"

  test "a real redirect through the live listener caches both tokens":
    # The end of the old failure: the browser signed in, the flow said the
    # port was taken, and NOTHING was written. Now the redirect lands on the
    # listener that opened the browser, and both token files exist after it.
    let home = freshHome("waku-connect-google-live")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    let seams = GoogleSeams(
      openBrowser: proc(url: string): bool =
        let redirectUri = block:
          var found = ""
          for key, value in decodeQuery(parseUri(url).query):
            if key == "redirect_uri":
              found = value
          found
        createThread(browserThread, hitLoopback, redirectUri & "/?code=abc")
        true,
      listenLoopback: listenGoogleLoopbackLive,
      exchange: proc(tokenUri, body: string): tuple[ok: bool,
        doc: JsonNode] = (true, %*{"access_token": "live",
          "refresh_token": "rt", "expires_in": 3600}),
      nowUnix: 1700000000)
    let msg = googleConnect(home, seams)
    joinThread(browserThread)
    assert "Google connected" in msg
    assert parseJson(readFile(home / "google-token.json"))["token"].getStr() ==
      "live"
    assert parseJson(readFile(home / "gmail-token.json"))["token"].getStr() ==
      "live"

  test "one consent asks for the calendar and Gmail scopes":
    let client = %*{"client_id": "cid", "client_secret": "cs"}
    let url = googleAuthUrl(client, "http://localhost:1")
    assert encodeUrl(googleScope) in url
    for scope in gmailScopes:
      assert encodeUrl(scope) in url

suite "connect waku-memory":
  test "a fresh home is added, then signed in":
    let home = freshHome("waku-connect-mem-add")
    let msg = memoryConnect(home,
      memorySignIn(true, "", "ana@example.com"))
    assert "Added Waku Memory to" in msg
    assert "Connected to Waku Memory as ana@example.com" in msg
    assert "waku_memory_*" in msg
    let config = parseJson(readFile(home / "mcp.json"))
    assert config["servers"].len == 1
    assert config["servers"][0]["url"].getStr() == memoryUrl

  test "a present server with a token is already connected":
    let home = freshHome("waku-connect-mem-present")
    discard memoryConnect(home, memorySignIn(true, "", "ana@example.com"))
    createDir(home / "mcp-auth")
    writeFile(authFilePath(home, memoryName),
      """{"account": "ana@example.com"}""")
    let msg = memoryConnect(home,
      memorySignIn(false, "must not run"))
    assert "already connected" in msg
    assert "waku mcp login" in msg

  test "a retired address is moved, not failed":
    let home = freshHome("waku-connect-mem-moved")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "waku_memory", "url": "https://d1o2fv4416yi84.cloudfront.net/x"}]}""")
    let msg = memoryConnect(home, memorySignIn(true, "", "b@c.d"))
    assert "Moved 'waku_memory'" in msg
    assert "refuses clients" in msg

  test "a conflicting name is left alone":
    let home = freshHome("waku-connect-mem-conflict")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "waku_memory", "url": "https://mine.example/mcp"}]}""")
    let msg = memoryConnect(home, memorySignIn(true))
    assert "already points at https://mine.example/mcp" in msg
    assert "not " & memoryUrl in msg

  test "an api-key entry needs no sign-in":
    let home = freshHome("waku-connect-mem-key")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "waku_memory", "url": "https://api.waku.one/mcp", "auth_env": "WM_KEY"}]}""")
    let msg = memoryConnect(home, memorySignIn(false, "must not run"))
    assert "using the API key in $WM_KEY" in msg

  test "a failed sign-in keeps the added line and names the docs":
    let home = freshHome("waku-connect-mem-fail")
    let msg = memoryConnect(home, memorySignIn(false, "browser blew up"))
    assert "Added Waku Memory to" in msg
    assert "browser blew up" in msg
    assert memoryDocs in msg

suite "connect treg":
  test "a fresh home is added, then signed in":
    let home = freshHome("waku-connect-treg-add")
    let msg = tregConnect(home,
      memorySignIn(true, "", "you@treg.to"))
    assert "Added treg to" in msg
    assert "Connected to treg as you@treg.to" in msg
    assert "treg_*" in msg
    assert "bills your own account" in msg
    let config = parseJson(readFile(home / "mcp.json"))
    assert config["servers"].len == 1
    assert config["servers"][0]["url"].getStr() == tregUrl

  test "the dispatcher routes treg with exit 0":
    let (msg, code) = cliConnect(@["treg"],
      freshHome("waku-connect-treg-dispatch"),
      googleSeams(newJNull()), memorySignIn(true, "", "you@treg.to"))
    assert code == 0
    assert "Connected to treg as you@treg.to" in msg

  test "the url identifies the server under any name":
    let home = freshHome("waku-connect-treg-anyname")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "research", "url": "https://treg.to/mcp", "oauth": true}]}""")
    createDir(home / "mcp-auth")
    writeFile(authFilePath(home, "research"),
      """{"account": "you@treg.to"}""")
    let msg = tregConnect(home, memorySignIn(false, "must not run"))
    assert "already connected" in msg
    assert "waku mcp login research" in msg

  test "a conflicting name is left alone":
    let home = freshHome("waku-connect-treg-conflict")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "treg", "url": "https://relay.example/mcp"}]}""")
    let msg = tregConnect(home, memorySignIn(true))
    assert "already points at https://relay.example/mcp" in msg
    assert "not " & tregUrl in msg
    assert "your own treg account" in msg

  test "an api-key entry needs no sign-in":
    let home = freshHome("waku-connect-treg-key")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "treg", "url": "https://treg.to/mcp/", "auth_env": "TREG_KEY"}]}""")
    let msg = tregConnect(home, memorySignIn(false, "must not run"))
    assert "using the key in $TREG_KEY" in msg

  test "a failed sign-in keeps the added line and names the docs":
    let home = freshHome("waku-connect-treg-fail")
    let msg = tregConnect(home, memorySignIn(false, "browser blew up"))
    assert "Added treg to" in msg
    assert "browser blew up" in msg
    assert tregDocs in msg

suite "connect treg state":
  test "an empty home is not added":
    let (where, detail) = tregState(freshHome("waku-treg-state-empty"))
    assert where == "not_added"
    assert detail == ""

  test "broken json names the file":
    let home = freshHome("waku-treg-state-broken")
    writeFile(home / "mcp.json", "{nope")
    let (where, detail) = tregState(home)
    assert where == "not_added"
    assert "not valid JSON" in detail

  test "a relay name with its own key is connected":
    let home = freshHome("waku-treg-state-relay")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "treg", "url": "https://relay.example/mcp", "auth_env": "TREG_KEY"}]}""")
    let (where, detail) = tregState(home)
    assert where == "connected"
    assert detail == "using the key in $TREG_KEY"

  test "a plain entry without oauth is connected":
    let home = freshHome("waku-treg-state-plain")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "treg", "url": "https://treg.to/mcp/"}]}""")
    let (where, _) = tregState(home)
    assert where == "connected"

  test "oauth without a token is not signed in, with one connected":
    let home = freshHome("waku-treg-state-oauth")
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "treg", "url": "https://treg.to/mcp/", "oauth": true}]}""")
    let (before, _) = tregState(home)
    assert before == "not_signed_in"
    createDir(home / "mcp-auth")
    writeFile(authFilePath(home, "treg"),
      """{"account": "you@treg.to"}""")
    let (after, detail) = tregState(home)
    assert after == "connected"
    assert detail.startsWith("as ")

  test "the card carries the connections page shape":
    let card = tregCard(freshHome("waku-treg-card-empty"))
    assert card["key"].getStr() == "treg"
    assert card["name"].getStr() == "treg"
    assert card["group"].getStr() == "Search & Observability"
    assert "Live data" in card["what"].getStr()
    assert card["state"].getStr() == "not_added"
