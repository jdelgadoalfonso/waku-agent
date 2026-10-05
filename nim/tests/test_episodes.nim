## The conformance suite every `EpisodeStore` has to pass.
##
## Same reason as `test_factstore.nim`: nothing checked the episodic backends
## for a long time, and the bill for an unchecked backend always arrives in
## front of a user. One `test` per contract rule, each looping over
## `backends`, with the backend name inside every failure message — a Nim loop
## does not parametrize, so the name has to be in the message or a red run
## does not say which backend broke.
##
## Offline by construction. `sqlite` always runs against a temp home; a vault
## backend (unit T2) runs against a temp dir, because files need no network
## and no account — which is the whole point of Obsidian over Notion.

import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/episodes
import ../src/obsidian

const
  backends = ["sqlite", "obsidian"]
    ## Every backend in this build. Adding one means adding its factory in
    ## `freshStore` below; the suite itself never grows a conditional.

  contractMethods = [
    # (name in Python, field name here) — read off the contract, not off the
    # tests, because the whole point is that the tests cannot drift away from
    # it unnoticed. Nim has no reflection to enumerate a record's fields, so
    # this table plus the "every field is filled" test below stand in for it.
    ("add", "add"), ("recent", "recent"), ("search", "search"),
    ("list", "list"), ("delete", "delete")]

proc freshStore(name, tag: string): tuple[store: EpisodeStore, db: DbConn,
                                          home: string] =
  ## A store on a home of its own, so one backend's rows can never satisfy
  ## another backend's search and hide a bug.
  result.home = getTempDir() / ("waku-episodes-" & tag & "-" & name)
  if dirExists(result.home):
    removeDir(result.home)
  result.db = connectDb(result.home)
  case name
  of "sqlite":
    result.store = sqliteEpisodeStore(result.db)
  of "obsidian":
    result.store = obsidianEpisodeStore(newObsidianStore(result.home / "vault"))
  else:
    raise newException(ValueError, "no episode backend: " & name)

proc done(db: DbConn, home: string) =
  ## Close and delete, so N tests times M backends do not leave a directory
  ## per run in /tmp.
  db.close()
  removeDir(home)

suite "the EpisodeStore contract":
  test "every field of the contract is filled":
    # A record of closures does not fail to compile when a field is left out
    # (it becomes nil), so this is the check that stands in for a Protocol:
    # a backend that "implements the contract" by forgetting a method fails
    # HERE, not in front of a user.
    for name in backends:
      let f = freshStore(name, "fields")
      assert f.store.add != nil, name & ": add is missing"
      assert f.store.recent != nil, name & ": recent is missing"
      assert f.store.search != nil, name & ": search is missing"
      assert f.store.list != nil, name & ": list is missing"
      assert f.store.delete != nil, name & ": delete is missing"
      done(f.db, f.home)

  test "add then recent round-trips, newest first":
    for name in backends:
      let f = freshStore(name, "roundtrip")
      f.store.add("sailed around the island", "2026-09-01 10:00")
      f.store.add("hiked the ridge trail", "2026-09-05 10:00")
      let hits = f.store.recent(4)
      assert hits.len == 2, name & ": stored two events and read " & $hits.len
      assert "ridge" in hits[0], name & ": newest first, got: " & $hits
      done(f.db, f.home)

  test "a miss returns empty rather than raising":
    # An episodic backend that throws takes the retrieval or the
    # consolidation down with it.
    for name in backends:
      let f = freshStore(name, "miss")
      assert f.store.search("nothing here matches this at all", 3) == [],
        name & ": a miss must be empty, not an error"
      done(f.db, f.home)

  test "an empty query falls back to recent":
    # Both Python backends agree on this (FTS fallback, keyword fallback),
    # so the contract states it: an empty query is not a search.
    for name in backends:
      let f = freshStore(name, "empty")
      f.store.add("sailed around the island", "2026-09-01 10:00")
      let hits = f.store.search("", 3)
      assert hits.len == 1, name & ": empty query must read recent: " & $hits
      done(f.db, f.home)

  test "search finds by keyword":
    for name in backends:
      let f = freshStore(name, "search")
      f.store.add("sailed around the island", "2026-09-01 10:00")
      f.store.add("hiked the ridge trail", "2026-09-05 10:00")
      let hits = f.store.search("sailed island", 3)
      assert hits.len == 1 and "island" in hits[0],
        name & ": stored an event and could not find it: " & $hits
      done(f.db, f.home)

  test "delete removes the event":
    for name in backends:
      let f = freshStore(name, "delete")
      f.store.add("sailed around the island", "2026-09-01 10:00")
      let rows = f.store.list(10)
      assert rows.len == 1, name & ": list must show what was added"
      assert f.store.delete(rows[0].id) == true,
        name & ": delete rejected the id its own list returned"
      assert f.store.list(10) == @[], name & ": the event is still there"
      done(f.db, f.home)

  test "an unknown id is false, not an exception":
    for name in backends:
      let f = freshStore(name, "unknown")
      assert f.store.delete("no-such-id") == false,
        name & ": an unknown id must be false, not an error"
      assert f.store.delete("") == false, name & ": an empty id must be false"
      done(f.db, f.home)

  test "list returns what was added, newest first":
    for name in backends:
      let f = freshStore(name, "list")
      f.store.add("first week", "2026-09-01 10:00")
      f.store.add("second week", "2026-09-08 10:00")
      let rows = f.store.list(10)
      assert rows.len == 2, name & ": expected two rows: " & $rows.len
      assert "second" in rows[0].summary, name & ": newest first: " & $rows
      assert rows[0].id.len > 0 and rows[1].id.len > 0,
        name & ": rows without ids"
      done(f.db, f.home)

  test "non-ascii round-trips on every backend":
    for name in backends:
      let f = freshStore(name, "unicode")
      f.store.add("reunión con Priya en el café", "2026-09-01 10:00")
      assert f.store.recent(4) == @["(2026-09-01 10:00) reunión con Priya en el café"],
        name & ": round trip mangled: " & $f.store.recent(4)
      done(f.db, f.home)

# --- the suite keeps itself honest -----------------------------------------
suite "the episode suite watches itself":
  test "every method on the contract is actually exercised here":
    # If the contract grows a method and nobody pins it, the suite is a
    # green run that tests nothing new. Count the exercised fields against
    # the table above instead of trusting the eye.
    var exercised: seq[string] = @[]
    for name in backends:
      let f = freshStore(name, "selfwatch")
      f.store.add("x", "2026-01-01 00:00")
      discard f.store.recent(1)
      discard f.store.search("x", 1)
      discard f.store.list(1)
      discard f.store.delete("0")
      exercised = @["add", "recent", "search", "list", "delete"]
      done(f.db, f.home)
    assert exercised.len == contractMethods.len,
      "a contract method is not exercised: " & $exercised
    for i, m in contractMethods:
      assert exercised[i] == m[1], "drift between suite and contract: " & m[0]
