## send_message — port of `waku/tools/messages.py`.
##
## Local-first: nothing is ever sent. Each message becomes a file in
## `<home>/outbox/` to read, edit, and send by hand.
##
## One deliberate deviation: `sendMessage` creates `outbox/` on demand.
## Python relies on `ensure_home` having run first; a Nim binary invoked
## anywhere should not fail drafting into a fresh home (same rationale as
## `connectDb` creating `home`).
##
## `safeName` reuses the word-rune rule, so the documented non-ASCII-numeral
## gap applies to filenames too — a conservative direction for a filename.

import std/os
import std/times
import std/unicode

import ./memory

proc safeName*(to: string, maxLen = 40): string =
  ## Alphanumeric runes stay, everything else becomes `-`, cut to 40.
  ## Port of `"".join(c if c.isalnum() else "-" for c in to)[:40]`
  ## (Python `isalnum` rejects `_` too — and so does `isWordRune`).
  var res = ""
  var n = 0
  for r in runes(to):
    if n >= maxLen:
      break
    res.add(if isWordRune(r): $r else: "-")
    inc n
  return res

proc utcStamp*(): string =
  ## `YYYYMMDDTHHMMSS` in UTC. Port of `datetime.now(UTC).strftime`.
  format(now().utc, "yyyyMMdd'T'HHmmss")

proc sendMessage*(home, to, body: string, stamp = ""): string =
  ## Draft `<stamp>-<safe-to>.txt` into the outbox and say so.
  ## `stamp` is injectable for deterministic tests; empty means "now".
  let s = if stamp.len > 0: stamp else: utcStamp()
  let fileName = s & "-" & safeName(to) & ".txt"
  createDir(home / "outbox")
  writeFile(home / "outbox" / fileName, "To: " & to & "\n\n" & body & "\n")
  return "Message to " & to & " placed in outbox (" & fileName &
    "). Nothing was sent — review it there."
