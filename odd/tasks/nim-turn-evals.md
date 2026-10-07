# Nim port — turn evals (los cinco checks + el juez bajo demanda)

Los `scores` de cada turno hoy son solo stored y `judge_offer` es null:
la página Evals no puede calificar un turno ni ofrecer el botón
"Judge this turn". Upstream califica cada turno al leerlo (spec 015) y
el juez corre solo cuando la persona lo pide, escribiendo un evento
`score` que la siguiente lectura recoge.

## Specs

- **S1** (los checks, verbatim upstream):
  > Five **code checks** are pure functions of one turn's trace events. Each
  > answers pass (1), fail (0) or n/a (None) with a one-line note. The page runs
  > them every time it reads the traces (`observability.build_turn`), so an old
  > turn is graded the first time the page opens, and a fixed check re-grades
  > every turn at once. Nothing is written to disk for a code check.

- **S2** (el juez, verbatim upstream):
  > One **AI-judge check** runs only when a person presses "Judge this turn".
  > It asks the small model of the provider in use whether the reply answers
  > the question and stays grounded in the tool outputs. Its answer costs money
  > and can differ twice, so it is written once, as a `score` trace event.

- **S3** (los cinco, verbatim upstream):
  > spend_claim: the reply's spend matches the trace; one_report: a research
  > turn saves exactly one report; grounded_numbers: the numbers in the reply
  > come from a tool, memory or the message; errors_handled: every failed tool
  > call was retried or mentioned; under_budget: the turn cost less than
  > WAKU_TURN_BUDGET_USD (default $1.00).

- **S4** (la ruta, verbatim upstream):
  > POST /api/turn-evals/judge {turn_id} (spec 015): ask the small model of
  > the provider in use whether one stored turn's reply answers its question
  > and stays grounded in its tool outputs. The turn is read from this home's
  > own traces, so a request cannot supply text to judge.

## Qué se portea (ground truth: `origin/main:waku/ops/turn_evals.py` + mitades en `observability.py:build_turn/payload` y `dashboard.py:judge_turn` + contrato en `evals/deterministic/test_turn_evals.py`)

- `turn_evals.nim` nuevo: `TURN_CHECKS` + `view` (mensaje, reply, tools con
  `describe`, reports, usd, v2, research, unfinished), `prose`/`sentences`/
  `money`/`budget_usd`, los cinco checks + `run_checks` (el que raisea es
  n/a con "check error", nunca rompe la página), `your_turns` (filas por
  check + fila judge), juez (`judge_prompt` con sus topes 4000/800/6000,
  `judge_estimate` vía `priceFor`, `judge_offer`, `parse_verdict` con
  min/10, `find_turn`, `_claim` 60s, `judge_turn` con llamada inyectada,
  `write_score`, ledger kind "judge"), `report` + `cli_main`
  (`waku evals turns [--window]`).
- Cableado: `build_turn` corre los checks en cada lectura + stored
  (`yourTurns` y la tabla ya viven en `observability.nim` — llegaron con
  la unidad de rutas y T6 los vuelve reales); `payload` pone
  `judge_offer` por turno (modelo = small del provider) y
  `evals.your_turns` por ventana; `observability_data` pasa el small model
  como ya hace; ruta POST en `dashboard.nim` con lista `portOnlyPostRoutes`
  (este Python no pinea la ruta, como pasó con GET observability).
- `research` del view = `matchingSkillNames` + `isResearch` (el par que el
  port ya tiene para `skill_loader` + `is_research`); report-shape y MARKER
  de `reports.nim`; `COMPANY_PROJECT` donde el port lo tenga.
- La llamada al modelo va por el seam `LlmClient.create` (inyectado en la
  ruta como `ChatFn`/`JudgeFn`: la ruta no construye clientes); `charges`
  y `turn_id` tagging donde el seam los dé, si no costo estimado.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | Infra de lectura: `view`, `prose`, `sentences`, `money`, `budget_usd`, `_result` + pines | S1 | test-first, suite offline | work unit |
| T2 | `spend_claim` (figuras, "N calls at $X each", cero, named-provider, tolerancia $0.01/20%) + pines | S1 S3 | test-first, pins | work unit |
| T3 | `one_report` (saves dedup, research, no-report, marker, v2) + pines | S1 S3 | test-first, pins | work unit |
| T4 | `grounded_numbers` (formatos, fechas, 90%, n/a memoria-sola) + pines | S1 S3 | test-first, pins | work unit |
| T5 | `errors_handled` + `under_budget` + `run_checks` (raise → n/a) + pines | S1 S3 | test-first, pins | work unit |
| T6 | Cableado (`build_turn` corre checks + stored, `research` por skill-match, `evals.your_turns` se vuelve real) + pines | S1 S2 | test-first, pins | work unit |
| T7 | Juez bajo demanda (`judge_offer` estimado, prompt, veredicto, score) + POST `/api/turn-evals/judge` + `portOnlyPostRoutes` + pines | S2 S4 | test-first, pins | work unit |
| T8 | `report` + `waku evals turns` + docs que la unidad vuelve falsos (regla 9) | S1 S4 | CLI + doc + pines | work unit |
| T9 | Cableado vivo del juez: el small model del provider en uso sobre el seam `buildClient` (spec 015, "It asks the small model of the provider in use") + pines de transporte scripted | S2 S4 | test-first, pins | work unit |

## Non-goals

- Los fixtures `evals/fixtures/turns/` (viven solo upstream): los pines del
  port arman sus turnos inline, como las unidades anteriores.
- Entrada hosted-policy para la ruta (este Python no la pinea; el eval de
  contrato no la ve, igual que `portOnlyGetRoutes`).
- Re-calificar modelos o releases: la unidad califica turnos, no suites.
- `release_info`/autodeploy, `collect()` completo de `/api/data`.
- El tagging `turn_id`/`charges` del cliente hosted (Python lo usa para
  que el proxy cobre la llamada del juez aparte del turno): el port no
  tiene proxy de metering, así que el costo sale de `llmCost` y el seam
  `charged_usd` queda como el punto de entrada si algún día lo hay.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: view de un turno armado trae mensaje/reply/tools/reports/usd/v2;
  prose quita fences/código/links; budget lee env o $1.00.
- **T2**: "$0.00" con treg $0.0089 falla y nombra ambas figuras; precio
  "would cost" es n/a; figura named va contra su provider; tolerancia.
- **T3**: research sin reporte falla; dos reportes fallan; marker en reply
  pasa sin memoria; "just answer, no report" es n/a (y falla si guarda).
- **T4**: $1.58M contra 1580000 pasa; figura inventada falla y se nombra;
  menos de 3 números es n/a; memoria-sola sin rastro es n/a.
- **T5**: reintentado pasa; mencionado pasa; silencioso falla; sin fallos
  es n/a; $1.34 falla al default; raise de un check es n/a y la página
  se arma igual.
- **T6**: `build_turn` trae los cinco code scores + stored; `your_turns`
  cuenta los checks recién corridos; pines viejos (stored, judge null)
  siguen verdes.
- **T7**: `judge_offer` trae modelo y usd estimado; prompt sale solo del
  turno guardado; el juez escribe un `score` con costo y modelo; turno
  desconocido y repeat <60s rehúsan; veredicto ilegible no escribe;
  `POST` pineado en POST + espejo intacto.
- **T8**: `waku evals turns` imprime tabla + turnos que fallan; `rg -n`
  documenta fuente y límites en `turn_evals.nim`.
- **T9**: el seam vivo manda un solo mensaje de usuario con el prompt,
  `max_tokens` 300 y el modelo pedido; lee `text`/`in`/`out` del
  response; un cliente que falla sube como `JudgeRefused` por la ruta;
  la ruta cae al `model` del home cuando no hay `small_model`; la línea
  del ledger sigue siendo una sola (el cliente NO se envuelve en
  `meteredClient`).

## Log

- **L1** (usuario): "sigue con turn-evals" (2026-10-07) — siguiente del
  orden tras observability.
- **L2** (investigación): el hueco existe hoy — scores stored-only,
  `judge_offer` null (pines en `observability.nim:369,608,1228,1494`).
  Ground truth en `origin/main:waku/ops/turn_evals.py` (949 líneas) +
  `observability.py:build_turn/payload` + `dashboard.py:judge_turn` +
  `test_turn_evals.py` (605). Este Python no tiene `turn_evals` ni la
  ruta (como pasó con observability) → `portOnlyPostRoutes`.
- **L3** (decisión de implementador): `turn_evals.nim` nuevo; `research`
  por `matchingSkillNames` + `isResearch` (el port ya los tiene);
  fixtures upstream-only (pines inline); la ruta inyecta la llamada
  (nunca construye clientes); `charges`/`turn_id` tagging donde el seam
  los dé, si no costo estimado.
- **L4** (cierre, T1-T8, 2026-10-07): suite completa **1432 OK, 0 FAILED**
  (+57 sobre observability: 47 turn-evals + 6 ruta + 2 wiring + 3 CLI −
  reacomodos). `nimble test` verde, cero warnings. T8 documenta la
  fuente y el límite en el módulo, el dispatch y el README (regla 9).
  Hallazgo: `yourTurns` y su tabla ya vivían en `observability.nim`
  (llegaron con la unidad de rutas) — T6 los volvió reales en vez de
  duplicarlos en `turn_evals.nim`.
- **L5** (usuario, 2026-10-07): "cablea el juez vivo" — el seam queda
  declarado como T9, no como follow-up: `arena_live` es donde vive
  `liveClientFor` y el `buildClient` que los tests ya scriptean, así que
  el cableado vivo entra ahí (una implementación del cliente, no dos) y
  la ruta deja de responder el error honesto.
- **L6** (cierre, T9, 2026-10-07): suite completa **1435 OK, 0 FAILED,
  cero warnings** (+3 sobre T8: 2 seam vivo + 1 fallback de modelo).
  `makeLiveTurnJudge(deps, provider)` en `arena_live` sobre
  `liveClientFor`; `dashboard` lo cablea junto a `makeLiveJudge`. El
  cliente **no** va por `meteredClient` (una línea de ledger por juicio:
  la escribe `judgeTurn`). La ruta usa `small_model or model`, como
  `judge_client`. `judgePass` de la página pasa a aliasar
  `turn_evals.judgePassMark` (un literal, no dos). Hallazgo de pin: el
  throttle de 60 s es por turn id **y por proceso**, así que dos pines
  en una corrida no pueden compartir turno — `judgeHome` lo toma como
  parámetro.
- **Pendiente al cortar** (2026-10-07): (1) el review nativo de la
  unidad sigue bloqueado en el gate `managed_assets_outdated` (espera
  autorización para el `gentle-ai sync` del continuation, que escribe
  fuera del proyecto); (2) deriva pre-existente de
  `nim/tests/factstore_fakes` (binario trackeado que cada `nimble test`
  regenera) sin decisión entre restaurar a HEAD o ignorar
  `.codegraph/`/`.pi/`.
