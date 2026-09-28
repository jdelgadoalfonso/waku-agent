## save_note — port of `waku/tools/notes.py`.
##
## The explicit memory path ("remember that Alex prefers mornings").

import std/strutils

import db_connector/db_sqlite

proc saveNote*(db: DbConn, subject, content: string): string =
  ## INSERT the fact (subject stored lowercased+stripped) and say so.
  ## The message quotes the ORIGINAL subject, same as Python.
  db.exec(sql"INSERT INTO facts (subject, content, source) VALUES (?,?,'user')",
          subject.toLower().strip(), content)
  return "Saved to memory under '" & subject & "': " & content
