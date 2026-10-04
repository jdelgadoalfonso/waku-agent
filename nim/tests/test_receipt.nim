## The turn receipt in the port (spec 011 group A, unit T2).
##
## The oracle is Python's `evals/deterministic/test_turn_receipt.py`: same
## turn, same events, same dollars ($0.06442 of model time on the example
## turn), the same closed key sets, the same hostile-input case. Offline
## only: the builder is pure, so nothing here touches a file or a socket.

import std/json
import std/strutils
import std/unittest

import ../src/receipt

const haiku = "claude-haiku-4-5-20251001"

# Real keys, shaped like the real thing: far longer than any id, name or
# provider a receipt may hold, which is the whole point of the patterns.
const secrets = ["Bearer sk-ant-api03-AUTHAUTHAUTHAUTHAUTHAUTHAUTHAUTH",
                 "sk-ant-api03-APIKEYAPIKEYAPIKEYAPIKEYAPIKEY",
                 "sk-ant-api03-ECHOECHOECHOECHOECHOECHOECHOECHO"]

proc searchOutput(found: int, trace = ""): string =
  ## A Waku Memory search's answer, as the string a tool event carries.
  var entries = newJArray()
  for i in 0 ..< found:
    entries.add(%*{"id": "m" & $i})
  var outp = %*{"entries": entries}
  if trace.len > 0:
    outp["retrieval_trace_id"] = %trace
  $outp

proc tregOutput(endpoint: string, usd: float): string =
  $(%*{"status": 200, "endpoint_id": endpoint, "cost_usd": usd,
         "body": newJObject()})

proc llm(usageIn, usageOut: int, kind = "", model = ""): (string, JsonNode) =
  ## A loop call names no kind and no model; a side call names both.
  ## The pair kind is always "llm" — it travels as the channel, like
  ## the observer delivers it, never as a field inside the event.
  var ev = %*{"usage": %*{"in": usageIn, "out": usageOut}}
  if kind.len > 0:
    ev["kind"] = %kind
  if model.len > 0:
    ev["model"] = %model
  ("llm", ev)

proc tool(name, output: string, status = ""): (string, JsonNode) =
  var ev = %*{"tool": name, "output": output}
  if status.len > 0:
    ev["status"] = %status
  ("tool", ev)

proc keysOf(node: JsonNode): seq[string] =
  ## An object's keys in insertion order, the way the pinned Python test
  ## reads `tuple(receipt)`.
  result = @[]
  if node.kind == JObject:
    for key in node.keys:
      result.add(key)

proc costs(r: JsonNode): seq[JsonNode] =
  for t in r["tools"]:
    result.add(t["usd"])

suite "receipt key sets":
  test "the keys are a closed set at every level":
    let r = buildReceipt(@[tool("treg_catalog_call_read",
      tregOutput("tomba.email.find", 0.01)),
      tool("waku_memory_memory_search", searchOutput(8)),
      llm(300, 30, "gate", haiku)], "anthropic")
    assert keysOf(r) == receiptKeys
    assert keysOf(r["model"]) == modelKeys
    assert keysOf(r["model"]["calls"][0]) == ["kind", "n"]
    assert keysOf(r["tools"][0]) == toolKeys
    assert keysOf(r["memory"]) == memoryKeys
    assert keysOf(r["memory"]["searches"][0]) == searchKeys
    assert r["memory"]["report"].kind == JNull,
      "no report event in this turn, so a null report"

  test "an empty turn is a zero receipt, not a crash":
    let r = buildReceipt(@[], "anthropic")
    assert keysOf(r) == receiptKeys
    assert keysOf(r["model"]) == modelKeys
    assert keysOf(r["memory"]) == memoryKeys
    assert r["model"]["in"].getInt == 0 and r["model"]["out"].getInt == 0
    assert r["model"]["calls"].len == 0 and r["tools"].len == 0
    assert r["memory"]["searches"].len == 0
    assert r["memory"]["used"].getInt == 0 and r["memory"]["kept"].getInt == 0
    assert r["model"]["usd"].getFloat == 0.0 and r["total_usd"].getFloat == 0.0
    assert r["model"]["estimate"].getBool
    assert r["credits"].kind == JNull
    assert parseJson($r) == r, "a receipt must survive the wire"

suite "counts and dollars":
  test "the example turn from the Python oracle, field for field":
    let events = @[
      llm(300, 30, "gate", haiku),
      tool("waku_memory_memory_search", searchOutput(8)),
      tool("waku_memory_memory_search", searchOutput(4)),
      llm(3000, 400),
      tool("treg_catalog_call_read", tregOutput("tomba.email.find", 0.010)),
      llm(4000, 500),
      tool("treg_catalog_call_read", tregOutput("serp.google.search", 0.020)),
      tool("search_web", "Three results. The first"),
      llm(5000, 950),
      llm(110, 22, "consolidation", haiku),
      ("consolidation", %*{"new_facts": 2})]
    let r = buildReceipt(events, "anthropic")
    # 12,410 in and 1,902 out, 0.06442 est: three Sonnet loop calls plus the
    # gate and the consolidation on Haiku (the loop's own events name no
    # model, so they price at the provider estimate, 3/15 — the same rate
    # Python's Sonnet row pays).
    assert r["model"]["in"].getInt == 12410
    assert r["model"]["out"].getInt == 1902
    assert abs(r["model"]["usd"].getFloat - 0.06442) < 1e-9
    assert r["model"]["estimate"].getBool
    var kinds = newJArray()
    for c in r["model"]["calls"]:
      kinds.add(%*{"kind": c["kind"].getStr(), "n": c["n"].getInt})
    assert kinds == %*[
      %*{"kind": "gate", "n": 1}, %*{"kind": "loop", "n": 3},
      %*{"kind": "consolidation", "n": 1}],
      "calls keep the order the turn made them in"
    # treg twice (a named provider beats the endpoint's first segment),
    # search_web once (its answer is a sentence, so it costs nothing)
    assert r["tools"].len == 3
    assert r["tools"][0]["tool"].getStr == "treg_catalog_call_read"
    assert r["tools"][0]["provider"].getStr == "tomba"
    assert r["tools"][1]["provider"].getStr == "serp"
    assert costs(r) == [%0.01, %0.02, newJNull()]
    for t in r["tools"]:
      assert t["status"].getStr == "ok"
    # memory: two searches, 12 found, no trace id named
    assert r["memory"]["searches"].len == 2
    assert r["memory"]["searches"][0]["found"].getInt == 8
    assert r["memory"]["searches"][1]["found"].getInt == 4
    assert r["memory"]["searches"][0]["trace_id"].kind == JNull
    assert r["memory"]["kept"].getInt == 2
    assert abs(r["total_usd"].getFloat - 0.09442) < 1e-9
    assert r["credits"].kind == JNull

  test "a memory_recall is a search too, and names its trace":
    let r = buildReceipt(@[
      tool("waku_memory_memory_recall", searchOutput(3, "trc-41")),
      tool("waku_memory_memory_search", searchOutput(1))], "anthropic")
    assert r["tools"].len == 0, "a memory tool is never counted as a tool"
    assert r["memory"]["searches"].len == 2
    assert r["memory"]["searches"][0]["tool"].getStr == "memory_recall"
    assert r["memory"]["searches"][0]["trace_id"].getStr == "trc-41"
    assert r["memory"]["searches"][1]["trace_id"].kind == JNull

  test "the local memory search counts as a search too":
    let r = buildReceipt(@[
      tool("engram_mem_search", searchOutput(5))], "openrouter")
    assert r["tools"].len == 0
    assert r["memory"]["searches"] == %*[%*{"tool": "memory_search",
      "found": 5, "trace_id": nil}]

  test "a tool status the caller already knows is not re-guessed":
    let r = buildReceipt(@[tool("search_web", "Three results.", "error")],
                         "anthropic")
    assert r["tools"][0]["status"].getStr == "error"
    assert r["tools"][0]["usd"].kind == JNull

  test "a provider shows only when the answer names what it cost":
    # Python's `tool_cost` returns None without a number, and a None cost
    # takes the provider with it: "treg · $0.030" is the whole claim.
    let r = buildReceipt(@[
      tool("treg_catalog_call_read", $(%*{"provider": "tomba",
        "endpoint_id": "tomba.email.find"})),
      tool("treg_catalog_call_read", $(%*{"cost_usd": 0.0,
        "endpoint_id": "tomba.email.find"}))], "anthropic")
    assert r["tools"][0]["provider"].getStr == ""
    assert r["tools"][0]["usd"].kind == JNull
    assert r["tools"][1]["provider"].getStr == "tomba"
    assert r["tools"][1]["usd"].getFloat == 0.0, "a free call is still $0"
    assert r["total_usd"].getFloat == 0.0

suite "privacy":
  test "no argument or output reaches the receipt":
    # A treg call whose arguments carry a header map and a key, and whose
    # output echoes a key somebody pasted. The arguments are not even in
    # the event: the builder never reads them.
    let leaky = ("tool", %*{"tool": "treg_catalog_call_read",
      "args": %*{"endpoint_id": "tomba.email.find", "api_key": secrets[1],
                 "headers": %*{"Authorization": secrets[0],
                               "X-Treg-Route-Max-Cost": "0.05"}},
      "output": $(%*{"endpoint_id": "tomba.email.find", "cost_usd": 0.01,
                     "body": %*{"echo": secrets[2]},
                     "provider": secrets[2]})})
    let r = buildReceipt(@[leaky], "anthropic")
    let text = $r
    for secret in secrets:
      assert secret notin text, "a key reached the receipt"
    assert r["tools"] == %*[%*{"tool": "treg_catalog_call_read",
      "provider": "tomba", "usd": 0.01, "status": "ok"}]


  test "a name, an id and a provider are held to their short pattern":
    # A provider that is really a key, a trace id with a newline smuggled
    # on the end, and a tool name 65 characters long (one past `_NAME`).
    let r = buildReceipt(@[
      tool("treg_catalog_call_read", $(%*{"cost_usd": 0.5,
        "provider": "sk-ant-api03-" & secrets[1]})),
      tool("waku_memory_memory_search",
        $(%*{"entries": [1], "retrieval_trace_id": "trc-41\n"})),
      tool("t" & "x".repeat(65), "x")], "anthropic")
    assert r["tools"][0]["provider"].getStr == ""
    assert r["memory"]["searches"][0]["trace_id"].kind == JNull,
      r"a trailing newline must fail the pattern, not be trimmed"
    assert r["tools"][1]["tool"].getStr == "tool",
      "a 65-character name reads as 'tool'"

suite "bad input":
  test "a broken event leaves the receipt valid":
    let events = @[
      tool("treg_catalog_call_read", $(%*{"cost_usd": -1})),
      tool("treg_catalog_call_read", $(%*{"new_facts": 0})),
      tool("treg_catalog_call_read", $(%*{"cost_usd": "a lot"})),
      tool("treg_catalog_call_read", $(%*{"cost_usd": true})),
      tool("treg_catalog_call_read", "not json at all"),
      tool("treg_catalog_call_read", "The endpoint failed"),
      tool("waku_memory_memory_search", "Error: timed out"),
      tool("x", ""),
      llm(0, 0),                       # a call that names no usage at all
      ("mystery", %*{"usage": newJNull()}),  # not even a known kind
      ("consolidation", newJObject()),  # and one with no facts
      ("report", %*{"memory_id": "rep-1003"})]
    let r = buildReceipt(events, "anthropic")
    assert r["tools"].len == 7, "six treg rows and the 'x' one; not the search"
    for c in costs(r):
      assert c.kind == JNull, "no number means no dollars"
    assert r["tools"][5]["status"].getStr == "error"
    assert r["tools"][6]["tool"].getStr == "x"
    assert r["tools"][6]["status"].getStr == "ok"
    assert r["memory"]["searches"] == %*[%*{"tool": "memory_search",
      "found": nil, "trace_id": nil}]
    assert r["memory"]["kept"].getInt == 0
    assert r["model"]["in"].getInt == 0 and r["total_usd"].getFloat == 0.0
    assert keysOf(r) == receiptKeys
    assert parseJson($r) == r, "a receipt must survive the wire"

  test "a kind this builder does not read changes nothing":
    let r = buildReceipt(@[("text", %*{"delta": "thinking"}),
                           ("gate", %*{"decision": "skip"}),
                           llm(900, 40)], "anthropic")
    assert r["model"]["in"].getInt == 900
    assert r["tools"].len == 0 and r["memory"]["searches"].len == 0
    assert abs(r["total_usd"].getFloat - 0.0033) < 1e-9,
      "900 in and 40 out at the 3/15 estimate"