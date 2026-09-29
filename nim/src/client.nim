## Client — port of `get_client` in `waku/loop/models.py`: settings to a
## live `LlmClient`, or a helpful error.
##
## Every failure here is a startup error with the fix in it (unknown
## provider names the visible ones; a hidden row names its variable; a
## missing key says what to set and which file is in play; a pasted smart
## quote is called out). Raised as `ClientConfigError`; the CLI prints the
## message and exits 1, like Python's `SystemExit`.
##
## ONE DIVERGENCE: rows may omit `base_url` when the SDK default is right
## (anthropic, openai). Python leans on the SDK; the Nim transport always
## posts to `baseUrl & path`, so the two well-known public defaults are
## filled in here (`https://api.anthropic.com`,
## `https://api.openai.com/v1`). Timeout (`WAKU_LLM_TIMEOUT`) has no
## transport knob yet and is skipped — noted, not silent.

import std/os
import std/strutils
import std/unicode

import ./config
import ./http
import ./loop
import ./providers

export loop

type
  ClientConfigError* = object of CatchableError
    ## `get_client`'s `SystemExit`: configuration, not a bug.

proc sdkDefaultBaseUrl(kind: string): string =
  ## The endpoint an SDK would use when the row omits `base_url`.
  if kind == "anthropic": "https://api.anthropic.com"
  else: "https://api.openai.com/v1"

proc clientFor*(s: var Settings, providers: seq[Provider], globalKey,
                dotenvPath: string): LlmClient =
  ## Build the client for `s.provider` and fill in the default model ids
  ## (`models_for`, so the turn and the pickers can never name different
  ## models). Key handling is verbatim: stripped (a pasted trailing space
  ## must not corrupt the latin-1 auth header), scoped rows never falling
  ## back to the global override, non-latin-1 rejected with the re-paste
  ## hint. Same for the endpoint: `WAKU_BASE_URL` never leaks into a
  ## scoped row's own URL.
  var row: Provider
  var found = false
  for p in providers:
    if p.name == s.provider:
      row = p
      found = true
      break
  if not found:
    raise newException(ClientConfigError,
      "Unknown WAKU_PROVIDER '" & s.provider & "'. Pick one of: " &
      visibleNames(providers).join(", "))
  if not row.isVisible():
    raise newException(ClientConfigError,
      "'" & s.provider & "' is not configured: set " & row.baseUrlEnv &
      " to enable it.")
  let apiKey = row.resolveApiKey(globalKey)
  if apiKey.len == 0:
    raise newException(ClientConfigError,
      missingKeyMessage(s.provider, row.keyEnv, row.keyUrl, dotenvPath,
                        visibleNames(providers)))
  for r in apiKey.runes:
    if r.ord > 0xFF:
      raise newException(ClientConfigError,
        row.keyEnv & " contains a non-ASCII character (e.g. a smart quote " &
        "or arrow from a bad paste). Re-paste the key with no spaces or " &
        "line breaks.")
  (s.model, s.smallModel) = modelsFor(s.provider, s.model, s.smallModel,
                                      providers)
  let configured = if row.baseUrlEnv.len > 0:
    getEnv(row.baseUrlEnv, "").strip() else: ""
  let rowBase = if configured.len > 0: configured else: row.baseUrl
  let base = if row.scopedCredentials: rowBase
             elif s.baseUrl.len > 0: s.baseUrl else: rowBase
  let url = if base.len > 0: base else: sdkDefaultBaseUrl(row.kind)
  let wire = if row.kind == "anthropic": wkAnthropic else: wkOpenAi
  toLlmClient(Transport(baseUrl: url, apiKey: apiKey, wire: wire))
