## CLI gateway — port of `waku/gateway/cli.py`: talk to your Waku.
##
## A gateway only moves text in and out; everything interesting happens in
## the loop. (The Telegram gateway is the same shape with polling instead
## of `readLine`.) Output is plain text: Python renders with rich
## (panels, colors); the port refuses that dependency, so the banner,
## snapshot box and live lines are undecorated but carry the same words.
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

proc liveObserver*(kind: string, ev: JsonNode) =
  ## Show the loop's internals live — the transparent-harness beat.
  ## `args` renders Python-style (`pyStr`); tool output is trimmed to 80
  ## columns so a verbose tool cannot flood the terminal.
  if kind == "tool":
    let output = ev.jget("output").getStr()
    echo "  tool · " & ev.jget("tool").getStr() & "(" &
      pyStr(ev.jget("args")) & ") → " & output[0 ..< min(80, output.len)]
  elif kind == "gate":
    echo "  gate · " & ev.jget("decision").getStr() & " — " &
      ev.jget("reason").getStr()
  elif kind == "consolidation":
    echo "  memory · consolidated " & $ev.jget("new_facts").getInt(0) &
      " fact(s) from recent chats"

proc runRepl*(w: var Waku) =
  ## The chat loop: read, respond, print. `/memory` shows the snapshot,
  ## `/quit` (or Ctrl-D) leaves. Memory stays in state.db either way.
  w.session.sessionId = "terminal"  # its own thread in the inbox
  echo "Waku — local, yours, transparent."
  echo "home: " & absolutePath(w.settings.home) &
    "   model: " & w.settings.model
  echo "Commands: /memory · /quit"
  setControlCHook(onCtrlC)
  while not replStop:
    stdout.write("you › ")
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
      echo memorySnapshot(w.db)
      continue
    let res = w.respond(userMessage, observer = liveObserver, source = "cli")
    echo "waku › " & res.reply & "\n"
  echo "bye — your memory stays in state.db"
