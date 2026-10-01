## Phase 8a tests: dashboard read-only backend — static files + GET routes.
## Offline only: temp homes, stub catalog fetch, no network, no `.waku/` writes.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import ../src/catalog
import ../src/dashboard
import ../src/pricing
import ../src/providers

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc testDeps(home, staticDir: string): DashboardDeps =
  DashboardDeps(home: home, staticDir: staticDir, provider: "anthropic",
    model: "test-model", smallModel: "", baseUrl: "", apiKey: "",
    providers: @[], env: initTable[string, string](),
    fetch: proc(url, key: string): string =
      raise newException(CatchableError, "network is stubbed: " & url),
    today: "2026-10-01", nowIso: "2026-10-01T00:00:00+00:00")

suite "phase 8a static content types":
  test "known suffixes match Python STATIC_TYPES":
    assert contentTypeFor("app.js") == "text/javascript"
    assert contentTypeFor("style.css") == "text/css"
    assert contentTypeFor("icon.svg") == "image/svg+xml"
    assert contentTypeFor("index.html") == "text/html; charset=utf-8"
    assert contentTypeFor("font.woff2") == "font/woff2"

  test "unknown suffix falls back to octet-stream":
    assert contentTypeFor("data.bin") == "application/octet-stream"
    assert contentTypeFor("noext") == "application/octet-stream"

suite "phase 8a serveStatic":
  test "serves a file with its content type":
    let root = freshDir("waku-dash-static")
    let web = root / "static"
    createDir(web)
    writeFile(web / "app.js", "console.log(1);")
    let (status, ctype, body) = serveStatic(web, "/static/app.js")
    assert status == 200
    assert ctype == "text/javascript"
    assert body == "console.log(1);"
    removeDir(root)

  test "query strings are stripped like Python":
    let root = freshDir("waku-dash-staticq")
    let web = root / "static"
    createDir(web)
    writeFile(web / "style.css", "a{}")
    let (status, _, _) = serveStatic(web, "/static/style.css?v=2")
    assert status == 200
    removeDir(root)

  test "traversal outside the static dir is a 404":
    let root = freshDir("waku-dash-traverse")
    let web = root / "static"
    createDir(web)
    writeFile(root / "secret.txt", "nope")
    assert serveStatic(web, "/static/../secret.txt")[0] == 404
    assert serveStatic(web, "/static/../../etc/hostname")[0] == 404
    removeDir(root)

  test "missing file is a 404":
    let root = freshDir("waku-dash-missing")
    createDir(root / "static")
    assert serveStatic(root / "static", "/static/nope.js")[0] == 404
    removeDir(root)

suite "phase 8a handleGet index fallback":
  test "unknown path falls back to index.html like Python":
    let root = freshDir("waku-dash-index")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    let d = testDeps(root, web)
    let (status, ctype, body) = handleGet(d, "/nope-not-a-route")
    assert status == 200
    assert ctype == "text/html; charset=utf-8"
    assert body == "<html></html>"
    removeDir(root)

  test "root serves index.html":
    let root = freshDir("waku-dash-root")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html>waku</html>")
    let (status, _, body) = handleGet(testDeps(root, web), "/")
    assert status == 200
    assert "waku" in body
    removeDir(root)

  test "missing index is a 404, not a crash":
    let root = freshDir("waku-dash-noindex")
    createDir(root / "static")
    assert handleGet(testDeps(root, root / "static"), "/")[0] == 404
    removeDir(root)

suite "phase 8a /api/models":
  test "unknown provider returns unlisted defaults without fetching":
    let root = freshDir("waku-dash-models")
    createDir(root / "static")
    var called = false
    var d = testDeps(root, root / "static")
    d.fetch = proc(url, key: string): string =
      called = true
      return "{}"
    let (status, ctype, body) = handleGet(d, "/api/models?provider=nope")
    assert status == 200
    assert ctype == "application/json"
    let node = parseJson(body)
    assert node["listed"].getBool() == false
    assert node["provider"].getStr() == "nope"
    assert not called  # offline: no catalog URL, no fetch attempted
    removeDir(root)

  test "fetch failure surfaces as listed=false with an error":
    let root = freshDir("waku-dash-modelfail")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.providers = @[Provider(name: "fake", kind: "openai",
      baseUrl: "http://127.0.0.1:9", catalogFromBaseUrl: true)]
    d.provider = "fake"
    let (status, _, body) = handleGet(d, "/api/models")
    assert status == 200
    let node = parseJson(body)
    assert node["listed"].getBool() == false
    assert node.hasKey("error")
    removeDir(root)

  test "a stubbed catalog lists entries free-first like Python":
    clearModelsCache()
    let root = freshDir("waku-dash-modellist")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.providers = @[Provider(name: "fake", kind: "openai",
      baseUrl: "http://127.0.0.1:9", catalogFromBaseUrl: true)]
    d.provider = "fake"
    d.fetch = proc(url, key: string): string =
      assert url == "http://127.0.0.1:9/models"
      return """{"data": [{"id": "b"}, {"id": "a:free",
        "pricing": {"prompt": "0", "completion": "0"}}]}"""
    let (status, _, body) = handleGet(d, "/api/models")
    assert status == 200
    let node = parseJson(body)
    assert node["listed"].getBool() == true
    assert node["models"][0]["id"].getStr() == "a:free"
    assert node["models"][1]["id"].getStr() == "b"
    clearPriceCache()
    clearModelsCache()
    removeDir(root)

suite "phase 8a /api/events":
  proc seedTrace(home: string) =
    createDir(home / "traces")
    writeFile(home / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"turn_start\"}\nnot json\n" &
      "{\"type\": \"gate\", \"decision\": \"retrieve\"}\n" &
      "{\"type\": \"turn_end\"}\n")

  test "missing trace file is empty with cursor 0":
    let root = freshDir("waku-dash-evempty")
    createDir(root / "static")
    let (status, _, body) = handleGet(testDeps(root, root / "static"),
      "/api/events")
    assert status == 200
    let node = parseJson(body)
    assert node["events"].len == 0
    assert node["cursor"].getInt() == 0
    removeDir(root)

  test "no cursor returns the tail only, like Python":
    let root = freshDir("waku-dash-evtail")
    createDir(root / "static")
    seedTrace(root)
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/events")[2])
    assert node["events"].len == 0
    assert node["cursor"].getInt() == 3  # the bad line never counts
    removeDir(root)

  test "cursor 0 replays every valid event":
    let root = freshDir("waku-dash-evzero")
    createDir(root / "static")
    seedTrace(root)
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/events?cursor=0")[2])
    assert node["events"].len == 3
    assert node["events"][0]["type"].getStr() == "turn_start"
    assert node["cursor"].getInt() == 3
    removeDir(root)

  test "out-of-range cursors reset to the tail":
    let root = freshDir("waku-dash-evrange")
    createDir(root / "static")
    seedTrace(root)
    let d = testDeps(root, root / "static")
    for raw in ["-1", "99", "bogus"]:
      let node = parseJson(handleGet(d, "/api/events?cursor=" & raw)[2])
      assert node["events"].len == 0
      assert node["cursor"].getInt() == 3
    removeDir(root)

suite "phase 8a /api/data status":
  test "spend derives from the ledger at read time":
    let root = freshDir("waku-dash-data")
    createDir(root / "static")
    # 1M in + 1M out on the (3.0, 15.0) default estimate = 18.0
    writeFile(root / "usage.jsonl",
      "{\"ts\": \"2026-10-01T00:00:00+00:00\", \"provider\": \"nope\", " &
      "\"model\": \"m\", \"in\": 1000000, \"out\": 1000000}\nbad line\n")
    let (status, ctype, body) = handleGet(testDeps(root, root / "static"),
      "/api/data")
    assert status == 200
    assert ctype == "application/json"
    let node = parseJson(body)
    assert node["provider"].getStr() == "anthropic"
    assert node["model"].getStr() == "test-model"
    assert node["home"].getStr().len > 0
    assert node["generated_at"].getStr() == "2026-10-01T00:00:00+00:00"
    assert node["usage"]["calls"].getInt() == 1
    assert node["usage"]["cost"].getFloat() == 18.0
    assert node["connections"].kind == JArray
    assert node["trace"]["file"].getStr() == "none"
    removeDir(root)

  test "trace file name is reported when today has one":
    let root = freshDir("waku-dash-datatrace")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"turn_start\"}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["trace"]["file"].getStr() == "2026-10-01.jsonl"
    assert node["trace"]["lines"].getInt() == 1
    removeDir(root)

suite "phase 8a route surface":
  test "every 8a route is a real Python GET route (contract stays green)":
    for r in readGetRoutes():
      assert r in pythonPinnedGet

  test "every 8a route answers 200 against an empty home":
    let root = freshDir("waku-dash-routes")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    let d = testDeps(root, web)
    for r in readGetRoutes():
      let (status, _, _) = handleGet(d, r)
      assert status == 200, r
    removeDir(root)

suite "phase 8a bind prose":
  test "loopback by default, env override wins":
    assert bindHost(initTable[string, string]()) == "127.0.0.1"
    assert bindHost({"WAKU_DASHBOARD_HOST": "0.0.0.0"}.toTable) == "0.0.0.0"

  test "port precedence is WAKU_DASHBOARD_PORT, then PORT, then 7777":
    assert dashboardPort(initTable[string, string]()) == 7777
    assert dashboardPort({"PORT": "8888"}.toTable) == 8888
    assert dashboardPort({"WAKU_DASHBOARD_PORT": "9999",
      "PORT": "8888"}.toTable) == 9999
    assert dashboardPort({"PORT": "bogus"}.toTable) == 7777
