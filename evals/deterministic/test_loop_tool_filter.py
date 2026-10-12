"""DETERMINISTIC EVAL -- the per-turn MCP filter (mcp-per-turn-filter).

A turn whose message matches an MCP server's `when` phrases sends
only the task-tagged tools that match, plus the untagged flagship
tools (§4.1/§4.2). A message that matches nothing sends the full
set — the filter is allow-by-default (§4.4). And a tool the filter
held back still runs when the model calls it anyway: the registry
keeps every tool and only the schema list is per-turn (§4.1).
"""

from __future__ import annotations

from evals.helpers import ScriptedClient, response, text_block
from waku.loop.agent import run_loop
from waku.runtime.session import derive_task_tags
from waku.tools.registry import Tool, ToolRegistry

# Two MCP servers as mcp.json would declare them (§4.3): each carries
# task tags its tools inherit, and the `when` phrases that fire them.
GH = {"name": "gh", "tasks": ["code"], "when": ["repo", "pull request"]}
CAL = {"name": "calendar", "tasks": ["calendar"],
       "when": ["meeting", "schedule"]}
# tasks with no `when`: no signal of its own (§4.2), so it may not
# fire on a message that matches nothing.
WHENLESS = {"name": "silent", "tasks": ["ghost"]}


class RecordingClient(ScriptedClient):
    """The scripted model, which also keeps every call's arguments."""

    def __init__(self, script):
        super().__init__(script)
        self.calls: list[dict] = []

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        return self._script.pop(0)


def _registry() -> ToolRegistry:
    """The flagship calendar tool (untagged: always sent) beside one
    tool per MCP server, each carrying its server's task tags."""
    empty = {"type": "object", "properties": {}}
    registry = ToolRegistry()
    registry.register(Tool(name="list_events", description="flagship",
                           input_schema=empty, fn=lambda **_: "[]"))
    registry.register(Tool(name="gh_pr", description="[MCP:gh]",
                           input_schema=empty, fn=lambda **_: "pr",
                           tags={"code"}))
    registry.register(Tool(name="calendar_mcp_create",
                           description="[MCP:calendar]",
                           input_schema=empty, fn=lambda **_: "created",
                           tags={"calendar"}))
    return registry


def _names(call: dict) -> list[str]:
    return [t["name"] for t in call["tools"]]


# --- 1. a message that names a server's `when` filters to it --------------


def test_a_message_matching_when_sends_only_that_servers_tools():
    # matching is case-insensitive; "Repo" and "Pull Request" still fire
    message = "Please fix this Pull Request in the Repo"
    assert derive_task_tags(message, [GH, CAL, WHENLESS]) == {"code"}

    client = RecordingClient([response([text_block("Done.")])])
    events: list[tuple[str, dict]] = []
    result = run_loop(client, "m", "Soul.",
                      [{"role": "user", "content": message}], _registry(),
                      task_tags={"code"},
                      observer=lambda kind, ev: events.append((kind, ev)))

    sent = _names(client.calls[0])
    assert sent == ["list_events", "gh_pr"], \
        "the flagship tool and gh go; calendar is held back"
    assert result.reply == "Done."
    # the turn logs what the model actually saw (§4.4), on the llm event
    llm = [ev for kind, ev in events if kind == "llm"]
    assert llm and llm[0]["tools_sent"] == sent


# --- 2. a message that matches no `when` sends the full set ----------------


def test_a_message_matching_no_when_sends_the_full_set():
    message = "what's the weather like today"
    assert derive_task_tags(message, [GH, CAL, WHENLESS]) == set()

    # None and the empty set are both allow-by-default (§4.4)
    for signal in (None, derive_task_tags(message, [GH, CAL])):
        client = RecordingClient([response([text_block("Sunny.")])])
        run_loop(client, "m", "Soul.",
                 [{"role": "user", "content": message}], _registry(),
                 task_tags=signal)
        assert _names(client.calls[0]) == ["list_events", "gh_pr",
                                           "calendar_mcp_create"]


# --- 3. a filtered-out tool still runs when the model calls it -------------


def test_execute_still_runs_a_tool_the_filter_held_back():
    registry = _registry()
    assert "calendar_mcp_create" not in _names({"tools": registry.schemas_for({"code"})})
    # history can hold a call to a schema the turn never sent (§4.1)
    assert registry.execute("calendar_mcp_create", {}) == "created"
