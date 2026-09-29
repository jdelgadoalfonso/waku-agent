## Phase 4b tests: session assembly (SOUL, system prompt, history window).
## Offline only: temp homes under getTempDir(), no network.

import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/memory
import ../src/session

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc testSettings(home: string, historyTurns = 12): Settings =
  Settings(provider: "openai", apiKey: "", model: "m", home: home,
           smallModel: "", maxIterations: 10, maxTokens: 8192,
           historyTurns: historyTurns, graphWorkflows: false)

suite "phase 4b soul file":
  test "load_soul creates SOUL.md with DEFAULT_SOUL on first run":
    let home = freshHome("waku-sess-soul")
    let text = loadSoul(home)
    assert text == defaultSoul
    assert readFile(home / "SOUL.md") == defaultSoul
    removeDir(home)

  test "load_soul never overwrites an existing SOUL.md":
    let home = freshHome("waku-sess-keep")
    writeFile(home / "SOUL.md", "You are Custom.")
    assert loadSoul(home) == "You are Custom."
    removeDir(home)

suite "phase 4b system prompt":
  test "build_system without memory has soul, clock and model line":
    let home = freshHome("waku-sess-sys")
    let s = newSession(testSettings(home))
    let sys = s.buildSystem("hello")
    assert "You are Waku, a personal assistant" in sys
    assert "Right now it is " in sys
    assert "(UTC" in sys
    assert "Your model: you are running on 'm' via the 'openai' provider" in sys
    assert "inside Waku, a local-first open-source agent harness" in sys
    assert "github.com/ShenSeanChen/waku-agent" in sys
    assert "Relevant memory" notin sys
    assert "Relevant skill" notin sys
    removeDir(home)

  test "build_system splices the retrieval seams when they answer":
    let home = freshHome("waku-sess-seam")
    let s = newSession(testSettings(home),
      retrieve = proc(msg: string, n: Observer): string = "alex likes sailing",
      skillsFor = proc(msg: string, n: Observer): string = "")
    let sys = s.buildSystem("what does alex like?")
    assert "Relevant memory:\nalex likes sailing" in sys
    assert "Relevant skill" notin sys  # empty answers are skipped
    removeDir(home)

suite "phase 4b exchanges":
  test "add_exchange folds tool calls into a [tools used: ...] line":
    let home = freshHome("waku-sess-fold")
    var s = newSession(testSettings(home))
    s.addExchange("go", "done",
      @[(tool: "echo", args: "{\"text\": \"x\"}", output: "echo:x")])
    assert s.history.len == 2
    assert s.history[0] == (role: "user", content: "go")
    assert s.history[1] ==
      (role: "assistant",
       content: "done\n[tools used: echo({\"text\": \"x\"}) -> echo:x]")
    removeDir(home)

  test "add_exchange without tools stores the bare reply":
    let home = freshHome("waku-sess-bare")
    var s = newSession(testSettings(home))
    s.addExchange("hi", "hello")
    assert s.history[1] == (role: "assistant", content: "hello")
    removeDir(home)

  test "add_exchange joins several tool calls with '; '":
    let home = freshHome("waku-sess-multi")
    var s = newSession(testSettings(home))
    s.addExchange("go", "done",
      @[(tool: "a", args: "{}", output: "1"),
        (tool: "b", args: "{\"x\": 1}", output: "2")])
    assert s.history[1] ==
      (role: "assistant",
       content: "done\n[tools used: a({}) -> 1; b({\"x\": 1}) -> 2]")
    removeDir(home)

  test "add_exchange with memory writes chat_log with meta on the assistant row":
    let home = freshHome("waku-sess-log")
    let db = connectDb(home)
    var s = newSession(testSettings(home), db = db)
    s.addExchange("hi", "hello", source = "cli", meta = "{\"iterations\":1}")
    let pairs = db.sessionHistory("default")
    assert pairs == @[(user: "hi", reply: "hello")]
    let rows = db.getAllRows(
      sql"SELECT role, meta FROM chat_log ORDER BY id")
    assert rows[0][0] == "user"
    assert rows[0][1] == ""
    assert rows[1][0] == "assistant"
    assert rows[1][1] == "{\"iterations\":1}"
    db.close()
    removeDir(home)

  test "add_exchange without meta leaves the assistant meta NULL":
    let home = freshHome("waku-sess-nometa")
    let db = connectDb(home)
    var s = newSession(testSettings(home), db = db)
    s.addExchange("hi", "hello")
    let rows = db.getAllRows(
      sql"SELECT meta FROM chat_log WHERE role='assistant'")
    assert rows.len == 1
    assert rows[0][0] == ""  # NULL reads back as ""
    let nulls = db.getAllRows(
      sql"SELECT COUNT(*) FROM chat_log WHERE role='assistant' AND meta IS NULL")
    assert nulls[0][0] == "1"
    db.close()
    removeDir(home)

suite "phase 4b lifecycle":
  test "switch reloads only the history_turns tail":
    let home = freshHome("waku-sess-tail")
    let db = connectDb(home)
    var s = newSession(testSettings(home, historyTurns = 2), db = db)
    for i in 1 .. 4:
      s.addExchange("q" & $i, "a" & $i)
    s.startNew("other")
    assert s.history.len == 0
    assert s.sessionId == "other"
    s.switch("default")
    assert s.history.len == 4  # 2 turns x 2 rows
    assert s.history[0] == (role: "user", content: "q3")
    assert s.history[^1] == (role: "assistant", content: "a4")
    db.close()
    removeDir(home)

  test "switch with no memory just retags and clears":
    let home = freshHome("waku-sess-nil")
    var s = newSession(testSettings(home))
    s.addExchange("hi", "hello")
    s.switch("fresh")
    assert s.sessionId == "fresh"
    assert s.history.len == 0
    removeDir(home)

  test "switch with history_turns=0 reloads the whole thread (Python quirk)":
    let home = freshHome("waku-sess-zero")
    let db = connectDb(home)
    var s = newSession(testSettings(home, historyTurns = 0), db = db)
    for i in 1 .. 3:
      s.addExchange("q" & $i, "a" & $i)
    s.switch("default")
    assert s.history.len == 6  # list[-0:] is list[0:] in Python too
    assert s.history[0] == (role: "user", content: "q1")
    db.close()
    removeDir(home)

  test "orphan assistant rows never pair in session_history":
    let home = freshHome("waku-sess-orphan")
    let db = connectDb(home)
    db.exec(sql("INSERT INTO chat_log (role, content, session_id, source) " &
            "VALUES ('assistant', 'stray', 's1', 'cli')"))
    var s = newSession(testSettings(home), db = db)
    s.switch("s1")
    assert s.history.len == 0
    db.close()
    removeDir(home)

suite "phase 4b config fields":
  const names = ["WAKU_SMALL_MODEL", "WAKU_MAX_ITERATIONS", "WAKU_MAX_TOKENS",
                 "WAKU_HISTORY_TURNS", "WAKU_GRAPH_WORKFLOWS"]

  test "new fields keep Python defaults when vars are unset":
    var saved: seq[(string, string, bool)] = @[]
    for n in names:
      saved.add((n, getEnv(n), existsEnv(n)))
      delEnv(n)
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.smallModel == ""
    assert s.maxIterations == 10
    assert s.maxTokens == 8192
    assert s.historyTurns == 12
    assert s.graphWorkflows == false
    for (n, v, was) in saved:
      if was: putEnv(n, v)
      else: delEnv(n)

  test "new fields respect every WAKU_* override, garbage ints fall back":
    var saved: seq[(string, string, bool)] = @[]
    for n in names:
      saved.add((n, getEnv(n), existsEnv(n)))
    putEnv("WAKU_SMALL_MODEL", "mini")
    putEnv("WAKU_MAX_ITERATIONS", "3")
    putEnv("WAKU_MAX_TOKENS", "not-a-number")
    putEnv("WAKU_HISTORY_TURNS", "5")
    putEnv("WAKU_GRAPH_WORKFLOWS", "yes")
    var s = defaultSettings()
    s.loadFromEnv()
    assert s.smallModel == "mini"
    assert s.maxIterations == 3
    assert s.maxTokens == 8192  # garbage keeps the default, never crashes
    assert s.historyTurns == 5
    assert s.graphWorkflows == true
    for (n, v, was) in saved:
      if was: putEnv(n, v)
      else: delEnv(n)
