# Nim port sync with origin/main (loop guardrail 2, consolidation filters, spec 018)

Port to `nim/src/` the three behavior changes `origin/main` landed after the
merge-base (`b246a59`), before the rebase. The Python side arrives with the
rebase; this work makes the Nim port match it. Sources of truth: commits
`c4ff93b` (#309), `cd698a5` (#311), `763d3e7` (#312) on origin/main.

## Specs

### S1 — Loop guardrail 2 answers from what the turn gathered (c4ff93b)
- `LIMIT_NOTE` = "You have reached the step limit for this turn and cannot call any more tools. Answer now from what you already gathered; say plainly what is missing or what failed."
- After `max_iterations`, ONE final tools-off call: `system` becomes `f"{system}\n\n{LIMIT_NOTE}"`, request carries `tools=tools.schemas()` and `tool_choice={"type": "none"}` (Anthropic refuses a history with tool_use blocks and no tools), `trim` runs first, `max_tokens` as usual.
- `notify("llm", {"iteration": max_iterations + 1, "kind": "final", "final_answer": true, "stop_reason": ..., "usage": {...}})`.
- `reply` = the final call's text; `LIMIT_REPLY` (the old static message) only when that call fails or wrote no text.
- `LoopResult.limit_reached: bool` = True on this path.

### S2 — Consolidation never keeps the assistant's own state (cd698a5 + 763d3e7)
- `is_ops_state(fact)`: True when subject+content matches `\bbalance\b` AND `_MONEYISH` (`\$|\busd\b|\bcredits?\b|\bmicro\b|\baccount\b|\bwallet\b|\btop(?:ped)?[- ]?up\b|\binsufficient\b|\btreg\b|\bapi\b`), or matches `_OPS_STATE` (insufficient credits, micro-USD, http/status/error 4xx-5xx, 402/429, rate limit, too many requests, quota, token counts, timeouts/tool errors, billing+treg/api/platform/waku, system prompt/context window/tool call).
- `is_memory_state(fact)`: True when subject+content matches `_MEMORY_STATE` (stored/saved/recorded/kept/held/found/listed in [waku] memory; find/locate in memory; no record/trace/mention of ... memory; memory ... no record/trace/mention of; [waku] memory has/holds/contains/lacks no/nothing).
- Filter order in `kept_if_due`: ops/memory-state drop BEFORE the report rule; then report, then recall.
- `SUMMARIZER_PROMPT` gains: "Extract only what the person said. Never extract from the assistant's replies, and never extract what the assistant's memory holds or lacks, such as \"no address is stored\" or \"it could not find X\". An answer the assistant gave is not a fact about the person."

### S3 — save_note tells the truth about where a fact went (763d3e7, spec 018)
- `facts` table gains `synced INTEGER DEFAULT 1` and `scope TEXT DEFAULT 'global'` (schema + idempotent `_migrate` ALTERs; existing rows default to synced=1 so the backlog is not re-sent).
- `save_note(subject, content, remember=None)`:
  - no `remember`: INSERT (subject, content, 'user') → synced=1; answer "Saved here. Waku Memory is not connected."
  - with `remember`: INSERT with synced=0, scope='global'; send `remember(content, "global")`; on success mark synced=1 and answer "Saved here and in Waku Memory" + " (id <memory_id>)" when the server named one; on failure answer "Saved here. Waku Memory did not take it (<reason>); it is sent again later." where reason is the error's first line cut to 80 chars.
- Tool description gains "The answer says where the fact was saved; repeat it to the user exactly."
- `_recalled` (app): a fact `save_note` saved counts as memory the turn handled — `"subject: content"` lines join the recalled text so consolidation does not extract the same sentence from the chat row again.

## Tasks

- T1 — S1: `nim/src/loop.nim` + `nim/tests/test_loop.nim` (done: cefd3aa)
- T2 — S2: `nim/src/memory_live.nim` + `nim/tests/test_memory_live.nim` (done: this commit)
- T3 — S3: `nim/src/notes.nim`, `nim/src/db.nim`, `nim/src/memory_admin.nim`, `nim/src/registry.nim` + tests (done: 492cbef)
- T4 — S3 wiring: `nim/src/app.nim` (`savedCell`), `nim/src/memory_live.nim` (`wireMemory` joins saved saves into `recalled`) + tests (done: this commit)

## Log

- L1 (user): "la rama actual esta desfasada con respecto a origin/main, antes de rebasearla hay que ver que es lo que se añade nuevo con respecto al port que estamos haciendo en Nim" → investigation found 3 behavior gaps; no nim/ conflicts with origin/main.
- L2 (user): "portamos primero y rebaseamos después" — port the three gaps first, rebase after.
- L3: rebase landed clean (181 commits, no conflicts) but exposed two contract gaps the merge-base tests could not see: (a) main's PINNED_GET/POST now name `/api/observability` and `/api/turn-evals/judge`, which the port already served as declared divergences — moved into the pythonPinned mirrors (dashboard.nim); (b) the SPA's `d.<key>` reads are not all /api/data reads — the test extractor now scopes own-payload files (compare/diagram/models/observe). Remaining red: `/api/data` owes `key_locations` (spec 013, `waku/key_locations.py` — resolve_home rule, env_write_target, STARTUP_ENV_NAMES, worktree detection), not yet ported. Awaiting the user's call: port now or track as the next unit.
