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
- **L7** (review nativo, 2026-10-08): punto 1 retomado con
  autorización. `gentle-ai sync --agent pi` (v4.0.0, 9 archivos,
  todos fuera del proyecto) desbloqueó `managed_assets_outdated`.
  Descubrimiento de ruta: para un rango comprometido hay que
  congelar el target con `review status --base-ref <commit>
  --committed-only` (proyección `base-diff`) y luego `review start`
  con los tokens ofrecidos; la fachada `start` sola no reconcilia
  `baseRef` con un árbol sucio (`candidate-mismatch`). Consentimiento
  `granted` (riesgo medio, 14 archivos, 2377 líneas). Lineage
  `review-350c858b082944dd` creado, lente `review-reliability`,
  presupuesto de corrección 200. **Bloqueado**: la corrida del
  revisor falló 3 veces con 429 del pool compartido upstream
  (Novita / ling-3.1-flash por OpenRouter); al cambiar el
  modelo, el 429 desapareció pero el relé devolvió 404 (modelo
  no gratuito; el proveedor sugiere el slug `minimax/minimax-m3`
  o clave paga). Nada quemado; el slot se reofrece en cada
  STATUS fresco. Pendiente: enrutar el relé a un modelo
  disponible (lado del usuario) y reintentar. (2026-10-08,
  reintentos): con el modelo cambiado el relé **sí corró**
  pero excedió el límite del relé (~1016868ms) con el
  prompt de 136KB del rango completo → declarado
  `unachievable_lens_slot` (lineage detenido). Nueva
  rebanada T9 por decisión del usuario: lineage
  `review-26fc4204948fdd02`, consentimiento granted,
  8 archivos/164 líneas, presupuesto 82 — y también
  excedió el límite (926720ms contra 926700ms) con un
  prompt de solo 31KB: el cuello es la **velocidad del
  modelo**, no el alcance. Remedio del proveedor:
  `GENTLE_PI_REVIEW_RELAY_PI_TIMEOUT_MS` (techo
  7200000ms) en el entorno del host, o un modelo de
  relé más rápido; ambos lados del usuario.
- **L8** (relanzamiento con timeout 2h, 2026-10-08): usuario subió
  `GENTLE_PI_REVIEW_RELAY_PI_TIMEOUT_MS` a 7200000 y autorizó sync +
  ambas revisiones (T9 primero). Secuencia que funciona: sync genérico
  para el withdraw, luego sync v4.0.0 exacto del continuation para que
  STATUS reofrezca collect. **T9 aprobada y quemada**
  (`review-26fc4204948fdd02`, 8 archivos/164 líneas, prompt 31KB):
  1697s, `approved`, 2 findings informativos no bloqueantes en
  `arena_live.nim` (retry sin pin 259-262 SUGGESTION, ledger-row sin
  pin 255-257 WARNING), revision `1e01b66d`, authority burned.
  **Rango completo fallido** (`review-350c858b082944dd`, 14
  archivos/2377 líneas, prompt ~136KB): 3606s y
  `pi-host-relay-transport-failure` (stream sin finish_reason,
  sin timeout); nada quemado, STATUS reofrece el slot. Lección:
  31KB→28min OK pero 136KB→60min sin finish con este modelo; el
  rango puede necesitar reintentos o seguir en rebanadas.
- **L9** (troceado en 4 grupos, 2026-10-08): usuario eligió 4 grupos y
  abandonar el rango (`operator_disposition`, committed, nada
  descartado). Worktrees hermanos registrados: g1 `da92dab`, g2
  `fa74feb`, g3 `47dcdf9`, g4 `4a20ead`. Grupos: G1 T1+T2 646,
  G2 T3+T4 536, G3 T5+T6 310, G4 T7+T8 767 (T9 ya quemada).
  Flujo en worktree limpio: native status `--base-ref
  --committed-only` → native start con tokens exactos → consent
  → sync v4.0.0 → collect → forecast → run. **G1 aprobada y
  quemada** (`review-ffd031747841504c`, 3 archivos/646 líneas,
  prompt ~40KB): 2209s, `approved`, 6 findings informativos
  (`turn_evals.nim` 102-103, 306-307, 31-41 WARNING; test 119-124
  WARNING; 122-124 y 324 SUGGESTION), revision `d75c2132`.
  Lección: la fachada START no admite `baseRef`
  (`schema-incompatible`); hay que usar el comando nativo exacto.
  Pendientes: G2, G3, G4.
- **L10** (G2 T3+T4, 2026-10-08): consent granted (medium, 2
  archivos/536 líneas, `review-ec50166725530492` en g2). Corrida
  3606s y mismo `pi-host-relay-transport-failure` que el rango
  (stream sin finish_reason a los ~60min, sin timeout); nada
  quemado, STATUS reofrece el slot. Patrón: fallos a ~3600s en
  rango y G2 contra éxitos en T9 (28min) y G1 (37min) → apunta a
  rango y G2 contra éxitos en T9 (28min) y G1 (37min) → apunta a
  límite del stream (~1h) más que al tamaño. Opciones: reintentar
  G2, partirlo en T3 (188) + T4 (348), o seguir con G3 (310).
- **L11** (partición G2, 2026-10-08): usuario eligió partir G2.
- **L12** (corrección nativa, 2026-10-09): T4 quedó en
  `correction_required` por `R3-scale-suffix-end-anchored`
  (CRITICAL). El find anclado a `$` buscaba el sufijo de escala
  en `text[start..^1]`: solo lo detecta al final del reply
  (falso negativo: "$1.5M" a mitad de frase) o en cualquier
  palabra final en k/m/b como "web" o "from" (falso positivo
  que escalaría todas las cifras anteriores). Fix: el find
  cubre solo el token coincidente (`whole`), como el lado
  fuente. Al probar apareció la segunda cara del bug: en
  `std/re` `groups[0]` es el primer grupo capturado, así que
  `scaleValue(sm[1])` leía "" y la escala estaba muerta en
  ambos lados; el lado del reply pasa a `sm[0]`. El `sm[1]`
  latente del lado fuente (660) queda fuera del alcance de
  este finding, anotado para seguimiento. Dos pines nuevos:
  cifra con escala a mitad de reply funde con la fuente cruda;
  reply terminado en palabra de escala no escala nada. Suite
  completa **1437 OK / 0 FAILED**. Revisión quemada en
  `review-7f29e5479b90eb62`: corrección de 17 líneas
  (commit `cc36950`), validación dirigida aceptada y
  acknowledgement quemado.
  Worktree nuevo `g2t3` en `9565d73` autorizado y registrado.
  **T3 aprobada y quemada** (`review-9dadce56c9ba7c9c`, 2
  archivos/188 líneas, prompt ~20KB): 2209s, `approved`, 6
  findings informativos, revision `a281f961`. **T4 en
  `correction_required** (`review-7f29e5479b90eb62`, 2
  archivos/348 líneas): revisor 2599s + refutador 691s que
  corroboró severos del candidato; plan de 1-174 diff lines
  ofrecido pero sin texto de findings en la transición
  (lens-context efímero). Lección: no transcribir hashes a mano
  (un target truncado da `invalid_request`); generar comandos
  desde el JSON. Pendientes: corrección T4, T4 quemar, G3, G4.
- **L13** (revisión G3, 2026-10-09): T5+T6 aprobados por revisión
  nativa (`review-3d6bc53a27ed1592`, 5 archivos/310 líneas, lente
  `review-reliability`). El revisor por subproceso murió a los 927s
  contra el límite derivado del relay (~15.5 min para un prompt de
  32KB; el revisor necesita ~30-40 min), así que la corrida terminó
  por la ruta en-host del proveedor: materializar la tarea, ejecutar
  el rol R3 desde los patches congelados y presentar el resultado por
  `capture-result --input`. 0 BLOCKER/CRITICAL; 2 advisory no
  bloqueantes: WARNING `R3-saidfailure-global-bypass`
  (`turn_evals.nim:826-827`: la alternativa de failure-words es
  global y pasa todo tool fallido si el reply menciona cualquier
  fallo) y SUGGESTION `R3-bundled-skill-dirs-in-loop`
  (`observability.nim:1515-1516`). Autoridad quemada
  (acknowledge-approved, revisión `e7305e18`).
- **L14** (revisión G4, 2026-10-09): T7+T8 aprobados por revisión
  nativa (`review-97a2a201ea501d96`, 12 archivos/767 líneas, misma
  lente y misma ruta en-host, prompt de 62KB). 0 BLOCKER/CRITICAL;
  3 advisory: WARNING `R3-window-value-missing-accepted`
  (`waku.nim:258-263`: `--window` sin valor se salta silenciosamente
  y sale 0 con 7d, mientras un valor inválido sale 2), SUGGESTION
  `R3-turns-report-duplicates-build` (`observability.nim:1569-1588`:
  `turnsReport` reimplementa el building de `payload`) y SUGGESTION
  `R3-judge-offer-builds-prompt-per-read` (`turn_evals.nim:971-978`:
  la oferta materializa el prompt completo en cada lectura aunque solo
  su longitud alimenta la estimación). Autoridad quemada (revisión
  `6a8db308`). Con esto T1-T8 tienen revisión nativa completa.
- **L15** (higiene de linajes, 2026-10-09): abandonado el lineage
  G2-combinado `review-ec50166725530492` (536 líneas; nunca admitió
  resultados de lente — T3 y T4 cerraron con sus propias revisiones
  quemadas). `operator_disposition`, actor `pi`, registro v2
  committed, lineage en cuarentena
  (`review-ec50166725530492-878788222`).
- **L16** (seguimiento de WARNING, 2026-10-09): corregidos los
  dos hallazgos advisory WARNING de G3 y G4, commits `2d74c61` y
  `10bfd49` en la rama feature. (1) `R3-saidfailure-global-bypass`:
  `checkErrorsHandled` ya no aplica las failure-words del reply a
  todos los tools fallidos — la alternativa global vale solo cuando
  un único tool falló (las palabras solo pueden significar esa
  llamada); con dos o más fallos cada uno debe ser reintentado o
  nombrado. Pin nuevo: "a second failure stays silent when the
  reply reports another". (2) `R3-window-value-missing-accepted`:
  `runEvalsTurnsCmd` ya no ignora un `--window` sin valor: sale 2
  nombrando las opciones, igual que un valor inválido. Pin nuevo:
  "a dangling --window names the choices and exits 2". Suite
  completa Nim 1439 OK / 0 FAILED. Los tres SUGGESTION de G3/G4
  siguen pendientes (limpieza, no bloqueante).
- **L17** (seguimiento de SUGGESTION, 2026-10-09): aplicados los
  tres hallazgos advisory SUGGESTION de G3 y G4, commits `bc9a517`,
  `8a79d97` y `bcc7ae4` en la rama feature. (1)
  `R3-bundled-skill-dirs-in-loop`: `payload` ya no evalúa
  `bundledSkillDirs()` dentro del loop por turno — la lista se
  calcula una vez por página. (2) `R3-turns-report-duplicates-build`:
  `payload` y `turnsReport` comparten `buildTurns` (joins de scores
  tardíos, research flag, `buildTurn`), así la tabla del CLI y la
  página no pueden desacoplarse. (3)
  `R3-judge-offer-builds-prompt-per-read`: la oferta del juez estima
  el costo desde las longitudes de los cortes (`judgePromptLength`
  sobre el iterator `judgeOutputs` compartido) sin materializar el
  prompt en cada lectura; el rubric se ensambla por concatenación,
  lo que además evita que el template sustituya placeholders que
  aparezcan en un mensaje o reply almacenado. Pin nuevo: "the
  prompt's length is the sum of its cut parts". Suite completa Nim
  1440 OK / 0 FAILED. Con esto los cinco hallazgos advisory de G3
  y G4 están resueltos.
