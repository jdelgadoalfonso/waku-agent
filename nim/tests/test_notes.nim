## save_note tests (spec 018): the tool tells the model the
## truth about where a fact went. Offline: a temp home, a
## real sqlite facts table, and a plain closure standing in
## for Waku Memory — the same shape as the Python eval
## `evals/deterministic/test_save_note_sends.py`.

import std/json
import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/memory_admin
import ../src/notes

proc freshDb(name: string): tuple[home: string, db: DbConn] =
  result.home = getTempDir() / name
  if dirExists(result.home):
    removeDir(result.home)
  createDir(result.home)
  result.db = connectDb(result.home)

proc factRow(db: DbConn): seq[string] =
  db.getRow(sql"SELECT subject, content, source, synced, scope FROM facts")

suite "save_note (spec 018)":
  test "a connected save goes to Waku Memory and the answer gives the id":
    let (home, db) = freshDb("waku-notes-connected")
    var sent: seq[string] = @[]
    let remember: notes.Remember = proc(content, scope: string): string =
      sent.add(content & "|" & scope)
      "mem-1"
    let tool = makeSaveNoteTool(db, remember)
    assert tool.fn(%*{"subject": "Alex",
      "content": "Alex prefers morning meetings."}) ==
      "Saved here and in Waku Memory (id mem-1)."
    assert sent == @["Alex prefers morning meetings.|global"]
    let row = factRow(db)
    assert row[0] == "alex"
    assert row[1] == "Alex prefers morning meetings."
    assert row[2] == "user"
    assert row[3] == "1"
    assert row[4] == "global"
    db.close()
    removeDir(home)

  test "a failed send says so and leaves the fact waiting for a retry":
    let (home, db) = freshDb("waku-notes-failed")
    let remember: notes.Remember = proc(content, scope: string): string =
      raise newException(CatchableError, "Waku Memory answered 503")
    let tool = makeSaveNoteTool(db, remember)
    assert tool.fn(%*{"subject": "Alex",
      "content": "Alex prefers morning meetings."}) ==
      "Saved here. Waku Memory did not take it " &
      "(Waku Memory answered 503); it is sent again later."
    let row = factRow(db)
    assert row[3] == "0"
    assert row[4] == "global"
    db.close()
    removeDir(home)

  test "a long failure reason is cut and kept on one line":
    let (home, db) = freshDb("waku-notes-long")
    let remember: notes.Remember = proc(content, scope: string): string =
      raise newException(CatchableError, "first line\n" & repeat("x", 300))
    let tool = makeSaveNoteTool(db, remember)
    let answer = tool.fn(%*{"subject": "Alex", "content": "A fact."})
    assert "\n" notin answer
    assert answer.len < 200
    db.close()
    removeDir(home)

  test "with no Waku Memory the fact is saved here and the answer says only that":
    let (home, db) = freshDb("waku-notes-disconnected")
    let tool = makeSaveNoteTool(db)
    assert tool.fn(%*{"subject": "Alex", "content": "A fact."}) ==
      "Saved here. Waku Memory is not connected."
    assert factRow(db)[3] == "1"
    db.close()
    removeDir(home)

  test "a server that names no id still counts as taken":
    let (home, db) = freshDb("waku-notes-noid")
    let remember: notes.Remember = proc(content, scope: string): string = ""
    let tool = makeSaveNoteTool(db, remember)
    assert tool.fn(%*{"subject": "Alex", "content": "A fact."}) ==
      "Saved here and in Waku Memory."
    assert factRow(db)[3] == "1"
    db.close()
    removeDir(home)
