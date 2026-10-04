## Session — port of `waku/runtime/session.py`: ephemeral working memory.
##
## The inner box on the whiteboard: everything here is rebuilt per run and
## thrown away. What persists lives in `memory.nim` (state.db). Working
## memory = system prompt (SOUL.md) + gated facts/episodes + chat history +
## the user's new message.
##
## TWO DIVERGENCES FROM PYTHON, both mechanical:
##
## - Python's `Memory` object arrives whole (`gated_retrieve`,
##   `matching_skills`, `log_chat`, `session_history`); Nim splits it: the
##   chat-log half is the `db` handle (`logChat`/`sessionHistory` in
##   memory.nim), the retrieval half rides as two nil-able `RetrieveFn`
##   seams. A nil `db` means memory is not wired (same as Python's
##   `memory=None`); `wireMemory` (memory_live.nim) fills the seams for
##   every agent the builders create, while tests keep building unwired
##   agents straight from `newSession`.
## - The clock line keeps Python's words but drops the `%Z` zone name:
##   `std/times` exposes the UTC offset portably, not the abbreviation, so
##   the line reads `(... (UTC+0200))` instead of `(CEST, UTC+0200)`. The
##   weekday is also always English (`dddd`): Python's `%A` follows the
##   process locale ("martes" under es-ES). Prompt text only — nothing
##   downstream parses it.
##
## `DEFAULT_SOUL` is verbatim Python: it names tools (`create_event`,
## `manage_memory`, `update_soul`, `create_skill`...) that later phases port;
## until then the registry answers "unknown tool", honestly documented.

import std/os
import std/strutils
import std/times

import db_connector/db_sqlite

import ./config
import ./loop
import ./memory

export config
export loop

const
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

type
  RetrieveFn* = proc(userMessage: string, notify: Observer): string {.closure.}
    ## `gated_retrieve` / `matching_skills` seam: "" means "nothing
    ## relevant". Nil until the retrieval layer lands. The observer rides
    ## along exactly like Python's `gated_retrieve(msg, notify=notify)`.

  ToolCall* = tuple[tool: string, args: string, output: string]
    ## One executed tool call. Python renders the args dict with str();
    ## the caller passes the already-rendered string here.

  Turn* = tuple[role: string, content: string]
    ## One history row (Python's `{"role": ..., "content": ...}` dict).

  Session* = object
    settings*: Settings
    db*: DbConn          ## nil until memory is wired (Python: memory=None)
    retrieve*: RetrieveFn
    skillsFor*: RetrieveFn
    sessionId*: string
    history*: seq[Turn]

proc loadSoul*(home: string): string =
  ## The editable persona file, created on first run and never overwritten:
  ## changing it changes who your Waku is. Port of `load_soul`.
  let soulPath = home / "SOUL.md"
  if not fileExists(soulPath):
    createDir(home)
    writeFile(soulPath, defaultSoul)
  readFile(soulPath)

proc newSession*(settings: Settings, sessionId = "default",
                 db: DbConn = nil, retrieve: RetrieveFn = nil,
                 skillsFor: RetrieveFn = nil): Session =
  ## One Session per gateway connection: chat history plus the recipe for
  ## the system prompt.
  Session(settings: settings, db: db, retrieve: retrieve,
          skillsFor: skillsFor, sessionId: sessionId, history: @[])

proc clockLine*(): string =
  ## `Right now it is Tuesday, 2026-09-29 21:38 (UTC+0200).` — the laptop's
  ## local clock, enough to resolve "in 30 minutes". See the module docs
  ## for the dropped `%Z` zone name.
  let t = now()
  let off = t.utcOffset
  let sign = if off < 0: "-" else: "+"
  let absOff = abs(off)
  let hhmm = sign & align($(absOff div 3600), 2, '0') &
    align($((absOff mod 3600) div 60), 2, '0')
  "Right now it is " & format(t, "dddd, yyyy-MM-dd HH:mm") &
    " (UTC" & hhmm & ")."

proc buildSystem*(s: Session, userMessage: string,
                   notify: Observer = nil): string =
  ## Assemble the system prompt: SOUL + clock + model line, then the gated
  ## memory and skill seams when they answer. Pure (only SOUL.md is read).
  var parts: seq[string] = @[loadSoul(s.settings.home), "\n" & clockLine(),
    "Your model: you are running on '" & s.settings.model & "' via the '" &
    s.settings.provider & "' provider, inside Waku, a local-first " &
    "open-source agent harness (github.com/ShenSeanChen/waku-agent)."]
  if not s.retrieve.isNil:
    let retrieved = s.retrieve(userMessage, notify)
    if retrieved.len > 0:
      parts.add("\nRelevant memory:\n" & retrieved)
  if not s.skillsFor.isNil:
    let skills = s.skillsFor(userMessage, notify)
    if skills.len > 0:
      parts.add("\nRelevant skill instructions:\n" & skills)
  parts.join("\n")

proc foldToolCalls*(reply: string, toolCalls: seq[ToolCall]): string =
  ## Fold tool activity into the assistant's history entry as one compact
  ## `[tools used: ...]` line. Without it the model forgets it already
  ## acted and happily re-runs the same tool next turn (the
  ## triple-booked-meeting bug from the first live test).
  if toolCalls.len == 0:
    return reply
  var items: seq[string] = @[]
  for c in toolCalls:
    items.add(c.tool & "(" & c.args & ") -> " & c.output)
  reply & "\n[tools used: " & items.join("; ") & "]"

proc addExchange*(s: var Session, userMessage, reply: string,
                  toolCalls: seq[ToolCall] = @[], source = "cli",
                  meta = "") =
  ## Record the turn in working memory and, when memory is wired, in the
  ## chat log (so consolidation can distill it later).
  let record = foldToolCalls(reply, toolCalls)
  s.history.add((role: "user", content: userMessage))
  s.history.add((role: "assistant", content: record))
  if not s.db.isNil:
    s.db.logChat(userMessage, record, s.sessionId, source, meta)

proc startNew*(s: var Session, sessionId: string) =
  ## A session is just a tag on chat_log rows: starting a new one clears
  ## working memory.
  s.sessionId = sessionId
  s.history = @[]

proc switch*(s: var Session, sessionId: string) =
  ## Reload a past conversation's recent tail into working memory.
  ## Consolidation still reads ALL unconsolidated rows regardless.
  ## `history_turns = 0` takes the whole thread: Python's `list[-0:]` is
  ## `list[0:]`, and this keeps that quirk instead of inventing a new one.
  s.sessionId = sessionId
  s.history = @[]
  if s.db.isNil:
    return
  var pairs = s.db.sessionHistory(sessionId)
  let turns = s.settings.historyTurns
  if turns > 0 and pairs.len > turns:
    pairs = pairs[pairs.len - turns .. ^1]
  for p in pairs:
    s.history.add((role: "user", content: p.user))
    s.history.add((role: "assistant", content: p.reply))
