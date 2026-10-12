"""Tool registry — the 'Agentic Tools' box on the whiteboard.

A tool is three things: a name+description the model reads, a JSON schema for
its arguments, and a Python function that runs. That's it. (Registry pattern
adapted from launch-agentic-rag's app/agents/tools/registry.py.)
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Tool:
    name: str
    description: str
    input_schema: dict[str, Any]
    fn: Callable[..., str]  # tools return a string the model observes
    # A long-running tool can opt in to STREAM progress while it works: set
    # wants_notify=True and accept a `_notify(kind, event)` keyword. The loop's
    # observer is passed through, so gateways/traces see inside the tool
    # (delegate_task uses this to relay pi's live events). The underscore keeps
    # it out of the model-facing schema — the model never supplies it.
    wants_notify: bool = False
    # Optional tags for the per-turn filter (mcp-per-turn-filter
    # proposal §4.2): empty means "always send", so flagship tools
    # keep their current behavior. MCP tools inherit their server's
    # task tags.
    tags: set[str] = field(default_factory=set)

    def to_api(self) -> dict[str, Any]:
        """The shape the Messages API expects in its `tools=` parameter."""
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": self.input_schema,
        }


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}

    def register(self, tool: Tool) -> None:
        self._tools[tool.name] = tool

    def get(self, name: str) -> Tool | None:
        return self._tools.get(name)

    def schemas(self) -> list[dict[str, Any]]:
        return [t.to_api() for t in self._tools.values()]

    def schemas_for(self, task_tags: set[str] | None) -> list[dict[str, Any]]:
        """The per-turn view run_loop sends as its `tools=` parameter
        (proposal §4.1). A None or empty signal is allow-by-default and
        returns the full set; otherwise a tool is sent when it has no
        tags, or its tags intersect the signal. The registry keeps every
        tool either way — execute() still runs a filtered-out name when
        the history already contains its call."""
        if not task_tags:
            return self.schemas()
        return [
            t.to_api() for t in self._tools.values()
            if not t.tags or t.tags & task_tags
        ]

    def execute(self, name: str, args: dict[str, Any], notify=None) -> str:
        """Run one tool call safely: the model observes errors as text instead
        of crashing the loop (execute_tool_safely pattern)."""
        tool = self._tools.get(name)
        if tool is None:
            return f"Error: unknown tool '{name}'"
        try:
            if tool.wants_notify:
                return tool.fn(**args, _notify=notify or (lambda kind, ev: None))
            return tool.fn(**args)
        except Exception as exc:  # surface, don't crash — the model can retry
            return f"Error running {name}: {exc}"
