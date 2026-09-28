## Phase 1a tests: state.db schema, triggers, migrations, PRAGMAs.
## Offline only: temp homes under getTempDir(), no network, no `.waku/`
## writes outside the temp dir.

import std/os
import std/unittest

import db_connector/db_sqlite

import ../src/db

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc schemaObjectNames(db: DbConn): seq[string] =
  for row in db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type IN ('table', 'trigger') ORDER BY name"):
    result.add(row[0])

suite "phase 1a schema":
  test "connectDb creates every table, FTS index and trigger":
    let home = freshHome("waku-db-schema")
    let db = connectDb(home)
    let names = schemaObjectNames(db)
    for expected in ["calendar_events", "facts", "facts_fts",
                     "facts_ai", "facts_ad", "facts_au",
                     "episodes", "episodes_fts", "episodes_ai", "episodes_ad",
                     "chat_log"]:
      assert expected in names, "missing schema object: " & expected
    assert fileExists(home / "state.db")
    db.close()
    removeDir(home)

  test "connectDb is idempotent across reopens":
    let home = freshHome("waku-db-reopen")
    var db = connectDb(home)
    db.exec(sql"INSERT INTO facts (subject, content) VALUES (?, ?)", "alex", "likes sailing")
    db.close()
    db = connectDb(home)
    assert db.getValue(sql"SELECT COUNT(*) FROM facts") == "1"
    assert db.getValue(sql"SELECT COUNT(*) FROM facts_fts") == "1"
    db.close()
    removeDir(home)

  test "facts triggers keep the FTS index in sync":
    let home = freshHome("waku-db-triggers")
    let db = connectDb(home)
    db.exec(sql"INSERT INTO facts (subject, content) VALUES (?, ?)", "alex", "likes sailing")
    assert db.getValue(sql"SELECT COUNT(*) FROM facts_fts WHERE facts_fts MATCH ?", "sailing") == "1"
    db.exec(sql"UPDATE facts SET content = ? WHERE subject = ?", "hates motorboats", "alex")
    assert db.getValue(sql"SELECT COUNT(*) FROM facts_fts WHERE facts_fts MATCH ?", "sailing") == "0"
    assert db.getValue(sql"SELECT COUNT(*) FROM facts_fts WHERE facts_fts MATCH ?", "motorboats") == "1"
    db.exec(sql"DELETE FROM facts WHERE subject = ?", "alex")
    assert db.getValue(sql"SELECT COUNT(*) FROM facts_fts WHERE facts_fts MATCH ?", "motorboats") == "0"
    db.close()
    removeDir(home)

  test "episodes triggers keep the FTS index in sync":
    let home = freshHome("waku-db-episodes-trg")
    let db = connectDb(home)
    db.exec(sql"INSERT INTO episodes (happened_at, summary) VALUES (?, ?)",
            "2026-09-01", "sailed around the island")
    assert db.getValue(sql"SELECT COUNT(*) FROM episodes_fts WHERE episodes_fts MATCH ?", "sailed") == "1"
    db.exec(sql"DELETE FROM episodes WHERE id = 1")
    assert db.getValue(sql"SELECT COUNT(*) FROM episodes_fts WHERE episodes_fts MATCH ?", "sailed") == "0"
    db.close()
    removeDir(home)

  test "migrate upgrades a legacy chat_log without the new columns":
    let home = freshHome("waku-db-migrate")
    var legacy = open(home / "state.db", "", "", "")
    legacy.exec(sql"""CREATE TABLE chat_log (
        id INTEGER PRIMARY KEY,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        consolidated INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now')))""")
    legacy.exec(sql"INSERT INTO chat_log (role, content) VALUES (?, ?)", "user", "hello")
    legacy.close()
    let db = connectDb(home)
    let cols = chatLogColumns(db)
    for expected in ["session_id", "source", "meta"]:
      assert expected in cols, "migration missed column: " & expected
    assert db.getValue(sql"SELECT content FROM chat_log WHERE role = ?", "user") == "hello"
    db.close()
    removeDir(home)

  test "busy_timeout is set to 3000ms":
    let home = freshHome("waku-db-pragma")
    let db = connectDb(home)
    assert db.getValue(sql"PRAGMA busy_timeout") == "3000"
    db.close()
    removeDir(home)
