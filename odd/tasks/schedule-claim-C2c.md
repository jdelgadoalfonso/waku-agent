# schedule claim C2c — at-most-once con claim atómico

Feature: claim atómico en `nim/` tras `WAKU_EXPERIMENTAL`. Dos loops (chat + multiplex) ya no disparan la misma fila: un `UPDATE` reclama vencidos con dueño + lease, el tick solo corre lo reclamado por él, y un crash libera por lease expirado en vez de re-disparar para siempre.

## Specs

S1: Claim atómico con dueño + lease. User verbatim: "vamos con el C2c"
S2: Sin doble disparo entre procesos; crash se recupera por lease. User verbatim: "vamos con el C2c"
S3: Migración aditiva (columnas con default), sin reescribir datos. User verbatim: "vamos con el C2c"

## Tasks

- T1 (S1,S3): columnas `claimed_at`/`claimed_by` en `schemaStmts` + `migrate()` + `claimDueTasks` + tests RED/GREEN (dos dueños, lease expirado) — commit: pending
- T2 (S1,S2): `tickDue` corre solo lo reclamado; fallo/crash deja lease que expira; tests — commit: pending
- T3 (S1-S3): docs que cambien (`docs/benchmarks.md` límites) + suite verde + verificación independiente (migración) — commit: pending

## Log

L1: User request verbatim: "vamos con el C2c"
L2: Propuesta previa aceptada (mem `odd/schedule-ticker-C2b/tasks`): "C2c (at-most-once con claim atómico)".
L3: Límite documentado que lo motiva: "no at-most-once (chat and dashboard can fire the same row twice; crash between run and reschedule re-runs)".
L4: Diseño: `UPDATE ... SET claimed_at=now, claimed_by=owner WHERE next_run <= now AND (claimed_at=0 OR claimed_at < now-lease)` + `SELECT WHERE claimed_by=owner AND claimed_at=now`; reschedule limpia el claim; lease 300s (> ~93s peor caso por tick).
L5: Verify `gentle-ai-verify mwnyka1w-a-5nf7`: S1-S3 PASS sin bloqueadores (28/28 + registry + checks limpios). Remates aplicados: contrato owner único por llamada, invariante lease > maxFire×~31s, reschedule fallido visible en la línea, wording crash mid-run en benchmarks. Reverde 28/28.
