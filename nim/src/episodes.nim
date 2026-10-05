## The `EpisodeStore` contract — dated events: what happened, and when.
##
## Semantic memory answers "what do I know?"; episodic answers "what happened
## last Tuesday?". Same shape of deal as `FactStore`: every backend must do
## the same five things and something has to CHECK it, because the dashboard's
## memory page and the consolidation read whatever answers.
##
## ## Why a record of closures, again
##
## Same reason as `factstore.nim`: the fields are all required, so a backend
## that forgets one fails to compile instead of failing in front of a user.
## The sqlite adapter below is a thin layer over the procs `memory.nim`
## already exposes — this unit is additive and changes no existing signature.
##
## ## The rules that are not negotiable
##
## - A miss returns `[]` or `false`. It never raises. An episodic backend
##   that throws takes the retrieval or the consolidation down with it.
## - An empty query is not a search: it falls back to `recent`. Both Python
##   backends agree (sqlite's FTS fallback, Notion's keyword fallback), so
##   the contract states it instead of letting each backend guess.
## - Ids are `string` and belong to whichever backend issued them: sqlite's
##   decimal counter, or a vault-relative path. Never parse a foreign id —
##   pass it back verbatim.
## - `list` and `recent` answer newest first. The sqlite adapter keeps its
##   `ORDER BY id DESC` (insertion order IS time order there); a file backend
##   orders by `happened_at`.

import std/strutils

import ./memory

import db_connector/db_sqlite

type
  EpisodeId* = string
    ## A row id as its backend issued it: sqlite's decimal counter, or a
    ## vault-relative note path. Opaque on purpose — nothing may parse it.

  EpisodeRec* = object
    ## One episode as the contract hands it out: what `list` returns. `id`,
    ## `happenedAt` and `summary` are the three the contract requires;
    ## `createdAt` is what the dashboard shows.
    id*: EpisodeId
    happenedAt*: string
    summary*: string
    createdAt*: string

  EpisodeStore* = object
    ## The contract: `add`/`search`/`recent` are the agent (retrieval and
    ## consolidation); `list`/`delete` are humans in the dashboard.
    add*: proc(summary, happenedAt: string)
      ## Record one dated event.
    recent*: proc(topK: int): seq[string]
      ## The latest events, newest first, as `"(date) summary"`. `[]` means
      ## "nothing stored", never "I could not read".
    search*: proc(query: string, topK: int): seq[string]
      ## Events matching `query`, same `"(date) summary"` shape. An EMPTY
      ## query falls back to `recent` — it is not a search.
    list*: proc(limit: int): seq[EpisodeRec]
      ## Newest first, for the dashboard. Each row carries the `id` that
      ## `delete` accepts.
    delete*: proc(id: EpisodeId): bool
      ## Forget an event. `false` when `id` is unknown, never an exception.

proc episodeIdToInt(id: EpisodeId): int64 =
  ## sqlite's own id, parsed. ONLY for the sqlite adapter: a foreign id must
  ## never come through here, and a non-numeric one is a miss (`false`).
  try:
    result = parseBiggestInt(id)
  except ValueError:
    result = 0

proc sqliteEpisodeStore*(db: DbConn): EpisodeStore =
  ## The local backend, as the contract: a thin layer over the procs
  ## `memory.nim` already exposes. It adds the one thing the contract
  ## demands and sqlite's shape does not: ids as opaque strings.
  result.add = proc(summary, happenedAt: string) =
    db.addEpisode(summary, happenedAt)

  result.recent = proc(topK: int): seq[string] =
    db.recentEpisodes(topK)

  result.search = proc(query: string, topK: int): seq[string] =
    db.searchEpisodes(query, topK)

  result.list = proc(limit: int): seq[EpisodeRec] =
    var recs: seq[EpisodeRec] = @[]
    for row in db.listEpisodes(limit):
      recs.add(EpisodeRec(id: $row.id, happenedAt: row.happenedAt,
                          summary: row.summary, createdAt: row.createdAt))
    recs

  result.delete = proc(id: EpisodeId): bool =
    # `episodeIdToInt` maps a foreign id to 0, and no row is ever 0 — so an
    # opaque id from another backend reads as "unknown", which is honest.
    if id.len == 0 or not id.allCharsInSet({'0'..'9'}):
      return false
    db.deleteEpisode(episodeIdToInt(id))
