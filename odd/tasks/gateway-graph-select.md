# Gateway a cualquier graph en caliente — sin restart

Cambio autorizado. El gateway hoy solo habla al loop (o al único graph global triage si `WAKU_GRAPH_WORKFLOWS=1`). Esto permite dirigir cada source (telegram/discord/whatsapp) a loop o a cualquier graph registrado, leyéndose por turno desde el env vivo, sin reconstruir la box ni reiniciar el servicio.

Estado al 2026-11-04. Documento creado desde el mapa de dos explorers. Base `nim-first` en `0e3b7a1`. Sin código aún.

## Specs

- **S1 — Selección por source en caliente.** Cada turno del gateway relee el selector desde el env vivo (`envOf()`): `WAKU_GRAPH_<SOURCE>` (ej. `WAKU_GRAPH_TELEGRAM`) con fallback a `WAKU_GRAPH_WORKFLOWS`. Valores: `off`/`loop` = loop puro, `triage` = graph triage, nombre de runner registrado = ese graph. Sin restart, sin rebuild de client/db.
- **S2 — Cualquier graph, no solo triage.** La tabla de runners (`graph/commands` o equivalente) es la fuente de verdad: el selector resuelve por nombre y `nil`/desconocido hace fail-open al loop, igual que el gate actual.
- **S3 — Sin regresión.** Con selector ausente o `off`, el comportamiento es exactamente el de hoy: snapshot de settings + triage si `graphWorkflows`, si no loop. Fail-open ante graph que raisea se mantiene.
- **S4 — Testeado.** Un pin determinista en `nim/tests/` prueba: por-turno relee env, `off` va a loop, `triage` va al graph, cambio de valor entre turnos sin rebuild. Cita del usuario: "quiero que el gateway pueda dirigirse no solo al loop sino también a cualquier graph sin necesidad de reiniciar el servicio".

## Tasks

| ID | Tarea | Spec | R |
|---|---|---|---|
| T1 | Resolver nombre de graph a GraphTurn (registry por nombre + `off`) | S1, S2 | P |
| T2 | Releer selector por turno en `gatewayAgents` + relajar gate en `app.nim` | S1, S3 | P |
| T3 | Pin determinista en `nim/tests/` + verificación + commit | S4 | P |

## Log

- **L1** (usuario, verbatim): "si, exactamente quiero que el gateway pueda dirigirse no solo al loop sino también a cualquier graph sin necesidad de reiniciar el servicio"
- **L2** (diseño): sin registry por nombre, solo `triageGraphTurn`; el selector es `WAKU_GRAPH_<SOURCE>` con fallback a `WAKU_GRAPH_WORKFLOWS`; `off`/`loop`/desconocido es nil (fail-open). Seam: releer `envOf()` por turno en `gatewayAgents` y relajar el gate de `app.nim:351` a `not w.graphTurn.isNil`.
- **L3** (evidencia): `nim check` app + dashboard SuccessX; `test_gateway_graph_select` 3 OK; `test_app` 41 OK; `test_dashboard` 137 OK, exit 0.
- **L4** (UI): selects en Connections vía `data/integrations.toml` (`WAKU_GRAPH_TELEGRAM/DISCORD/WHATSAPP`, choice loop/triage, default loop). Render y save automáticos por `connectionField`/`applyIntegration`; entran al fingerprint gateway y reconcilian. `.env.example` regenerado con `--write` (`--check` exit 0). Pin Nim `telegram.env.len` 2→3 + asserts del choice; `test_integration_rows` 24 OK, `test_integrations.py` 27 passed.
