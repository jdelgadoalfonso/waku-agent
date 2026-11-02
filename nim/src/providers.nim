## Provider registry — port of `data/providers.toml` plus the resolution
## rules in `waku/loop/models.py` (`models_for`, `_belongs_elsewhere`,
## the scoped-credentials key fallback and the no-key message).
##
## Only the TOML subset the registry uses is parsed: `[name]` tables with
## `key = "value"` strings, `true`/`false` flags and `price = [in, out]`
## lists. `[[array]]` tables (regional endpoints) and other non-string
## values are skipped.

import std/algorithm
import std/os
import std/strutils
import std/tables

type
  Provider* = object
    ## One row of `data/providers.toml`. Empty string means the row sets
    ## nothing and the reader falls back, like the Python dataclass.
    name*: string
    kind*: string            ## wire format: "anthropic" or "openai"
    keyEnv*: string          ## env var holding the key
    baseUrl*: string
    model*: string           ## loop default
    smallModel*: string      ## gate + consolidation default
    catalogUrl*: string
    flagship*: string
    fast*: string
    baseUrlEnv*: string
    keyUrl*: string          ## printed when the key is missing
    label*: string
    hiddenUnlessEnv*: bool
    claimsFamilies*: bool
    catalogFromBaseUrl*: bool
    modelEnv*: string
    smallModelEnv*: string
    scopedCredentials*: bool ## hosted row: never fall back to WAKU_API_KEY
    priceIn*: float          ## rough $/M input tokens (providers.toml `price`)
    priceOut*: float         ## rough $/M output tokens

proc defaultProvider(name: string): Provider =
  ## A row with no fields set. `claimsFamilies` defaults to true, matching
  ## the Python dataclass; every other flag defaults to false. The price
  ## defaults to the unknown-provider estimate in `pricing.priceFor`.
  result = Provider(name: name, claimsFamilies: true, priceIn: 3.0,
                    priceOut: 15.0)

proc setStringField(p: var Provider, key, value: string) =
  case key
  of "kind": p.kind = value
  of "key_env": p.keyEnv = value
  of "base_url": p.baseUrl = value
  of "model": p.model = value
  of "small_model": p.smallModel = value
  of "catalog_url": p.catalogUrl = value
  of "flagship": p.flagship = value
  of "fast": p.fast = value
  of "base_url_env": p.baseUrlEnv = value
  of "key_url": p.keyUrl = value
  of "label": p.label = value
  of "model_env": p.modelEnv = value
  of "small_model_env": p.smallModelEnv = value
  else: discard

proc setBoolField(p: var Provider, key: string, value: bool) =
  case key
  of "hidden_unless_env": p.hiddenUnlessEnv = value
  of "claims_families": p.claimsFamilies = value
  of "catalog_from_base_url": p.catalogFromBaseUrl = value
  of "scoped_credentials": p.scopedCredentials = value
  else: discard

proc parsePriceField(p: var Provider, rawValue: string) =
  ## Parse `price = [in, out]` into the row. A malformed list is skipped,
  ## keeping the row default — like every other unknown value, never fatal.
  let v = rawValue.strip()
  if not (v.startsWith("[") and v.endsWith("]")):
    return
  let parts = v[1 ..< ^1].split(",")
  if parts.len != 2:
    return
  try:
    p.priceIn = parseFloat(parts[0].strip())
    p.priceOut = parseFloat(parts[1].strip())
  except ValueError:
    discard

proc unquote*(value: string): (bool, string) =
  ## A quoted string, as `(found, text)`. Exported because the connections
  ## registry (`integrations.parseIntegrationRows`) reads the same TOML subset
  ## out of its own file: one vocabulary beats two readers drifting apart.
  let v = value.strip()
  if v.len >= 2 and v[0] == '"' and v[^1] == '"':
    return (true, v[1 ..< ^1])
  return (false, v)

proc stripInlineComment*(line: string): string =
  ## Drop a `#` comment that starts outside a quoted value. Exported beside
  ## `unquote`, for the same second reader. A `#` inside
  ## quotes (a URL fragment) survives; a commented header like
  ## `[foo] # note` becomes `[foo]`.
  var inQuotes = false
  for i, ch in line:
    if ch == '"':
      inQuotes = not inQuotes
    elif ch == '#' and not inQuotes:
      return line[0 ..< i].strip()
  return line

proc parseProviders*(text: string): seq[Provider] =
  ## Parse the registry TOML subset. Unknown keys, `[[array]]` tables and
  ## non-string values are skipped, never fatal.
  var inArray = false
  for rawLine in text.splitLines():
    let line = stripInlineComment(rawLine.strip())
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("["):
      # Any bracket line skips its section unless it is a valid table
      # header, so a malformed header can never merge keys into the
      # previous provider row.
      inArray = true
      if not line.startsWith("[[") and line.endsWith("]"):
        inArray = false
        result.add(defaultProvider(line[1 ..< ^1].strip()))
      continue
    if inArray or result.len == 0:
      continue
    let eq = line.find('=')
    if eq <= 0:
      continue
    let key = line[0 ..< eq].strip()
    let rawValue = line[eq + 1 .. ^1].strip()
    let (ok, value) = unquote(rawValue)
    if ok:
      setStringField(result[^1], key, value)
    elif rawValue == "true" or rawValue == "false":
      setBoolField(result[^1], key, rawValue == "true")
    elif key == "price":
      parsePriceField(result[^1], rawValue)
    # Anything else (numbers, other lists) is not registry data: skip.

proc loadProviders*(path: string): seq[Provider] =
  ## Read and parse a providers.toml file.
  parseProviders(readFile(path))

proc families*(p: Provider): seq[string] =
  ## The model FAMILIES this provider ships ("claude", "grok", "gemini"):
  ## first `-`-segments of its four defaults, vendor-namespaced ids with
  ## `/` excluded. Taken from the row itself, never a hand-kept list.
  for n in [p.model, p.smallModel, p.flagship, p.fast]:
    if n.len == 0 or "/" in n:
      continue
    let f = n.split("-")[0].toLowerAscii()
    if f.len > 0 and f notin result:
      result.add(f)

proc belongsElsewhere*(model, providerName: string,
                       providers: seq[Provider]): bool =
  ## Is this model name positively another provider's? Asks the POSITIVE
  ## question on purpose: anything unfamiliar stays, only a family some
  ## OTHER provider owns is dropped (it would 400, not surprise).
  ## A `claims_families = false` row (hosted free tier) owns nothing but is
  ## still judged by the map.
  if "/" in model:
    return false
  let family = model.split("-")[0].toLowerAscii()
  if family.len == 0:
    return false
  var owners = initTable[string, string]()
  for p in providers:
    if p.claimsFamilies and "/" notin p.model:
      for f in families(p):
        owners[f] = p.name
  let owner = owners.getOrDefault(family, "")
  return owner.len > 0 and owner != providerName

proc modelsNow*(p: Provider): (string, string) =
  ## The row's defaults with `model_env`/`small_model_env` overrides applied,
  ## so a hosted placeholder id never leaks to callers.
  var model = p.model
  var small = p.smallModel
  if p.modelEnv.len > 0:
    let override = getEnv(p.modelEnv, "").strip()
    if override.len > 0:
      model = override
  if p.smallModelEnv.len > 0:
    let override = getEnv(p.smallModelEnv, "").strip()
    if override.len > 0:
      small = override
  return (model, small)

proc modelsFor*(providerName, model, smallModel: string,
                providers: seq[Provider]): (string, string) =
  ## The model ids a turn against `providerName` will ACTUALLY run. A
  ## WAKU_MODEL/WAKU_SMALL_MODEL value inherited from the environment that
  ## belongs to another provider is dropped before the row default applies.
  let inheritedModel = getEnv("WAKU_MODEL", "").strip()
  let inheritedSmall = getEnv("WAKU_SMALL_MODEL", "").strip()
  var m = model
  var s = smallModel
  if inheritedModel.len > 0 and m == inheritedModel and
      belongsElsewhere(inheritedModel, providerName, providers):
    m = ""
  if inheritedSmall.len > 0 and s == inheritedSmall and
      belongsElsewhere(inheritedSmall, providerName, providers):
    s = ""
  for p in providers:
    if p.name == providerName:
      let (dm, ds) = modelsNow(p)
      if m.len == 0:
        m = dm
      if s.len == 0:
        s = ds
      return (m, s)
  return (m, s)

proc isVisible*(p: Provider): bool =
  ## False while a hidden row's endpoint is unset: a local user must never
  ## see the hosted row in a page, a list or an error message.
  if not p.hiddenUnlessEnv:
    return true
  if p.baseUrlEnv.len == 0:
    return false
  return getEnv(p.baseUrlEnv, "").strip().len > 0

proc visibleNames*(providers: seq[Provider]): seq[string] =
  ## Provider names a local user is allowed to see, sorted.
  for p in providers:
    if p.isVisible():
      result.add(p.name)
  result.sort()

proc resolveApiKey*(p: Provider, globalKey: string): string =
  ## Where this row's key comes from. A scoped-credentials row never falls
  ## back to the global WAKU_API_KEY override; everyone else prefers it.
  ## Truthiness is tested pre-strip like the Python source, so a
  ## whitespace-only global key yields "" instead of falling through.
  if p.scopedCredentials:
    return getEnv(p.keyEnv, "").strip()
  if globalKey.len > 0:
    return globalKey.strip()
  return getEnv(p.keyEnv, "").strip()

proc missingKeyMessage*(name, keyEnv, keyUrl, dotenvPath: string,
                        others: seq[string]): string =
  ## Say what to set, where to get it, and WHICH file is in play.
  var msg = "No API key for provider '" & name & "'.\n\n"
  if keyUrl.len > 0:
    msg &= "  1. Get a key: " & keyUrl & "\n"
  var where: string
  if dotenvPath.len > 0:
    where = "Add it to " & dotenvPath & ":\n    " & keyEnv & "=your-key-here"
  else:
    where = "No .env found from " & getCurrentDir() &
      " upward \u2014 create one here:\n    echo '" & keyEnv &
      "=your-key-here' >> .env"
  msg &= "  2. " & where & "\n\n"
  msg &= "Other providers: " & others.join(", ") & "\n"
  msg &= "Switch with WAKU_PROVIDER=<name> and that provider's key."
  return msg
