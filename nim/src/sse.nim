## SSE reassembly — ports of the streaming accumulators in
## `waku/loop/models.py`: `_OpenAIStream` (3b, this unit) and the Anthropic
## event assembler (3c).
##
## Both sides feed PARSED JSON per line/event (line splitting and `[DONE]` /
## Anthropic event envelopes belong to the 3e transport) and produce the same
## assembled shape `fromOpenAi` returns, so the loop cannot tell a streamed
## turn from a single call.

import std/json
import std/strutils

import ./wire

type
  OpenAiSlot* = object
    ## One tool call being reassembled, keyed by chunk `index`.
    index*: int
    id*: string
    name*: string
    args*: string

  OpenAiSse* = object
    ## Accumulator for one OpenAI chat.completions stream.
    text*: seq[string]
    slots*: seq[OpenAiSlot]
    usageIn*: int
    usageOut*: int

proc feedOpenAi*(st: var OpenAiSse, chunk: JsonNode): seq[string] =
  ## Fold one parsed chunk (`choices[].delta` + optional `usage`) into the
  ## accumulator. Returns this chunk's text deltas for live display.
  ## Port of `_OpenAIStream.text_stream` minus the network iteration.
  let usage = chunk.jget("usage")
  if usage.kind == JObject:
    if usage.hasKey("prompt_tokens"):
      st.usageIn = usage["prompt_tokens"].getInt()
    if usage.hasKey("completion_tokens"):
      st.usageOut = usage["completion_tokens"].getInt()
  let choices = chunk.jget("choices")
  if choices.kind != JArray or choices.len == 0:
    return @[]
  # First choice only, like Python's `chunk.choices[0]`: multi-choice
  # streams don't occur on these endpoints, and merging would corrupt.
  let delta = choices[0].jget("delta")
  if delta.kind != JObject:
    return @[]
  let content = delta.jget("content")
  if content.kind == JString and content.getStr().len > 0:
    st.text.add(content.getStr())
    result.add(content.getStr())
  let calls = delta.jget("tool_calls")
  if calls.kind != JArray:
    return result
  for tc in calls:
      # A missing `index` coalesces to -1 (Python would raise on the
      # attribute access); the field is always present on real streams.
      let idx = tc.jget("index").getInt(-1)
      var slotPos = -1
      for i in 0 ..< st.slots.len:
        if st.slots[i].index == idx:
          slotPos = i
          break
      if slotPos < 0:
        st.slots.add(OpenAiSlot(index: idx))
        slotPos = st.slots.len - 1
      let tcId = tc.jget("id").getStr()
      if tcId.len > 0:
        st.slots[slotPos].id = tcId
      let fn = tc.jget("function")
      if fn.kind == JObject:
        let fnName = fn.jget("name").getStr()
        if fnName.len > 0:
          st.slots[slotPos].name = fnName
        let frag = fn.jget("arguments").getStr()
        if frag.len > 0:
          st.slots[slotPos].args.add(frag)

proc finalOpenAi*(st: OpenAiSse): JsonNode =
  ## Assemble the Anthropic-shape message. Port of `get_final_message`:
  ## text block only when non-empty, slots in first-seen order, `tool_use`
  ## stop reason iff any tool call arrived. Truncated args raise (see wire).
  var blocks = newJArray()
  let text = st.text.join("")
  if text.len > 0:
    blocks.add(%*{"type": "text", "text": text})
  for s in st.slots:
    let parsed = if s.args.len == 0: newJObject() else: parseJson(s.args)
    blocks.add(%*{"type": "tool_use", "id": s.id, "name": s.name,
                  "input": parsed})
  result = %*{"stop_reason": "end_turn", "content": blocks,
    "usage": {"in": st.usageIn, "out": st.usageOut}}
  if st.slots.len > 0:
    result["stop_reason"] = % "tool_use"

type
  AnthropicBlock* = object
    ## One content block being reassembled, keyed by stream `index`.
    index*: int
    kind*: string
    text*: string
    id*: string
    name*: string
    inputJson*: string

  AnthropicSse* = object
    ## Accumulator for one Anthropic messages stream.
    blocks*: seq[AnthropicBlock]
    usageIn*: int
    usageOut*: int
    stopReason*: string

proc feedAnthropic*(st: var AnthropicSse, event: JsonNode): seq[string] =
  ## Fold one parsed SSE event (`message_start`, `content_block_start`,
  ## `content_block_delta`, `content_block_stop`, `message_delta`,
  ## `message_stop`, `ping`) into the accumulator. Returns this event's
  ## text deltas for live display. Mirrors what the anthropic SDK's
  ## `messages.stream()` exposes to the Python loop (`text_stream` deltas
  ## plus the final assembled message).
  let kind = event.jget("type").getStr()
  case kind
  of "message_start":
    let usage = event.jget("message").jget("usage")
    if usage.kind == JObject:
      if usage.hasKey("input_tokens"):
        st.usageIn = usage["input_tokens"].getInt()
      if usage.hasKey("output_tokens"):
        st.usageOut = usage["output_tokens"].getInt()
  of "content_block_start":
    let idx = event.jget("index").getInt(-1)
    let cb = event.jget("content_block")
    if cb.kind != JObject:
      return @[]
    let cbType = cb.jget("type").getStr()
    if cbType == "text":
      st.blocks.add(AnthropicBlock(index: idx, kind: "text",
        text: cb.jget("text").getStr()))
    elif cbType == "tool_use":
      st.blocks.add(AnthropicBlock(index: idx, kind: "tool_use",
        id: cb.jget("id").getStr(), name: cb.jget("name").getStr()))
  of "content_block_delta":
    # Unknown delta types (thinking/signature deltas on newer models) are
    # silently dropped here: this port assembles only text and tool inputs,
    # the two block kinds the loop consumes. Python reads them via the SDK,
    # which keeps them on the final message untouched — deferred with the
    # reasoning-tool phases, not forgotten.
    let idx = event.jget("index").getInt(-1)
    var pos = -1
    for i in 0 ..< st.blocks.len:
      if st.blocks[i].index == idx:
        pos = i
        break
    if pos < 0:
      return @[]
    let delta = event.jget("delta")
    let dType = delta.jget("type").getStr()
    if dType == "text_delta":
      let t = delta.jget("text").getStr()
      if t.len > 0:
        st.blocks[pos].text.add(t)
        result.add(t)
    elif dType == "input_json_delta":
      let frag = delta.jget("partial_json").getStr()
      if frag.len > 0:
        st.blocks[pos].inputJson.add(frag)
  of "message_delta":
    let stop = event.jget("delta").jget("stop_reason").getStr()
    if stop.len > 0:
      st.stopReason = stop
    let usage = event.jget("usage")
    if usage.kind == JObject and usage.hasKey("output_tokens"):
      st.usageOut = usage["output_tokens"].getInt()
  else:
    discard

proc finalAnthropic*(st: AnthropicSse): JsonNode =
  ## Assemble the loop's message shape: text/tool_use blocks in first-seen
  ## order, event stop reason (default `end_turn`), streamed usage.
  var blocks = newJArray()
  for b in st.blocks:
    if b.kind == "text":
      if b.text.len > 0:
        blocks.add(%*{"type": "text", "text": b.text})
    elif b.kind == "tool_use":
      let parsed = if b.inputJson.len == 0: newJObject()
                   else: parseJson(b.inputJson)
      blocks.add(%*{"type": "tool_use", "id": b.id, "name": b.name,
                     "input": parsed})
  result = %*{ "stop_reason": if st.stopReason.len > 0: st.stopReason
                              else: "end_turn",
    "content": blocks,
    "usage": {"in": st.usageIn, "out": st.usageOut}}
