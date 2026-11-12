# Triage agents routing

This page explains how Waku routes a message through triage to a worker. It covers `WAKU_AGENTS`, `WAKU_GRAPH_DASHBOARD`, the small model, and the trace files. It uses `gather` as the running example.

## `WAKU_AGENTS` enrolls workers for triage

`WAKU_AGENTS` holds a comma-separated list of worker names. Waku trims each entry, drops empty entries, and keeps the first occurrence of each name. An unset variable, an empty value, or a blank value enrolls no worker. The default enrolls no worker and keeps the five-node `quick|full` graph.

```sh
export WAKU_AGENTS="gather"
export WAKU_AGENTS="gather,brief"
```

`quick` and `full` never name workers. Triage reserves both labels for its own paths and drops them from the allow-list. Unknown names stay ignored. Builtin workers come from the binary (`gather`, `brief`). Plugin workers use the `plugin:<name>` form and require a loaded worker-eligible manifest. `nim/src/config.nim` parses the list into `Settings.agents`. The dashboard reads the same variable for the agents panel.

Triage offers a worker route only when a delegate backs it. An enabled name without a worker changes nothing. An unowned route fails open to the plain loop. The prompt stays byte-identical to the `quick|full` prompt when no worker is enabled.

## `WAKU_GRAPH_DASHBOARD` selects the dashboard graph

`WAKU_GRAPH_DASHBOARD` names the graph that serves browser chat. The per-source variable wins when it is set and non-empty. The global `WAKU_GRAPH_WORKFLOWS` applies as the fallback. Waku re-reads the selector on every turn. A change needs no rebuild and no restart.

| Value | Dashboard behavior |
|---|---|
| Empty, `off`, `loop`, `0`, `false`, `no` | Waku runs the plain loop. |
| `triage`, `1`, `true`, `yes`, `on` | Waku runs triage with the enrolled workers. |
| `gather` | Waku runs the gather turn directly. |
| `plugin:<name>` | Waku runs the named plugin graph when the plugin is loaded. |
| Unknown | Waku runs the plain loop. |

```sh
export WAKU_GRAPH_DASHBOARD=triage
export WAKU_GRAPH_DASHBOARD=off
```

The CLI uses the parallel variable `WAKU_GRAPH_CLI`. Gateways use `WAKU_GRAPH_<SOURCE>` with the same fallback.

## `WAKU_AGENTS=gather` differs from `WAKU_GRAPH_DASHBOARD=gather`

`WAKU_AGENTS="gather"` keeps triage in charge. The small model classifies each message as `quick`, `full`, or `gather`. Only an explicit digest, briefing, or report request routes to `gather`. Memory questions and identity questions route to `full` because the worker holds no conversation memory.

`WAKU_GRAPH_DASHBOARD=gather` removes triage from the path. Every dashboard message triggers the gather turn. The turn ignores the message text and builds the fixed morning digest. An empty digest fails open to the plain loop.

The same split applies to plugins. `WAKU_AGENTS="plugin:<name>"` offers the plugin as one triage route. `WAKU_GRAPH_DASHBOARD="plugin:<name>"` runs the plugin graph for every dashboard message.

## Triage uses the small model

Triage makes two small-model calls without tools. `classifyMessage` sends the message and the allowed routes with `max_tokens: 600` and parses a JSON route. `quickReply` sends the calendar and the message with `max_tokens: 600` and returns the fast reply. Both calls use the configured small model. Both calls record `llm` events with kinds `triage` and `quick`.

Waku resolves the small model in this order. `WAKU_SMALL_MODEL` wins when it names a model. The provider row supplies `small_model` when the override is empty. The provider comes from `WAKU_PROVIDER` with `anthropic` as the default. The full path uses `WAKU_MODEL` through `runFullTurn`.

A broken classification fails open to `full`. Missing JSON, an unknown label, or a call error routes the message to the plain loop and records the reason. The failure costs latency and never removes capability.

## Traces record the decision

Waku appends every turn to `.waku/traces/<date>.jsonl`. The file records `turn_start`, the `llm` events for kinds `triage` and `quick`, the `gate` decision, the `route` with its reason, any `delegation` and `worker_done` or `worker_error` events, and `turn_end. Each row shares the turn `turn_id`.

Waku appends token counts to `.waku/usage.jsonl`. The ledger keeps one row per model call with provider, model, kind, input tokens, and output tokens. The file never wipes. The dashboard prices rows into dollars.

The dashboard surfaces the same rows. The Loop view groups one turn into gate, model calls, tools, graph route, receipt, and reply. The Observability view aggregates turns, spend, tools, and per-agent rows with route, cost, process id, and state. The chat stream announces delegation and completion events while the turn runs.
