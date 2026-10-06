# Nim port — read-first con digests (brain lee el reporte entero vía get)

Un turno de research que encuentra un reporte anterior lo pone entero en el
prompt desde el snippet del search, y el modelo encima lo vuelve a pedir
entero con `memory_get` (upstream 2026-10-05: 328.5k tokens de entrada por
tres reportes que viajaban en cada llamada). El port tiene el hueco hoy:
`readFirst` no tiene `get`, no hay digests y el contexto lista cada hit
como bala plana con el texto recortado a 600.

## Specs

- **S1** (el paso get, verbatim upstream):
  > With `get`, each report found is read once and put in as its digest.

- **S2** (la lectura de un reporte, verbatim upstream):
  > One earlier report's digest, read with memory.get, or "" when the read failed or the memory is not a report.

- **S3** (el bloque del prompt, verbatim upstream):
  > The block the model reads before it researches. Reports first, since a report is the thing to start from, then everything else, newest first.

- **S4** (el digest, ya portado en trim, se reutiliza):
  > An earlier report in at most `limit` characters: its title, its Summary bullets and its waku-metrics tiles ("key numbers").

## Qué se portea (ground truth: `origin/main:waku/memory/brain.py` 207 líneas)

- `read_first(message, search, get=None)`: dos searches igual que hoy
  (sin cambios de scopes); con `get`, cada reporte encontrado se lee UNA
  vez (como máximo `REPORT_LIMIT = 3`) y se guarda su digest;
  sin `get` = comportamiento actual. Fallo del search o del get = se salta,
  el snippet hace de suplente, el turno nunca falla por esto.
- `_report_digest(get, id)`: parsea la respuesta; no-dict, fallo o cuerpo
  sin marker → `""`.
- `used`: `{id, text, created_at[:10], kind, report, title}` (title solo
  para reportes, `""` si no hay `# `).
- `calls`: un evento por search con `read_first: true` (la forma que el
  loop emite para las propias llamadas del modelo, más esta marca).
- `context(used, digests)`: reportes primero (estable), luego resto,
  newest-first dentro de cada grupo; reporte =
  `- Report "título"|an earlier report, saved {when} (memory {id}): ` más
  `its summary:` + digest indentado, o el snippet si no hubo digest;
  resto = `- {when}: {text} (memory {id})`; heading con
  `(from Waku Memory, searched before this turn; each item has the date
  it was saved):`; footers `Start from this...` + la nota de
  `memory_get` cuando hay al menos un reporte. Vacío = `""`.

## Mapeo Engram (divergencias ya documentadas, se extienden)

- `get` = tool `engram_mem_get_observation` del registry ya conectado
  (verificado vivo: existe y responde); `brainBackendFor` lo recoge igual
  que el search; ausente = `get` nil = comportamiento actual.
- La respuesta del get es `{"result": "<texto completo>"}` (verificado
  vivo contra id 440), no `{"memory": {...}}`: el digest sale de `result`
  (o `memory.body` en forma Waku); sin marker al inicio → `""`.
- El search devuelve filas de texto con id `#N`: el get pide `{"id": N}`
  (entero, `#` fuera); id no numérico = se salta localmente (el snippet
  suple, sin llamada fallida).
- Una fila `(discovery)` ES un reporte (equivale a `kind == semantic`):
  sin esta regla ningún hit Engram llegaría al digest, porque las filas
  nunca traen el marker. `(decision)` y demás siguen sin serlo.
- `created_at` de filas sigue `""` (divergencia previa: el texto del
  reporte no trae fecha); `date unknown` en el contexto entonces.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `get` en `BrainBackend` + `reportDigest` puro en `brain.nim` + `brainGetTool` y recojida en `brainBackendFor`; pines (conecta/desconecta, forma Waku + forma Engram, fallo/inválido/sin-marker → `""`, `#12` → `{"id": 12}`, id no numérico no llama) | S2 | test-first, suite offline | work unit |
| T2 | `readFirst` con `get`: lee como máximo 3 reportes, guarda `digests`, `used` con `title` + `created_at[:10]`, `calls` con `read_first: true`; sin `get` = pines actuales; fallo del get = snippet | S1, S2 | test-first, pins | work unit |
| T3 | `context` con digests: reportes primero + newest-first, fechas, footers, nota `memory_get`; actualiza los pines planos actuales | S3 | test-first, pins | work unit |
| T4 | Docs que la unidad vuelve falsos (regla 9): header del módulo + línea en `nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- `duration_ms` en los calls (lo toca la unidad de trazas spec 012, que
  es dueña de los cambios de forma de eventos).
- Cambiar searches, scopes o `match_mode` (divergencia Engram vigente).
- `app.nim`: el `get` viaja dentro del backend, `runFullTurn` no cambia.
- Re-pedir el reporte cuando el digest ya está (una lectura por reporte).

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: registry con `engram_mem_get_observation` conecta `get`, sin él
  es nil; `{"memory": {"body": marker...}}` y `{"result": marker...}`
  digieren; excepción/JSON inválido/cuerpo sin marker → `""` sin llamar
  de más; `"#12"` pide `{"id": 12}`; `"abc"` no llama.
- **T2**: hit reporte → un get con su id y `digests[id]` = digest; get que
  falla → `used` con snippet y sin digest; no-reporte → ningún get;
  4 reportes → 3 gets; `used[0]` con `title`, `created_at` cap 10,
  `calls[].read_first == true`; backend sin `get` = suite actual.
- **T3**: reporte viejo + hecho nuevo → reporte primero aunque sea más
  viejo; newest-first dentro de grupo; `its summary:` indentado cuando hay
  digest, snippet cuando no; footers presentes; `used` vacío = `""`.
- **T4**: `rg -n "digests|reportDigest" nim/src/brain.nim` documenta
  fuente y límites.

## Log

- **L1** (usuario): "adelante" (2026-10-06) — lo siguiente del orden.
- **L2** (investigación): el hueco existe hoy — `readFirst` sin `get`,
  sin `digests`, contexto plano. Ground truth en
  `origin/main:waku/memory/brain.py` + `tools/waku_memory.py:get_via`.
  Forma del get verificada VIVA contra `engram mcp`
  (`mem_get_observation` existe; respuesta `{"result": texto}`).
- **L3** (decisión de implementador): el `get` viaja en `BrainBackend`
  (como `search`), así `app.nim` no cambia; `digest` se reutiliza de
  `reports.nim` (portado en trim); fila `(discovery)` = reporte;
  `duration_ms` queda para la unidad de trazas.
