## save_note — port of `waku/tools/notes.py`.
##
## The explicit memory path ("remember that Alex prefers mornings").
## The *implicit* path is consolidation (memory_live.nim), which
## distills facts out of chat history without being asked.
##
## Spec 018: with Waku Memory connected, the fact is also sent
## there, through the same `remember` callable consolidation
## uses, and the answer names where it went. Until then the
## answer said "Saved to memory" while the fact stayed on this
## agent, and the model told the person it was saved.

import std/strutils

import db_connector/db_sqlite

import ./db

const noteScope* = "global"
  ## The scope every save_note fact goes to in Waku Memory
  ## (Python's `SCOPE`). The one place the name lives;
  ## everything else is remembered in scope "global".

const reasonMax* = 80
  ## `REASON_MAX`: one short line a person can read.

type Remember* = proc(content, scope: string): string {.closure.}
  ## One fact to Waku Memory: stores it and returns the id
  ## the server named ("" when it named none). Raises when
  ## the send failed. Port of the `remember` callable
  ## `waku/tools/waku_memory.py` builds from the MCP
  ## connection. The Nim port declares the seam; nothing
  ## fills it yet, because Waku Memory itself is a hosted
  ## backend and those stay Python-only.

proc failureReason*(exc: ref CatchableError): string =
  ## One short line a person can read: the first line of
  ## the error, cut. Port of `_reason`.
  let lines = exc.msg.strip().splitLines()
  let first = if lines.len > 0 and lines[0].len > 0: lines[0]
              else: $exc.name
  if first.len > reasonMax: first[0 ..< reasonMax] else: first

proc saveNote*(db: DbConn, subject, content: string,
               remember: Remember = nil): string =
  ## Store the fact (subject lowercased+stripped) and say
  ## where it went. With `remember`, the fact is stored
  ## unsynced first and marked once the send works, so a
  ## failed send, or a process that dies mid-send, leaves
  ## the fact for the next consolidation to retry
  ## (spec 006). Without it, the fact is saved here only
  ## and the answer says exactly that.
  let subject = subject.toLower().strip()
  if remember.isNil:
    db.exec(sql"INSERT INTO facts (subject, content, source) VALUES (?,?,'user')",
            subject, content)
    return "Saved here. Waku Memory is not connected."
  db.exec(sql"INSERT INTO facts (subject, content, source, synced, scope) VALUES (?,?,'user',0,?)",
          subject, content, noteScope)
  let rowId = db.getValue(sql"SELECT last_insert_rowid()")
  try:
    let memoryId = remember(content, noteScope)
    db.exec(sql"UPDATE facts SET synced = 1 WHERE id = ?", rowId)
    return "Saved here and in Waku Memory" &
      (if memoryId.len > 0: " (id " & memoryId & ")" else: "") & "."
  except CatchableError as exc:
    return "Saved here. Waku Memory did not take it (" &
      failureReason(exc) & "); it is sent again later."
