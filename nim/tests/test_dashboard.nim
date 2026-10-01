## Phase 8a tests: dashboard read-only backend — static files + GET routes.
## Phase 8b tests: POST mutations, SSE streams, reveal, server loop.
## Offline only: temp homes, stub catalog fetch, stub chat/voice/session
## seams, no network, no `.waku/` writes outside temp dirs.

import std/json
import std/os
import std/strutils
import std/tables
import std/unittest

import db_connector/db_sqlite

import ../src/catalog
import ../src/dashboard
import ../src/db
import ../src/integrations
import ../src/memory
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
    today: "2026-10-01", nowIso: "2026-10-01T00:00:00+00:00",
    dotenvPath: "", hostOs: "linux",
    chatFn: nil, chatStreamFn: nil, graphStreamFn: nil, voiceFn: nil,
    sessionFn: nil, revealProbe: nil, revealOpen: nil, raceFn: nil,
    judgeFn: nil, memoryRunFn: nil, judgmentRaceFn: nil,
    hostedListFn: nil, hostedWipeFn: nil, judgmentSuites: newJArray(),
    memoryExample: "", store: nil,
    probes: initTable[string, ProbeFn](), providerProbe: nil,
    rebuild: nil, gatewayReload: nil, gatewayStatus: nil)

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

proc collectFrames(d: var DashboardDeps, target,
    body: string): (bool, seq[string]) =
  ## Run one SSE route into memory: the offline shape of the socket loop.
  var frames: seq[string] = @[]
  let handled = handleStream(d, target, body,
    proc(f: string) = frames.add(f))
  (handled, frames)

proc frameKind(frame: string): string =
  ## The `kind` of one `data: {...}` frame.
  assert frame.startsWith("data: ")
  assert frame.endsWith("\n\n")
  parseJson(frame[6 .. ^3])["kind"].getStr()

proc seedChatDb(home: string) =
  let db = connectDb(home)
  db.logChat("hello", "hi there", "default", "dashboard", "")
  db.logChat("other", "other reply", "s-2", "cli", "")
  db.close()

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

suite "phase 8b sseFrame":
  test "frames are data: lines with the kind merged in":
    let frame = sseFrame("done", %*{"reply": "hi"})
    assert frameKind(frame) == "done"
    assert parseJson(frame[6 .. ^3])["reply"].getStr() == "hi"

  test "an event kind wins, like Python's {'kind': kind, **ev}":
    assert frameKind(sseFrame("done", %*{"kind": "tool"})) == "tool"

suite "phase 8b POST /api/chat":
  test "empty message is a 200 error, never a turn":
    let root = freshDir("waku-dash-chatempty")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    var called = false
    d.chatFn = proc(m: string): JsonNode =
      called = true
      %*{"reply": m}
    let (status, ctype, body) = handlePost(d, "/api/chat",
      """{"message": "  "}""")
    assert status == 200
    assert ctype == "application/json"
    assert parseJson(body)["error"].getStr() == "empty message"
    assert not called
    removeDir(root)

  test "a wired turn answers 200 with its payload":
    let root = freshDir("waku-dash-chat")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.chatFn = proc(m: string): JsonNode = %*{"reply": "echo: " & m}
    let (status, _, body) = handlePost(d, "/api/chat",
      """{"message": "hi"}""")
    assert status == 200
    assert parseJson(body)["reply"].getStr() == "echo: hi"
    removeDir(root)

  test "a failing turn surfaces as a 200 error, never a 500":
    let root = freshDir("waku-dash-chatfail")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.chatFn = proc(m: string): JsonNode =
      raise newException(CatchableError, "boom")
    let (status, _, body) = handlePost(d, "/api/chat",
      """{"message": "hi"}""")
    assert status == 200
    assert "boom" in parseJson(body)["error"].getStr()
    removeDir(root)

  test "an unwired turn is an honest error, not a hang":
    let root = freshDir("waku-dash-chatnil")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (status, _, body) = handlePost(d, "/api/chat",
      """{"message": "hi"}""")
    assert status == 200
    assert parseJson(body)["error"].getStr().len > 0
    removeDir(root)

suite "phase 8b chat/stream and graph/stream":
  test "empty chat-stream message emits one done error frame":
    let root = freshDir("waku-dash-csempty")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (handled, frames) = collectFrames(d, "/api/chat/stream",
      """{"message": ""}""")
    assert handled
    assert frames.len == 1
    assert frameKind(frames[0]) == "done"
    assert parseJson(frames[0][6 .. ^3])["error"].getStr() ==
      "empty message"
    removeDir(root)

  test "turn events stream as frames in order":
    let root = freshDir("waku-dash-cs")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.chatStreamFn = proc(m: string, emit: SseEmit) =
      emit("gate", %*{"decision": "skip"})
      emit("done", %*{"reply": m})
    let (handled, frames) = collectFrames(d, "/api/chat/stream",
      """{"message": "hi"}""")
    assert handled
    assert frames.len == 2
    assert frameKind(frames[0]) == "gate"
    assert frameKind(frames[1]) == "done"
    assert parseJson(frames[1][6 .. ^3])["reply"].getStr() == "hi"
    removeDir(root)

  test "a dying turn ends the stream with a done error":
    let root = freshDir("waku-dash-csboom")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.chatStreamFn = proc(m: string, emit: SseEmit) =
      raise newException(CatchableError, "stream boom")
    let (handled, frames) = collectFrames(d, "/api/chat/stream",
      """{"message": "hi"}""")
    assert handled
    assert frames.len == 1
    assert "stream boom" in parseJson(frames[0][6 .. ^3])["error"].getStr()
    removeDir(root)

  test "an unwired graph runner reports the unknown workflow":
    let root = freshDir("waku-dash-gsnil")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (handled, frames) = collectFrames(d, "/api/graph/stream",
      """{"workflow": "gather"}""")
    assert handled
    assert frames.len == 1
    assert "unknown workflow 'gather'" in
      parseJson(frames[0][6 .. ^3])["error"].getStr()
    removeDir(root)

  test "a wired graph runner streams its node events":
    let root = freshDir("waku-dash-gs")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.graphStreamFn = proc(p: JsonNode, emit: SseEmit) =
      emit("node_end", %*{"node": "fetch"})
      emit("done", %*{"workflow": p["workflow"].getStr()})
    let (handled, frames) = collectFrames(d, "/api/graph/stream",
      """{"workflow": "gather"}""")
    assert handled
    assert frames.len == 2
    assert frameKind(frames[0]) == "node_end"
    assert parseJson(frames[1][6 .. ^3])["workflow"].getStr() == "gather"
    removeDir(root)

  test "non-stream paths are not streams":
    let root = freshDir("waku-dash-nostream")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (handled, frames) = collectFrames(d, "/api/chat",
      """{"message": "hi"}""")
    assert not handled
    assert frames.len == 0
    removeDir(root)

suite "phase 8b POST /api/voice":
  test "without a transcriber the error names the missing extra":
    let root = freshDir("waku-dash-voicenil")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (status, _, body) = handlePost(d, "/api/voice", "RIFF-bytes")
    assert status == 200
    assert "voice" in parseJson(body)["error"].getStr().toLowerAscii()
    removeDir(root)

  test "a wired transcriber reads the raw blob, not JSON":
    let root = freshDir("waku-dash-voice")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.voiceFn = proc(raw: string): JsonNode =
      %*{"text": "heard " & $raw.len & " bytes"}
    let (status, _, body) = handlePost(d, "/api/voice", "12345")
    assert status == 200
    assert parseJson(body)["text"].getStr() == "heard 5 bytes"
    removeDir(root)

suite "phase 8b POST /api/memory":
  test "save_soul writes SOUL.md with a trailing newline":
    let root = freshDir("waku-dash-soul")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (status, _, body) = handlePost(d, "/api/memory",
      """{"action": "save_soul", "content": "Be kind."}""")
    assert status == 200
    assert parseJson(body)["ok"].getBool()
    assert readFile(root / "SOUL.md") == "Be kind.\n"
    removeDir(root)

  test "save_soul refuses an empty soul":
    let root = freshDir("waku-dash-soulempty")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (_, _, body) = handlePost(d, "/api/memory",
      """{"action": "save_soul", "content": "  "}""")
    assert "empty" in parseJson(body)["error"].getStr().toLowerAscii()
    removeDir(root)

  test "save_skill writes a valid SKILL.md inside the home skills dir":
    let root = freshDir("waku-dash-skill")
    createDir(root / "static")
    createDir(root / "skills" / "tidy")
    let dest = root / "skills" / "tidy" / "SKILL.md"
    var d = testDeps(root, root / "static")
    let content = "---\nname: tidy\ndescription: tidies\n---\n# Tidy\n"
    let (_, _, body) = handlePost(d, "/api/memory",
      $(%*{"action": "save_skill", "path": dest, "content": content}))
    assert parseJson(body).getOrDefault("ok").getBool(false)
    assert readFile(dest) == content.strip() & "\n"
    removeDir(root)

  test "save_skill rejects bad frontmatter, wrong names and escapes":
    let root = freshDir("waku-dash-skillbad")
    createDir(root / "static")
    createDir(root / "skills")
    var d = testDeps(root, root / "static")
    let nofm = $(%*{"action": "save_skill",
      "path": root / "skills" / "SKILL.md", "content": "no frontmatter"})
    assert "frontmatter" in
      parseJson(handlePost(d, "/api/memory", nofm)[2])["error"].getStr()
    let wrong = $(%*{"action": "save_skill",
      "path": root / "skills" / "notes.md", "content": "---\nname: x\n---\n"})
    assert "SKILL.md" in
      parseJson(handlePost(d, "/api/memory", wrong)[2])["error"].getStr()
    let esc = $(%*{"action": "save_skill",
      "path": getTempDir() / "skills" / "SKILL.md",
      "content": "---\nname: x\ndescription: y\n---\n"})
    assert "skills folders" in
      parseJson(handlePost(d, "/api/memory", esc)[2])["error"].getStr()
    removeDir(root)

  test "fact and episode crud moves sqlite rows":
    let root = freshDir("waku-dash-memcrud")
    createDir(root / "static")
    let db = connectDb(root)
    db.addFact("maria", "likes tea")
    db.addEpisode("first run", "2026-10-01")
    let fid = db.getValue(sql"SELECT id FROM facts")
    let eid = db.getValue(sql"SELECT id FROM episodes")
    db.close()
    var d = testDeps(root, root / "static")
    let upd = $(%*{"action": "update_fact", "id": parseInt(fid),
      "content": "likes coffee"})
    assert parseJson(handlePost(d, "/api/memory", upd)[2])["ok"].getBool()
    let del = $(%*{ "action": "delete_fact", "id": parseInt(fid)})
    assert parseJson(handlePost(d, "/api/memory", del)[2])["ok"].getBool()
    let delep = $(%*{"action": "delete_episode", "id": parseInt(eid)})
    assert parseJson(handlePost(d, "/api/memory", delep)[2])["ok"].getBool()
    let db2 = connectDb(root)
    assert db2.getValue(sql"SELECT COUNT(*) FROM facts") == "0"
    assert db2.getValue(sql"SELECT COUNT(*) FROM episodes") == "0"
    db2.close()
    removeDir(root)

  test "bad ids and unknown actions are errors":
    let root = freshDir("waku-dash-membad")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let bad = handlePost(d, "/api/memory",
      """{"action": "delete_fact", "id": "nope"}""")[2]
    assert parseJson(bad)["error"].getStr() == "bad id"
    let unk = handlePost(d, "/api/memory",
      """{"action": "levitate"}""")[2]
    assert "unknown action" in parseJson(unk)["error"].getStr()
    removeDir(root)

  test "notion episodes stay an honest error in the Nim port":
    let root = freshDir("waku-dash-memnotion")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.env["WAKU_EPISODIC_STORE"] = "notion"
    let (_, _, body) = handlePost(d, "/api/memory",
      """{"action": "delete_episode", "id": 1}""")
    assert "notion" in parseJson(body)["error"].getStr().toLowerAscii()
    removeDir(root)

suite "phase 8b POST /api/settings and /api/pin":
  test "episodic_store stays in Connections":
    let root = freshDir("waku-dash-setep")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (_, _, body) = handlePost(d, "/api/settings",
      """{"episodic_store": "notion"}""")
    assert "Connections" in parseJson(body)["error"].getStr()
    removeDir(root)

  test "toggles persist to env and the dotenv file":
    let root = freshDir("waku-dash-settog")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.dotenvPath = root / ".env"
    let (status, _, body) = handlePost(d, "/api/settings",
      """{"experimental": "1", "graph_workflows": ""}""")
    assert status == 200
    assert parseJson(body)["ok"].getBool()
    assert d.env["WAKU_EXPERIMENTAL"] == "1"
    assert d.env["WAKU_GRAPH_WORKFLOWS"] == ""
    let dotenv = readFile(root / ".env")
    assert "WAKU_EXPERIMENTAL=1" in dotenv
    removeDir(root)

  test "pin needs a provider and a model":
    let root = freshDir("waku-dash-pinreq")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (_, _, body) = handlePost(d, "/api/pin",
      """{"action": "pin", "provider": "demo"}""")
    assert "required" in parseJson(body)["error"].getStr()
    removeDir(root)

  test "pin, unpin and default reorder models.json":
    let root = freshDir("waku-dash-pin")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    discard handlePost(d, "/api/pin",
      """{"action": "pin", "provider": "demo", "model": "b"}""")
    discard handlePost(d, "/api/pin",
      """{"action": "pin", "provider": "demo", "model": "a"}""")
    var node = parseJson(handlePost(d, "/api/pin",
      """{"action": "default", "provider": "demo", "model": "a"}""")[2])
    assert node["ok"].getBool()
    assert node["pinned"][0]["model"].getStr() == "a"
    node = parseJson(handlePost(d, "/api/pin",
      """{"action": "unpin", "provider": "demo", "model": "a"}""")[2])
    assert node["pinned"].len == 1
    let unk = handlePost(d, "/api/pin",
      """{"action": "levitate", "provider": "demo", "model": "b"}""")[2]
    assert "unknown action" in parseJson(unk)["error"].getStr()
    removeDir(root)

suite "phase 8b POST /api/query":
  test "empty, non-select and multi-statement bodies are errors":
    let root = freshDir("waku-dash-qbad")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    assert "SELECT" in parseJson(handlePost(d, "/api/query",
      """{"sql": "   "}""")[2])["error"].getStr()
    assert "Only SELECT" in parseJson(handlePost(d, "/api/query",
      """{"sql": "DELETE FROM facts"}""")[2])["error"].getStr()
    assert "One statement" in parseJson(handlePost(d, "/api/query",
      """{"sql": "SELECT 1; SELECT 2"}""")[2])["error"].getStr()
    removeDir(root)

  test "select and with read the state db, capped at 200 rows":
    let root = freshDir("waku-dash-q")
    createDir(root / "static")
    let db = connectDb(root)
    db.addFact("maria", "likes tea")
    db.close()
    var d = testDeps(root, root / "static")
    let node = parseJson(handlePost(d, "/api/query",
      """{"sql": "SELECT subject, content FROM facts"}""")[2])
    assert node["columns"] == %*["subject", "content"]
    assert node["rows"] == %*[["maria", "likes tea"]]
    let withNode = parseJson(handlePost(d, "/api/query",
      """{"sql": "WITH x AS (SELECT 1 AS a) SELECT a FROM x"}""")[2])
    assert withNode["rows"] == %*[["1"]]
    removeDir(root)

  test "a missing table surfaces as an error, never a 500":
    let root = freshDir("waku-dash-qmissing")
    createDir(root / "static")
    discard connectDb(root)
    var d = testDeps(root, root / "static")
    let (status, _, body) = handlePost(d, "/api/query",
      """{"sql": "SELECT * FROM nope"}""")
    assert status == 200
    assert parseJson(body).hasKey("error")
    removeDir(root)

suite "phase 8b POST /api/session":
  test "history reads the thread with meta, without touching the agent":
    let root = freshDir("waku-dash-sesshist")
    createDir(root / "static")
    seedChatDb(root)
    var d = testDeps(root, root / "static")
    var touched = false
    d.sessionFn = proc(p: JsonNode): JsonNode =
      touched = true
      %*{}
    let node = parseJson(handlePost(d, "/api/session",
      """{"action": "history", "id": "default"}""")[2])
    assert node["ok"].getBool()
    assert node["session_id"].getStr() == "default"
    assert node["history"].len == 2
    assert node["history"][0]["role"].getStr() == "user"
    assert node["history"][1]["meta"].kind == JNull
    assert not touched
    removeDir(root)

  test "__all__ returns the whole cross-thread timeline":
    let root = freshDir("waku-dash-sessall")
    createDir(root / "static")
    seedChatDb(root)
    var d = testDeps(root, root / "static")
    let node = parseJson(handlePost(d, "/api/session",
      """{"action": "history", "id": "__all__"}""")[2])
    assert node["history"].len == 4
    removeDir(root)

  test "new delegates to the agent seam when wired":
    let root = freshDir("waku-dash-sessfn")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.sessionFn = proc(p: JsonNode): JsonNode =
      %*{"ok": true, "session_id": "s-stub", "history": []}
    let node = parseJson(handlePost(d, "/api/session",
      """{"action": "new"}""")[2])
    assert node["session_id"].getStr() == "s-stub"
    removeDir(root)

  test "new without a seam still mints a dated thread":
    let root = freshDir("waku-dash-sessnew")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let node = parseJson(handlePost(d, "/api/session",
      """{"action": "new"}""")[2])
    assert node["ok"].getBool()
    assert node["session_id"].getStr().startsWith("s-")
    assert node["history"].len == 0
    removeDir(root)

  test "unknown session actions are errors":
    let root = freshDir("waku-dash-sessbad")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (_, _, body) = handlePost(d, "/api/session",
      """{"action": "levitate"}""")
    assert "unknown action" in parseJson(body)["error"].getStr()
    removeDir(root)

suite "phase 8b GET /api/reveal":
  test "paths outside the home stay inside":
    let root = freshDir("waku-dash-revout")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    writeFile(root / "secret.txt", "nope")
    var d = testDeps(root, web)
    assert "outside" in
      parseJson(handleGet(d, "/api/reveal?path=..%2Fsecret.txt")[2])[
        "error"].getStr()
    removeDir(root)

  test "a missing path is an error, not a crash":
    let root = freshDir("waku-dash-revmiss")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    var d = testDeps(root, web)
    assert "not found" in
      parseJson(handleGet(d, "/api/reveal?path=nope.txt")[2])["error"].getStr()
    removeDir(root)

  test "an editor seam opens files, never sqlite":
    let root = freshDir("waku-dash-reved")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    writeFile(root / "notes.txt", "hi")
    discard connectDb(root)  # state.db exists now
    var d = testDeps(root, web)
    var opened: seq[string] = @[]
    d.revealProbe = proc(name: string): bool = name == "code"
    d.revealOpen = proc(argv: seq[string]) = opened = argv
    let node = parseJson(handleGet(d, "/api/reveal?path=notes.txt")[2])
    assert node["ok"].getBool()
    assert node["opened_in"].getStr() == "code"
    assert opened == @["code", absolutePath(root / "notes.txt")]
    let (_, _, dbBody) = handleGet(d, "/api/reveal?path=state.db")
    assert "macOS-only" in parseJson(dbBody)["error"].getStr()
    removeDir(root)

  test "without an editor off macOS the error keeps the path":
    let root = freshDir("waku-dash-revplat")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    var d = testDeps(root, web)
    d.revealProbe = proc(name: string): bool = false
    let (_, _, body) = handleGet(d, "/api/reveal?path=.")
    let err = parseJson(body)["error"].getStr()
    assert "macOS-only" in err
    assert absolutePath(root) in err
    removeDir(root)

suite "phase 8b POST connections and providers":
  test "unknown integration keys are errors":
    let root = freshDir("waku-dash-connunk")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (_, _, body) = handlePost(d, "/api/connections",
      """{"key": "nope", "values": {}}""")
    assert "unknown integration" in parseJson(body)["error"].getStr()
    let (_, _, testBody) = handlePost(d, "/api/connections/test",
      """{"key": "nope"}""")
    assert "unknown integration" in parseJson(testBody)["error"].getStr()
    removeDir(root)

  test "a row with no probe reports no test available":
    let root = freshDir("waku-dash-conntest")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.env["TAVILY_API_KEY"] = "x"
    let node = parseJson(handlePost(d, "/api/connections/test",
      """{"key": "tavily"}""")[2])
    assert node["status"]["message"].getStr() == "no test available"
    removeDir(root)

  test "applying a connection writes the dotenv diff":
    let root = freshDir("waku-dash-connapply")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.dotenvPath = root / ".env"
    let node = parseJson(handlePost(d, "/api/connections",
      """{"key": "tavily", "values": {"TAVILY_API_KEY": "sk-test"}}""")[2])
    assert node["ok"].getBool()
    assert "TAVILY_API_KEY=sk-test" in readFile(root / ".env")
    assert d.env["TAVILY_API_KEY"] == "sk-test"
    removeDir(root)

  test "providers toggle availability without losing the key":
    let root = freshDir("waku-dash-provdis")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.dotenvPath = root / ".env"
    d.providers = @[Provider(name: "demo", kind: "openai",
      baseUrl: "http://127.0.0.1:9", keyEnv: "DEMO_API_KEY")]
    var node = parseJson(handlePost(d, "/api/providers",
      """{"provider": "demo", "disabled": true}""")[2])
    assert node["ok"].getBool()
    assert d.env["WAKU_DISABLED_PROVIDERS"] == "demo"
    d.env["WAKU_PROVIDER"] = "demo"
    node = parseJson(handlePost(d, "/api/providers",
      """{"provider": "demo", "disabled": true}""")[2])
    assert "current provider" in node["error"].getStr()
    node = parseJson(handlePost(d, "/api/providers",
      """{"provider": "nope", "disabled": true}""")[2])
    assert "unknown provider" in node["error"].getStr()
    removeDir(root)

  test "saving a provider key probes before persisting":
    let root = freshDir("waku-dash-provkey")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.dotenvPath = root / ".env"
    d.providers = @[Provider(name: "demo", kind: "openai",
      baseUrl: "http://127.0.0.1:9", keyEnv: "DEMO_API_KEY")]
    var probed = initTable[string, string]()
    d.providerProbe = proc(values: Table[string, string]) =
      probed = values
    let node = parseJson(handlePost(d, "/api/providers",
      """{"provider": "demo", "key": "sk-1"}""")[2])
    assert node["ok"].getBool()
    assert probed.getOrDefault("DEMO_API_KEY") == "sk-1"
    assert "DEMO_API_KEY=sk-1" in readFile(root / ".env")
    removeDir(root)

suite "phase 8b POST route surface":
  test "every 8b route is a real Python POST route (contract stays green)":
    for r in readPostRoutes():
      assert r in pythonPinnedPost

  test "every served POST route answers 200 against an empty home":
    let root = freshDir("waku-dash-postroutes")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.chatFn = proc(m: string): JsonNode = %*{"reply": m}
    d.voiceFn = proc(raw: string): JsonNode = %*{"text": raw}
    let bodies = {
      "/api/chat": """{"message": "hi"}""",
      "/api/memory": """{"action": "save_soul", "content": "x"}""",
      "/api/settings": """{}""",
      "/api/query": """{"sql": "SELECT 1"}""",
      "/api/session": """{"action": "history"}""",
      "/api/pin":
        """{"action": "pin", "provider": "demo", "model": "m"}""",
      "/api/connections": """{"key": "tavily", "values": {}}""",
      "/api/connections/test": """{"key": "tavily"}""",
      "/api/providers": """{"provider": "demo", "disabled": true}""",
      "/api/voice": "audio-bytes",
      "/api/judgment-arena/key": """{"key": "ts-test"}""",
      "/api/memory-arena/clean": """{}""",
    }.toTable
    for r in readPostRoutes():
      if r in bodies:
        let (status, _, _) = handlePost(d, r, bodies[r])
        assert status == 200, r
    removeDir(root)

  test "8d arena POST routes are real now (key validates, clean names)":
    let root = freshDir("waku-dash-arena8d")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (keyStatus, _, keyBody) = handlePost(d,
      "/api/judgment-arena/key", """{"key": ""}""")
    assert keyStatus == 200
    assert "paste a key" in parseJson(keyBody)["error"].getStr()
    let (cleanStatus, _, cleanBody) = handlePost(d,
      "/api/memory-arena/clean", "{}")
    assert cleanStatus == 200
    assert "no track chosen" in parseJson(cleanBody)["error"].getStr()
    for r in ["/api/judgment-arena/stream",
        "/api/memory-arena/stream"]:
      let (handled, frames) = collectFrames(d, r, "{}")
      assert handled, r
      assert frames.len == 1
      assert "not wired" in frames[0] or "no track" in frames[0] or
        "unknown suite" in frames[0]
    removeDir(root)

  test "unknown POST paths 404 and broken JSON 400s":
    let root = freshDir("waku-dash-post404")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    assert handlePost(d, "/api/nope", "{}")[0] == 404
    assert handlePost(d, "/api/chat", "{oops")[0] == 400
    removeDir(root)

suite "phase 8a pinned-but-later GET branches":
  test "8d arena GETs are real now, never the SPA shell":
    let root = freshDir("waku-dash-get8d")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    var d = testDeps(root, web)
    for r in ["/api/judgment-arena",
        "/api/memory-arena", "/api/memory-arena/stores"]:
      let (status, ctype, body) = handleGet(d, r)
      assert status == 200, r
      assert ctype == "application/json", r
      assert parseJson(body).kind in {JObject, JArray}, r
    removeDir(root)

  test "unknown api paths 404 as JSON":
    let root = freshDir("waku-dash-get404")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    var d = testDeps(root, web)
    let (status, ctype, body) = handleGet(d, "/api/nope")
    assert status == 404
    assert ctype == "application/json"
    assert "unknown api path" in body
    removeDir(root)

suite "phase 8b server loop":
  test "pickPort walks past busy ports, ten tries only":
    let taken = proc(port: int): bool = port in [7777, 7778]
    assert pickPort(7777, taken) == 7779
    let allTaken = proc(port: int): bool = true
    try:
      discard pickPort(7777, allTaken)
      assert false, "must raise"
    except CatchableError as exc:
      assert "no free port" in exc.msg

  test "prepareDashboard resolves host and walks the base port":
    let root = freshDir("waku-dash-prep")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.env["WAKU_DASHBOARD_HOST"] = "0.0.0.0"
    let taken = proc(port: int): bool = port == 7777
    let srv = prepareDashboard(d, taken)
    assert srv.host == "0.0.0.0"
    assert srv.port == 7778
    removeDir(root)

  test "runDashboardCmd reconciles, serves and shuts down":
    let root = freshDir("waku-dash-run")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    var srv = prepareDashboard(d,
      proc(port: int): bool = false)
    var reconciled = false
    var shutdown = false
    var servedPort = -1
    proc doReconcile() = reconciled = true
    proc doShutdown() = shutdown = true
    proc doServe(s: var DashboardServer) = servedPort = s.port
    let rc = runDashboardCmd(srv, doReconcile, doShutdown, doServe)
    assert rc == 0
    assert reconciled
    assert shutdown
    assert servedPort == srv.port
    removeDir(root)

suite "phase 8c compare wiring":
  test "history is a real GET inside the pinned surface":
    assert "/api/compare/history" in readGetRoutes()
    for r in readGetRoutes():
      assert r in pythonPinnedGet
    for r in readPostRoutes():
      assert r in pythonPinnedPost

  test "history answers 200 with the repriced shape on an empty home":
    let root = freshDir("waku-dash-chist")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (status, ctype, body) = handleGet(d, "/api/compare/history")
    assert status == 200
    assert ctype == "application/json"
    let node = parseJson(body)
    assert node["runs"].len == 0
    assert node["aggregate"].len == 0
    removeDir(root)

  test "clear, regrade and delete_run answer 200 on an empty home":
    let root = freshDir("waku-dash-cpost")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    for r in ["/api/compare/clear", "/api/compare/regrade",
        "/api/compare/delete_run"]:
      let (status, _, body) = handlePost(d, r, "{}")
      assert status == 200, r
      assert parseJson(body)["runs"].len == 0, r
    removeDir(root)

  test "a stored race round-trips through clear and delete":
    let root = freshDir("waku-dash-chist2")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.nowIso = "2026-10-01T00:00:00+00:00"
    d.raceFn = proc(message: string, specs: seq[string],
                     emit: SseEmit): JsonNode =
      var outp = newJArray()
      outp.add(%*{"spec": "a:m", "provider": "a", "model": "m",
        "reply": "done", "tokens_in": 10, "tokens_out": 5})
      outp
    let (_, frames) = collectFrames(d, "/api/compare/stream",
      """{"message": "hi", "models": ["a:m"]}""")
    assert frames.len == 1
    assert frameKind(frames[0]) == "done"
    let hist = parseJson(handleGet(d, "/api/compare/history")[2])
    assert hist["runs"].len == 1
    assert hist["runs"][0]["ts"].getStr() ==
      "2026-10-01T00:00:00+00:00"
    let ts = hist["runs"][0]["ts"].getStr()
    let del = parseJson(handlePost(d, "/api/compare/delete_run",
      $(%*{"ts": ts}))[2])
    assert del["runs"].len == 0
    removeDir(root)

  test "compare/stream validates before racing":
    let root = freshDir("waku-dash-cstream")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    var raced = false
    d.raceFn = proc(message: string, specs: seq[string],
                     emit: SseEmit): JsonNode =
      raced = true
      newJArray()
    let (_, frames) = collectFrames(d, "/api/compare/stream",
      """{"message": "", "models": []}""")
    assert frames.len == 1
    assert "message and models required" in frames[0]
    assert not raced
    removeDir(root)

  test "compare/stream without a runner is an honest done error":
    let root = freshDir("waku-dash-cstreamnil")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (handled, frames) = collectFrames(d, "/api/compare/stream",
      """{"message": "hi", "models": ["a:m"]}""")
    assert handled
    assert frames.len == 1
    assert "not wired" in frames[0]
    removeDir(root)

  test "a busy block fails fast without serving":
    let root = freshDir("waku-dash-runbusy")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    var srv = prepareDashboard(d,
      proc(port: int): bool = port != 7786)
    assert srv.port == 7786
    removeDir(root)

proc writeProbesFixture(dir: string): string =
  ## One demo track the 8d dashboard tests resolve against.
  result = dir / "probes.json"
  writeFile(result, """{"tracks": {"demo": {
    "label": "Demo", "seed": ["Priya prefers morning meetings."],
    "probes": [{"id": "recall", "test": "recall",
      "question": "When does Priya like to meet?",
      "expect_any": ["morning"]}]}}}""")

suite "phase 8d judgment-arena wiring":
  test "the picker serves suites, contestants and past runs":
    let root = freshDir("waku-dash-jget")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.judgmentSuites = %*[{"id": "s1", "title": "Leads"}]
    let (status, ctype, body) = handleGet(d, "/api/judgment-arena")
    assert status == 200
    assert ctype == "application/json"
    let node = parseJson(body)
    assert node["suites"].len == 1
    assert node["contestants"][0]["spec"].getStr() ==
      "typesafe:jev-latest"
    assert node["runs"].len == 0
    removeDir(root)

  test "the key endpoint validates before it ever writes":
    let root = freshDir("waku-dash-jkey")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.dotenvPath = root / ".env"
    let empty = parseJson(handlePost(d, "/api/judgment-arena/key",
      """{"key": "  "}""")[2])
    assert "paste a key" in empty["error"].getStr()
    let bad = parseJson(handlePost(d, "/api/judgment-arena/key",
      """{"key": "clave-con-\u00e1"}""")[2])
    assert "ASCII" in bad["error"].getStr()
    assert not fileExists(root / ".env")
    let ok = parseJson(handlePost(d, "/api/judgment-arena/key",
      """{"key": "ts-live"}""")[2])
    assert ok["ok"].getBool()
    assert ok["ready"].getBool()
    assert ok["where"].getStr() == root / ".env"
    assert "TYPESAFE_API_KEY=ts-live" in readFile(root / ".env")
    assert d.env["TYPESAFE_API_KEY"] == "ts-live"
    removeDir(root)

  test "judgment/stream validates the suite before any runner":
    let root = freshDir("waku-dash-jstream")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.judgmentSuites = %*[{"id": "s1", "title": "Leads"}]
    let (_, unknown) = collectFrames(d, "/api/judgment-arena/stream",
      """{"suite": "nope", "specs": []}""")
    assert unknown.len == 1
    assert "unknown suite" in unknown[0]
    let (_, nilFrames) = collectFrames(d, "/api/judgment-arena/stream",
      """{"suite": "s1", "specs": ["typesafe:jev-latest"]}""")
    assert nilFrames.len == 1
    assert "not wired" in nilFrames[0]
    removeDir(root)

  test "judgment/stream runs a wired race through to done":
    let root = freshDir("waku-dash-jstreamrun")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.judgmentSuites = %*[{"id": "s1"}]
    d.judgmentRaceFn = proc(suiteId: string, specs: seq[string],
        suites: JsonNode, emit: SseEmit) =
      emit("answer", %*{"spec": specs[0], "ok": true})
      emit("done", %*{"scoreboard": []})
    let (handled, frames) = collectFrames(d,
      "/api/judgment-arena/stream",
      """{"suite": "s1", "specs": ["typesafe:jev-latest"]}""")
    assert handled
    assert frames.len == 2
    assert frameKind(frames[0]) == "answer"
    assert frameKind(frames[1]) == "done"
    let (_, badFrames) = collectFrames(d, "/api/judgment-arena/stream",
      "{oops")
    assert "invalid JSON" in badFrames[0]
    removeDir(root)

suite "phase 8d memory-arena wiring":
  test "without the shipped fixture the tab reports unavailable":
    let root = freshDir("waku-dash-mgetoff")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.memoryExample = ""
    let node = parseJson(handleGet(d, "/api/memory-arena")[2])
    assert node["available"].getBool() == false
    removeDir(root)

  test "with a fixture the tab names sets, models and backends":
    let root = freshDir("waku-dash-mget")
    createDir(root / "static")
    let fx = writeProbesFixture(root)
    var d = testDeps(root, root / "static")
    d.memoryExample = fx
    let node = parseJson(handleGet(d, "/api/memory-arena")[2])
    assert node["available"].getBool()
    assert node["sets"].len == 1
    assert node["chosen"].getStr() == ""
    assert node["backends"][0].getStr() == "sqlite"
    assert node["models"].kind == JArray
    assert node["tracks"].hasKey("demo")
    let chosen = parseJson(handleGet(d,
      "/api/memory-arena?probes=" & fx & "::demo")[2])
    assert chosen["chosen"].getStr() == fx & "::demo"
    removeDir(root)

  test "stores read the live home until a track scopes a race":
    let root = freshDir("waku-dash-mstores")
    createDir(root / "static")
    let db = connectDb(root)
    db.addFact("priya", "prefers morning meetings")
    db.close()
    var d = testDeps(root, root / "static")
    let node = parseJson(handleGet(d,
      "/api/memory-arena/stores")[2])
    assert node.len == 2  # sqlite + control, nothing hosted configured
    assert node[0]["store"].getStr() == "sqlite"
    assert node[0]["kind"].getStr() == "live"
    assert node[0]["count"].getInt() == 1
    assert node[0]["facts"][0]["subject"].getStr() == "priya"
    assert node[1]["store"].getStr() == "control"
    assert "told nothing" in node[1]["note"].getStr()
    let only = parseJson(handleGet(d,
      "/api/memory-arena/stores?store=control")[2])
    assert only.len == 1
    assert only[0]["store"].getStr() == "control"
    removeDir(root)

  test "clean without a track deletes nothing, honestly":
    let root = freshDir("waku-dash-mclean")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let node = parseJson(handlePost(d, "/api/memory-arena/clean",
      """{}""")[2])
    assert "no track chosen" in node["error"].getStr()
    removeDir(root)

  test "clean with a fixture removes only this race's homes":
    let root = freshDir("waku-dash-mcleanfx")
    createDir(root / "static")
    let fx = writeProbesFixture(root)
    var d = testDeps(root, root / "static")
    d.memoryExample = fx
    let node = parseJson(handlePost(d, "/api/memory-arena/clean",
      $(%*{"probes": fx & "::demo"}))[2])
    assert node["errors"].len == 2  # mem0 + zep wipes unwired, said aloud
    assert "not wired" in node["errors"][0].getStr()
    assert node["partition"].getStr().startsWith("waku-arena-")
    removeDir(root)

  test "memory/stream without a runner ends done, never 500":
    let root = freshDir("waku-dash-mstream")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    let (_, untracked) = collectFrames(d, "/api/memory-arena/stream",
      """{}""")
    assert untracked.len == 1
    assert "no track 'example'" in untracked[0]
    let fx = writeProbesFixture(root)
    d.memoryExample = fx
    let (_, nilFrames) = collectFrames(d, "/api/memory-arena/stream",
      $(%*{"probes": fx & "::demo", "backends": ["sqlite"]}))
    assert nilFrames.len == 1
    assert "not wired" in nilFrames[0]
    removeDir(root)

  test "memory/stream runs a wired race through to done":
    let root = freshDir("waku-dash-mstreamrun")
    createDir(root / "static")
    let fx = writeProbesFixture(root)
    var d = testDeps(root, root / "static")
    d.memoryExample = fx
    var got: seq[string] = @[]
    d.memoryRunFn = proc(backends: seq[string], track, model: string,
        seedOnly: bool, fixture: JsonNode, emit: SseEmit) =
      got = backends
      assert track == "demo"
      emit("probe", %*{"contestant": "sqlite", "outcome": "pass"})
      emit("done", %*{"scoreboard": []})
    let (handled, frames) = collectFrames(d, "/api/memory-arena/stream",
      $(%*{"probes": fx & "::demo", "backends": []}))
    assert handled
    assert got == @["sqlite"]  # empty defaults, like Python
    assert frames.len == 2
    assert frameKind(frames[0]) == "probe"
    assert frameKind(frames[1]) == "done"
    let (_, badFrames) = collectFrames(d, "/api/memory-arena/stream",
      "{oops")
    assert "invalid JSON" in badFrames[0]
    removeDir(root)
