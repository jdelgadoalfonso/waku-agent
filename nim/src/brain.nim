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

const
  researchSkill* = "research-report"
    ## The skill whose trigger marks a turn as research. Its matcher is
    ## the detector: no second heuristic to drift from what the skill
    ## itself answers to.
  brainHeading* = "What the company brain already knows"
  brainSearchTool* = "engram_mem_search"
    ## The tool name the model would call for the same search, and the
    ## name the read path notifies its searches under.
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
    ## answers text. The zero value (nil `search`) is disconnected — the
    ## read path is off, like Python's `search=None`.
    search*: proc(args: JsonNode): string {.closure.}

proc brainConnected*(b: BrainBackend): bool =
  ## There is a memory to read first.
  not b.search.isNil

proc brainBackendFor*(tools: ToolRegistry): BrainBackend =
  ## The read-first backend in an already-built registry: the memory
  ## search tool by its model name. Nothing found, nothing connected.
  for t in tools.tools:
    if t.name == brainSearchTool:
      let fn = t.fn
      return BrainBackend(search: fn)
  BrainBackend()

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

proc brainEntries*(text: string): seq[JsonNode] =
  ## One `{id, title, text}` per Engram hit row (`[n] #id (type) — title`
  ## plus the lines under it): the entries behind a Used list. Rows
  ## without an id are skipped, like Python's entries without one, and
  ## each text is capped at `textChars`, ellipsis included.
  result = @[]
  var curId = ""
  var curTitle = ""
  var curLines: seq[string] = @[]
  template flushEntry() =
    if curId.len > 0:
      var body = curLines.join(" ").splitWhitespace().join(" ")
      if body.len > textChars:
        body = body[0 ..< textChars - 1] & "…"
      result.add(%*{"id": curId, "title": curTitle, "text": body})
      curId = ""
      curTitle = ""
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
        curTitle = if dash > 0: s[dash + 3 .. ^1].strip() else: ""
        curLines = @[]
        continue
    if curId.len > 0 and s.len > 0:
      curLines.add(s)
  flushEntry()

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
  let asks = @[
    %*{"query": about, "limit": subjectLimit, "match_mode": "any"},
    %*{"query": about, "scope": companyScope, "type": reportType,
       "limit": companyLimit, "match_mode": "any"}]
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
        "created_at": %"", "kind": %"", "report": %false})
      blocks.add("- " & e["title"].getStr() & " (" &
        e["id"].getStr() & "): " & e["text"].getStr())
  if blocks.len == 0:
    return result
  result.context = brainHeading & ":\n" &
    blocks.join("\n")
