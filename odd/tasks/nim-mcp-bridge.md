# Nim bridge concurrente (cierre del follow-up de fase 6)

Objetivo: cerrar el follow-up "bridge concurrente" declarado en
`odd/tasks/nim-phase6-mcp.md:139-142,197-199,214` sin hilos y sin
traicionar el diseño single-thread. Rama
`feature/nim-phase0-skeleton`, base HEAD `d30d573`.

## Por qué A+D y no multiplexar

El ground truth Python es serial: `_connect_all` itera
`for spec in servers` (`mcp_client.py:239-273`), sin `gather` ni
pool. Su "concurrencia" es hilo daemon + event loop para no
bloquear al llamador y para esperar `fut.result(deadline)`
(`mcp_client.py:99-100,127-128`). Portar hilos rompería la
decisión single-thread (precedente 8b, gateways 7d1). Lo fiel es:
(A) declarar el bridge síncrono por diseño + (D) esperar el
`connectionDeadline` de verdad como hace Python (hoy se calcula y
se tira, `mcp.nim:545`). La multiplexación con pump (opción B)
queda como follow-up solo si aparece necesidad real (OAuth 300 s).

## Alcance

- `connectAll` espera por servidor hasta `connectionDeadline` con
  `sleep` inyectable (nuevo seam `SleepFn`; el reloj `nowUnix` ya
  existe) y aborta al vencer. Offline testeable.
- Doc: `mcp.nim` + `nim/README.md:13,195-196` declaran bridge
  síncrono + divergencia cerrada/abierta; el padre actualiza las
  3 líneas del task file de fase 6 (regla 9).
- Sin `std/posix` (portabilidad), sin tocar ids 1/2/3 salvo que el
  diseño lo exija, sin hilos.

## No-objetivos

- Pump multiplexado (B), hilos, `std/posix`. Cambiar `rpcRequest`.
  Push/PR/merge.

## Tareas

- [x] B1 Deadline esperado + bridge síncrono declarado (route: delegated mur02rpc-m-r2dq). Checks OBSERVED: parent spot `test_mcp` 81/81; worker: RED (deadline ignorado + SleepFn inexistente) → GREEN 81/81, full 888 OK, 0 warnings. Riesgo: sleeper nil = espera real (documentado; ningún caller vivo lo hace). Regla 9 por el padre: task file fase 6 actualizado (3 líneas).
- [x] B2 Verificación cierre (route: delegated verify mur118q7-n-flzh). Veredicto ACCEPT. Checks OBSERVED: `nimble test` 888 OK / 0 FAILED, rulebook 17 passed, cross-count 888/888, diff acotado (286+/69- en 4 archivos), sin mutaciones.

## Criterios de aceptación

- Un servidor lento ya no cuelga el arranque: aborta al deadline.
- El README y el task file de fase 6 ya no prometen un bridge
  concurrente pendiente.
- Cero cambios en `waku/`, `hosted/`, `evals/`.

## Progreso

- 2026-10-02: documento creado tras exploración
  `gentle-ai-explore mur00fmd-l-54el`. HEAD `d30d573`. B1 DONE
  (worker mur02rpc-m-r2dq). Suite 888 (883+5). Sin commits.
- 2026-10-02: B2 DONE (verify ACCEPT). Bridge cerrado: 888/888, rulebook 17. Commits: `b3d6084` código + este archivo y fase 6 (abajo).

## Commits

- `b3d6084` Deadline esperado en bridge síncrono (mcp.nim +
  test_mcp.nim + README).
- (este archivo + `nim-phase6-mcp.md`) Cierre documentado.
- Assess: limitación conocida con untracked residentes; vía
  cubierta por verify ACCEPT.

## Evidencia de verificación

- (pendiente)

## Siguiente paso

- Lanzar B1 con `gentle-ai-worker`.
