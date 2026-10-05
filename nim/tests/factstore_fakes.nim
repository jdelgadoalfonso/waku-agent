## A stateful fake of a hosted `FactStore`, for the conformance suite.
##
## NOT a suite: the file deliberately does not start with `test`, so
## `nimble test` does not compile it on its own. It exists because the
## conformance suite has to run every rule against every backend, and a hosted
## backend cannot be reached from a test that must stay offline — Python's own
## version gates mem0 behind `WAKU_TEST_MEM0=1` because a maintainer running
## the suite must not fill somebody's real Mem0 workspace with test facts about
## Priya's meeting preferences.
##
## So this fake is what makes the contract a real gate: it holds rows in
## memory, answers substring searches, and obeys the same three rules the
## contract states. A backend that gets one of them wrong here is wrong against
## a real service too, because the rules are about the adapter, not the wire.
##
## Its `add` stores verbatim — which is what v3's async extraction does NOT
## guarantee, and why the strict round-trip rule is asserted against this fake
## and kept opt-in against the real service (see
## `odd/tasks/nim-mem0-store.md` L7).

import std/algorithm
import std/math
import std/strutils

import ../src/factstore

var fakeRows: seq[StoreFact] = @[]

proc resetFake*() =
  fakeRows = @[]

proc hits(fact: StoreFact, query: string): bool =
  ## Any token of the query matching subject or content — a deliberate
  ## stand-in for a semantic search, and enough for the contract's rules: a
  ## round trip has to find what was stored, and a miss has to find nothing.
  ##
  ## Tokens, not the whole string: `search_with_ids("elon launch")` is one
  ## query and the fact holds "elon" and "The launch is in March", which a
  ## substring fake would miss. A fake that is stricter than the service it
  ## stands in for fails the round-trip rule for a reason that has nothing to
  ## do with the adapter under test.
  let haystack = fact.subject.toLowerAscii() & " " & fact.content.toLowerAscii()
  var any = false
  for token in query.toLowerAscii().splitWhitespace():
    if token.len >= 2 and haystack.contains(token):
      any = true
  any

proc mem0FakeStore*(): FactStore =
  ## A hosted backend, minus the hosted part: same contract, rows in memory,
  ## and it starts with one row so `list` on an untouched store has something
  ## to say — the shape a real service always has, and the one a naive fake
  ## gets wrong.
  resetFake()
  fakeRows.add(StoreFact(id: "mem-1", subject: "seed", content: "seeded row",
                         source: "user", createdAt: "2026-01-01T00:00:00Z"))
  var next = 2

  result.add = proc(subject, content, source: string) =
    fakeRows.add(StoreFact(id: "mem-" & $next,
                           subject: subject.toLowerAscii().strip(),
                           content: content, source: source,
                           createdAt: "2026-01-01T00:00:00Z"))
    inc next

  result.search = proc(query: string, topK: int): seq[string] =
    var found: seq[string] = @[]
    for fact in fakeRows:
      if fact.hits(query):
        found.add("[" & fact.subject & "] " & fact.content)
    found

  result.list = proc(limit: int): seq[StoreFact] =
    fakeRows

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    var found: seq[StoreFact] = @[]
    for fact in fakeRows:
      if fact.hits(query):
        found.add(fact)
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    for i, fact in fakeRows:
      if fact.id == id:
        fakeRows[i].content = content
        if subject.len > 0:
          fakeRows[i].subject = subject.toLowerAscii().strip()
        return true
    false

  result.delete = proc(id: FactId): bool =
    for i, fact in fakeRows:
      if fact.id == id:
        fakeRows.delete(i)
        return true
    false

  result.settle = proc(timeoutMs: int): bool =
    discard timeoutMs
    true

proc zepFakeStore*(): FactStore =
  ## A temporal graph, minus the graph part: same contract, rows in memory.
  ## Separate rows from the mem0 fake so one backend's seed can never satisfy
  ## another backend's search and hide a bug — `freshStore` already isolates
  ## by home dir for sqlite, and this isolates the hosted fakes from each other.
  var zepRows: seq[StoreFact] = @[]
  zepRows.add(StoreFact(id: "zep-1", subject: "seed", content: "seeded row",
                         source: "zep", createdAt: "2026-01-01T00:00:00Z"))
  var next = 2

  result.add = proc(subject, content, source: string) =
    zepRows.add(StoreFact(id: "zep-" & $next,
                           subject: subject.toLowerAscii().strip(),
                           content: content, source: source,
                           createdAt: "2026-01-01T00:00:00Z"))
    inc next

  result.search = proc(query: string, topK: int): seq[string] =
    var found: seq[string] = @[]
    for fact in zepRows:
      if fact.hits(query):
        found.add("[" & fact.subject & "] " & fact.content)
    found

  result.list = proc(limit: int): seq[StoreFact] =
    zepRows

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    var found: seq[StoreFact] = @[]
    for fact in zepRows:
      if fact.hits(query):
        found.add(fact)
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    for i, fact in zepRows:
      if fact.id == id:
        zepRows[i].content = content
        if subject.len > 0:
          zepRows[i].subject = subject.toLowerAscii().strip()
        return true
    false

  result.delete = proc(id: FactId): bool =
    for i, fact in zepRows:
      if fact.id == id:
        zepRows.delete(i)
        return true
    false

  result.settle = proc(timeoutMs: int): bool =
    discard timeoutMs
    true

proc fakeEmbed*(text: string): seq[float32] =
  ## Deterministic stand-in for OpenAI embeddings: 8 buckets, token-hashed,
  ## so rows sharing a token rank above rows sharing none. Shared with
  ## `test_pgvector.nim` so the client's ranking is pinnable offline — the
  ## suite never spends a cent and never touches a network.
  result = newSeq[float32](8)
  for token in text.toLowerAscii().splitWhitespace():
    if token.len >= 2:
      var h = 0
      for ch in token:
        h = (h * 31 + ord(ch)) and 0x7fffffff
      result[h mod 8] += 1.0

proc cosine*(a, b: seq[float32]): float =
  ## Cosine similarity, 0 when either side is empty. What `<=>` computes
  ## server-side, spelled out so the fake ranks like the database would.
  var dot, na, nb = 0.0
  for i in 0 ..< min(a.len, b.len):
    dot += a[i].float * b[i].float
    na += a[i].float * a[i].float
    nb += b[i].float * b[i].float
  if na == 0.0 or nb == 0.0: 0.0
  else: dot / (sqrt(na) * sqrt(nb))

type
  PgFakeRow = tuple[id: int, chunkId, subject, content: string,
                     vec: seq[float32]]

proc pgFakeStore*(): FactStore =
  ## `rag_chunks` minus Postgres: rows in memory, `fakeEmbed` vectors,
  ## cosine ranking. Ids are decimal strings — the port exposes BIGSERIAL
  ## `id`, and `_column_for` parity decides the column by shape.
  ##
  ## Candidacy is exact token overlap (like the mem0/zep fakes) and cosine
  ## only ORDERS: a hash bucket collides, so pure-cosine candidacy would call
  ## a nonsense query a hit. The real backend ranks by `<=>` over true
  ## embeddings; the SQL pins in `test_pgvector.nim` prove that path, and
  ## this fake proves the contract.
  var rows: seq[PgFakeRow] = @[]
  rows.add((1, "fact-seed", "seed", "seeded row", fakeEmbed("seed: seeded row")))
  var next = 2

  proc columnOf(id: string): string =
    if id.len > 0 and id.allCharsInSet({'0'..'9'}): "id" else: "chunk_id"

  proc rank(query: string, topK: int): seq[PgFakeRow] =
    let q = fakeEmbed(query)
    var scored: seq[(float, PgFakeRow)] = @[]
    for row in rows:
      # Candidacy first: the row must share a real token with the query.
      # Cosine over hash buckets orders; it does not decide — a bucket
      # collision is not a memory.
      let haystack = row.subject.toLowerAscii() & " " & row.content.toLowerAscii()
      var shares = false
      for token in query.toLowerAscii().splitWhitespace():
        if token.len >= 2 and haystack.contains(token):
          shares = true
      if not shares:
        continue
      scored.add((cosine(q, row.vec), row))
    scored.sort(proc(a, b: (float, PgFakeRow)): int = cmp(b[0], a[0]))
    result = @[]
    for i in 0 ..< min(topK, scored.len):
      result.add(scored[i][1])

  result.add = proc(subject, content, source: string) =
    discard source
    let clean = subject.toLowerAscii().strip()
    rows.add((next, "fact-" & $next, clean, content,
              fakeEmbed(clean & ": " & content)))
    inc next

  result.search = proc(query: string, topK: int): seq[string] =
    var found: seq[string] = @[]
    for row in rank(query, topK):
      found.add("[" & row.subject & "] " & row.content)
    found

  result.list = proc(limit: int): seq[StoreFact] =
    var found: seq[StoreFact] = @[]
    var i = rows.len - 1
    while i >= 0 and found.len < limit:
      found.add(StoreFact(id: $rows[i].id, subject: rows[i].subject,
                          content: rows[i].content, source: "",
                          createdAt: "2026-01-01T00:00:00Z"))
      dec i
    found

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    var found: seq[StoreFact] = @[]
    for row in rank(query, topK):
      found.add(StoreFact(id: $row.id, subject: row.subject,
                          content: row.content, source: "", createdAt: ""))
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    let col = columnOf(id)
    for i, row in rows:
      let match = if col == "id": $row.id == id else: row.chunkId == id
      if match:
        rows[i].content = content
        if subject.len > 0:
          rows[i].subject = subject.toLowerAscii().strip()
        rows[i].vec = fakeEmbed(rows[i].subject & ": " & content)
        return true
    false

  result.delete = proc(id: FactId): bool =
    let col = columnOf(id)
    for i, row in rows:
      let match = if col == "id": $row.id == id else: row.chunkId == id
      if match:
        rows.delete(i)
        return true
    false

  result.settle = proc(timeoutMs: int): bool =
    discard timeoutMs
    true