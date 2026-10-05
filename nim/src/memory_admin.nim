## Memory self-management tools — port of `waku/tools/memory_admin.py`.
##
## `manageMemory` (search/correct/forget facts and episodes), `updateSoul`
## (append a behaviour rule to SOUL.md), `createSkill` (author a SKILL.md).
## Everything stays on the local machine.
##
## Deferred with notes (need phase 4+ wiring, no local equivalent yet):
## - `validSkillText` is deliberately stricter than `_parse_text`: an empty
##   description is rejected, while Python checks key presence only. The
##   tool's own message promises "present and non-trivial", so the strict
##   side matches the contract the model reads.
## - `createSkill`'s live `memory.skills.refresh()`: the file write below IS
##   the durable effect; re-scanning a running session lands with session wiring.
## - the bundled-skills existence check takes its dirs as a parameter; phase 4
##   passes the real checkout/wheel locations, tests pass temp dirs.
## - episode `id` is `int64` (SQLite). Python coerces non-digit ids for the
##   Notion backend (UUID pages); that backend is out of scope until phase 5.

import std/json
import std/os
import std/re
import std/strutils
import std/unicode

import db_connector/db_sqlite

import ./episodes
import ./factstore
import ./messages
import ./notes
import ./tools
import ./wire

const
  soulMax* = 8000
  defaultSoul* = """You are Waku, a personal assistant running locally on your user's laptop.
You are concise, warm, and proactive. You remember what your user tells you.

Rules:
- When the user wants to schedule something, use create_event. Resolve relative
  dates and times ("next Tuesday", "in 30 minutes") to ISO timestamps yourself;
  the current date and time are given below — trust them, never ask the user
  what time it is.
- When the user asks what's on their calendar (a day, a week, "yesterday"), use
  list_events — you CAN read the calendar, not just write to it.
- When the user shares something durable about a person, project, or preference,
  use save_note to remember it.
- When asked to message someone, use send_message (it drafts to a local outbox).
- If memory context is provided below, trust it — it came from your own store.
- Call each tool at most once per request. Your history shows [tools used: ...]
  lines for past turns — if a tool already ran, do NOT run it again; answer
  from that record instead.
- Be honest about where things live. Every tool's output states exactly where
  its artifact landed (local calendar file, Apple Calendar, memory database at
  .waku/state.db) — relay that truthfully, and never claim something synced
  anywhere the tool output doesn't say.
- You can manage your own memory: use manage_memory to correct or forget facts,
  update_soul to save a standing preference the user gives you, and create_skill
  to save a repeatable workflow the user teaches you (only after they say yes).
"""
  slugPattern = "^[a-z0-9][a-z0-9-]{1,40}$"
  skillFrontPattern = "(?s)^---\n(.*?)\n---\n(.*)$"

let
  slugRe = re(slugPattern)
  skillFrontRe = re(skillFrontPattern)

proc rawId*(args: JsonNode): string =
  ## The row id as it came in, whatever JSON type it arrived as: a number
  ## from sqlite's dashboard, a string from a hosted store's. Coercing both
  ## to text here is what lets one call site serve every backend — the same
  ## `str(payload.get("id", ""))` the Python dashboard does.
  let raw = args.jget("id")
  case raw.kind
  of JString: raw.getStr()
  of JInt: $raw.getBiggestInt()
  else: ""

proc manageMemory*(db: DbConn, facts: FactStore, episodes: EpisodeStore,
                   action: string,
                   kind = "fact", id = "", query = "", content = "",
                   subject = ""): string =
  ## Port of `manage_memory`. Episode search lists + substring-filters
  ## (no FTS there, same as Python); facts go through the contract, so this
  ## is the same code whichever backend holds them.
  ##
  ## `id` is a string because it is opaque: sqlite's counter for the local
  ## store, a UUID for mem0. The dashboard has always handed it back
  ## verbatim, so nothing downstream had to parse it.
  let act = action.toLowerAscii()
  if act == "search":
    if kind == "episode":
      var hits: seq[string] = @[]
      for e in episodes.list(20):
        if query.len == 0 or query.toLower() in e.summary.toLower():
          hits.add("#" & e.id & " (" & e.happenedAt & ") " & e.summary)
          if hits.len >= 8:
            break
      return if hits.len > 0: hits.join("\n") else: "no episodes"
    var lines: seq[string] = @[]
    for f in facts.searchWithIds(query, 8):
      lines.add("#" & f.id & " [" & f.subject & "] " & f.content)
    return if lines.len > 0: lines.join("\n") else: "no matching facts"
  if act == "update":
    if kind != "fact":
      return "Only facts can be updated (episodes are historical)."
    # An empty subject means "leave it alone" — that is the contract's
    # `subject=None`, and the adapter is where each backend's own shape gets
    # absorbed (a remote store rewrites one blob).
    let ok = facts.update(id, content, subject)
    return if ok: "Updated fact #" & $id & "." else: "No fact with id " & $id & "."
  if act == "delete":
    if kind == "episode":
      return if episodes.delete(id): "Deleted episode #" & id & "."
             else: "No episode with id " & id & "."
    return if facts.delete(id): "Deleted fact #" & id & "."
           else: "No fact with id " & id & "."
  return "action must be one of: search, update, delete"

proc loadSoul*(home: string): string =
  ## Read SOUL.md, creating it with the default persona on first run.
  ## Port of `load_soul` in `waku/runtime/session.py`.
  let path = home / "SOUL.md"
  if not fileExists(path):
    writeFile(path, defaultSoul)
  return readFile(path)

proc updateSoul*(home, rule: string): string =
  ## Append one behaviour rule under `## Learned rules`. Append-only:
  ## full rewrites stay human work in the dashboard. Port of `update_soul`.
  ## Length is counted in runes (Python counts code points, not bytes).
  var r = rule.strip().strip(leading = true, trailing = false, chars = {'-'})
  r = r.strip()
  if r.len == 0:
    return "Nothing to add."
  var text = loadSoul(home)
  if text.runeLen > soulMax:
    return "SOUL.md is at its size limit — edit it in the dashboard instead."
  if "## Learned rules" notin text:
    text = text.strip(leading = false) & "\n\n## Learned rules\n"
  text = text.strip(leading = false) & "\n- " & r & "\n"
  writeFile(home / "SOUL.md", text)
  return "Noted, I'll remember to: " & r

proc validSkillText*(text: string): bool =
  ## The `_parse_text` gate: `---` frontmatter with name + description.
  ## Port of the validation in `waku/memory/procedural/loader.py`.
  var m: array[2, string]
  if not match(text, skillFrontRe, m):
    return false
  for line in m[0].splitLines():
    let parts = line.split(":", 1)
    if parts.len == 2 and parts[0].strip().toLowerAscii() == "name" and
        parts[1].strip().strip(chars = {'\'', '"'}).len > 0:
      for line2 in m[0].splitLines():
        let p2 = line2.split(":", 1)
        if p2.len == 2 and p2[0].strip().toLowerAscii() == "description" and
            p2[1].strip().strip(chars = {'\'', '"'}).len > 0:
          return true
  return false

proc createSkill*(home, name, description, body: string,
                  bundledDirs: seq[string] = @[]): string =
  ## Author `<home>/skills/<slug>/SKILL.md`, never overwriting.
  ## Port of `create_skill` minus the live session refresh (see header).
  let slug = name.strip().toLower().replace(" ", "-")
  if not match(slug, slugRe):
    return "Skill name must be a short slug like 'weekly-review' (lowercase, hyphens)."
  let dest = home / "skills" / slug / "SKILL.md"
  if fileExists(dest):
    return "A skill named '" & slug & "' already exists — pick another name."
  for d in bundledDirs:
    if fileExists(d / slug / "SKILL.md"):
      return "A skill named '" & slug & "' already exists — pick another name."
  let text = "---\nname: " & slug & "\ndescription: " & description.strip() &
    "\n---\n\n" & body.strip() & "\n"
  if not validSkillText(text):
    return "That didn't validate — description must be present and non-trivial."
  createDir(parentDir(dest))
  writeFile(dest, text)
  return "Created skill '" & slug & "'. It will trigger on: " & description.strip()

proc makeSaveNoteTool*(db: DbConn): Tool =
  Tool(name: "save_note",
    description: "Save a durable fact to long-term memory. Use when the user tells you something " &
      "worth remembering about themselves, a person, or a project — especially if they " &
      "say 'remember' or share a preference.",
    inputSchema: %*{"type": "object",
      "properties": {
        "subject": {"type": "string", "description": "Who/what this is about, e.g. 'alex' or 'acme-project'"},
        "content": {"type": "string", "description": "The fact, one sentence"}},
      "required": ["subject", "content"]},
    fn: proc(args: JsonNode): string =
      notes.saveNote(db, strArg(args, "subject"), strArg(args, "content")))

proc makeSendMessageTool*(home: string): Tool =
  Tool(name: "send_message",
    description: "Draft a message to someone and place it in the local outbox for the user to " &
      "review and send. Use when the user asks you to message, tell, or remind someone.",
    inputSchema: %*{"type": "object",
      "properties": {
        "to": {"type": "string", "description": "Recipient name or address"},
        "body": {"type": "string", "description": "The message text"}},
      "required": ["to", "body"]},
    fn: proc(args: JsonNode): string =
      messages.sendMessage(home, strArg(args, "to"), strArg(args, "body")))

proc makeManageMemoryTool*(db: DbConn, facts: FactStore,
                           episodes: EpisodeStore): Tool =
  Tool(name: "manage_memory",
    description: "Search, correct, or delete the user's long-term memory (facts and episodes). " &
      "ALWAYS search first to get the id, then update or delete that id. " &
      "Use when the user says something you remember is wrong or should be forgotten.",
    inputSchema: %*{"type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["search", "update", "delete"]},
        "kind": {"type": "string", "enum": ["fact", "episode"], "description": "default fact"},
        "id": {"type": ["integer", "string"],
                 "description": "row id (from a prior search); an opaque " &
                   "string — a number on sqlite, a UUID on a hosted store"},
        "query": {"type": "string", "description": "keywords for search"},
        "content": {"type": "string", "description": "new text for update"},
        "subject": {"type": "string", "description": "optional new subject for a fact update"}},
      "required": ["action"]},
    fn: proc(args: JsonNode): string =
      manageMemory(db, facts, episodes, strArg(args, "action"),
                   strArg(args, "kind", "fact"), rawId(args),
                   strArg(args, "query"), strArg(args, "content"),
                   strArg(args, "subject")))

proc makeUpdateSoulTool*(home: string): Tool =
  Tool(name: "update_soul",
    description: "Save a durable rule about how you should behave for this user (their " &
      "preferences and standing instructions). Appends to your persona; takes " &
      "effect next turn. Use when the user tells you how they want you to act.",
    inputSchema: %*{"type": "object",
      "properties": {
        "rule": {"type": "string", "description": "one behaviour rule, imperative"}},
      "required": ["rule"]},
    fn: proc(args: JsonNode): string =
      updateSoul(home, strArg(args, "rule")))

proc makeCreateSkillTool*(home: string,
                          bundledDirs: seq[string] = @[]): Tool =
  Tool(name: "create_skill",
    description: "Write a new reusable skill (a SKILL.md the agent loads when relevant) so you " &
      "can repeat a workflow the user taught you. Only call this after the user agrees. " &
      "body = step-by-step instructions; description = when to use it (include trigger words).",
    inputSchema: %*{"type": "object",
      "properties": {
        "name": {"type": "string", "description": "short slug, e.g. weekly-review"},
        "description": {"type": "string", "description": "one line: what it does and when to use it"},
        "body": {"type": "string", "description": "the step-by-step instructions (markdown)"}},
      "required": ["name", "description", "body"]},
    fn: proc(args: JsonNode): string =
      createSkill(home, strArg(args, "name"), strArg(args, "description"),
                  strArg(args, "body"), bundledDirs))
