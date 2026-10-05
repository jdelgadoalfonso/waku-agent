## Pins for the LangMem store — the port of
## `waku/memory/semantic/langmem_store.py` in its default in-process mode
## (`nim/src/langmem.nim`).
##
## Two kinds of check, like every backend. The conformance suite in
## `test_factstore.nim` proves the ADAPTER obeys the contract, against the
## hand-written `langmemFakeStore`. This file proves the CLIENT keeps the
## reference semantics — prefix, canonical JSON, overwrite-with-re-embed,
## cosine ranking without threshold — because the fake cannot prove what only
## the client does.
##
## Offline by construction: the embed seam is injected, and NOTHING here
## spends an embedding. The ranking pins use hand-made vectors so order is
## exact, never hash-luck.

import std/json
import std/strutils
import std/unittest

import ../src/langmem
import factstore_fakes

var embedTextsSeen: seq[seq[string]] = @[]
var embedCalls = 0

proc cannedTable(texts: seq[string]): EmbedBatch =
  ## Vectors by content, fully deterministic: the query "qq" is [1,0], rows
  ## containing "alpha" are [1,0], rows containing "beta" are [0,1],
  ## everything else is [0.2,0.9]. Shared tokens are irrelevant here — the
  ## table, not the hash, decides.
  inc embedCalls
  var vecs: seq[seq[float32]] = @[]
  for t in texts:
    if t == "qq" or "alpha" in t: vecs.add(@[1.0f32, 0.0f32])
    elif "beta" in t: vecs.add(@[0.0f32, 1.0f32])
    else: vecs.add(@[0.2f32, 0.9f32])
  EmbedBatch(ok: true, vecs: vecs)

proc testClient(): LangMemClient =
  embedTextsSeen = @[]
  embedCalls = 0
  newLangMemClient("sk-test",
    embedTexts = proc(texts: seq[string]): EmbedBatch =
      embedTextsSeen.add(texts)
      cannedTable(texts))

suite "identity and packing":
  test "the namespace packs with the unit separator":
    assert langmemPrefix == "waku\x1ffacts"

  test "the model keeps its provider prefix until the wire":
    assert parseEmbedModel("openai:text-embedding-3-small") ==
      "text-embedding-3-small"
    assert parseEmbedModel("text-embedding-3-small") == "text-embedding-3-small"

  test "what gets embedded is the whole value as canonical JSON":
    let c = testClient()
    assert c.add("Alex", "sailing", "user")
    assert embedTextsSeen.len == 1
    let payload = parseJson(embedTextsSeen[0][0])
    assert payload["subject"].getStr() == "alex"
    assert payload["content"].getStr() == "sailing"
    assert payload["source"].getStr() == "user"
    # Canonical means byte-stable: same value, same text, every process.
    assert embedTextsSeen[0][0] ==
      """{"content":"sailing","source":"user","subject":"alex"}"""

suite "put/get/delete":
  test "add then get round-trips, subject lowered":
    let c = testClient()
    assert c.add("Alex", "sailing", "user")
    assert c.rows.len == 1
    let (found, row) = c.get(c.rows[0].key)
    assert found and row.subject == "alex" and row.content == "sailing"
    assert row.key.startsWith("fact-") and row.key.len == 17

  test "get on a missing key is false, not an exception":
    let c = testClient()
    let (found, _) = c.get("fact-nope")
    assert found == false

  test "delete checks first: missing is false":
    let c = testClient()
    assert c.delete("fact-nope") == false
    assert c.add("a", "b", "user")
    assert c.delete(c.rows[0].key) == true
    assert c.rows.len == 0

  test "a failed embedding stores nothing":
    let c = newLangMemClient("sk-test",
      embedTexts = proc(texts: seq[string]): EmbedBatch =
        EmbedBatch(ok: false, detail: "HTTP 401: bad key"))
    assert c.add("alex", "sailing", "user") == false
    assert c.rows.len == 0, "a vectorless row would silently skip every search"

suite "update merges and re-embeds":
  test "put over a key keeps created_at and refreshes the vector":
    let c = testClient()
    assert c.add("alex", "sailing", "user")
    let key = c.rows[0].key
    let born = c.rows[0].createdAt
    assert c.update(key, "sails on weekends", "") == true
    assert c.rows[0].createdAt == born
    assert c.rows[0].content == "sails on weekends"
    assert c.rows[0].subject == "alex", "empty subject keeps the stored one"
    assert embedCalls == 2, "add embeds once, update re-embeds once"
    assert "weekends" in embedTextsSeen[1][0]

  test "update on a missing key is false and embeds nothing":
    let c = testClient()
    assert c.update("fact-nope", "new", "alex") == false
    assert embedCalls == 0

suite "ranking without threshold":
  test "cosine orders, best first":
    let c = testClient()
    assert c.add("t", "alpha facts here", "user")
    assert c.add("t", "beta facts here", "user")
    let ranked = c.searchRows("qq", 8)
    assert ranked.len == 2
    assert "alpha" in ranked[0].content
    assert "beta" in ranked[1].content

  test "a nonsense query returns the closest rows, not empty":
    # Upstream parity, stated in the module header: [] means an empty store
    # or dead embeddings, never "no match". The conformance fake is
    # deliberately stricter so the suite stays deterministic.
    let c = testClient()
    assert c.add("t", "alpha facts here", "user")
    assert c.searchRows("zzz-no-signal", 8).len == 1

  test "an empty store searches empty, and topK caps":
    let c = testClient()
    assert c.searchRows("qq", 8) == @[]
    assert c.add("t", "alpha one", "user")
    assert c.add("t", "alpha two", "user")
    assert c.searchRows("qq", 1).len == 1

  test "list is newest-first":
    let c = testClient()
    assert c.add("t", "alpha one", "user")
    assert c.add("t", "alpha two", "user")
    # Same-second stamps collide, so force an order the clock did not give.
    c.rows[0].createdAt = "2026-01-01T00:00:01Z"
    c.rows[1].createdAt = "2026-01-01T00:00:02Z"
    let listed = c.listRows(10)
    assert listed[0].content == "alpha two"
    assert listed[1].content == "alpha one"

suite "failures answer, they never raise":
  test "a raising embedder becomes empty results and false":
    let c = newLangMemClient("sk-test",
      embedTexts = proc(texts: seq[string]): EmbedBatch =
        raise newException(IOError, "connection refused"))
    let store = langmemFactStore(c)
    store.add("alex", "sailing", "user")
    assert store.search("alex", 4) == @[]
    assert store.list(10) == @[]
    assert store.searchWithIds("alex", 4) == @[]
    assert store.update("fact-1", "new", "") == false
    assert store.delete("fact-1") == false
    assert store.settle(1000) == true

  test "search formats subject, and bare content without one":
    let store = langmemFactStore(testClient())
    store.add("alex", "sailing", "user")
    store.add("", "just words", "user")
    # Same score by construction (identical fallback vectors), so order is
    # unspecified — assert the SET, not the sequence.
    let hits = store.search("qq", 8)
    assert hits.len == 2
    assert "[alex] sailing" in hits and "just words" in hits
