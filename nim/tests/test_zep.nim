## Pins for the Zep client — the port of `waku/memory/semantic/zep_store.py`
## against the SDK generation 3.29.0 (`nim/src/zep.nim`).
##
## Two kinds of check, like mem0. The conformance suite in `test_factstore.nim`
## proves the ADAPTER obeys the contract, against a stateful fake. This file
## proves the CLIENT says what the API expects — verb, path and body for every
## call — because a client that posts to the right shape at the wrong path
## answers 404 and every rule still passes against the fake.
##
## Offline by construction: the seam captures and asserts. Nothing here reaches
## `api.getzep.com`, and nothing writes a node into anybody's graph.

import std/json
import std/strutils
import std/unittest

import ../src/zep

type
  Call* = tuple[verb, path, body: string]

var seen: seq[Call] = @[]
var nowMsValue = 0

proc fastClock(): int64 = int64(nowMsValue)
proc fastSleep(ms: int64) = nowMsValue += int(ms)

proc testClient(answer = "{}"): ZepClient =
  seen = @[]
  nowMsValue = 0
  newZepClient("zep-test-key", "waku", send = proc(verb, path,
      body: string): ZepResult =
    seen.add((verb, path, body))
    ZepResult(ok: true, status: 200, body: answer, detail: ""),
    nowMs = fastClock, sleepMs = fastSleep)

suite "the packed blob":
  test "subject and content round-trip, subject lowercased":
    assert packFact("  Alex  ", "runs a robotics startup") ==
      "alex: runs a robotics startup"
    let (subject, content) = unpackFact("alex: runs a robotics startup")
    assert subject == "alex"
    assert content == "runs a robotics startup"

  test "a blob with no separator is all content":
    let (subject, content) = unpackFact("runs a robotics startup")
    assert subject == ""
    assert content == "runs a robotics startup"

suite "what the client puts on the wire":
  test "add ingests text with type and user, then waits on the episode":
    # add blocks until the episode is processed: a benchmark that seeds and
    # immediately queries must not read an empty graph.
    var calls = 0
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        seen.add((verb, path, body))
        inc calls
        if calls == 1:
          return ZepResult(ok: true, status: 200,
            body: """{"uuid_":"ep-1","processed":false}""", detail: "")
        return ZepResult(ok: true, status: 200,
          body: """{"episodes":[{"uuid_":"ep-1","processed":true}]}""",
          detail: ""),
      nowMs = fastClock, sleepMs = fastSleep)
    seen = @[]
    nowMsValue = 0
    let answer = c.add("Alex", "runs a robotics startup", "user")
    assert answer.ok
    assert seen[0][0] == "POST" and seen[0][1] == "/graph"
    let payload = parseJson(seen[0][2])
    assert payload["data"].getStr() == "alex: runs a robotics startup"
    assert payload["type"].getStr() == "text"
    assert payload["user_id"].getStr() == "waku"
    assert seen[1][0] == "GET"
    assert seen[1][1].startsWith("/graph/episodes/user/waku?lastn=")

  test "search posts graph/search with user and limit":
    let c = testClient("""{"edges":[],"nodes":[]}""")
    discard c.search("robotics", 3)
    let (verb, path, body) = seen[0]
    assert verb == "POST"
    assert path == "/graph/search"
    let payload = parseJson(body)
    assert payload["query"].getStr() == "robotics"
    assert payload["limit"].getInt() == 3
    assert payload["user_id"].getStr() == "waku"

  test "listing nodes is a POST with the limit in the body":
    # The trap this pins: node listing is POST, not GET.
    let c = testClient("[]")
    discard c.listNodes(50)
    assert seen[0][0] == "POST"
    assert seen[0][1] == "/graph/node/user/waku"
    assert parseJson(seen[0][2])["limit"].getInt() == 50

  test "node and edge get/delete use their own paths with the id in them":
    let c = testClient("{}")
    discard c.nodeGet("n-7")
    discard c.edgeGet("e-7")
    discard c.nodeDelete("n-7")
    discard c.edgeDelete("e-7")
    assert seen[0][1] == "/graph/node/n-7"
    assert seen[1][1] == "/graph/edge/e-7"
    assert seen[2][0] == "DELETE" and seen[2][1] == "/graph/node/n-7"
    assert seen[3][0] == "DELETE" and seen[3][1] == "/graph/edge/e-7"

  test "an id cannot walk out of the path":
    let c = testClient("{}")
    discard c.nodeDelete("../../v1/ping")
    assert seen[0][1] == "/graph/node/..%2F..%2Fv1%2Fping",
      "unencoded id could address another endpoint: " & seen[0][1]

  test "ensureUser posts the user id":
    let c = testClient("{}")
    discard c.ensureUser()
    assert seen[0][0] == "POST" and seen[0][1] == "/users"
    assert parseJson(seen[0][2])["user_id"].getStr() == "waku"

suite "the shapes the API answers with":
  test "search merges edges and nodes, capped at topK":
    let answer = """{"edges":[{"uuid_":"e-1","fact":"alex: sailing"}],
      "nodes":[{"uuid_":"n-1","summary":"alex: likes tea"}]}"""
    let store = zepFactStore(testClient(answer))
    let rows = store.searchWithIds("alex", 8)
    assert rows.len == 2
    assert rows[0].id == "e-1" and rows[0].content == "sailing"
    assert rows[1].id == "n-1" and rows[1].content == "likes tea"
    assert store.search("alex", 8) == @["[alex] sailing", "[alex] likes tea"]

  test "a node list becomes list rows with source zep":
    let answer = """[{"uuid_":"n-2","name":"alex: quay"}]"""
    let rows = zepFactStore(testClient(answer)).list(10)
    assert rows.len == 1
    assert rows[0].id == "n-2"
    assert rows[0].source == "zep"
    assert rows[0].subject == "alex"

  test "an answer that is not JSON is no rows, not a crash":
    let store = zepFactStore(testClient("<html>502 Bad Gateway</html>"))
    assert store.list(10) == @[]
    assert store.search("alex", 4) == @[]

suite "settle waits for the graph, not the episodes":
  test "an empty graph settles immediately":
    # Nothing seeded — usually the arena's control contestant. Timing out
    # here would punish the contestant that wrote nothing.
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        seen.add((verb, path, body))
        if verb == "GET":
          return ZepResult(ok: true, status: 200,
            body: """{"episodes":[]}""", detail: "")
        return ZepResult(ok: true, status: 200, body: "[]", detail: ""),
      nowMs = fastClock, sleepMs = fastSleep)
    seen = @[]
    nowMsValue = 0
    assert c.settle(1000) == true

  test "processed episodes with zero nodes are NOT settled":
    # The live run that motivated the double event: every episode done, no
    # nodes yet. Settle must keep waiting instead of handing out a green
    # light for an empty graph.
    var polls = 0
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        seen.add((verb, path, body))
        if verb == "GET":
          return ZepResult(ok: true, status: 200,
            body: """{"episodes":[{"uuid_":"ep-1","processed":true}]}""",
            detail: "")
        return ZepResult(ok: true, status: 200, body: "[]", detail: ""),
      nowMs = proc(): int64 = int64(polls * 2000),
      sleepMs = proc(ms: int64) = inc polls)
    assert c.settle(3000) == false

  test "episodes done plus a still node count settles":
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        seen.add((verb, path, body))
        if verb == "GET":
          return ZepResult(ok: true, status: 200,
            body: """{"episodes":[{"uuid_":"ep-1","processed":true}]}""",
            detail: "")
        return ZepResult(ok: true, status: 200,
          body: """[{"uuid_":"n-1","summary":"alex: sailing"}]""", detail: ""),
      nowMs = fastClock, sleepMs = fastSleep)
    seen = @[]
    nowMsValue = 0
    assert c.settle(30000) == true

suite "failures answer, they never raise":
  test "a raising sender becomes empty results and false":
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        raise newException(IOError, "connection refused"),
      nowMs = fastClock, sleepMs = fastSleep)
    let store = zepFactStore(c)
    store.add("alex", "sailing", "user")
    assert store.search("alex", 4) == @[]
    assert store.list(10) == @[]
    assert store.searchWithIds("alex", 4) == @[]
    assert store.update("n-1", "new", "") == false
    assert store.delete("n-1") == false

  test "update on an unknown id is false without ingesting":
    # Unknown ids 404 on both gets; only then must update refuse to ingest.
    # (A sender that answers ok to everything would make exists() true —
    # that is a broken fake, not a broken client.)
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        seen.add((verb, path, body))
        if verb == "GET":
          return ZepResult(ok: false, status: 404, body: "{}", detail: "no")
        return ZepResult(ok: true, status: 200, body: "{}", detail: ""),
      nowMs = fastClock, sleepMs = fastSleep)
    seen = @[]
    let store = zepFactStore(c)
    assert store.update("missing", "new content", "alex") == false
    for call in seen:
      assert call.path != "/graph", "ingested a correction for unknown id"

  test "delete tries the node, then the edge":
    var calls = 0
    let c = newZepClient("zep-test-key", "waku",
      send = proc(verb, path, body: string): ZepResult =
        seen.add((verb, path, body))
        inc calls
        if calls == 1:
          return ZepResult(ok: false, status: 404, body: "{}", detail: "no")
        return ZepResult(ok: true, status: 200, body: "{}", detail: ""),
      nowMs = fastClock, sleepMs = fastSleep)
    seen = @[]
    assert zepFactStore(c).delete("e-9") == true
    assert seen[0][1] == "/graph/node/e-9"
    assert seen[1][1] == "/graph/edge/e-9"
