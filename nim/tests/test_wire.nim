## Phase 3a tests: the wire-format bridge. Pure and offline.

import std/json
import std/strutils
import std/unittest

import ../src/wire

suite "phase 3a anthropic to openai":
  test "system, text, tools and the token key convert":
    let req = toOpenAi("gpt-5", %*[{"role": "user", "content": "hi"}],
      10, "be nice",
      %*[{"name": "ping", "description": "p", "input_schema": {"type": "object"}}])
    assert req["model"].getStr() == "gpt-5"
    assert req["max_completion_tokens"].getInt() == 10
    assert req["messages"][0] == %*{"role": "system", "content": "be nice"}
    assert req["messages"][1] == %*{"role": "user", "content": "hi"}
    assert req["tools"][0]["function"]["parameters"] == %*{"type": "object"}

  test "assistant blocks split into text and function calls":
    let req = toOpenAi("m", %*[{"role": "assistant", "content": [
      {"type": "text", "text": "on it"},
      {"type": "tool_use", "id": "t1", "name": "ping",
       "input": {"loud": true}}]}],
      10)
    let entry = req["messages"][0]
    assert entry["content"].getStr() == "on it"
    assert entry["tool_calls"][0]["function"]["arguments"].getStr() == "{\"loud\":true}"

  test "thought_signature round-trips through extra_content":
    let parsed = fromOpenAi("gemini-3.5-flash", %*{
      "choices": [{"message": {"content": nil, "tool_calls": [
        {"id": "t1", "extra_content": {"google": {"thought_signature": "ABC123"}},
         "function": {"name": "create_event",
                      "arguments": "{\"title\":\"x\"}"}}]}}],
      "usage": {"prompt_tokens": 1, "completion_tokens": 1}})
    let callBlock = parsed["content"][0]
    assert callBlock["extra"] == %*{"google": {"thought_signature": "ABC123"}}
    assert parsed["stop_reason"].getStr() == "tool_use"
    assert parsed["usage"] == %*{"in": 1, "out": 1}
    let back = toOpenAi("gemini-3.5-flash",
      %*[{"role": "assistant", "content": [callBlock]}], 10)
    assert back["messages"][0]["tool_calls"][0]["extra_content"] ==
      %*{"google": {"thought_signature": "ABC123"}}

  test "tool_result blocks become tool messages":
    let req = toOpenAi("m", %*[
      {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t1", "name": "ping", "input": {}}]},
      {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "pong"}]}],
      10)
    assert req["messages"][1] ==
      %*{"role": "tool", "tool_call_id": "t1", "content": "pong"}

  test "falsy extra is dropped like Python if extra":
    assert not extraTruthy(%*{})
    assert not extraTruthy(%"")
    assert not extraTruthy(newJNull())
    assert extraTruthy(%*{"google": {"thought_signature": "X"}})
    let req = toOpenAi("m", %*[{"role": "assistant", "content": [
      {"type": "tool_use", "id": "t1", "name": "ping",
       "input": {}, "extra": {}}]}], 10)
    assert not req["messages"][0]["tool_calls"][0].hasKey("extra_content")

suite "phase 3a openai to anthropic":
  test "text-only response maps usage and end_turn":
    let msg = fromOpenAi("m", %*{
      "choices": [{"message": {"content": "hello", "tool_calls": nil}}],
      "usage": {"prompt_tokens": 3, "completion_tokens": 5}})
    assert msg["stop_reason"].getStr() == "end_turn"
    assert msg["content"] == %*[{"type": "text", "text": "hello"}]
    assert msg["usage"] == %*{"in": 3, "out": 5}

  test "empty choices surface the endpoint error":
    try:
      discard fromOpenAi("openrouter/x",
        %*{"error": {"message": "rate limited"}})
      assert false, "must raise"
    except CatchableError as e:
      assert "openrouter/x" in e.msg
      assert "rate limited" in e.msg
    try:
      discard fromOpenAi("m", %*{})
      assert false, "must raise"
    except CatchableError as e:
      assert "endpoint returned no choices" in e.msg

  test "missing arguments default to an empty object":
    let msg = fromOpenAi("m", %*{
      "choices": [{"message": {"content": nil, "tool_calls": [
        {"id": "t9", "function": {"name": "ping"}}]}}]})
    assert msg["content"][0]["input"] == %*{}

suite "phase 3a max_tokens fallback rule":
  test "retries only on parameter errors":
    assert shouldRetryWithMaxTokens(
      "unknown parameter: max_completion_tokens")
    assert shouldRetryWithMaxTokens("Use MAX_TOKENS instead")
    assert not shouldRetryWithMaxTokens("401 unauthorized")
    assert not shouldRetryWithMaxTokens("model not found: gpt-5.x")
    let swapped = withMaxTokensKey(
      %*{"model": "m", "max_completion_tokens": 32})
    assert swapped == %*{"model": "m", "max_tokens": 32}
