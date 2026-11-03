---
name: new-tool
description: Add a new tool to Waku the right way — schema, safe execution, deterministic eval, honest output. Use when adding or modifying agent tools or when the user asks for a new capability.
---

## Procedure

1. One file per tool in `nim/src/`, building a `Tool` and handing it to
   `register(reg, tool)` from `nim/src/tools.nim`. `waku/tools/` is the frozen
   Python half: it takes no new tool.
2. The tool function must be:
   - **Idempotent** where repeat calls could occur (check-before-insert, like
     create_event's title+start guard).
   - **Honest in its return string**: say exactly where the artifact went
     (file path, table) and how the user can see it. Never imply effects the
     tool doesn't have.
   - **Local-first by default**: write to `.waku/` or state.db; real external
     services go behind env-gated adapters.
3. Register it in the registry the binary builds, and check that the tool list
   the model sees still earns its place: a new core tool is the last resort,
   and a skill is cheaper.
4. Add deterministic coverage beside the port: a `nim/tests/test_*.nim` suite
   that runs offline with a scripted client, fires the tool and asserts the
   artifact (DB row or file). `evals/deterministic/` guards the frozen half and
   the repo, not new capability.
5. If the tool needs usage guidance, add a skill under `skills/` (validated by
   `scripts/validate_skills.py`) instead of prose in the system prompt.
6. Check scope first: the repo ships flagship-task tools only. New capabilities
   beyond scheduling/notes/messages should be discussed before building.
