## JSON in Python's handwriting — `json.dumps` defaults, twice removed.
##
## Two Nim-port surfaces need byte-level `json.dumps` parity (the dashboard
## reads these files, so "parses the same" is not enough):
##
## - `jsonDumps`: `json.dumps` defaults — separators `(", ", ": ")`,
##   `ensure_ascii=True` (lowercase `\uXXXX`, surrogate pairs past U+FFFF),
##   insertion order. Used for `usage.jsonl` and the chat `meta` column.
##   Traces stay human-readable (`$`, raw UTF-8), exactly like Python's
##   `ensure_ascii=False` there.
## - `pyStr`: Python `str()` of tool args for the `[tools used: ...]`
##   history line (`{'text': 'x'}`, `True`/`False`/`None`). Prompt text
##   only — the dashboard's turn card reads `meta`, never this line — so
##   exotic values (nested quotes, astral chars) render sensibly rather
##   than byte-exactly.

import std/json
import std/strutils
import std/unicode

proc dumpsStr(s: string, res: var string) =
  ## One JSON string with `ensure_ascii=True` (Python's default).
  res.add('"')
  for r in s.runes:
    let o = r.ord
    case o
    of 0x22: res.add("\\\"")
    of 0x5C: res.add("\\\\")
    of 0x0A: res.add("\\n")
    of 0x0D: res.add("\\r")
    of 0x09: res.add("\\t")
    of 0x08: res.add("\\b")
    of 0x0C: res.add("\\f")
    elif o < 0x20: res.add("\\u00" & o.toHex(2).toLowerAscii())
    elif o < 0x7F: res.add(chr(o))
    elif o <= 0xFFFF: res.add("\\u" & o.toHex(4).toLowerAscii())
    else:
      # astral plane: UTF-16 surrogate pair, like CPython's ensure_ascii
      let v = o - 0x10000
      res.add("\\u" & (0xD800 + (v shr 10)).toHex(4).toLowerAscii())
      res.add("\\u" & (0xDC00 + (v and 0x3FF)).toHex(4).toLowerAscii())
  res.add('"')

proc dumpsNode(node: JsonNode, res: var string) =
  case node.kind
  of JString: dumpsStr(node.getStr(), res)
  of JInt: res.add($node.getBiggestInt())
  of JFloat: res.add($node.getFloat())
  of JBool: res.add(if node.getBool(): "true" else: "false")
  of JNull: res.add("null")
  of JArray:
    res.add('[')
    for i in 0 ..< node.len:
      if i > 0: res.add(", ")
      dumpsNode(node[i], res)
    res.add(']')
  of JObject:
    res.add('{')
    var first = true
    for key, value in pairs(node):
      if not first: res.add(", ")
      first = false
      dumpsStr(key, res)
      res.add(": ")
      dumpsNode(value, res)
    res.add('}')

proc jsonDumps*(node: JsonNode): string =
  ## `json.dumps(node)` with default settings. Inf/NaN floats have no JSON
  ## form (Python emits bare `Infinity`); the port's writers only ever
  ## store ints and strings, so this refuses nothing and documents the gap.
  dumpsNode(node, result)

proc pyStrQuote(s: string): string =
  ## `repr` of a str for the common case: single quotes, backslash and
  ## quote escaped. (Full repr picks double quotes when the value holds a
  ## single quote; tool args with both quote kinds render sensibly here
  ## instead of byte-exactly — prompt text, not a contract.)
  result = "'"
  for ch in s:
    if ch == '\\': result.add("\\\\")
    elif ch == '\'': result.add("\\'")
    else: result.add(ch)
  result.add("'")

proc pyStr*(node: JsonNode): string =
  ## Python `str()` of a JSON value: `{'text': 'x'}`, `[1, True, None]`.
  case node.kind
  of JString: pyStrQuote(node.getStr())
  of JInt: $node.getBiggestInt()
  of JFloat: $node.getFloat()
  of JBool: (if node.getBool(): "True" else: "False")
  of JNull: "None"
  of JArray:
    var items: seq[string] = @[]
    for item in items(node): items.add(pyStr(item))
    "[" & items.join(", ") & "]"
  of JObject:
    var items: seq[string] = @[]
    for key, value in pairs(node):
      items.add(pyStrQuote(key) & ": " & pyStr(value))
    "{" & items.join(", ") & "}"
