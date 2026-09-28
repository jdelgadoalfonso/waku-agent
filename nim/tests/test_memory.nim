## Phase 1c tests: facts/episodes CRUD against a real temp state.db.
## Offline only: temp homes under getTempDir(), no network.

import std/os
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/memory

proc freshDb(name: string): tuple[home: string, db: DbConn] =
  let home = getTempDir() / name
  if dirExists(home):
    removeDir(home)
  result = (home, connectDb(home))

suite "phase 1c facts":
  test "add lowercases the subject and search finds it":
    let (home, db) = freshDb("waku-mem-facts")
    db.addFact("  ALEX  ", "likes sailing")
    assert db.searchFacts("alex") == @["[alex] likes sailing"]
    assert db.searchFacts("ALEX") == @["[alex] likes sailing"]
    db.close()
    removeDir(home)

  test "empty query returns no rows, ids variant falls back to list":
    let (home, db) = freshDb("waku-mem-empty")
    db.addFact("alex", "likes sailing")
    assert db.searchFacts("x") == newSeq[string]()
    assert db.searchFactsWithIds("x").len == 1
    assert db.searchFactsWithIds("x")[0].subject == "alex"
    db.close()
    removeDir(home)

  test "list is newest-first and honors the limit":
    let (home, db) = freshDb("waku-mem-list")
    db.addFact("one", "first")
    db.addFact("two", "second")
    let rows = db.listFacts(1)
    assert rows.len == 1
    assert rows[0].subject == "two"
    assert rows[0].source == "user"
    db.close()
    removeDir(home)

  test "update rewrites content and keeps the index in sync":
    let (home, db) = freshDb("waku-mem-update")
    db.addFact("alex", "likes sailing")
    assert db.updateFactContent(1, "hates motorboats")
    assert db.searchFacts("sailing") == newSeq[string]()
    assert db.searchFacts("motorboats") == @["[alex] hates motorboats"]
    assert db.updateFact(1, "loves kayaks", "  ALEX  ")
    assert db.searchFacts("kayaks") == @["[alex] loves kayaks"]
    assert not db.updateFactContent(999, "ghost")
    db.close()
    removeDir(home)

  test "delete removes the row and returns false when missing":
    let (home, db) = freshDb("waku-mem-delete")
    db.addFact("alex", "likes sailing")
    assert db.deleteFact(1)
    assert db.searchFacts("sailing") == newSeq[string]()
    assert not db.deleteFact(1)
    db.close()
    removeDir(home)

  test "settle is immediately true":
    assert settle()

suite "phase 1c episodes":
  test "search blends relevance with recency":
    let (home, db) = freshDb("waku-mem-episodes")
    db.addEpisode("sailed around the island", "2026-09-01")
    db.addEpisode("sailed past the lighthouse", "2026-09-10")
    db.addEpisode("hiked the ridge trail", "2026-09-05")
    let hits = db.searchEpisodes("sailed")
    assert hits.len == 2
    assert hits[0] == "(2026-09-10) sailed past the lighthouse"
    assert hits[1] == "(2026-09-01) sailed around the island"
    db.close()
    removeDir(home)

  test "empty query falls back to recent":
    let (home, db) = freshDb("waku-mem-ep-recent")
    db.addEpisode("older thing", "2026-01-01")
    db.addEpisode("newer thing", "2026-09-01")
    assert db.searchEpisodes("x") == @["(2026-09-01) newer thing",
                                       "(2026-01-01) older thing"]
    db.close()
    removeDir(home)

  test "list and delete follow the facts pattern":
    let (home, db) = freshDb("waku-mem-ep-crud")
    db.addEpisode("a thing", "2026-05-01")
    assert db.listEpisodes().len == 1
    assert db.listEpisodes()[0].happenedAt == "2026-05-01"
    assert db.deleteEpisode(1)
    assert not db.deleteEpisode(1)
    assert db.listEpisodes().len == 0
    db.close()
    removeDir(home)
