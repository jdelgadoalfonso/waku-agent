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
| T1 | `nim/src/otelproto.nim`: writer protobuf mínimo (varint, tag, length-delimited, fixed64) + `Span`/`buildRequest` que arma el `ExportTraceServiceRequest`. Puro, sin HTTP. Pines de bytes dorados en `nim/tests/test_otelproto.nim` con ids y timestamps inyectados | S2 | test-first, suite offline | `2ccb4f9` |
| T2 | `nim/src/otel.nim`: parser del endpoint (mismo validador que el probe de `nim/src/dashboard.nim:2641`), árbol de spans del turno, exporter con POST `/v1/traces` `application/x-protobuf` y seams inyectados (send, clock, ids). `nim/tests/test_otel.nim`: pines del árbol de spans y del flush + un test loopback real sobre 127.0.0.1 con el precedente de `nim/tests/test_http.nim:52` que fija puerto, headers y bytes | S3, S4 | test-first, suite offline | `6110e75` |
| T3 | Cableado: `otelEndpoint` en `nim/src/config.nim` + `loadFromEnv`, `newTracer` recibe el endpoint, `trace.nim` abre/cierra/cierra-span por turno, `app.nim` pasa `settings.otelEndpoint`. TLS solo por `newTlsHttpClient` (gate de `nim/tests/test_tls.nim:519`). Con endpoint vacío el port se comporta exactamente como hoy | S1 | test-first, pins en `test_trace.nim` (cableado) y `test_phase0.nim` (env) | `a5a51bc` |
| T4 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md` (tres sitios + una sección nueva), `docs/proposals/nim-receipt.md` §4, `odd/tasks/nim-port.md` (landing). y el mensaje de `trace.nim`, corregido en T3 con el código | S1 | doc + pines | este |

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

Evidencia final (T1-T4): `nimble test` = **1172 OK, 0 FAILED, 56 suites, EXIT=0**, sin warnings de compilador. Las suites tocadas se compilaron además con `--forceBuild` (`test_otelproto` 23, `test_otel` 25, `test_trace` 11, `test_phase0` 7, `test_cli` 24, `test_app` 27, `test_session` 15, `test_tls` 17), porque `nimble test` puede enlazar `.o` anteriores a los fuentes. `evals/deterministic/test_rulebook.py` = 17 passed; ningún eval de Python toca `nim/`, así que la cobertura determinista de esta unidad es la suite Nim, que es la convención de todas las fases del port. `pytest evals/deterministic` completo no corre en esta máquina (falta `anthropic`), preexistente.

**No verificado:** que Phoenix o un collector real acepten el payload — no hay collector offline. La evidencia más fuerte disponible es que los bytes de T1 los decodificó el `opentelemetry-proto` real (1.39.1) byte a byte, y que el POST real del test loopback de T2 lleva exactamente esos bytes con los headers correctos. Un build `-d:wakuTls -d:ssl` con un collector `https://` tampoco se probó (necesita libssl y un collector remoto).

## Log

- **L1** (usuario, verbatim): "vamos a implementar opentelemetry de forma manual en el port de Nim que estamos haciendo"
- **L2** (usuario, verbatim): encoding **OTLP/HTTP + protobuf**, endpoint **host:port igual que Python**, alcance **espejo 1:1 de Python**. Preguntado porque el spec OTel marca `http/json` como opcional y el default es `http/protobuf`; el exporter manual tiene que hablar el que todos los collectors aceptan.
- **L3** (decisión de implementador): Phoenix sirve OTLP/HTTP en el **puerto 6006** (el mismo que su UI), no en el 4317 genérico; el README lo dice junto al ejemplo, porque el doc de Phoenix usa el 4317 en la tabla y el 6006 en el ejemplo.
- **L4** (decisión de implementador): los hijos son spans de duración cero, igual que el `with ...: pass` de Python. No inventar duración: el port no cronometra cada evento.
- **L5** (T1, decisiones de implementador): un campo opcional vacío se **omite** en todos los niveles (`parent_span_id` de la raíz, `name` vacío), pero un valor de atributo vacío **se escribe**: omitirlo dejaría un `AnyValue` sin campo, que ningún colector puede pintar. No se codifican `Span.flags` ni `Span.status` (nada en este camino los necesita) ni `ExportTracePartialSuccess` (es la **respuesta** del colector, capa HTTP de T2). Verificación de T1: los bytes se decodificaron con el `opentelemetry-proto` real (1.39.1) y volvieron byte-idénticos, y 8 mutaciones de número de campo (Span 9→10, ScopeSpans 2→3, Request 1→2, etc.) quedaron todas killed por la suite.
- **L6** (T2, divergencia deliberada): el POST lleva la **raíz primero** y luego los hijos; el `BatchSpanProcessor` de Python exporta los hijos antes. No cambia nada para un colector (el árbol se arma por `parentSpanId`, no por posición) y el orden estable hace la salida byte-determinista.
- **L7** (T2, divergencia deliberada): un `tool: null` produce el span `tool`, donde Python produce `tool.None` — `f"{None}"` es un artefacto del f-string de Python, no un nombre de span. No se reproduce la wart.
- **L8** (T2, comportamiento fijado): un `turn()` sin `endTurn` entre medio **reemplaza** el turno abierto (se descartan sus spans) en vez de anidarlo como el context manager de Python. Un exporter con una sola raíz por turno no puede anidar; queda pineado por test para que no sea accidental.
- **L9** (T2, verificador independiente): el validador del endpoint está **duplicado** desde el probe de `dashboard.nim` (importar no es posible: es una closure en un módulo de 3700 líneas, fuera de la superficie de edición). Un test de deriva lee las **dos fuentes** y compara las frases y la lista `for bad in [...]`, siguiendo el precedente de `nim/tests/test_tls.nim:519`; sin eso la suite solo repetiría la tabla y una deriva pasaría verde. Dos findings del verificador se corrigieron antes de commitear: un assert que decía `waku.kind` que NO debe aparecer (Python sí lo emite en `tracing.py:191`), y un `flush()` a secas que mandaba `end < start`.