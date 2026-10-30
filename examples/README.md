# examples — short lessons about Waku itself

Each file here teaches one thing and runs in one command. Waku runs from the
Nim binary built in [../nim/](../nim/README.md). A row whose command runs the
frozen Python half in `../waku/` says so, because that half still works and
teaches the same three steps.

| File | What it teaches | Run it |
|---|---|---|
| [tiny_memory_agent.py](tiny_memory_agent.py) | the loop's three steps with memory, and nothing else in frame — a Python lesson about the frozen half | `python examples/tiny_memory_agent.py` |
| [mcp.demo.json](mcp.demo.json) | connecting Waku to an MCP server, with no remote host | `mkdir -p .waku && cp examples/mcp.demo.json .waku/mcp.json && WAKU_HOME=.waku ./nim/waku dashboard` |

The MCP demo server itself is `evals/fixtures/mcp_demo_server.py`, because the
test suite runs the same server. Material about other projects lives in
[../lab/](../lab/README.md).

The rules for this folder are in
[conventions §6](../docs/context/conventions.md#6-examples-and-video-material).
