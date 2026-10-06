## Trim — port of `waku/loop/trim.py`: old tool results, cut once read.
##
## The loop re-sends the whole conversation on every call, so a large tool
## result rides along on every iteration after the one that produced it.
## `shrinkSeen` is the `trim` step for `runLoop`: before each call after
## the first, every tool result except the newest message's is one the
## model has already read; a result longer than LONG_CHARS keeps its first
## KEEP_CHARS characters and a note saying how long it was. The newest
## results are never touched: the model has not read them yet. The trace
## keeps every output whole, so nothing is lost to the person.
##
## Results older than the latest iteration are the only ones cut, so a
## cut result is shorter than LONG_CHARS and is never cut again.
##
## `chainTrim` runs steps in order. `runFullTurn` runs
## `reports.shrinkRead` first, so an earlier report becomes its digest
## rather than its first KEEP_CHARS characters.

import std/json
import std/strutils

import ./wire

const
  LONG_CHARS* = 4000
    ## A result this long or shorter is left whole: a calendar answer or
    ## a memory fact costs less than the note that would replace it.

  KEEP_CHARS* = 2000
    ## What a cut result keeps: its opening, which for search JSON holds
    ## the first few hits and their fields.

  NOTE_TAIL* = "[Cut from {total} characters after you read it. The whole output is in this turn's trace. Results you have read are cut before each later call, so write down what you need from a result before you call the next tool.]"
    ## The note body; `{total}` is the pre-cut length with thousands
    ## separators (Python's `{total:,}`).

type
  Trim* = proc(messages: var seq[JsonNode]) {.closure.}
    ## A pass over the working memory that may shorten what the model
    ## already read. Mutates `messages` in place; nil leaves it as is.

proc commas*(n: int): string =
  ## `5000` as `"5,000"` (Python's `f"{total:,}"`).
  let digits = $n
  var i = 0
  for c in digits:
    if c in {'0' .. '9'}:
      break
    result.add(c)
    inc i
  let rest = digits[i .. ^1]
  for j, c in rest:
    if j > 0 and (rest.len - j) mod 3 == 0:
      result.add(',')
    result.add(c)

proc noteFor*(total: int): string =
  ## The full note for a result of `total` characters.
  "\n\n" & NOTE_TAIL.replace("{total}", commas(total))

proc shrinkSeen*(messages: var seq[JsonNode]) =
  ## Cut each long tool result the model has already read, in place.
  if messages.len == 0:
    return
  for i in 0 ..< messages.len - 1:
    let message = messages[i]
    if message.kind != JObject or message.jget("role").getStr() != "user":
      continue
    let content = message.jget("content")
    if content.kind != JArray:
      continue
    for blk in content:
      if blk.kind != JObject or blk.jget("type").getStr() != "tool_result":
        continue
      let text = blk.jget("content")
      if text.kind != JString:
        continue
      let s = text.getStr()
      if s.len > LONG_CHARS:
        blk["content"] = %(s[0 ..< KEEP_CHARS] & noteFor(s.len))

proc chainTrim*(steps: varargs[Trim]): Trim =
  ## One `trim` that runs `steps` in order.
  let run = @steps
  result = proc(messages: var seq[JsonNode]) {.closure.} =
    for step in run:
      step(messages)

proc toTrim*(step: proc(messages: var seq[JsonNode]) {.nimcall.}): Trim =
  ## A top-level `trim` step as a `Trim`: `shrinkSeen`/`shrinkRead` are
  ## plain procs (no closure environment), and `varargs[Trim]` does not
  ## re-wrap them the way a single closure slot does — so the call
  ## site wraps once, explicitly, instead of every `chainTrim` caller
  ## repeating the two-line closure.
  let s = step
  result = proc(messages: var seq[JsonNode]) {.closure.} =
    s(messages)
