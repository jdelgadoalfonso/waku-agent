# Nim 9a — packaging (binario único)

Objetivo: cerrar el packaging del port Nim para que el binario sea
único y distribuible: assets embebidos en compilación, una sola
fuente de versión, `task test` declarado, target de build y gate en
CI. Sin dependencias nuevas (regla 3). Rama
`feature/nim-phase0-skeleton`, base HEAD `ecfbd74`.

Contrato: `docs/nim-port-design.md:46-47` (embed por
`include`/`staticRead`, aditivo nunca reemplazo), `:79-80` (judge
evals quedan Python-only), `LICENSE-BRAND:23` (design incluido sin
modificar), AGENTS.md reglas 3/8/9. Alcance elegido por el usuario:
packaging primero (meta-evals y black-box quedan para 9b/9c).

## Por qué

Fase 8 dejó el embed como "phase-close decision, still pending"
(`dashboard.nim:187-188`: sirve `waku/ops/static/` desde disco). Sin
embed no hay binario único. Además hay dos fuentes de versión
(`waku.nimble:7` `0.0.1-phase0` vs const en `src/waku.nim`), el
mismo defecto que `test_version.py` prohíbe en Python, y `task test`
no está declarado (depende de auto-descubrimiento).

## Alcance

- Embed en compilación de `waku/ops/static/` vía `staticRead`
  (generado desde el checkout, nunca editado: regla 8). Si un asset
  no puede embeberse (tamaño, formato), se documenta la excepción
  en el mismo módulo, no se deja en silencio.
- Versión de fuente única: el const de `waku.nim` manda y el nimble
  lo referencia, o viceversa con un solo punto de edición. Formato
  semver válido (`\d+\.\d+\.\d+`, espíritu de `test_version.py:36`).
- `task test` declarado en `waku.nimble` (hoy solo
  version/author/description/license/srcDir/bin/requires).
- Build documentado y repetible: target en `Makefile` + verificar si
  hay job nimble en `.github/workflows/` (el mapeo no lo confirmó);
  si falta, añadirlo solo si no rompe la tabla CI de AGENTS.md.
- Agujero TLS declarado: sin `ssl` el binario no abre
  `wss://gateway.discord.gg` ni HTTPS directo; el packaging lo deja
  por escrito en `nim/README.md`, no lo esconde.

## No-objetivos

- Nuevas dependencias ni `ssl` (regla 3). Judge evals (Python-only
  por diseño). Mirror meta-evals (9b) y cross-check black-box (9c).
  Push/PR/merge (decisiones tuyas).

## Tareas

- [x] 9a-1 Embed de assets en compilación (route: delegated muqtdt1a-9-gy4t, trigger: multi-file + archivo grande; primer intento muqsmfoh murió sin escribir, retry limpio). Checks OBSERVED: parent spot `test_embed` 11 OK; worker: full 850 OK EXIT=0, build forzado 0 warnings, prueba runtime con binario sin checkout (sha256 idénticos, 404 en /static/nope.js). 55 ficheros embebidos, checkout solo leído, `design/` intacto. Riesgo anotado: compilar exige checkout (el binario no); embed vacío = 404 documentado.
- [x] 9a-2 Versión de fuente única + semver (route: delegated muqup7d4-a-l4pt). Checks OBSERVED: parent spot `test_version` 4/4 OK; worker: full 854 OK, warnings 0, triangulación 9.9.9 mueve ambos consumidores. Dirección: el nimble manda (`0.0.1`, sin sufijo) y `waku.nim` deriva por `staticRead` (nimble cachea por mtime del manifest; paquete instalado sin `src/` al lado). Respuesta al worker: la frase del README la escribe 9a-3 (opción a).
- [x] 9a-3 `task test` + Makefile + CI (route: delegated muqv89jc-b-uk59). Checks OBSERVED: `nimble tasks` lista `test`; parent: rulebook 17 passed tras fixes. Worker: `nimble test` 854 OK + `make nim-test` 854 OK + `nimble build` 0 warnings + `--version` 0.0.1 + `nimble check` válido. Nuevo `.github/workflows/nim.yml` (job aparte, ningún job existente tocado; toolchain no ejecutable offline). Regla 9 por el padre: fila nim en AGENTS.md (97 líneas, bajo el cap) + filas make en docs/commands.md. Artefacto stray del worker borrado por el padre.
- [x] 9a-4 Verificación cierre (route: delegated verify muqvnvta-c-lakq). Veredicto ACCEPT-WITH-NOTES. Checks OBSERVED: `nimble test` 854 OK EXIT=0 (cross-count 854/854), build forzado 0 warnings, rulebook 17 passed, binario sin checkout con sha256 idénticos + matriz 404, `nimble tasks` lista test, `make -n` OK, AGENTS.md 97 líneas, `--version` 0.0.1. Notas no bloqueantes: residuos conocidos, build requiere checkout por diseño, nim.yml sin correr en runner real.

## Criterios de aceptación

- `nim/waku` corre con `waku/ops/static/` movido de lugar
  (embed real, no path dependiente).
- Una sola edición cambia la versión en binario y nimble.
- `nimble test` y build documentados y repetibles desde cero.
- Regla 8 intacta (nada editado bajo `design/`).

## Progreso

- 2026-10-02: 9a-1 DONE (worker muqtdt1a-9-gy4t). Suite 850 (839+11). Sin commits.
- 2026-10-02: 9a-4 DONE (verify ACCEPT-WITH-NOTES). 9a completo: 854/854, 0 warnings, rulebook 17, binario sin checkout probado. PENDIENTE autorización: commits (propuesta abajo). Push/PR/merge: decisiones tuyas.

## Commits (cortes por coherencia de archivo)

El harness no permite partir por hunks: `waku.nimble` (versión 9a-2
+ task 9a-3) y `nim/README.md` (embed 9a-1 + build 9a-3) van enteros.
Assess por corte: unassessable (misma limitación con untracked
residentes que en 7d2) → vía high cubierta por self-verificación
+ verify independiente ACCEPT-WITH-NOTES.

- `091ac24` Embed del frontend en el binario (dashboard.nim +
  test_embed.nim nuevo).
- `cba5fdc` Versión desde el manifest + `task test` declarado
  (waku.nimble entero + waku.nim + test_version.nim nuevo).
- `35f913a` Targets, CI y docs (Makefile + nim.yml nuevo + README
  + AGENTS.md + docs/commands.md).
- (este archivo) Registro del landing de 9a.

## Evidencia de verificación

- (pendiente)

## Siguiente paso

- Lanzar 9a-1 con `gentle-ai-worker` y superficies exactas.
