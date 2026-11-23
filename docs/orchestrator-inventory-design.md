# Orchestrator inventory — unified graphs + plugins (Slice A, read-only)

Status: proposal. Slice A covers only a common manifest and a unified `describe()` that the dashboard shows. Selection, prompts, and subagent creation stay unchanged. Slices B (per-turn filter) and C (bounded instantiation) wait for separate proposals.

Scope: the Nim half (`nim/`). `waku/` stays frozen and serves only as the behaviour oracle. Slice A adds no tool, no prompt entry, and no default dependency.

## 1. Problem

The orchestrator cannot answer "what graphs and plugins do I have for this task" from one place. Today there are three disconnected inventories:

1. `agentCards` in `nim/src/graph/agents.nim` — description, cost, and touch scope. Read only by tests.
2. Graph registry `plugin:<name>` in `nim/src/graph/registry.nim` (`registerPluginGraph`) — feeds the dashboard and the worker gate only.
3. Skills plus compiled plugins: `<home>/skills/*/SKILL.md` discovered per turn by text match (`matchingSkills`), and `<home>/plugins/*.so` discovered at startup by `loadPluginGraphs` in `nim/src/graph/plugins.nim` and checked per turn by `installedSkill` in `nim/src/memory_live.nim`. `nim/src/app.nim` runs the first installed skill in the top-2 text matches.

The routing gate `triagePromptFor` in `nim/src/triage.nim` sees only route names with a fixed legend. The card (when to use it, cost, risk) never reaches the model that picks the route. A compiled skill whose text did not match is unreachable, and the orchestrator cannot propose a subagent from a compiled skill on its own.

Dashboard `graphSection` hardcodes `triageTopology() + gatherTopology()`. A plugin workflow never appears in the list. `skill_graph_propose` / `skill_graph_approve` on `POST /api/memory` have no UI.

Slice A fixes visibility only. It does not change what the gate sees or what the orchestrator spawns.

## 2. Decision: one manifest, one describe()

Add one read-only inventory type and serve it where `/api/data` already serves the agent panel.

```nim
type InventoryEntry = object
  name: string        # "triage" | "gather" | "plugin:<name>"
  kind: string        # "graph" | "plugin"
  tasks: seq[string]  # tags the B-slice filter will match, e.g. ["research", "brief"]
  when_to_use: string # one sentence, from the agent card or skill frontmatter (snake_case, like the cards)
  cost: string        # "loop" | "headless" + rough model class, no dollars here
  fallback: string    # "plain-loop" — every entry fails open to the plain loop
  source: string      # "builtin" | "plugin-so" | "skill-md"
  installed: bool     # false for a skill with no .so yet
```

Rules:

- Builtins (`triage`, `gather`) come from `builtinWorkflows()` in `nim/src/graph/registry.nim`.
- Plugin graphs come from `loadPluginGraphs` (`nim/src/graph/plugins.nim`): each `.so` manifest becomes one `plugin:<name>` entry.
- Skills without a `.so` appear with `installed: false` and never become routable in Slice A. This makes the "not yet compiled" state visible without changing behaviour.
- A graph entry keeps `describe()` as today (`engine.nim`: `{name, nodes, edges}`). A plugin entry keeps its compiler manifest (`skillgraph.nim`: only `llm` + `router` nodes, `needs: ["llm"]`, DAG with forward reach). The inventory does not re-declare node schemas; it points at them.
- A registry entry with no card, or a card with no registry row, is reported by `inventoryGaps()` and never emitted as a half row (the read-only version of the `integrations.nim` closed-set rule). Slice A refuses nothing at startup; refusal waits for Slice C.

Non-goals for Slice A: no change to `triagePromptFor`, no per-turn tag filter, no new spawn path, no `triagePromptFor` card injection, no propose/approve UI. The orchestrator keeps spawning exactly what it spawns today (`waku --role worker --agent <name>` over one JSON line on stdin, text/event/cost/done/error lines on stdout, timeout or crash fails open to the local loop).

## 3. Dashboard and API

- Extend the `collect()` blob that `/api/data` already returns with `inventory: InventoryEntry[]`, built from the same constructors the loop uses, so the dashboard lists what the loop can run.
- `graphSection` keeps serving `workflows` unchanged and adds `inventory`: builtins, installed `plugin:<name>` entries and on-disk skills. Each row shows `when_to_use`, `cost`, and `installed`.
- The Memory tab keeps propose/approve as the only write path. No new write route in Slice A.

## 4. Testing

Every behaviour change gets a deterministic eval (offline, no key):

- Closed-set pin: an inventory built from a fixture registry with one builtin, one installed plugin, and one uncompiled skill returns exactly those three entries with the fields above, and refuses a card without a row.
- Dashboard pin: `graphSection` renders a plugin workflow from the same fixture (today it cannot).
- Drift pin: every `agentCards` name appears in the inventory and every inventory `graph` name appears in `workflowNames()`.

Prove each test can fail: remove one row, watch it go red, put it back. Say so in the PR.

Frontend has no test runner: verify the panel in a browser per `data/static/README.md`.

## 5. Rollout

- Slice A defines the manifest type, the unified `describe()`, and the dashboard list. It changes no behaviour.
- Slice B will add the per-turn tag filter in the orchestrator, reusing the `schemas_for()` tags idea and fed by `tasks` above.
- Slice C will add bounded instantiation from the inventory, and it keeps the existing `workerAgents` + `pluginWorkerEligible` gate unchanged until C lands.

## 6. Open questions

1. Where does `when_to_use` live for a compiled plugin: skill frontmatter, compiler manifest, or agent card override? Proposal: card override wins, frontmatter is the default, compiler manifest carries it verbatim.
2. Should uncompiled skills be listed with `installed: false`, or hidden until approved? Proposal: listed, so the gap is visible, but never routable.
