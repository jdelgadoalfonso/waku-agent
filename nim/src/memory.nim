## Memory — port of `waku/memory/semantic/store.py` (`_fts_query`, facts)
## and `waku/memory/episodic/store.py` (episodes).
##
## Unit 1b (the FTS5 parity gate) is the pure `ftsQuery` plus its vectors in
## `tests/test_fts.nim`. Unit 1c builds the SQLite-backed `Fact`/`Episode`
## stores below on top of `db.nim` and `ftsQuery`.

import std/strutils
import std/unicode

import db_connector/db_sqlite

func isWordRune*(r: Rune): bool =
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

type
  Fact* = object
    ## One row of `facts`. `source` is 'user' or 'consolidation'.
    id*: int64
    subject*: string
    content*: string
    source*: string
    createdAt*: string

  Episode* = object
    ## One row of `episodes`.
    id*: int64
    happenedAt*: string
    summary*: string
    createdAt*: string

proc addFact*(db: DbConn, subject, content: string,
              source = "user") =
  ## Port of `SqliteFactStore.add`: subject stored lowercased+stripped.
  db.exec(sql"INSERT INTO facts (subject, content, source) VALUES (?,?,?)",
          subject.toLower().strip(), content, source)

proc searchFacts*(db: DbConn, query: string, topK = 4): seq[string] =
  ## Port of `SqliteFactStore.search`: BM25-ranked `"[subject] content"`.
  ## An empty query is not a search — it returns no rows.
  let fts = ftsQuery(query)
  if fts.len == 0:
    return @[]
  for row in db.getAllRows(sql("SELECT f.subject, f.content FROM facts_fts " &
      "JOIN facts f ON f.id = facts_fts.rowid " &
      "WHERE facts_fts MATCH ? ORDER BY rank LIMIT ?"), fts, $topK):
    result.add("[" & row[0] & "] " & row[1])

proc listFacts*(db: DbConn, limit = 200): seq[Fact] =
  ## Newest first. Port of `SqliteFactStore.list`.
  for row in db.getAllRows(sql("SELECT id, subject, content, source, created_at " &
      "FROM facts ORDER BY id DESC LIMIT ?"), $limit):
    result.add(Fact(id: parseBiggestInt(row[0]), subject: row[1],
                    content: row[2], source: row[3], createdAt: row[4]))

proc searchFactsWithIds*(db: DbConn, query: string,
                         topK = 8): seq[Fact] =
  ## Port of `search_with_ids`: ranked rows, or the newest rows when the
  ## query carries no searchable token.
  let fts = ftsQuery(query)
  if fts.len == 0:
    return listFacts(db, topK)
  for row in db.getAllRows(sql("SELECT f.id, f.subject, f.content FROM facts_fts " &
      "JOIN facts f ON f.id = facts_fts.rowid " &
      "WHERE facts_fts MATCH ? ORDER BY rank LIMIT ?"), fts, $topK):
    result.add(Fact(id: parseBiggestInt(row[0]), subject: row[1],
                    content: row[2], source: "", createdAt: ""))

proc updateFactContent*(db: DbConn, id: int64, content: string): bool =
  ## Port of `update` without subject: content only. True when a row moved.
  db.execAffectedRows(sql"UPDATE facts SET content=? WHERE id=?",
                      content, $id) > 0

proc updateFact*(db: DbConn, id: int64, content, subject: string): bool =
  ## Port of `update` with subject (stored lowercased+stripped).
  ## Split from `updateFactContent` so "no subject change" needs no sentinel:
  ## Python spells it `subject=None`, which has no Nim default-arg equivalent.
  db.execAffectedRows(sql"UPDATE facts SET content=?, subject=? WHERE id=?",
                      content, subject.toLower().strip(), $id) > 0

proc deleteFact*(db: DbConn, id: int64): bool =
  ## Port of `SqliteFactStore.delete`. True when a row moved.
  db.execAffectedRows(sql"DELETE FROM facts WHERE id=?", $id) > 0

proc settle*(): bool =
  ## Port of `SqliteFactStore.settle`: always settled — the row and its
  ## FTS5 index land in one step, so a fact is searchable the instant
  ## `addFact` returns. (No `timeout` param: there is nothing to wait for.)
  true

proc addEpisode*(db: DbConn, summary, happenedAt: string) =
  ## Port of `SqliteEpisodeStore.add`.
  db.exec(sql"INSERT INTO episodes (happened_at, summary) VALUES (?,?)",
          happenedAt, summary)

proc recentEpisodes*(db: DbConn, topK = 3): seq[string] =
  ## Port of `SqliteEpisodeStore.recent`: newest `happened_at` first.
  for row in db.getAllRows(sql("SELECT happened_at, summary FROM episodes " &
      "ORDER BY happened_at DESC LIMIT ?"), $topK):
    result.add("(" & row[0] & ") " & row[1])

proc searchEpisodes*(db: DbConn, query: string, topK = 3): seq[string] =
  ## Port of `SqliteEpisodeStore.search`: relevance first, most recent
  ## first among matches; an empty query falls back to `recentEpisodes`.
  let fts = ftsQuery(query)
  if fts.len == 0:
    return recentEpisodes(db, topK)
  for row in db.getAllRows(sql("SELECT e.happened_at, e.summary FROM episodes_fts " &
      "JOIN episodes e ON e.id = episodes_fts.rowid " &
      "WHERE episodes_fts MATCH ? ORDER BY rank, e.happened_at DESC LIMIT ?"),
      fts, $topK):
    result.add("(" & row[0] & ") " & row[1])

proc listEpisodes*(db: DbConn, limit = 200): seq[Episode] =
  ## Newest first. Port of `SqliteEpisodeStore.list`.
  for row in db.getAllRows(sql("SELECT id, happened_at, summary, created_at " &
      "FROM episodes ORDER BY id DESC LIMIT ?"), $limit):
    result.add(Episode(id: parseBiggestInt(row[0]), happenedAt: row[1],
                       summary: row[2], createdAt: row[3]))

proc deleteEpisode*(db: DbConn, id: int64): bool =
  ## Port of `SqliteEpisodeStore.delete`. True when a row moved.
  db.execAffectedRows(sql"DELETE FROM episodes WHERE id=?", $id) > 0
