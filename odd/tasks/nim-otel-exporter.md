# Nim port — exporter OTLP/OpenTelemetry hecho a mano (spans)

Cierra el non-goal que el port dejó anotado en `docs/proposals/nim-receipt.md` §4 y en el header de `nim/src/trace.nim`: hoy el port escribe JSONL pero no exporta spans. Esta unidad lo implementa sin SDK, sin gRPC y sin dependencias nuevas, espejo 1:1 de la telemetría que emite `waku/ops/tracing.py`.

## Specs

- **S1** (petición del usuario, verbatim):
  > vamos a implementar opentelemetry de forma manual en el port de Nim que estamos haciendo

- **S2** (decisión del usuario, verbatim — encoding del transporte):
  > **OTLP/HTTP + protobuf (recomendado)** — "Encoder protobuf mínimo escrito a mano (varint, fixed64, anidado length-delimited). Compatible con cualquier collector y con Phoenix. Cuesta ~200-300 líneas más y un test de bytes dorados."

- **S3** (decisión del usuario, verbatim — configuración del endpoint):
  > **host:port igual que Python (recomendado)** — "Acepta OTEL_EXPORTER_OTLP_ENDPOINT como host:port (con o sin esquema, igual que el probe del dashboard ya instalado) y hace POST a http://host:port/v1/traces. Mismo env var, mismo validador, cero contratos nuevos; se documenta que Phoenix usa 6006, no 4317."

- **S4** (decisión del usuario, verbatim — alcance de los spans):
  > **Espejo 1:1 de Python (recomendado)** — "Span raíz agent_run por turno (AGENT, con waku.user_message), un span hijo por cada evento del loop (LLM/TOOL/CHAIN según el tipo), atributos waku.<campo> y flush por turno al cerrar, igual que force_flush."

## Contrato a espejar (ground truth: `waku/ops/tracing.py`, `waku/config.py`)

Nada de esto es diseño nuevo: es lo que Python ya emite, para que Phoenix/Langfuse/Grafana muestren lo mismo en los dos lenguajes.

| Pieza | Python | Valor a portar |
|---|---|---|
| Setting | `otel_endpoint` | `otelEndpoint` = `OTEL_EXPORTER_OTLP_ENDPOINT`, default `""` |
| Raíz del turno | `start_as_current_span("agent_run")` en `turn()` | span raíz `agent_run`, `openinference.span.kind = AGENT`, atributo `waku.user_message` |
| Hijos | un span por `event()`, dentro del contexto del turno | un span hijo por evento, **duración cero** (`start == end`, es un `with ...: pass`), `parentSpanId` = raíz, mismo `traceId` del turno |
| Nombre del hijo | `f"{kind}.{event.get('tool', event.get('decision', ''))}".rstrip(".")` | idéntico; `llm` sin sufijo queda `"llm."` → `"llm"` tras el `rstrip` |
| Tipo del span | `{"llm": "LLM", "tool": "TOOL"}.get(kind, "CHAIN")` | `openinference.span.kind` igual, y **solo** como atributo: el enum OTLP `Span.kind` queda `INTERNAL` (trabajo que hizo Waku), porque Python tampoco lo cambia |
| Atributos | `{f"waku.{k}": json.dumps(v, default=str) for k, v in event.items()}` | cada campo del evento como `waku.<campo>` con el **string** de su JSON (números included: `"in": "10"`) |
| Exportación | `BatchSpanProcessor` + `force_flush(2000)` en `end_turn()` | un POST por turno con todos los spans del turno, sin hilo, sin timer |
| Recurso | `Resource.create({"service.name": "waku-agent"})` | atributo `service.name = "waku-agent"` |
| Falta el SDK | `except ImportError` → mensaje a stdout | **no aplica**: el port no tiene SDK que faltar. Se documenta la diferencia |

Nombres de campo del OTLP (`opentelemetry/proto/trace/v1/trace.proto`) que hay que codificar a mano: `ExportTraceServiceRequest.resourceSpans`, `ResourceSpans.resource/scopeSpans`, `Resource.attributes`, `ScopeSpans.scope/spans`, `Scope`, `Span.trace_id/span_id/parent_span_id/name/kind/start_time_unix_nano/end_time_unix_nano/attributes`, `KeyValue.key/value`, `AnyValue.string_value`, `AnyValue.int_value`.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/otelproto.nim`: writer protobuf mínimo (varint, tag, length-delimited, fixed64) + `Span`/`buildRequest` que arma el `ExportTraceServiceRequest`. Puro, sin HTTP. Pines de bytes dorados en `nim/tests/test_otelproto.nim` con ids y timestamps inyectados | S2 | test-first, suite offline | work unit |
| T2 | `nim/src/otel.nim`: parser del endpoint (mismo validador que el probe de `nim/src/dashboard.nim:2641`), árbol de spans del turno, exporter con POST `/v1/traces` `application/x-protobuf` y seams inyectados (send, clock, ids). `nim/tests/test_otel.nim`: pines del árbol de spans y del flush + un test loopback real sobre 127.0.0.1 con el precedente de `nim/tests/test_http.nim:52` que fija puerto, headers y bytes | S3, S4 | test-first, suite offline | work unit |
| T3 | Cableado: `otelEndpoint` en `nim/src/config.nim` + `loadFromEnv`, `newTracer` recibe el endpoint, `trace.nim` abre/cierra/cierra-span por turno, `app.nim` pasa `settings.otelEndpoint`. TLS solo por `newTlsHttpClient` (gate de `nim/tests/test_tls.nim:519`). Con endpoint vacío el port se comporta exactamente como hoy | S1 | test-first, pins en `nim/tests/test_trace.nim` | work unit |
| T4 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md` (tres sitios), `docs/proposals/nim-receipt.md` §4, `odd/tasks/nim-port.md` (landing + phase list), `docs/architecture.md` si lo exige, y el mensaje de `trace.nim` | S1 | doc + pins | work unit |

## Non-goals

- gRPC / HTTP/2 (el spec lo permite, pero exige framing y TLS; el port no tiene TLS por defecto).
- Headers de autenticación (Langfuse cloud los usa): el endpoint es local por defecto, S3 lo define sin credenciales.
- Batch en background, reintentos, cola o backpressure: un POST por turno y que un fallo de red **no** levante dentro del turno.
- Métricas y logs OTLP: solo spans, que es lo que Python exporta.
- Cambiar el JSONL, el ledger, los prompts o cualquier tool.

## Verificación

- `nimble test` verde y cero warnings (`--forceBuild`, el gate del repo).
- T1: bytes dorados exactos para un `Span` conocido (trace/span id, timestamps y atributos inyectados) + un round-trip de un parser de test mínimo que lee los campos de vuelta.
- T2: sin endpoint no se crea exporter; con endpoint, un turno emite raíz + hijos en orden y **un** POST al cerrarse; el loopback comprueba método, ruta, `Content-Type` y que el cuerpo decodifica a los spans esperados.
- T3: `OTEL_EXPORTER_OTLP_ENDPOINT` leída de env; `newTracer` con endpoint vacío no cambia ni un byte del JSONL existente (pin de los tests de `test_trace.nim` sin tocar).
- T4: `rg -n "OTel spans|otel" nim/README.md docs/proposals/nim-receipt.md` ya no afirma que sea trabajo futuro.

## Log

- **L1** (usuario, verbatim): "vamos a implementar opentelemetry de forma manual en el port de Nim que estamos haciendo"
- **L2** (usuario, verbatim): encoding **OTLP/HTTP + protobuf**, endpoint **host:port igual que Python**, alcance **espejo 1:1 de Python**. Preguntado porque el spec OTel marca `http/json` como opcional y el default es `http/protobuf`; el exporter manual tiene que hablar el que todos los collectors aceptan.
- **L3** (decisión de implementador): Phoenix sirve OTLP/HTTP en el **puerto 6006** (el mismo que su UI), no en el 4317 genérico; el README lo dice junto al ejemplo, porque el doc de Phoenix usa el 4317 en la tabla y el 6006 en el ejemplo.
- **L4** (decisión de implementador): los hijos son spans de duración cero, igual que el `with ...: pass` de Python. No inventar duración: el port no cronometra cada evento.
- **L5** (T1, decisiones de implementador): un campo opcional vacío se **omite** en todos los niveles (`parent_span_id` de la raíz, `name` vacío), pero un valor de atributo vacío **se escribe**: omitirlo dejaría un `AnyValue` sin campo, que ningún colector puede pintar. No se codifican `Span.flags` ni `Span.status` (nada en este camino los necesita) ni `ExportTracePartialSuccess` (es la **respuesta** del colector, capa HTTP de T2). Verificación de T1: los bytes se decodificaron con el `opentelemetry-proto` real (1.39.1) y volvieron byte-idénticos, y 8 mutaciones de número de campo (Span 9→10, ScopeSpans 2→3, Request 1→2, etc.) quedaron todas killed por la suite.