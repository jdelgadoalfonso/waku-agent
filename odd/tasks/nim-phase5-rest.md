# Nim port — phase 5 resto: pricing + catalog + integrations

## Goal
Cerrar la fase 5 del port Nim (después de 5a skill distribution ya landed en `dac3a10`):
portar `waku/ops/pricing.py` (177 líneas) + `waku/ops/catalog.py` (264 líneas) +
el registry de `waku/integrations.py` (905 líneas) + price lists de `waku/providers.toml`,
con paridad Python y tests 100% offline.

## Unidades (una por commit, para proteger revisión)
- **5b pricing** (siguiente): `nim/src/pricing.nim` — `MODEL_PRICING`, `MODEL_CUTOFF`,
  `PRICING` derivado de providers.toml `price`, `price_for` (cache > :free > model > provider),
  `remember_price`, `cutoff_for`, `usage_summary` (lee `usage.jsonl`, reprecifica al leer).
  Requiere extender `providers.nim` para parsear `price = [in, out]` (hoy lo salta).
  Tests offline con ledger temp.
- **5c catalog**: `nim/src/catalog.nim` — `list_models` con seam inyectado
  (fetch + settings + env), caché 5min / fallo ~1min, `_known_default_ids`,
  `pinned_specs`/`save_pinned`/`default_model_for` sobre `models.json`.
  Llama a `remember_price` de 5b. Sin red en tests.
- **5d integrations**: `nim/src/integrations.nim` — registry menos probes con
  subprocess (igual que `integrations.nim` en diseño), estados y vistas.
  Lo más grande (905 líneas Python); se ancla fino al empezar.

## Estado actual
- Rama: `feature/nim-phase0-skeleton`.
- 5b LANDED en `4d20c5e` (pricing.nim + price en providers.nim + 16 tests,
  verifier accept-with-notes, suite 220 OK, 0 warnings).
  Divergencias deliberadas restantes: fallback exige `providers` explícito
  (default `@[]` → 3.0/15.0), ledger no-dict/tokens-float normalizados,
  round half-away (Python half-even), sort inestable en empates, seam
  `clearPriceCache` sin equivalente Python.
- 5c LANDED en `c7ea28e` (catalog.nim + 24 tests,
  verifier accept-with-notes, suite 244 OK, 0 warnings).
  Divergencias deliberadas: sin pareo regional, sin HTTP real (fetch
  inyectado + seam `now`), tools/reasoning ausentes (no null), degradar
  en vez de lanzar, sort inestable en empates.
- Siguiente: 5d integrations (registry menos probes con subprocess).
- Python ground truth: `waku/ops/pricing.py`, `waku/ops/catalog.py`,
  `waku/integrations.py`, `waku/providers.toml` (12 rows con `price`),
  `waku/loop/models.py` (REGISTRY/PROVIDERS).

## Gates por unidad
- TDD con RED observado, `nimble test` verde, 0 warnings, sin red.
- Verificación independiente accept / accept-with-notes + notas / reject.
- Commit de unidad en la rama feature, sin push/PR.
- Regla 9: fix the doc your change makes false (nim/README + nim-port.md).
