# Orchestrator memory context for workers (proposal)

Status: approved 2026-11-09 — implementation in progress under this doc. No code changes ship under this doc until the maintainer approves it.

## Goal

This proposal gives a delegated worker read-only memory without letting the worker open the store. The orchestrator reads memory once and passes a bounded text snapshot in the task line. The worker uses that snapshot as its memory scan and writes nothing.

## Background

A delegation uses one JSON line from the orchestrator to the worker. The line already carries a `context` string field. The orchestrator always sends `""` today (`nim/src/delegate.nim`). The worker builds its app without a database (`nim/src/waku.nim`, `buildWorkerApp`), so its memory scan answers `(memory unavailable: the worker holds no local store)` (`nim/src/gather.nim`, `unwiredMemory`). The triage prompt sends memory and identity questions to `full` and never to an agent route (`nim/src/triage.nim`). A small model can still ignore that clause, so a worker can receive a question that needs memory and answer blind.

## Proposal

The orchestrator fills `context` with the output of the existing gated retrieval for the user message. The worker uses a non-empty `context` as its `mem_text` scan result. An empty `context` keeps today's behavior byte for byte.

Three rules bound the change:

1. The orchestrator owns all reads. It calls the same gated retrieval the loop uses, truncates the result to a fixed limit, and marks truncation in the text. It never passes paths, keys, or handles.
2. The worker owns no reads. It never opens the database when `context` is present. It treats `context` as opaque text for one scan and never persists it.
3. Failures stay silent and cheap. An empty retrieval sends `""`. An oversized snapshot truncates. A malformed `context` behaves like `""`. The turn fails open to the local loop exactly as today.

## Contract

The wire format does not change. `makeTaskLine` already defines `context` as a string, and `parseTaskLine` already accepts it. This proposal only defines what the orchestrator writes there and what the worker reads from it.

- The orchestrator writes at most 5000 characters of retrieved facts and episodes, joined with newlines. It appends `[truncated]` when retrieval returns more.
- The worker reads `context` only for the `scan_memory` step of a gather turn. It does not log `context`, store it, or return it outside the digest.
- The worker keeps `writeDraft = false`, a silent tracer, no database, and no tool registry. This proposal adds no write path.

## What stays unchanged

The trace rule stays unchanged: only the orchestrator writes traces, usage rows, and the database. The delegation lifecycle stays unchanged: timeout, non-zero exit, and invalid lines fail open to the local loop. The prompt boundary stays unchanged: memory and identity questions still route to `full` when no delegate answers them. This proposal only covers the case where a delegated turn still benefits from a small amount of read-only memory.

## Testing

Each behavior change gets a deterministic eval before it ships:

- The orchestrator truncates a long retrieval to the limit and marks it.
- An empty retrieval sends `""` and the worker reports the existing unavailable text.
- The worker uses a non-empty `context` as `mem_text` without opening a database.
- A malformed `context` behaves like `""` and the turn still answers or fails open.

The tests call the constructors directly and never assert that a string appears in source.

## Rollout

1. The maintainer approves this doc.
2. The orchestrator fills `context` behind the existing delegate seam.
3. The worker reads `context` as its memory scan.
4. The same PR updates this doc status, the orchestrator design doc lot, `docs/status.md` if it names the worker as memory-blind, and `odd/tasks/orchestrator-instances.md`.

Non-goals: worker-initiated memory search, worker writes, cross-turn worker memory, new dependencies, and any change to the frozen Python half.
