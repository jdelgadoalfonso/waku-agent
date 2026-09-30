## Model catalog — port of `waku/ops/catalog.py`: what a provider can serve
## (`listModels`) and the curated `provider:model` shortlist (`pinnedSpecs`,
## `defaultModelFor`, `savePinned`).
##
## Conventions and deliberate divergences:
##
## - Cache lifetimes mirror Python: successful listings live 300 s; failures
##   are stored with `ts = now - 240`, so the same 300 s window expires them
##   ~60 s after the failure while the reason survives in the meantime.
## - The fetch is INJECTED (`FetchFn`): this module performs no real HTTP.
##   Wiring to a live client comes with a later phase; callers pass a stub
##   (tests) or a real client that returns the body or raises
##   `CatchableError` carrying the human-readable reason.
## - Region matching is unavailable: the Nim `Provider` parser skips
##   `[[array]]` tables, so there are no regional endpoints to pair a base
##   URL with. `catalogFor` falls back to the row `catalogUrl`, where Python
##   would first try the region-paired catalog.
## - "" means missing everywhere (provider fields, settings fields, keys),
##   like the Python `""`/`None` defaults read through `or`.
## - Sort order mirrors Python exactly: free models first, then
##   tools-capable/unknown, then tools-incapable, with id as tiebreak.
## - Entry `tools`/`reasoning` keys exist only when the listing names
##   `supported_parameters`; absent params omit both keys (Python `None`).
## - Malformed entries degrade to defaults instead of raising, except an
##   empty id, which is skipped like Python.

import std/algorithm
import std/json
import std/math
import std/os
import std/strutils
import std/tables
import std/times
import std/unicode

import ./pricing
import ./providers

type
  FetchFn* = proc(url, key: string): string {.closure.}
    ## Injected catalog fetch: return the raw response body, or raise
    ## `CatchableError` with the human-readable reason on failure.

  CatalogSettings* = object
    ## The `Settings` fields `catalog.py` reads, mirrored so this module
    ## never imports config.
    home*: string
    provider*: string
    model*: string
    smallModel*: string
    baseUrl*: string
    apiKey*: string

  CacheEntry = tuple[ts: float, models: JsonNode, err: string]

var modelsCache*: Table[string, CacheEntry] = initTable[string, CacheEntry]()
  ## Listing cache keyed by catalog URL. `err` is "" on a real listing and
  ## carries the failure reason otherwise.

proc clearModelsCache*() =
  ## Drop every cached listing and failure. Test seam.
  modelsCache.clear()

proc defaultPair(p: Provider): seq[string] =
  ## `[flagship, fast]`, deduped, falling back through `modelsNow` — like
  ## Python's `default_pair`, so `model_env` overrides win over placeholders.
  let (m, s) = modelsNow(p)
  let a = if p.flagship.len > 0: p.flagship else: m
  let b = if p.fast.len > 0: p.fast else: s
  for id in [a, b]:
    if id.len > 0 and id notin result:
      result.add(id)

proc configuredBaseUrl(p: Provider): string =
  ## Provider-scoped endpoint, falling back to the built-in default.
  let override = if p.baseUrlEnv.len > 0: getEnv(p.baseUrlEnv, "").strip()
                 else: ""
  if override.len > 0: override else: p.baseUrl

proc catalogFor(p: Provider): string =
  ## The row's explicit catalog URL. Python additionally matches regional
  ## `endpoints` against the active base URL; the Nim registry skips
  ## `[[array]]` tables, so that match has nothing to work with.
  p.catalogUrl

proc withoutTrailingSlash(s: string): string =
  var i = s.len
  while i > 0 and s[i - 1] == '/':
    dec i
  s[0 ..< i]

proc knownDefaultIds(found: bool, p: Provider, model, smallModel: string,
                     isActive: bool): JsonNode =
  ## Flagship + fast (+ the active model pair when active), deduped, each as
  ## `{"id": ...}` — the picker is never empty, even with no catalog.
  var ids: seq[string] = @[]
  if isActive:
    ids.add(model)
    ids.add(smallModel)
  if found:
    ids.add(defaultPair(p))
  result = newJArray()
  var seen: seq[string] = @[]
  for id in ids:
    if id.len > 0 and id notin seen:
      seen.add(id)
      result.add(%*{"id": id})

proc isLatin1(key: string): bool =
  ## HTTP headers must be latin-1: any rune past U+00FF means a bad paste.
  for r in key.runes:
    if r.ord >= 256:
      return false
  return true

proc latin1Message(p: Provider): string =
  p.keyEnv & " contains a non-ASCII character — re-paste the key " &
    "(no spaces, line breaks, or arrows)."

proc paramPresent(params: JsonNode): bool =
  params.kind == JArray or params.kind == JString

proc paramContains(params: JsonNode, name: string): bool =
  case params.kind
  of JArray:
    for item in params:
      if item.kind == JString and item.getStr() == name:
        return true
    return false
  of JString:
    return name in params.getStr()
  else:
    return false

proc round3(x: float): float =
  round(x * 1000.0) / 1000.0

proc priceNum(node: JsonNode): float =
  ## A catalog price, whether the wire sends a string, int or float.
  case node.kind
  of JString: parseFloat(node.getStr())
  of JInt: node.getBiggestInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "not a price")

proc parseEntry(m: JsonNode): (bool, JsonNode) =
  ## Returns (keep, entry); empty ids are not kept.
  var mid = ""
  if m.kind == JObject and m.hasKey("id") and m["id"].kind == JString:
    mid = m["id"].getStr()
  if mid.len == 0:
    return (false, newJNull())
  var pricing = newJObject()
  if m.kind == JObject and m.hasKey("pricing") and m["pricing"].kind == JObject:
    pricing = m["pricing"]
  var promptIsZero = false
  if pricing.hasKey("prompt") and pricing["prompt"].kind == JString:
    promptIsZero = pricing["prompt"].getStr() == "0"
  var entry = newJObject()
  entry["id"] = %mid
  entry["free"] = %(mid.endsWith(":free") or promptIsZero)
  if m.kind == JObject and m.hasKey("supported_parameters") and
      paramPresent(m["supported_parameters"]):
    let params = m["supported_parameters"]
    entry["tools"] = %paramContains(params, "tools")
    entry["reasoning"] = %paramContains(params, "reasoning")
  if m.kind == JObject and m.hasKey("context_length"):
    entry["context"] = m["context_length"]
  else:
    entry["context"] = newJNull()
  try:
    # OpenRouter prices are $/token; keep $/M like Python (`* 1e6`). Both
    # legs must parse, or neither price is stored — also like Python.
    let pin = priceNum(pricing["prompt"]) * 1e6
    let pout = priceNum(pricing["completion"]) * 1e6
    rememberPrice(mid, pin, pout)
    entry["price_in"] = %round3(pin)
    entry["price_out"] = %round3(pout)
  except CatchableError:
    discard
  return (true, entry)

proc entryRank(e: JsonNode): (bool, bool, string) =
  ## `(not free, tools-is-false, id)`: free first, tools-incapable last.
  var free = false
  if e.hasKey("free") and e["free"].kind == JBool:
    free = e["free"].getBool()
  var toolsFalse = false
  if e.hasKey("tools") and e["tools"].kind == JBool:
    toolsFalse = not e["tools"].getBool()
  (not free, toolsFalse, e["id"].getStr())

proc listModels*(s: CatalogSettings, providers: seq[Provider], fetch: FetchFn,
                 onlyProvider = "", useCache = true,
                 now = epochTime()): JsonNode =
  ## Model ids available on a provider, for the settings model picker.
  ## Returns `{"provider", "model", "small_model", "endpoint", "listed",
  ## "models"}` plus `"error"` when unlisted-with-reason.
  let name = if onlyProvider.len > 0: onlyProvider else: s.provider
  var found = false
  var prov = Provider()
  for p in providers:
    if p.name == name:
      found = true
      prov = p
      break
  # A scoped-credentials row never reads the global base-URL override.
  var base = ""
  if found and prov.scopedCredentials:
    base = configuredBaseUrl(prov)
  elif name == s.provider and s.baseUrl.len > 0:
    base = s.baseUrl
  elif found:
    base = configuredBaseUrl(prov)
  let (model, smallModel) = modelsFor(name, s.model, s.smallModel, providers)
  var outp = newJObject()
  outp["provider"] = %name
  outp["model"] = %model
  outp["small_model"] = %smallModel
  outp["endpoint"] = %(if base.len > 0: base else: name)
  let isActive = name == s.provider
  var url = ""
  if found and catalogFor(prov).len > 0:
    url = catalogFor(prov)
  elif found and prov.kind == "openai" and base.len > 0:
    url = withoutTrailingSlash(base) & "/models"
  elif found and prov.catalogFromBaseUrl and base.len > 0:
    url = withoutTrailingSlash(base) & "/v1/models"
  else:
    outp["listed"] = %false
    outp["models"] = knownDefaultIds(found, prov, model, smallModel, isActive)
    return outp
  if useCache and url in modelsCache:
    let hit = modelsCache[url]
    if now - hit.ts < 300:
      outp["listed"] = %(hit.err.len == 0)
      outp["models"] = hit.models
      if hit.err.len > 0:
        outp["error"] = %hit.err
      return outp
  # This provider's own key; `s.apiKey` only holds the ACTIVE provider's.
  let activeKey = if name == s.provider: s.apiKey else: ""
  let key = if found: resolveApiKey(prov, activeKey) else: activeKey.strip()
  if found and not isLatin1(key):
    outp["listed"] = %false
    outp["models"] = knownDefaultIds(found, prov, model, smallModel, isActive)
    outp["error"] = %latin1Message(prov)
    return outp
  proc fail(msg: string): JsonNode =
    let known = knownDefaultIds(found, prov, model, smallModel, isActive)
    modelsCache[url] = (ts: now - 240.0, models: known, err: msg)
    outp["listed"] = %false
    outp["models"] = known
    outp["error"] = %msg
    return outp
  var body = ""
  try:
    body = fetch(url, key)
  except CatchableError as exc:
    return fail(exc.msg)
  var data: JsonNode
  try:
    data = parseJson(body)
  except CatchableError as exc:
    return fail(exc.msg)
  var entries: seq[JsonNode] = @[]
  if data.kind == JObject and data.hasKey("data") and
      data["data"].kind == JArray:
    for m in data["data"]:
      let (keep, entry) = parseEntry(m)
      if keep:
        entries.add(entry)
  entries.sort(proc(a, b: JsonNode): int = cmp(entryRank(a), entryRank(b)))
  var models = newJArray()
  for e in entries:
    models.add(e)
  modelsCache[url] = (ts: now, models: models, err: "")
  outp["listed"] = %true
  outp["models"] = models
  return outp

proc defaultPinnedSpecs*(providers: seq[Provider]): seq[string] =
  ## Starter shortlist: flagship + fast for every visible provider with a key
  ## set. Flagship comes first, so it is that provider's default.
  for p in providers:
    if p.isVisible() and p.keyEnv.len > 0 and getEnv(p.keyEnv, "").len > 0:
      for m in defaultPair(p):
        result.add(p.name & ":" & m)

proc stalePlatformPin(spec: string, providers: seq[Provider]): bool =
  ## True only when a saved pin equals its row's TOML placeholder model or
  ## small_model AND that placeholder is no longer what the row's
  ## `model_env`/`small_model_env` override resolves to — a pin from before
  ## the override was set, or before it moved on. Anything else pinned is a
  ## real catalog choice and is left alone.
  let idx = spec.find(':')
  if idx < 0:
    return false
  let name = spec[0 ..< idx]
  let pinnedModel = spec[idx + 1 .. ^1]
  if pinnedModel.len == 0:
    return false
  for p in providers:
    if p.name != name:
      continue
    if p.modelEnv.len == 0 and p.smallModelEnv.len == 0:
      return false
    if pinnedModel != p.model and pinnedModel != p.smallModel:
      return false
    let (liveModel, liveSmall) = modelsNow(p)
    return pinnedModel != liveModel and pinnedModel != liveSmall
  return false

proc pinnedSpecs*(home: string, providers: seq[Provider]): seq[string] =
  ## The curated `provider:model` shortlist from `home/models.json`, minus
  ## stale platform pins. Missing-file details fall back to the defaults; a
  ## present-but-pinless file keeps its empty choice, like Python.
  let path = home / "models.json"
  if not fileExists(path):
    return defaultPinnedSpecs(providers)
  var saved: JsonNode
  try:
    saved = parseJson(readFile(path))
  except CatchableError:
    return defaultPinnedSpecs(providers)
  if saved.kind != JObject:
    return defaultPinnedSpecs(providers)
  if not saved.hasKey("pinned"):
    return @[]
  if saved["pinned"].kind != JArray:
    return defaultPinnedSpecs(providers)
  for item in saved["pinned"]:
    if item.kind == JString and not stalePlatformPin(item.getStr(), providers):
      result.add(item.getStr())

proc defaultModelFor*(provider, home: string,
                      providers: seq[Provider]): string =
  ## A provider's default model = the FIRST one pinned for it. "" means
  ## "use the provider's built-in default".
  for spec in pinnedSpecs(home, providers):
    let idx = spec.find(':')
    if idx >= 0 and spec[0 ..< idx] == provider and idx + 1 < spec.len:
      return spec[idx + 1 .. ^1]
  return ""

proc savePinned*(home: string, specs: seq[string]) =
  ## Persist the curated shortlist, in order. The ONLY writer of
  ## `models.json` — keep it that way.
  createDir(home)
  writeFile(home / "models.json", pretty(%*{"pinned": specs}, 1))
