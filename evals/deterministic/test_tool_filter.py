"""DETERMINISTIC EVAL — per-turn tool filter on the registry.

Proposal docs/mcp-per-turn-filter-design.md §6: a task signal narrows
the schemas one turn sees, without unregistering anything. An empty or
missing signal sends the full set — the filter defaults to allow (§4.4).
§4.3: an MCP server's optional `tasks` list tags every tool it
publishes, and a server without it stays always visible.
Hermetic: no subprocess, no network, no .waku state."""

from __future__ import annotations

import json

from waku.tools.registry import Tool, ToolRegistry


def filtered_registry() -> ToolRegistry:
    """Two tagged MCP-style tools (<server>_<tool>) plus one flagship
    tool that carries no tags."""
    registry = ToolRegistry()
    registry.register(Tool(
        name="gh_create_pr",
        description="Create a GitHub pull request",
        input_schema={"type": "object", "properties": {}},
        fn=lambda: "created",
        tags={"code"},
    ))
    registry.register(Tool(
        name="calendar_create_event",
        description="Create a calendar event",
        input_schema={"type": "object", "properties": {}},
        fn=lambda: "created",
        tags={"calendar"},
    ))
    registry.register(Tool(
        name="save_note",
        description="Save a note to memory",
        input_schema={"type": "object", "properties": {}},
        fn=lambda: "saved",
    ))
    return registry


def names(schemas: list[dict]) -> set[str]:
    return {schema["name"] for schema in schemas}


def test_code_task_sends_gh_and_omits_calendar():
    """§6 case 1: a code task sends the gh tools and omits calendar."""
    sent = names(filtered_registry().schemas_for({"code"}))
    assert "gh_create_pr" in sent
    assert "calendar_create_event" not in sent
    # untagged flagship tools keep current behavior (§4.2)
    assert "save_note" in sent


def test_calendar_task_sends_calendar_and_omits_gh():
    """§6 case 2: a calendar task sends the calendar tools and omits gh."""
    sent = names(filtered_registry().schemas_for({"calendar"}))
    assert "calendar_create_event" in sent
    assert "gh_create_pr" not in sent
    assert "save_note" in sent


def test_empty_signal_sends_full_set():
    """§6 case 3: an empty signal sends the full set."""
    registry = filtered_registry()
    full = names(registry.schemas())
    assert names(registry.schemas_for(set())) == full
    assert names(registry.schemas_for(None)) == full


# --- the bridge: a server's `tasks` reach its tools (§4.3) -------

def _bridge_registry(tmp_path, monkeypatch, servers: list) -> ToolRegistry:
    """Register the tools an MCPBridge reports for a written mcp.json,
    with the connecting stubbed out (the treg eval's pattern), so the
    bridge's own config reading is what is under test."""
    from waku.tools import mcp_client

    monkeypatch.delenv("TREG_API_KEY", raising=False)
    tmp_path.mkdir(parents=True, exist_ok=True)
    (tmp_path / "mcp.json").write_text(
        json.dumps({"servers": servers}), encoding="utf-8")

    async def connect_all(self, resolved):
        metas = [{"name": "do_thing", "description": "do it",
                  "inputSchema": {"type": "object", "properties": {}}}]
        return {s["name"]: metas for s in resolved}

    monkeypatch.setattr(mcp_client.MCPBridge, "_connect_all", connect_all)
    # _deadline imports the mcp extra, which CI does not install.
    monkeypatch.setattr(mcp_client.MCPBridge, "_deadline", lambda self, servers: 5.0)
    bridge = mcp_client.MCPBridge(tmp_path / "mcp.json")
    try:
        tools = bridge.start()
    finally:
        bridge.close()
    registry = ToolRegistry()
    for tool in tools:
        registry.register(tool)
    return registry


def test_a_server_with_tasks_filters_by_schemas_for(tmp_path, monkeypatch):
    """§4.3: a server that declares `tasks` tags every tool it
    publishes, so a code turn sees them and a calendar turn does not."""
    registry = _bridge_registry(tmp_path, monkeypatch, [
        {"name": "gh", "command": "mcp-gh", "tasks": ["code"]},
    ])
    assert names(registry.schemas_for({"code"})) == {"gh_do_thing"}
    assert "gh_do_thing" not in names(registry.schemas_for({"calendar"}))


def test_a_server_without_tasks_is_always_visible(tmp_path, monkeypatch):
    """§4.3: a server without `tasks` keeps the current behavior —
    its tools reach the model on every turn, whatever the signal."""
    registry = _bridge_registry(tmp_path, monkeypatch, [
        {"name": "fs", "command": "npx"},
    ])
    for signal in ({"code"}, {"calendar"}, set(), None):
        assert names(registry.schemas_for(signal)) == {"fs_do_thing"}


def test_a_tasks_that_is_not_a_list_is_ignored(tmp_path, monkeypatch):
    """§4.3's invalid config: a `tasks` that is not a list is ignored
    — the server stays always visible and Waku still starts."""
    registry = _bridge_registry(tmp_path, monkeypatch, [
        {"name": "gh", "command": "mcp-gh", "tasks": "code"},
    ])
    for signal in ({"code"}, {"calendar"}, set()):
        assert names(registry.schemas_for(signal)) == {"gh_do_thing"}
