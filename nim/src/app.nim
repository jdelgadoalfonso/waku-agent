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
## The receipt (spec 011 S4) follows Python's `_receipt` in ORDER — persist,
## consolidate, build, meta, trace event, end turn — with four differences
## the builder's own header already owns: no `used` count (`memory.used`
## stays 0; nothing carries one), no hosted `charges` (`credits` stays
## null), `last_insert_rowid()` instead of the row id `add_exchange`
## returns, and no `log.exception` on a failed receipt (this build has no
## logger seam; the turn survives instead). `default_model` is likewise
## absent: `buildReceipt` prices a model-less event at the provider
## estimate, exactly as its unit 2 pinned.
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

import ./brain
import ./config
import ./episodes
import ./factstore
import ./langmem
import ./mem0
import ./mcp
import ./obsidian
import ./pgvector
import ./zep
import ./jsondump
import ./loop
import ./memory
import ./receipt
import ./reports
import ./session
import ./tools
import ./trace
import ./trim
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
    facts*: FactStore
      ## Where the facts live — sqlite by default, whichever backend
      ## `WAKU_SEMANTIC_STORE` names otherwise. Every read and write of a
      ## FACT goes through this, never through `db`. Holding it here is what
      ## keeps one client (and therefore one pending `settle` event) per
      ## agent instead of one per registry.
    episodes*: EpisodeStore
      ## Where the episodes live — sqlite by default, the Obsidian vault
      ## when `WAKU_EPISODIC_STORE` names it. Every read and write of an
      ## EPISODE goes through this, never through `db`.
    client*: LlmClient
    tools*: ToolRegistry
    session*: Session
    tracer*: Tracer
    graphTurn*: GraphTurn
    afterTurn*: AfterTurn
    reportCell*: ref string
      ## The research report THIS turn saved (spec 009 B), as a cell:
      ## `respond` writes it and the consolidation seam (a closure over a
      ## `var Waku`, which cannot capture the agent itself) reads it. Empty
      ## every other turn.
    savedCell*: ref string
      ## The save_note facts THIS turn saved (spec 018), as
      ## "subject: content" lines: `respond` writes them and the
      ## consolidation seam reads them alongside the gate's text, so
      ## a fact the turn just saved is memory the turn handled,
      ## not a finding to extract again from the chat row.

type
  StoreChoice* = tuple[store: FactStore, name: string]
    ## The store AND which backend it is. The name is not part of the contract
    ## (a store cannot be asked what it is) but assembly needs to answer it:
    ## the status line says where the facts live, a test pins the selector,
    ## and `WAKU_SEMANTIC_STORE=mem0` with no key has to be able to say it
    ## fell back rather than answering a search that quietly came from
    ## another backend.

proc factStoreFor*(settings: Settings, db: DbConn): StoreChoice =
  ## Which backend holds the facts, from `WAKU_SEMANTIC_STORE`. The port of
  ## `_make_fact_store` in `waku/memory/__init__.py`: an unknown value
  ## answers with sqlite rather than refusing, which is what Python does and
  ## what keeps a typo from taking a turn down.
  ##
  ## `MEM0_API_KEY` / `ZEP_API_KEY` are read here, not from `Settings`,
  ## because that is what Python's adapters do: the keys belong to the
  ## connections registry, not to the settings dataclass. `DATABASE_URL` and
  ## `OPENAI_API_KEY` follow the same rule for the `postgres` backend — a
  ## database address is a secret, not a setting. `OPENAI_API_KEY` likewise
  ## gates `langmem` (embeddings are billed), whose `WAKU_LANGMEM_POSTGRES`
  ## switches memory mode to its Postgres twin. No key means no hosted
  ## client — the loop then answers from sqlite and says nothing, because a
  ## half-wired remote store is worse than a local one.
  case settings.semanticStore
  of "mem0":
    let key = envOrDefault("MEM0_API_KEY", "")
    if key.len > 0:
      let client = newMem0Client(key, settings.mem0UserId,
                                 topK = settings.retrievalTopK)
      return (store: mem0FactStore(client), name: "mem0")
    stderr.writeLine("(memory) WAKU_SEMANTIC_STORE=mem0 but MEM0_API_KEY is " &
      "empty — falling back to sqlite, which will not show those memories.")
  of "zep":
    let key = envOrDefault("ZEP_API_KEY", "")
    if key.len > 0:
      let client = newZepClient(key, settings.zepUserId,
                                topK = settings.retrievalTopK)
      return (store: zepFactStore(client), name: "zep")
    stderr.writeLine("(memory) WAKU_SEMANTIC_STORE=zep but ZEP_API_KEY is " &
      "empty — falling back to sqlite, which will not show those memories.")
  of "postgres":
    let url = envOrDefault("DATABASE_URL", "")
    let key = envOrDefault("OPENAI_API_KEY", "")
    if url.len > 0 and key.len > 0:
      let client = newPgClient(url, key, topK = settings.retrievalTopK,
        embedModel = envOrDefault("OPENAI_EMBED_MODEL",
                                  "text-embedding-3-small"))
      return (store: pgFactStore(client), name: "postgres")
    stderr.writeLine("(memory) WAKU_SEMANTIC_STORE=postgres but DATABASE_URL " &
      "or OPENAI_API_KEY is empty — falling back to sqlite, which will " &
      "not show those memories.")
  of "langmem":
    let key = envOrDefault("OPENAI_API_KEY", "")
    if key.len > 0:
      let dsn = envOrDefault("WAKU_LANGMEM_POSTGRES", "")
      let client = newLangMemClient(key, topK = settings.retrievalTopK,
        embedModel = envOrDefault("OPENAI_EMBED_MODEL",
                                  "openai:text-embedding-3-small"),
        pgDsn = dsn)
      if dsn.len > 0:
        return (store: langmemFactStore(client), name: "langmem-pg")
      return (store: langmemFactStore(client), name: "langmem")
    stderr.writeLine("(memory) WAKU_SEMANTIC_STORE=langmem but OPENAI_API_KEY " &
      "is empty — falling back to sqlite, which will not show those memories.")
  else: discard
  (store: sqliteFactStore(db), name: "sqlite")

type
  EpisodeChoice* = tuple[store: EpisodeStore, name: string]
    ## The episode store AND which backend it is — the episodic twin of
    ## `StoreChoice`, for the same reason: the status line says where the
    ## episodes live, a test pins the selector, and a named-but-unconfigured
    ## backend has to be able to say it fell back.

proc episodeStoreFor*(settings: Settings, db: DbConn): EpisodeChoice =
  ## Which backend holds the episodes, from `WAKU_EPISODIC_STORE`. `obsidian`
  ## needs `WAKU_OBSIDIAN_VAULT`; without it, sqlite answers with a line on
  ## stderr. `notion` is Python-only: it falls back the same way here, and
  ## the dashboard keeps its explicit error for the action itself — S3
  ## replaces Notion with Obsidian in this port, it does not resurrect it.
  case settings.episodicStore
  of "obsidian":
    if settings.obsidianVault.len > 0:
      return (store: obsidianEpisodeStore(
        newObsidianStore(settings.obsidianVault)), name: "obsidian")
    stderr.writeLine("(memory) WAKU_EPISODIC_STORE=obsidian but " &
      "WAKU_OBSIDIAN_VAULT is empty — falling back to sqlite, whose " &
      "episodes live in state.db instead of your vault.")
  of "notion":
    stderr.writeLine("(memory) WAKU_EPISODIC_STORE=notion is not supported " &
      "in the Nim port (Obsidian took its place) — falling back to sqlite.")
  else: discard
  (store: sqliteEpisodeStore(db), name: "sqlite")

proc newWaku*(settings: Settings, client: LlmClient, db: DbConn = nil,
              tools = ToolRegistry(), graphTurn: GraphTurn = nil,
              afterTurn: AfterTurn = nil): Waku =
  ## Memory first (the memory-management tools need it), then the registry,
  ## the session, the tracer — the same order as Python's `__init__`.
  result.settings = settings
  result.db = db
  result.client = client
  result.tools = tools
  result.facts = factStoreFor(settings, db).store
  result.episodes = episodeStoreFor(settings, db).store
  result.session = newSession(settings, db = db)
  result.tracer = newTracer(settings.home, settings.provider, settings.model,
                           settings.otelEndpoint)
  new(result.reportCell)
  result.reportCell[] = ""
  new(result.savedCell)
  result.savedCell[] = ""
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

proc lastChatRowId(db: DbConn): int64 =
  ## The row `logChat` just wrote — SQLite's own answer. Python's
  ## `add_exchange` returns its row id and `logChat` here returns nothing
  ## (left alone by the receipt unit), so the turn asks the connection,
  ## which is why this must be read before anything else inserts.
  for row in db.getAllRows(sql"SELECT last_insert_rowid()"):
    return row[0].parseBiggestInt()

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
  var system = w.session.buildSystem(userMessage, notify)
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
  # Spec 009 A: research starts from what the company brain already
  # knows. The searches run here, before the model's first call, and
  # are shown as tool calls; a failed search is skipped, never fatal.
  # `brainBackendFor` reads the already-connected registry, so without
  # a memory server (or without the skill) this whole block is a no-op.
  var knownCalls: seq[JsonNode] = @[]
  var knownUsed: seq[JsonNode] = @[]
  var backend = brainBackendFor(w.tools)
  backend.digest = proc(body: string): string = reports.digest(body)
  if brainConnected(backend) and not w.session.researchNames.isNil and
      isResearch(w.session.researchNames(userMessage)):
    let known = readFirst(userMessage, backend)
    knownCalls = known.calls
    knownUsed = known.used
    for call in known.calls:
      notify("tool", call)
    if known.context.len > 0:
      system = system & "\n" & known.context
  # The per-turn filter signal (mcp-per-turn-filter §4.2): the
  # message decides which task-tagged MCP tools this turn's model
  # call sees. The declarations are read from mcp.json itself —
  # like the dashboard's and the trace's server names — because
  # they describe intent even for a server that did not connect
  # this run. No match, or no readable file, is an empty signal:
  # the full set (allow-by-default, §4.4).
  var mcpSpecs: seq[McpServerSpec] = @[]
  try:
    mcpSpecs = loadMcpServers(w.settings.home)
  except ValueError:
    discard
  let taskTags = deriveTaskTags(userMessage, mcpSpecs)
  var res = runLoop(w.client, w.settings.model, system, messages, w.tools,
          w.settings.maxIterations, w.settings.maxTokens, notify, stream,
          chainTrim(toTrim(shrinkRead), toTrim(shrinkSeen)), taskTags)
  res.readFirst = knownCalls
  res.used = knownUsed
  return res

proc respond*(w: var Waku, userMessage: string, observer: Observer = nil,
              source = "cli", stream = false): LoopResult =
  ## One full turn: working memory → loop (or graph) → persist. Everything
  ## that happens is both shown (observer) and recorded (tracer).
  var captured = newJObject()
  # Spec 011: the events a receipt is built from, in the order they came —
  # the same list Python's `_capture` keeps, alongside the telemetry below
  # (this extends the capture, it does not replace it). `copy` because the
  # observer chain keeps handing the same nodes around.
  var turnEvents: seq[tuple[kind: string, ev: JsonNode]] = @[]
  proc capture(kind: string, ev: JsonNode) =
    if kind == "llm" or kind == "tool" or kind == "consolidation" or
        kind == "report":
      turnEvents.add((kind, copy(ev)))
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

  # Spec 007: a reply holding a research report saves it whole to memory
  # and keeps only its first sentences in the chat. No backend, or a
  # failed send, leaves the reply whole and emits nothing.
  if not w.reportCell.isNil:
    w.reportCell[] = ""
  var reportEvent = newJNull()
  var report: Report
  if findReport(res.reply, report):
    # The client and model are read out of `w` before the closure: a
    # `var Waku` cannot be captured, and the classifier only needs these.
    let reportClient = w.client
    let reportModel = w.settings.smallModel
    let saved = saveReport(res.reply, saveBackendFor(w.tools),
      proc(one: Report): bool =
        isCompanyResearch(reportClient, reportModel, one, notify))
    if saved.event.kind == JObject:
      res.reply = saved.reply
      reportEvent = saved.event
      if not w.reportCell.isNil:
        w.reportCell[] = report.body
      notify("report", saved.event)

  let quick = captured.jget("graph_route").jget("target").getStr() ==
    "quick_reply"
  var metaTools = newJArray()
  for c in res.toolCalls:
    metaTools.add(%*{"tool": c.jget("tool").getStr(),
                     "status": statusOf(c.jget("output").getStr())})
  var metaUsed = newJArray()
  for u in res.used:
    metaUsed.add(copy(u))
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
    "used": metaUsed,
    "report": reportEvent,
    # which brain answered — a reopened thread (or a mid-thread model
    # switch) shows it per card. A quick graph turn ran the small model;
    # say so honestly.
    "model": (if quick: %w.settings.smallModel else: %w.settings.model),
    "provider": w.settings.provider,
  }
  w.session.addExchange(userMessage, res.reply, toToolCalls(res.toolCalls),
                        source, jsonDumps(meta))
  # The assistant row `addExchange` just stored — read BEFORE `afterTurn`:
  # a due consolidation inserts fact rows on this same connection, which
  # would move `last_insert_rowid()` off the chat row. (-1: no db wired.)
  let chatRow = if w.db.isNil: -1 else: lastChatRowId(w.db)
  # Spec 018: a fact save_note saved is memory this turn
  # handled, so consolidation must not extract the same
  # sentence from the chat row again. Filled every turn —
  # an empty overwrite is what keeps a stale save from
  # leaking into a later turn's consolidation.
  if not w.savedCell.isNil:
    var saved: seq[string] = @[]
    for c in res.toolCalls:
      if c.jget("tool").getStr() == "save_note":
        saved.add(c.jget("args").jget("subject").getStr() & ": " &
                  c.jget("args").jget("content").getStr())
    w.savedCell[] = saved.join("\n")
  if not w.afterTurn.isNil:
    w.afterTurn(notify)
  # Spec 011 (the oracle's order): the receipt is built ONCE, after
  # consolidation has kept what it keeps — its `consolidation` event
  # carries `new_facts`, and it reads the chat log this turn just wrote.
  #
  # The three values `buildReceipt` deliberately leaves neutral are filled
  # HERE, by the turn that owns them: `turn_id` is still set (`endTurn` has
  # not run yet), and `model.id` is the brain this turn's meta already
  # named (a quick graph turn ran the small model, as the meta says).
  # `memory.used` stays 0 on purpose: `session.retrieve` hands the prompt
  # JOINED TEXT, so no count of retrieved facts crosses any seam, and
  # inventing one would be a lie (see `receipt.nim`'s header).
  #
  # A receipt that raises must NEVER fail the turn: the reply is already
  # stored and the tracer closes the turn either way, so the worst case is
  # a turn with no receipt line under it. Caught and skipped here — Python
  # logs the exception, and this build has no logger seam.
  try:
    let turnId = w.tracer.turnId
    # `rec`, not `receipt`: the module name stays readable in this scope.
    var rec = buildReceipt(turnEvents, w.settings.provider)
    rec["turn_id"] = %turnId
    rec["model"]["id"] = %meta.jget("model").getStr()
    res.receipt = rec
    meta["turn_id"] = %turnId
    meta["receipt"] = copy(rec)
    if chatRow >= 0:
      w.db.updateChatMeta(chatRow, jsonDumps(meta))
    w.tracer.event("receipt", rec)
  except CatchableError:
    discard  # the answer is the product; the receipt is one line under it
  w.tracer.endTurn(res.reply, res.iterations)
  return res
