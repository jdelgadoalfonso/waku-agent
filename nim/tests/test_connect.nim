## `waku connect` tests: dispatcher exit codes plus both connectors with
## stubbed seams. Offline only: temp homes, no browser, no sockets — the
## live adapters (`waitGoogleCallbackLive`, `exchangeGoogleLive`) are never
## called here.

import std/json
import std/os
import std/strutils
import std/unittest

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
    waitLoopback: proc(port: int): string = target,
    exchange: proc(tokenUri, body: string): tuple[ok: bool,
      doc: JsonNode] = (true, exchangeDoc),
    nowUnix: 1700000000)

proc memorySignIn(ok: bool, msg = "", identity = ""): MemorySignInFn =
  result = proc(home, name: string): tuple[ok: bool, msg: string,
    identity: string] = (ok, msg, identity)

suite "connect dispatcher":
  test "no args prints usage and exits 1":
    let (msg, code) = cliConnect(@[], freshHome("waku-connect-noargs"),
      googleSeams(newJNull()), memorySignIn(true))
    assert "google" in msg and "waku-memory" in msg
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

  test "a refused exchange saves nothing":
    let home = freshHome("waku-connect-google-refused")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    let seams = GoogleSeams(
      openBrowser: proc(url: string): bool = true,
      waitLoopback: proc(port: int): string = "/?code=abc",
      exchange: proc(tokenUri, body: string): tuple[ok: bool,
        doc: JsonNode] = (false, newJNull()),
      nowUnix: 1700000000)
    let msg = googleConnect(home, seams)
    assert "token refused" in msg
    assert not fileExists(home / "google-token.json")

  test "consent caches the token and names the source":
    let home = freshHome("waku-connect-google-ok")
    writeFile(home / "credentials.json",
      """{"installed": {"client_id": "cid", "client_secret": "cs"}}""")
    let doc = %*{"access_token": "ya", "refresh_token": "rt",
                  "expires_in": 3600}
    let msg = googleConnect(home, googleSeams(doc))
    assert "connected (read-only via credentials.json override)" in msg
    assert "google-token.json" in msg
    let cached = parseJson(readFile(home / "google-token.json"))
    assert cached["token"].getStr() == "ya"
    assert cached["refresh_token"].getStr() == "rt"
    assert cached["client_id"].getStr() == "cid"
    assert cached["expiry"].getBiggestInt() == 1700003600

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
