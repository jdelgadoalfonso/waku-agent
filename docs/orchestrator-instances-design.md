# Orchestrator of waku-agents: same binary, role processes

Status: approved — maintainer yes total 2026-11-05 (T4). Code may proceed in T3.1-T3.5 slices.
Tier: Proposal per `docs/context/conventions.md` section 2 — touches loop, graph engine, tool-call contract surface, and adds a top-level orchestration concept.

## Goal

Turn waku-agent into an orchestrator of waku-agents:

- One orchestrator process routes each turn to worker processes.
- Workers are instances of the same binary with a different role (`orchestrator` vs `worker --agent <name>`).
- A worker runs either a loop or a graph plugin; the orchestrator does not care which, only the contract.
- One dashboard (the orchestrator's) with full traceability and observability of orchestrator plus workers.
- Keep overview, gateway, loop, memory, tools, database, observability, evals working as today.

Non-goals: remote workers, new default dependencies, new Python capability in `waku/` (frozen, nim-first S1).

## Background

Today `Waku.respond()` already routes `quick | full` with fail-open to the loop (`waku/app.py:121-129`), and `/name` invokes a named graph (`waku/ops/commands.py:85-95`). The Nim port adds a plugin registry (`nim/src/graph/registry.nim`). The dashboard already animates loop stages (`data/static/js/diagram.js`) and graph stages (`data/static/js/graph.js:137-174`), fed by `GET /api/events` over `.waku/traces/*.jsonl`.

## Lot 1 — Process model, stdio JSON, trace contract

- Roles: the orchestrator is the default process (it takes no role flag); a worker is `waku --role worker --agent <name>`.
- Transport: stdlib only, no new dependency. Parent spawns child per delegation:
  - parent -> child on stdin, one JSON line: `{trace_id, turn_id, task, context, budget:{timeout_ms, max_tool_calls}}`.
  - child -> parent on stdout, JSON lines: `{type, trace_id, agent, pid, payload}` where type in `text, event, cost, done, error`.
- Lifecycle: spawn per delegation with timeout and kill; on timeout, malformed output, or non-zero exit, fail-open to the local loop (same rule as `waku/app.py:128-129`).
- Trace rule: orchestrator mints `trace_id` per user turn and passes it down. Only the orchestrator writes to `.waku/traces/<date>.jsonl`, `usage.jsonl`, and DB. Workers never write runtime data directly (hard rule 1).
- Event envelope reused: `triage, route, graph_start, node_start, node_end, graph_end, llm, tool, gate` plus `delegation:{agent, pid, route, reason, path}` aggregated by the orchestrator into the turn `meta`.

## Lot 2 — Agent registry in Nim (as built: T2.1-T2.3)

- New `nim/src/graph/agents.nim` beside `graph/registry.nim` (registry untouched): `enrollAgent` (replace-by-name, ignores nameless/non-object), `enrollAgentChecked` (kind gate `loop|graph`), `agentCard/agentNames/agentKind` (builtins triage/gather report `graph`), `enabledAgents` (enrollment order). Pure, offline, pinned by `nim/tests/test_agents.nim`.
- Router stays model-writes-key, code-reads-key (`waku/graph/nodes.py:66-67` precedent): `classifyMessage` takes `allowedRoutes` (default `@["quick","full"]`, old callers unchanged); anything outside fails open to `full` with the reason. `buildTriageGraph` takes `agentRoutes` + `DelegateFn` and adds one `delegate_agent` node with router entries; with none enabled the topology is byte-identical (5 nodes, pinned). Offer-only-when-receivable: the prompt offers an agent route only when a delegate is bound, because an unmapped label is a router error, not a `full` fallback.
- Plumbing (T2.3): `Settings.agents` + `WAKU_AGENTS` (comma-separated, trim, dedupe, default empty = today's behavior) in `nim/src/config.nim`; `triagePromptFor` renders the gate prompt (byte-identical to `triagePrompt` with no agent enabled); `triageGraphTurn(..., agents = @[], delegateFn = nil)` threads allow-list and delegate seam. Execution wiring landed in slices 2a-2c: `makeDelegateFn` supervises one worker per delegation, `buildCliApp` binds it at startup, and every per-turn dashboard binder (`resolveGatewayGraph` through `reselectGraphTurn`, `ensureWaku`, `/triage`, `gatewayAgents`) rebuilds it, so `WAKU_AGENTS` naming a worker is live on the CLI, the browser chat, the gateways and the dashboard slash command. With `WAKU_AGENTS` empty the delegate is nil and the topology stays the five-node quick|full graph, byte for byte; a delegated route with no execution binding (or a worker that fails open) answers `(false, _)` so the plain loop answers.
- New capability lives in `nim/`; no new top-level package (ladder section 3).
- Deterministic evals in `nim/tests/test_agents.nim` (5), `test_router_agents.nim` (3), `test_agent_plumbing.nim` (10); regressions pinned by `test_workflows.nim` (28) and `test_plugin_registry.nim` (7). `.env.example`/user-docs mention of `WAKU_AGENTS` deferred (sensitive path, needs an explicit plan).

## Lot 3 — Single dashboard, dual Overview

- One dashboard: the orchestrator's. Workers run headless (no port).
- Overview stays `VIEWS.overview` in `data/static/js/views.js:506-517`, same order (`uiStatBand, gateSplit, archSVG, graphPanel, turnCard`). Only change: expand `archSVG` for loop turns, expand `graphPanel` for graph-plugin turns, based on the last turn's `graph.route`. No rewrite of `archSVG` (byte-frozen per `data/static/README.md` rule 2).
- Agents panel: new `agentsPanel` inside Overview listing live workers as `{name, kind: loop|graph, pid, state: idle|busy|dead, cost, last_route}`. Topology comes from the agent registry `describe()` payload in `/api/data`; no JS topology per plugin.
- Inter-agent edges: orchestrator emits `delegation {from, to, trace_id, turn_id}` and `message {from, to, trace_id, kind: task|partial|done|error}` events into the same JSONL consumed by `GET /api/events`. `graph.js:animateGraphStage` reuses `route` edge lighting (`g-<w>-<router>-<target>`) for `delegation`, and `diagram.js:pollEvents` 450ms + `graph.js` 100ms ticker render message waves in real time with no new polling loop.
- Animations unchanged: loop via `diagram.js:STAGE`, graph via `graph.js:animateGraphStage/graphLive`. Delegated subtrace expands on click, fed by aggregated `agents:[{agent, route, reason, path, cost}]` in the SSE `done` (extension of `dashboard.py:152-154).
- `/api/observability` and `/api/events` aggregate per agent, not only `quick/full`. Frontend contracts (`/api/data`, SSE shapes) stay backward compatible.
- Constraints: tokens from `docs/context/design-system.md`, no edit of `data/static/design/`, no build step, global handlers only, no emojis. Visible redesign in the binary requires `make nim-build` (`staticRead` embed in `nim/src/dashboard.nim:429-497`). New `/api/*` routes need hosted policy entries (`test_route_contract.py`) only if `hosted/` is touched.

## Testing

- `make nim-test` offline suite green; new `nim/tests/test_orchestrator_*.nim` for route selection, fail-open on worker crash/timeout, and trace aggregation.
- Dashboard: `test_static_assets.py`, `test_design_system.py`, `test_observability.py` (archSVG hash), topology payload pins.
- Docs updated in the same PR for every behavior change (hard rule 9).

## Rollout

1. Contract + one worker extracted (`gather`) + fail-open.
2. Registry + `quick|full|<worker>` router.
3. Overview dual-panel + per-agent observability.
