## App — port of `waku/app.py`: one Waku from its parts, one turn per call.
##
## The assembly diagram in code: settings → db → tools → session → loop,
## with the tracer watching everything. Gateways call `respond()`.
##
## THREE DIVERGENCES FROM PYTHON, all seams the phase plan already owns:
##
## - Python builds its own client (`get_client(settings)`) and tool wiring
##   (`build_registry`) inside `__init__`; Nim takes both injected (same
##   seam Python's evals use for `client`/`conn`, generalized). Implicit
##   network construction (settings → transport) arrives with the
##   integrations phase; the default registry stays empty until the
##   remaining tools land — a Waku that pretends to be wired would be
##   worse than one that says it isn't.
## - The triage graph itself is 4d. `graphTurn` is its seam: nil means the
##   flag path is off; a set seam answers `(answered, result)` and any
##   exception still fails open to the plain loop, exactly like Python.
## - `maybe_consolidate` / `export_markdown` live in memory_live.nim.
##   The `afterTurn` hook is their seam (nil = skip; `wireMemory` sets
##   it); persistence itself (`add_exchange` → chat_log) happens every
##   turn, like Python.
##
## What 4c DOES fix canonically (verifier note 8 from 4b): the turn `meta`
## renders with `jsonDumps` (`json.dumps`-shaped, `{"iterations": 1}` with
## the space), because the dashboard reads meta for the turn card. And the
## `[tools used: ...]` fold renders args with `pyStr` (Python `str()` of
## the input dict); that line is prompt text, so parity is semantic.
## - `graph_end` on a graph failure carries `errorText` (`"Type: msg"`,
##   the port's established convention) instead of Python's `repr(exc)`
##   (`"ValueError('boom')"`); same turn card, different punctuation.
## - A missing `triage` event renders `reason` as `""` (Python's
##   `captured.get("triage_reason", "")`), never null — the dashboard
##   reads a string.

import std/json
import std/monotimes
import std/strutils
import std/times

import db_connector/db_sqlite

import ./config
import ./jsondump
import ./loop
import ./session
import ./tools
import ./trace
import ./wire

export config
export loop
export tools

type
  GraphTurn* = proc(userMessage: string, notify: Observer,
                    stream: bool): tuple[answered: bool,
                                         res: LoopResult] {.closure.}
    ## One turn through the triage graph (4d plugs it in). `answered=false`
    ## means "the graph produced nothing" → the caller falls open to the
    ## plain loop, so this path can only ever ADD speed, never lose a reply.

  AfterTurn* = proc(notify: Observer) {.closure.}
    ## Consolidation + MEMORY.md sync (`wireMemory` sets it).

  Waku* = object
    settings*: Settings
    db*: DbConn
    client*: LlmClient
    tools*: ToolRegistry
    session*: Session
    tracer*: Tracer
    graphTurn*: GraphTurn
    afterTurn*: AfterTurn

proc newWaku*(settings: Settings, client: LlmClient, db: DbConn = nil,
              tools = ToolRegistry(), graphTurn: GraphTurn = nil,
              afterTurn: AfterTurn = nil): Waku =
  ## Memory first (the memory-management tools need it), then the registry,
  ## the session, the tracer — the same order as Python's `__init__`.
  result.settings = settings
  result.db = db
  result.client = client
  result.tools = tools
  result.session = newSession(settings, db = db)
  result.tracer = newTracer(settings.home, settings.provider, settings.model)
  result.graphTurn = graphTurn
  result.afterTurn = afterTurn

proc statusOf*(output: string): string =
  ## `"error"` when the tool output reads like a failure, else `"ok"` —
  ## verbatim Python (the turn card's red/green dot).
  let low = output.toLowerAscii()
  if "failed" in low or "timed out" in low or low.startsWith("error"):
    "error"
  else:
    "ok"

proc toToolCalls*(calls: seq[JsonNode]): seq[ToolCall] =
  ## The loop's `{tool, args, output}` events into session fold entries.
  ## `args` renders Python-style (`pyStr`); a missing key reads `None`,
  ## like `c["args"]` on a thin dict.
  for c in calls:
    result.add((tool: c.jget("tool").getStr(),
                args: pyStr(c.jget("args")),
                output: c.jget("output").getStr()))

proc runFullTurn*(w: var Waku, userMessage: string, notify: Observer,
                  stream: bool): LoopResult =
  ## The classic turn: assemble working memory, run THE loop. The graph's
  ## `full_agent` node (4d) calls THIS, so loop-as-a-node can never drift
  ## from loop-as-default.
  let system = w.session.buildSystem(userMessage, notify)
  # A bounded window: only the last N turns (2 rows each) enter the
  # prompt, so context/cost/latency stay flat no matter how long the
  # thread runs. `history_turns = 0` takes the whole thread — Python's
  # `history[-0:]` is `history[0:]`, same quirk as `switch`.
  let window = w.settings.historyTurns * 2
  let hist = w.session.history
  var messages: seq[JsonNode] = @[]
  let tail = if window > 0 and hist.len > window:
    hist[hist.len - window .. ^1] else: hist
  for t in tail:
    messages.add(%*{"role": t.role, "content": t.content})
  messages.add(%*{"role": "user", "content": userMessage})
  runLoop(w.client, w.settings.model, system, messages, w.tools,
          w.settings.maxIterations, w.settings.maxTokens, notify, stream)

proc respond*(w: var Waku, userMessage: string, observer: Observer = nil,
              source = "cli", stream = false): LoopResult =
  ## One full turn: working memory → loop (or graph) → persist. Everything
  ## that happens is both shown (observer) and recorded (tracer).
  var captured = newJObject()
  proc capture(kind: string, ev: JsonNode) =
    if kind == "gate":
      captured["gate"] = %*{"decision": ev.jget("decision"),
                            "reason": ev.jget("reason")}
    elif kind == "route":
      captured["graph_route"] = %*{"target": ev.jget("target"),
                                   "reason": ev.jget("reason")}
    elif kind == "triage":
      captured["triage_reason"] = ev.jget("reason")
    elif kind == "graph_end":
      captured["graph_path"] = copy(ev.jget("path"))
  let notify = compose(observer, w.tracer.tracerEvent(), capture)
  let t0 = getMonoTime()
  w.tracer.turn(userMessage)

  # The graph front door is optional and can NEVER make Waku worse:
  # seam unset → exactly the old code path; set → the triage graph
  # decides quick vs full, and any failure anywhere falls open to the
  # plain loop below (same fail-open rule as the retrieval gate).
  var res: LoopResult
  var answered = false
  if w.settings.graphWorkflows and not w.graphTurn.isNil:
    try:
      (answered, res) = w.graphTurn(userMessage, notify, stream)
    except CatchableError as exc:
      notify("graph_end", %*{"workflow": "triage", "ms": 0, "steps": 0,
                             "path": newJArray(),
                             "error": errorText(exc)})
      answered = false
  if not answered:
    res = w.runFullTurn(userMessage, notify, stream)

  let quick = captured.jget("graph_route").jget("target").getStr() ==
    "quick_reply"
  var metaTools = newJArray()
  for c in res.toolCalls:
    metaTools.add(%*{"tool": c.jget("tool").getStr(),
                     "status": statusOf(c.jget("output").getStr())})
  let meta = %*{
    "gate": captured.jget("gate"),
    "graph": (if captured.hasKey("graph_route"):
      %*{"workflow": "triage",
         "route": (if quick: %"quick" else: %"full"),
         "reason": (if captured.hasKey("triage_reason"):
                        captured["triage_reason"] else: %""),
         "path": captured.jget("graph_path")}
    else: newJNull()),
    "iterations": res.iterations,
    "latency_ms": int((getMonoTime() - t0).inMilliseconds),
    "tools": metaTools,
    # which brain answered — a reopened thread (or a mid-thread model
    # switch) shows it per card. A quick graph turn ran the small model;
    # say so honestly.
    "model": (if quick: %w.settings.smallModel else: %w.settings.model),
    "provider": w.settings.provider,
  }
  w.session.addExchange(userMessage, res.reply, toToolCalls(res.toolCalls),
                        source, jsonDumps(meta))
  if not w.afterTurn.isNil:
    w.afterTurn(notify)
  w.tracer.endTurn(res.reply, res.iterations)
  return res
