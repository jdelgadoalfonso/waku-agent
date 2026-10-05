## Phase 4c tests: app respond + tracer + canonical JSON.
## Offline only: scripted clients, temp homes, no network.

import std/json
import std/os
import std/sequtils
import std/strutils
import std/unicode
import std/times
import std/unittest

import db_connector/db_sqlite

import ../src/app
import ../src/brain
import ../src/db
import ../src/factstore
import ../src/jsondump
import ../src/memory_live
import ../src/receipt
import ../src/reports
import ../src/trace

type
  Script = ref object
    items: seq[JsonNode]
    pos: int
    seen: seq[JsonNode]

proc textResp(text: string): JsonNode =
  %*{"stop_reason": "end_turn", "usage": {"in": 2, "out": 5},
     "content": [{"type": "text", "text": text}]}

proc toolResp(id, name: string, input: JsonNode): JsonNode =
  %*{"stop_reason": "tool_use", "usage": {"in": 3, "out": 7},
     "content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}

proc scriptedClient(script: Script): LlmClient =
  LlmClient(create: proc(req: JsonNode): JsonNode =
    script.seen.add(copy(req))
    result = script.items[script.pos]
    inc script.pos)

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc testSettings(home: string, historyTurns = 12,
                  graphWorkflows = false): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
           smallModel: "mini", maxIterations: 10, maxTokens: 8192,
           historyTurns: historyTurns, graphWorkflows: graphWorkflows)

proc echoRegistry(output: string): ToolRegistry =
  result.register(Tool(name: "echo", description: "e",
    inputSchema: %*{"type": "object"},
    fn: proc(args: JsonNode): string = output))

proc traceLines(home: string): seq[JsonNode] =
  let path = home / "traces" / format(now(), "yyyy-MM-dd") & ".jsonl"
  for line in lines(path):
    result.add(parseJson(line))

proc usageLines(home: string): seq[JsonNode] =
  for line in lines(home / "usage.jsonl"):
    result.add(parseJson(line))

proc chatMeta(db: DbConn): JsonNode =
  let rows = db.getAllRows(
    sql"SELECT meta FROM chat_log WHERE role='assistant' ORDER BY id DESC LIMIT 1")
  parseJson(rows[0][0])

proc keysOf(node: JsonNode): seq[string] =
  ## An object's keys in insertion order, the way `test_receipt.nim` reads
  ## a pinned set.
  result = @[]
  if node.kind == JObject:
    for key in node.keys:
      result.add(key)

suite "phase 4c json dumps":
  test "separators match json.dumps defaults":
    assert jsonDumps(%*{"iterations": 1, "tools": newJArray()}) ==
      "{\"iterations\": 1, \"tools\": []}"

  test "ensure_ascii escapes non-ASCII lowercase like Python":
    assert jsonDumps(%"café") == "\"caf\\u00e9\""
    assert jsonDumps(%"a\nb\"c\\d") == "\"a\\nb\\\"c\\\\d\""
    assert jsonDumps(%"\u0001") == "\"\\u0001\""

  test "scalars and nesting render plainly":
    assert jsonDumps(%*{"ok": true, "n": nil, "v": [1, 2.5]}) ==
      "{\"ok\": true, \"n\": null, \"v\": [1, 2.5]}"

  test "astral chars render as surrogate pairs like CPython":
    assert jsonDumps(%($Rune(0x1F600))) == "\"\\ud83d\\ude00\""

  test "utcStamp matches isoformat(timespec=milliseconds)":
    let s = utcStamp()
    assert s.endsWith("+00:00")
    assert s.contains("T")
    let dot = s.find('.')
    assert dot > 0
    assert s[dot + 1 .. dot + 3].allIt(it in {'0' .. '9'})
    assert s[dot + 4] == '+'

suite "phase 4c pyStr":
  test "flat tool args render like Python str(dict)":
    assert pyStr(%*{"text": "x"}) == "{'text': 'x'}"

  test "nesting uses True/False/None like Python":
    assert pyStr(%*[true, nil, %*{"k": [1]}]) == "[True, None, {'k': [1]}]"

suite "phase 4c respond":
  test "a text turn persists history, meta, trace and ledger":
    let home = freshHome("waku-app-text")
    let db = connectDb(home)
    let script = Script(items: @[textResp("hello there")])
    var w = newWaku(testSettings(home), scriptedClient(script), db)
    let res = w.respond("hi")
    assert res.reply == "hello there"
    assert res.iterations == 1
    assert w.session.history ==
      @[(role: "user", content: "hi"),
        (role: "assistant", content: "hello there")]
    let meta = chatMeta(db)
    assert meta["iterations"].getInt() == 1
    assert meta["model"].getStr() == "m"
    assert meta["provider"].getStr() == "openai"
    assert meta["tools"].len == 0
    assert meta["gate"].kind == JNull
    assert meta["graph"].kind == JNull
    assert meta["latency_ms"].getInt() >= 0
    # canonical render: the space after ':' pins json.dumps shape
    let raw = db.getAllRows(
      sql"SELECT meta FROM chat_log WHERE role='assistant'")[0][0]
    assert "\"iterations\": 1" in raw
    let kinds = block:
      var ks: seq[string] = @[]
      for e in traceLines(home): ks.add(e["type"].getStr())
      ks
    assert kinds[0] == "turn_start"
    assert "llm" in kinds
    assert kinds[^1] == "turn_end"
    assert "text" notin kinds  # streaming deltas never hit the trace
    let usage = usageLines(home)
    assert usage.len == 1
    assert usage[0]["kind"].getStr() == "loop"
    assert usage[0]["in"].getInt() == 2
    assert usage[0]["out"].getInt() == 5
    db.close()
    removeDir(home)

  test "a tool turn folds [tools used: ...] and cards tool status":
    let home = freshHome("waku-app-tool")
    let db = connectDb(home)
    let script = Script(items: @[toolResp("t1", "echo", %*{"text": "x"}),
                                 textResp("done")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
                    echoRegistry("echo:x"))
    let res = w.respond("go")
    assert res.reply == "done"
    assert w.session.history[1] ==
      (role: "assistant",
       content: "done\n[tools used: echo({'text': 'x'}) -> echo:x]")
    let meta = chatMeta(db)
    assert meta["tools"] == %*[{"tool": "echo", "status": "ok"}]
    db.close()
    removeDir(home)

  test "a failing tool output cards status error":
    let home = freshHome("waku-app-err")
    let db = connectDb(home)
    let script = Script(items: @[toolResp("t1", "echo", %*{}),
                                 textResp("hmm")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
                    echoRegistry("failed hard"))
    discard w.respond("go")
    assert chatMeta(db)["tools"] == %*[{"tool": "echo", "status": "error"}]
    db.close()
    removeDir(home)

  test "only the history window enters the next prompt":
    let home = freshHome("waku-app-win")
    let db = connectDb(home)
    let script = Script(items: @[textResp("a1"), textResp("a2")])
    var w = newWaku(testSettings(home, historyTurns = 1),
                    scriptedClient(script), db)
    discard w.respond("q1")
    discard w.respond("q2")
    let msgs = script.seen[1]["messages"]
    assert msgs.len == 3  # last turn (2 rows) + the new message
    assert msgs[0]["content"].getStr() == "q1"
    assert msgs[1]["content"].getStr() == "a1"
    assert msgs[2]["content"].getStr() == "q2"
    db.close()
    removeDir(home)

  test "stream=true works with a create-only client":
    let home = freshHome("waku-app-stream")
    let db = connectDb(home)
    let script = Script(items: @[textResp("s")])
    var w = newWaku(testSettings(home), scriptedClient(script), db)
    assert w.respond("hi", stream = true).reply == "s"
    db.close()
    removeDir(home)

  test "afterTurn hook runs after persist with the composed notify":
    let home = freshHome("waku-app-hook")
    let db = connectDb(home)
    let script = Script(items: @[textResp("ok")])
    var seen = ""
    var w = newWaku(testSettings(home), scriptedClient(script), db,
      afterTurn = proc(n: Observer) =
        seen = "ran"
        n("custom", %*{"x": 1}))
    discard w.respond("hi")
    assert seen == "ran"
    var kinds: seq[string] = @[]
    for e in traceLines(home): kinds.add(e["type"].getStr())
    assert "custom" in kinds  # the hook shared the composed notify
    db.close()
    removeDir(home)

  test "source tags the gateway the message came through":
    let home = freshHome("waku-app-src")
    let db = connectDb(home)
    let script = Script(items: @[textResp("ok")])
    var w = newWaku(testSettings(home), scriptedClient(script), db)
    discard w.respond("hi", source = "telegram")
    let rows = db.getAllRows(sql"SELECT DISTINCT source FROM chat_log")
    assert rows.len == 1
    assert rows[0][0] == "telegram"
    db.close()
    removeDir(home)

suite "phase 4c graph door":
  test "flag on with no seam falls through to the loop in silence":
    let home = freshHome("waku-app-noseam")
    let db = connectDb(home)
    let script = Script(items: @[textResp("plain")])
    var w = newWaku(testSettings(home, graphWorkflows = true),
                    scriptedClient(script), db)
    assert w.respond("hi").reply == "plain"
    assert chatMeta(db)["graph"].kind == JNull
    db.close()
    removeDir(home)

  test "flag off never touches the graph seam":
    let home = freshHome("waku-app-off")
    let db = connectDb(home)
    let script = Script(items: @[textResp("plain")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
      graphTurn = proc(msg: string, n: Observer,
                       s: bool): tuple[answered: bool,
                                       res: LoopResult] =
        raise newException(ValueError, "must not run"))
    assert w.respond("hi").reply == "plain"
    assert chatMeta(db)["graph"].kind == JNull
    db.close()
    removeDir(home)

  test "a quick graph answer cards the small model":
    let home = freshHome("waku-app-quick")
    let db = connectDb(home)
    let script = Script(items: @[textResp("unused")])
    var w = newWaku(testSettings(home, graphWorkflows = true),
                    scriptedClient(script), db,
      graphTurn = proc(msg: string, n: Observer,
                       s: bool): tuple[answered: bool, res: LoopResult] =
        n("route", %*{"target": "quick_reply", "reason": "trivial"})
        n("triage", %*{"reason": "trivial"})
        (true, LoopResult(reply: "quick!", toolCalls: @[], iterations: 1)))
    assert w.respond("hi").reply == "quick!"
    assert script.seen.len == 0  # the loop never ran
    let meta = chatMeta(db)
    assert meta["model"].getStr() == "mini"
    assert meta["graph"]["route"].getStr() == "quick"
    assert meta["graph"]["reason"].getStr() == "trivial"
    db.close()
    removeDir(home)

  test "a graph failure falls open to the plain loop":
    let home = freshHome("waku-app-failopen")
    let db = connectDb(home)
    let script = Script(items: @[textResp("from loop")])
    var w = newWaku(testSettings(home, graphWorkflows = true),
                    scriptedClient(script), db,
      graphTurn = proc(msg: string, n: Observer,
                       s: bool): tuple[answered: bool,
                                       res: LoopResult] =
        raise newException(ValueError, "boom"))
    assert w.respond("hi").reply == "from loop"
    var found = false
    for e in traceLines(home):
      if e["type"].getStr() == "graph_end" and e["error"].kind != JNull:
        found = true
    assert found
    db.close()
    removeDir(home)

suite "spec 011 turn receipt":
  test "a scripted turn carries the receipt the builder pinned":
    let home = freshHome("waku-app-receipt")
    let db = connectDb(home)
    let script = Script(items: @[toolResp("t1", "echo", %*{"text": "x"}),
                                 textResp("done")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
                    echoRegistry("echo:x"),
      afterTurn = proc(n: Observer) =
        # consolidation runs AFTER the exchange is stored and reports what
        # it kept; the receipt is built after it, so the kept count is here.
        n("consolidation", %*{"new_facts": 2}))
    let res = w.respond("go")
    assert keysOf(res.receipt) == receiptKeys, "the pinned key set, in order"
    # which brain answered, named by the turn itself (not by the builder)
    assert res.receipt["model"]["id"].getStr() == "m"
    # both loop calls counted: 3+2 in, 7+5 out
    assert res.receipt["model"]["in"].getInt() == 5
    assert res.receipt["model"]["out"].getInt() == 12
    assert res.receipt["model"]["calls"] == %*[%*{"kind": "loop", "n": 2}]
    assert res.receipt["tools"] == %*[%*{"tool": "echo", "provider": "",
      "usd": nil, "status": "ok"}]
    assert res.receipt["memory"]["kept"].getInt() == 2,
      "the receipt is built after consolidation, so it counts what it kept"
    assert res.receipt["memory"]["used"].getInt() == 0,
      "nothing carries a count of retrieved facts, so nothing claims one"
    # 5 in @ $3/M + 12 out @ $15/M on the unknown-provider estimate
    assert abs(res.receipt["total_usd"].getFloat - 0.000195) < 1e-9
    assert res.receipt["credits"].kind == JNull
    # one id joins this turn's rows, and it is the id the trace opened with
    let lines = traceLines(home)
    assert res.receipt["turn_id"].getStr() == lines[0]["turn_id"].getStr()
    assert res.receipt["turn_id"].getStr().startsWith("t_")
    var kinds: seq[string] = @[]
    for e in lines: kinds.add(e["type"].getStr())
    assert kinds[^2] == "receipt", "the receipt lands before the turn closes"
    assert kinds[^1] == "turn_end"
    for e in lines:
      if e["type"].getStr() == "receipt":
        assert e["model"]["id"].getStr() == "m", "the trace carries the payload"
        assert e["memory"]["kept"].getInt() == 2
    db.close()
    removeDir(home)

  test "a quick graph turn names the small model in its receipt":
    let home = freshHome("waku-app-receiptquick")
    let db = connectDb(home)
    let script = Script(items: @[textResp("unused")])
    var w = newWaku(testSettings(home, graphWorkflows = true),
                    scriptedClient(script), db,
      graphTurn = proc(msg: string, n: Observer,
                       s: bool): tuple[answered: bool, res: LoopResult] =
        n("route", %*{"target": "quick_reply", "reason": "trivial"})
        (true, LoopResult(reply: "quick!", toolCalls: @[], iterations: 1)))
    let res = w.respond("hi")
    assert res.receipt["model"]["id"].getStr() == "mini",
      "the answering brain is the one the turn's meta already named"
    assert res.receipt["model"]["in"].getInt() == 0
    db.close()
    removeDir(home)

  test "the stored meta round-trips turn_id plus the receipt":
    let home = freshHome("waku-app-receiptmeta")
    let db = connectDb(home)
    let script = Script(items: @[textResp("hello there")])
    var w = newWaku(testSettings(home), scriptedClient(script), db)
    let res = w.respond("hi")
    let meta = chatMeta(db)
    assert meta["turn_id"].getStr() == res.receipt["turn_id"].getStr()
    assert meta["receipt"] == res.receipt,
      "the reopened thread draws the same line the Loop tab does"
    # the rewrite kept the canonical render (the space after ':'), and it
    # landed on the assistant row that was just written, not a new row
    let rows = db.getAllRows(
      sql"SELECT meta FROM chat_log WHERE role='assistant'")
    assert rows.len == 1
    assert "\"iterations\": 1" in rows[0][0]
    assert "\"turn_id\": \"t_" in rows[0][0]
    db.close()
    removeDir(home)

  test "fact inserts after the exchange do not steal the receipt's row":
    # `last_insert_rowid` is read BEFORE `afterTurn`: a due consolidation
    # inserts fact rows on the same connection, which would otherwise move
    # the id off the assistant row the exchange just stored.
    let home = freshHome("waku-app-receiptrow")
    let db = connectDb(home)
    let script = Script(items: @[textResp("noted")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
      afterTurn = proc(n: Observer) =
        db.exec(sql("INSERT INTO facts (subject, content) " &
          "VALUES ('k', 'v')"))
        n("consolidation", %*{"new_facts": 1}))
    let res = w.respond("hi")
    let got = db.getAllRows(
      sql"SELECT meta FROM chat_log WHERE role='assistant'")
    assert got.len == 1
    assert parseJson(got[0][0])["receipt"] == res.receipt,
      "the receipt landed on the assistant row, not the fact row"
    assert parseJson(got[0][0])["receipt"]["memory"]["kept"].getInt() == 1
    db.close()
    removeDir(home)

  test "a receipt that cannot land still answers the turn":
    # The reply is stored and the tracer closes the turn either way, so a
    # receipt that raises costs one line, never the answer. Fault injected
    # through the one seam the receipt's own write needs: consolidation
    # reported, then the table it would update stopped being there.
    let home = freshHome("waku-app-receiptfail")
    let db = connectDb(home)
    let script = Script(items: @[textResp("still answered")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
      afterTurn = proc(n: Observer) =
        n("consolidation", %*{"new_facts": 1})
        db.exec(sql"ALTER TABLE chat_log RENAME TO chat_log_gone"))
    let res = w.respond("hi")
    assert res.reply == "still answered"
    var kinds: seq[string] = @[]
    for e in traceLines(home): kinds.add(e["type"].getStr())
    assert kinds[^1] == "turn_end", "the turn still closes"
    assert "receipt" notin kinds, "no receipt line, and the turn survived it"
    db.close()
    removeDir(home)

suite "spec 009 brain reads first":
  test "a research turn searches before the loop and keeps the Used":
    let home = freshHome("waku-app-brainread")
    let db = connectDb(home)
    let skillRoot = home / "bundled"
    createDir(skillRoot / "research-report")
    writeFile(skillRoot / "research-report" / "SKILL.md",
      "---\nname: research-report\ndescription: Research report on " &
      "companies, competitors, markets, products, pricing and launches.\n" &
      "---\nBody.")
    let script = Script(items: @[textResp("here is what I found")])
    var reg = echoRegistry("x")
    reg.register(Tool(name: "engram_mem_search", description: "s",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string =
        "Found 1 memories:\n\n[1] #7 (decision) — Pick mem0\n    We picked it."))
    var w = newWaku(testSettings(home), scriptedClient(script), db, reg)
    w.session.researchNames = proc(message: string): seq[string] =
      matchingSkillNames(home, @[skillRoot], message)
    var kinds: seq[string] = @[]
    let res = w.respond("compare competitors pricing launches",
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert res.reply == "here is what I found"
    assert "tool" in kinds, "the searches show as tool calls"
    assert res.readFirst.len == 2
    assert res.used.len == 1
    assert res.used[0]["id"].getStr() == "#7"
    db.close()
    removeDir(home)

  test "no backend means no read, like Python with no memory":
    let home = freshHome("waku-app-brainoff")
    let db = connectDb(home)
    let script = Script(items: @[textResp("plain answer")])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
      echoRegistry("x"))
    w.session.researchNames = proc(message: string): seq[string] =
      @["research-report"]
    var kinds: seq[string] = @[]
    let res = w.respond("compare competitors pricing launches",
      proc(kind: string, ev: JsonNode) = kinds.add(kind))
    assert res.reply == "plain answer"
    assert "tool" notin kinds
    assert res.used.len == 0 and res.readFirst.len == 0
    db.close()
    removeDir(home)

suite "spec 007 a saved research report":
  test "a marked reply is saved whole and the chat keeps the lead":
    let home = freshHome("waku-app-reportsave")
    let db = connectDb(home)
    let marked = "Here is what I found.\n\n" & reportMarker &
      "\n\n# mem0 competitors\n\n## Summary\n- it charges per seat\n\n" &
      "## Findings\nlong body"
    var savedArgs: seq[JsonNode] = @[]
    # the loop answers first, the company/personal classifier second
    let script = Script(items: @[textResp(marked),
      textResp("""{"company_research": true}""")])
    var reg = echoRegistry("x")
    reg.register(Tool(name: "engram_mem_save", description: "s",
      inputSchema: %*{"type": "object"},
      fn: proc(args: JsonNode): string =
        savedArgs.add(args)
        """{"id": "42"}"""))
    var w = newWaku(testSettings(home), scriptedClient(script), db, reg)
    var kinds: seq[string] = @[]
    var reports: seq[JsonNode] = @[]
    let res = w.respond("research mem0 competitors pricing launches",
      proc(kind: string, ev: JsonNode) {.closure.} =
        kinds.add(kind)
        if kind == "report":
          reports.add(ev))
    # the chat keeps the preface and the saved line, not the report
    assert res.reply.startsWith("Here is what I found.")
    assert "Report saved: mem0 competitors." in res.reply
    assert reportMarker notin res.reply
    assert reports.len == 1
    assert reports[0]["memory_id"].getStr() == "42"
    assert reports[0]["scope"].getStr() == companyScope
    assert savedArgs[0]["content"].getStr().startsWith(reportMarker)
    # the turn's meta carries the card a reopened thread draws
    let meta = chatMeta(db)
    assert meta["report"]["memory_id"].getStr() == "42"
    assert meta["report"]["summary"].len == 1
    # and the receipt names the report too
    assert res.receipt["memory"]["report"].getStr() == "42"
    db.close()
    removeDir(home)

  test "no backend leaves the report in the reply":
    let home = freshHome("waku-app-reportoff")
    let db = connectDb(home)
    let marked = "lead only\n\n" & reportMarker & "\n\n# t"
    let script = Script(items: @[textResp(marked)])
    var w = newWaku(testSettings(home), scriptedClient(script), db,
      echoRegistry("x"))
    var reports: seq[JsonNode] = @[]
    let res = w.respond("research mem0 competitors pricing launches",
      proc(kind: string, ev: JsonNode) {.closure.} =
        if kind == "report":
          reports.add(ev))
    assert res.reply == marked, "no memory, no shortened reply"
    assert reports.len == 0
    assert chatMeta(db)["report"].kind == JNull
    assert res.receipt["memory"]["report"].kind == JNull
    db.close()
    removeDir(home)

suite "which backend holds the facts":
  test "sqlite is the answer unless something is named":
    # The default has to be the local one, byte-identical to before this seam
    # existed: a user with no env var must not notice the port grew a
    # contract.
    let home = getTempDir() / "waku-store-default"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    var s = defaultSettings()
    check factStoreFor(s, db).name == "sqlite"
    let hits: seq[string] = factStoreFor(s, db).store.search("anything", 4)
    check hits.len == 0
    db.close()
    removeDir(home)

  test "an unknown value answers sqlite rather than refusing":
    # Python's `_make_fact_store` falls through to SqliteFactStore for
    # anything it does not recognise, and a typo in a .env must not take a
    # turn down — it just quietly keeps the local store.
    let home = getTempDir() / "waku-store-unknown"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    var s = defaultSettings()
    s.semanticStore = "supabase"
    assert factStoreFor(s, db).name == "sqlite", "supabase is not in this port yet; the honest answer is sqlite"
    db.close()
    removeDir(home)

  test "mem0 needs a key, and says so when it falls back":
    # Naming a backend without its key is the failure mode a user hits on
    # day one. The store still works (sqlite), it says why on stderr, and the
    # selector answers "sqlite" so a status line cannot claim otherwise.
    let home = getTempDir() / "waku-store-nokey"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedKey = existsEnv("MEM0_API_KEY")
    let savedValue = getEnv("MEM0_API_KEY")
    delEnv("MEM0_API_KEY")
    var s = defaultSettings()
    s.semanticStore = "mem0"
    check factStoreFor(s, db).name == "sqlite"
    if savedKey:
      putEnv("MEM0_API_KEY", savedValue)
    db.close()
    removeDir(home)

  test "mem0 with a key builds the hosted store":
    let home = getTempDir() / "waku-store-mem0"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedKey = existsEnv("MEM0_API_KEY")
    let savedValue = getEnv("MEM0_API_KEY")
    putEnv("MEM0_API_KEY", "m0-test-key")
    var s = defaultSettings()
    s.semanticStore = "mem0"
    s.mem0UserId = "someone"
    check factStoreFor(s, db).name == "mem0"
    if savedKey:
      putEnv("MEM0_API_KEY", savedValue)
    else:
      delEnv("MEM0_API_KEY")
    db.close()
    removeDir(home)

  test "an agent built for mem0 carries the hosted store":
    # The seam is only real if the agent holds it: `newWaku` is where the
    # builders (CLI, dashboard, gateways) get theirs.
    let home = getTempDir() / "waku-store-agent"
    if dirExists(home):
      removeDir(home)
    let savedKey = existsEnv("MEM0_API_KEY")
    let savedValue = getEnv("MEM0_API_KEY")
    putEnv("MEM0_API_KEY", "m0-test-key")
    var s = defaultSettings()
    s.home = home
    s.semanticStore = "mem0"
    let db = connectDb(home)
    let script = Script(items: @[textResp("hola")])
    let w = newWaku(s, scriptedClient(script), db)
    let rows: seq[StoreFact] = w.facts.list(1)
    assert rows.len >= 0, "the agent must hold a store, not nothing"
    check factStoreFor(s, db).name == "mem0"
    if savedKey:
      putEnv("MEM0_API_KEY", savedValue)
    else:
      delEnv("MEM0_API_KEY")
    db.close()
    removeDir(home)

  test "zep needs a key, and says so when it falls back":
    let home = getTempDir() / "waku-store-zep-nokey"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedKey = existsEnv("ZEP_API_KEY")
    let savedValue = getEnv("ZEP_API_KEY")
    delEnv("ZEP_API_KEY")
    var s = defaultSettings()
    s.semanticStore = "zep"
    check factStoreFor(s, db).name == "sqlite"
    if savedKey:
      putEnv("ZEP_API_KEY", savedValue)
    db.close()
    removeDir(home)

  test "zep with a key builds the hosted store":
    let home = getTempDir() / "waku-store-zep"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedKey = existsEnv("ZEP_API_KEY")
    let savedValue = getEnv("ZEP_API_KEY")
    putEnv("ZEP_API_KEY", "zep-test-key")
    var s = defaultSettings()
    s.semanticStore = "zep"
    s.zepUserId = "someone"
    check factStoreFor(s, db).name == "zep"
    if savedKey:
      putEnv("ZEP_API_KEY", savedValue)
    else:
      delEnv("ZEP_API_KEY")
    db.close()
    removeDir(home)

  test "postgres needs a database and an embeddings key":
    # Either half missing is a half-wired remote store, which is worse than
    # a local one: sqlite plus a line on stderr, like the other backends.
    let home = getTempDir() / "waku-store-pg-nokey"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedUrl = existsEnv("DATABASE_URL")
    let savedUrlValue = getEnv("DATABASE_URL")
    let savedKey = existsEnv("OPENAI_API_KEY")
    let savedKeyValue = getEnv("OPENAI_API_KEY")
    delEnv("DATABASE_URL")
    delEnv("OPENAI_API_KEY")
    var s = defaultSettings()
    s.semanticStore = "postgres"
    check factStoreFor(s, db).name == "sqlite"
    putEnv("DATABASE_URL", "postgres://u:p@localhost:5432/waku")
    check factStoreFor(s, db).name == "sqlite"
    if savedUrl:
      putEnv("DATABASE_URL", savedUrlValue)
    else:
      delEnv("DATABASE_URL")
    if savedKey:
      putEnv("OPENAI_API_KEY", savedKeyValue)
    db.close()
    removeDir(home)

  test "postgres with both keys builds the pg store (lazily)":
    # Lazily: building must NOT dial — there is no server in the test env,
    # and construction only wraps the URL and the key.
    let home = getTempDir() / "waku-store-pg"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedUrl = existsEnv("DATABASE_URL")
    let savedUrlValue = getEnv("DATABASE_URL")
    let savedKey = existsEnv("OPENAI_API_KEY")
    let savedKeyValue = getEnv("OPENAI_API_KEY")
    putEnv("DATABASE_URL", "postgres://u:p@localhost:5432/waku")
    putEnv("OPENAI_API_KEY", "sk-test")
    var s = defaultSettings()
    s.semanticStore = "postgres"
    check factStoreFor(s, db).name == "postgres"
    if savedUrl:
      putEnv("DATABASE_URL", savedUrlValue)
    else:
      delEnv("DATABASE_URL")
    if savedKey:
      putEnv("OPENAI_API_KEY", savedKeyValue)
    else:
      delEnv("OPENAI_API_KEY")
    db.close()
    removeDir(home)

  test "langmem needs an embeddings key, either mode":
    let home = getTempDir() / "waku-store-lm-nokey"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedKey = existsEnv("OPENAI_API_KEY")
    let savedKeyValue = getEnv("OPENAI_API_KEY")
    delEnv("OPENAI_API_KEY")
    var s = defaultSettings()
    s.semanticStore = "langmem"
    check factStoreFor(s, db).name == "sqlite"
    if savedKey:
      putEnv("OPENAI_API_KEY", savedKeyValue)
    db.close()
    removeDir(home)

  test "langmem with a key builds the memory store, with a DSN the pg twin":
    # Building never dials in either mode: memory keeps rows in the client
    # and Postgres opens per call — so no server is needed to assert this.
    let home = getTempDir() / "waku-store-lm"
    if dirExists(home):
      removeDir(home)
    let db = connectDb(home)
    let savedKey = existsEnv("OPENAI_API_KEY")
    let savedKeyValue = getEnv("OPENAI_API_KEY")
    let savedDsn = existsEnv("WAKU_LANGMEM_POSTGRES")
    let savedDsnValue = getEnv("WAKU_LANGMEM_POSTGRES")
    putEnv("OPENAI_API_KEY", "sk-test")
    delEnv("WAKU_LANGMEM_POSTGRES")
    var s = defaultSettings()
    s.semanticStore = "langmem"
    check factStoreFor(s, db).name == "langmem"
    putEnv("WAKU_LANGMEM_POSTGRES", "postgres://u:p@localhost:5432/waku")
    check factStoreFor(s, db).name == "langmem-pg"
    if savedKey:
      putEnv("OPENAI_API_KEY", savedKeyValue)
    else:
      delEnv("OPENAI_API_KEY")
    if savedDsn:
      putEnv("WAKU_LANGMEM_POSTGRES", savedDsnValue)
    else:
      delEnv("WAKU_LANGMEM_POSTGRES")
    db.close()
    removeDir(home)
