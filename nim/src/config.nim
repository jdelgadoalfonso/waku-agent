## Configuration — every knob is an env var, documented in `.env.example`.
##
## Phase 0 port of the `waku/config.py` subset: the `Settings` object, the
## `WAKU_*` env overrides and a small `.env` line parser. No settings
## framework: a plain object read once at startup. If you can read this file,
## you know everything the port can be configured to do so far.

import std/os
import std/strutils

type
  Settings* = object
    ## Where the LLM, the keys and the state directory live.
    provider*: string
      ## LLM provider id (a row in `waku/providers.toml`, see `waku/loop/models.py`).
    apiKey*: string
      ## Explicit `WAKU_API_KEY` override. Empty means the provider's own
      ## key env var and default models are used.
    model*: string
      ## Explicit `WAKU_MODEL` override. Empty means the provider's
      ## default models are used.
    home*: string
      ## `WAKU_HOME`: where Waku keeps its state (memory DB, calendar,
      ## outbox, traces). Local-first means you can always look.

proc defaultSettings*(): Settings =
  ## Settings before any env var is read (the Python dataclass defaults).
  Settings(provider: "anthropic", apiKey: "", model: "", home: ".waku")

proc loadFromEnv*(s: var Settings) =
  ## Read the `WAKU_*` env vars into `s`, keeping the sensible default
  ## when a var is unset.
  s.provider = getEnv("WAKU_PROVIDER", "anthropic")
  s.apiKey = getEnv("WAKU_API_KEY")
  s.model = getEnv("WAKU_MODEL")
  s.home = getEnv("WAKU_HOME", ".waku")

proc loadSettings*(): Settings =
  ## Port of `waku/config.py` `load_settings`: read the env vars once
  ## at startup.
  result = defaultSettings()
  result.loadFromEnv()

proc parseDotenvLine*(line: string): (string, string) =
  ## Parse one `.env` line as `KEY=VALUE`.
  ##
  ## Blank lines and `#` comments return `("", "")`, and a line without `=`
  ## is ignored the same way. Quotes around the value are stripped when they
  ## wrap the whole value (single or double). A `=` inside the value survives.
  let trimmed = line.strip()
  if trimmed.len == 0 or trimmed.startsWith("#"):
    return ("", "")
  let eq = trimmed.find('=')
  if eq <= 0:
    return ("", "")
  let key = trimmed[0 ..< eq].strip()
  var value = trimmed[eq + 1 .. ^1].strip()
  if value.len >= 2 and
      ((value[0] == '"' and value[^1] == '"') or
       (value[0] == '\'' and value[^1] == '\'')):
    value = value[1 ..< ^1]
  return (key, value)
