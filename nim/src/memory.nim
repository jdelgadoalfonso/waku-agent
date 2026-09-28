## Memory — port of `waku/memory/semantic/store.py` (`_fts_query`, facts)
## and `waku/memory/episodic/store.py` (episodes).
##
## Unit 1b (the FTS5 parity gate) is the pure `ftsQuery` plus its vectors in
## `tests/test_fts.nim`. Unit 1c builds the SQLite-backed `Fact`/`Episode`
## stores below on top of `db.nim` and `ftsQuery`.

import std/strutils
import std/unicode

import db_connector/db_sqlite

func isWordRune(r: Rune): bool =
  ## One `[^\W_]` character: a Unicode letter or an ASCII digit.
  ## Underscore is a separator (unicode61 splits `waku_agent` in two).
  ## Known gap vs Python `str.isalnum`: non-ASCII numbers (Nd/Nl/No such as
  ## U+0663 or U+00B2) are separators here. Documented, not planned: memory
  ## queries with non-ASCII numerals are vanishingly rare, and the index
  ## (unicode61, SQLite-side) is untouched — only exotic query tokens split.
  isAlpha(r) or (r.ord >= ord('0') and r.ord <= ord('9'))

func isUnsegmented(r: Rune): bool =
  ## A rune from a script unicode61 does not segment (Hiragana, Katakana,
  ## CJK Extension A, CJK Unified, CJK Compatibility): a whole run is one
  ## index term, so only these tokens are searched as `prefix*`. Same ranges
  ## as `_UNSEGMENTED` in `waku/memory/semantic/store.py`.
  let o = r.ord
  (o >= 0x3040 and o <= 0x309F) or
  (o >= 0x30A0 and o <= 0x30FF) or
  (o >= 0x3400 and o <= 0x4DBF) or
  (o >= 0x4E00 and o <= 0x9FFF) or
  (o >= 0xF900 and o <= 0xFAFF)

proc ftsQuery*(text: string): string =
  ## Reduce user text to `word OR word OR ...` over alphanumeric tokens.
  ## Port of `_fts_query`: lowercase first (so a user's "and" never parses
  ## as the FTS5 `AND` operator), keep runs of 2+ word runes, dedupe keeping
  ## first occurrence, `*`-suffix unsegmented-script tokens, empty when no
  ## token survives (callers read that as "no query").
  var words: seq[string] = @[]
  var cur = ""
  var curLen = 0
  for r in runes(text.toLower()):
    if isWordRune(r):
      cur.add($r)
      inc curLen
    else:
      if curLen >= 2 and cur notin words:
        words.add(cur)
      cur = ""
      curLen = 0
  if curLen >= 2 and cur notin words:
    words.add(cur)
  if words.len == 0:
    return ""
  for w in words.mitems():
    for r in runes(w):
      if isUnsegmented(r):
        w.add("*")
        break
  return words.join(" OR ")
