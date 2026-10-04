## Deterministic Completion scoring — port of `waku/ops/scoring.py`.
##
## The ONE scorer for the eval battery: did the expected tool fire, with
## the expected args, and did enough of the loop run. Judge-free by
## design (the local mirror of an outcome check, not a vibe).

import std/json
import std/os
import std/strutils

import ./wire

proc datasetPath*(startDir = ""): string =
  ## `evals/dataset.jsonl` beside the checkout (`findProvidersToml`
  ## convention: working directory first, binary directory last), or ""
  ## when there is no checkout — then there are no battery cases.
  for candidate in ["evals/dataset.jsonl", "../evals/dataset.jsonl",
      "../../evals/dataset.jsonl"]:
    if fileExists(candidate):
      return candidate
  let besideBin = getAppDir() / "dataset.jsonl"
  if fileExists(besideBin):
    return besideBin
  return ""

proc loadCases*(path = ""): seq[JsonNode] =
  ## Every battery case in file order; empty when the dataset is missing.
  let at = if path.len > 0: path else: datasetPath()
  if at.len == 0 or not fileExists(at):
    return @[]
  var text = ""
  try:
    text = readFile(at)
  except IOError:
    return @[]
  for line in text.splitLines():
    if line.strip().len == 0:
      continue
    try:
      result.add(parseJson(line))
    except JsonParsingError:
      continue

proc checkCase*(c: JsonNode, toolCalls: JsonNode): tuple[passed: bool,
    why: string] =
  ## The deterministic contract: right tool, right args, enough calls.
  ## `why` is "ok" on success, else the first failed expectation.
  var fired: seq[string] = @[]
  if toolCalls.kind == JArray:
    for call in toolCalls:
      fired.add(call.jget("tool").getStr())
  if c.jget("expect_tool").kind == JNull:
    if fired.len == 0:
      return (true, "no tool expected")
    return (false, "called " & fired.join(", "))
  let want = c.jget("expect_tool").getStr()
  if want notin fired:
    return (false, "expected " & want & ", called " &
      (if fired.len > 0: fired.join(", ") else: "nothing"))
  var args = newJObject()
  for call in toolCalls:
    if call.jget("tool").getStr() == want:
      args = call.jget("args")
      break
  let needles = c.jget("expect_in_args")
  if needles.kind == JObject:
    for key, needle in pairs(needles):
      if needle.getStr().toLowerAscii() notin
          args.jget(key).getStr().toLowerAscii():
        return (false, "'" & needle.getStr() & "' not in args[" & key & "]")
  var minimum = 0
  let rawMin = c.jget("expect_min_tool_calls")
  if rawMin.kind == JInt:
    minimum = int(rawMin.getBiggestInt())
  if fired.len < minimum:
    return (false, "only " & $fired.len & " tool calls, wanted >= " &
      $minimum)
  return (true, "ok")

proc caseForMessage*(message: string,
    cases: seq[JsonNode] = @[]): JsonNode =
  ## The battery case whose input matches this prompt (trimmed exact
  ## match) — `JNull` for a free-form prompt, which still races.
  let msg = message.strip()
  for c in cases:
    if c.jget("input").getStr().strip() == msg:
      return c
  return newJNull()
