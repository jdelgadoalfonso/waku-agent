## Zep, the temporal-graph semantic store — the port of
## `waku/memory/semantic/zep_store.py` against the API generation the pinned
## SDK actually speaks (`zep-cloud 3.29.0`): base
## `https://api.getzep.com/api/v2`, header `Authorization: Api-Key <key>`.
## Zero dependencies, REST by hand over the port's one HTTP helper, exactly
## like mem0, the MCP bridge and the OTLP exporter.
##
## Waku's own store and Mem0 hold facts as rows: a newer fact leaves the older
## one sitting there, equally retrievable. Zep builds a temporal knowledge
## graph — entities and relationships with validity intervals — so a fact can
## be superseded AT A POINT IN TIME rather than merely outranked. That is the
## update test ("the design review moved to Wednesday"), and the reason this
## backend exists.
##
## ## What does not map cleanly, stated plainly
##
## `graph.add` ingests text and derives nodes and edges from it — the fact put
## in is not the row got back. So `add` is a graph ingest, not an insert;
## `search` returns Zep's rendering of an edge or node, not Waku's sentence;
## `update` has no counterpart (a graph does not edit in place: the correction
## is ingested and the older edge is superseded by validity dates). Ids are
## node/edge UUIDs (strings), which `FactId = string` already allows.
##
## Ingestion is ASYNCHRONOUS: `graph.add` returns an episode with
## `processed=false`, and the text only becomes searchable once Zep has
## decomposed it. `add` therefore blocks in `_wait_processed`, and `settle`
## waits for the SECOND event mem0 never had: every episode `processed` AND a
## node count held still — `processed` describes the EPISODE, and the nodes
## derived from it arrive afterwards.
##
## ## Failures never raise
##
## The contract's first rule: a memory backend that throws takes the whole turn
## down with it. Every call here answers, `ok == false` at worst, and the
## adapter turns that into `[]` or `false` — never an exception.

import std/httpclient
import std/json
import std/os
import std/strutils
import std/times
import std/uri

import ./factstore
import ./http
import ./wire

type
  PackedFact* = tuple[subject, content: string]
    ## The two halves of one stored blob. Named because a tuple return type
    ## cannot carry field names inline (`(subject, content: string)` does not
    ## compile), and the tests want to say which half they are checking.

  ZepResult* = object
    ## One HTTP answer, already judged. `detail` is bounded so a caller that
    ## logs it cannot print more than the terminal showed.
    ok*: bool
    status*: int
    body*: string
    detail*: string

  ZepClient* = ref object
    ## One Zep user graph. The three seams (send, clock, sleep) exist so the
    ## tests can drive `settle` without a network and without waiting; each
    ## has a real default, so `newZepClient` with a key alone is the normal
    ## construction.
    apiKey*: string
    userId*: string
    host*: string
    topK*: int
    send*: proc(verb, path, body: string): ZepResult
    nowMs*: proc(): int64
    sleepMs*: proc(ms: int64)

const
  reasonLimit* = 160
    ## One line, not a stack trace: these land in stderr inside a turn.
  pollEveryMs* = 2000
    ## What Python's `_POLL_EVERY` says: ask every 2s, and the deadline is the
    ## real bound. The tests inject a clock so this never sleeps for real.
  stableNeeded* = 3
    ## How many identical node counts `settle` needs before it believes the
    ## graph stopped growing — the number Python's `settle` uses.

proc bounded(text: string): string =
  if text.len <= reasonLimit: text
  else: text[0 ..< reasonLimit] & "..."

proc packFact*(subject, content: string): string =
  ## `"subject: content"`, subject lowercased — Waku keeps the two apart and
  ## Zep stores one ingested blob, so the round trip goes through this shape.
  ## It is the same packing the Python adapter does (`f"{subject}: {content}"`
  ## lowered), for the same reason.
  subject.toLowerAscii().strip() & ": " & content

proc unpackFact*(text: string): PackedFact =
  ## The other half of the round trip. A blob with no `": "` is all content:
  ## splitting it would invent a subject out of nothing.
  let safe = if text.len > 0: text else: ""
  let parts = safe.split(": ", maxsplit = 1)
  if parts.len == 2: (parts[0], parts[1]) else: ("", safe)

proc zepHeaders(c: ZepClient): HttpHeaders =
  newHttpHeaders([("Content-Type", "application/json"),
                  ("Authorization", "Api-Key " & c.apiKey)])

proc requestSafe(verb: HttpMethod, url, body: string,
                 headers: HttpHeaders): ZepResult =
  ## The one live round trip, over `http.nim`'s helper so an `https://` host
  ## gets the TLS context in a `-d:wakuTls` build and is refused honestly in
  ## the default one. A refused or broken socket is `ok: false` with a short
  ## reason: the contract forbids raising from a memory backend.
  var client = newTlsHttpClient(timeout = 30 * 1000)
  try:
    let response = client.request(url, verb, body, headers)
    result.ok = response.status.startsWith("2")
    try:
      result.status = parseInt(response.status.split(' ')[0])
    except ValueError:
      result.status = 0
    result.body = response.body
    if not result.ok:
      result.detail = "HTTP " & $result.status & ": " & bounded(response.body.strip())
  except CatchableError as exc:
    result.ok = false
    result.detail = bounded(exc.msg)
  finally:
    client.close()

proc parseMethod(name: string): HttpMethod =
  ## "GET"/"POST"/"PUT"/"DELETE"/"PATCH" as the wire verb. The seam takes the
  ## verb as a string so a test can assert on it without importing httpclient.
  case name
  of "GET": HttpGet
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  of "PATCH": HttpPatch
  else: HttpPost

proc newZepClient*(apiKey, userId: string, topK = 4,
                   host = "https://api.getzep.com/api/v2",
                   send: proc(verb, path, body: string): ZepResult = nil,
                   nowMs: proc(): int64 = nil,
                   sleepMs: proc(ms: int64) = nil): ZepClient =
  ## `apiKey` is `ZEP_API_KEY`, `userId` is `ZEP_USER_ID` with the "empty means
  ## absent" rule already applied by the caller (Python's `env_or`).
  let client = ZepClient(apiKey: apiKey, userId: userId, host: host, topK: topK)
  if send != nil:
    client.send = send
  else:
    client.send = proc(verb, path, body: string): ZepResult =
      requestSafe(parseMethod(verb), client.host & path, body,
                  zepHeaders(client))
  if nowMs != nil:
    client.nowMs = nowMs
  else:
    client.nowMs = proc(): int64 = int64(epochTime() * 1000)
  if sleepMs != nil:
    client.sleepMs = sleepMs
  else:
    client.sleepMs = proc(ms: int64) = sleep(int(ms))
  client

proc trySend(c: ZepClient, verb, path, body: string): ZepResult =
  ## The send, with the contract's first rule applied ONCE so that no call
  ## site can forget it: a memory backend that throws takes the whole turn
  ## down with it.
  try:
    result = c.send(verb, path, body)
  except CatchableError as exc:
    result = ZepResult(ok: false, status: 0, body: "", detail: bounded(exc.msg))

# --- shapes ---------------------------------------------------------------

proc searchRows(payload: string): seq[JsonNode] =
  ## A search returns `edges` and/or `nodes` depending on scope; both carry a
  ## uuid and some rendered text, under different attribute names.
  var parsed: JsonNode
  try:
    parsed = parseJson(payload)
  except JsonParsingError:
    return @[]
  if parsed.kind != JObject:
    return @[]
  for group in ["edges", "nodes"]:
    let found = parsed.jget(group)
    if found.kind == JArray:
      for item in found:
        result.add(item)

proc nodeRows(payload: string): seq[JsonNode] =
  ## `POST graph/node/user/{id}` answers a bare list; tolerate the wrapped
  ## shapes too, for the same reason mem0 tolerates three.
  var parsed: JsonNode
  try:
    parsed = parseJson(payload)
  except JsonParsingError:
    return @[]
  case parsed.kind
  of JArray: parsed.elems
  of JObject:
    for key in ["nodes", "results", "data"]:
      let found = parsed.jget(key)
      if found.kind == JArray:
        return found.elems
    @[]
  else: @[]

proc episodeList(payload: string): seq[JsonNode] =
  ## `GET graph/episodes/user/{id}` answers `{"episodes": [...]}`.
  var parsed: JsonNode
  try:
    parsed = parseJson(payload)
  except JsonParsingError:
    return @[]
  case parsed.kind
  of JArray: parsed.elems
  of JObject:
    let found = parsed.jget("episodes")
    if found.kind == JArray: found.elems else: @[]
  else: @[]

proc rowText(row: JsonNode): string =
  ## The rendering, whichever field carries it: edges hold `fact`, nodes hold
  ## `summary` or `name`.
  for key in ["fact", "summary", "name"]:
    let found = row.jget(key)
    if found.kind == JString and found.getStr().len > 0:
      return found.getStr()
  ""

proc rowId(row: JsonNode): string =
  for key in ["uuid_", "uuid"]:
    let found = row.jget(key)
    if found.kind == JString and found.getStr().len > 0:
      return found.getStr()
  ""

proc rowCreated(row: JsonNode): string =
  let found = row.jget("created_at")
  if found.kind == JString: found.getStr() else: ""

proc factOf(row: JsonNode): StoreFact =
  let (subject, content) = unpackFact(rowText(row))
  StoreFact(id: rowId(row), subject: subject, content: content,
            source: "zep", createdAt: rowCreated(row))

proc episodeUuid(body: string): string =
  ## The `uuid_` (or `uuid`) of the episode `add` just ingested — what
  ## `_wait_processed` polls for.
  var parsed: JsonNode
  try:
    parsed = parseJson(body)
  except JsonParsingError:
    return ""
  rowId(parsed)

proc episodeProcessed(ep: JsonNode): bool =
  let found = ep.jget("processed")
  if found.kind == JBool: found.getBool() else: false

# --- the wire --------------------------------------------------------------

proc ensureUser*(c: ZepClient): ZepResult =
  ## `POST users` — creating is idempotent in effect: an already-exists error
  ## is the success case, so the adapter never checks this answer.
  trySend(c, "POST", "/users", $(%*{"user_id": c.userId}))

proc addEpisode*(c: ZepClient, subject, content: string): ZepResult =
  ## `POST graph` — the ingest. `type` is always `"text"`: Waku hands Zep one
  ## rendered blob per fact, exactly like the Python adapter.
  let payload = %*{"data": packFact(subject, content),
        "type": "text", "user_id": c.userId}
  trySend(c, "POST", "/graph", $payload)

proc waitProcessed*(c: ZepClient, uuid: string, timeoutMs: int): bool =
  ## Block until this episode reports `processed`, polling the user's episode
  ## list rather than `episode.get(uuid)` — the per-uuid fetch did not reflect
  ## the flag when the Python adapter was written, and trusting it made a
  ## fully-ingested graph look empty for two minutes.
  if uuid.len == 0:
    return false
  let started = c.nowMs()
  while c.nowMs() - started < timeoutMs:
    let answer = trySend(c, "GET",
      "/graph/episodes/user/" & encodeUrl(c.userId) & "?lastn=20", "")
    if answer.ok:
      for ep in episodeList(answer.body):
        if rowId(ep) == uuid:
          if episodeProcessed(ep):
            return true
          break
    c.sleepMs(pollEveryMs)
  false

proc add*(c: ZepClient, subject, content, source: string): ZepResult =
  ## Ingest, then wait: `add` means "stored enough to be waited on", and the
  ## waiting is what keeps a benchmark that seeds and immediately queries from
  ## reading an empty graph and scoring Zep as having forgotten everything.
  ## `source` is accepted for contract symmetry and not sent: the graph has no
  ## provenance field on ingest.
  discard source
  let answer = c.addEpisode(subject, content)
  if answer.ok:
    discard c.waitProcessed(episodeUuid(answer.body), 120 * 1000)
  answer

proc search*(c: ZepClient, query: string, topK = -1): ZepResult =
  ## `POST graph/search` with the user id at the top level, like the SDK.
  let payload = %*{"query": query, "user_id": c.userId,
        "limit": (if topK > 0: topK else: c.topK)}
  trySend(c, "POST", "/graph/search", $payload)

proc listNodes*(c: ZepClient, limit = 200): ZepResult =
  ## `POST graph/node/user/{id}` — POST, not GET, with the limit in the body.
  let payload = %*{"limit": limit}
  trySend(c, "POST", "/graph/node/user/" & encodeUrl(c.userId), $payload)

proc nodeGet*(c: ZepClient, id: string): ZepResult =
  trySend(c, "GET", "/graph/node/" & encodeUrl(id), "")

proc edgeGet*(c: ZepClient, id: string): ZepResult =
  trySend(c, "GET", "/graph/edge/" & encodeUrl(id), "")

proc nodeDelete*(c: ZepClient, id: string): ZepResult =
  trySend(c, "DELETE", "/graph/node/" & encodeUrl(id), "")

proc edgeDelete*(c: ZepClient, id: string): ZepResult =
  trySend(c, "DELETE", "/graph/edge/" & encodeUrl(id), "")

proc exists*(c: ZepClient, id: string): bool =
  ## A uuid can name a node or an edge and the caller cannot know which, so
  ## both are tried — the same reason `delete` tries both.
  c.edgeGet(id).ok or c.nodeGet(id).ok

proc episodesDone(c: ZepClient, lastn: int): tuple[done: bool, count: int] =
  ## One poll of the double event: every listed episode `processed`, and how
  ## many episodes there are. An empty list is NOT done here — the caller
  ## decides what empty means, because `add`'s waiter and `settle` disagree.
  let answer = trySend(c, "GET",
    "/graph/episodes/user/" & encodeUrl(c.userId) & "?lastn=" & $lastn, "")
  if not answer.ok:
    return (false, -1)
  let eps = episodeList(answer.body)
  if eps.len == 0:
    return (false, 0)
  for ep in eps:
    if not episodeProcessed(ep):
      return (false, eps.len)
  (true, eps.len)

proc settle*(c: ZepClient, timeoutMs: int): bool =
  ## Wait until the GRAPH stopped growing, not until the episodes say done:
  ## every episode processed AND a node count held still `stableNeeded` times.
  ## A live run had every episode `processed=true` with zero nodes, so asking
  ## only the first event returns an unrelated fact for "when is the launch".
  ## An empty episode list settles immediately — nothing was seeded, usually
  ## the arena's control contestant, and there is nothing to wait for.
  let started = c.nowMs()
  # Empty from the start is settled, not a timeout: nothing was seeded,
  # usually the arena's control contestant, and there is nothing to wait for.
  # A failed poll (count -1) is NOT empty — that is a dead socket, which
  # must read as "not ready" rather than as a green light.
  let (done0, n0) = c.episodesDone(50)
  if not done0 and n0 == 0:
    return true
  var last = -1
  var stable = 0
  while c.nowMs() - started < timeoutMs:
    let (done, _) = c.episodesDone(50)
    var nodes = -1
    let listed = c.listNodes(200)
    if listed.ok:
      nodes = nodeRows(listed.body).len
    if done and nodes == last and nodes > 0:
      inc stable
    else:
      stable = 0
    last = nodes
    if stable >= stableNeeded:
      return true
    c.sleepMs(pollEveryMs)
  false

proc zepFactStore*(c: ZepClient): FactStore =
  ## The contract, over this client. Every method answers instead of raising;
  ## `update` with an empty subject reads the subject back first — the graph
  ## stores one ingested blob per fact, so a content-only edit has to rewrite
  ## all of it, which is what Python's `update` does when `subject is None`.
  result.add = proc(subject, content, source: string) =
    discard c.add(subject, content, source)

  result.search = proc(query: string, topK: int): seq[string] =
    let answer = c.search(query, topK)
    var hits: seq[string] = @[]
    if not answer.ok:
      return hits
    for row in searchRows(answer.body):
      let (subject, content) = unpackFact(rowText(row))
      hits.add(if subject.len > 0: "[" & subject & "] " & content else: content)
    hits

  result.list = proc(limit: int): seq[StoreFact] =
    let answer = c.listNodes(limit)
    var found: seq[StoreFact] = @[]
    if not answer.ok:
      return found
    for row in nodeRows(answer.body):
      found.add(factOf(row))
    found

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    let answer = c.search(query, topK)
    var found: seq[StoreFact] = @[]
    if not answer.ok:
      return found
    for row in searchRows(answer.body):
      found.add(factOf(row))
      if found.len >= topK:
        break
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    # A graph has no in-place edit: verify the id exists, then re-ingest the
    # correction and let validity dates supersede the older edge. Deleting
    # first would throw away the history Zep exists to keep.
    if not c.exists(id):
      return false
    var useSubject = subject
    if useSubject.len == 0:
      let known = c.listNodes(500)
      if known.ok:
        for row in nodeRows(known.body):
          let fact = factOf(row)
          if fact.id == id:
            useSubject = fact.subject
            break
    c.add(useSubject, content, "correction").ok

  result.delete = proc(id: FactId): bool =
    # A uuid can name a node or an edge; failure of the first is the ordinary
    # case, not an error — only failing BOTH means unknown.
    if c.nodeDelete(id).ok:
      return true
    c.edgeDelete(id).ok

  result.settle = proc(timeoutMs: int): bool =
    c.settle(timeoutMs)
