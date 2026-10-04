## The `FactStore` contract — the port of `waku/memory/semantic/base.py`.
##
## Python writes that file as a `Protocol`, which is the whole point of it: Waku
## is meant to be indifferent to *where* facts live (SQLite on your laptop, a
## hosted memory API), so every backend must be able to do the same seven
## things and something has to CHECK it. Nothing checked it for a long time, and
## the bill arrived as failures in front of users: a store shipping without
## `list()` 500'd the dashboard, one without `search_with_ids()` was guarded by
## `hasattr(..., else [])`, and the agent then answered "no matching facts"
## while the facts sat in the database — no error, no trace, no way to notice.
##
## A guard around a missing method does not prevent a bug; it converts a loud
## one into a silent lie. So the contract is a type you cannot half-implement
## and a conformance suite that every backend has to pass
## (`tests/test_factstore.nim`, the port of
## `evals/deterministic/test_fact_store_conformance.py`).
##
## ## Why a record of closures
##
## Nim has no structural Protocol, and a record of function fields is the
## honest translation: the fields are all required, so a backend that forgets
## one fails to compile instead of failing in front of a user. That is the
## defect the Protocol docstring describes, turned into a compile error.
##
## ## The rules that are not negotiable
##
## - A miss returns `[]` or `false`. It never raises. A memory backend that
##   throws takes the whole turn down with it.
## - `settle()` returning true must mean SEARCHABLE, not merely written. For a
##   remote store those are very different moments.
## - Ids are `string` and belong to whichever backend issued them: sqlite
##   counts, a hosted API hands out UUIDs. Never parse a foreign id — pass it
##   back verbatim. (`FactId` is `int | str` in Python for the same reason;
##   this port renders the sqlite int64 as its decimal text at the boundary.)
##
## ## What a closure field costs versus a Python def
##
## No default arguments: Python's `search(query, top_k=4)` and
## `add(..., source="user")` become explicit at every call site. The defaults
## live in the callers that already own them (`settings.retrievalTopK`), so
## nothing is lost — but the signature is wider, and that is the honest Nim
## spelling of the same contract.
##
## ## The one asymmetry with `memory.nim`
##
## `update` takes an EMPTY `subject` to mean "leave the subject alone", where
## `memory.nim` splits that into `updateFactContent` / `updateFact` to avoid a
## sentinel. Both are right for their layer: the sqlite layer wants no
## sentinel in its SQL, while a remote store rewrites one blob and must read
## the subject back itself (what Python's `update` does when `subject is
## None`). The adapter is where that difference gets absorbed, so callers get
## one method and each backend gets the behaviour it needs.
##
## `StoreFact` and `memory.Fact` are two shapes on purpose, and only until the
## call sites move to the store (unit T3): this unit is additive and changes
## no existing signature, so the sqlite adapter converts between them at the
## boundary instead of rewriting every caller first.

import std/strutils

import ./memory

import db_connector/db_sqlite

type
  FactId* = string
    ## A row id as its backend issued it: sqlite's decimal counter, or a
    ## hosted API's UUID. Opaque on purpose — nothing may parse it.

  StoreFact* = object
    ## One fact as the contract hands it out: what `list` and
    ## `search_with_ids` return. `id`/`subject`/`content` are the three the
    ## contract requires; `source` and `createdAt` are what Python's rows
    ## carry and what the dashboard shows.
    id*: FactId
    subject*: string
    content*: string
    source*: string
    createdAt*: string

  FactStore* = object
    ## The contract, as required function fields. Split by who calls them:
    ## `add`/`search` are the agent every turn; `list`/`update`/`delete` are
    ## humans in the dashboard and the `manage_memory` tool.
    add*: proc(subject, content, source: string)
      ## Store one fact. `subject` is who/what it is about (stored
      ## lowercased by convention); `source` records who claimed it.
      ## The promise is "this is stored": a backend that decides otherwise
      ## has broken the contract, which is why mem0 is told not to infer.
    search*: proc(query: string, topK: int): seq[string]
      ## Facts relevant to `query`, best first, formatted for the prompt as
      ## `[subject] content`. `[]` means "nothing matched", never "I could
      ## not run the search".
    list*: proc(limit: int): seq[StoreFact]
      ## Recent facts, newest first, for the dashboard.
    searchWithIds*: proc(query: string, topK: int): seq[StoreFact]
      ## `search`, but each row carries the `id` that `update`/`delete`
      ## accept. This is the lookup step of every correction, which is why
      ## answering `[]` on failure instead of raising is so damaging.
    update*: proc(id: FactId, content, subject: string): bool
      ## Replace a fact's text; an EMPTY `subject` leaves the subject alone.
      ## `false` when `id` is unknown, never an exception — a stale id from
      ## the dashboard must not become a 500.
    delete*: proc(id: FactId): bool
      ## Forget a fact. `false` when `id` is unknown, never an exception.
    settle*: proc(timeoutMs: int): bool
      ## Block until what was written is actually SEARCHABLE, or give up and
      ## answer `false`. A local store answers `true` immediately. Never
      ## raises: a backend that cannot confirm readiness should be slower,
      ## not fatal.

proc factIdToInt(id: FactId): int64 =
  ## sqlite's own id, parsed. ONLY for the sqlite adapter: a foreign id must
  ## never come through here, and a non-numeric one is a miss (`false`),
  ## which is the honest answer for "no such row in this database".
  try:
    result = parseBiggestInt(id)
  except ValueError:
    result = 0

proc sqliteFactStore*(db: DbConn): FactStore =
  ## The local backend, as the contract: a thin layer over the procs
  ## `memory.nim` already exposes. It adds the two things the contract
  ## demands and sqlite's shape does not: ids as opaque strings, and
  ## `update`'s empty subject meaning "leave it alone".
  result.add = proc(subject, content, source: string) =
    db.addFact(subject, content, source)

  result.search = proc(query: string, topK: int): seq[string] =
    db.searchFacts(query, topK)

  result.list = proc(limit: int): seq[StoreFact] =
    # `result` inside a closure is the CLOSURE's result, so the rows need a
    # local name; naming it `rows` also says what it is.
    var rows: seq[StoreFact] = @[]
    for row in db.listFacts(limit):
      rows.add(StoreFact(id: $row.id, subject: row.subject,
                          content: row.content, source: row.source,
                          createdAt: row.createdAt))
    rows

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    var rows: seq[StoreFact] = @[]
    for row in db.searchFactsWithIds(query, topK):
      rows.add(StoreFact(id: $row.id, subject: row.subject,
                          content: row.content, source: "", createdAt: ""))
    rows

  result.update = proc(id: FactId, content, subject: string): bool =
    if subject.len == 0:
      return db.updateFactContent(factIdToInt(id), content)
    db.updateFact(factIdToInt(id), content, subject)

  result.delete = proc(id: FactId): bool =
    db.deleteFact(factIdToInt(id))

  result.settle = proc(timeoutMs: int): bool =
    ## The local store has nothing to wait for: the row and its FTS5 index
    ## land in one step. The parameter is accepted and ignored on purpose —
    ## the contract is one shape for every backend.
    discard timeoutMs
    settle()