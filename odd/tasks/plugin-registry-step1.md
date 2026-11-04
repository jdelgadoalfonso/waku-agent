# Plugin registry paso 1 — registry sin .so

Cambio autorizado. Primer paso para llevar los plugins a la realidad: registry global de graphs + enable list vía tabla, sin dlopen todavía. El dashboard deja de hardcodear el par triage+gather y lee del registry.

Estado al 2026-11-04. Base `main` en `1f09243`. Sin código aún.

## Specs

- **S1 — Registry como fuente de verdad.** Existe `nim/src/graph/registry.nim` con los graphs builtin (triage, gather). `graphSection` lee del registry en vez de `[triageTopology(), gatherTopology()]`. Payloads `describe()` idénticos a hoy.
- **S2 — Enable list en tabla.** La lista de habilitados vive en tabla `[plugins]` en config (decisión del usuario). Sin ficheros en `.waku/plugins/` en este paso; eso queda para la fase dlopen.
- **S3 — Sin regresión.** `graphSelectorFor` / `resolveGatewayGraph` conservan aliases legacy (`off`/`loop`/desconocido → nil). Añadir un tercer graph futuro aparece en el select sin tocar el route contract hosted. Citas del usuario: "nos quedamos con JSON v1" y "vamos con el paso 1".
- **S4 — Testeado.** Pin determinista en `nim/tests/` prueba: registry-driven con triage+gather presentes, nombres únicos, payload válido, enable list. Cita del usuario: "déjalo como referencia local" (para `nim/measure_state_sizes.nim`, que no se commitea).

## Tasks

| ID | Tarea | Spec | R |
|---|---|---|---|
| T1 | Crear `nim/src/graph/registry.nim` con triage+gather (ojo: `nim/src/registry.nim` ya existe, calificar imports) | S1 | P |
| T2 | Cambiar `graphSection` (dashboard.nim:707,754) a leer del registry | S1, S3 | P |
| T3 | Tabla `[plugins]` + extender choices / selector con nombres del registry | S2, S3 | P |
| T4 | Pin determinista + verificación offline + commit | S4 | P |

## Log

- **L1** (usuario, verbatim): "vale, ¿cual es entonces el primer paso para llevarlo a la realidad?"
- **L2** (usuario, verbatim): "vamos con el paso 1"
- **L3** (usuario, decisión enable list, verbatim opción): "Tabla [plugins] en config"
- **L4** (diseño): paso 1 = registry + enable list sin `.so`; loader mínimo JSON y plugin de ejemplo quedan para pasos 2 y 3. Base: handoff explorer `mw2ck5s8-3-3rtw`.
- **L5** (evidencia paso 1): `nim/src/graph/registry.nim` nuevo (builtins triage+gather, `enabledWorkflows`, `isKnownPluginKind`, `parsePluginList`); `graphSection` lee del registry con overload `plugins` (default ambos); `Settings.plugins` + `WAKU_PLUGINS` en `config.nim`; pin `nim/tests/test_plugin_registry.nim` 7 OK. Vecinos: test_graph 27, test_workflows 28, test_gateway_graph_select 5, test_dashboard 137 — 0 FAILED. `nim/measure_state_sizes(.nim)` queda fuera del commit por pedido del usuario.
