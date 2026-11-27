# schedule ticker C2b — vencidos ejecutan brief y reagendan

Feature: ticker C2b en `nim/` tras `WAKU_EXPERIMENTAL`. Revisa vencidos en el turno del chat y en el multiplex del dashboard/gateway; cada vencido corre su turno headless y se reagenda. Sin crontab, sin resume tras reinicio (lo no corrido se vuelve vencido y corre al volver).

## Specs

S1: Revisa en chat + multiplex. User verbatim: "Chat + multiplex"
S2: Al vencer ejecuta brief y reagenda. User verbatim: "Ejecuta brief y reagenda"
S3: Núcleo puro con runner inyectado; el live usa la maquinaria worker existente. User verbatim: "vamos con el ticker C2b"

## Tasks

- [x] T1 (S3): `tickDue` puro en `schedule.nim` (due + runner inyectado + reagenda `now+interval`) + tests RED/GREEN — commit: 517ed27
- [x] T2 (S2): runner live brief via maquinaria worker (`delegateArgv` + `defaultWorkerRunner`, `--role worker --agent brief`) + tests con seams — commit: 517ed27
- [x] T3 (S1): hooks en turno del chat y paso del multiplex + tras `WAKU_EXPERIMENTAL` + tests — commit: 517ed27
- [x] T4 (S1-S3): docs que cambien (`docs/roadmap.md`, `docs/benchmarks.md`) + eval determinista (regla 4 AGENTS.md) — commit: b1e3ea2

## Log

L1: User request verbatim: "vamos con el ticker C2b"
L2: User host verbatim: "Chat + multiplex"
L3: User fire verbatim: "Ejecuta brief y reagenda"
L5: Verify `gentle-ai-verify mwnxxsix-8-z8lh`: sin bloqueadores (S1-S3 PASS); hallazgos de honestidad aplicados: reloj tras el gate en `beforeTurn`, `getAppFilename` en try con línea misconfigured, docs con inanición/bloqueo ~93s/reapertura de DB, import json sin uso fuera. Reverde: schedule 20/20 + registry + experimental + checks waku/dashboard OK.
L6: Commits: 517ed27 (ticker+hooks) + b1e3ea2 (registro+docs).
L4: Explorer `mwnwr4kr-3-m970`: sin ticker hoy; `workers.nim:53-58,94-119`, `waku.nim:708-780,302-322`, `delegate.nim:123-127,247-276`, `supervisor.nim:61+`, `dashboard.nim:4396-4402` (dice no scheduler), `db.nim:15-95`, store `factstore.nim:121`, patrón `run_command.nim`.
L7 (2026-11-27, cierre gap doc): T1-T3 landed en 517ed27, T4 en b1e3ea2 (`roadmap.md` con `schedule_task` vivo + `benchmarks.md` con los límites); los evals deterministas viajaron con el código en 517ed27. El "pending" era stale: el fichero se creó en el mismo 517ed27, que también trae C2c. L5-L6 verificados contra HEAD: reloj dentro del gate en `beforeTurn`, `getAppFilename` en try con línea misconfigured, y `test_schedule.nim` 28/28 = 20 pins de C2b + 8 de C2c. Sin cambio de código, solo se marcan T1-T4 [x] con sus hashes.
