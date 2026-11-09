## Worker table — T2: every headless worker behind one lookup.
##
## The parent side already dispatches N agents (T17): this is the child
## side to match. Each entry pairs an agent name with a body of one
## shared shape: the parsed task line in, the child lines out.
## `gather` was the first entry, `brief` (T3) the second; anything
## answers one `error` line and never runs — the same answer a broken
## worker costs the parent (fail-open to its own loop), never a turn
## that reads as success or a broken pipe that reads as nothing.
##
## Bodies stay injected (`GatherFn` today, one closure per worker
## tomorrow) so this module and its tests stay offline: no spawn, no
## file IO, no clock. Live code in `waku.nim` builds the closures over
## the headless app.

import std/json
import std/strutils


import ./delegation
import ./graph/plugins
import ./worker_brief
import ./worker_gather
import ./worker_plugin

export worker_brief
export worker_gather
export worker_plugin

type
  WorkerBody* = proc(task: JsonNode): seq[JsonNode] {.closure.}
    ## One worker turn: the parsed task line in, the exact child lines
    ## to emit on stdout. Never raises: a failing workflow answers an
    ## `error` line, like `runGatherWorker` does today.

proc gatherBody*(gather: GatherFn): WorkerBody =
  ## The `gather` entry: the injected gather closure answers through
  ## the existing `runGatherWorker` path (event, cost when the synth
  ## reported usage, done — or one `error` line).
  result = proc(task: JsonNode): seq[JsonNode] {.closure.} =
    runGatherWorker(task, gather)

proc briefBody*(brief: BriefFn): WorkerBody =
  ## The `brief` entry (T3): the injected briefing closure answers
  ## through `runBriefWorker` (event, then done — or one `error` line).
  result = proc(task: JsonNode): seq[JsonNode] {.closure.} =
    runBriefWorker(task, brief)

proc workerTable*(gather: GatherFn, brief: BriefFn = nil): seq[tuple[
    agent: string, body: WorkerBody]] =
  ## The agents this binary can actually run headless, in order. `gather`
  ## first, `brief` second; a third worker adds one entry here and one
  ## half module beside `worker_gather.nim` — the lookup below needs no
  ## new branch per agent. A nil body stays out of the table, so
  ## `workerTable(gather)` keeps today's gather-only wire.
  result = @[(agent: "gather", body: gatherBody(gather))]
  if not brief.isNil:
    result.add((agent: "brief", body: briefBody(brief)))

proc pluginBody*(agent: string, run: PluginFn): WorkerBody =
  ## A `plugin:<name>` entry (T2): the injected run closure answers
  ## through `runPluginWorker` with the entry's agent stamped on every
  ## line. `runWorkerCmd` binds one entry per delegated plugin turn.

  result = proc(task: JsonNode): seq[JsonNode] {.closure.} =
    runPluginWorker(agent, task, run)

proc isPluginAgent*(agent: string): bool =
  ## A worker name routed to a plugin runner: the `plugin:` prefix with
  ## a non-empty plugin name.
  agent.startsWith(pluginGraphPrefix) and
    agent.len > pluginGraphPrefix.len

proc pluginWorkerNames*(enabled: seq[string]): seq[string] =
  ## Enabled `plugin:<name>` routes whose loaded manifest is worker
  ## eligible. The parent gate offers a plugin route only when a worker
  ## stands behind it — the same rule as built-in agents — without
  ## spawning anything: the module registry already holds every loaded
  ## plugin, and an unknown or ineligible name simply stays out.
  for agent in enabled:
    if isPluginAgent(agent) and agent notin result:
      let plugin = findLoadedPlugin(
        agent[pluginGraphPrefix.len .. ^1])
      if not plugin.isNil and pluginWorkerEligible(plugin.nodes):
        result.add(agent)

proc runWorkerLines*(agent, stdinLine: string, table: seq[tuple[
    agent: string, body: WorkerBody]]): seq[JsonNode] =
  ## Pure worker entrypoint: one stdin line in, the child lines out.
  ## An agent with no entry, an unreadable line and a structurally
  ## invalid task each answer ONE valid `error` line, and no body ever
  ## runs for them.
  var found: WorkerBody = nil
  for entry in table:
    if entry.agent == agent and not entry.body.isNil:
      found = entry.body
      break
  if found.isNil:
    return @[makeChildLine("error", "", "", agent, 0,
      %*{"message": "no worker for agent '" & agent & "'"})]
  var task: JsonNode
  try:
    task = parseJson(stdinLine.strip())
  except CatchableError:
    return @[makeChildLine("error", "", "", agent, 0,
      %*{"message": "invalid task: the line is not JSON"})]
  var err = ""
  if not parseTaskLine(task, err):
    return @[makeChildLine("error", "", "", agent, 0,
      %*{"message": "invalid task: " & err})]
  found(task)
