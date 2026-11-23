## Unified graphs+plugins inventory — Slice A (read-only).
##
## The single place that answers "what graphs and plugins exist": the
## union of builtin workflows, loaded plugin graphs, enrolled agent
## cards and on-disk skills. This module only READS the three
## registries — it enrolls and registers nothing, so including it
## changes no behaviour. Selection (who runs) stays where it is until
## Slice B; this is the list Slice B will filter.
##
## One direction only: this module imports `graph/registry` and
## `graph/agents` and never `graph/plugins` or `memory_live`, so the
## dependency stays `inventory -> registries`, never the reverse. A
## skill's installed flag arrives as data (the dashboard reads it with
## `installedSkill`), the same way a topology arrives as data in
## `registerPluginGraph`.

import std/json
import std/strutils

import ./registry
import ./agents
import ../wire

type
  SkillStatus* = tuple[name: string, installed: bool]
    ## One on-disk skill: its folder name and whether `<name>.so`
    ## exists in the plugins dir. The caller reads the filesystem;
    ## this module only sorts names into entries.

proc entryFor(name, kind, source, whenToUse, cost: string,
    installed: bool): JsonNode =
  ## One inventory row with every field present (empty string when
  ## unknown) — a half row is never emitted.
  result = newJObject()
  result["name"] = %name
  result["kind"] = %kind
  result["tasks"] = newJArray()
  result["when_to_use"] = %whenToUse
  result["cost"] = %cost
  result["fallback"] = %"plain-loop"
  result["source"] = %source
  result["installed"] = %installed

proc inventoryFind*(entries: seq[JsonNode], name: string): JsonNode =
  ## The entry for `name`, nil when the inventory has no such row.
  for e in entries:
    if e.jget("name").getStr() == name:
      return e
  nil

proc cardText(card: JsonNode, key: string): string =
  ## A card field or "" — cards may omit anything except name/kind.
  if card != nil:
    return card.jget(key).getStr()
  ""

proc inventoryEntries*(enabled: seq[string],
    skills: seq[SkillStatus] = @[]): seq[JsonNode] =
  ## Builtins filtered to `enabled`, then every loaded plugin graph,
  ## then every on-disk skill not already covered. Builtins are always
  ## `installed`; a skill with a `.so` lists as `plugin-so` under its
  ## `plugin:` name, one without as `skill-md` under its folder name.
  ## An enrolled card fills `when_to_use` and `cost` — it never
  ## creates a row on its own (see `inventoryGaps`).
  for wf in builtinWorkflows():
    let name = wf.jget("name").getStr()
    if name notin enabled:
      continue
    let card = agentCard(name)
    result.add(entryFor(name, "graph", "builtin",
      cardText(card, "when_to_use"), cardText(card, "cost"), true))
  for name in pluginGraphNames():
    if inventoryFind(result, name) != nil:
      continue
    let card = agentCard(name)
    result.add(entryFor(name, "plugin", "plugin-so",
      cardText(card, "when_to_use"), cardText(card, "cost"), true))
  for s in skills:
    let pname = "plugin:" & s.name
    if inventoryFind(result, pname) != nil:
      continue
    if s.installed:
      let card = agentCard(pname)
      result.add(entryFor(pname, "plugin", "plugin-so",
        cardText(card, "when_to_use"), cardText(card, "cost"), true))
    else:
      if inventoryFind(result, s.name) != nil:
        continue
      let card = agentCard(pname)
      result.add(entryFor(s.name, "plugin", "skill-md",
        cardText(card, "when_to_use"), cardText(card, "cost"), false))

proc inventoryGaps*(enabled: seq[string],
    skills: seq[SkillStatus] = @[]): seq[string] =
  ## Read-only mismatch report, one line per problem. A loaded plugin
  ## graph with no enrolled card, and an enrolled `plugin:` card with
  ## neither a loaded graph nor an installed skill. Builtins are exempt
  ## (`agentKind` covers them without a card) and loop-only cards are
  ## exempt (the agents panel already lists them). Slice A refuses
  ## nothing at startup — it reports, so the gap is visible.
  for name in pluginGraphNames():
    if agentCard(name) == nil:
      result.add(name & " has a graph but no agent card")
  for cname in agentNames():
    if not cname.startsWith("plugin:"):
      continue
    if pluginGraph(cname) != nil:
      continue
    var covered = false
    for s in skills:
      if "plugin:" & s.name == cname and s.installed:
        covered = true
    if not covered:
      result.add(cname & " has a card but no graph")
