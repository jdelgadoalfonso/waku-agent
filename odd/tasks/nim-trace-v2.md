# Nim port — trazas spec 012 (schema v2 + nombres GenAI)

Las líneas del trace siguen el schema viejo: la línea `llm` no dice de
qué turno es ni qué costó, la línea `tool` es el evento crudo (sin
`source`, `span`, `ok`, args sin redactar) y el export OTLP manda los
campos con nombres propios en vez de los semconv GenAI. Upstream lo
cambió en spec 012 (`v: 2`): el loop estampa `call_id` + `duration_ms`,
el tracer sella cada línea y el export mapea a GenAI en un solo lugar.

## Specs

- **S1** (el loop estampa, verbatim upstream):
  > spec 012: how long the call took, for the trace

- **S2** (la línea `llm`, verbatim upstream):
  > Spec 012: join the call to its turn and say what it cost

  > An `llm` line carries `turn_id`, `cost_usd` (the `pricing.py` estimate for its tokens), `span: "llm"` and `gen_ai.operation.name: "chat"`.

- **S3** (la línea `tool`, verbatim upstream):
  > What a line holds (spec 012, schema `v: 2`). A `tool` line carries the turn's `turn_id`, the tool's `source` (`treg`, `waku_memory`, `local` or `mcp:<server>`), `duration_ms`, `ok` and on a failure `error`, `cost_usd`, `endpoint_id` and `provider` when the result names them, and for a Waku Memory call its `query`, `results`, `memory_ids` and `retrieval_trace_id`; its `span` kind (`tool`, `retrieval` or `memory_write`).

  > Its `args` are redacted and trimmed to 500 characters; its `output` is kept whole.

- **S4** (el export, verbatim upstream):
  > The OTel export uses the GenAI semantic-convention names (`observability.GENAI`, the one mapping).

## Qué se portea (ground truth: `origin/main:waku/loop/agent.py:151-155`, `waku/ops/observability.py`, `waku/ops/tracing.py:Tracer.event`)

- Loop: cada evento `tool` lleva `call_id` (el id del `tool_use`) y
  `duration_ms` (entero ≥ 0 medido alrededor del execute). Misma forma
  para llamadas fallidas (el execute responde texto, no raise).
- `observe.nim` nuevo (solo el núcleo v2 de `observability.py`, no la
  página): `GENAI` + `OPERATION` (`llm: chat`, `tool: execute_tool`,
  `retrieval: search_memory`, `memory_write: create_memory`),
  `tool_source` (`treg_`→treg, `waku_memory_`→waku_memory,
  `<server>_`→mcp:server, resto local), `span_kind` (reads→retrieval,
  remember/forget/import→memory_write), `tool_type`
  (datastore/extension/function), `genai_attributes`,
  `redact` + `trace_args` (cap 500), `outcome` (failed/timed
  out/error/status≥400, solo primera línea), `_memory_fields`
  (query/results/ids cap 20/trace_id con forma), `describe`
  (los campos propios del evento v2 ganan a lo derivado),
  `trace_record` (sin `args`/`call_id` crudos, `v: 2`, `turn_id`,
  `gen_ai.operation.name`, `gen_ai.tool.type`, `call_id`→
  `gen_ai.tool.call.id`), `llm_cost` (precio × tokens, round 6).
- `trace.nim`: línea `llm` = `turn_id` + `cost_usd` + `span: llm` +
  `gen_ai.operation.name: chat` (sello ANTES de ledger+fila+span, como
  Python reasigna `event`); línea `tool` = `trace_record` con los
  servers de `home/mcp.json` (lectura tolerante: falta/inválido = `@[]`).
- `otel.nim`: el span lleva `openinference.span.kind`, cada campo como
  `waku.<campo>` EXCEPTO `gen_ai.*` y `cost_usd`, más `genai_attributes`
  (nombres GenAI, `mcp.method.name`, `waku.cost.usd`).
- `tool_cost` se reutiliza de `receipt.nim` (ya portado); su matiz
  (endpoint solo del output, no de args) queda como divergencia anotada.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | Loop estampa `call_id` + `duration_ms` en cada evento `tool` + pines (presentes, id del tool_use, entero ≥ 0, también en fallo) | S1 | test-first, suite offline | work unit |
| T2 | `observe.nim` núcleo puro + pines (sources, spans, types, redact/trim 500, outcome, describe incl. memoria y passthrough v2) | S3 | test-first, pins | work unit |
| T3 | `trace_record` + `llm_cost` + sellado en `trace.nim` (llm y tool) + lectura tolerante de servers + pines | S2, S3 | test-first, pins | work unit |
| T4 | Attrs del span en `otel.nim` (skip gen_ai/cost + mapeo) + pines | S4 | test-first, pins | work unit |
| T5 | Docs que la unidad vuelve falsos (regla 9): headers + línea en `nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Lectura de trazas para la página (`read_events/group_turns/build_turn/story/hotspots` → unidad de rutas dashboard).
- `hosted/`, turn_evals, judge.
- Cambiar `receipt.toolCost` (se reutiliza tal cual; matiz anotado).
- Nuevos transports o batching en el exporter.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: turno con tool deja `call_id == "t1"` y `duration_ms` int ≥ 0 en
  `toolCalls[0]` y en el evento; tool desconocido también estampa.
- **T2**: `treg_x`→treg, `waku_memory_memory_search`→waku_memory+retrieval,
  `engram_mem_search` con servers `@["engram"]`→mcp:engram, `echo`→local;
  secreto en args → `***`; `failed …`→ok=false+error; memoria con entries
  → results/ids; evento v2 propio gana a lo derivado.
- **T3**: línea llm con `turn_id/cost_usd/span/gen_ai.operation.name`;
  línea tool con `v == 2`, args redactados, `gen_ai.tool.call.id`;
  `mcp.json` ausente/inválido = `@[]` sin raise.
- **T4**: el span no lleva `waku.cost_usd` ni `waku.gen_ai.*` crudos y sí
  `gen_ai.tool.name`, `gen_ai.operation.name`, `waku.cost.usd`.
- **T5**: `rg -n "gen_ai.operation.name" nim/src/trace.nim nim/src/otel.nim nim/src/observe.nim` documenta fuente y límites.

## Log

- **L1** (usuario): "adelante" (2026-10-06) — lo siguiente del orden.
- **L2** (investigación): el hueco existe hoy — `trace.nim` espeja el
  tracing pre-012, `otel.nim` manda nombres propios, el loop no estampa
  nada. Ground truth en `agent.py:151-155` + `observability.py` (1110
  líneas, solo núcleo v2) + `tracing.py:event`. `pricing.nim` y
  `receipt.toolCost` ya existen y se reutilizan.
- **L3** (decisión de implementador): `observe.nim` nuevo solo-núcleo
  (la página queda para rutas dashboard); servers desde `mcp.json`
  tolerante como upstream; `duration_ms` con monotonía del stdlib;
  `toolCost` sin tocar.
