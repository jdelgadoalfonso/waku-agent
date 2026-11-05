## Agent registry — lot 2 T2.1: which agents the orchestrator can
## delegate to, beside the graph registry.
##
## One card per agent: what it is (`kind: loop|graph`), when to use it,
## what it takes, what it costs, what it may change. The orchestrator
## matches on cards; it never sniffs a worker's implementation. Like
## `registry.registerPluginGraph`, enrollment is data-only and
## replace-by-name, so tests stay offline and deterministic.
##
## Builtin kinds mirror `registry.defaultPlugins` (triage/gather are
## graphs); `config.nim` owns the enable list, this module only
## filters by the list it is given.

import std/json

import ../wire

const knownAgentKinds* = @["loop", "graph"]
  ## The only worker shapes the supervisor knows how to run: a loop
  ## turn or a graph turn over stdio.

var agentCards: seq[JsonNode] = @[]
  ## Enrolled cards, in enrollment order. Process lifetime, like the
  ## plugin graphs: an enrollment is never withdrawn.

proc isKnownAgentKind*(kind: string): bool =
  kind in knownAgentKinds

proc enrollAgent*(card: JsonNode) =
  ## Add (or replace by name) one agent card. A nameless or
  ## non-object payload is ignored rather than stored half-drawn.
  ## Unknown kinds are stored as-is here; the checked variant below
  ## is the gate loaders use.
  if card.kind != JObject:
    return
  let name = card.jget("name").getStr()
  if name.len == 0:
    return
  for i in 0 ..< agentCards.len:
    if agentCards[i].jget("name").getStr() == name:
      agentCards[i] = card
      return
  agentCards.add(card)

proc enrollAgentChecked*(card: JsonNode, err: var string): bool =
  ## Enrollment with the kind gate: only `loop|graph` cross into the
  ## registry. Returns false with `err` naming the rejection.
  if card.kind != JObject:
    err = "agent card must be an object"
    return false
  if card.jget("name").getStr().len == 0:
    err = "missing name"
    return false
  if not isKnownAgentKind(card.jget("kind").getStr()):
    err = "unknown kind"
    return false
  enrollAgent(card)
  err = ""
  true

proc agentNames*(): seq[string] =
  ## Enrolled names, in enrollment order.
  for card in agentCards:
    result.add(card.jget("name").getStr())

proc agentCard*(name: string): JsonNode =
  ## The enrolled card for `name`, nil when nothing enrolled it.
  for card in agentCards:
    if card.jget("name").getStr() == name:
      return card

proc agentKind*(name: string): string =
  ## Worker shape for `name`: builtins triage/gather are graphs (they
  ## mirror `registry.defaultPlugins`), enrolled cards declare their
  ## own, anything else is "".
  if name == "triage" or name == "gather":
    return "graph"
  let card = agentCard(name)
  if card != nil:
    return card.jget("kind").getStr()
  ""

proc enabledAgents*(enabled: seq[string]): seq[JsonNode] =
  ## Enrolled cards filtered to `enabled`, preserving enrollment
  ## order (the orchestrator lists workers as they arrived, not as
  ## the flag ordered them). Unknown names are skipped.
  for card in agentCards:
    if card.jget("name").getStr() in enabled:
      result.add(card)
