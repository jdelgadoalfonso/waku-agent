## Postgres + pgvector, the user-hosted semantic store — the port of
## `waku/memory/semantic/supabase_store.py` with the transport broadened:
## plain SQL over a direct connection instead of `supabase-py` (PostgREST +
## RPC), so ANY Postgres with the `vector` extension works, not just Supabase.
## Zero new dependencies: `db_connector/db_postgres` already ships, and the
## embeddings go over the port's one HTTP helper like every other REST call.
##
## The schema is launch-rag's `rag_chunks` (`sql/init_postgres.sql`): the port
## emits the cosine directly (`ORDER BY embedding <=> $1::vector LIMIT $2`)
## and never needs the `match_chunks` RPC the videos teach — one less function
## to install, and `search_with_ids` answers in ONE trip instead of Python's
## rank-then-resolve two.
##
## ## What costs money here
##
## Every `add` AND every `search` pays one OpenAI embeddings call (network +
## latency + dollars). The sqlite store answers from disk; mem0 and Zep answer
## from a service that already extracted; this backend embeds on the way in
## AND on the way out. That is the trade, stated where the user opts in.
##
## ## Failures never raise
##
## The contract's first rule: a memory backend that throws takes the whole turn
## down with it. Every call here answers, `ok == false` at worst, and the
## adapter turns that into `[]` or `false` — never an exception. A refused
## socket, a missing table, a dead embedding call: all `false`, never a stack.

import std/httpclient
import std/json
import std/random
import std/sequtils
import std/strutils
import std/uri

import db_connector/db_postgres

import ./factstore
import ./http
import ./wire

type
  PgAnswer* = object
    ## One database round trip, already judged. `rows` are raw strings exactly
    ## as libpq hands them back; `affected` is the UPDATE/DELETE row count.
    ok*: bool
    rows*: seq[Row]
    affected*: int64
    detail*: string

  EmbedAnswer* = object
    ## One embeddings call, already judged.
    ok*: bool
    vec*: seq[float32]
    detail*: string

  PgClient* = ref object
    ## One Postgres database + one embeddings key. The two seams (query,
    ## embed) exist so the tests can pin SQL and ranking without a server and
    ## without spending a cent; each has a real default, so `newPgClient` with
    ## a URL and a key alone is the normal construction.
    ##
    ## Connections are per operation (open, run, close), like the dashboard's
    ## per-request stores: nothing holds a socket between turns, and a server
    ## that went away reads as `false` on the next call rather than as a
    ## stale-handle crash.
    conninfo*: string
    openaiKey*: string
    embedModel*: string
    openaiBase*: string
    topK*: int
    query*: proc(sql: string, args: seq[string], expectRows: bool): PgAnswer
    embed*: proc(text: string): EmbedAnswer

const
  reasonLimit* = 160
    ## One line, not a stack trace: these land in stderr inside a turn.
  embedDim* = 1536
    ## `text-embedding-3-small`, the model Python uses and the width the
    ## `VECTOR(1536)` column expects. A different model needs a different
    ## column — vectors do not truncate.

  addSql* = "INSERT INTO rag_chunks (chunk_id, source, text, embedding) " &
    "VALUES ($1,$2,$3,$4::vector) ON CONFLICT (chunk_id) DO UPDATE SET " &
    "source=EXCLUDED.source, text=EXCLUDED.text, embedding=EXCLUDED.embedding"
  searchSql* = "SELECT id, chunk_id, source, text FROM rag_chunks " &
    "ORDER BY embedding <=> $1::vector LIMIT $2"
  listSql* = "SELECT id, source, text, created_at FROM rag_chunks " &
    "ORDER BY id DESC LIMIT $1"

proc bounded(text: string): string =
  if text.len <= reasonLimit: text
  else: text[0 ..< reasonLimit] & "..."

proc columnFor*(id: FactId): string =
  ## Which column names this fact: the launch-rag table has BOTH `id BIGSERIAL`
  ## and `chunk_id TEXT`, and the port exposes the integer — the same rule as
  ## Python's `_column_for`, by shape rather than by parsing.
  if id.len > 0 and id.allCharsInSet({'0'..'9'}): "id" else: "chunk_id"

proc getSql*(col: string): string =
  "SELECT source, text FROM rag_chunks WHERE " & col & " = $1 LIMIT 1"

proc updateSql*(col: string): string =
  "UPDATE rag_chunks SET source=$1, text=$2, embedding=$3::vector WHERE " &
    col & " = $4"

proc deleteSql*(col: string): string =
  "DELETE FROM rag_chunks WHERE " & col & " = $1"

proc queryParamsOf(query: string): seq[(string, string)] =
  ## `std/uri` exposes the raw query string; split it into pairs here so
  ## `conninfoOf` stays pure and testable without a connection.
  result = @[]
  for pair in query.split('&'):
    if pair.len == 0:
      continue
    let kv = pair.split('=', maxsplit = 1)
    if kv.len == 2:
      result.add((decodeUrl(kv[0]), decodeUrl(kv[1])))
    else:
      result.add((decodeUrl(kv[0]), ""))

proc conninfoOf*(databaseUrl: string): string =
  ## `DATABASE_URL` into libpq keywords. A `postgres://` URL becomes
  ## `host= port= dbname= user= password=` plus whatever query params it
  ## carried (`sslmode`, `connect_timeout`, …); anything else passes through
  ## untouched, so a keyword conninfo keeps working verbatim.
  if not databaseUrl.startsWith("postgres://") and
     not databaseUrl.startsWith("postgresql://"):
    return databaseUrl
  let parsed = parseUri(databaseUrl)
  var parts: seq[string] = @[]
  if parsed.hostname.len > 0:
    parts.add("host=" & parsed.hostname)
  if parsed.port.len > 0:
    parts.add("port=" & parsed.port)
  let path = parsed.path.strip(chars = {'/'})
  if path.len > 0:
    parts.add("dbname=" & path)
  if parsed.username.len > 0:
    parts.add("user=" & decodeUrl(parsed.username))
  if parsed.password.len > 0:
    parts.add("password=" & decodeUrl(parsed.password))
  for pair in queryParamsOf(parsed.query):
    parts.add(pair[0] & "=" & pair[1])
  parts.join(" ")

proc vecLit*(vec: seq[float32]): string =
  ## A vector as Postgres reads it: `[0.1,0.2,…]`, always bracketed even when
  ## empty (an empty literal errors loudly rather than matching everything).
  "[" & vec.mapIt($it).join(",") & "]"

proc freshChunkId*(): string =
  ## `fact-` + 12 hex, the same shape Python's `uuid4().hex[:12]` makes.
  ## Random per call: the upsert key must never collide with a previous fact.
  const hex = "0123456789abcdef"
  result = "fact-"
  for _ in 0 ..< 12:
    result.add(hex[rand(15)])

proc liveQuery(conninfo, sql: string, args: seq[string],
               expectRows: bool): PgAnswer =
  ## The one real round trip: open, run, close. Anything — refused socket,
  ## missing table, missing extension — is `ok: false` with a short reason.
  var db: DbConn = nil
  try:
    db = db_postgres.open("", "", "", conninfo)
  except CatchableError as exc:
    return PgAnswer(ok: false, detail: bounded(exc.msg))
  try:
    if expectRows:
      PgAnswer(ok: true, rows: db.getAllRows(sql(sql), args))
    else:
      PgAnswer(ok: true, affected: db.execAffectedRows(sql(sql), args))
  except CatchableError as exc:
    PgAnswer(ok: false, detail: bounded(exc.msg))
  finally:
    # Bare, like the mem0/zep clients: the repo gate (`test_tls`) forbids
    # catching inside a finally, and `PQfinish` does not raise — guarding nil
    # is the whole safety story here.
    if db != nil:
      db.close()

proc liveEmbed(c: PgClient, text: string): EmbedAnswer =
  ## `POST {base}/v1/embeddings` by hand: no openai dependency, the same
  ## helper the mem0/zep clients use. The shape tolerance is deliberate — the
  ## API has one shape today and the failure mode of pinning to it exactly is
  ## a benchmark that breaks on a version bump.
  var client = newTlsHttpClient(timeout = 30 * 1000)
  try:
    let response = client.request(c.openaiBase & "/v1/embeddings", HttpPost,
      $(%*{"model": c.embedModel, "input": text}),
      newHttpHeaders([("Content-Type", "application/json"),
                      ("Authorization", "Bearer " & c.openaiKey)]))
    if not response.status.startsWith("2"):
      return EmbedAnswer(ok: false,
        detail: "HTTP " & response.status & ": " & bounded(response.body.strip()))
    let parsed = parseJson(response.body)
    let embedding = parsed.jget("data")
    if embedding.kind == JArray and embedding.len > 0:
      let vec = embedding[0].jget("embedding")
      if vec.kind == JArray and vec.len > 0:
        var vals: seq[float32] = @[]
        for n in vec:
          vals.add(n.getFloat().float32)
        return EmbedAnswer(ok: true, vec: vals)
    EmbedAnswer(ok: false, detail: "embeddings: no vector in answer")
  except CatchableError as exc:
    EmbedAnswer(ok: false, detail: bounded(exc.msg))
  finally:
    client.close()

proc newPgClient*(databaseUrl, openaiKey: string, topK = 4,
                  embedModel = "text-embedding-3-small",
                  openaiBase = "https://api.openai.com",
                  query: proc(sql: string, args: seq[string],
                              expectRows: bool): PgAnswer = nil,
                  embed: proc(text: string): EmbedAnswer = nil): PgClient =
  ## `databaseUrl` is `DATABASE_URL` verbatim (URL or keywords);
  ## `openaiKey` is `OPENAI_API_KEY`. Both arrive already checked by the
  ## caller — an empty either means the selector never builds this client.
  randomize()
  let client = PgClient(conninfo: conninfoOf(databaseUrl), openaiKey: openaiKey,
                        embedModel: embedModel, openaiBase: openaiBase, topK: topK)
  if query != nil:
    client.query = query
  else:
    client.query = proc(sql: string, args: seq[string],
                        expectRows: bool): PgAnswer =
      liveQuery(client.conninfo, sql, args, expectRows)
  if embed != nil:
    client.embed = embed
  else:
    client.embed = proc(text: string): EmbedAnswer = liveEmbed(client, text)
  client

proc tryQuery(c: PgClient, sql: string, args: seq[string],
              expectRows: bool): PgAnswer =
  ## The seam, with the contract's first rule applied ONCE: a raising seam is
  ## a dead server, which reads as `false` rather than as a crash.
  try:
    result = c.query(sql, args, expectRows)
  except CatchableError as exc:
    result = PgAnswer(ok: false, detail: bounded(exc.msg))

proc tryEmbed(c: PgClient, text: string): EmbedAnswer =
  try:
    result = c.embed(text)
  except CatchableError as exc:
    result = EmbedAnswer(ok: false, detail: bounded(exc.msg))

# --- the operations ---------------------------------------------------------

proc add*(c: PgClient, subject, content, source: string): PgAnswer =
  ## Embed, then upsert. The embedding is computed BEFORE the insert, so the
  ## row is searchable as soon as Postgres commits it — which is why `settle`
  ## below answers immediately. `source` is accepted for contract symmetry and
  ## not stored: `rag_chunks` has one subject column, like Python.
  discard source
  let vec = c.tryEmbed(subject.toLowerAscii().strip() & ": " & content)
  if not vec.ok:
    return PgAnswer(ok: false, detail: vec.detail)
  c.tryQuery(addSql, @[freshChunkId(), subject.toLowerAscii().strip(),
                       content, vecLit(vec.vec)], false)

proc search*(c: PgClient, query: string, topK = -1): PgAnswer =
  ## Rank by cosine, best first. An embedding failure is `[]`, not an error —
  ## the adapter decides that, and this answer carries it.
  let vec = c.tryEmbed(query)
  if not vec.ok:
    return PgAnswer(ok: false, detail: vec.detail)
  c.tryQuery(searchSql, @[vecLit(vec.vec),
                          $(if topK > 0: topK else: c.topK)], true)

proc listRows*(c: PgClient, limit = 200): PgAnswer =
  c.tryQuery(listSql, @[$limit], true)

proc getRow*(c: PgClient, id: string): PgAnswer =
  let col = columnFor(id)
  c.tryQuery(getSql(col), @[id], true)

proc exists*(c: PgClient, id: string): bool =
  ## One select on the column the id's shape names. Unknown ids find no row.
  let answer = c.getRow(id)
  answer.ok and answer.rows.len > 0

proc update*(c: PgClient, id, content, subject: string): PgAnswer =
  ## Re-embeds. A vector store where update rewrote the text but left the old
  ## embedding would keep answering the OLD question and not the new one — the
  ## silent-wrong-answer failure the Python file is a reaction to.
  let col = columnFor(id)
  let current = c.tryQuery(getSql(col), @[id], true)
  if not current.ok or current.rows.len == 0 or current.rows[0].len < 1:
    return PgAnswer(ok: false, detail: "unknown id")
  let newSubject = if subject.len > 0: subject.toLowerAscii().strip()
                   else: current.rows[0][0].toLowerAscii().strip()
  let vec = c.tryEmbed(newSubject & ": " & content)
  if not vec.ok:
    return PgAnswer(ok: false, detail: vec.detail)
  let done = c.tryQuery(updateSql(col),
                        @[newSubject, content, vecLit(vec.vec), id], false)
  if done.ok and done.affected > 0: done
  else: PgAnswer(ok: false, detail: "unknown id")

proc delete*(c: PgClient, id: string): PgAnswer =
  let done = c.tryQuery(deleteSql(columnFor(id)), @[id], false)
  if done.ok and done.affected > 0: done
  else: PgAnswer(ok: false, detail: "unknown id")

proc settle*(c: PgClient, timeoutMs: int): bool =
  ## Already settled: see `add`. The parameter is accepted and ignored like
  ## the sqlite adapter's — the contract is one shape for every backend.
  discard c
  discard timeoutMs
  true

proc pgFactStore*(c: PgClient): FactStore =
  ## The contract, over this client. Every method answers instead of raising.
  result.add = proc(subject, content, source: string) =
    discard c.add(subject, content, source)

  result.search = proc(query: string, topK: int): seq[string] =
    let answer = c.search(query, topK)
    var hits: seq[string] = @[]
    if not answer.ok:
      return hits
    for row in answer.rows:
      if row.len < 4:
        continue
      let subject = row[2]
      hits.add(if subject.len > 0: "[" & subject & "] " & row[3] else: row[3])
    hits

  result.list = proc(limit: int): seq[StoreFact] =
    let answer = c.listRows(limit)
    var found: seq[StoreFact] = @[]
    if not answer.ok:
      return found
    for row in answer.rows:
      if row.len < 3:
        continue
      found.add(StoreFact(id: row[0], subject: row[1], content: row[2],
                          source: "",
                          createdAt: if row.len > 3: row[3] else: ""))
    found

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    # ONE trip: the ranking select already carries `id`, unlike Python's
    # rank-then-resolve two. Same rows the user would correct.
    let answer = c.search(query, topK)
    var found: seq[StoreFact] = @[]
    if not answer.ok:
      return found
    for row in answer.rows:
      if row.len < 4:
        continue
      found.add(StoreFact(id: row[0], subject: row[2], content: row[3],
                          source: "", createdAt: ""))
      if found.len >= topK:
        break
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    c.update(id, content, subject).ok

  result.delete = proc(id: FactId): bool =
    c.delete(id).ok

  result.settle = proc(timeoutMs: int): bool =
    c.settle(timeoutMs)
