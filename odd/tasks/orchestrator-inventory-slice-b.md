# Orchestrator inventory Slice B (per-turn tag filter)

Two-line header: approved proposal `docs/orchestrator-inventory-design.md` rollout Slice B; narrows the gate's route offer by task tags, reusing the `schemas_for()` matcher idea. Fail-open: an empty match restores today's full offer.

## Specs

- S1: "The gate lists only routes whose tasks match the turn; an empty match restores the full offer and notes it, so the orchestrator never faces zero options."
- S2: "Tasks come from the agent card `tasks` field; an entry without tasks is always listed (fail-open: irrelevance unproven)."
- S3: "Matching reuses the existing per-turn tag matcher (`schemas_for()` idea); no second matcher is introduced."
- S4: "Every behaviour change gets a deterministic eval; the gate prompt keeps citing name + when_to_use so the pick stays traceable."

## Tasks

- [ ] T1 (S2): `tasks` in inventory entries from enrolled cards (empty = listed always) — route: inline
- [ ] T2 (S1,S3): gate filter in triage/delegate path reusing the tag matcher, fail-open — route: inline
- [ ] T3 (S4): deterministic pins (match narrows / empty restores / no-tasks listed) — route: inline
- [ ] T4: neighbor suites + rulebook — route: inline

## Log

- L1: user: "vamos con el slice B" (after Slice A landed: manifest + describe + dashboard list, read-only).
- L2: Slice B landed via worker (T1-T3, test-first, S1-S3 PASS, S4 partial: `when_to_use` not injected into gate prompt — needs explicit decision). Assess: risk medium, native unassessable (untracked files), plan = writer self-verification stands, no separate verifier. Verified: test_triage_filter 5/5, test_inventory 6/6, test_workflows 40/40, test_plugin_registry/agents/plugin_graphs green, rulebook 17 passed. Full `nimble test` not run.
- L3: independent verify (gentle-ai-verify): points 1-4 + 6 PASS; point 5 qualified FAIL (empty-signal test didn't pin its guard; turn test pinned only forward direction). Fixed inline: empty-signal test now enrolls tagless `delta` (guard break -> RED confirmed, restored -> 5/5 GREEN); turn test asserts the exact route line and documents why reverse divergence needs no pin.
