# run_command fase C1 — solo lectura con allowlist

Feature: `run_command` en `nim/` como tool viva de solo lectura (argv sin shell, allowlist cerrada, workdir acotado), tras `WAKU_EXPERIMENTAL`. `schedule_task` queda para después.

## Specs

S1: Solo lectura con allowlist. User verbatim: "Solo lectura con allowlist"
S2: argv sin shell, workdir acotado, timeout + env-deny reutilizados. User verbatim: "argv sin shell, workdir acotado, timeout + env-deny. Lo seguro."
S3: Tras `WAKU_EXPERIMENTAL`, sale de `plannedTools`. User verbatim: "run_command primero"
S4: `schedule_task` después, no en este slice. User verbatim: "Scheduler in-app simple"

## Tasks

- [x] T1 (S1,S2): allowlist cerrada + ejecutor argv-only sin shell + tests RED/GREEN — commit: 599b79c
- [x] T2 (S2): workdir pin a workspace/cwd validado + timeout + env-deny + errores honestos (124/127) + tests — commit: 599b79c
- [x] T3 (S3): registro tras `WAKU_EXPERIMENTAL` en `registry.nim` + salida de `plannedTools` + tests registro — commit: b1e3ea2
- [x] T4 (S1-S4): docs que cambien (`docs/roadmap.md`, `docs/benchmarks.md`) + eval determinista (regla 4 AGENTS.md) — commit: b1e3ea2

## Log

L1: User request verbatim: "continua con la siguiente fase"
L2: User decision verbatim run_command: "Solo lectura con allowlist"
L3: User decision verbatim schedule_task: "Scheduler in-app simple"
L4: User order verbatim: "run_command primero"
L5: Explorer `gentle-ai-explore mwnvp1f1-1-x2rq`: mapa stubs (`experimental.nim:43-51,435-452`, `registry.nim:88-94`, `config.nim:196`), patrón `delegate_task`/`runProcess` (`tools.nim:22-33,105-140`), sin allowlist existente, propuesta C1/C2.
L6: Spot check `nim/src/tools.nim:105-140`: `runProcess` cierra stdin, deadline mata con 124, binario ausente 127, `env:nil` hereda.
L7: Fase C1 commiteada: 599b79c (módulo+tests) + b1e3ea2 (registro+docs). (regla usuario): `nim/src/run_command.nim` nuevo (allowlist cat/git/grep/ls, git solo diff/log/status, sin shell, workdir pin, timeout 20/max30, env-deny, truncate 8000) + `nim/tests/test_run_command.nim` 9/9 GREEN (RED previo: modulo ausente + /tmp/ws). Registro tras EXPERIMENTAL en `nim/src/registry.nim`, `plannedTools` pierde run_command, `test_experimental` actualizado. Docs `roadmap.md`/`benchmarks.md`. `nim check src/waku.nim` OK.
L8: Verify `gentle-ai-verify mwnweu4a-2-ea50`: B1 workdir escape (`cwd=<root>/..` pasaba `startsWith` por `absolutePath` sin normalizar) + G1 flag-paths/symlinks, G2 overclaim shell/writes, G3 deadcode, G4 sin exit-code. Fix: `validWorkdir` con `normalizedPath` + `expandFilename` (relativo contra root, NUL refuse), git peligroso primero, `-f/--file` y `..` en flags refuse, errores `exit N + 500 chars`, descripcion sin `shell`. Tests 14/14 GREEN + experimental/registry/check OK. Limites en `benchmarks.md`.
L9 (2026-11-27, cierre gap doc): T1-T2 landed en 599b79c (modulo + tests, incluidos los fixes de L8), T3-T4 en b1e3ea2 (registro + `roadmap.md` + `benchmarks.md` + `test_experimental`). El "pending" era stale; sin cambio de codigo, solo se marcan T1-T4 [x] con sus hashes.
