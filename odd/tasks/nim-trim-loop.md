# Nim port — trim del loop (shrink_seen + shrink_read encadenados)

El loop reenvía la conversación entera en cada llamada, así que un tool
result grande viaja en cada iteración posterior a la que lo produjo
(upstream 2026-10-05: un turno treg de 8 llamadas envió 626.5k tokens para
8.4k de salida). El port tiene el hueco hoy: `runLoop` no toma `trim`,
`reports.nim` no tiene `digest` ni `shrink_read`, y `app.nim` no encadena.

## Specs

- **S1** (regla shrink_seen, verbatim upstream):
  > Cut each long tool result the model has already read, in place.

- **S2** (orden del chain, verbatim upstream):
  > One `trim` that runs `steps` in order. app.py runs reports.shrink_read first, so an earlier report becomes its digest rather than its first KEEP_CHARS characters.

- **S3** (regla shrink_read + digest, verbatim upstream):
  > Cut each whole report the model already read to its digest.

  > An earlier report in at most `limit` characters: its title, its Summary bullets and its waku-metrics tiles ("key numbers").

## Qué se portea (ground truth: `origin/main:waku/loop/trim.py`, `waku/loop/agent.py`, `waku/memory/reports.py`, `waku/app.py`)

- `shrink_seen`: solo `messages[:-1]` (lo newest nunca se toca); solo
  `role == "user"` con `content` lista de bloques `type == "tool_result"`
  con `content` str; `len > LONG_CHARS (4000)` → `text[:KEEP_CHARS (2000)]`
  + `NOTE` con `{total:,}`. La traza guarda todo entero (fuera del trim).
  Cortado una vez: un resultado ya cortado es más corto que LONG y no se
  vuelve a cortar.
- `chain(*steps)`: un `trim` que corre los pasos en orden.
- `digest(body, limit = DIGEST_CHARS (1500))`: título + bullets de Summary
  + línea `Numbers: label: value (note); ...` desde tiles `waku-metrics`
  (salta tiles cuyo label matchee `cost of (this|the) (run|turn|report|research)`);
  si pasa `limit`, corta a `limit-1 + "…"`. `find` cae a
  `Report(title="Research report")` cuando no hay marker.
- `shrink_read`: solo `messages[:-1]`; el bloque debe contener MARKER y
  `len > 2*DIGEST_CHARS`; `_shrunk` parsea JSON (`{"memory": {...}}` o el
  dict directo), exige `body` con marker, conserva solo
  `id/kind/scope/created_at` + `body = digest + "\n\n" + TRIMMED`
  (`[The rest of this report was cut from the context after you read it; waku_memory_memory_get returns it whole again.]`);
  JSON inválido o sin reporte → deja intacto.
- `run_loop`: `trim` se llama solo cuando `iteration > 1`; `None` deja
  `messages` como están. `app.py` encadena
  `trim.chain(reports.shrink_read, trim.shrink_seen)`.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `trim.nim` puro: `LONG_CHARS/KEEP_CHARS/NOTE`, `shrinkSeen`, `chainTrim` + pins (corta solo `[:-1]`, deja ≤4000, newest intacto, no-tool_result intacto, cortado no se recorta, chain en orden) | S1, S2 | test-first, suite offline | work unit |
| T2 | `digest` + `shrinkRead` en `reports.nim` + pins (digest título+bullets+numbers, cap 1500 con …, salta run-cost, shrink solo `[:-1]` con marker y >3000, conserva id/kind/scope/created_at, inválido intacto) | S3 | test-first, pins | work unit |
| T3 | Plomería: `runLoop` acepta `trim` (solo `iteration > 1`, nil = actual) + `runFullTurn` encadena `shrinkRead` primero y `shrinkSeen` después; el scripted de 2 iteraciones observa el corte | S1, S2, S3 | test-first, pins | work unit |
| T4 | Docs que la unidad vuelve falsos (regla 9): comentarios del módulo + línea en `nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Cambiar la traza: guarda todo entero (Python `waku/ops/tracing.py`); el
  port no recorta nada persistido, solo el contexto reenviado.
- `slot_gate`/jev, `remember`/`mark_synced` (divergencias previas, no esta
  unidad).
- Reembolsar, repromptear o medir tokens ahorrados más allá del corte.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: resultado largo en `messages[0]` con newest corto se corta a
  `2000 + NOTE` con el total formateado; `≤4000` intacto; newest largo
  intacto; bloque no-tool_result intacto; correr dos veces no cambia la
  segunda; `chain` corre `shrinkRead`-primero en el orden dado.
- **T2**: reporte en `memory.get` de `messages[0]` >3000 se vuelve digest +
  TRIMMED conservando id/kind/scope/created_at; ≤3000 o sin marker intacto;
  JSON inválido intacto; digest respeta cap y salta run-cost.
- **T3**: `runLoop` con script de 2 iteraciones llama al trim antes de la
  segunda y deja `messages` como hoy con `trim = nil`.
- **T4**: `rg -n "shrinkSeen|shrinkRead" nim/src/trim.nim nim/src/reports.nim nim/src/loop.nim nim/src/app.nim` documenta fuente y límites.

## Log

- **L1** (usuario, orden aceptado): "Sí, vamos con trim" (2026-10-06).
- **L2** (investigación): el hueco existe hoy — `runLoop` sin `trim`,
  `reports.nim` sin `digest`/`shrink_read`, `app.nim:runFullTurn` sin
  cadena. Ground truth en `origin/main:waku/loop/trim.py` (63 líneas),
  `agent.py:84-106`, `reports.py:shrink_read/_shrunk/digest`, `app.py:237-238`.
- **L3** (decisión de implementador): `trim.nim` nuevo puro sobre
  `JsonNode` (mensajes Anthropic-shape del loop); `digest/shrinkRead` en
  `reports.nim` espejando `_shrunk`; `runLoop` toma `trim` opcional nil por
  defecto para no romper llamadas actuales; `runFullTurn` encadena
  `shrinkRead` primero como upstream. `shrinkSeen`/`shrinkRead` son procs
  planos y `varargs[Trim]` no los re-envuelve solo: el call site usa
  `toTrim` una vez, explícito.
- **L4** (cierre, T1-T3): suite completa **1324 OK, 0 FAILED** (+11 sobre
  recalled: 5 de trim — 3 shrink_seen + 1 chain + 1 toTrim — , 5 de reports
  — 3 digest + 2 shrink_read — , 1 hook del loop). T4 documenta la fuente
  y el límite en los módulos y el aterrizaje en `nim-port.md`.
