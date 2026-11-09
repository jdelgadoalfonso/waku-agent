# Plugin workers (proposal)

Status: implemented 2026-11-09 on `feat/plugin-workers` (T2 eligibility gate + headless runner + triage gate threading). Snapshot semantics confirmed: the task-line snapshot (T21-D) rides for plugins exactly as for `gather`/`brief` — read-only, bounded, no live queries back.

## Goal

This proposal runs a graph plugin as a same-binary worker process. The plugin loads isolated in the worker, and the orchestrator keeps owning every effect it does not explicitly lend.

## Background

Plugins run in-process today. The parent loads each `.so` with `dlopen` and hands it a table of six host callbacks: `llmComplete`, `toolCall`, `stateKeys`, `fetch`, `stringFree` and `log` (`nim/src/graph/hostfns.nim`). Those are raw C function pointers in one shared address space: they cannot cross a process boundary, and the worker wire (stdin task line, stdout child lines) carries JSON, not pointers. The reference plugin `textops` declares per-node `needs`: only its `summarize` node needs `llm`; the rest is pure (`upper`, `expand`) or routing (`pick_long`).

## Proposal

Eligibility first, execution second. A plugin runs as a worker only when every node need fits what a headless worker may touch: `llm` served by the worker's own client, pure plugin-local computation, and routing. Anything else (`toolCall`, `fetch`, `stateKeys` against the parent store) refuses at load with "no worker for this plugin shape", and the parent fails open to the local loop exactly as an unknown agent does. The `needs` manifest the plugin already declares is the gate: no new metadata.

Concretely, the worker loads the `.so`, builds the manifest graph with a local host scope, and drives one turn: `llm` nodes call the worker's own client and report usage on the `cost` child line (the slice-10 rule); `log` becomes a child `message` line the orchestrator traces; the reply rides `done` like every other worker. The wire does not change, and the slice-9 rules hold: no runtime writes, a silent tracer, no store, no outbox.

## Alternatives

Forwarding host callbacks to the orchestrator as wire RPC would keep every plugin eligible, but it turns each node call into a cross-process round trip and invents a protocol the task line deliberately avoids. A worker-side tool registry would re-create the full agent inside the worker and break the rule that workers hold no tools. Both stay out: eligibility keeps this proposal small, and either can revisit the decision with its own measurements.

## Testing

Each behavior change gets a deterministic eval: an ineligible manifest refuses with one `error` line and never spawns; an eligible plugin answers event, cost when its `llm` node reported usage, and done with the reply; a failing plugin answers `error`, never raises. The gate offers the plugin route only when its worker binds, like every other agent.

## Rollout

1. The maintainer approves this doc and confirms the eligibility line (`llm`-only plus pure nodes).
2. The plugin worker lands with `textops` as its first proof.
3. The same PR updates this doc status, the orchestrator design doc, and `odd/tasks/plugin-workers.md`.

Non-goals: callback forwarding over the wire, worker-side tools or stores, remote workers, new default dependencies, and any change to the frozen Python half.
