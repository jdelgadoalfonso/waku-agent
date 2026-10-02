# Nim 9b — meta-evals mirror (repo gates en Nim)

Objetivo: espejar en Nim los invariantes de repo que los evals
Python no cubren (sus globs solo miran `waku/`, `evals/`,
`scripts/`): boundary de imports, unicidad de nombres por módulo y
frescura de las copias de diseño. Rama
`feature/nim-phase0-skeleton`, base HEAD `7a03892`.

Contrato: espejo fiel de `test_rulebook.py:124-158,235-266`,
`test_hosted_boundary.py` (dirección denylist) y
`test_design_system.py:68-88`. Aditivo, nunca reemplazo
(`nim-port-design.md:94-98`). Sin tocar `waku/`, `hosted/`, `evals/`.

## Por qué

`test_rulebook` y `test_hosted_boundary` no escanean `nim/`: un
import a `examples/`/`lab/`/`hosted/` desde Nim, un nombre duplicado
en un módulo o una copia de diseño editada pasarían en silencio.
9a ya cubre versión (`test_version.nim`) y embed==checkout
(`test_embed.nim`): no repetir.

## Alcance (5 pines, un suite nuevo `test_repo_gates.nim`)

- A. `nim/src` + `nim/tests` nunca alcanzan `examples/` ni `lab/`
  (denylist en imports de columna 0 y en literales; `waku/` y
  `evals/` permitidos: son rutas de datos reales).
- B. Ningún import de `nim/` contiene componente `hosted`.
- C. Ningún módulo define dos veces un nombre top-level
  (`proc/func/template/macro/type/const/let/var` en columna 0),
  ignorando declaraciones adelantadas sin cuerpo y permitiendo
  overloads con firma distinta (contrato Nim, no Python).
- D. Las copias de diseño igualan al master por sha256
  (espíritu `test_design_system.py:68-77`; leer `SOURCE.md`).
- E. La tabla CI de AGENTS.md nombra el gate nim (guarda la fila
  que 9a-3 agregó).

Rutas servidas: NO duplicar (pineadas en 8a). Rutas Python-side
(licencias, emoji, caps de docs, CSS/JS): NO duplicar (deriva).

## No-objetivos

- Cambios en `src/` salvo que un pin revele una violación real
  (entonces se reporta, no se esconde). Nuevas dependencias.
  Push/PR/merge.

## Tareas

- [x] 9b-1 Suite `test_repo_gates.nim` con los 5 pines (route: delegated muqwnu5l-e-3a82, single-file). Checks OBSERVED: parent spot 14/14 OK; worker: RED con violación plantada (4 FAILED) → GREEN 14/14 ×3 corridas, full 868 OK, 0 warnings, verde desde `/` y `/tmp`. Cero ediciones en `src/` (los 3 pares homónimos son overloads/forward-decl legítimos). Solo lectura sobre `design/`.
- [x] 9b-2 Verificación cierre (FALLBACK, sin verificador independiente: `gentle-ai-verify` cayó 3 veces seguidas sin producir salida). Checks del padre, todos observados: `nimble test` 868 OK / 0 FAILED, `test_repo_gates` 14/14, rulebook 17 passed, cross-count 868/868, `git diff` vacío (cero tracked modificados). Veredicto: ACCEPT por vía fallback (más débil que independiente: el worker aportó RED→GREEN + suite completa, el padre re-ejecutó todo).

## Criterios de aceptación

- Los 5 invariantes pineados offline, sin red ni subprocess.
- Cero cambios en `waku/`, `hosted/`, `evals/`, `examples/`, `lab/`.
- Regla 8 intacta (solo lectura sobre `design/`).

## Progreso

- 2026-10-02: 9b-1 DONE (worker muqwnu5l-e-3a82). Suite 868 (854+14). Sin commits.
- 2026-10-02: 9b-2 DONE por fallback (verify cayó 3×). 9b completo: 868/868, rulebook 17. Commits: `038b332` suite + este archivo (abajo).

## Commits

- `038b332` Pines repo-gates en Nim (test_repo_gates.nim nuevo,
  14 tests). Sin verificación independiente disponible (3 caídas
  del mecanismo): evidencia del worker (RED→GREEN + suite) +
  re-ejecución completa del padre, registrado como fallback.
- (este archivo) Registro del landing de 9b.

## Evidencia de verificación

- (pendiente)

## Siguiente paso

- Lanzar 9b-1 con `gentle-ai-worker`.
