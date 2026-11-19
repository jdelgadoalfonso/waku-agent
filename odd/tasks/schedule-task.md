# schedule_task fase C2a — núcleo puro + tool, sin ticker

Feature: `schedule_task` en `nim/` como tool viva tras `WAKU_EXPERIMENTAL` (fase C2a: matemática pura de intervalos + store + validación). El enganche del ticker queda para C2b.

## Specs

S1: Scheduler in-app simple. User verbatim: "Scheduler in-app simple"
S2: Intervalo fijo, vive con el proceso, persiste en `.waku/`. User verbatim: "schedule_task in-app simple"
S3: Núcleo puro primero, ticker después. User verbatim: "ok"
S4: Tras `WAKU_EXPERIMENTAL`, reemplaza el stub. User verbatim: "schedule_task in-app simple"

## Tasks

- T1 (S1,S3): matemática pura de intervalos/next-run (inyecta `now`, sin reloj) + tests RED/GREEN — commit: pending
- T2 (S2): tabla `scheduled_tasks` en `db.nim` + store add/list/due/mark-done + tests round-trip — commit: pending
- T3 (S1,S4): tool `schedule_task` (validar-construir, un entry, adaptador live) + registro experimental + quitar stub de `plannedTools` + tests — commit: pending
- T4 (S1-S4): docs que cambien (`docs/roadmap.md`, `docs/benchmarks.md`) + eval determinista (regla 4 AGENTS.md) — commit: pending

## Log

L1: User request verbatim: "continua con la siguiente fase"
L2: User decision verbatim run_command: "Solo lectura con allowlist"
L3: User decision verbatim schedule_task: "Scheduler in-app simple"
L4: User order verbatim: "run_command primero"
L5: User options verbatim: "cuales son las opciones?"
L6: User choice verbatim: "schedule_task in-app simple"
L7: User approval verbatim slice puro: "ok"
L9: C2a done sin commit: `nim/src/schedule.nim` (parseInterval 60s..7d + nextRun/isDue + store + scheduleTask/makeScheduleTaskTool) + `nim/tests/test_schedule.nim` 7/7 GREEN (RED: modulo ausente, addScheduledTask, scheduleTask). Worker `mwnx7dw1-4-qila` cableó registro (stub fuera de `plannedTools` tipado vacío, `makeScheduleTaskTool(db)` en bloque experimental, `test_experimental` sin stubs). Suite final: schedule 7/7 + experimental 11/11 + registry 10/10 + `nim check` OK sin warnings (quitado `import ./wire` sin uso). Docs `roadmap.md`/`benchmarks.md` (C2a vivo, ticker en C2b).
L8: Explorer `gentle-ai-explore mwnwr4kr-3-m970`: stub en `experimental.nim:44-46` (stub maker :423-431); workers `workers.nim:53-58,94-119`, `worker_brief.nim:19-21,28-51`, `waku.nim:708-780,302-322,798-803,112,816-817,336-348`, `delegate.nim:30,60-74,83-86,123-127,247-276`, `supervisor.nim:61+`, `brief.nim:23-37,39-45`; persistencia `db.nim:15-95,97+`, `factstore.nim:121+`, `Makefile:18,38-39`; patrón `run_command.nim:1-7,14-15,51-99,101-136,138-165`, `github.nim:30-32`, `registry.nim:87-97`, `config.nim:196,56-59`; ticker sin hogar (dashboard `4396-4402` dice no scheduler); C2a sin crontab ni resume tras reinicio.
