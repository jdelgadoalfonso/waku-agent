## Wire-format bridge — port of `OpenAICompatClient`'s pure half in
## `waku/loop/models.py` (`_to_openai`, `_create` response shaping, the
## max_tokens key fallback rule).
##
## The loop speaks one dialect (Anthropic Messages shape, JSON here); this
## module translates requests and responses for OpenAI-style
## chat.completions endpoints. Streaming reassembly (3b) and the HTTP
## transport (3e) build on these shapes.
##
## Shapes (all `JsonNode`):
## - anthropic message: `{"role":.., "content": str | [blocks]}`,
##   text block `{"type":"text","text":..}`,
##   tool block `{"type":"tool_use","id":..,"name":..,"input":{..},"extra"?}`.
##   `extra` carries Gemini's `thought_signature` (absent otherwise).
## - assembled response: `{"stop_reason":..,
##   "usage":{"in":..,"out":..}, "content":[blocks]}`.

import std/json
import std/strutils

proc jget*(node: JsonNode, key: string): JsonNode =
  ## Nil-safe field read: missing/non-object yields `JNull`, never nil.
  ## (`std/json.getOrDefault` returns nil for a missing key — a segfault
  ## waiting to happen on `.kind`.)
  if node.kind == JObject and node.hasKey(key):
    return node[key]
  return newJNull()

proc extraTruthy*(node: JsonNode): bool =
  ## Python-truthy for the `extra` (thought_signature) carrier: `if extra:`
  ## drops None AND empty containers/strings, not just null.
  case node.kind
  of JNull: false
  of JObject, JArray: node.len > 0
  of JString: node.getStr().len > 0
  of JBool: node.getBool()
  of JInt: node.getInt() != 0
  of JFloat: node.getFloat() != 0.0

proc textOf*(blocks: JsonNode): string =
  ## Concatenated text of an assistant content-block list.
  for b in blocks:
    if b.kind == JObject and b.jget("type").getStr() == "text":
      result.add(b.jget("text").getStr())

proc toOpenAi*(model: string, messages: JsonNode, maxTokens: int,
               system = "", tools = newJArray()): JsonNode =
  ## Anthropic-shape turn -> OpenAI chat.completions kwargs.
  ## Port of `_to_openai` (request key: `max_completion_tokens`).
  var oaiMessages = newJArray()
  if system.len > 0:
    oaiMessages.add(%*{"role": "system", "content": system})
  for m in messages:
    let role = m["role"].getStr()
    let content = m["content"]
    if content.kind == JString:
      oaiMessages.add(%*{"role": role, "content": content.getStr()})
    elif role == "assistant":
      var calls = newJArray()
      for b in content:
        if b.jget("type").getStr() != "tool_use":
          continue
        var call = %*{"id": b["id"].getStr(), "type": "function",
          "function": {"name": b["name"].getStr(),
                       "arguments": $b.jget("input")}}
        if b.hasKey("extra") and extraTruthy(b["extra"]):
          call["extra_content"] = b["extra"]
        calls.add(call)
      var entry = %*{"role": "assistant", "content": nil}
      let text = textOf(content)
      if text.len > 0:
        entry["content"] = %text
      if calls.len > 0:
        entry["tool_calls"] = calls
      oaiMessages.add(entry)
    else:
      # anthropic tool_result blocks -> one 'tool' message each. Anything
      # else in the list converts to nothing on both sides (Python's
      # `block.get` guard skips it just as silently).
      for b in content:
        if b.kind == JObject and b.jget("type").getStr() == "tool_result":
          oaiMessages.add(%*{"role": "tool",
            "tool_call_id": b["tool_use_id"].getStr(),
            "content": b["content"].getStr()})
  result = %*{"model": model, "messages": oaiMessages,
              "max_completion_tokens": maxTokens}
  if tools.len > 0:
    var converted = newJArray()
    for t in tools:
      converted.add(%*{"type": "function",
        "function": {"name": t["name"].getStr(),
                     "description": t["description"].getStr(),
                     "parameters": t["input_schema"]}})
    result["tools"] = converted

proc shouldRetryWithMaxTokens*(errMsg: string): bool =
  ## Retry with the legacy `max_tokens` key ONLY when the error is about
  ## that parameter. Port of the `_call` guard (retrying any error buried
  ## real failures, e.g. a gpt-5.x call failing for another reason).
  let m = errMsg.toLowerAscii()
  "max_completion_tokens" in m or "max_tokens" in m

proc withMaxTokensKey*(kwargs: JsonNode): JsonNode =
  ## Swap `max_completion_tokens` for the legacy `max_tokens` key.
  result = copy(kwargs)
  if result.hasKey("max_completion_tokens"):
    result["max_tokens"] = result["max_completion_tokens"]
    result.delete("max_completion_tokens")

proc fromOpenAi*(model: string, response: JsonNode): JsonNode =
  ## OpenAI chat.completions response -> assembled Anthropic-shape message.
  ## Port of `_create`: empty choices surface the endpoint's error text,
  ## `extra_content` (thought_signature) rides along for the echo-back.
  let choices = response.jget("choices")
  if choices.kind != JArray or choices.len == 0:
    let err = response.jget("error")
    # Deviation in quoting only: Python interpolates the raw error object
    # (`str(dict)`), Nim renders it as JSON (`$`). Same object, same info.
    let detail = if err.kind == JNull or err.kind == JObject and err.len == 0:
      "endpoint returned no choices"
    else:
      $err
    raise newException(CatchableError, model & ": " & detail)
  let message = choices[0]["message"]
  var blocks = newJArray()
  let content = message.jget("content")
  if content.kind == JString and content.getStr().len > 0:
    blocks.add(%*{"type": "text", "text": content.getStr()})
  let calls = message.jget("tool_calls")
  if calls.kind == JArray:
    for c in calls:
      let argStr = c["function"].jget("arguments").getStr("{}")
      # Missing/empty arguments mean `{}` (mirrors `or "{}"`). Present but
      # invalid JSON raises, same as Python's `json.loads` — a truncated
      # stream is a transport fault, not a callable tool call.
      let parsed = if argStr.len == 0: newJObject() else: parseJson(argStr)
      var toolBlock = %*{"type": "tool_use", "id": c["id"].getStr(),
        "name": c["function"]["name"].getStr(), "input": parsed}
      if c.hasKey("extra_content"):
        toolBlock["extra"] = c["extra_content"]
      blocks.add(toolBlock)
  let usage = response.jget("usage")
  result = %*{"stop_reason": "end_turn", "content": blocks,
    "usage": {"in": 0, "out": 0}}
  if calls.kind == JArray and calls.len > 0:
    result["stop_reason"] = % "tool_use"
  if usage.kind == JObject:
    if usage.hasKey("prompt_tokens"):
      result["usage"]["in"] = usage["prompt_tokens"]
    if usage.hasKey("completion_tokens"):
      result["usage"]["out"] = usage["completion_tokens"]
