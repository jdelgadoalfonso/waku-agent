## Research starts from what the brain already knows (spec 009 A).
##
## Port of `waku/memory/brain.py`: a research turn used to start from
## nothing, repeating whole searches instead of starting from the first
## report. When a turn is research (the `research-report` skill matched)
## and a memory backend is connected, this module runs the searches BEFORE
## the model's first call, hands back what they found as the turn's Used
## list (plus one tool event per search, the shape the loop emits for a
## model's own calls), and writes the "What the company brain already
## knows" block for the system prompt. A search that fails is skipped: a
## turn never waits on one or fails for it.
##
## BACKEND. Python reads Waku Memory (hosted) through an injected search
## callable and never sees the transport; this port does the same, and
## the first backend is Engram over MCP (`engram_mem_search` in the
## agent's own registry — no new connection, the tools are already
## connected). `brainBackendFor` finds it there; nothing found means the
## whole read path is off, exactly like Python with no Waku Memory.
##
## SCOPES. Python asks memory for `scope: "all"` and files a report under
## `project:Company brain`. Engram has no projects to invent: its scopes
## are project/personal/global, so the same two-way split maps as
## `global` (knowledge about the world, readable by every agent —
## waku.one's Knowledge) for company research and `personal` (about the
## person) for everything else, and a search without a scope filter is
## "everywhere" (Python's "all"). Engram's `type` replaces Waku
## Memory's `kind`: a report is filed as `discovery`.
##
## Two deliberate divergences, both from the transport shape: Engram
## answers text (`Found N memories:…`), not Waku Memory's JSON entries,
## so `brainEntries` parses the text rows (`[n] #id (type) — title` plus
## the lines under it, capped like Python's `TEXT_CHARS`) instead of
## JSON, and a report's text carries no date, so the Used list's
## `created_at` is empty rather than invented.

import std/json
import std/strutils

import ./tools
import ./wire

const
  reportMarkerOf* = "<!-- waku-report v1 -->"
    ## The line that opens a research report (spec 007's marker). Declared
    ## here because a memory that IS a report is recognized by it; the
    ## writer lives in `reports.nim`.

  researchSkill* = "research-report"
    ## The skill whose trigger marks a turn as research. Its matcher is
    ## the detector: no second heuristic to drift from what the skill
    ## itself answers to.
  brainHeading* = "What the company brain already knows"
  brainSearchTool* = "engram_mem_search"
    ## The tool name the model would call for the same search, and the
    ## name the read path notifies its searches under.
  brainGetTool* = "engram_mem_get_observation"
    ## The tool that reads one memory whole by id (`mem_get_observation`
    ## on the Engram server, verified live). The read-first digest path
    ## calls it once per earlier report it found.
  companyScope* = "global"
    ## Where company/market research lives (Python's `COMPANY_PROJECT`,
## which is a project; Engram's scopes are project/personal/global, so
## shared knowledge is `global`): readable by every agent on the machine.
  personalScope* = "personal"
    ## What is about the person rather than the work (Python's `global`,
## which in Engram's vocabulary is the company brain instead).
  reportType* = "discovery"
    ## Engram's `type` for a research report (Python's `kind: semantic`).
  subjectLimit* = 6
  companyLimit* = 3
  reportReadLimit* = 3
    ## At most this many earlier reports are read whole for their digest
    ## (Python's `REPORT_LIMIT`, which also caps the second search — here
    ## that cap is `companyLimit`).
  textChars* = 600

  fillerWords = ["a", "an", "the", "of", "for", "on", "about",
    "and", "or", "to", "in", "into", "with", "vs", "versus",
    "me", "my", "our", "us", "we", "i", "you", "please",
    "can", "could", "would", "will", "do", "does", "did",
    "tell", "show", "give", "find", "look", "up", "research",
    "researching", "compare", "comparing", "who", "what", "which",
    "whats", "how", "is", "are", "was", "were", "be", "latest",
    "new", "current", "report", "write", "make", "get", "some",
    "any", "all"]

type
  BrainBackend* = object
    ## A connected memory to read first: `search` runs one query and
    ## answers text, `get` reads one memory whole by id. The zero value
    ## (nil `search`) is disconnected — the read path is off, like
    ## Python's `search=None`. A nil `get` (or nil `digest`) leaves the
    ## digest path off: reports keep their search snippet, like Python
    ## with `get=None`.
    ##
    ## `digest` is injected (it lives in `reports.nim`, which imports
    ## this module, so naming it here would circle the imports): the
    ## wiring passes the real one, tests pass a stub or none.
    search*: proc(args: JsonNode): string {.closure.}
    get*: proc(args: JsonNode): string {.closure.}
    digest*: proc(body: string): string {.closure.}

proc brainConnected*(b: BrainBackend): bool =
  ## There is a memory to read first.
  not b.search.isNil

proc brainBackendFor*(tools: ToolRegistry): BrainBackend =
  ## The read-first backend in an already-built registry: the memory
  ## search tool and the get-one tool, each by its model name. Nothing
  ## found, nothing connected — each side independently.
  for t in tools.tools:
    if t.name == brainSearchTool:
      result.search = t.fn
    elif t.name == brainGetTool:
      result.get = t.fn

proc isResearch*(skillNames: seq[string]): bool =
  ## The trigger skill fired.
  researchSkill in skillNames

proc subject*(message: string): string =
  ## The message without the words that only ask for research:
  ## "research the competitors of mem0" -> "competitors mem0".
  ## Port of `brain.subject` (same filler list, same fallback).
  var kept: seq[string] = @[]
  for w in message.toLower().splitWhitespace():
    let word = w.strip(chars = {'.', ',', '?', '!', ':', ';', '(', ')',
      '"', '\''})
    if word.len > 0 and word notin fillerWords:
      kept.add(word)
  if kept.len > 0: kept.join(" ") else: message.strip()

proc startsMarker*(body: string): bool =
  ## A report opens with the marker, whatever indent precedes it.
  var s2 = body
  while s2.len > 0 and s2[0] in {' ', '\t'}:
    s2 = s2[1 .. ^1]
  s2.startsWith(reportMarkerOf)

proc entryText*(body: string): string =
  ## What one memory may put in the prompt: the body (or snippet) with
  ## the report marker gone, whitespace folded, capped at `textChars`.
  ## Port of Python's `_text`.
  var body2 = body.replace(reportMarkerOf, "").strip()
  body2 = body2.splitWhitespace().join(" ")
  if body2.len > textChars:
    body2 = body2[0 ..< textChars - 1] & "…"
  body2

proc jsonEntries*(doc: JsonNode): seq[JsonNode] =
  ## Waku Memory's own answer shape (`{"entries": [...]}`), read exactly
  ## like Python's `_entries`/`_is_report`/`_title`/`_text`: an entry
  ## without an id is skipped, a report is one whose body opens with the
  ## marker or whose kind is `semantic`, and its title is its `# ` line.
  if doc.kind != JObject:
    return
  let entries = doc.jget("entries")
  if entries.kind != JArray:
    return
  for e in entries:
    if e.kind != JObject:
      continue
    let id = e.jget("id").getStr()
    if id.len == 0:
      continue
    let body = e.jget("body").getStr()
    let snippet = e.jget("snippet").getStr()
    let whole = if body.len > 0: body else: snippet
    var title = ""
    for line in whole.splitLines():
      if line.startsWith("# "):
        title = line[2 .. ^1].strip()
        break
    let kind = e.jget("kind").getStr()
    result.add(%*{"id": id, "title": title, "text": entryText(whole),
      "created_at": e.jget("created_at").getStr(),
      "kind": kind,
      "report": (startsMarker(whole) or kind == "semantic")})

proc brainEntries*(text: string): seq[JsonNode] =
  ## One `{id, title, text, created_at, kind, report}` per hit. Three
  ## shapes are accepted, in this order: Waku Memory's JSON `entries`
  ## (Python's shape), a JSON envelope whose `result` holds Engram's text
  ## rows, and those rows themselves (`[n] #id (type) — title` plus the
  ## lines under them — a JSON string keeps its newlines ESCAPED, so the rows
  ## are only lines once the envelope is unwrapped). Rows without an id
  ## are skipped, like Python's entries without one, and each text is
  ## capped at `textChars`, ellipsis included.
  result = @[]
  try:
    let doc = parseJson(text)
    if doc.kind == JObject and doc.hasKey("entries"):
      return jsonEntries(doc)
    if doc.kind == JObject and doc.jget("result").kind == JString:
      return brainEntries(doc.jget("result").getStr())
  except JsonParsingError:
    discard
  var curId = ""
  var curTitle = ""
  var curLines: seq[string] = @[]
  var curKind = ""
  template flushEntry() =
    if curId.len > 0:
      let body = curLines.join("\n")
      result.add(%*{"id": curId, "title": curTitle,
        "text": entryText(body), "created_at": %"", "kind": curKind,
        "report": startsMarker(body)})
      curId = ""
      curTitle = ""
      curKind = ""
      curLines = @[]
  for line in text.splitLines():
    let s = line.strip()
    if s.len > 3 and s[0] == '[':
      let close = s.find(']')
      let hash = s.find('#', close)
      let dash = s.find("—", hash)
      if close > 0 and hash > close:
        flushEntry()
        let idEnd = s.find(' ', hash)
        curId = if idEnd > hash: s[hash ..< idEnd] else: s[hash .. ^1]
        if dash > 0:
          curTitle = s[dash + 3 .. ^1].strip()
          # "(discovery)" sits between the id and the dash
          let open = s.find('(', close)
          let closeParen = s.find(')', close)
          if open > close and closeParen > open:
            curKind = s[open + 1 ..< closeParen].strip()
        curLines = @[]
        continue
    if curId.len > 0 and s.len > 0:
      curLines.add(s)
  flushEntry()

proc digestReady*(b: BrainBackend): bool =
  ## The digest path is on: a `get` to read with and a `digest` to
  ## shrink with. Either nil leaves reports on their search snippet.
  not b.get.isNil and not b.digest.isNil

proc parseGetId*(id: string, n: var int): bool =
  ## An entry id as the get tool's integer: `"#12"` and `"12"` read
  ## `12`; anything else is not callable (the snippet stands in without
  ## spending a failed call).
  var s = id.strip()
  if s.startsWith("#"):
    s = s[1 .. ^1]
  if s.len == 0:
    return false
  for c in s:
    if c notin {'0' .. '9'}:
      return false
  try:
    n = parseInt(s)
    true
  except ValueError:
    false

proc reportBody*(text: string): string =
  ## The full report body in a get answer, or "" when it holds none.
  ## Two shapes: Waku Memory's (`{"memory": {...}}` with `body`, else
  ## the dict itself) and Engram's (`{"result": text}`, verified live).
  ## Only a body opening with the marker counts — anything else is a
  ## fact or a note, and the snippet already covers it.
  var answer: JsonNode
  try:
    answer = parseJson(text)
  except JsonParsingError:
    return ""
  if answer.kind != JObject:
    return ""
  var candidate = ""
  let mem = answer.jget("memory")
  if mem.kind == JObject:
    candidate = mem.jget("body").getStr()
    if candidate.len == 0:
      candidate = mem.jget("content").getStr()
  elif answer.jget("result").kind == JString:
    candidate = answer.jget("result").getStr()
  elif answer.jget("body").kind == JString:
    candidate = answer.jget("body").getStr()
  if candidate.strip(leading = true, trailing = false)
      .startsWith(reportMarkerOf):
    return candidate
  ""

proc reportDigest*(backend: BrainBackend, id: string): string =
  ## One earlier report's digest, read with the backend's get, or ""
  ## when the read failed or the memory is not a report. Port of
  ## Python's `_report_digest` (which catches everything: the snippet
  ## stands in and the turn goes on).
  if not digestReady(backend):
    return ""
  var n = 0
  if not parseGetId(id, n):
    return ""
  var text = ""
  try:
    text = backend.get(%*{"id": n})
  except CatchableError:
    return ""
  let body = reportBody(text)
  if body.len == 0:
    return ""
  backend.digest(body)

proc readFirst*(message: string,
    backend: BrainBackend): tuple[calls: seq[JsonNode],
    used: seq[JsonNode], context: string] =
  ## Both searches, what they found, and the prompt block. Empty when
  ## the backend is disconnected and when nothing was found — and a
  ## failed search is skipped, never fatal.
  result = (calls: @[], used: @[], context: "")
  if not brainConnected(backend):
    return result
  let about = subject(message)
  # `any` for the subject search, `all` for the targeted one: the first
  # must FIND an earlier report even when the words do not all appear in
  # it (`all` found nothing for "mem0 competitors pricing" against a
  # report that never says "pricing"), which is the reason Python runs a
  # second search at all; the second is a precise lookup (scope + type),
  # so AND is free there. `all_projects` is Engram's Python "all" scope,
  # and it is REQUIRED:
  # a search without a project (or this flag) is refused outright
  # (`expected_project must be a valid non-empty project name`), so the
  # port never names a project it cannot know.
  let asks = @[
    %*{"query": about, "all_projects": true, "limit": subjectLimit,
       "match_mode": "any"},
    %*{"query": about, "all_projects": true, "scope": companyScope,
       "type": reportType, "limit": companyLimit,
       "match_mode": "all"}]
  var seen: seq[string] = @[]
  var blocks: seq[string] = @[]
  for args in asks:
    var text = ""
    try:
      text = backend.search(args)
    except CatchableError:
      continue
    result.calls.add(%*{"tool": brainSearchTool, "args": args,
                        "output": text})
    for e in brainEntries(text):
      if e["id"].getStr() in seen:
        continue
      seen.add(e["id"].getStr())
      result.used.add(%*{"id": e["id"], "text": e["text"],
        "created_at": e["created_at"], "kind": e["kind"],
        "report": e["report"]})
      blocks.add("- " & e["title"].getStr() & " (" &
        e["id"].getStr() & "): " & e["text"].getStr())
  if blocks.len == 0:
    return result
  result.context = brainHeading & ":\n" &
    blocks.join("\n")
