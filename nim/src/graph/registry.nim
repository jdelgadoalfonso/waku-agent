## Graph plugin registry — which graphs exist: two builtins, plus one per
## loaded plugin (step 3).
##
## The single source of truth for which graphs exist. Step 1 held the two
## builtins (triage, gather); step 3 lets a loaded plugin contribute one
## more (`registerPluginGraph`), and the dashboard reads this module instead
## of a hardcoded pair, so a third graph appears with no dashboard change.
##
## Name clash note: `nim/src/registry.nim` is the TOOL registry. This
## module is `graph/registry`; import it with a `from` import
## (`from ./graph/registry import enabledWorkflows, ...`) so the two
## module names never meet.
##
## Enable list: the `[plugins]` table the user chose lives in `Settings`
## (`config.nim`, `WAKU_PLUGINS`, comma-separated, default both). This
## module only filters by the list it is given — it never reads env
## itself, so tests stay offline and deterministic.
##
## One direction only: this module imports `gather`/`triage` for the
## builtin topologies and NEVER `graph/plugins`, so a plugin's topology
## arrives as data (`registerPluginGraph(name, describe())`) and the
## dependency stays `plugins -> registry`.

import std/json
import std/strutils

import ../gather
import ../triage
import ../wire

const defaultPlugins* = @["triage", "gather"]
  ## Builtins, in dashboard order. `config.nim` mirrors this literal as
  ## the `Settings.plugins` default (config cannot import this module:
  ## triage -> app -> config would become a cycle).

const knownPluginKinds* = @["tool", "llm", "agent", "router"]
  ## The only node kinds a plugin manifest may declare (they map 1:1 to
  ## the factories in `graph/nodes.nim`). Anything else is rejected at
  ## load time — open decision #2, closed here as reject-unknown.

proc parsePluginList*(raw: string): seq[string] =
  ## `WAKU_PLUGINS="triage, gather"` -> @["triage", "gather"]. Trims,
  ## drops empties, dedupes preserving order. Empty input means "no
  ## opinion" and returns @[] — callers fall back to `defaultPlugins`.
  for part in raw.split(','):
    let name = part.strip()
    if name.len > 0 and name notin result:
      result.add(name)

proc isKnownPluginKind*(kind: string): bool =
  ## True for the four declarable kinds, false for anything else
  ## (including `fn`, which carries a closure and can never cross the
  ## plugin boundary).
  kind in knownPluginKinds

proc workflowNames*(): seq[string] =
  ## The builtin names, in dashboard order.
  defaultPlugins

proc builtinWorkflows*(): seq[JsonNode] =
  ## Both topologies straight from the engine (never hand-drawn).
  @[triageTopology(), gatherTopology()]

var pluginGraphs: seq[JsonNode] = @[]
  ## Graphs a loaded plugin contributed, in registration order. Process
  ## lifetime, like the library they came from: a successful load is never
  ## unloaded, so its graph never leaves this list either.

proc registerPluginGraph*(name: string, topology: JsonNode) =
  ## Add (or replace by name) one plugin-contributed topology. Only data
  ## crosses: the loader hands over the `describe()` payload it built, so
  ## this module never learns a `.so` exists. A nameless or non-object
  ## payload is ignored rather than stored half-drawn.
  if name.len == 0 or topology.kind != JObject:
    return
  var payload = topology
  if payload.jget("name").getStr() != name:
    payload = copy(topology)
    payload["name"] = %name
  for i in 0 ..< pluginGraphs.len:
    if pluginGraphs[i].jget("name").getStr() == name:
      pluginGraphs[i] = payload
      return
  pluginGraphs.add(payload)

proc pluginGraphNames*(): seq[string] =
  ## The plugin-contributed names, in registration order.
  for wf in pluginGraphs:
    result.add(wf.jget("name").getStr())

proc pluginGraph*(name: string): JsonNode =
  ## The registered topology for `name`, nil when no plugin declared one.
  for wf in pluginGraphs:
    if wf.jget("name").getStr() == name:
      return wf

proc enabledWorkflows*(enabled: seq[string]): seq[JsonNode] =
  ## Builtins filtered to `enabled`, preserving dashboard order, then every
  ## plugin-contributed graph. A plugin graph is not filtered by the enable
  ## list: the `.so` being loaded and registered IS its enable decision, and
  ## a chart the dashboard certified as present while hiding it would be
  ## the lie this registry exists to avoid. Unknown names in `enabled` are
  ## skipped (a plugin name that never loaded); an empty list returns an
  ## empty builtin list — the "fall back to default" lives in the callers
  ## (`config.loadFromEnv`, dashboard env parse), not here.
  for wf in builtinWorkflows():
    if wf.jget("name").getStr() in enabled:
      result.add(wf)
  for wf in pluginGraphs:
    result.add(wf)
