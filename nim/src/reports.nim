## Research reports — a reply that holds one is saved whole (spec 007).
##
## Port of `waku/memory/reports.py`: the `research-report` skill teaches
## the format (waku-report v1, one Markdown document whose first line is
## MARKER) and this module is the writer's half — it finds the report in
## the reply, sends it to the memory backend as ONE memory in the scope
## the report's subject deserves, and hands back a short chat reply plus
## a `report` event for the chat's card.
##
## Same three rules as Python, unchanged:
## 1. the report is found only when a line is exactly MARKER;
## 2. `isCompanyResearch` fail-CLOSES to personal (a model may answer
##    "true" as a string; anything else, an error included, is personal),
##    so a report is never filed as company knowledge by mistake;
## 3. `saveReport` leaves the reply whole and emits no event when there
##    is no report, no backend, or the send failed — a failure is
##    swallowed, never raised, because the turn is already answered.
##
## BACKEND. Python's `remember` is a callable Waku Memory hands it; here
## it is the Engram `mem_save` tool out of the agent's own registry
## (`brainBackendFor`'s sibling, `saveBackendFor`), which takes a title,
## the body and a scope. A send that answers without a parsable id reads
## as failed, same as Python's `RuntimeError(text[:200])` on a bad shape.

import std/json
import std/sequtils
import std/strutils

import ./brain
import ./loop
import ./tools
import ./wire

const
  reportMarker* = "<!-- waku-report v1 -->"
    ## The line that opens a report, alone on its line.

  scopePrompt* = """\
A research report's title and summary follow. Answer true when it is research
about a company or market (companies, competitors, products, prices, funding,
launches), and false when it is about the user's own life.

Reply with ONLY this JSON: {"company_research": true} or {"company_research": false}

Title: {title}
Summary:
{summary}"""
    ## Port of Python's `SCOPE_PROMPT`, `{`/`}` doubled exactly as Python's
    ## `.format` needs.

  reportSaveTool* = "engram_mem_save"
    ## The backend's save tool, by the model name it carries in the
    ## registry (`brainSearchTool` is its search sibling).

type
  Report* = object
    ## One report out of a reply: what came before the marker, the report
    ## itself from the marker on, its title and its summary bullets.
    preface*: string
    body*: string
    title*: string
    summary*: seq[string]

  SaveBackend* = object
    ## A connected memory to write reports to. The zero value is
    ## disconnected: no report is saved and the reply stays whole.
    save*: proc(args: JsonNode): string {.closure.}

proc saveBackendFor*(tools: ToolRegistry): SaveBackend =
  ## The save backend in an already-built registry. Nothing found,
  ## nothing connected.
  for t in tools.tools:
    if t.name == reportSaveTool:
      let fn = t.fn
      return SaveBackend(save: fn)
  SaveBackend()

proc findReport*(reply: string, found: var Report): bool =
  ## The report in `reply`, if any: a line exactly equal to MARKER.
  ## `found` is only written when there is one (Python's `None`), so a
  ## reply without a report keeps its own body untouched.
  let lines = (if reply.len > 0: reply else: "").splitLines()
  var start = -1
  for i, line in lines:
    if line.strip() == reportMarker:
      start = i
      break
  if start < 0:
    return false
  let rest = lines[start + 1 .. ^1]
  var title = ""
  for line in rest:
    if line.startsWith("# "):
      title = line[2 .. ^1].strip()
      break
  var summary: seq[string] = @[]
  var inside = false
  for line in rest:
    if line.startsWith("## "):
      inside = line[3 .. ^1].strip().toLowerAscii() == "summary"
    elif inside:
      var s = line
      while s.len > 0 and s[0] in {' ', '\t'}:
        s = s[1 .. ^1]
      if s.startsWith("- ") or s.startsWith("* "):
        summary.add(s[2 .. ^1].strip())
  found = Report(preface: lines[0 ..< start].join("\n").strip(),
    body: lines[start .. ^1].join("\n").strip() & "\n",
    title: if title.len > 0: title else: "Research report",
    summary: summary)
  true

proc chatReply*(report: Report): string =
  ## What the chat keeps: the sentences before the marker, or the
  ## Summary's first three bullets when the model wrote none, then where
  ## the rest went. Port of `chat_reply`.
  var lead = report.preface
  if lead.len == 0:
    var bullets: seq[string] = @[]
    for b in report.summary[0 ..< min(3, report.summary.len)]:
      bullets.add(if b.len > 0 and b[^1] in ['.', '!', '?']: b else: b & ".")
    lead = bullets.join(" ")
  let saved = "Report saved: " & report.title & "."
  if lead.len > 0: lead & "\n\n" & saved else: saved

const
  DIGEST_CHARS* = 1500
    ## What one earlier report may put in a prompt: title, Summary,
    ## key numbers.

  TRIMMED* = "[The rest of this report was cut from the context after you read it; waku_memory_memory_get returns it whole again.]"
    ## The note a digest carries: the whole report is one `memory_get`
    ## away.

proc strOf*(node: JsonNode): string =
  ## Python's `str(value)` for a tile field: strings travel whole,
  ## numbers and booleans read as their JSON text, anything else as "".
  case node.kind
  of JString: node.getStr()
  of JInt: $node.getBiggestInt()
  of JFloat: $node.getFloat()
  of JBool: $node.getBool()
  else: ""

proc isRunCost*(label: string): bool =
  ## Port of `_RUN_COST`: `cost of (this|the) (run|turn|report|research)`
  ## case-insensitive with word boundaries — a tile stating what a run
  ## cost is never a key number (the model cannot see its own token cost).
  let lower = label.toLowerAscii()
  for det in ["this", "the"]:
    for noun in ["run", "turn", "report", "research"]:
      let phrase = "cost of " & det & " " & noun
      var at = lower.find(phrase)
      while at >= 0:
        let beforeOk = at == 0 or lower[at - 1] notin {'a' .. 'z', '0' .. '9', '_', 'A' .. 'Z'}
        let afterIx = at + phrase.len
        let afterOk = afterIx >= lower.len or lower[afterIx] notin {'a' .. 'z', '0' .. '9', '_', 'A' .. 'Z'}
        if beforeOk and afterOk:
          return true
        at = lower.find(phrase, at + 1)
  false

proc metricsTiles*(body: string): seq[JsonNode] =
  ## Every `waku-metrics` tile list in `body`, in order. A fence opens
  ## only at a line start (`^```waku-metrics`, MULTILINE) and closes at
  ## the next `\n``` (non-greedy DOTALL); unparsable or non-list
  ## payloads contribute nothing, like Python's `except ValueError`.
  var i = 0
  let fence = "```waku-metrics\n"
  while true:
    let at = body.find(fence, i)
    if at < 0:
      break
    if at != 0 and body[at - 1] != '\n':
      i = at + 1
      continue
    let inner0 = at + fence.len
    let closeAt = body.find("\n```", inner0)
    if closeAt < 0:
      break
    let raw = body[inner0 ..< closeAt]
    i = closeAt + 1
    var parsed: JsonNode
    try:
      parsed = parseJson(raw)
    except JsonParsingError:
      continue
    if parsed.kind != JArray:
      continue
    for tile in parsed:
      result.add(tile)

proc digest*(body: string, limit: int = DIGEST_CHARS): string =
  ## An earlier report in at most `limit` characters: its title, its
  ## Summary bullets and its waku-metrics tiles ("key numbers").
  var report: Report
  if not findReport(body, report):
    report = Report(preface: "", body: if body.len > 0: body else: "",
      title: "Research report", summary: @[])
  var lines = @[report.title]
  for b in report.summary:
    lines.add("- " & b)
  var numbers: seq[string] = @[]
  for tile in metricsTiles(report.body):
    if tile.kind != JObject:
      continue
    let label = strOf(tile.jget("label"))
    if label.len == 0 or isRunCost(label):
      continue
    let value = strOf(tile.jget("value"))
    let note = strOf(tile.jget("note"))
    numbers.add(label & ": " & value & (if note.len > 0: " (" & note & ")" else: ""))
  if numbers.len > 0:
    lines.add("Numbers: " & numbers.join("; "))
  let text = lines.join("\n")
  if text.len <= limit: text else: text[0 ..< limit - 1] & "\xe2\x80\xa6"

proc tryShrinkReport*(text: string, short: var string): bool =
  ## Port of `_shrunk`: the digest form of a `memory.get` answer holding
  ## a report, or false when `text` is not one (invalid JSON, no report).
  var answer: JsonNode
  try:
    answer = parseJson(text)
  except JsonParsingError:
    return false
  if answer.kind != JObject:
    return false
  let memory = if answer.hasKey("memory") and answer["memory"].kind == JObject:
    answer["memory"] else: answer
  let body = memory.jget("body")
  if body.kind != JString or reportMarker notin body.getStr():
    return false
  var kept = newJObject()
  for k in ["id", "kind", "scope", "created_at"]:
    if memory.hasKey(k):
      kept[k] = memory[k]
  kept["body"] = %(digest(body.getStr()) & "\n\n" & TRIMMED)
  short = $(%*{"memory": kept})
  true

proc shrinkRead*(messages: var seq[JsonNode]) =
  ## Cut each whole report the model already read to its digest.
  ## Every tool result in `messages` except the newest (which the model
  ## has not read yet) that is a memory.get answer holding a report
  ## longer than twice DIGEST_CHARS keeps the memory's id, kind, scope
  ## and date, and its body becomes the digest plus a note that
  ## memory_get returns it whole again.
  if messages.len == 0:
    return
  for i in 0 ..< messages.len - 1:
    let message = messages[i]
    if message.kind != JObject or message.jget("role").getStr() != "user":
      continue
    let content = message.jget("content")
    if content.kind != JArray:
      continue
    for blk in content:
      if blk.kind != JObject or blk.jget("type").getStr() != "tool_result":
        continue
      let text = blk.jget("content")
      if text.kind != JString:
        continue
      let s = text.getStr()
      if reportMarker notin s or s.len <= 2 * DIGEST_CHARS:
        continue
      var short = ""
      if tryShrinkReport(s, short):
        blk["content"] = %short

proc isCompanyResearch*(client: LlmClient, smallModel: string,
    report: Report, notify: Observer = nil): bool =
  ## The company/personal decision for one report, asked of the small
  ## model and metered as a `report` call (Python's `metered(... "report")`).
  ## Fail-closed: only a `"true"` string says company, everything else
  ## (including an error) is the person's own life.
  let summary = report.summary.mapIt("- " & it).join("\n")
  let prompt = scopePrompt
    .replace("{title}", report.title)
    .replace("{summary}", summary)
  try:
    let req = %*{"model": smallModel, "max_tokens": 600,
                 "messages": @[%*{"role": "user", "content": prompt}]}
    let text = textOf(meteredClient(client, "report", smallModel,
      notify).create(req)["content"])
    let a = text.find('{')
    let b = text.rfind('}')
    if a < 0 or b < a:
      return false
    let answer = parseJson(text[a .. b])
    # Python's `str(value).lower() == "true"`: a JSON true and the strings
    # "true"/"True" all say company; every other value says personal.
    let flag = answer.jget("company_research")
    if flag.kind == JBool:
      return flag.getBool()
    return flag.getStr().toLowerAscii() == "true"
  except CatchableError:
    return false

proc rememberReport*(backend: SaveBackend, report: Report,
    scope: string): string =
  ## Send the report whole to the memory that took it, and name the id it
  ## came back with. Raises when the answer does not name one — a send
  ## that cannot be identified is a send that failed (Python's
  ## `RuntimeError(text[:200])`), and the caller keeps the reply whole.
  if backend.save.isNil:
    raise newException(IOError, "no memory backend to save a report in")
  let text = backend.save(%*{"title": report.title, "content": report.body,
    "scope": scope, "type": brain.reportType, "capture_prompt": false})
  var answer: JsonNode
  try:
    answer = parseJson(text)
  except JsonParsingError:
    raise newException(IOError, text[0 ..< min(200, text.len())])
  # Engram answers `{"id": 406, ...}` — a NUMBER. Other shapes (a string
  # id, an `observation.id`) are accepted too; none of them means the send
  # did not land, which is what the caller treats as a failed send.
  for node in [answer.jget("id"),
      answer.jget("observation").jget("id"),
      answer.jget("memory").jget("id")]:
    if node.kind == JString and node.getStr().len > 0:
      return node.getStr()
    if node.kind == JInt:
      return $node.getBiggestInt()
  raise newException(IOError, "the backend named no id for the report")

proc saveReport*(reply: string, backend: SaveBackend,
    company: proc(report: Report): bool): tuple[reply: string,
    event: JsonNode] =
  ## `(the chat reply, the report event)`. The reply comes back unchanged
  ## with no event when it holds no report, when no backend is connected
  ## and when the send failed. A failure is swallowed: the turn has
  ## already been answered.
  var report: Report
  if not findReport(reply, report):
    return (reply, newJNull())
  if backend.save.isNil:
    return (reply, newJNull())
  let isCompany = company(report)
  let scope = if isCompany: brain.companyScope else: brain.personalScope
  var id = ""
  try:
    id = rememberReport(backend, report, scope)
  except CatchableError:
    return (reply, newJNull())
  var summary = newJArray()
  for b in report.summary:
    summary.add(%b)
  (chatReply(report),
    %*{"title": report.title, "memory_id": id, "scope": scope,
      "summary": summary})