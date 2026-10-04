## The turn receipt — what one turn did and cost, built once (spec 011 A3).
##
## Port of the pure half of `waku/ops/receipt.py` (spec 011 group A, unit 2
## of `docs/proposals/nim-receipt.md`): Python builds one dict out of the
## events a turn already emitted — every `llm` call (the loop's and the side
## calls `meteredClient` reports), every `tool` call, the facts a
## consolidation created — and the chat draws ONE line under the answer.
## Same key sets, same closed set at every level, same estimate-only
## dollars, same structural privacy. `evals/deterministic/test_turn_receipt.py`
## stays the Python oracle; this is the port side of the same shapes.
##
## PURE. `buildReceipt` takes the turn's events and a provider and returns a
## `JsonNode`: no clock, no file, no socket, no global state. Dollars come
## from `pricing.priceFor` and nowhere else (single-sourced, like every
## other price in the port), and the "a missing or mistyped usage number
## is 0, never a crash" rule is `loop.nim`'s `usageNum`, reused rather
## than restated — so the offline suite can pin all of it.
##
## THE INPUT. A `seq` of the turn's own `(kind, event)` pairs, in the
## order they came — exactly what Python's `receipt.build` takes, and
## exactly what an Observer delivers (the kind travels as the channel,
## not as a field: live `llm`/`tool`/`consolidation` events carry no
## `"type"`). A pair whose event is not an object is skipped, like
## Python skipping a non-dict.
## - `llm`    — `kind` (loop/gate/consolidation/triage/quick/judge),
##              `model`, `usage{in,out}`. The loop's own events name no kind
##              and no model, so they read as "loop" and price at the
##              provider estimate, like Python's `default_model` path.
## - `tool`   — `tool`, `output` (the tool's own answer, as a string) and
##              `status` when the caller already computed one. Nothing else
##              is read, which is why a receipt cannot quote an argument.
## - `consolidation` — `new_facts`, which is exactly what `memory_live.nim`
##              announces after a consolidation.
## - `report`   — `memory_id` (spec 007's saved research report; `JNull`
##              when the turn saved none).
##
## PRIVACY. A receipt holds names, counts, dollars and ids, never text: no
## tool arguments, no tool output, no prompt, no reply, no memory body, no
## header. A tool's arguments can carry a header map and a key, and its
## output can echo a key somebody pasted, so this module copies NAMED fields
## into new objects and checks every string it copies against a short
## pattern, instead of filtering the event it was given. Real keys are far
## longer than any id, name or provider a receipt may hold, so the pattern
## is the fence. Nim's `re.match` anchors at the START only, so every
## pattern here ends in `\z`: fullmatch semantics, and a value carrying a
## trailing newline is rejected rather than trimmed into shape.
##
## WHAT THE PORT HAS NO EMITTER FOR (the deliberate gaps, not oversights):
## - `turn_id`, `model.id` and `memory.used` are the CALLER's three values
##   (Python takes them as keyword arguments). This builder is handed a
##   turn's events and a provider, so it leaves them neutral ("", 0)
##   rather than guessing which model answered — naming the gate's
##   small model as the answering brain of a full turn would be a lie.
##   Surfacing (unit 3) fills them from the turn it is already inside.
## - `memory.kept` is the COUNT of facts a consolidation created, not
##   Python's list of kept facts with `memory_id`/`sent`: this port's
##   consolidation announces a count, so `new_facts` is the only honest
##   thing it can hold.
##
## ESTIMATE ONLY. `estimate` is always true and `credits` always null: the
## hosted metering proxy's exact charges are a non-goal (proposal §4), so
## Python's `charges` passthrough has no argument here. A hosted build that
## ever grows one adds a key it also pins.

import std/json
import std/math
import std/re
import std/strutils
import std/tables

import ./loop
import ./pricing
import ./wire

const
  receiptKeys* = ["turn_id", "model", "tools", "memory", "total_usd",
                  "credits"]
    ## The receipt's keys, at every level. A new field is a deliberate
    ## change: `tests/test_receipt.nim` pins these sets.
  modelKeys* = ["id", "in", "out", "usd", "estimate", "calls"]
  toolKeys* = ["tool", "provider", "usd", "status"]
  memoryKeys* = ["searches", "used", "kept", "report"]
    ## Python's `MEMORY_KEYS` whole: `report` is back since the port
    ## gained its emitter (spec 007 saves a report into a `report`
    ## event) — before that it had nothing to copy.
  searchKeys* = ["tool", "found", "trace_id"]

  # Python's `_ID` / `_NAME` / `_PROVIDER`, as fullmatch patterns. Nim's
  # string literals process escapes, so the anchor is written `\\z`: the
  # regex engine must see the PCRE absolute-end anchor, and `$` would let
  # a value carrying a trailing newline slip past it.
  idPattern = "^[A-Za-z0-9_.:-]{1,80}\\z"
  namePattern = "^[A-Za-z0-9_.-]{1,64}\\z"
  # A provider name comes out of a tool's own answer, so it is held to the
  # shape of one ("tomba", "PredictLeads") and kept far shorter than a key.
  providerPattern = "^[A-Za-z][A-Za-z0-9 _.-]{0,23}\\z"

  # The Waku Memory tools whose results count as searches, not tools. The
  # keys are what the MODEL reads, i.e. `mcp.modelSafeName(server, tool)`
  # — `waku_memory_memory_search` — written out so this pure module never
  # imports the MCP transport. The loop renames an MCP tool `<server>_<tool>`
  # in Python too, which is why these strings match its `SEARCH_TOOLS`.
  searchTools = {"waku_memory_memory_search": "memory_search",
                 "waku_memory_memory_recall": "memory_recall",
                 "engram_mem_search": "memory_search",
                 "engram_mem_recall": "memory_recall"}.toTable

let
  idRe = re(idPattern)
  nameRe = re(namePattern)
  providerRe = re(providerPattern)

proc nameOrStr(text: string, rx: Regex): string =
  ## A name copied into the receipt, or "" when it is not that shape.
  if match(text, rx): text else: ""

proc nameOr(value: JsonNode, rx: Regex = nameRe): string =
  ## The same rule for a value that may not be a string at all.
  if value.kind == JString: nameOrStr(value.getStr(), rx) else: ""

proc idOrNull(value: JsonNode): JsonNode =
  ## An id copied into the receipt, or null when it is not id-shaped.
  ## (`memory.searches[].trace_id` and nothing else in this port.)
  if value.kind == JString and match(value.getStr(), idRe):
    value
  else:
    newJNull()

proc outputText(ev: JsonNode): string =
  ## A tool event's own answer, or "" when it is absent or not a string —
  ## Python's `_status`/`_json` both read a str or nothing.
  let outp = ev.jget("output")
  if outp.kind == JString: outp.getStr() else: ""

proc jsonObj(text: string): JsonNode =
  ## Python's `_json`: the answer parsed, but only when it is an object.
  ## Anything else — a sentence, a list, a truncated write — reads as null.
  if text.len == 0:
    return newJNull()
  try:
    let parsed = parseJson(text)
    if parsed.kind == JObject: parsed else: newJNull()
  except JsonParsingError:
    newJNull()

proc round6(x: float): float =
  ## `round(x, 6)` like Python: dollars in a receipt carry six decimals.
  round(x * 1e6) / 1e6

proc toolCost(ev: JsonNode): tuple[usd: float, provider: string,
                                   known: bool] =
  ## (dollars, provider) when a tool's answer names what it cost, as
  ## treg's call does through the hosted relay too, else nothing: Python's
  ## `tool_cost` returns None and the receipt shows no provider either.
  ## A named provider wins over the endpoint's first segment
  ## ("tomba.email.find" -> "tomba"), the same rule render.js's toolCost
  ## used before the receipt moved it here.
  result = (usd: 0.0, provider: "", known: false)
  let outp = jsonObj(outputText(ev))
  if outp.kind != JObject:
    return result
  let cost = outp.jget("cost_usd")
  if cost.kind != JInt and cost.kind != JFloat:
    return result
  let usd = if cost.kind == JInt: cost.getBiggestInt().float
            else: cost.getFloat()
  if usd < 0.0:
    return result
  var provider = nameOr(outp.jget("provider"), providerRe)
  if provider.len == 0:
    var endpoint = outp.jget("endpoint_id")
    if endpoint.kind != JString or endpoint.getStr().len == 0:
      endpoint = outp.jget("endpoint")
    if endpoint.kind == JString:
      provider = nameOrStr(endpoint.getStr().split(".")[0], providerRe)
  result = (usd: round6(usd), provider: provider, known: true)

proc statusOf(ev: JsonNode): string =
  ## "error" when the event already says so, else when its answer reads
  ## like a failure ("failed", "timed out", a leading "error"), else "ok".
  ## Python's `_status`, plus the one thing this port can add: a caller
  ## that already computed a status (`app.nim` writes one per tool into the
  ## turn's meta) does not have to be guessed back out of the text.
  let own = ev.jget("status")
  if own.kind == JString:
    let said = own.getStr().toLowerAscii()
    if said == "ok" or said == "error":
      return said
  let low = outputText(ev).toLowerAscii()
  if "failed" in low or "timed out" in low or low.startsWith("error"):
    "error"
  else:
    "ok"

proc buildReceipt*(events: seq[tuple[kind: string, ev: JsonNode]],
                   provider: string): JsonNode =
  ## One receipt from a turn's (kind, event) pairs, in the order they came.
  ## Port of `receipt.build` minus the three caller-owned values and the
  ## `report` event the port has no emitter for (see the header).
  var tokensIn = 0
  var tokensOut = 0
  var usd = 0.0
  var toolUsd = 0.0
  var calls = initOrderedTable[string, int]()
  var tools = newJArray()
  var searches = newJArray()
  var kept = 0
  var report = newJNull()
  for pair in events:
    let kind = pair.kind
    let ev = pair.ev
    if ev.kind != JObject:
      continue
    case kind
    of "report":
      report = idOrNull(ev.jget("memory_id"))
    of "llm":
      let usage = ev.jget("usage")
      let nIn = max(usageNum(usage, "in"), 0)
      let nOut = max(usageNum(usage, "out"), 0)
      let (pIn, pOut) = priceFor(provider, ev.jget("model").getStr())
      inc(tokensIn, nIn)
      inc(tokensOut, nOut)
      usd += nIn.float / 1e6 * pIn + nOut.float / 1e6 * pOut
      var callKind = nameOr(ev.jget("kind"))
      if callKind.len == 0:
        callKind = "loop"
      calls[callKind] = calls.getOrDefault(callKind, 0) + 1
    of "tool":
      let name = ev.jget("tool").getStr()
      if searchTools.hasKey(name):
        # A Waku Memory search is a memory event, not a tool call: it gets
        # the found count and the retrieval trace, never the entries.
        let outp = jsonObj(outputText(ev))
        var found = newJNull()
        let entries = outp.jget("entries")
        if entries.kind == JArray:
          found = %entries.len
        searches.add(%*{"tool": searchTools[name], "found": found,
                        "trace_id": idOrNull(outp.jget("retrieval_trace_id"))})
      else:
        let cost = toolCost(ev)
        var toolName = nameOr(ev.jget("tool"))
        if toolName.len == 0:
          toolName = "tool"
        tools.add(%*{"tool": toolName,
          "provider": (if cost.known: cost.provider else: ""),
          "usd": (if cost.known: %cost.usd else: newJNull()),
          "status": statusOf(ev)})
        if cost.known:
          toolUsd += cost.usd
    of "consolidation":
      kept = max(usageNum(ev, "new_facts"), 0)
    else:
      discard  # a kind this builder does not read (gate, route, text…)
  var callList = newJArray()
  for kind, n in calls.pairs:
    callList.add(%*{"kind": kind, "n": n})
  let modelUsd = round6(usd)
  result = %*{"turn_id": %"",
              "model": %*{"id": %"", "in": %tokensIn, "out": %tokensOut,
                "usd": %modelUsd, "estimate": %true, "calls": callList},
              "tools": tools,
              "memory": %*{"searches": searches, "used": %0, "kept": %kept,
                "report": report},
              "total_usd": %round6(modelUsd + toolUsd),
              "credits": newJNull()}