# Limpieza + deuda menor (post-9c/TLS/bridge)

Objetivo: dejar el árbol y `/tmp` limpios y cerrar la deuda menor
documentada que tiene fix claro. Rama
`feature/nim-phase0-skeleton`, base HEAD `f5d5f69`.

## Alcance

- L1. Limpieza (padre): borrar `.gitignore.orig` (marcadores de
  conflicto viejos) + scratch conocido en `/tmp` (binarios
  `test_*`, suites `*_d`, sandboxes `nim*`/`waku-*`, probes,
  logs de las corridas). Solo nombres conocidos, nada ajeno.
- L2. `test_workflows.nim` deja dirs `waku-tri-*` en `/tmp`
  (`:103,173` sin `removeDir`): agregar limpieza + pin.
- L3. 4 seams REST tragan el refusal sin-TLS y responden 0
  (`try/except` en `finally` durante unwinding; pineado en
  `test_tls.nim`): que propaguen. Actualiza esos pines.
  Cambia comportamiento vivo (offline intacto).
- L4. Backoff al poll idle de telegram en el multiplex del
  dashboard (~4 `getUpdates`/s hoy): espera creciente ante polls
  vacíos seguidos, resetea con actividad. Pineado offline.
- L5. `odd/tasks/nim-port.md` sección Landed al día (7d2, 9a/9b/9c,
  bridge, TLS) — debe decir lo que hay, no lo de ayer (regla 9).
- L6. Verificación + commits.

## No-objetivos

- `.codegraph/`, `.pi/` (tooling del entorno, se quedan).
- `nim.yml` en runner real (solo corre con push: es entrega).
- Pin C solo intra-módulo, pump Discord 250 ms, `discordServe`
  vs pump (posturas aceptadas y documentadas, sin cambio).
- Push/PR/merge.

## Tareas

- [ ] L1 Limpieza /tmp + .gitignore.orig (route: inline, padre).
- [ ] L2 removeDir en test_workflows (route: delegated).
- [ ] L3 Propagar refusal en seams REST (route: delegated).
- [x] L4 Backoff poll telegram (route: delegated mur5hd1y-x-8w6a; primer intento murió sin escribir). Checks OBSERVED: parent spot 39/39; worker: RED (seam sin ventana) → GREEN 39/39, full 914 OK, 0 warnings. Idle 250ms ×2^vacías con cap 2000ms; resetea en turn/webhook/Discord no-timeout; browser no resetea. `wait` ahora recibe la ventana (cambio de firma contenido a 2 archivos).
- [ ] L5 nim-port.md Landed al día (route: inline, padre).
- [x] L6 Verificación + commits (route: delegated verify mur5why5-y-qycb). Veredicto ACCEPT-WITH-NOTES. Checks OBSERVED: `nimble test` 914 OK / 0 FAIL (39 suites, 4 corridas idénticas), rulebook 17 passed, cross-count 925 = 914 + 11 flagged-only, finally desnudo confirmado en diff, backoff [250,500,1000,2000,2000,2000] pineado. Notas: task doc untracked (entra al commit), scratch del verificador borrado por el padre.

## Criterios de aceptación

- `git status` sin `.gitignore.orig`; `/tmp` sin nuestro scratch.
- Suite verde con los pines nuevos/actualizados; rulebook 17.
- Docs dicen lo que hay.

## Progreso

- 2026-10-02: documento creado. HEAD `f5d5f69`. L1/L5 del padre
  primero, luego workers secuenciales (un writer a la vez).

## Evidencia de verificación

- (pendiente)

## Siguiente paso

- L1: listar scratch y borrar solo lo conocido. HECHO.

## Commits

- `843f02b` Limpieza de temporales en suites (test_workflows +
  test_integrations).
- `e560477` Refusals que propagan (discord + whatsapp + mcp +
  test_tls).
- `f814943` Backoff idle telegram (dashboard +
  test_supervisor_hookup).
- (este archivo + `nim-port.md`) Docs.
- Assess: limitación conocida con untracked residentes; vía
  cubierta por verify ACCEPT-WITH-NOTES.

## Commits propuestos (cortes por coherencia de archivo)

1. Limpieza de temporales en suites (test_workflows.nim +
   test_integrations.nim: registry + sweep).
2. Refusals que propagan (discord + whatsapp + mcp + test_tls.nim).
3. Backoff idle telegram (dashboard.nim +
   test_supervisor_hookup.nim).
4. Docs (nim-port.md Landed + este archivo).
- Assess: limitación conocida con untracked residentes; vía
  cubierta por verify ACCEPT-WITH-NOTES.

## Residual cerrado después (follow-up de L3)

- `whatsappServe`: el `finally` cerraba `owned` con try/except
  anidado y tragaba el re-raise de listener muerto. Fix igual
  que L3 (close desnudo) + pin de forma en
  `test_live_gateways.nim` (el comportamiento no es pineable
  offline: EMFILE con límite 524288 no se monta en un test).
  Suite 916. Propuesta de mejora del worker: ensanchar el shape
  scan de `test_tls.nim` a "ningún `except` entre `finally:` y
  el fin de su cuerpo" (hoy solo matchea un nivel).
