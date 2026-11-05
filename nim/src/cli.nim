## CLI gateway — port of `waku/gateway/cli.py`: talk to your Waku.
##
## A gateway only moves text in and out; everything interesting happens in
## the loop. (The Telegram gateway is the same shape with polling instead
## of `readLine`.) Python decorates this surface with rich; the default
## build prints the same words in plain text. A `-d:wakuStyle` build
## routes the same surfaces through `style.Renderer` and the vendored
## terminal_style, so the optional build carries the decoration without
## adding a default dependency.
##
## `memorySnapshot` is pure (a bounded, read-only view over the local
## memory); the REPL owns the session thread `"terminal"`, like Python.

import std/json
import std/os
import std/strutils
import std/syncio

import db_connector/db_sqlite

import ./app
import ./jsondump
import ./style
import ./wire

export app

var replStop = false

proc onCtrlC() {.noconv.} =
  ## Ctrl-C breaks the loop instead of killing the process mid-line, so
  ## the bye line still prints (Python catches KeyboardInterrupt the
  ## same way). Signal-safe: a single boolean store.

proc memorySnapshot*(db: DbConn): string =
  ## Render a bounded, read-only view of Waku's local memory.
  let factCount = db.getValue(sql"SELECT COUNT(*) FROM facts")
  var lines = @["Semantic facts (" & factCount & ")"]
  var facts = 0
  for row in db.getAllRows(
      sql"SELECT subject, content FROM facts ORDER BY id DESC LIMIT 8"):
    lines.add("- [" & row[0] & "] " & row[1])
    inc facts
  if facts == 0:
    lines.add("- none yet")
  let episodeCount = db.getValue(sql"SELECT COUNT(*) FROM episodes")
  lines.add("")
  lines.add("Recent episodes (" & episodeCount & ")")
  var episodes = 0
  for row in db.getAllRows(sql("SELECT happened_at, summary FROM episodes " &
      "ORDER BY happened_at DESC, id DESC LIMIT 5")):
    lines.add("- " & row[0] & " - " & row[1])
    inc episodes
  if episodes == 0:
    lines.add("- none yet")
  lines.add("")
  let pending = db.getValue(
    sql"SELECT COUNT(*) FROM chat_log WHERE consolidated = 0")
  lines.add("Unconsolidated chat messages: " & pending)
  return lines.join("\n")

proc observerLine*(r: Renderer, kind: string, ev: JsonNode): string =
  ## One live line, styled by `r`. `args` renders Python-style
  ## (`pyStr`); tool output is trimmed to 80 columns so a verbose
  ## tool cannot flood the terminal.
  if kind == "tool":
    let output = ev.jget("output").getStr()
    r.dim("  tool · " & ev.jget("tool").getStr() & "(" &
      pyStr(ev.jget("args")) & ") → " & output[0 ..< min(80, output.len)])
  elif kind == "gate":
    r.dim("  gate · " & ev.jget("decision").getStr() & " — " &
      ev.jget("reason").getStr())
  elif kind == "consolidation":
    r.dim("  memory · consolidated " & $ev.jget("new_facts").getInt(0) &
      " fact(s) from recent chats")
  else:
    ""

proc liveObserver*(kind: string, ev: JsonNode) =
  ## The plain observer every existing caller keeps getting.
  let line = observerLine(plainRenderer(), kind, ev)
  if line.len > 0:
    echo line

proc makeLiveObserver*(r: Renderer): Observer =
  ## The same live lines, through a renderer.
  proc observe(kind: string, ev: JsonNode) =
    let line = observerLine(r, kind, ev)
    if line.len > 0:
      echo line
  observe

proc runRepl*(w: var Waku, renderer: Renderer = plainRenderer(),
              graphReselect: proc(w: var Waku) {.closure.} = nil) =
  ## The chat loop: read, respond, print. `/memory` shows the snapshot,
  ## `/quit` (or Ctrl-D) leaves. Memory stays in state.db either way.
  ## The renderer is a parameter so tests can pin the plain output.
  ##
  ## `graphReselect` is the per-turn graph hook, called just before each
  ## `respond` so the turn's graph is the one the selector names NOW (the
  ## browser's `liveChatStreamFn` does the same with source "dashboard").
  ## Nil keeps the startup seam `buildCliApp` bound — the hook can only
  ## ever re-bind it, never leave the loop without one.
  w.session.sessionId = "terminal"  # its own thread in the inbox
  echo renderer.panel("", renderer.bold("Waku — local, yours, transparent.") &
    "\n" & "home: " & absolutePath(w.settings.home) &
    "   model: " & w.settings.model & "\n" & "Commands: /memory · /quit")
  setControlCHook(onCtrlC)
  let observer = makeLiveObserver(renderer)
  while not replStop:
    stdout.write(renderer.prompt("you › "))
    flushFile(stdout)
    var userMessage = ""
    try:
      userMessage = stdin.readLine().strip()
    except EOFError:
      break
    if userMessage.len == 0:
      continue
    if userMessage == "/quit" or userMessage == "/exit":
      break
    if userMessage == "/memory":
      echo renderer.panel("Memory snapshot", memorySnapshot(w.db))
      continue
    if not graphReselect.isNil:
      graphReselect(w)
    let res = w.respond(userMessage, observer = observer, source = "cli")
    echo renderer.boldGreen("waku › ") & res.reply & "\n"
  echo renderer.dim("bye — your memory stays in state.db")
