# docs — what is in here

Start with [AGENTS.md](../AGENTS.md) at the repo root: it routes every kind of
change to the one file that covers it. This folder holds those files, sorted
into four groups.

## Start here

- [getting-started.md](getting-started.md) — install, the first run, and
  connecting Waku Memory, with a check at the end of every step.
- [tour.md](tour.md) — the dashboard, things to try, the loop, graph workflows
  and skills.
- [status.md](status.md) — what works, what is known-broken, what is
  deliberately not built. Rewritten whole rather than appended to, so it
  cannot become a changelog. Read it before opening a PR.

## The rulebook

| file | what it answers |
|---|---|
| [context/conventions.md](context/conventions.md) | how much process a change needs, where capability goes, testing, git, scope |
| [context/design-system.md](context/design-system.md) | how the dashboard looks, and which primitive to use |
| [context/writing-rules.md](context/writing-rules.md) | how we write docs, UI copy and commit messages |
| [context/gotchas.md](context/gotchas.md) | traps someone already stepped on |
| [context/maintainers.md](context/maintainers.md) | how maintainers review, merge and release; contributors can skip it |

## Reference — how the system works

| file | what it answers |
|---|---|
| [architecture.md](architecture.md) | the four pillars, and which file is which diagram box |
| [triage-agents.md](triage-agents.md) | how triage routes a message to a worker, and which variable selects each graph |
| [loop-vs-graph.md](loop-vs-graph.md) | when a turn needs shape, and why the loop never changes |
| [agent-graphs-design.md](agent-graphs-design.md) | the graph engine's design and its fail-open rule |
| [graph-plugins-design.md](graph-plugins-design.md) | a graph node from a Nim dynamic library: the C boundary, the host functions, and the trust tiers (proposal) |
| [orchestrator-instances-design.md](orchestrator-instances-design.md) | the orchestrator of same-binary role processes: the delegation contract, the agent registry, and the single dashboard |
| [orchestrator-memory-context-design.md](orchestrator-memory-context-design.md) | read-only memory for delegated workers: the bounded task snapshot without a worker store (proposal) |
| [generic-workers-design.md](generic-workers-design.md) | any loop or graph as a same-binary worker process behind the delegation contract (proposal) |
| [plugin-workers-design.md](plugin-workers-design.md) | graph plugins as worker processes: eligibility by manifest needs, effects owned by the orchestrator (proposal) |
| [mcp-per-turn-filter-design.md](mcp-per-turn-filter-design.md) | selective MCP tools: the per-turn filter and its `tasks`/`when` config |
| [gmail-integration-design.md](gmail-integration-design.md) | Gmail as a capability: the three tools, the draft-first send guard, and its open decisions |
| [providers-registry.md](providers-registry.md) | adding a model provider: one table in `data/providers.toml` |
| [memory-backends-playbook.md](memory-backends-playbook.md) | seeing your memories in each provider's own console |
| [benchmarks.md](benchmarks.md) | what has been measured, and how |
| [integrations.md](integrations.md) | voice, Telegram, Apple, Google Calendar, MCP, Waku Memory — all opt-in |
| [commands.md](commands.md) | every `waku` and `make` command |
| [evals.md](evals.md) | the two kinds of eval, the Docker tier, the release gate, traces and spend |
| [roadmap.md](roadmap.md) | what is live, what is still a skeleton, upgrade paths |
| [nim-port-design.md](nim-port-design.md) | the Nim port: one binary, same `.waku/`, and the phase list with its gates |

## Whiteboards

Every whiteboard is an **editable `.excalidraw` source**: download one, drop it
on [excalidraw.com](https://excalidraw.com), and remix it for your own team.
The ones that explain Waku live in [whiteboards/](whiteboards/); the ones from
videos about other projects live with their topic in [../lab/](../lab/README.md).

| Chart | What it explains |
|---|---|
| [`waku-architecture.excalidraw`](whiteboards/waku-architecture.excalidraw) | Waku itself — harness, loop, memory pillars, LLM Ops (editable rebuild of [the whiteboard](architecture-whiteboard.png)); its LLM Ops panel is the whiteboard's, with observe, two evals and a release gate, not the dashboard's four boxes (Trace, Observability, Evals, Release) |
| [`loop-vs-graph.excalidraw`](whiteboards/loop-vs-graph.excalidraw) | Loop vs graph engineering — the ladder, and two timelines from a measured run of `waku brief` against `waku gather` ([the write-up](loop-vs-graph.md)) |
| [`k3-architecture.excalidraw`](../lab/kimi-k3/whiteboards/k3-architecture.excalidraw) | Kimi K3: the 16-of-896 MoE, KDA + AttnRes attention, why agent loops get cheap |
| [`pi-architecture.excalidraw`](../lab/pi-agent/whiteboards/pi-architecture.excalidraw) | pi (72K-star coding agent): 4-tool core, extensions, one EventStream |

New charts arrive with every video. If they help you,
[a star](https://github.com/ShenSeanChen/waku-agent) keeps them coming — and
[sponsoring](https://github.com/sponsors/ShenSeanChen) gets new whiteboards early.

`scripts/whiteboard/build_*.py` generates the Waku boards so they match the
hand-drawn masters; edit the builder, not the JSON.

## Deliberately not in docs/

- [../examples/](../examples/README.md) — short runnable lessons about Waku
  itself.
- [../lab/](../lab/README.md) — one folder per outside topic (Kimi K3, pi, the
  memory products), with its write-up, boards and code. Video work starts
  there.

[conventions §6](context/conventions.md#6-examples-and-video-material) has the
rules for both.
