## LangMem, the library-not-a-service semantic store — the port of
## `waku/memory/semantic/langmem_store.py`: LangGraph's store semantics over
## rows this process owns (this unit) or your Postgres (T2), never an account
## somewhere else. Zero new dependencies; embeddings go over the port's one
## HTTP helper like every other REST call.
##
## The odd one out, as Python's docstring says: choosing LangMem is choosing a
## STORE — in-process here, Postgres there — and letting reads and writes go
## through it. There is no console and no key of its own; what it bills you
## for is embeddings, one per `add` and one per `search`.
##
## ## The default is ephemeral, and that is disclosed loudly
##
## Without a database this client's rows die with the process — the agent's
## long-lived client is fine for a run, and the dashboard's per-request client
## sees an empty store, exactly like Python's per-collect construction. `list`
## after a restart returning nothing is the store working as documented, not a
## bug in Waku. For persistence bring Postgres (T2) or use the `postgres`
## backend, which is the same vectors with a different table.
##
## ## Behaviors mirrored from the reference implementation
##
## Namespaces join with `\x1f` (unit separator) into the row prefix, so
## `("waku", "facts")` reads `"waku\x1ffacts"`. `put` on an existing key
## overwrites, keeps `created_at`, refreshes `updated_at` and RE-EMBEDS — a
## store that kept the old vector would answer the old question and not the
## new one. What gets embedded is the whole value as canonical JSON (the
## default `fields=["$"]`), keys sorted. Search ranks by cosine with NO
## threshold: a nonsense query returns the closest rows, not `[]` — same as
## upstream, where `[]` means an empty store or dead embeddings, never "no
## match". (`created_at`/`updated_at` are fixed-width UTC, so they sort as
## text; the port's own canonical form, opaque to callers.)
##
## ## Where the port diverges, stated plainly
##
## `list` answers newest-first (`created_at DESC`): the upstream scan orders
## by `(prefix, key)`, but THIS repo's contract promises recent facts first and
## the contract wins over upstream. The conformance fake additionally requires
## exact token overlap for candidacy (like the pg fake) — strictly narrower
## than prod by construction, so the suite stays deterministic.
##
## ## Failures never raise
##
## The contract's first rule: a memory backend that throws takes the whole turn
## down with it. Every call here answers, `ok == false` at worst, and the
## adapter turns that into `[]` or `false` — never an exception.

import std/algorithm
import std/httpclient
import std/json
import std/math
import std/random
import std/strutils
import std/times

import ./factstore
import ./http
import ./wire

const
  langmemPrefix* = "waku\x1ffacts"
    ## `ns_to_str(("waku", "facts"))`: namespaces join with the unit
    ## separator, which never appears inside a namespace part.
  reasonLimit* = 160
    ## One line, not a stack trace: these land in stderr inside a turn.
  embedDim* = 1536
    ## `text-embedding-3-small`, the model Python configures and the width
    ## the T2 `VECTOR(1536)` column expects. A different model needs a
    ## different column — vectors do not truncate.

type
  EmbedBatch* = object
    ## One embeddings call over many texts, already judged. `vecs[i]` is the
    ## vector for `texts[i]`; a short answer is a failed answer.
    ok*: bool
    vecs*: seq[seq[float32]]
    detail*: string

  MemRow* = object
    ## One namespaced item: the row both modes share, in memory here and in
    ## `langmem_store` there. `vec` is empty until (re-)embedded.
    key*: string
    subject*: string
    content*: string
    source*: string
    createdAt*: string
    updatedAt*: string
    vec*: seq[float32]

  LangMemClient* = ref object
    ## One `("waku", "facts")` namespace. `rows` is the whole database in
    ## memory mode; the `embedTexts` seam exists so tests pin ranking without
    ## spending a cent. (T2 adds the Postgres twin behind the same ops.)
    prefix*: string
    topK*: int
    embedModel*: string
    openaiKey*: string
    openaiBase*: string
    rows*: seq[MemRow]
    embedTexts*: proc(texts: seq[string]): EmbedBatch

proc bounded(text: string): string =
  if text.len <= reasonLimit: text
  else: text[0 ..< reasonLimit] & "..."

proc nowIso*(): string =
  ## Fixed-width UTC: sorts as text, chronologically. The port's own
  ## canonical form (Python writes `+00:00`; callers must treat both as
  ## opaque).
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc freshFactKey*(): string =
  ## `fact-` + 12 hex, the shape `uuid4().hex[:12]` makes. Random per call:
  ## the key must never collide with a previous fact.
  const hex = "0123456789abcdef"
  result = "fact-"
  for _ in 0 ..< 12:
    result.add(hex[rand(15)])

proc valueJson*(subject, content, source: string): string =
  ## The whole value as canonical JSON with sorted keys — what gets embedded
  ## (upstream default `fields=["$"]`), not the `subject: content` packing
  ## the other backends use. `%*` renders insertion order, so alphabetical
  ## insertion IS canonical output.
  $(%*{"content": content, "source": source, "subject": subject})

proc parseEmbedModel*(configured: string): string =
  ## `"openai:text-embedding-3-small"` → `"text-embedding-3-small"`: the
  ## provider prefix is LangChain's addressing, not the API's model name. A
  ## bare name passes through untouched.
  let parts = configured.split(':', maxsplit = 1)
  if parts.len == 2 and parts[0].len > 0 and parts[1].len > 0: parts[1]
  else: configured

proc cosineScore*(a, b: seq[float32]): float =
  ## Cosine similarity in [-1, 1]; 0 when either side is empty. What the T2
  ## `<=>` computes server-side, spelled out so memory mode ranks like the
  ## database will.
  var dot, na, nb = 0.0
  for i in 0 ..< min(a.len, b.len):
    dot += a[i].float * b[i].float
    na += a[i].float * a[i].float
    nb += b[i].float * b[i].float
  if na == 0.0 or nb == 0.0: 0.0
  else: dot / (sqrt(na) * sqrt(nb))

proc liveEmbedTexts(c: LangMemClient, texts: seq[string]): EmbedBatch =
  ## `POST {base}/v1/embeddings` by hand, batched: one call per `add`, one
  ## per `search`. No openai dependency, the same helper the other backends
  ## use. A short or shapeless answer is a failed answer, not a partial one.
  var client = newTlsHttpClient(timeout = 30 * 1000)
  try:
    var inputs = newJArray()
    for t in texts:
      inputs.add(%t)
    let response = client.request(c.openaiBase & "/v1/embeddings", HttpPost,
      $(%*{"model": c.embedModel, "input": inputs}),
      newHttpHeaders([("Content-Type", "application/json"),
                      ("Authorization", "Bearer " & c.openaiKey)]))
    if not response.status.startsWith("2"):
      return EmbedBatch(ok: false,
        detail: "HTTP " & response.status & ": " & bounded(response.body.strip()))
    let parsed = parseJson(response.body)
    let data = parsed.jget("data")
    if data.kind != JArray or data.len != texts.len:
      return EmbedBatch(ok: false, detail: "embeddings: shapeless answer")
    var vecs: seq[seq[float32]] = @[]
    for item in data:
      let vec = item.jget("embedding")
      if vec.kind != JArray or vec.len == 0:
        return EmbedBatch(ok: false, detail: "embeddings: no vector in answer")
      var vals: seq[float32] = @[]
      for n in vec:
        vals.add(n.getFloat().float32)
      vecs.add(vals)
    EmbedBatch(ok: true, vecs: vecs)
  except CatchableError as exc:
    EmbedBatch(ok: false, detail: bounded(exc.msg))
  finally:
    client.close()

proc newLangMemClient*(openaiKey: string, topK = 4,
                       embedModel = "openai:text-embedding-3-small",
                       openaiBase = "https://api.openai.com",
                       embedTexts: proc(texts: seq[string]): EmbedBatch = nil
                       ): LangMemClient =
  ## `openaiKey` is `OPENAI_API_KEY`, already checked by the caller — an empty
  ## key means the selector never builds this client. The model keeps its
  ## `openai:` prefix until the wire, where it is stripped.
  randomize()
  let client = LangMemClient(prefix: langmemPrefix, topK: topK,
    embedModel: parseEmbedModel(embedModel), openaiKey: openaiKey,
    openaiBase: openaiBase)
  if embedTexts != nil:
    client.embedTexts = embedTexts
  else:
    client.embedTexts = proc(texts: seq[string]): EmbedBatch =
      liveEmbedTexts(client, texts)
  client

proc tryEmbed(c: LangMemClient, texts: seq[string]): EmbedBatch =
  ## The seam, with the contract's first rule applied ONCE: a raising embedder
  ## is a dead embeddings call, which reads as `false` rather than as a crash.
  ## A short answer is also failure — a partial vector list would misalign
  ## every row it touches.
  try:
    let answer = c.embedTexts(texts)
    if answer.ok and answer.vecs.len == texts.len: answer
    else: EmbedBatch(ok: false, detail: "embeddings: shapeless answer")
  except CatchableError as exc:
    EmbedBatch(ok: false, detail: bounded(exc.msg))

proc findRow(c: LangMemClient, key: string): int =
  ## Index of the row, or -1. Linear: namespaces here are hundreds of facts,
  ## not millions, and the reference implementation scans too.
  for i, row in c.rows:
    if row.key == key:
      return i
  -1

proc putRow(c: LangMemClient, key, subject, content, source: string): bool =
  ## Overwrite-or-insert with re-embedding. `false` leaves the table
  ## untouched: a failed embedding must never store a vectorless row that
  ## every later search silently skips.
  let embedded = c.tryEmbed(@[valueJson(subject, content, source)])
  if not embedded.ok:
    return false
  let stamp = nowIso()
  let at = c.findRow(key)
  if at >= 0:
    c.rows[at].subject = subject
    c.rows[at].content = content
    c.rows[at].source = source
    c.rows[at].updatedAt = stamp
    c.rows[at].vec = embedded.vecs[0]
  else:
    c.rows.add(MemRow(key: key, subject: subject, content: content,
                      source: source, createdAt: stamp, updatedAt: stamp,
                      vec: embedded.vecs[0]))
  true

proc add*(c: LangMemClient, subject, content, source: string): bool =
  ## One namespaced item. The subject is lowered and stripped; the source
  ## travels inside the value (unlike `rag_chunks`, this table HAS a source
  ## column-equivalent — parity with Python, which keeps them apart too).
  c.putRow(freshFactKey(), subject.toLowerAscii().strip(), content, source)

proc get*(c: LangMemClient, key: string): tuple[found: bool, row: MemRow] =
  let at = c.findRow(key)
  if at < 0: (false, MemRow())
  else: (true, c.rows[at])

proc update*(c: LangMemClient, key, content, subject: string): bool =
  ## Get, merge, re-put: an empty subject keeps the stored one (the
  ## contract's rule, matching Python's `subject is None`). Missing is
  ## `false`, never an exception.
  let (found, row) = c.get(key)
  if not found:
    return false
  let useSubject = if subject.len > 0: subject.toLowerAscii().strip()
                   else: row.subject
  c.putRow(key, useSubject, content, row.source)

proc delete*(c: LangMemClient, key: string): bool =
  ## Check-then-remove: deleting blind would report success on a key that was
  ## never there, and the conformance suite exists for exactly that lie.
  let at = c.findRow(key)
  if at < 0:
    return false
  c.rows.delete(at)
  true

proc listRows*(c: LangMemClient, limit = 200): seq[MemRow] =
  ## Newest-first by `created_at` (the contract's rule — see the module
  ## header for why this differs from upstream's key order).
  var ordered = c.rows
  ordered.sort(proc(a, b: MemRow): int = cmp(b.createdAt, a.createdAt))
  if ordered.len > limit: ordered[0 ..< limit] else: ordered

proc searchRows*(c: LangMemClient, query: string, topK = -1): seq[MemRow] =
  ## Embed the query, rank every embedded row by cosine, best first, no
  ## threshold — upstream parity (see the module header). A dead embeddings
  ## call is `[]`, and rows stored before a failed add carry no vector and
  ## never match (there are none: `putRow` refuses to store them).
  let embedded = c.tryEmbed(@[query])
  if not embedded.ok:
    return @[]
  let limit = if topK > 0: topK else: c.topK
  var scored: seq[(float, MemRow)] = @[]
  for row in c.rows:
    if row.vec.len == 0:
      continue
    scored.add((cosineScore(embedded.vecs[0], row.vec), row))
  scored.sort(proc(a, b: (float, MemRow)): int = cmp(b[0], a[0]))
  result = @[]
  for i in 0 ..< min(limit, scored.len):
    result.add(scored[i][1])

proc settle*(c: LangMemClient, timeoutMs: int): bool =
  ## Already settled: the store is this process — a dict, no queue, no
  ## server. Accepted and ignored like the sqlite adapter's.
  discard c
  discard timeoutMs
  true

proc rowToFact(row: MemRow): StoreFact =
  StoreFact(id: row.key, subject: row.subject, content: row.content,
            source: row.source, createdAt: row.createdAt)

proc langmemFactStore*(c: LangMemClient): FactStore =
  ## The contract, over this client. Every method answers instead of raising;
  ## `update` with an empty subject keeps the stored one via the client's
  ## merge (no read-back needed: subject and content are separate fields
  ## here, unlike the single-blob backends).
  result.add = proc(subject, content, source: string) =
    discard c.add(subject, content, source)

  result.search = proc(query: string, topK: int): seq[string] =
    var hits: seq[string] = @[]
    for row in c.searchRows(query, topK):
      hits.add(if row.subject.len > 0: "[" & row.subject & "] " & row.content
               else: row.content)
    hits

  result.list = proc(limit: int): seq[StoreFact] =
    var found: seq[StoreFact] = @[]
    for row in c.listRows(limit):
      found.add(rowToFact(row))
    found

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    var found: seq[StoreFact] = @[]
    for row in c.searchRows(query, topK):
      found.add(rowToFact(row))
      if found.len >= topK:
        break
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    c.update(id, content, subject)

  result.delete = proc(id: FactId): bool =
    c.delete(id)

  result.settle = proc(timeoutMs: int): bool =
    c.settle(timeoutMs)
