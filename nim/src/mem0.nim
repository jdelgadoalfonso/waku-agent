## Mem0, the hosted semantic store — the port of
## `waku/memory/semantic/mem0_store.py` against the API generation the pinned
## SDK actually speaks (`mem0ai 2.2.0`): v3 for add/search/get_all, v1 for
## update and delete. Zero dependencies, REST by hand over the port's one HTTP
## helper, exactly like the MCP bridge and the OTLP exporter.
##
## Waku's own store is FTS5 keyword search; Supabase is embeddings you host.
## Mem0 is a memory *service*: you hand it text and it decides what is worth
## keeping, then retrieves it semantically. Having all three behind one
## `FactStore` is what makes the Memory arena a fair fight — one agent, one
## model, one loop, and the only thing that changes is where facts live.
##
## ## What v3 changed, and what it costs this contract
##
## v3 is the "additive pipeline": one LLM call extracts memories, nothing is
## updated or deleted, and the write is ASYNCHRONOUS. `add` returns an
## `event_id`. So the old guard `infer=False` is gone, and the promise
## `add()` used to make — "this fact is stored and findable" — is no longer
## something the service guarantees. Python's adapter still passes that flag
## (see the finding in `odd/tasks/nim-mem0-store.md` L6); against v3 it is not
## being honoured by anyone. This port does not pretend otherwise: `add`
## means "enqueued for extraction", and `settle` is what tells you whether it
## landed.
##
## ## What v3 gave us, which is worth more than it took
##
## A readiness signal. `settle()` no longer has to guess by watching a row
## count stop moving (3 identical reads every 2s, which is what the Python
## adapter does because it had nothing better): it asks `GET /v1/event/{id}/`
## whether the event this `add` produced is done. That is the first honest
## "settled means searchable" in this integration.
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
    ## compile: Nim reads the names as identifiers), and the tests want to
    ## say which half they are checking.

  Mem0Result* = object
    ## One HTTP answer, already judged. `detail` is bounded so a caller that
    ## logs it cannot print more than the terminal showed.
    ok*: bool
    status*: int
    body*: string
    detail*: string

  Mem0Client* = ref object
    ## One mem0 account. The three seams (send, clock, sleep) exist so the
    ## tests can drive `settle` without a network and without waiting; each
    ## has a real default, so `newMem0Client` with an endpoint alone is the
    ## normal construction.
    apiKey*: string
    userId*: string
    host*: string
    topK*: int
    pendingEvent*: string
      ## The `event_id` of the last `add`, "" when there is nothing to wait
      ## for. Kept because `settle` has to be callable with no add in front
      ## of it (the arena's control contestant seeds nothing at all).
    send*: proc(verb, path, body: string): Mem0Result
    nowMs*: proc(): int64
    sleepMs*: proc(ms: int64)

const
  reasonLimit* = 160
    ## One line, not a stack trace: these land in stderr inside a turn.

proc bounded(text: string): string =
  if text.len <= reasonLimit: text
  else: text[0 ..< reasonLimit] & "..."

proc packFact*(subject, content: string): string =
  ## `"subject: content"`, subject lowercased — Waku keeps the two apart and
  ## mem0 stores one blob, so the round trip goes through this shape and
  ## `unpackFact` reads it back. It is the same packing the Python adapter
  ## does, for the same reason: `[subject] content` stays renderable on the
  ## way out without a second field or a second call.
  subject.toLowerAscii().strip() & ": " & content

proc unpackFact*(text: string): PackedFact =
  ## The other half of the round trip. A blob with no `": "` is all content:
  ## splitting it would invent a subject out of nothing and then store the
  ## user's sentence in a field called subject. `text` is a plain string, so
  ## the null guard is a length check — `orElse` is for Options.
  let safe = if text.len > 0: text else: ""
  let parts = safe.split(": ", maxsplit = 1)
  if parts.len == 2: (parts[0], parts[1]) else: ("", safe)

proc mem0Headers(c: Mem0Client): HttpHeaders =
  newHttpHeaders([("Content-Type", "application/json"),
                  ("Authorization", "Token " & c.apiKey)])

proc postSpansSafe(verb: HttpMethod, url, body: string,
                   headers: HttpHeaders): Mem0Result =
  ## The one live round trip, over `http.nim`'s helper so an `https://` host
  ## gets the TLS context in a `-d:wakuTls` build and is refused honestly in
  ## the default one. A refused or broken socket is `ok: false` with a short
  ## reason: the contract forbids raising from a memory backend.
  var client = newTlsHttpClient(timeout = 30 * 1000)
  try:
    let response = client.request(url, verb, body, headers)
    # `status` is the human string ("200 OK") and `code` the enum, so the
    # number comes from splitting the string; anything unparseable is 0 and
    # reads as a failure, which is the safe direction.
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
  ## "GET"/"POST"/"PUT"/"DELETE" as the wire verb. The seam takes the verb as
  ## a string so a test can assert on it without importing httpclient.
  case name
  of "GET": HttpGet
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  else: HttpPost

proc newMem0Client*(apiKey, userId: string, topK = 4,
                    host = "https://api.mem0.ai",
                    send: proc(verb, path, body: string): Mem0Result = nil,
                    nowMs: proc(): int64 = nil,
                    sleepMs: proc(ms: int64) = nil): Mem0Client =
  ## `apiKey` is `MEM0_API_KEY`, `userId` is `MEM0_USER_ID` with the
  ## "empty means absent" rule already applied by the caller (Python's
  ## `env_or`): a blank box in the Connections form must fall back to the
  ## default rather than scoping somebody's memory to "".
  ##
  ## A local `client` rather than `result`: inside these closures `result`
  ## would be the CLOSURE's result, so naming it once here is what keeps the
  ## default send pointing at this account instead of at a Mem0Result.
  let client = Mem0Client(apiKey: apiKey, userId: userId, host: host, topK: topK)
  if send != nil:
    client.send = send
  else:
    client.send = proc(verb, path, body: string): Mem0Result =
      postSpansSafe(parseMethod(verb), client.host & path, body,
                    mem0Headers(client))
  if nowMs != nil:
    client.nowMs = nowMs
  else:
    client.nowMs = proc(): int64 = int64(epochTime() * 1000)
  if sleepMs != nil:
    client.sleepMs = sleepMs
  else:
    client.sleepMs = proc(ms: int64) = sleep(int(ms))
  client

proc rows(payload: string): JsonNode =
  ## The shape tolerance Python insists on: the hosted API has answered with a
  ## bare list, `{"results": [...]}` and `{"memories": [...]}` across versions.
  ## Pinning to whichever shipped the day this was written makes a benchmark
  ## that breaks on a minor API bump, which is worse than no benchmark.
  var parsed: JsonNode
  try:
    parsed = parseJson(payload)
  except JsonParsingError:
    return newJArray()
  case parsed.kind
  of JArray: parsed
  of JObject:
    for key in ["results", "memories", "data"]:
      let found = parsed.jget(key)
      if found.kind == JArray:
        return found
    newJArray()
  else: newJArray()

proc rowText(row: JsonNode): string =
  ## The blob, whichever field carries it in this version.
  for key in ["memory", "text"]:
    let found = row.jget(key)
    if found.kind == JString and found.getStr().len > 0:
      return found.getStr()
  ""

proc rowId(row: JsonNode): string =
  for key in ["id", "memory_id"]:
    let found = row.jget(key)
    if found.kind == JString and found.getStr().len > 0:
      return found.getStr()
    if found.kind == JInt:
      return $found.getBiggestInt()
  ""

proc rowSource(row: JsonNode): string =
  let meta = row.jget("metadata")
  if meta.kind == JObject:
    let found = meta.jget("source")
    if found.kind == JString: return found.getStr()
  ""

proc factOf(row: JsonNode): StoreFact =
  let (subject, content) = unpackFact(rowText(row))
  let created = row.jget("created_at")
  StoreFact(id: rowId(row), subject: subject, content: content,
            source: rowSource(row),
            createdAt: if created.kind == JString: created.getStr() else: "")

proc rememberEvent(c: Mem0Client, body: string) =
  ## Keep the `event_id` of the last successful add so `settle` has something
  ## to wait for. An add that failed leaves whatever was pending alone: a
  ## settle that waited on an event from a previous add would be lying.
  var parsed: JsonNode
  try:
    parsed = parseJson(body)
  except JsonParsingError:
    return
  for key in ["event_id", "id"]:
    let found = parsed.jget(key)
    if found.kind == JString and found.getStr().len > 0:
      c.pendingEvent = found.getStr()
      return

proc trySend(c: Mem0Client, verb, path, body: string): Mem0Result =
  ## The send, with the contract's first rule applied ONCE so that no call
  ## site can forget it: a memory backend that throws takes the whole turn
  ## down with it. Every method below goes through here rather than calling
  ## `send` directly — the alternative was one try/except per method, and the
  ## one somebody forgets is the bug.
  try:
    result = c.send(verb, path, body)
  except CatchableError as exc:
    result = Mem0Result(ok: false, status: 0, body: "", detail: bounded(exc.msg))

proc add*(c: Mem0Client, subject, content, source: string): Mem0Result =
  ## `POST /v3/memories/add/`, exactly what the pinned SDK sends: the messages
  ## array, `user_id` at the TOP level (v3 accepts entity ids there, unlike v2
  ## search which demands them inside `filters`) and the provenance metadata.
  ## NO `infer` field: v3 has no such flag (see the module header).
  let payload = %*{"messages": [%*{"role": "user",
        "content": packFact(subject, content)}],
        "user_id": c.userId,
        "metadata": %*{"source": source}}
  let answer = trySend(c, "POST", "/v3/memories/add/", $payload)
  # The event belongs to the CLIENT, not to whoever called add: recording it
  # here is what makes settle honest for any caller, not only the adapter.
  if answer.ok:
    c.rememberEvent(answer.body)
  answer

proc search*(c: Mem0Client, query: string, topK = -1): Mem0Result =
  ## `POST /v3/memories/search/` with the entity id inside `filters` — the
  ## SDK raises on a top-level `user_id` here, and the API answers 400.
  let payload = %*{"query": query,
        "filters": %*{"user_id": c.userId},
        "top_k": (if topK > 0: topK else: c.topK)}
  trySend(c, "POST", "/v3/memories/search/", $payload)

proc getAllRows*(c: Mem0Client, limit = 200): Mem0Result =
  ## `POST /v3/memories/` — POST, not GET, in v3, and paginated. The page
  ## size carries the caller's limit so one round trip is one answer.
  let payload = %*{"filters": %*{"user_id": c.userId},
        "page": 1, "page_size": limit}
  trySend(c, "POST", "/v3/memories/", $payload)

proc update*(c: Mem0Client, id: string, text: string): Mem0Result =
  ## `PUT /v1/memories/{id}/`. The id is percent-encoded by the seam's caller
  ## expectation: it is an opaque string and a UUID needs no escaping, but a
  ## hostile id must not be able to walk out of the path.
  trySend(c, "PUT", "/v1/memories/" & encodeUrl(id) & "/",
        $(%*{"text": text}))

proc delete*(c: Mem0Client, id: string): Mem0Result =
  trySend(c, "DELETE", "/v1/memories/" & encodeUrl(id) & "/", "")

proc eventDone*(c: Mem0Client, eventId: string): Mem0Result =
  ## `GET /v1/event/{id}/` — the readiness question. Tolerant about the field
  ## name, like every shape in this file.
  trySend(c, "GET", "/v1/event/" & encodeUrl(eventId) & "/", "")

proc settled*(body: string): bool =
  ## Whether the event is finished. v3 has used more than one spelling, so
  ## this accepts the honest ones and refuses to guess: an event nobody
  ## recognises reads as "not settled yet", which makes settle wait and then
  ## time out. Answering true on an unknown shape would be the one answer the
  ## contract forbids.
  var parsed: JsonNode
  try:
    parsed = parseJson(body)
  except JsonParsingError:
    return false
  for key in ["status", "state"]:
    let found = parsed.jget(key)
    if found.kind == JString:
      let value = found.getStr().toUpperAscii()
      if value in ["DONE", "COMPLETED", "SUCCESS", "SUCCEEDED", "FINISHED"]:
        return true
      if value in ["FAILED", "ERROR"]:
        return false
  for key in ["processed", "done", "completed"]:
    let found = parsed.jget(key)
    if found.kind == JBool:
      return found.getBool()
  false

proc settle*(c: Mem0Client, timeoutMs: int): bool =
  ## Ask the service whether the write landed, instead of watching a count
  ## stop moving. No pending event means nothing to wait for, which is the
  ## arena's control contestant and any caller that only read: `true`,
  ## immediately, and a local store is never slower than that.
  if c.pendingEvent.len == 0:
    return true
  let started = c.nowMs()
  while c.nowMs() - started < timeoutMs:
    let answer = c.eventDone(c.pendingEvent)
    if answer.ok and settled(answer.body):
      c.pendingEvent = ""
      return true
    c.sleepMs(2000)
  false

proc mem0FactStore*(c: Mem0Client): FactStore =
  ## The contract, over this client. Every method answers instead of raising,
  ## and `update` with an empty subject reads the subject back first — mem0
  ## stores one blob, so a subject-only edit has to rewrite all of it, which
  ## is what Python's `update` does when `subject is None`.
  result.add = proc(subject, content, source: string) =
    # `add` records its own event id; the adapter only forwards.
    discard c.add(subject, content, source)

  result.search = proc(query: string, topK: int): seq[string] =
    let answer = c.search(query, topK)
    var hits: seq[string] = @[]
    if not answer.ok:
      return hits
    for row in rows(answer.body):
      let (subject, content) = unpackFact(rowText(row))
      hits.add(if subject.len > 0: "[" & subject & "] " & content else: content)
    hits

  result.list = proc(limit: int): seq[StoreFact] =
    let answer = c.getAllRows(limit)
    var found: seq[StoreFact] = @[]
    if not answer.ok:
      return found
    for row in rows(answer.body):
      found.add(factOf(row))
    found

  result.searchWithIds = proc(query: string, topK: int): seq[StoreFact] =
    let answer = c.search(query, topK)
    var found: seq[StoreFact] = @[]
    if not answer.ok:
      return found
    for row in rows(answer.body):
      found.add(factOf(row))
    found

  result.update = proc(id: FactId, content, subject: string): bool =
    var useSubject = subject
    if useSubject.len == 0:
      # Read the subject back rather than dropping it: that is the whole
      # reason the contract's `update` is one method and not two.
      let known = c.getAllRows(500)
      if not known.ok:
        return false
      for row in rows(known.body):
        let fact = factOf(row)
        if fact.id == id:
          useSubject = fact.subject
          break
    c.update(id, packFact(useSubject, content)).ok

  result.delete = proc(id: FactId): bool =
    c.delete(id).ok

  result.settle = proc(timeoutMs: int): bool =
    c.settle(timeoutMs)