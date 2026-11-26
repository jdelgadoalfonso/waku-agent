# Gate fail-open quiet (LlmRefused)

Two-line header: the memory gate and the triage gate fail open on every turn with a bare `(LlmRefused)` notice that hides the provider's real message and repeats identically each turn; phase A quiets the notice (real message + repeat marking, fallback unchanged), phase B stops calling a small model that refuses.

## Specs

- S1: "En cada turno aparece gate failed open (LlmRefused)" — the fail-open reason must carry the provider's real message via `errorText` instead of the bare `($exc.name)`, in both `shouldRetrieve` and `classifyMessage`.
- S2: an identical consecutive fail-open reason is announced once in full; repeats are marked `(repeats)` instead of re-announced identically. The fallback never changes: gate errors still retrieve, triage errors still go full.
- S3 (phase B): "un LlmRefused 4xx degrada el gate en el proceso" — after a refusal the gate stops calling the failing small model (always retrieves without gating) with one deterministic notice; zero repeated failing calls.
- S4: "Every behaviour change gets a deterministic eval; prove each test can fail."

## Tasks

- [x] T1 (S1): reason carries provider message in `shouldRetrieve` + `classifyMessage` — route: inline
- [x] T2 (S2): repeat marking for identical consecutive fail-open reasons — route: inline
- [x] T3 (S4): pins — msg visible; two same-failure turns → full once + `(repeats)` — route: inline
- [x] T4 (S3, phase B): degrade gate on LlmRefused 4xx — route: inline
- [x] T5: neighbor suites + rulebook + full nimble test — route: inline
- [x] T-extend (S2 gap): non-exception fail-open paths through the same repeat marking + `resetTriageFailState` seam — route: worker (mwuv6uhf-6-zr1r)

## Log

- L1: user: "seguimos con el siguiente bug" -> chose "A y después B" for the gate fail-open: A quiet notice first, then B fix the cost cause.
- L2: A+B landed inline, test-first (RED observed on both new pins before fix). `errorText` in both fail-open reasons; `(repeats)` marking via module vars reset on clean decisions; `LlmRefused` degrades the memory gate in-process (`gateDegraded`, zero further small-model calls, `resetGateFailState` test seam). Verified: test_memory_live 47/47, test_workflows 41/41, triage/inventory/slice-c/dashboard neighbors green, rulebook 17, full `nimble test` EXIT 0 (2178 OK, 0 FAILED). Triage degrade left out (same pattern, not the reported symptom). No commit per policy.
- L3: S2 extension landed via worker (helpers `gateFailNote`/`triageFailNote`, all fail-open returns routed, `resetTriageFailState` seam; fallbacks unchanged). Verified: test_memory_live 48/48, test_workflows 42/42, rulebook 17, full `nimble test` EXIT 0 (2180 OK, 0 FAILED).
- L4 (2026-11-26, live): probe `hola, que tal` -> `gate · skip — Small talk greeting`, respuesta por vía rápida sin fail-open. El `LlmRefused` anterior fue transitorio (cuota/4xx puntual); triage y gate usan el mismo small model sin tools, así que ese aviso vale para los dos. Decisión: NO degradar triage, se conserva el quick path. Reabrir solo si vuelve un 4xx con su mensaje real.
- Next: cerrado 2026-11-26 — no procede degradar triage tras live limpio; si vuelve el fail-open, capturar la línea `gate ·` y decidir (404 = arreglar `providers.toml`, 400/422 persistente = degradar, 429 = no degradar).
