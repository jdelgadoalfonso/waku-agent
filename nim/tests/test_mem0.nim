## Pins for the mem0 client — the port of `waku/memory/semantic/mem0_store.py`
## against v3 (`nim/src/mem0.nim`).
##
## Two kinds of check, and the split matters. The conformance suite in
## `test_factstore.nim` proves the ADAPTER obeys the contract, against a stateful
## fake. This file proves the CLIENT says what v3 expects — verb, path, headers
## and body for every call — because a client that posts to the right shape at
## the wrong path answers 404 and every rule still passes against the fake.
##
## Offline by construction: the seam captures and asserts, and the ONE real
## socket is a threaded stub on `127.0.0.1` (the precedent in `test_http.nim`).
## Nothing here reaches `api.mem0.ai`, and nothing writes a memory into anybody's
## account — which is exactly why Python gates its mem0 checks behind
## `WAKU_TEST_MEM0=1`.

import std/json
import std/net
import std/unittest

import ../src/mem0

type
  Call* = tuple[verb, path, body: string]
    ## One captured request. A tuple keeps the recording trivial; the value is
    ## in the assertions below.

var seen: seq[Call] = @[]
var nextAnswer = ""

proc recording(verb, path, body: string): Mem0Result =
  seen.add((verb, path, body))
  Mem0Result(ok: true, status: 200, body: nextAnswer, detail: "")

proc testClient(answer = "{}"): Mem0Client =
  ## A client with deterministic seams: the recording sender, a clock that only
  ## moves when a test says so, and a sleep that does not sleep. `settle`
  ## otherwise waits 2s per poll, which is 2s of nothing per test.
  seen = @[]
  nextAnswer = answer
  newMem0Client("m0-test-key", "waku", send = recording)

suite "the packed blob":
  test "subject and content round-trip, subject lowercased":
    assert packFact("  Alex  ", "runs a robotics startup") ==
      "alex: runs a robotics startup"
    let (subject, content) = unpackFact("alex: runs a robotics startup")
    assert subject == "alex"
    assert content == "runs a robotics startup"

  test "a blob with no separator is all content":
    ## Splitting it would invent a subject and then store the user's sentence
    ## in a field called subject — the round trip has to survive whatever the
    ## service already holds.
    let (subject, content) = unpackFact("runs a robotics startup")
    assert subject == ""
    assert content == "runs a robotics startup"
    let (emptySubject, emptyContent) = unpackFact("")
    assert emptySubject == "" and emptyContent == ""

suite "what the client puts on the wire":
  test "add posts v3 with user_id at the top level and NO infer":
    # v3 accepts entity ids at the top level, and `infer` is GONE in v3: it is
    # the additive pipeline, extraction always runs. Sending an `infer` flag
    # the API no longer knows would be a promise this client cannot keep.
    let c = testClient("""{"event_id":"evt-7"}""")
    discard c.add("Alex", "runs a robotics startup", "user")
    assert seen.len == 1
    let (verb, path, body) = seen[0]
    assert verb == "POST"
    assert path == "/v3/memories/add/"
    let payload = parseJson(body)
    assert payload["user_id"].getStr() == "waku"
    assert payload["metadata"]["source"].getStr() == "user"
    assert payload["messages"][0]["role"].getStr() == "user"
    assert payload["messages"][0]["content"].getStr() ==
      "alex: runs a robotics startup"
    assert "infer" notin payload,
      "v3 has no infer flag; sending one pretends add() still stores verbatim"

  test "search posts v3 with the entity id inside filters":
    # The SDK raises on a top-level `user_id` for search and the API answers
    # 400: in v3 search the entity id goes inside `filters`.
    let c = testClient("""{"results":[]}""")
    discard c.search("robotics", 3)
    let (verb, path, body) = seen[0]
    assert verb == "POST"
    assert path == "/v3/memories/search/"
    let payload = parseJson(body)
    assert payload["query"].getStr() == "robotics"
    assert payload["top_k"].getInt() == 3
    assert payload["filters"]["user_id"].getStr() == "waku"
    assert "user_id" notin payload, "search wants the id inside filters"

  test "get_all posts (not GETs) v3 with the limit as the page size":
    let c = testClient("""{"results":[]}""")
    discard c.getAllRows(50)
    let (verb, path, body) = seen[0]
    assert verb == "POST"
    assert path == "/v3/memories/"
    let payload = parseJson(body)
    assert payload["page"].getInt() == 1
    assert payload["page_size"].getInt() == 50
    assert payload["filters"]["user_id"].getStr() == "waku"

  test "update and delete use the v1 paths with the id in them":
    let c = testClient("{}")
    discard c.update("mem-7", "alex: ships in June")
    discard c.delete("mem-7")
    assert seen[0][0] == "PUT" and seen[0][1] == "/v1/memories/mem-7/"
    assert parseJson(seen[0][2])["text"].getStr() == "alex: ships in June"
    assert seen[1][0] == "DELETE" and seen[1][1] == "/v1/memories/mem-7/"

  test "an id cannot walk out of the path":
    ## The id is an opaque string from a foreign system, so it gets encoded
    ## rather than pasted into the URL.
    let c = testClient("{}")
    discard c.delete("../../v1/ping")
    assert seen[0][1] == "/v1/memories/..%2F..%2Fv1%2Fping/",
      "an unencoded id could address a different endpoint: " & seen[0][1]

suite "the shapes the API answers with":
  test "results, memories and a bare list are all rows":
    # The hosted API has answered with all three across versions. Pinning to
    # whichever shipped the day this was written makes an adapter that breaks
    # on a minor API bump, which is worse than no adapter.
    let answers = [
      """{"results":[{"id":"a","memory":"alex: sailing","metadata":{"source":"user"}}]}""",
      """{"memories":[{"id":"b","text":"alex: sailing"}]}""",
      """[{"id":"c","memory":"alex: sailing"}]"""]
    for answer in answers:
      # Through the contract, not through the client: the client's job is the
      # wire, and the adapter is what turns a payload into a fact. A pin that
      # called the client directly would prove a shape neither user ever sees.
      let store = mem0FactStore(testClient(answer))
      assert store.list(10).len == 1, "not read: " & answer
      assert store.search("alex", 4) == @["[alex] sailing"],
        "not formatted: " & answer

  test "a row answers its id and its source, whichever field carries them":
    let rows = mem0FactStore(testClient(
      """[{"memory_id":"d","memory":"alex: sailing","metadata":{"source":"consolidation"}}]""")).list(10)
    assert rows.len == 1
    assert rows[0].id == "d"
    assert rows[0].source == "consolidation"
    assert rows[0].subject == "alex"

  test "an answer that is not JSON is no rows, not a crash":
    # A memory backend that throws takes the whole turn down with it.
    let store = mem0FactStore(testClient("<html>502 Bad Gateway</html>"))
    assert store.list(10) == @[]
    assert store.search("alex", 4) == @[]

suite "settle asks instead of guessing":
  test "nothing pending settles immediately":
    # The arena's control contestant seeds nothing at all, and a local store is
    # never slower than this: no event, no waiting.
    let c = testClient()
    assert c.settle(50) == true
    assert seen.len == 0, "with nothing pending it must not even call home"

  test "a done event settles and clears":
    let c = testClient("""{"event_id":"evt-7"}""")
    discard c.add("Alex", "runs a robotics startup", "user")
    nextAnswer = """{"status":"DONE"}"""
    assert c.settle(1000) == true
    assert c.pendingEvent == "", "a settled event must not be waited on again"
    assert seen[0][1] == "/v3/memories/add/"
    assert seen[1][0] == "GET" and seen[1][1] == "/v1/event/evt-7/"

  test "an event still running is polled until it finishes":
    let c = testClient("""{"event_id":"evt-7"}""")
    discard c.add("Alex", "runs a robotics startup", "user")
    # Two polls say pending, the third says done: this is the case Python
    # handles by watching a row count stop moving, and the reason this is the
    # first integration with a real readiness signal.
    var answers = ["""{"status":"PENDING"}""", """{"status":"PROCESSING"}""",
                   """{"status":"COMPLETED"}"""]
    # One clock, in milliseconds, so the timeout is readable next to the
    # 2000ms poll interval instead of being a unit conversion in disguise.
    var sleptMs, polls = 0
    c.nowMs = proc(): int64 = int64(sleptMs)
    c.sleepMs = proc(ms: int64) = sleptMs += int(ms)
    # Indexed by POLLS, not by `seen.len`: the add above already used the
    # recording sender, so counting captured calls would start the answer
    # sequence one step late and pass for the wrong reason.
    c.send = proc(verb, path, body: string): Mem0Result =
      seen.add((verb, path, body))
      let answer = answers[min(polls, answers.len - 1)]
      inc polls
      Mem0Result(ok: true, status: 200, body: answer, detail: "")
    assert c.settle(30000) == true
    assert seen.len == 4, "add plus three polls: " & $seen.len
    assert sleptMs >= 4000, "each poll waits, which is the cost of asking"

  test "a failed event is not settled, and an unknown shape is not settled":
    # An answer nobody recognises must read as "not yet", or settle hands out
    # a green light for a write that may not have landed.
    for answer in ["""{"status":"FAILED"}""", """{"unexpected":"shape"}""", "nonsense"]:
      let c = testClient("""{"event_id":"evt-7"}""")
      discard c.add("Alex", "runs a robotics startup", "user")
      nextAnswer = answer
      var sleptMs = 0
      c.nowMs = proc(): int64 = int64(sleptMs)
      c.sleepMs = proc(ms: int64) = sleptMs += int(ms)
      c.send = proc(verb, path, body: string): Mem0Result =
        seen.add((verb, path, body))
        Mem0Result(ok: true, status: 200,
                   body: if seen.len == 1: """{"event_id":"evt-7"}""" else: answer,
                   detail: "")
      assert c.settle(1000) == false, "settled on: " & answer

suite "failures answer, they never raise":
  test "a raising sender becomes empty results and false":
    # The contract's first rule. A memory backend that throws takes the whole
    # turn down with it, so every one of these has to come back as a value.
    let c = newMem0Client("m0-test-key", "waku",
                          send = proc(verb, path, body: string): Mem0Result =
                            raise newException(IOError, "connection refused"))
    let store = mem0FactStore(c)
    store.add("alex", "sailing", "user")
    assert store.search("alex", 4) == @[]
    assert store.list(10) == @[]
    assert store.searchWithIds("alex", 4) == @[]
    assert store.update("mem-1", "new", "") == false
    assert store.delete("mem-1") == false

  test "a 500 is the same shape as a dead socket":
    let c = newMem0Client("m0-test-key", "waku",
                          send = proc(verb, path, body: string): Mem0Result =
                            Mem0Result(ok: false, status: 500,
                                       body: """{"detail":"quota"}""",
                                       detail: "HTTP 500: {\"detail\":\"quota\"}"))
    let store = mem0FactStore(c)
    assert store.search("alex", 4) == @[]
    assert store.delete("mem-1") == false

  test "update with no subject reads it back first":
    # mem0 stores one blob, so a subject-only edit has to rewrite all of it.
    # Without the read-back the subject would be erased, and that is silent:
    # the fact still searches, it just belongs to nobody.
    let c = testClient("""[{"id":"mem-9","memory":"alex: sailing"}]""")
    let store = mem0FactStore(c)
    assert store.update("mem-9", "sails on weekends", "") == true
    var rewrote = ""
    for call in seen:
      if call.verb == "PUT":
        rewrote = parseJson(call.body)["text"].getStr()
    assert rewrote == "alex: sails on weekends",
      "the subject was lost in the rewrite: " & rewrote