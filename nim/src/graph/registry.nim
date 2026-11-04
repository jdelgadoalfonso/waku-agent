## Graph plugin registry — step 1: builtins only, no dynamic libraries.
##
## The single source of truth for which graphs exist. Today it holds the
## two builtins (triage, gather); a later step teaches it to load a plugin
## `.so` and append its `describe()` payloads here. The dashboard reads
## this instead of a hardcoded pair, so a third graph appears with no
## dashboard change.
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

proc enabledWorkflows*(enabled: seq[string]): seq[JsonNode] =
  ## Builtins filtered to `enabled`, preserving dashboard order.
  ## Unknown names are skipped (future plugins); an empty list returns
  ## an empty list — the "fall back to default" lives in the callers
  ## (`config.loadFromEnv`, dashboard env parse), not here.
  for wf in builtinWorkflows():
    if wf.jget("name").getStr() in enabled:
      result.add(wf)
