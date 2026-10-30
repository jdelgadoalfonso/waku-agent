# Roadmap

The whiteboard has boxes beyond the flagship scheduling task. This page says
which ones are live, which are still skeletons, and how each default upgrades
when you outgrow it.

New capability lands in `nim/`, because the Nim binary is how you use Waku and
`waku/` is frozen. The list below therefore describes what the port carries.
`nim/README.md` has the phase list, and [nim-port-design.md](nim-port-design.md)
records the gates each phase had to pass.

## The boxes beyond the flagship task

These live in [`waku/tools/experimental.py`](../waku/tools/experimental.py),
off by default; `WAKU_EXPERIMENTAL=1` registers them. The port carries the same
set in `nim/src/experimental.nim`.

**Sub-Agents is live.** `delegate_task` hands a coding job to
[pi](https://github.com/earendil-works/pi) — Mario Zechner's minimal
open-source coding agent — through its headless print mode (`pi -p "task"`).
Waku stays the orchestrator (memory, context, evals); pi is the specialist
contractor (read/bash/edit/write). Try it:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
WAKU_EXPERIMENTAL=1 ./nim/waku
# "have pi fix the failing test in ~/my-project"
```

The full pi transcript lands in `.waku/outbox/delegate-*.log`; tune the budget
with `WAKU_DELEGATE_TIMEOUT` (default 300s). The pi walkthrough is in
[lab/pi-agent/](../lab/pi-agent/README.md).

The rest are still deliberate **skeletons**: the intent is drawn so the diagram
maps to something, but nothing is over-promised. They report "coming soon",
and the dashboard's **Tools** tab lists them under **Coming soon**:

| Whiteboard box | Tool | Status |
|---|---|---|
| Sub-Agents | `delegate_task` | **live** — delegates coding tasks to pi |
| Graph workflows | [`waku/graph/`](../waku/graph) | **live** behind `WAKU_GRAPH_WORKFLOWS=1` — [triage-first turns](tour.md#graph-workflows) |
| Terminal tool | `run_command` | skeleton — needs a real sandbox + safety surface first |
| Browser tool | `browse_web` | skeleton — `search_web` already covers read-only lookups |
| Cron Job | `schedule_task` | skeleton — `make brief` + a system cron line covers it today |

A teaching repo's point is a readable core, so these come alive one at a time,
tested.

## Graph plugins, if they arrive

[graph-plugins-design.md](graph-plugins-design.md) proposes running a graph node
from a Nim dynamic library, over a C boundary that carries JSON and handles.
Nothing is built, and this page does not schedule it. Two tiers inside that
proposal are deliberately waiting:

| Tier | What it adds | Why it waits |
|---|---|---|
| Child process | A plugin that crashes ends a child instead of Waku. | The in-process tier proves the contract first, and a second transport is a second implementation to keep honest. |
| WebAssembly | Memory, syscalls and lifetime inside a sandbox. | A third transport, worth the work only for a plugin nobody trusts. |

## Upgrade paths

| Default (zero setup) | Upgrade | How |
|---|---|---|
| SQLite FTS5 keyword memory | Supabase pgvector semantic search | `WAKU_SEMANTIC_STORE=supabase` + [sql/init_supabase.sql](../sql/init_supabase.sql) — the exact schema from [launch-rag](https://github.com/ShenSeanChen/launch-rag)/[launch-agentic-rag](https://github.com/ShenSeanChen/launch-agentic-rag) |
| Mock calendar (ICS + SQLite) | Apple / Google Calendar | `WAKU_APPLE_CALENDAR=1` (macOS) or `WAKU_GOOGLE_CALENDAR=1` — the tool schema stays. The frozen Python half also needs `pip install -e '.[gcal]'` |
| Hand-built memory pillars | mem0 / Zep / LangMem | set `WAKU_SEMANTIC_STORE` and race them in the Arena's Memory tab; the frozen Python half also needs `pip install -e '.[arena]'`. [Where to see your memories in each provider's own console](memory-backends-playbook.md) |
| Local memory on one machine | Waku Memory, shared across agents | `./nim/waku connect waku-memory` — see [integrations](integrations.md#share-one-memory-with-your-other-agents-waku-memory) |

## Related repos (the building blocks)

[launch-rag](https://github.com/ShenSeanChen/launch-rag) ·
[launch-agentic-rag](https://github.com/ShenSeanChen/launch-agentic-rag) ·
[launch-agent-skills](https://github.com/ShenSeanChen/launch-agent-skills) ·
[launch-mcp-demo](https://github.com/ShenSeanChen/launch-mcp-demo) ·
[launch-DeepResearch-Backend](https://github.com/ShenSeanChen/launch-DeepResearch-Backend)
