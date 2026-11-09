## Worker plugin — T2: a graph plugin as a headless worker turn.
##
## Pure turn logic for `waku --role worker --agent plugin:<name>`. The
## live entrypoint (`.so` load, local host scope, `runGraph`, stdout
## write) stays in `waku.nim` so this module and its tests stay
## offline: inject `PluginFn`, get back the exact child lines to emit.
##
## - valid task -> `event` (turn ready), a `cost` line when the run
##   reported token counts, then `done` (reply plus an empty
##   `draft_path`: the worker writes nothing, the parent files)
## - invalid task or run raising -> single `error`, never raises
##
## No usage in the state means no model call happened: no invented
## charge — the same rule as slice 10. Only manifests the eligibility
## gate (`pluginWorkerEligible`) accepts ever reach this runner.

import std/json
import std/os
import std/strutils

import ./delegation
import ./graph/engine
import ./graph/hostfns
import ./graph/plugins
import ./loop
import ./tools
import ./wire

type
  PluginFn* = proc(): JsonNode {.closure.}
    ## Run one plugin turn and return its final state (`reply`,
    ## `draft_path`, and — like slice 10 — `usage` when an `llm` node
    ## reported token counts). Tests inject recordings; live code
    ## passes a closure over the manifest graph run.

proc runPluginWorker*(agent: string, task: JsonNode,
    run: PluginFn): seq[JsonNode] =
  ## One headless plugin turn. `agent` names the worker
  ## (`plugin:<name>`); `pid` is 0 (the parent stamps the observed pid
  ## on receipt).
  var err = ""
  if not parseTaskLine(task, err):
    return @[makeChildLine("error", "", "", agent, 0,
      %*{"message": "invalid task: " & err})]
  let traceId = task.jget("trace_id").getStr()
  let turnId = task.jget("turn_id").getStr()
  var state: JsonNode
  try:
    state = run()
  except CatchableError as exc:
    return @[makeChildLine("error", traceId, turnId, agent, 0,
      %*{"message": "plugin failed: " & exc.msg})]
  let reply = state.jget("reply").getStr()
  if reply.strip().len == 0:
    # An empty reply would read as success: say so instead, and the
    # parent fails open on the missing claim like any error line.
    return @[makeChildLine("error", traceId, turnId, agent, 0,
      %*{"message": "plugin answered nothing"})]
  let draft = state.jget("draft_path").getStr()
  result = @[
    makeChildLine("event", traceId, turnId, agent, 0,
      %*{"kind": "node_end", "node": agent,
          "reply_len": reply.len}),
  ]
  let usage = state.jget("usage")
  if usage.kind == JObject:
    var payload = copy(usage)
    result.add(makeChildLine("cost", traceId, turnId, agent, 0,
      payload))
  let logs = state.jget("logs")
  if logs.kind == JArray:
    for entry in items(logs):
      result.add(makeChildLine("message", traceId, turnId, agent, 0,
        %*{"kind": "log",
            "level": entry.jget("level").getStr("info"),
            "text": entry.jget("message").getStr()}))
  result.add(makeChildLine("done", traceId, turnId, agent, 0,
    %*{"reply": reply, "draft_path": draft}))

proc pluginRunHeadless*(home, pluginName, message, model,
    memoryText: string, client: LlmClient): JsonNode =
  ## One headless plugin turn (T2): load the plugin from the worker
  ## home, refuse ineligible manifests, run the manifest graph with a
  ## local host scope, and answer the final state. Raises on load
  ## failure, ineligibility, or a dead run — the caller maps every
  ## raise to one `error` child line, so the parent fails open.
  ##
  ## The local scope serves `llm` with the worker's own client (the
  ## task's effective model is the scope default), reads the run's
  ## own snapshot for `stateKeys`, and answers `plugin_log` on the
  ## run observer. `tool` and `fetch` are refused twice: the
  ## eligibility gate keeps such manifests out, and `allowed` would
  ## deny an undeclared call at runtime anyway.
  let path = pluginDir(home) / pluginName & ".so"
  let table = newHostTable(client, ToolRegistry(), model)
  let plugin = loadPlugin(path, addr table[])
  if not pluginWorkerEligible(plugin.nodes):
    raise newException(CatchableError,
      "plugin " & pluginName & " not eligible as worker")
  let handle = nextHostHandle()
  var state = %*{"message": message, "mem_text": memoryText}
  var totalIn, totalOut = 0
  var sawLlm = false
  var logs: seq[JsonNode] = @[]
  proc collect(kind: string, ev: JsonNode) {.closure.} =
    if kind == "llm":
      let u = ev.jget("usage")
      if u.kind == JObject:
        totalIn += u.jget("in").getInt(0)
        totalOut += u.jget("out").getInt(0)
      sawLlm = true
    elif kind == "plugin_log":
      logs.add(%*{"level": ev.jget("level").getStr("info"),
                  "message": ev.jget("message").getStr()})
  try:
    discard runGraph(buildPluginGraph(plugin, plugin.nodes, handle),
      state, collect)
  finally:
    expireHandle(handle)
  var reply = ""
  if state.jget("result").kind == JObject:
    reply = state["result"].jget("reply").getStr()
  elif state.jget("reply").kind == JString:
    reply = state["reply"].getStr()
  result = %*{"reply": reply, "draft_path": ""}
  if sawLlm:
    result["usage"] = %*{"kind": "plugin", "model": model,
      "in": totalIn, "out": totalOut}
  if logs.len > 0:
    result["logs"] = %logs

proc pluginTaskRunner*(home, pluginName, taskLine, model,
    memoryText: string, client: LlmClient): PluginFn =
  ## The `runWorkerCmd` closure as a testable unit: it parses the raw
  ## stdin line, reads the user text from the wire `task` field (not a
  ## `message` key — the triage state key with the same smell), and runs
  ## the plugin headless. An unreadable line raises here, and the caller
  ## maps it to one `error` child line like any failing run.
  let line = taskLine
  result = proc(): JsonNode {.closure.} =
    let task = parseJson(line.strip())
    pluginRunHeadless(home, pluginName, taskMessage(task), model,
      memoryText, client)
