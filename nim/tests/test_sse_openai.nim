## Phase 3b tests: OpenAI SSE reassembly gate. Pure and offline: parsed
## chunk objects in, assembled message out. The chunk sequences below mirror
## real `chat.completions` streams with `stream_options.include_usage`.

import std/json
import std/unittest

import ../src/sse

proc feedAll(chunks: JsonNode): tuple[state: OpenAiSse, deltas: seq[string]] =
  var st: OpenAiSse
  var deltas: seq[string] = @[]
  for c in chunks:
    for d in feedOpenAi(st, c):
      deltas.add(d)
  (st, deltas)

suite "phase 3b openai reassembly":
  test "text across chunks plus a usage tail assembles":
    let (st, deltas) = feedAll(%*[
      {"choices": [{"delta": {"content": "Hello"}}]},
      {"choices": [{"delta": {"content": " world"}}]},
      {"choices": [], "usage": {"prompt_tokens": 7, "completion_tokens": 2}}])
    assert deltas == @["Hello", " world"]
    let msg = finalOpenAi(st)
    assert msg["content"] == %*[{"type": "text", "text": "Hello world"}]
    assert msg["usage"] == %*{"in": 7, "out": 2}
    assert msg["stop_reason"].getStr() == "end_turn"

  test "one tool call reassembles across split args":
    let (st, _) = feedAll(%*[
      {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "t1",
        "function": {"name": "ping", "arguments": ""}}]}}]},
      {"choices": [{"delta": {"tool_calls": [{"index": 0,
        "function": {"arguments": "{\"loud\":"}}]}}]},
      {"choices": [{"delta": {"tool_calls": [{"index": 0,
        "function": {"arguments": "true}"}}]}}]}])
    let msg = finalOpenAi(st)
    assert msg["stop_reason"].getStr() == "tool_use"
    assert msg["content"] == %*[{"type": "tool_use", "id": "t1",
      "name": "ping", "input": {"loud": true}}]

  test "two interleaved calls keep index order with mixed text":
    let (st, deltas) = feedAll(%*[
      {"choices": [{"delta": {"content": "on it",
        "tool_calls": [{"index": 1, "id": "tB",
          "function": {"name": "b", "arguments": "{\"x\":2}"}}]}}]},
      {"choices": [{"delta": {
        "tool_calls": [{"index": 0, "id": "tA",
          "function": {"name": "a", "arguments": "{}"}}]}}]}])
    assert deltas == @["on it"]
    let msg = finalOpenAi(st)
    assert msg["content"][0] == %*{"type": "text", "text": "on it"}
    assert msg["content"][1]["id"].getStr() == "tB"
    assert msg["content"][2]["id"].getStr() == "tA"

  test "empty args become an empty object":
    let (st, _) = feedAll(%*[
      {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "t1",
        "function": {"name": "ping"}}]}}]}])
    assert finalOpenAi(st)["content"][0]["input"] == %*{}

  test "truncated args raise instead of calling with garbage":
    let (st, _) = feedAll(%*[
      {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "t1",
        "function": {"name": "ping", "arguments": "{\"loud\":"}}]}}]}])
    try:
      discard finalOpenAi(st)
      assert false, "must raise"
    except JsonParsingError:
      discard
