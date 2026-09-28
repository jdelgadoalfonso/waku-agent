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

