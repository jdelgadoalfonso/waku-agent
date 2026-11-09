# Generic workers (proposal)

Status: proposal — awaiting maintainer yes. No code changes ship under this doc until the maintainer approves it.

## Goal

This proposal turns every worker into what `gather` already is. Any loop or graph workflow runs as a same-binary worker process behind the delegation contract, and the orchestrator keeps routing by route without caring what runs behind each label.

## Background

One worker exists today. `delegateWorkers` holds a single name (`nim/src/delegate.nim:30`), `workerChildLines` answers "no worker for agent" for anything else (`nim/src/waku.nim:689`), and the T17 pin locks one productive worker in. The dispatch side is already generic: the T17 dispatcher hands each route to its own delegate, so a second worker inherits the routing for free. Only the execution side is hardcoded: `workerChildLines` always ends in `runGatherWorker`, and `runWorkerCmd` always builds a gather closure. The wire itself is already generic: task lines carry trace, turn, task, context, budget and model for any agent, and child lines carry event, cost, done and error with an agent name. The T21-D memory snapshot and the T19 model override ride the task line for any future worker with no further wire change.

## Proposal

A worker table replaces the single-name gate. Each entry names an agent and the runner that serves one task line: parse the line, run the workflow headless, and return the child lines. `workerChildLines` looks the agent up in the table instead of branching on `gather`, and `runWorkerCmd` builds the matching closure. Every worker follows the slice-9 rules: no runtime writes, a silent tracer, no database, no outbox copy, and fail-open to the local loop on any failure. The orchestrator side does not change: `workerAgents` already admits any table member, and the gate offers a route only when a worker stands behind it.

## Placement

The table lives in a new module, `nim/src/workers.nim`. It sits beside the worker halves (`worker_gather.nim`, and later `worker_brief.nim`): each half keeps its own workflow knowledge, and the table only maps names to runners. It does not live in `graph/agents.nim`: enrollment there answers the gate question (which routes the prompt may offer), while the table answers the execution question (which process runs the route). Mixing the two would couple prompt topology to process lifetime.

Each entry pairs an agent name with a runner of one shared shape: the parsed task line in, the child lines out. `workerChildLines` keeps its current contract (unknown agent, unreadable line and invalid task each answer one `error` line) and replaces its `gather` branch with a table lookup. `runWorkerCmd` keeps reading the task line first, then builds the worker context the entry needs: the headless app, the T19 model override and the T21-D memory snapshot. `gather` becomes the first entry with no behavior change; `brief` plugs in as the second with one new half module. The orchestrator, the dispatcher, the gate and the wire stay untouched.

## First worker

The table needs one second entry to prove the shape. Three candidates exist:

- **brief**: the morning briefing as a loop turn (`nim/src/brief.nim`). It mirrors `gather` in scope and needs the same headless adaptation: skip the outbox write and return the reply. Smallest delta.
- **loop**: the plain full-agent turn as a worker. Most general, but it duplicates the fail-open target and needs a tighter budget story.
- **plugin graphs**: the `plugin:<name>` graphs run in-process today through `dlopen`. Moving them behind worker processes is a different isolation decision and stays out of this proposal.

The recommended first entry is **brief**: it reuses the slice-9 pattern line for line and exercises the table without inventing new worker semantics.

## Testing

Each worker gets deterministic evals before it ships: an unknown agent answers one `error` line without spawning, an unreadable line answers one `error` line, a valid task returns event, cost when the workflow reports usage, and done with the reply, and a failing workflow answers `error` instead of raising. The table itself gets pins: one entry per worker, no duplicate names, and the gate offers only table members. Tests call the constructors directly and never assert that a string appears in source.

## Rollout

1. The maintainer approves this doc and picks the first worker.
2. The worker table lands with `gather` as its first entry: no behavior change.
3. The first worker lands headless with its pins.
4. The same PR updates this doc status, the orchestrator design doc, and `odd/tasks/generic-workers.md`.

Non-goals: remote workers, worker-initiated memory search, worker writes, plugin-process isolation, new default dependencies, and any change to the frozen Python half.
