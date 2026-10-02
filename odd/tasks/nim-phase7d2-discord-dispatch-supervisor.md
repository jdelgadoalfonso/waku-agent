# Nim 7d2 — Discord WebSocket + dispatch + supervisor

Objetivo: cerrar la fase 7 del port Nim con la segunda mitad de 7d: receive Discord por WebSocket (RFC 6455) detrás de `receiveDiscordEvent`, dispatch `waku telegram|discord|whatsapp|voice` en `waku.nim`, y supervisor real en el dashboard. Incluye el hardening diferido de 7d1.

Contrato base: `odd/tasks/nim-phase7-gateways.md` sección 7d2 + Cierre fase 7. Rama `feature/nim-phase0-skeleton`. Base HEAD `4aac622`. Sin push/PR sin pedido explícito.

## Por qué

7d1 dejó los loops de telegram/whatsapp/voz con seams (`telegramPoll`, `TakeConn`) y los `*Starter` que re-arman pero no bombean. Sin 7d2, `waku telegram|discord|whatsapp|voice` sigue en stub (`waku.nim:299-301`), `receiveDiscordEvent` raisea (`discord.nim:178-183`), y el dashboard no supervisa gateways (`buildDashboardDeps` deja `gatewayReload/gatewayStatus: nil`, `serveDashboardCmd` sin hooks).

## Alcance

- Discord: handshake, frames, masking, heartbeat, op 2/10 y `MESSAGE_CREATE` a mano con stdlib, detrás de `receiveDiscordEvent`. `DiscordHandle` + `discordStatus/Stop/Starter` espejo de `discord.py:212-283` y `on_message` `discord.py:141-164`.
- `waku.nim`: cuatro ramas reales antes del stub genérico (precedente `runMcpCmd`). `telegram` → `telegramRun`, `discord` → loop WebSocket, `whatsapp` → `serveWhatsapp` con `take = nil`, `voice` → `voiceMain` con `sessionId = "voice"`, sin supervisor.
- Dashboard: `newSupervisor` con starters telegram/discord/whatsapp + `envFields` (telegram sin const: usar registro `integrations.nim` o añadir `telegramEnvFields`), `reconcile` al arrancar, `supervisorShutdown` al salir, adaptadores `GatewayStatusFn`/`GatewayReloadFn` en `buildDashboardDeps`, tick `telegramPoll` con timeout corto entre requests + `TakeConn` propio para whatsapp. Fallback aceptado: whatsapp con comando propio y solo reportado.
- Hardening 7d1: (a) `voiceio.engineFailure` (`voiceio.nim:177-183`) por `safeException`; (b) guardia nil en `telegramStop` (`telegram.nim:369-379`) y `whatsappStop` (`whatsapp.nim:419-426`).
- Tests: reemplazar pin `test_chat_gateways.nim:171-177` (raisea con "7d"), pineas nuevos de handshake/frames/dispatch/supervisor/tick/orden.

## No-objetivos

- Audio/red/subprocess en tests. Sin dependencias nuevas (regla 3). Sin tocar `hosted/`↔`waku/` (boundary). Sin push/PR/merge. `cli.py` sin unidad propia (`runRepl` ya lo cubre).

## Restricciones

- Single-thread: `telegramPoll` como función, webhook con `TakeConn`. Un turno bloquea el dashboard (postura 8b ya aceptada).
- `env` como `Table`, transportes como procs. Redacción por `safeException`. Verify token como `***`/`none`.
- Un cambio lógico por commit, mensaje sobre el código. Forecast ~450-600 líneas autoradas: estrategia `ask-on-risk` (default); si se supera 400 antes del siguiente commit, preguntar cadena vs single-PR.

## Tareas

- [x] 7d2-1 Discord WS receive + handle (route: delegated gentle-ai-worker muqm80ih-2-4zyv, trigger: multi-file write). Checks OBSERVED: test_discord_ws 53 OK EXIT=0 (parent spot re-run 53 OK), test_chat_gateways 37 OK, full nimble test 790 OK EXIT=0 (worker), warnings ON 0 en ambos suites. Diff +714 tracked + nuevo test ~716 líneas: supera heurística 400, no recortado; estrategia ask-on-risk pendiente antes del commit.
- [x] 7d2-2 Dispatch `waku.nim` 4 ramas (route: delegated muqn52bz-3-ckft). Checks OBSERVED: parent spot `test_cli` desde `nim/` con pines dispatch en verde (telegram/discord/whatsapp/voice rehúsan como Python); worker: `nimble test` 804 OK EXIT=0, `test_cli` 24 OK, `test_discord_ws` 60 OK, warnings 0, `nimble build --forceBuild` EXIT=0. TLS: rechazo honesto (sin `ssl.nim` en Nim 2.3.1, regla 3). README:117 arreglado (regla 9).
- [x] 7d2-3 Supervisor dashboard + tick (route: delegated muqo1rzl-4-9vy6). Checks OBSERVED: parent spot `test_supervisor_hookup` 28 OK; worker: `nimble test` 833 OK EXIT=0, `test_dashboard` 92 OK warnings 0, `nimble build --forceBuild` EXIT=0. Decisiones: `gatewayEnvFields` desde registro (sin const nuevo), Discord supervisado bombea el wire (no llama a `discordServe`), webhook por puerta + `TakeConn`. Diff acumulado ~2000 inserciones tracked + 2 tests nuevos: ask-on-risk antes del commit.
- [x] 7d2-4 Hardening diferido 7d1 (route: delegated muqpt2jj-5-zqri). Checks OBSERVED: parent spot `test_voiceio` cola en verde + `test_live_gateways` sin FAILED/SIGSEGV; worker: voiceio 27 OK, live 30 OK, `nimble test` 839 OK EXIT=0, warnings 0. RED previo: 3 FAILED con secreto + SIGSEGV en `telegramStop` nil. Límite: flag suelto `--token value` sin NAME con sufijo no se redacta (fuera de surfaces).
- [x] 7d2-5 Verificación cierre (route: delegated verify muqqcz3j-6-edml). Veredicto ACCEPT. Checks OBSERVED por verificador: `nimble test` 839 OK EXIT=0 (conteo `[OK]`=839, cross-count `^  test "`=839, 0 FAILED), `nimble build --forceBuild` EXIT=0 0 warnings, `test_rulebook.py` 17 passed. Riesgos 7d2-1/7d2-2 resueltos (README, TLS honesto, pines stub/receive actualizados). Residuales: `.gitignore.orig` con marcadores (no tocar sin autorización), `test_workflows` deja dirs en /tmp, scratch en /tmp listado sin borrar.

## Criterios de aceptación

- `receiveDiscordEvent` ya no raisea; handshake/frames/heartbeat/op2-10/MESSAGE_CREATE pineados offline.
- `waku telegram|discord|whatsapp|voice` con paridad Python salvo loops documentados; pin 4e actualizado explícitamente.
- Dashboard reconcilia al arrancar, apaga al salir, expone status/reload, tick telegram entre requests.
- Hardening (a)+(b) cerrado con tests que fallarían pre-fix.
- Suite verde EXIT=0, 0 warnings con build forzado, regla 9 (task file al día).

## Progreso

- 2026-10-02: documento creado tras exploración `gentle-ai-explore muqm3anx-1-m53g`. HEAD `4aac622` limpio. Pendiente primer write.
- 2026-10-02: 7d2-5 DONE (verify ACCEPT). 7d2 completo y verificado: 839/839, 0 warnings, rulebook 17. PENDIENTE autorización: commits (diff 2141+/67-, ask-on-risk: cadena vs single-PR) + `gentle_review assess` en cada work-unit commit. Push/PR/merge: decisiones tuyas.

## Commits (opción A, cortes por coherencia de archivo)

El harness reescribe el `git diff` crudo como vista de texto, así que
`discord.nim` no se pudo partir por hunks entre 7d2-1 y 7d2-2: el
commit 1 lleva el path Discord entero y el 2 queda solo dispatch.
Mismo contenido total, mismos tests.

- `3e83fd2` Discord WebSocket receive, serve loop y dial seam
  (discord.nim + test_chat_gateways + test_discord_ws nuevo).
  Assess: unassessable (limitación con untracked presentes) → vía
high: self-verificación del worker (790/804 suite) + verify
independiente ACCEPT del alcance completo.
- `2f76c3b` Dispatch telegram, discord, whatsapp y voice desde waku
  (waku.nim + test_cli + README). Assess: unassessable, misma vía.
- `d4a6f63` Supervisor de gateways desde el dashboard
  (dashboard + integrations + test_dashboard + test_supervisor_hookup
  nuevo). Assess: unassessable, misma vía.
- `93fe2ba` Redacción de fallos de motor de voz y guardias en stops
  (voiceio + telegram + whatsapp + test_voiceio +
  test_live_gateways). Assess: unassessable, misma vía.
- (este archivo) Registro del landing de la fase 7d2.

## Evidencia de verificación

- (pendiente) Comandos exactos por tarea en el worker; conteo `grep ^..test` cruzado; `nim c --forceBuild` por suite si hay stale `.o`.

## Siguiente paso

- Lanzar 7d2-1 con `gentle-ai-worker` y superficies exactas.
