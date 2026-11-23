# Orchestrator inventory Slice C (bounded instantiation)

Two-line header: approved proposal `docs/orchestrator-inventory-design.md` rollout Slice C; builds the delegates table from the inventory so every offered route has something that can receive it. Eligibility verdicts are reused, never rewritten.

## Specs

- S1: "The delegates table is built from inventory entries: one live delegate per installed entry the existing eligibility gates accept; nothing else can receive a route."
- S2: "Eligibility rules are reused unchanged (`delegateWorkers` membership for builtins, `pluginWorkerEligible` for plugins); the inventory replaces only the name source, never the verdict."
- S3: "Every offered route has a delegate: the bind-time delegates cover the unfiltered inventory offer, and the per-turn filter (Slice B) only narrows within it."
- S4: "Every behaviour change gets a deterministic eval; fail-open preserved (a route without a delegate still answers full through the plain loop)."

## Tasks

- [ ] T1 (S1,S2): inventory-driven delegate list reusing workerAgents/pluginWorkerEligible — route: worker
- [ ] T2 (S3): binders build delegates and offer from the same inventory — route: worker
- [ ] T3 (S4): deterministic pins (offered ⇒ runnable; unknown ⇒ no delegate; fail-open) — route: worker
- [ ] T4: neighbor suites + rulebook + independent verify — route: inline

## Log

- L1: user: "vamos con el slice C" (after Slice B landed: per-turn tag filter with fail-open, independently verified).
- L2: Slice C landed via worker (T1-T3, test-first, S1-S4 PASS). Follow-up fixed `brief` regression: `agentRoster` = runnableAgents(entries) ∪ workerAgents(enabled, extra); all 5 binders share one rule with extra recomputed from roster. Verified: slice-c suite 14/14, inventory 6/6, triage-filter 5/5, delegate + gateway_graph_select green, nim check waku clean, rulebook 17 passed, assess recorded (medium/unassessable, writer self-verification). Full `nimble test` not run; no commit.
- L3: independent verify (gentle-ai-verify): points 1-6 PASS, no blockers. Notes: inventory half admits loaded eligible plugins absent from WAKU_AGENTS (name-source widening consistent with S2, behavior change vs enable-list-only offer); binder-shape pins exercise helpers, binder call sites guarded by source inspection; cross-half dedupe correct by inspection, unpinned.
