## Phase 8a tests: dashboard read-only backend — static files + GET routes.
## Phase 8b tests: POST mutations, SSE streams, reveal, server loop.
## Offline only: temp homes, stub catalog fetch, stub chat/voice/session
## seams, no network, no `.waku/` writes outside temp dirs.

import std/json
import std/os
import std/strutils
import std/tables
import std/times
import std/unittest

import db_connector/db_sqlite

import ../src/app
import ../src/catalog
import ../src/config
import ../src/dashboard
import ../src/db
import ../src/loop
import ../src/integrations
import ../src/factstore
import ../src/memory
import factstore_fakes
import ../src/pricing
import ../src/providers
import ../src/receipt

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc payloadKeys*(src: string, lowercase = true): seq[string] =
  ## Every `D.<key>` / `d.<key>` read in one frontend file: `D` is the
  ## global `/api/data` blob and the views receive it as `d`, so both
  ## spellings are payload reads. A file that fetches an endpoint of
  ## its own (observe.js, compare.js, models.js, diagram.js) hands
  ## THAT response to its views as `d`, so such a file is extracted
  ## with `lowercase = false`: only `D.`, the global `refresh()` sets
  ## once per page, is a /api/data read there. DOM members on
  ## unrelated `d` locals (`querySelector`, `innerHTML`, …) are denied
  ## by name — a new one shows up as a missing payload key, and the
  ## fix is extending that list, never inventing an endpoint key for it.
  const domDeny = ["addEventListener", "appendChild", "body",
    "checked", "classList", "className", "click", "close", "createElement",
    "currentTarget", "dataset", "disabled", "files", "focus",
    "getAttribute", "getElementById", "innerHTML", "preventDefault",
    "querySelector", "querySelectorAll", "remove", "reset", "setAttribute",
    "show", "showModal", "stopPropagation", "style", "submit", "target",
    "textContent", "value"]
  const ident = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}
  var i = 0
  while i < src.len - 2:
    if (src[i] == 'D' or (src[i] == 'd' and lowercase)) and
        src[i + 1] == '.' and
        (i == 0 or src[i - 1] notin ident):
      var j = i + 2
      var key = ""
      while j < src.len and src[j] in ident:
        key.add(src[j])
        inc j
      if key.len > 0 and key[0] in {'a' .. 'z'} and key notin domDeny and
          key notin result:
        result.add(key)
      i = j
    else:
      inc i

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
    assert node["usage"]["total_cost"].getFloat() == 18.0
    assert node["connections"].kind == JArray
    assert node["trace"]["file"].getStr() == "none"
    removeDir(root)

  test "connections carry full card views like Python collect()":
    # The Connections tab groups cards by `group` and opens modals from
    # `fields` (views.js). Stubs without those keys collapse every card
    # into "Tools" and leave Channels/Productivity/Memory empty, so the
    # shape is the contract, not just the array.
    let root = freshDir("waku-dash-dataconnviews")
    createDir(root / "static")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    let conns = node["connections"]
    assert conns.kind == JArray
    assert conns.len > 0
    var groups: seq[string] = @[]
    for item in conns:
      assert item["key"].getStr().len > 0
      assert item["group"].getStr().len > 0
      assert item["name"].getStr().len > 0
      assert item["what"].getStr().len > 0
      assert item["status"]["state"].getStr().len > 0
      assert item["fields"].kind == JArray
      let g = item["group"].getStr()
      if g notin groups:
        groups.add(g)
    for g in ["Channels", "Calendar & Productivity",
        "Memory & Storage", "Search & Observability"]:
      assert g in groups, g
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

  test "graph block ships engine topologies, disabled by default":
    let root = freshDir("waku-dash-datagraph")
    createDir(root / "static")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    let g = node["graph"]
    assert g["enabled"].getBool() == false
    assert g["workflows"].len == 2
    assert g["workflows"][0]["name"].getStr() == "triage"
    assert g["workflows"][1]["name"].getStr() == "gather"
    for wf in g["workflows"]:
      assert wf["nodes"].len > 0
      assert wf["edges"].len > 0
    assert g["runs"].len == 0
    assert g["stats"]["quick"].getInt() == 0
    assert g["stats"]["full"].getInt() == 0
    removeDir(root)

  test "graph flag follows WAKU_GRAPH_WORKFLOWS":
    let root = freshDir("waku-dash-datagraphon")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.env["WAKU_GRAPH_WORKFLOWS"] = "1"
    let node = parseJson(handleGet(d, "/api/data")[2])
    assert node["graph"]["enabled"].getBool() == true
    removeDir(root)

  test "turns default to an empty array, stats to zeros":
    # The Loop tab reads `d.turns.length` with no fallback: `undefined`
    # here is the TypeError that blanks the page, so the empty home must
    # still serve the shape.
    let root = freshDir("waku-dash-dataturnsempty")
    createDir(root / "static")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["turns"].kind == JArray
    assert node["turns"].len == 0
    let s = node["stats"]
    for key in ["turns", "tool_calls", "tool_errors", "gate_skips",
        "gate_retrieves", "tokens_in", "tokens_out", "cost",
        "latency_avg", "latency_p95", "trace_files"]:
      assert s.hasKey(key), key
    assert s["turns"].getInt() == 0
    assert s["trace_files"].getInt() == 0
    removeDir(root)

  test "turns group trace events with latency and repriced cost":
    let root = freshDir("waku-dash-dataturns")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"turn_start\", \"user_message\": \"hi\", " &
      "\"ts\": \"2026-10-01T00:00:01+00:00\"}\n" &
      "{\"type\": \"gate\", \"decision\": \"skip\", \"reason\": \"greeting\", " &
      "\"ts\": \"2026-10-01T00:00:01+00:00\"}\n" &
      "{\"type\": \"route\", \"workflow\": \"triage\", " &
      "\"target\": \"quick_reply\"," &
      "\"ts\": \"2026-10-01T00:00:02+00:00\"}\n" &
      "{\"type\": \"triage\", \"route\": \"quick\", \"reason\": \"just thanks\", " &
      "\"ts\": \"2026-10-01T00:00:02+00:00\"}\n" &
      "{\"type\": \"llm\", \"usage\": {\"in\": 100, \"out\": 50}, " &
      "\"ts\": \"2026-10-01T00:00:04+00:00\"}\n" &
      "{\"type\": \"tool\", \"tool\": \"save_note\", " &
      "\"args\": {}, \"output\": \"boom failed hard. rest\", " &
      "\"ts\": \"2026-10-01T00:00:05+00:00\"}\n" &
      "{\"type\": \"graph_end\", \"workflow\": \"triage\", \"ms\": 9, " &
      "\"ts\": \"2026-10-01T00:00:06+00:00\"}\n" &
      "{\"type\": \"turn_end\", \"reply\": \"hey\", \"iterations\": 2, " &
      "\"ts\": \"2026-10-01T00:00:07+00:00\"}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["turns"].len == 1
    let t = node["turns"][0]
    assert t["user_message"].getStr() == "hi"
    assert t["reply"].getStr() == "hey"
    assert t["iterations"].getInt() == 2
    assert t["gate"]["decision"].getStr() == "skip"
    assert t["graph"]["route"].getStr() == "quick"
    assert t["graph"]["reason"].getStr() == "just thanks"
    assert t["latency_ms"].getInt() == 3000
    # 100 in @ $3/M + 50 out @ $15/M on the default estimate.
    assert abs(t["cost"].getFloat() - 0.00105) < 1e-9
    assert t["tools"].len == 1
    assert t["tools"][0]["status"].getStr() == "error"
    assert t["tools"][0]["summary"].getStr() == "boom failed hard"
    let s = node["stats"]
    assert s["turns"].getInt() == 1
    assert s["tool_calls"].getInt() == 1
    assert s["tool_errors"].getInt() == 1
    assert s["gate_skips"].getInt() == 1
    assert s["gate_retrieves"].getInt() == 0
    assert s["tokens_in"].getInt() == 100
    assert s["tokens_out"].getInt() == 50
    assert s["latency_avg"].getInt() == 3000
    assert s["latency_p95"].getInt() == 3000
    assert s["trace_files"].getInt() == 1
    removeDir(root)

  test "a turn carries the receipt its trace recorded, cost unchanged":
    # Spec 011: `app.respond` writes one `receipt` event per turn; the Loop
    # tab reads `t.receipt` (render.js). The payload is what `receipt.nim`
    # built, with the record's own `type`/`ts` wrapper taken off, so the
    # keys land in the builder's order.
    let root = freshDir("waku-dash-datareceipt")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"turn_start\", \"user_message\": \"hi\", " &
      "\"ts\": \"2026-10-01T00:00:01+00:00\"}\n" &
      "{\"type\": \"llm\", \"usage\": {\"in\": 100, \"out\": 50}, " &
      "\"ts\": \"2026-10-01T00:00:02+00:00\"}\n" &
      "{\"type\": \"receipt\", \"turn_id\": \"t_abc\", " &
      "\"model\": {\"id\": \"m\", \"in\": 100, \"out\": 50, " &
      "\"usd\": 0.00105, \"estimate\": true, " &
      "\"calls\": [{\"kind\": \"loop\", \"n\": 1}]}, " &
      "\"tools\": [], \"memory\": {\"searches\": [], \"used\": 0, " &
      "\"kept\": 2}, \"total_usd\": 0.00105, \"credits\": null, " &
      "\"ts\": \"2026-10-01T00:00:03+00:00\"}\n" &
      "{\"type\": \"turn_end\", \"reply\": \"hey\", \"iterations\": 1, " &
      "\"ts\": \"2026-10-01T00:00:04+00:00\"}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["turns"].len == 1
    let t = node["turns"][0]
    var keys: seq[string] = @[]
    for k in t["receipt"].keys:
      keys.add(k)
    assert keys == receiptKeys, "the builder's pinned set, in its order"
    assert t["receipt"]["turn_id"].getStr() == "t_abc"
    assert t["receipt"]["model"]["id"].getStr() == "m"
    assert t["receipt"]["memory"]["kept"].getInt() == 2
    assert t["receipt"]["credits"].kind == JNull
    # repricing is untouched: cost still comes from this turn's own calls
    assert abs(t["cost"].getFloat - 0.00105) < 1e-9
    assert node["stats"]["turns"].getInt() == 1
    assert node["stats"]["tokens_in"].getInt() == 100
    removeDir(root)

  test "a turn with no receipt event carries no receipt key":
    # The footer's fallback line (seconds, iterations, model) must still be
    # what an unrecorded turn draws, so the key is absent, not null.
    let root = freshDir("waku-dash-datareceiptnone")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"turn_start\", \"user_message\": \"hi\", " &
      "\"ts\": \"2026-10-01T00:00:01+00:00\"}\n" &
      "{\"type\": \"llm\", \"usage\": {\"in\": 100, \"out\": 50}, " &
      "\"ts\": \"2026-10-01T00:00:02+00:00\"}\n" &
      "{\"type\": \"turn_end\", \"reply\": \"hey\", \"iterations\": 1, " &
      "\"ts\": \"2026-10-01T00:00:03+00:00\"}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["turns"].len == 1
    let t = node["turns"][0]
    assert t.hasKey("receipt") == false
    assert abs(t["cost"].getFloat - 0.00105) < 1e-9
    removeDir(root)

  test "an unfinished turn names the hang, a bad stamp blanks latency":
    let root = freshDir("waku-dash-datunfinished")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"turn_start\", \"user_message\": \"stuck\", " &
      "\"ts\": \"not-a-time\"}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["turns"].len == 1
    let t = node["turns"][0]
    assert t["unfinished"].getBool() == true
    assert "NEVER FINISHED" in t["reply"].getStr()
    assert t["latency_ms"].kind == JNull
    removeDir(root)

  test "usage keeps Python's total_* shape":
    let root = freshDir("waku-dash-datausage")
    createDir(root / "static")
    writeFile(root / "usage.jsonl",
      "{\"ts\": \"2026-10-01T00:00:00+00:00\", \"provider\": \"nope\", " &
      "\"model\": \"m\", \"in\": 1000000, \"out\": 1000000}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["usage"]["calls"].getInt() == 1
    assert node["usage"]["total_in"].getInt() == 1000000
    assert node["usage"]["total_out"].getInt() == 1000000
    assert node["usage"]["total_cost"].getFloat() == 18.0
    removeDir(root)

  test "the catalog shows Gmail only when its switch is on":
    let root = freshDir("waku-dash-datagmail")
    createDir(root / "static")
    var deps = testDeps(root, root / "static")
    var names: seq[string] = @[]
    for t in parseJson(handleGet(deps, "/api/data")[2])["tools"]["catalog"]:
      names.add(t["name"].getStr())
    assert "gmail_search" notin names
    deps.env["WAKU_GMAIL"] = "1"
    names = @[]
    for t in parseJson(handleGet(deps, "/api/data")[2])["tools"]["catalog"]:
      names.add(t["name"].getStr())
    assert "gmail_search" in names
    assert "gmail_read" in names
    assert "gmail_send" in names
    # The sending switch does not add a second capability: the tool is the
    # same one, and only its effect changes, exactly like the registry.
    deps.env["WAKU_GMAIL_SEND"] = "1"
    names = @[]
    for t in parseJson(handleGet(deps, "/api/data")[2])["tools"]["catalog"]:
      names.add(t["name"].getStr())
    assert "gmail_send" in names
    removeDir(root)

  test "state rows read an empty home as empty arrays":
    let root = freshDir("waku-dash-datastateempty")
    createDir(root / "static")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["facts"].len == 0
    assert node["episodes"].len == 0
    assert node["episodes_source"].getStr() == "sqlite"
    assert node["episodes_error"].getStr() == ""
    assert node["calendar"].len == 0
    assert node["outbox"].len == 0
    assert node["soul"].getStr() == ""
    assert node["chat_pending"].getInt() == 0
    assert node["chat_log"].len == 0
    assert node["sessions"].len == 0
    assert node["current_session"].getStr().startsWith("dashboard-")
    assert node["consolidate_every"].getInt() == 6
    # Bundled repo skills load with no home skill present — like production.
    assert node["skills"].kind == JArray
    assert node["eval_report"].kind == JNull
    assert node["eval_history"].len == 0
    assert node["wake_scans"].len == 0
    assert node["trace_tail"].len == 0
    assert node["trace_errors"].len == 0
    assert node["trace_file"].kind == JNull
    assert node["settings"]["provider"].getStr() == "anthropic"
    let tools = node["tools"]
    assert tools["apple_on"].getBool() == false
    assert tools["planned"].len == 0
    assert tools["mcp"]["configured"].getBool() == false
    assert tools["mcp"]["live"].getBool() == false
    var names: seq[string] = @[]
    for t in tools["catalog"]:
      names.add(t["name"].getStr())
    for want in ["create_event", "list_events", "save_note",
        "send_message", "manage_memory", "update_soul", "create_skill"]:
      assert want in names, want
    removeDir(root)

  test "state rows serve seeded facts, episodes, calendar and chat":
    let root = freshDir("waku-dash-datastateseed")
    createDir(root / "static")
    createDir(root / "outbox")
    let db = connectDb(root)
    db.exec(sql("INSERT INTO facts (subject, content, source) VALUES " &
      "('Priya', 'morning meetings', 'user')"))
    db.exec(sql("INSERT INTO episodes (happened_at, summary) VALUES " &
      "('2026-09-01', 'a quiet week')"))
    db.exec(sql("INSERT INTO calendar_events (title, start) VALUES " &
      "('swim', '2026-10-04T17:00:00')"))
    db.close()
    writeFile(root / "SOUL.md", "be kind")
    writeFile(root / "outbox" / "digest.txt", "x".repeat(500))
    writeFile(root / "eval_report.json", "{\"ok\": true}")
    writeFile(root / "eval_runs.jsonl",
      "{\"n\": 1}\nbad\n{\"n\": 2}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["facts"].len == 1
    assert node["facts"][0]["subject"].getStr() == "Priya"
    # The id is the contract's opaque string, not sqlite's counter as a
    # number: a hosted store's UUID has to render here and survive the round
    # trip that memory.js performs. The value is still sqlite's 1.
    assert node["facts"][0]["id"].kind == JString
    assert node["facts"][0]["id"].getStr() == "1"
    assert node["episodes"].len == 1
    assert node["episodes"][0]["summary"].getStr() == "a quiet week"
    assert node["calendar"].len == 1
    assert node["calendar"][0]["title"].getStr() == "swim"
    assert node["soul"].getStr() == "be kind"
    assert node["outbox"].len == 1
    assert node["outbox"][0]["name"].getStr() == "digest.txt"
    assert node["outbox"][0]["text"].getStr().len == 400
    assert node["eval_report"]["ok"].getBool() == true
    assert node["eval_history"].len == 2
    assert node["eval_history"][0]["n"].getInt() == 2
    let tables = node["db"]["tables"]
    assert tables.len == 4
    assert tables[0]["name"].getStr() == "calendar_events"
    var cols: seq[string] = @[]
    for c in tables[1]["columns"]:
      cols.add(c.getStr())
    assert "subject" in cols
    assert tables[1]["count"].getInt() == 1
    assert tables[1]["sample"][0]["id"].kind == JInt
    assert node["db"]["all_tables"].len >= 4
    removeDir(root)

  test "the memory page follows WAKU_SEMANTIC_STORE=zep when a key exists":
    # The page builds its store per request through factsFor: with zep named
    # and keyed it must answer "zep", without the key it falls back to
    # sqlite rather than a half-wired graph.
    let root = freshDir("waku-dash-zepstore")
    let db = connectDb(root)
    let savedStore = getEnv("WAKU_SEMANTIC_STORE")
    let savedKey = existsEnv("ZEP_API_KEY")
    let savedValue = getEnv("ZEP_API_KEY")
    putEnv("WAKU_SEMANTIC_STORE", "zep")
    putEnv("ZEP_API_KEY", "zep-test-key")
    check factsFor(testDeps(root, root), db).name == "zep"
    delEnv("ZEP_API_KEY")
    check factsFor(testDeps(root, root), db).name == "sqlite"
    if savedStore.len > 0:
      putEnv("WAKU_SEMANTIC_STORE", savedStore)
    else:
      delEnv("WAKU_SEMANTIC_STORE")
    if savedKey:
      putEnv("ZEP_API_KEY", savedValue)
    db.close()
    removeDir(root)

  test "the memory page follows WAKU_SEMANTIC_STORE=postgres when keyed":
    # factsFor is backend-agnostic, and this pins that it stays that way:
    # postgres needs no per-request field (no user scoping), so the page
    # must answer "postgres" with both keys and sqlite without either.
    let root = freshDir("waku-dash-pgstore")
    let db = connectDb(root)
    let savedStore = getEnv("WAKU_SEMANTIC_STORE")
    let savedUrl = existsEnv("DATABASE_URL")
    let savedUrlValue = getEnv("DATABASE_URL")
    let savedKey = existsEnv("OPENAI_API_KEY")
    let savedKeyValue = getEnv("OPENAI_API_KEY")
    putEnv("WAKU_SEMANTIC_STORE", "postgres")
    putEnv("DATABASE_URL", "postgres://u:p@localhost:5432/waku")
    putEnv("OPENAI_API_KEY", "sk-test")
    check factsFor(testDeps(root, root), db).name == "postgres"
    delEnv("OPENAI_API_KEY")
    check factsFor(testDeps(root, root), db).name == "sqlite"
    if savedStore.len > 0:
      putEnv("WAKU_SEMANTIC_STORE", savedStore)
    else:
      delEnv("WAKU_SEMANTIC_STORE")
    if savedUrl:
      putEnv("DATABASE_URL", savedUrlValue)
    else:
      delEnv("DATABASE_URL")
    if savedKey:
      putEnv("OPENAI_API_KEY", savedKeyValue)
    db.close()
    removeDir(root)

  test "the memory page reads episodes through the selector":
    # sqlite ids render as strings now (opaque-id parity with facts); with a
    # vault configured the same page answers obsidian rows and says so.
    let root = freshDir("waku-dash-epstore")
    createDir(root / "static")
    let db = connectDb(root)
    db.exec(sql("INSERT INTO episodes (happened_at, summary) VALUES " &
      "('2026-09-01 10:00', 'a quiet week')"))
    let savedStore = getEnv("WAKU_EPISODIC_STORE")
    let savedVault = existsEnv("WAKU_OBSIDIAN_VAULT")
    let savedVaultValue = getEnv("WAKU_OBSIDIAN_VAULT")
    delEnv("WAKU_EPISODIC_STORE")
    delEnv("WAKU_OBSIDIAN_VAULT")
    var node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["episodes"].len == 1
    assert node["episodes"][0]["id"].kind == JString
    assert node["episodes"][0]["id"].getStr() == "1"
    assert node["episodes_source"].getStr() == "sqlite"
    putEnv("WAKU_EPISODIC_STORE", "obsidian")
    putEnv("WAKU_OBSIDIAN_VAULT", root / "vault")
    let store = episodesFor(testDeps(root, root / "static"), db).store
    store.add("seeded in the vault", "2026-10-06 10:00")
    node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["episodes"].len == 1
    assert node["episodes"][0]["summary"].getStr() == "seeded in the vault"
    assert node["episodes_source"].getStr() == "obsidian"
    if savedStore.len > 0:
      putEnv("WAKU_EPISODIC_STORE", savedStore)
    else:
      delEnv("WAKU_EPISODIC_STORE")
    if savedVault:
      putEnv("WAKU_OBSIDIAN_VAULT", savedVaultValue)
    else:
      delEnv("WAKU_OBSIDIAN_VAULT")
    db.close()
    removeDir(root)

  test "the memory page follows WAKU_SEMANTIC_STORE=langmem when keyed":
    # Memory mode builds a client that only this request would feed — the
    # pin proves dispatch, not persistence (there is none, by design).
    let root = freshDir("waku-dash-lmstore")
    let db = connectDb(root)
    let savedStore = getEnv("WAKU_SEMANTIC_STORE")
    let savedKey = existsEnv("OPENAI_API_KEY")
    let savedKeyValue = getEnv("OPENAI_API_KEY")
    let savedDsn = existsEnv("WAKU_LANGMEM_POSTGRES")
    let savedDsnValue = getEnv("WAKU_LANGMEM_POSTGRES")
    putEnv("WAKU_SEMANTIC_STORE", "langmem")
    putEnv("OPENAI_API_KEY", "sk-test")
    delEnv("WAKU_LANGMEM_POSTGRES")
    check factsFor(testDeps(root, root), db).name == "langmem"
    putEnv("WAKU_LANGMEM_POSTGRES", "postgres://u:p@localhost:5432/waku")
    check factsFor(testDeps(root, root), db).name == "langmem-pg"
    delEnv("OPENAI_API_KEY")
    check factsFor(testDeps(root, root), db).name == "sqlite"
    if savedStore.len > 0:
      putEnv("WAKU_SEMANTIC_STORE", savedStore)
    else:
      delEnv("WAKU_SEMANTIC_STORE")
    if savedKey:
      putEnv("OPENAI_API_KEY", savedKeyValue)
    if savedDsn:
      putEnv("WAKU_LANGMEM_POSTGRES", savedDsnValue)
    else:
      delEnv("WAKU_LANGMEM_POSTGRES")
    db.close()
    removeDir(root)

  test "sessions group chat rows and resume the fresh dashboard thread":
    let root = freshDir("waku-dash-datasessions")
    createDir(root / "static")
    let db = connectDb(root)
    # Fresh stamps (wall clock): the dashboard thread must resume.
    let now = format(getTime().utc, "yyyy-MM-dd HH:mm:ss")
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('user', 'hello', 'dashboard-keep', 'dashboard', '" &
      now & "')"))
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('assistant', 'hi', 'dashboard-keep', " &
      "'dashboard', '" & now & "')"))
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('user', 'other', 's-2', 'cli', " &
      "'2026-09-01 00:00:01')"))
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('assistant', 'yo', 's-2', 'cli', " &
      "'2026-09-01 00:00:02')"))
    db.close()
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["chat_log"].len == 4
    assert node["chat_log"][0]["role"].getStr() == "user"
    assert node["chat_pending"].getInt() == 4
    assert node["sessions"].len == 2
    assert node["sessions"][0]["id"].getStr() == "dashboard-keep"
    assert node["sessions"][0]["messages"].getInt() == 2
    var sources: seq[string] = @[]
    for s in node["sessions"][0]["sources"]:
      sources.add(s.getStr())
    assert "dashboard" in sources
    assert node["current_session"].getStr() == "dashboard-keep"
    removeDir(root)

  test "trace sections read wake scans, tail and file name":
    let root = freshDir("waku-dash-datatraces")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"wake_scan\", \"heard\": \"waku\", " &
      "\"ts\": \"2026-10-01T00:00:00+00:00\"}\n" &
      "{\"type\": \"turn_start\", \"user_message\": \"hi\", " &
      "\"ts\": \"2026-10-01T00:00:01+00:00\"}\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    assert node["wake_scans"].len == 1
    assert node["wake_scans"][0]["heard"].getStr() == "waku"
    assert node["trace_tail"].len == 2
    assert node["trace_tail"][0]["detail"].getStr() == "hi"
    assert node["trace_file"].getStr() == "2026-10-01.jsonl"
    removeDir(root)

  test "skills list home SKILL.md rows the tab edits":
    let root = freshDir("waku-dash-dataskills")
    createDir(root / "static")
    createDir(root / "skills" / "demo")
    writeFile(root / "skills" / "demo" / "SKILL.md",
      "---\nname: demo\ndescription: does things\n---\n\nDo it.\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    var sk = newJNull()
    for row in node["skills"]:
      if row["name"].getStr() == "demo":
        sk = row
    assert sk.kind == JObject
    assert sk["description"].getStr() == "does things"
    assert sk["body"].getStr() == "Do it."
    assert sk["editable"].getBool() == true
    assert sk["rel"].getStr() == "skills" / "demo" / "SKILL.md"
    removeDir(root)

  test "providers serve card rows without leaking secrets":
    let root = freshDir("waku-dash-dataproviders")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.providers = @[Provider(name: "anthropic", kind: "anthropic",
      keyEnv: "ANTHROPIC_API_KEY"),
      Provider(name: "openai", kind: "openai", keyEnv: "OPENAI_API_KEY")]
    d.env["ANTHROPIC_API_KEY"] = "sk-test-9999"
    let body = handleGet(d, "/api/data")[2]
    # The full key must never reach the browser; only the last four.
    assert "sk-test-9999" notin body
    let node = parseJson(body)
    assert node["providers"].len == 2
    let anthropic = node["providers"][0]
    assert anthropic["key"].getStr() == "anthropic"
    assert anthropic["group"].getStr() == "AI Providers"
    assert anthropic["name"].getStr().len > 0
    assert anthropic["fields"].len == 1
    assert anthropic["fields"][0]["configured"].getBool() == true
    assert anthropic["fields"][0]["last4"].getStr() == "9999"
    assert anthropic["fields"][0]["value"].getStr() == ""
    assert anthropic["status"]["state"].getStr() == "configured"
    assert anthropic.hasKey("install_command")
    assert anthropic.hasKey("setup_url")
    let openai = node["providers"][1]
    assert openai["fields"][0]["configured"].getBool() == false
    assert openai["status"]["state"].getStr() == "not_configured"
    removeDir(root)

  test "graph runs and stats read the trace events":
    let root = freshDir("waku-dash-datagraphruns")
    createDir(root / "static")
    createDir(root / "traces")
    writeFile(root / "traces" / "2026-10-01.jsonl",
      "{\"type\": \"route\", \"workflow\": \"triage\", " &
      "\"target\": \"quick_reply\", \"ts\": \"2026-10-01T00:00:01+00:00\"}\n" &
      "{\"type\": \"graph_end\", \"workflow\": \"triage\", \"ms\": 12, " &
      "\"steps\": 3, \"path\": [\"classify\", \"quick_reply\"], " &
      "\"error\": null, \"ts\": \"2026-10-01T00:00:02+00:00\"}\n" &
      "not json\n")
    let node = parseJson(handleGet(testDeps(root, root / "static"),
      "/api/data")[2])
    let g = node["graph"]
    assert g["stats"]["quick"].getInt() == 1
    assert g["stats"]["full"].getInt() == 0
    assert g["runs"].len == 1
    assert g["runs"][0]["workflow"].getStr() == "triage"
    assert g["runs"][0]["ms"].getInt() == 12
    assert g["runs"][0]["at"].getStr() == "2026-10-01T00:00:02+00:00"
    assert g["runs"][0]["steps"].getInt() == 3
    assert g["runs"][0]["path"].len == 2
    removeDir(root)

suite "phase 8a /api/data frontend contract":
  test "every payload key the SPA reads is served or a named gap":
    # `refresh()` sets `D = /api/data`, so each `D.<key>` (and the `d.<key>`
    # reads inside the views that receive it) is a key this endpoint owes
    # the page. A missing key degrades silently in the browser (a fallback
    # object, a forever-empty tab), never red in CI — this test fails
    # closed instead. `knownGaps` is the rest of Python's `collect()` blob,
    # owned by the still-unlanded 8x units; porting one means deleting its
    # line here, which the companion test below enforces.
    let jsDir = normalizedPath(currentSourcePath().parentDir / ".." / ".." /
      "waku" / "ops" / "static" / "js")
    if not dirExists(jsDir):
      skip()
    # No gaps left: every key the SPA reads is served. Keep the list
    # (empty) so the next frontend read outside the payload fails here
    # instead of degrading silently in the browser.
    const knownGaps: seq[string] = @[]
    # Files whose `d` is NOT the /api/data blob: each fetches an
    # endpoint of its own and hands THAT response to its views
    # (observe.js's `d` is /api/observability's payload, compare.js's
    # is the /api/compare/history list, models.js's is the /api/models
    # catalog, diagram.js's is the /api/events stream). Their
    # lowercase `d.<key>` reads belong to that endpoint's contract, not
    # this one; `D.` is still the blob everywhere. A new page with its
    # own payload is a decision, not a detail: name its file here.
    const ownPayload = ["compare.js", "diagram.js", "models.js",
                        "observe.js"]
    var read: seq[string] = @[]
    for kind, path in walkDir(jsDir):
      if kind != pcFile or not path.endsWith(".js"):
        continue
      var dataView = true
      for f in ownPayload:
        if path.endsWith(f):
          dataView = false
      for key in payloadKeys(readFile(path), lowercase = dataView):
        if key notin read:
          read.add(key)
    assert read.len > 0, "no D./d. reads found — the extractor is broken"
    let root = freshDir("waku-dash-contract")
    createDir(root / "static")
    let node = statusPayload(testDeps(root, root / "static"))
    var missing: seq[string] = @[]
    for key in read:
      if not node.hasKey(key) and key notin knownGaps:
        missing.add(key)
    removeDir(root)
    assert missing.len == 0,
      "frontend reads unserved /api/data keys: " & missing.join(", ") &
      " — serve them or name them in knownGaps"

  test "named gaps disappear as their units land":
    # Fail-closed the other way: a gap that IS served now must leave the
    # list, so the list can only shrink toward the empty contract.
    let root = freshDir("waku-dash-contractgaps")
    createDir(root / "static")
    let node = statusPayload(testDeps(root, root / "static"))
    removeDir(root)
    for gap in ["graph", "turns", "stats", "settings", "db",
        "sessions", "outbox", "facts", "eval_report", "episodes",
        "current_session", "chat_log", "calendar", "chat_pending",
        "consolidate_every", "episodes_error", "episodes_source",
        "eval_history", "skills", "soul", "tools", "trace_errors",
        "trace_file", "trace_tail", "wake_scans", "providers"]:
      assert node.hasKey(gap), gap & " is served — remove it from knownGaps"

suite "phase 8a route surface":
  test "every served GET route is Python's or a declared divergence":
    for r in readGetRoutes():
      assert r in pythonPinnedGet or r in portOnlyGetRoutes, r

  test "the port-only list never shadows a route Python pins":
    # A route here is a deliberate gap that the hosted route-contract eval
    # cannot see, so it must stay a gap: one the Python side already pins
    # belongs in the mirror, and the mirror must stay exactly Python's.
    for r in portOnlyGetRoutes:
      assert r notin pythonPinnedGet, r
    for r in pythonPinnedGet:
      assert r notin portOnlyGetRoutes, r
    assert portOnlyGetRoutes == @[],
      "a new port-only route is a decision, not a detail: name it here"

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

  test "the done frame carries the turn receipt, or null without one":
    # Like Python's `getattr(result, "receipt", None)`: a turn that went
    # through `respond` names its dollars, an older literal stays null.
    var res = LoopResult(reply: "hi", toolCalls: @[], iterations: 1)
    res.receipt = buildReceipt(
      @[("llm", %*{"usage": {"in": 10, "out": 2}})], "anthropic")
    let box = WakuBox(waku: Waku(settings: Settings(provider: "anthropic",
      model: "m", smallModel: "mini")))
    let done = donePayload(box, res, newJNull(), newJNull(), newJNull(),
      newJNull(), 5)
    assert done["reply"].getStr() == "hi"
    assert done["receipt"] == res.receipt
    assert done["receipt"]["model"]["in"].getInt() == 10
    assert done["model"].getStr() == "m"
    let bare = donePayload(box,
      LoopResult(reply: "hi", toolCalls: @[], iterations: 1),
      newJNull(), newJNull(), newJNull(), newJNull(), 5)
    assert bare["receipt"].kind == JNull

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
    # A fact id is opaque, so a non-numeric one is a MISS ("no such row"),
    # not a malformed request: answering "bad id" here is what makes a
    # hosted store unusable from this page. An EPISODE id is opaque too now
    # (sqlite's counter locally, a vault path on obsidian) — same rule.
    let bad = handlePost(d, "/api/memory",
      """{"action": "delete_fact", "id": "nope"}""")[2]
    assert parseJson(bad)["ok"].getBool() == false
    assert "error" notin parseJson(bad)
    let badEpisode = handlePost(d, "/api/memory",
      """{"action": "delete_episode", "id": "nope"}""")[2]
    assert parseJson(badEpisode)["ok"].getBool() == false
    assert "error" notin parseJson(badEpisode)
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

  test "view checked_at is null until a check stamps it, like Python":
    # Python's `asdict` renders an unchecked row's `checked_at=None` as
    # JSON null; `%*` on an empty string renders `""`, which the tab
    # tolerates (both are falsy) but is not the contract.
    let root = freshDir("waku-dash-connchecked")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.env["TAVILY_API_KEY"] = "x"
    var node = parseJson(handlePost(d, "/api/connections/test",
      """{"key": "tavily"}""")[2])
    assert node["status"]["checked_at"].kind == JNull
    writeFile(root / "connections_health.json",
      """{"tavily": {"state": "connected", "message": "ok", """ &
      """"checked_at": "2026-10-01T00:00:00Z"}}""")
    var d2 = testDeps(root, root / "static")
    d2.env["TAVILY_API_KEY"] = "x"
    node = parseJson(handlePost(d2, "/api/connections/test",
      """{"key": "tavily"}""")[2])
    assert node["status"]["checked_at"].getStr() == "2026-10-01T00:00:00Z"
    removeDir(root)

  test "a gateway row renders the status the seam reports":
    # The deps field 7d2-3 fills with the supervisor's provider: a save of
    # a gateway row must report the handle's standing, not a bare
    # "configured". Pinned here (the wiring itself lives in
    # `test_supervisor_hookup.nim`) so a handler change that stops reading
    # the seam fails in the handler's own suite.
    let root = freshDir("waku-dash-conngw")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.dotenvPath = root / ".env"
    d.env["TELEGRAM_BOT_TOKEN"] = "tok"
    var asked: seq[string] = @[]
    let status: GatewayStatusFn =
      proc(key: string): (bool, IntegrationStatus) =
        asked.add(key)
        (true, IntegrationStatus(state: error,
          message: "another instance is polling this token"))
    d.gatewayStatus = status
    let node = parseJson(handlePost(d, "/api/connections",
      """{"key": "telegram", "values": {"TELEGRAM_BOT_TOKEN": "tok"}}""")[2])
    assert node["ok"].getBool()
    assert asked == @["telegram"]
    assert node["view"]["status"]["state"].getStr() == "error"
    assert "another instance" in node["view"]["status"]["message"].getStr()
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
  test "every served POST route is Python's or a declared divergence":
    for r in readPostRoutes():
      assert r in pythonPinnedPost or r in portOnlyPostRoutes, r

  test "the port-only list never shadows a route Python pins":
    for r in portOnlyPostRoutes:
      assert r notin pythonPinnedPost, r
    for r in pythonPinnedPost:
      assert r notin portOnlyPostRoutes, r
    assert portOnlyPostRoutes == @[],
      "a new port-only route is a decision, not a detail: name it here"

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
      "/api/turn-evals/judge": """{"turn_id": "t_nope42"}""",
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

suite "phase 8a hosted front-door GETs":
  proc seedSessions(root: string) =
    let db = connectDb(root)
    let now = format(getTime().utc, "yyyy-MM-dd HH:mm:ss")
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('user', 'hello   world', 'dashboard-keep', " &
      "'dashboard', '" & now & "')"))
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('assistant', 'hi', 'dashboard-keep', " &
      "'dashboard', '" & now & "')"))
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source, " &
      "created_at) VALUES ('user', 'other', 's-2', 'cli', " &
      "'2026-09-01 00:00:01')"))
    db.close()

  test "session list reads the conversations and the current thread":
    let root = freshDir("waku-dash-getsession-list")
    seedSessions(root)
    let (status, ctype, body) = handleGet(testDeps(root, root),
      "/api/session?action=list")
    assert status == 200
    assert ctype == "application/json"
    let node = parseJson(body)
    assert node["ok"].getBool()
    assert node["conversations"].len == 2
    assert node["conversations"][0]["id"].getStr() == "dashboard-keep"
    assert node["conversations"][0]["title"].getStr() == "hello world"
    assert node["conversations"][0]["messages"].getInt() == 2
    assert node["current"].getStr() == "dashboard-keep"
    removeDir(root)

  test "session history and state read without touching the agent":
    let root = freshDir("waku-dash-getsession-state")
    seedSessions(root)
    let d = testDeps(root, root)
    let hist = parseJson(handleGet(d, "/api/session?action=history&id=s-2")[2])
    assert hist["ok"].getBool()
    assert hist["session_id"].getStr() == "s-2"
    assert hist["history"].len == 1
    let st = parseJson(handleGet(d, "/api/session?action=state")[2])
    assert st["ok"].getBool()
    assert st["sessions"].len == 2
    assert st["current_session"].getStr() == "dashboard-keep"
    for k in ["provider", "model", "small_model", "pinned",
        "disabled_providers"]:
      assert st["settings"].hasKey(k), k
    removeDir(root)

  test "session writes stay POST-only on GET":
    let root = freshDir("waku-dash-getsession-ro")
    let d = testDeps(root, root)
    for target in ["/api/session", "/api/session?action=delete",
        "/api/session?action=new"]:
      let (status, ctype, body) = handleGet(d, target)
      assert status == 200, target
      assert ctype == "application/json", target
      assert "reads only: action=list, history or state" in body, target
    removeDir(root)

  test "embed chat stamps origins and an allowlisted theme":
    let root = freshDir("waku-dash-embed")
    let web = root / "static"
    createDir(web)
    writeFile(web / "embed.html",
      "<html@@THEME@@><body data-embed-origins=\"@@EMBED_ORIGINS@@\">x")
    let d = testDeps(root, web)
    let (status, ctype, body) = handleGet(d, "/embed/chat")
    assert status == 200
    assert ctype == "text/html; charset=utf-8"
    assert "https://www.waku.one" in body
    assert "data-theme" notin body
    assert "@@" notin body
    let themed = handleGet(d, "/embed/chat?theme=dark")[2]
    assert "<html data-theme=\"dark\">" in themed
    let evil = handleGet(d, "/embed/chat?theme=evil")[2]
    assert "data-theme" notin evil
    removeDir(root)

  test "embed chat 404s without the page, like a missing index":
    let root = freshDir("waku-dash-embed404")
    let web = root / "static"
    createDir(web)
    let (status, _, _) = handleGet(testDeps(root, web), "/embed/chat")
    assert status == 404
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
      assert r in pythonPinnedGet or r in portOnlyGetRoutes, r
    for r in readPostRoutes():
      assert r in pythonPinnedPost or r in portOnlyPostRoutes, r

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
    d.raceFn = proc(message: string, specs: seq[string], coding: bool,
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
    d.raceFn = proc(message: string, specs: seq[string], coding: bool,
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


suite "the memory page goes through the fact store":
  test "an injected store is what the page lists, not the local db":
    # The point of T3b: the memory page and a turn must agree about where the
    # facts live. A page load against a home whose sqlite is EMPTY, with a
    # store that has rows, proves the route reads the store.
    let root = freshDir("waku-dash-storepage")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.facts = mem0FakeStore()
    d.facts.add("Priya", "prefers mornings", "user")
    let node = parseJson(handleGet(d, "/api/data")[2])
    assert node["facts"].len == 2, "the fake's own seeded row plus ours"
    var sawPriya = false
    for fact in node["facts"]:
      if fact["subject"].getStr() == "priya":
        sawPriya = true
        assert fact["id"].getStr().startsWith("mem-"),
          "a hosted id is a string, not a number"
    assert sawPriya, "the page did not read the store"
    removeDir(root)

  test "an opaque id survives the round trip through the page":
    # What memory.js does: render `fact-<id>`, post that id back. A UUID has
    # to make the whole trip, or a hosted store's facts can never be edited
    # by hand.
    let root = freshDir("waku-dash-storeid")
    createDir(root / "static")
    var d = testDeps(root, root / "static")
    d.facts = mem0FakeStore()
    let rows = d.facts.list(50)
    let hosted = rows[0].id
    let (_, _, body) = handlePost(d, "/api/memory",
      $(%*{"action": "update_fact", "id": hosted,
           "content": "seeded and edited"}))
    assert parseJson(body)["ok"].getBool(), "the page refused the id it rendered"
    assert d.facts.search("edited", 4).len == 1
    removeDir(root)

  test "sqlite is still the answer when nothing is injected":
    let root = freshDir("waku-dash-storedefault")
    createDir(root / "static")
    let d = testDeps(root, root / "static")
    let db = connectDb(root)
    db.exec(sql("INSERT INTO facts (subject, content, source) VALUES " &
      "('Alex', 'likes sailing', 'user')"))
    db.close()
    let node = parseJson(handleGet(d, "/api/data")[2])
    assert node["facts"].len == 1
    assert node["facts"][0]["subject"].getStr() == "Alex"
    removeDir(root)

suite "phase 12 observability route":
  proc obsDeps(root, web: string, nowMs: int64): DashboardDeps =
    ## The route's deps with a frozen clock and a pinned stamp, so a
    ## crafted trace lands in a named window.
    result = testDeps(root, web)
    result.nowMs = nowMs
    result.nowIso = "2026-10-05T12:00:00+00:00"
    result.provider = "openrouter"
    result.model = "m"

  test "serves the payload, newest turn first, with an unknown window at 7d":
    let root = freshDir("waku-dash-obs")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    createDir(root / "traces")
    # One file per day, as the tracer writes them: file order IS time
    # order, which is what makes "newest first" a reversal.
    writeFile(root / "traces" / "2020-01-01.jsonl", [
      $(%*{"type": "turn_start", "turn_id": "t_0",
           "ts": "2020-01-01T10:00:00.000+00:00", "user_message": "old"}),
      $(%*{"type": "turn_end", "turn_id": "t_0",
           "ts": "2020-01-01T10:00:01.000+00:00", "reply": "old",
           "iterations": 1})].join("\n") & "\n")
    writeFile(root / "traces" / "2026-10-05.jsonl", [
      $(%*{"type": "turn_start", "turn_id": "t_1",
           "ts": "2026-10-05T10:00:00.000+00:00", "user_message": "hi"}),
      $(%*{"type": "llm", "turn_id": "t_1",
           "ts": "2026-10-05T10:00:01.000+00:00",
           "usage": {"in": 10, "out": 2}, "stop_reason": "end_turn"}),
      $(%*{"type": "turn_end", "turn_id": "t_1",
           "ts": "2026-10-05T10:00:02.000+00:00", "reply": "yo",
           "iterations": 1})].join("\n") & "\n")
    # A frozen clock AFTER both turns (2026-10-06T12:00Z): the 7d window
    # still holds t_1 and drops the 2020 one, which is the filter being
    # pinned rather than the turn's own date.
    let nowMs = 1791288000000'i64
    let d = obsDeps(root, web, nowMs)
    let (status, ctype, body) = handleGet(d, "/api/observability")
    assert status == 200 and ctype == "application/json"
    let node = parseJson(body)
    assert node["generated_at"].getStr() == "2026-10-05T12:00:00+00:00"
    assert node["summary"]["window"].getStr() == "7d"
    # `turns` is every turn, newest first, capped — the window shows up in
    # `summary` (upstream's `payload` filters the cards, never the list).
    assert node["turns"].len == 2
    assert node["turns"][0]["turn_id"].getStr() == "t_1"
    assert node["turns"][1]["turn_id"].getStr() == "t_0"
    assert node["summary"]["turns"]["count"].getInt() == 1,
      "the 2020 turn is outside the frozen 7d"
    let (status2, _, body2) =
      handleGet(d, "/api/observability?window=garbage")
    assert status2 == 200
    assert parseJson(body2)["summary"]["window"].getStr() == "7d",
      "an unknown window falls back to 7d, like Python"
    let (status3, _, body3) = handleGet(d, "/api/observability?window=all")
    assert status3 == 200
    let all = parseJson(body3)
    assert all["summary"]["window"].getStr() == "all"
    assert all["turns"].len == 2
    assert all["summary"]["turns"]["count"].getInt() == 2,
      "all counts both turns"
    assert all["turns"][0]["judge_offer"].kind == JNull
    assert all["trace_files"].getInt() == 2
    removeDir(root)

  test "an empty home still answers the whole shape":
    let root = freshDir("waku-dash-obs-empty")
    let web = root / "static"
    createDir(web)
    writeFile(web / "index.html", "<html></html>")
    let (status, _, body) =
      handleGet(obsDeps(root, web, 1760000000000'i64), "/api/observability")
    assert status == 200
    let node = parseJson(body)
    for key in ["generated_at", "summary", "spend_by_day", "trace_files",
        "trace_file", "trace_errors", "turns", "tools", "memory", "spend",
        "evals"]:
      assert node.hasKey(key), key
    assert node["turns"].len == 0
    assert node["evals"]["your_turns"]["7d"]["turns"].getInt() == 0
    removeDir(root)

suite "phase 15 turn-evals judge route":
  proc judgeHome(name: string, turnId = "t_f00d42"): string =
    ## One temp home with a judged-ready turn. `turnId` is a parameter
    ## because the 60-second throttle is per turn id and per process: two
    ## pins in one run must not share one.
    result = getTempDir() / name
    if dirExists(result):
      removeDir(result)
    createDir(result / "traces")
    createDir(result / "static")
    writeFile(result / "static" / "index.html", "<html></html>")
    writeFile(result / "traces" / "2026-10-05.jsonl", [
      $(%*{"type": "turn_start", "turn_id": turnId,
           "ts": "2026-10-05T10:00:00.000+00:00", "user_message": "hi"}),
      $(%*{"type": "turn_end", "turn_id": turnId,
           "ts": "2026-10-05T10:00:02.000+00:00", "reply": "yo",
           "iterations": 1})].join("\n") & "\n")

  proc judgeDeps(root: string): DashboardDeps =
    result = testDeps(root, root / "static")
    result.smallModel = "m"
    result.nowIso = "2026-10-06T12:00:00+00:00"

  test "unwired the button answers an honest error, never a 500":
    let root = judgeHome("waku-dash-judge-nil")
    var d = judgeDeps(root)
    let (status, ctype, body) = handlePost(d, "/api/turn-evals/judge",
      """{"turn_id": "t_f00d42"}""")
    assert status == 200 and ctype == "application/json"
    assert "no judge backend" in parseJson(body)["error"].getStr()
    removeDir(root)

  test "wired it judges once, then refuses the repeat":
    let root = judgeHome("waku-dash-judge-once")
    var d = judgeDeps(root)
    d.turnJudgeFn = proc(prompt, model: string): JsonNode {.closure.} =
      %*{"text": "{\"addresses_question\": 8, \"grounded\": 7, " &
        "\"reason\": \"answers\"}", "in": 50, "out": 5}
    let (status, _, body) = handlePost(d, "/api/turn-evals/judge",
      """{"turn_id": "t_f00d42"}""")
    assert status == 200
    let node = parseJson(body)
    assert node["score"]["turn_id"].getStr() == "t_f00d42"
    assert node["score"]["value"].getFloat() == 0.7
    let (status2, _, body2) = handlePost(d, "/api/turn-evals/judge",
      """{"turn_id": "t_f00d42"}""")
    assert status2 == 200
    assert "less than a minute" in parseJson(body2)["error"].getStr()
    let (status3, _, body3) = handlePost(d, "/api/turn-evals/judge",
      """{"turn_id": "t_nope"}""")
    assert status3 == 200
    assert "No turn with that id" in parseJson(body3)["error"].getStr()
    removeDir(root)

  test "the payload offers the small model, or null without one":
    let root = judgeHome("waku-dash-judge-offer")
    var d = judgeDeps(root)
    d.nowMs = 1791288000000'i64
    let (_, _, body) = handleGet(d, "/api/observability")
    let offer = parseJson(body)["turns"][0]["judge_offer"]
    assert offer["model"].getStr() == "m"
    assert offer["usd"].kind == JFloat
    d.smallModel = ""
    let (_, _, body2) = handleGet(d, "/api/observability")
    assert parseJson(body2)["turns"][0]["judge_offer"].kind == JNull
    removeDir(root)

  test "the route judges with the small model, or the home's model without one":
    var seen: seq[string] = @[]
    let record = proc(prompt, model: string): JsonNode {.closure.} =
      seen.add(model)
      %*{"text": "{\"addresses_question\": 8, \"grounded\": 8, " &
        "\"reason\": \"ok\"}", "in": 1, "out": 1}
    # `small_model or model`, like Python's `judge_client`.
    let small = judgeHome("waku-dash-judge-model-small", "t_add999")
    var withSmall = judgeDeps(small)
    withSmall.turnJudgeFn = record
    discard handlePost(withSmall, "/api/turn-evals/judge",
      """{"turn_id": "t_add999"}""")
    let bare = judgeHome("waku-dash-judge-model-bare", "t_beef01")
    var withoutSmall = judgeDeps(bare)
    withoutSmall.smallModel = ""
    withoutSmall.turnJudgeFn = record
    discard handlePost(withoutSmall, "/api/turn-evals/judge",
      """{"turn_id": "t_beef01"}""")
    assert seen == @["m", "test-model"], $seen
    removeDir(small)
    removeDir(bare)

  test "an unwrapped binary has no eval counts to read":
    assert checkoutRoot("") == "" or dirExists(checkoutRoot("") / "evals")
    assert checkoutRoot("/nonexistent-xyz/waku/ops/static") == ""
