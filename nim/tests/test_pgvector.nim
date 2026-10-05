## Pins for the Postgres+pgvector backend — the port of
## `waku/memory/semantic/supabase_store.py` with a direct-SQL transport
## (`nim/src/pgvector.nim`).
##
## Two kinds of check, like mem0/zep. The conformance suite in
## `test_factstore.nim` proves the ADAPTER obeys the contract, against the
## in-memory `pgFakeStore`. This file proves the CLIENT says what Postgres
## expects — table, operator, casts and parameter order — because SQL that
## names the wrong column answers empty and every rule still passes against
## the fake.
##
## Offline by construction: the seams capture and assert. The one exception
## is the live gate at the bottom, behind `WAKU_TEST_POSTGRES=1` plus
## `DATABASE_URL`, which round-trips its own `waku-test-` rows and deletes
## them afterwards — nothing of the user's survives the run.

import std/os
import std/strutils
import std/unittest

import ../src/pgvector
import factstore_fakes

type
  QCall = tuple[sql: string, args: seq[string], expectRows: bool]

var seenQ: seq[QCall] = @[]
var nextRows: seq[seq[string]] = @[]
var nextAffected = 1i64
var embedCalls = 0

proc recording(sql: string, args: seq[string],
               expectRows: bool): PgAnswer =
  seenQ.add((sql, args, expectRows))
  PgAnswer(ok: true, rows: nextRows, affected: nextAffected)

proc countingEmbed(text: string): EmbedAnswer =
  inc embedCalls
  EmbedAnswer(ok: true, vec: fakeEmbed(text))

proc testClient(): PgClient =
  seenQ = @[]
  nextRows = @[]
  nextAffected = 1
  embedCalls = 0
  newPgClient("postgres://u:p@localhost:5432/waku", "sk-test",
              query = recording, embed = countingEmbed)

suite "conninfo":
  test "a URL becomes libpq keywords, params forwarded":
    assert conninfoOf("postgres://u:p%40ss@db.example.com:5433/app?sslmode=require") ==
      "host=db.example.com port=5433 dbname=app user=u password=p@ss sslmode=require"

  test "postgresql:// is accepted too, and missing parts are omitted":
    assert conninfoOf("postgresql://u@localhost/app") ==
      "host=localhost dbname=app user=u"

  test "a keyword conninfo passes through untouched":
    let kw = "host=/var/run/postgresql dbname=waku user=waku"
    assert conninfoOf(kw) == kw

suite "what the client sends":
  test "add embeds subject: content and upserts on chunk_id":
    let c = testClient()
    discard c.add("Alex", "runs a robotics startup", "user")
    assert embedCalls == 1
    assert seenQ.len == 1
    assert "ON CONFLICT (chunk_id)" in seenQ[0].sql
    assert "rag_chunks" in seenQ[0].sql
    assert seenQ[0].args[0].startsWith("fact-")
    assert seenQ[0].args[0].len == 17
    assert seenQ[0].args[1] == "alex"
    assert seenQ[0].args[2] == "runs a robotics startup"
    assert seenQ[0].args[3].startsWith("[") and seenQ[0].args[3].endsWith("]")

  test "search ranks by cosine with the limit as $2":
    let c = testClient()
    discard c.search("robotics", 3)
    assert seenQ.len == 1
    assert "<=>" in seenQ[0].sql
    assert "::vector" in seenQ[0].sql
    assert "LIMIT $2" in seenQ[0].sql
    assert seenQ[0].args[1] == "3"

  test "search defaults to the client's topK":
    let c = testClient()
    discard c.search("robotics")
    assert seenQ[0].args[1] == "4"

  test "listing reads newest first with the limit as $1":
    let c = testClient()
    discard c.listRows(50)
    assert "ORDER BY id DESC" in seenQ[0].sql
    assert seenQ[0].args == @["50"]

  test "the column follows the id's shape, and the id stays a parameter":
    assert columnFor("42") == "id"
    assert columnFor("fact-ab12") == "chunk_id"
    assert columnFor("") == "chunk_id"
    assert columnFor("12a") == "chunk_id"
    let c = testClient()
    nextRows = @[@["alex", "sailing"]]
    discard c.update("42", "sails", "")
    discard c.delete("fact-ab12")
    assert "WHERE id = $1" in seenQ[0].sql
    assert "WHERE chunk_id = $1" in seenQ[^1].sql
    for call in seenQ:
      assert "42" notin call.sql and "fact-ab12" notin call.sql,
        "an id interpolated into SQL is an injection: " & call.sql

  test "update with no subject reads it back, then re-embeds":
    # The vector has to move with the text, or the store keeps answering the
    # old question — the silent-wrong-answer failure this pins.
    let c = testClient()
    nextRows = @[@["alex", "sailing"]]
    assert c.update("7", "sails on weekends", "").ok
    assert seenQ[0].sql.startsWith("SELECT source")
    assert seenQ[1].sql.startsWith("UPDATE rag_chunks")
    assert seenQ[1].args[0] == "alex"
    assert seenQ[1].args[1] == "sails on weekends"
    assert embedCalls == 1, "re-embed the rewrite, not the lookup"

  test "update on an unknown id is false and embeds nothing":
    let c = testClient()
    nextRows = @[]
    assert c.update("999", "new", "alex").ok == false
    assert embedCalls == 0, "never pay an embedding for a row that is not there"
    assert seenQ.len == 1, "one lookup, no write: " & $seenQ.len

  test "delete answers affected rows, not exceptions":
    let c = testClient()
    assert c.delete("5").ok
    nextAffected = 0
    assert c.delete("5").ok == false

suite "the shapes the adapter answers with":
  test "search and list map columns to facts, short rows are skipped":
    let c = testClient()
    nextRows = @[@["3", "fact-aa", "alex", "sailing"], @["oops"]]
    let store = pgFactStore(c)
    assert store.searchWithIds("alex", 8)[0].id == "3"
    assert store.search("alex", 8) == @["[alex] sailing"]
    nextRows = @[@["3", "alex", "sailing", "2026-01-01"]]
    let listed = store.list(10)
    assert listed.len == 1 and listed[0].source == ""
    # The column holds the subject, not provenance — parity with Python.

  test "a dead database is empty results and false, never a raise":
    let c = newPgClient("postgres://u:p@localhost:5432/waku", "sk-test",
      query = proc(sql: string, args: seq[string],
                   expectRows: bool): PgAnswer =
        raise newException(IOError, "connection refused"),
      embed = countingEmbed)
    let store = pgFactStore(c)
    store.add("alex", "sailing", "user")
    assert store.search("alex", 4) == @[]
    assert store.list(10) == @[]
    assert store.searchWithIds("alex", 4) == @[]
    assert store.update("1", "new", "") == false
    assert store.delete("1") == false

  test "a dead embeddings call is quiet on the way in and empty on the way out":
    var queries = 0
    let c = newPgClient("postgres://u:p@localhost:5432/waku", "sk-test",
      query = proc(sql: string, args: seq[string],
                   expectRows: bool): PgAnswer =
        inc queries
        PgAnswer(ok: true, rows: @[@["1", "fact-a", "alex", "sailing"]],
                 affected: 1),
      embed = proc(text: string): EmbedAnswer =
        EmbedAnswer(ok: false, detail: "HTTP 401: bad key"))
    let store = pgFactStore(c)
    store.add("alex", "sailing", "user")
    assert queries == 0, "no embedding, no insert"
    assert store.search("alex", 4) == @[]

  test "settle is immediate even when everything is down":
    let c = newPgClient("postgres://u:p@localhost:5432/waku", "sk-test",
      query = proc(sql: string, args: seq[string],
                   expectRows: bool): PgAnswer =
        raise newException(IOError, "gone"),
      embed = proc(text: string): EmbedAnswer =
        EmbedAnswer(ok: false, detail: "gone"))
    assert pgFactStore(c).settle(120000) == true

suite "live gate, opt-in":
  test "round-trips its own rows and deletes them afterwards":
    if getEnv("WAKU_TEST_POSTGRES") != "1" or getEnv("DATABASE_URL").len == 0:
      echo "SKIP live postgres: set WAKU_TEST_POSTGRES=1 and DATABASE_URL"
    else:
      let c = newPgClient(getEnv("DATABASE_URL"), getEnv("OPENAI_API_KEY"))
      let ext = c.query("SELECT 1 FROM pg_extension WHERE extname='vector'",
                        @[], true)
      if not ext.ok or ext.rows.len == 0:
        echo "SKIP live postgres: extension \"vector\" is not installed"
      else:
        let store = pgFactStore(c)
        store.add("waku-test", "the launch moved to wednesday", "user")
        assert store.settle(1000) == true
        let found = store.searchWithIds("waku-test launch wednesday", 8)
        assert found.len > 0, "seeded a fact and could not find it"
        assert store.delete(found[0].id) == true
        assert store.searchWithIds("waku-test launch wednesday", 8) == @[]
