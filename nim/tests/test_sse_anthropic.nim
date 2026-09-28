## Phase 3c tests: Anthropic SSE reassembly gate. Pure and offline: parsed
## event objects in, assembled message out. The sequences below mirror real
## `POST /v1/messages` streams (message_start, content_block_start, deltas,
## message_delta with usage, message_stop).

import std/json
import std/unittest

import ../src/sse

proc feedAll(events: JsonNode): tuple[state: AnthropicSse, deltas: seq[string]] =
  var st: AnthropicSse
  var deltas: seq[string] = @[]
  for e in events:
    for d in feedAnthropic(st, e):
      deltas.add(d)
  (st, deltas)

suite "phase 3c anthropic reassembly":
  test "text message assembles with usage and stop reason":
    let (st, deltas) = feedAll(%*[
      {"type": "message_start",
       "message": {"usage": {"input_tokens": 12, "output_tokens": 0}}},
      {"type": "content_block_start", "index": 0,
       "content_block": {"type": "text", "text": ""}},
      {"type": "content_block_delta", "index": 0,
       "delta": {"type": "text_delta", "text": "Hello"}},
      {"type": "content_block_delta", "index": 0,
       "delta": {"type": "text_delta", "text": " there"}},
      {"type": "content_block_stop", "index": 0},
      {"type": "message_delta",
       "delta": {"stop_reason": "end_turn"},
       "usage": {"output_tokens": 4}},
      {"type": "message_stop"}])
    assert deltas == @["Hello", " there"]
    let msg = finalAnthropic(st)
    assert msg["content"] == %*[{"type": "text", "text": "Hello there"}]
    assert msg["stop_reason"].getStr() == "end_turn"
    assert msg["usage"] == %*{"in": 12, "out": 4}

  test "tool_use reassembles split input_json":
    let (st, _) = feedAll(%*[
      {"type": "message_start",
       "message": {"usage": {"input_tokens": 20, "output_tokens": 0}}},
      {"type": "content_block_start", "index": 0,
       "content_block": {"type": "tool_use", "id": "tu_1", "name": "ping"}},
      {"type": "content_block_delta", "index": 0,
       "delta": {"type": "input_json_delta", "partial_json": "{\"loud\":"}},
      {"type": "content_block_delta", "index": 0,
       "delta": {"type": "input_json_delta", "partial_json": " true}"}},
      {"type": "content_block_stop", "index": 0},
      {"type": "message_delta",
       "delta": {"stop_reason": "tool_use"},
       "usage": {"output_tokens": 9}},
      {"type": "message_stop"}])
    let msg = finalAnthropic(st)
    assert msg["stop_reason"].getStr() == "tool_use"
    assert msg["content"] == %*[{"type": "tool_use", "id": "tu_1",
      "name": "ping", "input": {"loud": true}}]

  test "mixed text and tool with ping ignored":
    let (st, deltas) = feedAll(%*[
      {"type": "message_start",
       "message": {"usage": {"input_tokens": 5, "output_tokens": 0}}},
      {"type": "ping"},
      {"type": "content_block_start", "index": 0,
       "content_block": {"type": "text", "text": ""}},
      {"type": "content_block_delta", "index": 0,
       "delta": {"type": "text_delta", "text": "on it"}},
      {"type": "content_block_stop", "index": 0},
      {"type": "content_block_start", "index": 1,
       "content_block": {"type": "tool_use", "id": "tu_2", "name": "a"}},
      {"type": "content_block_delta", "index": 1,
       "delta": {"type": "input_json_delta", "partial_json": "{}"}},
      {"type": "content_block_stop", "index": 1},
      {"type": "message_delta",
       "delta": {"stop_reason": "tool_use"},
       "usage": {"output_tokens": 6}},
      {"type": "message_stop"}])
    assert deltas == @["on it"]
    let msg = finalAnthropic(st)
    assert msg["content"][0] == %*{"type": "text", "text": "on it"}
    assert msg["content"][1]["id"].getStr() == "tu_2"
    assert msg["content"][1]["input"] == %*{}

  test "truncated input_json raises like the openai gate":
    var st: AnthropicSse
    discard feedAnthropic(st, %*{"type": "content_block_start", "index": 0,
      "content_block": {"type": "tool_use", "id": "tu_1", "name": "ping"}})
    discard feedAnthropic(st, %*{"type": "content_block_delta", "index": 0,
      "delta": {"type": "input_json_delta", "partial_json": "{\"loud\":"}})
    try:
      discard finalAnthropic(st)
      assert false, "must raise"
    except JsonParsingError:
      discard

  test "empty stream yields an empty end_turn":
    var st: AnthropicSse
    let msg = finalAnthropic(st)
    assert msg["stop_reason"].getStr() == "end_turn"
    assert msg["content"].len == 0
    assert msg["usage"] == %*{"in": 0, "out": 0}
