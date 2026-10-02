# Nim 9c — black-box cross-check (el binario contra los pins Python)

Objetivo: probar el binario `nim/waku` construido como caja negra y
atar las copias a mano a sus originales Python, cerrando la fase 9.
Rama `feature/nim-phase0-skeleton`, base HEAD `6be4700`.

Contrato: aditivo, nunca reemplazo (`nim-port-design.md:94-98`).
Sin tocar `waku/`, `hosted/`, `evals/`. AGENTS regla 4 en espíritu:
el pin debe correr, no skipear siempre.

## Por qué

Dos huecos reales que 9a/9b no cubren: (1) `pythonPinnedGet/Post`
(`dashboard.nim:108,129`) son copias a mano de `PINNED_GET/POST`
(`test_dashboard_routes.py`) que pueden divergir en silencio;
(2) nadie ejecuta el binario construido y compara observables
(exit codes, frases exactas, `--version`) contra la verdad Python.

## Alcance (suite nueva `test_blackbox.nim` + paso en `nim.yml`)

- Pines de proceso (subprocess `osproc`, offline, tmp `WAKU_HOME`):
  `--version` == nimble, `bogus` exit 1 + uso, `mcp` en home
  vacío (frase exacta de `mcp_cli.py:94-96), `connections`
  store fresco/exit 1 con ERROR, `chat` sin claves (exit 1,
  stderr, home no creado), 4 gateways sin credencial (exit 1 +
  primera variable en orden Python), `--help` (contrato propio,
  divergencia declarada).
- Pin de divergencia: `pythonPinnedGet/Post` iguales a los sets
  `PINNED_GET/POST` leídos de `test_dashboard_routes.py`
  (precedente `hosted/test_route_contract.py:26-38`).
- Skip-guard si el binario falta (patrón `test_phase0c.nim:89`,
  `test_embed.nim:96`); default `./waku` con CWD=nim
  (`.gitignore:50` ya lo ignora). `nim.yml`: paso nuevo DESPUÉS
  del build que corre este suite (en `nimble test` skipea sin
  binario; ningún job existente se toca).

## No-objetivos

- `waku dashboard` servido (bloquea en socket, sin contrato
  negro). Cambiar `pythonPinned*` (si divergen, se reporta).
  Eval Python con skip (skipearía siempre en CI). Push/PR/merge.

## Tareas

- [x] 9c-1 Suite `test_blackbox.nim` + paso `nim.yml` (route: delegated muqxsts1-j-d0a4). Checks OBSERVED: parent spot 15/15 OK sin skips; worker: RED (skip sin binario + coma + parser vacío) → GREEN 15/15, full 883 OK, 0 warnings, paso CI idéntico 15/15. Sin divergencia: `pythonPinned*` == PINNED 9+20. Solo 2 superficies tocadas.
- [x] 9c-2 Verificación cierre (route: delegated verify muqykv5j-k-0jyq; el mecanismo se recuperó). Veredicto ACCEPT. Checks OBSERVED por verificador: `nimble test` 883 OK / 0 FAILED, rulebook 17 passed, cross-count 883/883, diff scope exacto (nim.yml +8), status sin mutaciones. Notas no bloqueantes: residuos conocidos.

## Criterios de aceptación

- El binario construido pasa todos los pines negros en el paso
  de CI y en local tras `nimble build`.
- `pythonPinned*` atados a los sets Python: una divergencia futura
  falla en vez de pasar en silencio.
- Regla 8 intacta; cero cambios fuera de las superficies.

## Progreso

- 2026-10-02: documento creado tras exploración
  `gentle-ai-explore muqxputg-i-zwj5`. HEAD `6be4700`. 9c-1 DONE
  (worker muqxsts1-j-d0a4). Suite 883 (868+15). Sin commits.
- 2026-10-02: 9c-2 DONE (verify ACCEPT). 9c completo: 883/883, rulebook 17. Commits: `c79ae45` suite + paso CI, y este archivo (abajo).

## Commits

- `c79ae45` Suite black-box + paso CI (test_blackbox.nim nuevo,
  15 pines; nim.yml +8 con el paso tras el build).
- (este archivo) Registro del landing de 9c.
- Assess: limitación conocida con untracked residentes (6
  resultados idénticos hoy); vía cubierta por verify ACCEPT.

## Evidencia de verificación

- (pendiente)

## Siguiente paso

- Lanzar 9c-1 con `gentle-ai-worker`.
