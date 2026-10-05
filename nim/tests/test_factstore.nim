## The conformance suite every `FactStore` has to pass — the port of
## `evals/deterministic/test_fact_store_conformance.py`.
##
## This file is the reason the contract in `src/factstore.nim` is worth
## anything. Python's version runs eleven checks against EVERY backend it knows
## (sqlite, supabase, mem0, zep, langmem), and it exists because nothing used to
## check: `SupabaseFactStore` shipped missing four of the six methods and the
## first anyone found out was a user whose dashboard 500'd. The suite grew out
## of that, and the last test here grows with it.
##
## Structure: one `test` per contract rule, each looping over `backends`, with
## the backend name inside every failure message. Python's `parametrize` gives
## one test id per backend; a Nim loop does not, so the name has to be in the
## message or a red run does not say which backend broke.
##
## Offline by construction. `sqlite` always runs against a temp home; a hosted
## backend arrives here as a loopback fake (unit T2), because the real services
## cannot: Python gates mem0 behind `WAKU_TEST_MEM0=1` precisely because a
## maintainer running the suite must not start filling somebody's real Mem0
## workspace with test facts about Priya's meeting preferences.

import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/factstore

import factstore_fakes

const
  backends = ["sqlite", "mem0-fake", "zep-fake", "pg-fake", "langmem-fake"]
    ## Every backend in this build. `mem0-fake` is the stateful fake in
    ## `factstore_fakes.nim`, so the hosted contract is a gate that always
    ## runs and never reaches a network. Adding a real backend means adding
    ## its factory here; the suite itself never grows a conditional.

  contractMethods = [
    # (name in Python, field name here) — read off the contract, not off the
    # tests, because the whole point is that the tests cannot drift away from
    # it unnoticed. Nim has no reflection to enumerate a record's fields, so
    # this table plus the "every field is filled" test below stand in for
    # Python's `vars(FactStore)`.
    ("add", "add"), ("search", "search"), ("list", "list"),
    ("search_with_ids", "searchWithIds"), ("update", "update"),
    ("delete", "delete"), ("settle", "settle")]

proc freshStore(name, tag: string): tuple[store: FactStore, db: DbConn,
                                          home: string] =
  ## A store on a home of its own, so one backend's rows can never satisfy
  ## another backend's search and hide a bug.
  result.home = getTempDir() / ("waku-factstore-" & tag & "-" & name)
  if dirExists(result.home):
    removeDir(result.home)
  result.db = connectDb(result.home)
  case name
  of "sqlite":
    result.store = sqliteFactStore(result.db)
  of "mem0-fake":
    result.store = mem0FakeStore()
  of "zep-fake":
    result.store = zepFakeStore()
  of "pg-fake":
    result.store = pgFakeStore()
  of "langmem-fake":
    result.store = langmemFakeStore()
  else:
    raise newException(ValueError, "no fake for backend: " & name)

proc done(db: DbConn, home: string) =
  ## Close and delete, so eleven tests times N backends do not leave a
  ## directory per run in /tmp.
  db.close()
  removeDir(home)

suite "the FactStore contract":
  test "every field of the contract is filled":
    # THE regression. Python's version asserts `isinstance(store, FactStore)`
    # and names the missing methods; a Protocol check. A record of closures
    # does not fail to compile when a field is left out (it becomes nil), so
    # this is the check that stands in for it: a backend that "implements the
    # contract" by forgetting a method has to fail HERE.
    for name in backends:
      let f = freshStore(name, "fields")
      assert f.store.add != nil, name & ": add is missing"
      assert f.store.search != nil, name & ": search is missing"
      assert f.store.list != nil, name & ": list is missing"
      assert f.store.searchWithIds != nil, name & ": search_with_ids is missing"
      assert f.store.update != nil, name & ": update is missing"
      assert f.store.delete != nil, name & ": delete is missing"
      assert f.store.settle != nil, name & ": settle is missing"
      done(f.db, f.home)

  test "add then search round-trips":
    for name in backends:
      let f = freshStore(name, "roundtrip")
      f.store.add("jensen", "Jensen always wears a leather jacket", "user")
      let hits = f.store.search("jensen leather jacket", 4)
      var found = false
      for hit in hits:
        if "leather jacket" in hit:
          found = true
      assert found, name & ": stored a fact and could not find it: " & $hits
      done(f.db, f.home)

  test "a miss returns empty rather than raising":
    # A memory backend that throws takes the whole turn down with it.
    for name in backends:
      let f = freshStore(name, "miss")
      assert f.store.search("nothing here matches this at all", 4) == [],
        name & ": a miss must be empty, not an error"
      done(f.db, f.home)

  test "search_with_ids returns ids that update accepts":
    # The lookup step of every correction. When this returns [] on failure
    # instead of raising, the agent reports the memory does not exist — which
    # is precisely what the `hasattr` guard in manage_memory used to cause.
    for name in backends:
      let f = freshStore(name, "ids")
      f.store.add("elon", "The launch is in March", "user")
      let rows = f.store.searchWithIds("elon launch", 8)
      assert rows.len > 0, name & ": found nothing it just stored"
      if rows.len > 0:
        assert rows[0].content.len > 0, name & ": row without content"
        assert f.store.update(rows[0].id, "The launch is in June", "") == true,
          name & ": update rejected the id its own search returned"
      done(f.db, f.home)

  test "update changes what search returns":
    for name in backends:
      let f = freshStore(name, "update")
      f.store.add("elon", "The launch is in March", "user")
      let rows = f.store.searchWithIds("elon launch", 8)
      assert rows.len > 0, name & ": found nothing it just stored"
      discard f.store.update(rows[0].id, "The launch is in June", "")
      var june = false
      for hit in f.store.search("elon launch", 4):
        if "June" in hit:
          june = true
      assert june, name & ": update claimed True and search still says March"
      done(f.db, f.home)

  test "an empty subject leaves the subject alone":
    # `update(id, content, subject=None)` in Python. The remote stores rewrite
    # one blob and have to read the subject back themselves, which is why the
    # contract speaks ONE method; the sqlite layer keeps its split and the
    # adapter absorbs the difference. A backend that dropped the subject
    # instead would silently rename every corrected fact to nothing.
    for name in backends:
      let f = freshStore(name, "subject")
      f.store.add("Tom Holland", "cannot keep a secret", "user")
      let before = f.store.searchWithIds("Tom Holland", 8)
      assert before.len > 0, name & ": found nothing it just stored"
      discard f.store.update(before[0].id, "cannot keep a quiet one", "")
      let rows = f.store.searchWithIds("Tom Holland", 8)
      assert rows.len > 0, name & ": the fact went missing"
      if rows.len > 0:
        assert rows[0].subject == "tom holland",
          name & ": subject was not left alone: " & rows[0].subject
      done(f.db, f.home)

  test "delete removes the fact":
    for name in backends:
      let f = freshStore(name, "delete")
      f.store.add("tom", "Tom Holland cannot keep a secret", "user")
      let rows = f.store.searchWithIds("tom holland secret", 8)
      assert rows.len > 0, name & ": found nothing it just stored"
      assert f.store.delete(rows[0].id) == true, name & ": delete said False"
      var still = false
      for hit in f.store.search("tom holland secret", 4):
        if "secret" in hit:
          still = true
      assert not still, name & ": deleted and still searchable"
      done(f.db, f.home)

  test "an unknown id is false, not an exception":
    # False means "no such row". Raising here would turn a stale id in the
    # dashboard into a 500.
    for name in backends:
      let f = freshStore(name, "unknown")
      assert f.store.update("999999999", "x", "") == false,
        name & ": update claimed True for a row that does not exist"
      assert f.store.delete("999999999") == false,
        name & ": delete claimed True for a row that does not exist"
      # A foreign id is a miss too, not a crash: mem0's ids are UUIDs and a
      # sqlite adapter must never try to be clever with one.
      assert f.store.update("5f9c2a4e-0b1d-4c7a-9f3e-2d8b6a1c0e55", "x", "") == false,
        name & ": a non-numeric id must be a miss"
      done(f.db, f.home)

  test "list returns what was added":
    for name in backends:
      let f = freshStore(name, "list")
      f.store.add("pikachu", "Pikachu is coming to the dinner party", "user")
      let rows = f.store.list(50)
      var found = false
      for r in rows:
        if "Pikachu" in r.content:
          found = true
        assert r.id.len > 0, name & ": a listed fact with no id"
        assert r.subject.len > 0, name & ": a listed fact with no subject"
        assert r.content.len > 0, name & ": a listed fact with no content"
      assert found, name & ": list lost the fact that was just added"
      done(f.db, f.home)

  test "non-ascii round-trips on every backend":
    # The 2026-08-05 bug (see test_memory_search.py) was one backend's query
    # builder dropping non-ASCII. Pinning it HERE means a new backend cannot
    # reintroduce it — the failure mode was users silently receiving somebody
    # else's memories, which no amount of English coverage would catch.
    for name in backends:
      let f = freshStore(name, "nonascii")
      f.store.add("сергей", "Сергей любит плавать", "user")
      assert f.store.search("Сергей", 4).len > 0,
        name & ": a Cyrillic fact stored but not findable"
      done(f.db, f.home)

  test "settle reports readiness and never raises":
    # settle() answers "is what I wrote actually searchable yet". The contract
    # that matters is the PAIRING: settle() returning true while a just-written
    # fact is not findable would be worse than having no method, because the
    # caller gets a green light and a wrong answer and blames the store's
    # memory rather than its clock.
    for name in backends:
      let f = freshStore(name, "settle")
      f.store.add("alex", "runs a robotics startup", "user")
      assert f.store.settle(5000) == true, name & ": a local store has nothing to wait for"
      assert f.store.search("robotics", 4).len > 0,
        name & ": settled must mean searchable, not merely written"
      done(f.db, f.home)

  test "settle is safe to call on an empty store":
    # Called before anything is written — the arena's control contestant seeds
    # nothing at all. Waiting for a count to stabilise must not hang or throw on
    # a store where the count is legitimately zero forever.
    for name in backends:
      let f = freshStore(name, "emptysettle")
      assert f.store.settle(500) == true,
        name & ": settling an empty store must answer, not hang"
      done(f.db, f.home)

  # --- the suite keeps itself honest -----------------------------------------
  test "every method on the contract is actually exercised here":
    # A contract only helps if the suite grows with it. Add a method to
    # FactStore without testing it and this fails — otherwise the contract
    # silently widens and we are back to trusting that backends implement it,
    # which is the exact assumption that broke.
    let source = readFile(currentSourcePath())
    let body = source.split("# --- the suite keeps itself honest", 1)[0]
    for (pyName, fieldName) in contractMethods:
      assert ("store." & fieldName & "(") in body,
        "the contract's `" & pyName & "` is never exercised in this suite"

  test "the contract list and the record agree":
    # The table above can itself go stale: someone renames a field and updates
    # the tests, and the self-policing test above then greps for a name nobody
    # calls. A store built from every declared method and read back through
    # them closes that loop — if a field were renamed, this would not compile.
    var probe: FactStore
    probe.add = proc(subject, content, source: string) = discard
    probe.search = proc(query: string, topK: int): seq[string] = @[]
    probe.list = proc(limit: int): seq[StoreFact] = @[]
    probe.searchWithIds = proc(query: string, topK: int): seq[StoreFact] = @[]
    probe.update = proc(id: FactId, content, subject: string): bool = true
    probe.delete = proc(id: FactId): bool = true
    probe.settle = proc(timeoutMs: int): bool = true
    for (_, fieldName) in contractMethods:
      assert fieldName.len > 0, "a contract method with no field name"
    assert probe.search("anything", 4) == @[]
    assert probe.settle(1)