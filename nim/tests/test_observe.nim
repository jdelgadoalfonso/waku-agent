## Observe — port of the v2 core of `waku/ops/observability.py`.
##
## Offline only: pure functions over stub events, no model, no files
## (except the mcp.json probe, which points at temp dirs).

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/observe

suite "tool source":
  test "prefixes sort every tool":
    assert toolSource("treg_search", @[]) == "treg"
    assert toolSource("waku_memory_memory_search", @[]) == "waku_memory"
    assert toolSource("echo", @[]) == "local"
    assert toolSource("", @[]) == "local"
    assert toolSource("engram_mem_search", @["engram"]) == "mcp:engram"
    assert toolSource("engram_mem_search", @[]) == "local"
    assert toolSource("treg_search", @["treg"]) == "treg",
      "treg and waku_memory are never mcp servers"

suite "span kind":
  test "memory reads and writes sort out, the rest is tool":
    assert spanKind("waku_memory_memory_search") == "retrieval"
    assert spanKind("waku_memory_memory_recall") == "retrieval"
    assert spanKind("waku_memory_memory_get") == "retrieval"
    assert spanKind("waku_memory_memory_remember") == "memory_write"
    assert spanKind("waku_memory_memory_forget") == "memory_write"
    assert spanKind("waku_memory_memory_import") == "memory_write"
    assert spanKind("echo") == "tool"
    assert spanKind("treg_search") == "tool"

suite "tool type":
  test "datastore, extension, function":
    assert toolType("waku_memory") == "datastore"
    assert toolType("local") == "function"
    assert toolType("treg") == "extension"
    assert toolType("mcp:engram") == "extension"

suite "redact":
  test "secret keys and key-shaped strings become stars":
    let clean = redact(%*{"query": "rival prices",
      "api_key": "sk-abcdef1234567890"})
    assert clean["query"].getStr() == "rival prices"
    assert clean["api_key"].getStr() == "***"
    let nested = redact(%*{"a": {"token": "x", "ok": 1},
      "b": ["Bearer abcdef1234567890"]})
    assert nested["a"]["token"].getStr() == "***"
    assert nested["a"]["ok"].getInt() == 1
    assert nested["b"][0].getStr() == "***"

suite "trace args":
  test "short args stay an object, long ones one trimmed string":
    let short = traceArgs(%*{"query": "x"})
    assert short.kind == JObject
    assert short["query"].getStr() == "x"
    let big = traceArgs(%*{"query": "y".repeat(600)})
    assert big.kind == JString
    assert big.getStr().len <= argsChars + 2,
      "499 bytes ASCII + the 3-byte ellipsis, like digest's cap"
    assert big.getStr().endsWith("…")

suite "outcome":
  test "failed lines fail, quoted failures do not":
    let (ok1, _) = outcome("failed boom")
    assert not ok1
    let (ok2, err2) = outcome("Error: down")
    assert not ok2 and err2.len > 0
    let (ok3, _) = outcome("timed out after 3s")
    assert not ok3
    let (ok4, _) = outcome("ok done")
    assert ok4
    let (ok5, _) = outcome("a clean first line\nquoting \"failed\" mid-article is fine")
    assert ok5, "only the first line is read"
    let (ok6, err6) = outcome("""{"status": 500, "error": "bad"}""")
    assert not ok6 and "bad" in err6
    let (ok7, _) = outcome("""{"status": 200}""")
    assert ok7

suite "describe":
  test "a plain local call":
    let d = describe(%*{"tool": "echo", "args": %*{"text": "hi"},
      "output": "echo:hi"})
    assert d["source"].getStr() == "local"
    assert d["span"].getStr() == "tool"
    assert d["ok"].getBool()
    assert not d.hasKey("error")

  test "a failure carries its first line":
    let d = describe(%*{"tool": "echo", "args": %*{},
      "output": "failed boom\nsecond line here"})
    assert not d["ok"].getBool()
    assert d["error"].getStr() == "failed boom\nsecond line here"

  test "a treg answer names its cost and provider":
    let d = describe(%*{"tool": "treg_search", "args": newJObject(),
      "output": $(%*{"cost_usd": 0.007, "provider": "tomba",
        "endpoint_id": "tomba.email.find"})})
    assert d["source"].getStr() == "treg"
    assert d["cost_usd"].getFloat() == 0.007
    assert d["provider"].getStr() == "tomba"
    assert d["endpoint_id"].getStr() == "tomba.email.find"

  test "a memory search keeps query, counts and ids":
    let d = describe(%*{"tool": "waku_memory_memory_search",
      "args": %*{"query": "rivals"},
      "output": $(%*{"entries": [{"id": "a"}, {"id": "b"}, {"x": 1}],
        "retrieval_trace_id": "rt_1"})})
    assert d["span"].getStr() == "retrieval"
    assert d["query"].getStr() == "rivals"
    assert d["results"].getInt() == 3
    assert d["memory_ids"] == %*["a", "b"]
    assert d["retrieval_trace_id"].getStr() == "rt_1"

  test "a v2 line's own fields win over derivation":
    let d = describe(%*{"tool": "echo", "args": %*{}, "output": "hi",
      "v": 2, "source": "treg", "ok": false})
    assert d["source"].getStr() == "treg"
    assert not d["ok"].getBool()

suite "genai attributes":
  test "an llm event maps providers, model, usage and chat":
    let a = genaiAttributes("llm", %*{"provider": "anthropic",
      "model": "m", "usage": {"in": 10, "out": 5},
      "stop_reason": "end_turn"})
    assert a["gen_ai.provider.name"].getStr() == "anthropic"
    assert a["gen_ai.request.model"].getStr() == "m"
    assert a["gen_ai.usage.input_tokens"].getInt() == 10
    assert a["gen_ai.usage.output_tokens"].getInt() == 5
    assert a["gen_ai.response.finish_reasons"] == %*["end_turn"]
    assert a["gen_ai.operation.name"].getStr() == "chat"

  test "a memory read maps names, counts and the store":
    let a = genaiAttributes("tool", %*{"tool": "waku_memory_memory_search",
      "source": "waku_memory", "span": "retrieval", "query": "q",
      "results": 2, "call_id": "c1", "cost_usd": 0.01})
    assert a["gen_ai.tool.name"].getStr() == "waku_memory_memory_search"
    assert a["gen_ai.memory.query.text"].getStr() == "q"
    assert a["gen_ai.memory.record.count"].getInt() == 2
    assert a["gen_ai.operation.name"].getStr() == "search_memory"
    assert a["gen_ai.tool.type"].getStr() == "datastore"
    assert a["gen_ai.memory.store.id"].getStr() == "waku_memory"
    assert a["waku.cost.usd"].getFloat() == 0.01

suite "mcp server names":
  test "missing or broken mcp.json reads as no servers":
    assert mcpServerNames("/nonexistent-dir-xyz") == @[]
    let home = getTempDir() / "observe_probe"
    createDir(home)
    writeFile(home / "mcp.json", "not json")
    assert mcpServerNames(home) == @[]
    writeFile(home / "mcp.json",
      """{"servers": [{"name": "a"}, {"name": "engram"}, {"x": 1}]}""")
    assert mcpServerNames(home) == @["engram", "a"]
