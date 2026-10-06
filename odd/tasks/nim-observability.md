# Nim port — GET /api/observability (la página lee sus trazas)

El dashboard Nim no tiene la ruta: la página Observability (turnos como
trazas, herramientas por fuente, memoria, spend, evals) no puede dibujar
nada. Upstream la sirve desde los traces y el ledger del propio home
(`observability.payload`), y la mitad de lectura (`read_events`,
`group_turns`, `build_turn`, secciones) es la misma base que la ruta del
juez usará después.

## Specs

- **S1** (agrupar, verbatim upstream):
  > Events between `turn_start` and `turn_end`, one dict per turn, oldest first. The same grouping `dashboard.collect()` has always used, so a trace written before spec 011 splits into the same turns.

- **S2** (una fila, verbatim upstream):
  > One waterfall row from one trace event, or None for an event the waterfall does not draw (graph bookkeeping).

- **S3** (el payload, verbatim upstream):
  > Everything the Observability page draws, in one answer.

- **S4** (la ruta, verbatim upstream):
  > Spec 012: the Observability page's turns, tools, memory, spend and evals, read from this home's traces and ledger only.

## Qué se portea (ground truth: `origin/main:waku/ops/observability.py` mitad página + `waku/ops/dashboard.py:/api/observability`)

- `observability.nim` nuevo (la mitad página; el núcleo v2 ya vive en
  `observe.nim`): `WINDOWS` + `window_start`/`_in_window`, `read_events`
  (eventos + errores de encoding + archivos, oldest first),
  `group_turns`, `preview` (+`OUTPUT_CHARS`), `_step` (gate/llm/tool/
  consolidation/report/receipt/triage/route; grafo = None),
  `_score` + `_stored_scores` (solo stored: code/judge/human por
  `turn_id`), `build_turn` (steps, tiempos, dólares, memoria, grafo,
  hotspots, errores, story), `story`/`hotspots`/`turn_errors`/
  `_graph`/`_group_loops`, `tool_stats`, spend (`spend_items`,
  `_charged_receipts`, `_ledger_rows`, `spend_totals`, `spend`,
  `spend_by_day`, `by_model`, `usage_summary`), `summary`,
  `memory_per_turn`, `evals_info` (conteo `evals/`, `eval_report.json`,
  historial; release opcional), `TURN_CHECKS` + `your_turns`,
  `payload` (mismas claves; `judge_offer: null` sin modelo juez).
- Ruta `GET /api/observability[?window=7d]` en `dashboard.nim` (ventana
  inválida = `7d`, como upstream): `observability_data(window)` sobre el
  home del server. Listas `pythonPinnedGet` + eval de contrato al día.
- `scores` de cada turno = solo stored: `run_checks` (los cinco checks
  de código, spec 015 A) llega con la unidad turn-evals; hasta entonces
  sus filas leen n/a. `judge_offer` null por la misma razón.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | Lectores puros: ventanas, `read_events`, `group_turns` + pines (errores, unfinished, pre-011) | S1 | test-first, suite offline | work unit |
| T2 | Vista de turno: `preview`, `_step` por kind, scores stored, `build_turn` + story/hotspots/errores/grafo + pines | S2 | test-first, pins | work unit |
| T3 | Secciones + `payload`: tools, spend, summary, memory, evals_info, your_turns + pines | S3 | test-first, pins | work unit |
| T4 | Ruta GET + `window` + listas pineadas + pines de dashboard | S4 | test-first, pins | work unit |
| T5 | Docs que la unidad vuelve falsos (regla 9): headers + línea en `nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Los cinco checks (`run_checks`, spec 015 A), `judge_offer` con modelo,
  y `POST /api/turn-evals/judge` → unidad turn-evals (siguiente).
- `release_info`/autodeploy, hosted, `collect()` completo de `/api/data`.
- Re-escribir historia: trazas viejas se leen tal cual (describe ya sabe).

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: jsonl con líneas rotas → eventos + 1 error + archivo listado;
  turn_start sin turn_end → unfinished; turn_end sin start se ignora;
  ventana `30d`/basura.
- **T2**: cada kind dibuja su fila y grafo no; llm sin costo estima;
  tool waku_memory → kind memory + query; scores stored por turn_id;
  story/hotspots/errores sobre un turno armado.
- **T3**: `payload` trae todas las claves; tools agrupa treg/memoria;
  spend suma un total; turns newest-first capados; evals cuenta
  `evals/` o null sin checkout.
- **T4**: `GET /api/observability?window=garbage` responde 200 con
  payload de `7d`; ruta pineada en GET + contrato.
- **T5**: `rg -n "observability" nim/src/dashboard.nim` documenta
  fuente y límites.

## Log

- **L1** (usuario): "Rutas dashboard" (2026-10-06) — último HIGH.
- **L2** (investigación): el hueco existe hoy — sin ruta ni lectores.
  Ground truth en `observability.py` (mitad página, ~líneas 319-1110) +
  ruta en `dashboard.py:1090`. `preview` se portea aquí (era non-goal
  de trace-v2). `judge_*` y `run_checks` quedan fuera a propósito.
- **L3** (decisión de implementador): `observability.nim` nuevo (la
  página; el núcleo sigue en `observe.nim`); scores stored-only hasta
  turn-evals; `judge_offer` null sin modelo (misma forma, sin ofertas).
