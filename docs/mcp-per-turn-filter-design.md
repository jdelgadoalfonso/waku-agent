# MCP Per-Turn Tool Filter — design proposal

Status: Approved by the user and implemented (Python T1-T5 plus Nim port T6-T7, uncommitted worktree). This document stays as the design record.
Scope: Waku sends fewer MCP tools to the model on each turn without removing servers.

## 1. Problem

Waku registers every MCP tool at startup and sends every schema on every model call.
`MCPBridge.start()` connects every server in `~/.waku/mcp.json` and returns one `Tool`
per remote tool as `<server>_<tool>` (`waku/tools/mcp_client.py`).
`ToolRegistry.schemas()` returns every registered tool (`waku/tools/registry.py`),
and `run_loop()` passes those schemas to `client.messages.create()` on each iteration
(`waku/loop/agent.py`).
Each new MCP server therefore adds tokens to every turn, even when the user task
needs none of its tools.
`WAKU_UNAVAILABLE_TOOLS` does not fix this. It appends tool names to the system prompt
(`waku/runtime/session.py`, `waku/config.py`) and never removes schemas.

## 2. Decision

Filter registered schemas per turn before the model call.
The registry keeps every tool. The loop sends only the tools that match the current
task. Servers stay connected, so this design restarts no subprocess and repeats no
OAuth handshake.

## 3. Alternatives considered

Per-process profiles in `mcp.json` would start only the servers that match a named
profile. This option is simpler and needs no loop change. It fails the goal because
selection happens once per process, not once per user message. A chat session that
mixes calendar work and code review would still carry both sets.

A lazy `call_mcp` meta-tool would register one tool and fetch the catalog on demand.
This option saves the most context. It hides native schemas from the model, adds a
second indirection for arguments and errors, and needs the largest change to the
tool-call contract. This proposal rejects it for now and keeps it as future work.

## 4. Design

### 4.1 Filter point

`run_loop()` calls a new `ToolRegistry.schemas_for(task_signal)` instead of
`schemas()` when it builds the `tools=` parameter. `schemas()` stays for the
dashboard catalog, traces, and tests that need the full set. `execute()` keeps
accepting any registered name, so a filtered-out tool still runs if the history
already contains its call.

### 4.2 Task signal

The filter reuses the existing skill matcher (`SkillLoader.match()` in
`waku/memory/procedural/loader.py`) or the retrieval gate
(`waku/memory/retrieval_gate.py`) to derive a small signal from the latest user
message. The signal names task tags such as `calendar`, `code`, or `web`.
Each registry entry carries an optional tag set. Flagship tools keep their current
behavior. Each MCP server declares tags in `mcp.json`, and each of its tools
inherits them.

### 4.3 Config

`mcp.json` gains an optional per-server block:

```json
{
  "servers": [
    {
      "name": "gh",
      "command": "mcp-gh",
      "tasks": ["code"],
      "when": ["mention of repo", "mention of pull request"]
    }
  ]
}
```

A server without `tasks` keeps the current behavior and always loads. This choice
preserves backward compatibility for existing `mcp.json` files.

### 4.4 Guardrails

The filter defaults to allow. An empty or uncertain signal sends the current full
set. A deny list (`WAKU_UNAVAILABLE_TOOLS`) continues to apply after filtering.
The loop logs the filtered tool names per turn so traces and the dashboard can
show what the model actually saw.

## 5. Risks

A wrong signal hides a tool the model needs, and the turn fails without calling it.
The skill-trigger eval documents this precision problem
(`evals/deterministic/test_skill_triggers.py`). The allow-by-default rule and the
per-turn log mitigate it.

Filtering must not break trace lineage or the dashboard catalog. Traces map tool
origin as `mcp:<server>` (`waku/ops/observability.py`). The dashboard lists MCP
servers and their catalog without starting subprocesses (`waku/ops/dashboard.py`).
Both keep reading the full registry, never the filtered view.

Filtering must not restart MCP servers. `MCPBridge` owns one event loop and one
session per server (`waku/tools/mcp_client.py`). The filter runs after `start()`
and touches only the schema list, so it creates no new process or login.

## 6. Deterministic eval

Every behavior change needs a deterministic eval (`evals/deterministic/`).
The proposal adds `evals/deterministic/test_tool_filter.py` with three cases:

1. A code task sends the `gh` tools and omits the calendar MCP tools.
2. A calendar task sends the calendar tools and omits the `gh` tools.
3. An empty signal sends the full set.

The PR proves each test fails before the fix by breaking the filter, watching the
test turn red, and restoring the code.

## 7. Docs touched by this change

This change makes four statements false unless the same PR updates them:

- `docs/architecture.md` says the registry decides which tools are on.
- `docs/integrations.md` says any configured server reaches the agent.
- `docs/status.md` describes current tool behavior.
- `docs/getting-started.md` says a restart loads tools.

## 8. Tasks

1. Add tags to `Tool` and `schemas_for()` to `ToolRegistry` with unit eval.
2. Read per-server `tasks`/`when` from `mcp.json` in `MCPBridge` setup.
3. Wire the filter into `run_loop()` and log filtered names per turn.
4. Keep dashboard catalog and traces on the full registry.
5. Update the four docs and run `make gate` plus `make lint`.
