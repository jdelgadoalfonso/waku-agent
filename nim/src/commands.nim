## Slash commands — call a graph workflow by name.
##
## Port of `waku/ops/commands.py`: `/gather` runs the morning gather,
## `/graphs` lists what is available. Two kinds of graph ship in Waku and
## conflating them made the UI say something false: `triage` is a ROUTER
## (runs itself on every message, never pick it) while `gather` is a
## PROCEDURE (a named shape you ask for).
##
## Python discovers runnable workflows by importing `waku.ops.run_<name>`
## for every module in `waku/graph/workflows/`. Nim has no dynamic
## imports, so the table below is explicit — one entry per workflow that
## ships BOTH halves (pure shape + bound runner). The rule is the same:
## a shape the engine can draw but nobody can invoke stays out of the
## table. Summaries are static strings (Nim cannot read a docstring at
## runtime); they quote the binder module's first doc line, and a test
## pins them to the `/graphs` output.
##
## This module stays pure: parsing, describing and composing replies.
## Running (agent, browser, network) lives behind the injected
## `ConnectFn`/`WorkflowFn` seams, wired in `dashboard.runSlashCommand`.

import std/json
import std/strutils

import ./wire

type
  SlashEntry* = object
    ## One runnable workflow: its name, its one-line summary, and whether
    ## it takes the message after the command (`triage` routes one;
    ## `gather` always fetches the same four things).
    name*: string
    summary*: string
    takesMessage*: bool

const
  slashTable* = [
    SlashEntry(name: "gather",
      summary: "`python -m waku gather` — the morning briefing, run as a graph.",
      takesMessage: false),
    SlashEntry(name: "triage",
      summary: "`/triage <message>` — run the router on demand, and watch it choose.",
      takesMessage: true),
  ]
    ## The runnable workflows, in the order `describe` lists them
    ## (Python sorts `discover()` the same way).

  triageUsage* = "`/triage` needs a message to route.\n\n" &
    "Try `/triage thanks!` (takes the quick door) and then " &
    "`/triage what's on my calendar today?` (takes the full door), and compare."
    ## Port of `run_triage`'s empty-message reply, verbatim.

proc parseCommand*(message: string): (bool, string, string) =
  ## `('/gather', 'rest')` / `('graphs', '')` / not-a-command. A leading
  ## slash only counts at the very start and with no space after it, so
  ## a message that merely mentions a path is still a message.
  let text = message.strip()
  if not text.startsWith("/") or text.startsWith("/ "):
    return (false, "", "")
  let rest = text[1 .. ^1]
  let space = rest.find(' ')
  if space < 0:
    return (true, rest.strip().toLowerAscii(), "")
  return (true, rest[0 ..< space].strip().toLowerAscii(),
    rest[space + 1 .. ^1].strip())

proc describeCommands*(): string =
  ## The `/graphs` reply: every runnable workflow with its summary, plus
  ## the router-vs-procedure note, like Python's `describe`.
  var lines = @["**Graph workflows you can run by name**", ""]
  for entry in slashTable:
    lines.add("`/" & entry.name & "` — " & entry.summary)
  lines.add("")
  lines.add("`triage` is the ROUTER — it also runs itself on every " &
    "message when graph workflows are on, so calling it by name just " &
    "lets you watch one message choose a door. The others are " &
    "procedures: they only run when you ask.")
  return lines.join("\n")

proc unknownCommandReply*(name: string): string =
  ## No workflow called `/name`: what exists plus the pointer, like Python.
  var known: seq[string] = @[]
  for entry in slashTable:
    known.add("`/" & entry.name & "`")
  return "No workflow called `/" & name & "`.\n\nAvailable: " &
    known.join(", ") & " · `/graphs` for details."

proc composeWorkflowDone*(state: JsonNode, name: string,
    latencyMs: int): JsonNode =
  ## The terminal `done` payload for a workflow run: the digest (or the
  ## honest nothing), the ignored-argument note, the draft path and the
  ## per-node errors — the same shape Python's `_run_command` emits.
  var reply = state.jget("digest").getStr()
  if reply.len == 0:
    reply = "(the workflow produced no text)"
  let ignored = state.jget("ignored_argument").getStr()
  if ignored.len > 0:
    reply = "`/" & name & "` takes no input, so \u201c" & ignored &
      "\u201d was not used — a fixed shape always fetches the same " &
      "sources. Ask a normal question to use the loop instead.\n\n" & reply
  let draft = state.jget("draft_path").getStr()
  if draft.len > 0:
    reply &= "\n\n*saved to `" & draft & "`*"
  let errors = state.jget("errors")
  if errors.kind == JObject:
    for node, err in pairs(errors):
      reply &= "\n\n*" & node & ": " & err.getStr() & "*"
  result = %*{"reply": reply, "tools": newJArray(), "gate": newJNull(),
              "consolidation": newJNull(), "iterations": 0,
              "latency_ms": latencyMs, "workflow": name}
