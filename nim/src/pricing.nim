## Pricing — port of `waku/ops/pricing.py`: what a call cost, in dollars
## a human can feel.
##
## The loop writes a permanent ledger (`.waku/usage.jsonl`): one line per API
## call with provider, model and token counts. It deliberately does NOT store
## a price. Prices change; tokens don't. So cost is derived HERE, at read
## time, from the current tables — fixing a wrong rate silently corrects
## every past race and every historical spend chart.
##
## Three tables, checked in this order by `priceFor`:
##
##   priceCache      exact per-model rates learned from a live catalog fetch
##                   (OpenRouter reports them) — see the phase 5c catalog
##   modelPricing    hand-maintained rates for endpoints with no listable
##                   catalog (the anthropic wire has none)
##   provider row    the row's `price` from `providers.toml`, deliberately
##                   rough and labelled "est" in the UI
##
## Unknown providers fall back to `defaultPrice` (3.0, 15.0), like Python's
## `PRICING.get(provider, (3.0, 15.0))`. Pricing stays single-sourced: the
## provider fallback comes from the parsed `providers.toml` rows, never from
## a second hand-kept table (Python derives `PRICING` from its registry the
## same way). `modelCutoff` stores "" for unpublished cutoffs (Python None);
## the UI shows a dash rather than a guess, and `cutoffFor` returns "" for
## unknown ids too. `totalCost` is rounded to 4 decimals like Python's
## `round(..., 4)`; per-bucket costs are left unrounded, also like Python.

import std/algorithm
import std/json
import std/math
import std/os
import std/strutils
import std/tables

import ./providers

type
  Price* = tuple[pin, pout: float]
    ## $/M tokens (in, out) for one call.

  UsageSummary* = object
    ## `usageSummary` over the permanent spend ledger: all-time tokens +
    ## dollar cost plus per-day and per-provider breakdowns.
    calls*: int
    totalIn*: int
    totalOut*: int
    totalCost*: float
    byDay*: seq[JsonNode]      ## {date, calls, in, out, cost}, newest first
    byProvider*: seq[JsonNode] ## {provider, calls, in, out, cost}, costliest first

const
  defaultPrice*: Price = (3.0, 15.0)
    ## Unknown-provider estimate, like Python's `PRICING.get` default.

let
  modelPricing*: Table[string, Price] = {
    "claude-opus-4-8": (5.0, 25.0),
    "claude-fable-5": (10.0, 50.0),
    "claude-sonnet-5": (3.0, 15.0),
    "claude-haiku-4-5-20251001": (1.0, 5.0),
    "gpt-5.6-sol": (5.0, 30.0),
    "gpt-5.3-chat-latest": (1.75, 14.0),
    "gemini-3.1-pro-preview": (2.0, 12.0),
    "gemini-3.5-flash": (1.5, 9.0),
    "kimi-k3": (3.0, 15.0),
    "kimi-k2.7-code-highspeed": (1.9, 8.0),
    "kimi-k2.7": (0.95, 4.0),
    "grok-4.5": (2.0, 6.0),
    "grok-4.3": (1.25, 2.5),
    "deepseek-v4-flash": (0.15, 0.30),
    "deepseek-v4-flash-free": (0.0, 0.0),
  }.toTable
  modelCutoff*: Table[string, string] = {
    "claude-opus-4-8": "2026-01",
    "claude-fable-5": "2026-01",
    "claude-sonnet-5": "2026-01",
    "claude-haiku-4-5-20251001": "2025-02",
    "gpt-5.6-sol": "2026-02",
    "gpt-5.3-chat-latest": "2025-08",
    "gemini-3.1-pro-preview": "2025-01",
    "gemini-3.5-flash": "2025-01",
    "kimi-k3": "2026-01",
    "kimi-k2.7-code-highspeed": "",
    "kimi-k2.7": "",
    "grok-4.5": "2026-02",
    "grok-4.3": "2025-12",
    "deepseek-v4-flash": "2026-04",
    "deepseek-v4-flash-free": "2026-04",
  }.toTable

var priceCache*: Table[string, Price] = initTable[string, Price]()
  ## Exact per-model rates from a live catalog fetch. Process-lifetime only:
  ## the ledger stores tokens, so a restart just falls back to the tables.

proc rememberPrice*(model: string, pin, pout: float) =
  ## Record an EXACT per-model rate learned from a live catalog fetch, so
  ## `priceFor` stops guessing for this model.
  priceCache[model] = (pin, pout)

proc clearPriceCache*() =
  ## Drop everything `rememberPrice` learned. Test seam: the Python cache
  ## has no clear because tests share one process the same way.
  priceCache.clear()

proc cutoffFor*(model: string): string =
  ## Knowledge-cutoff date ("YYYY-MM") for a model id, or "" when the
  ## vendor hasn't published one (the UI shows a dash rather than a guess).
  modelCutoff.getOrDefault(model, "")

proc providerFallback(provider: string,
                      providers: seq[Provider]): Price =
  ## The row's `price` from `providers.toml`, or the unknown-provider
  ## estimate when the row isn't in the given set.
  for p in providers:
    if p.name == provider:
      return (p.priceIn, p.priceOut)
  return defaultPrice

proc priceFor*(provider, model: string,
               providers: seq[Provider] = @[]): Price =
  ## $/M tokens (in, out) for one call: the catalog's per-model price when
  ## known, $0 for ":free" ids, a known `modelPricing` id, else the
  ## provider-level estimate.
  if model in priceCache:
    return priceCache[model]
  if model.endsWith(":free"):
    return (0.0, 0.0)
  if model in modelPricing:
    return modelPricing[model]
  return providerFallback(provider, providers)

proc jsonInt(node: JsonNode, key: string): int =
  ## Ledger numbers default to 0 when missing or mistyped, like Python's
  ## `r.get("in", 0)` (the ledger is append-only and hand-editable).
  if node.kind != JObject or not node.hasKey(key):
    return 0
  let v = node[key]
  case v.kind
  of JInt: int(v.getBiggestInt())
  of JFloat: int(v.getFloat())
  else: 0

proc jsonStr(node: JsonNode, key: string): string =
  if node.kind != JObject or not node.hasKey(key):
    return ""
  let v = node[key]
  if v.kind == JString: v.getStr() else: ""

proc round4(x: float): float =
  round(x * 10000.0) / 10000.0

proc usageSummary*(home: string,
                   providers: seq[Provider] = @[]): UsageSummary =
  ## Read the PERMANENT spend ledger (`usage.jsonl`) into all-time tokens +
  ## dollar cost plus per-day and per-provider breakdowns. Cost derives from
  ## tokens with `priceFor` (approximate, labelled "est"), so old rows
  ## reprice too. Bad JSON lines are skipped, like Python's
  ## `except json.JSONDecodeError: pass`.
  result = UsageSummary(calls: 0, totalIn: 0, totalOut: 0, totalCost: 0.0,
                        byDay: @[], byProvider: @[])
  let path = home / "usage.jsonl"
  if not fileExists(path):
    return result
  var dayAcc = initTable[string, tuple[calls, tin, tout: int, cost: float]]()
  var provAcc = initTable[string, tuple[calls, tin, tout: int, cost: float]]()
  for line in lines(path):
    var rec: JsonNode
    try:
      rec = parseJson(line)
    except CatchableError:
      continue
    if rec.kind != JObject:
      continue
    let prov = jsonStr(rec, "provider")
    let modl = jsonStr(rec, "model")
    let inn = jsonInt(rec, "in")
    let outn = jsonInt(rec, "out")
    let (pin, pout) = priceFor(prov, modl, providers)
    let cost = inn.float / 1e6 * pin + outn.float / 1e6 * pout
    let ts = jsonStr(rec, "ts")
    let day = if ts.len >= 10: ts[0 .. 9] else: ts
    let d = dayAcc.getOrDefault(day, (0, 0, 0, 0.0))
    dayAcc[day] = (d.calls + 1, d.tin + inn, d.tout + outn, d.cost + cost)
    # Missing provider reads as "?" (`r.get("provider", "?")`); an
    # explicit empty string stays empty, like Python.
    var pk = "?"
    if rec.hasKey("provider") and rec["provider"].kind == JString:
      pk = rec["provider"].getStr()
    let q = provAcc.getOrDefault(pk, (0, 0, 0, 0.0))
    provAcc[pk] = (q.calls + 1, q.tin + inn, q.tout + outn, q.cost + cost)
    inc result.calls
    inc(result.totalIn, inn)
    inc(result.totalOut, outn)
    result.totalCost += cost
  result.totalCost = round4(result.totalCost)
  var days: seq[JsonNode] = @[]
  for day, a in dayAcc.pairs:
    days.add(%*{"date": day, "calls": a.calls, "in": a.tin, "out": a.tout,
                "cost": a.cost})
  days.sort(proc(x, y: JsonNode): int = cmp(y["date"].getStr(),
                                            x["date"].getStr()))
  result.byDay = if days.len > 30: days[0 ..< 30] else: days
  var provs: seq[JsonNode] = @[]
  for name, a in provAcc.pairs:
    provs.add(%*{"provider": name, "calls": a.calls, "in": a.tin,
                 "out": a.tout, "cost": a.cost})
  provs.sort(proc(x, y: JsonNode): int = cmp(y["cost"].getFloat(),
                                             x["cost"].getFloat()))
  result.byProvider = provs
