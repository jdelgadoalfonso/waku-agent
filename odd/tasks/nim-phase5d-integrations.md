# Nim port — phase 5d: integrations registry

## Goal
Port `waku/integrations.py` (905 líneas) a `nim/src/integrations.nim`, en dos
unidades para proteger revisión. Toda lectura de entorno por parámetro
(`env: Table[string, string]`), home por parámetro; cero red, cero subprocess.

## 5d1 — núcleo puro (LANDED `42125f1`, 28 tests, suite 272 OK)
- Tipos: `IntegrationState` (5 estados), `ReloadMode`, `FieldKind`,
  `EnvField`, `IntegrationStatus`, `Integration`, `FieldView`,
  `IntegrationView`, `ApplyResult`.
- `INTEGRATIONS`: las 13 filas estáticas con sus fields exactos
  (nombres, labels, kinds, required/secret/defaults/options/placeholders/
  helps/option_labels, extra, setup_url, reload, enabled-predicado).
  Los predicados `enabled` lambda/darwin se portan como procs con
  `(env, hostOs)` — `sys.platform` se inyecta (`hostOs = "darwin"` real por
  defecto vía `hostOS`), para tests deterministas en Linux.
- Derivadas de providers: `_integrationFromProvider` (field API key +
  field Base URL CHOICE solo si `baseUrlEnv` y endpoints — Nim no tiene
  endpoints: siempre solo el field key, divergencia documentada),
  `providerIntegrations` (solo visibles), `registry = providers + static`,
  `envExampleProviderIntegrations` (hidden siempre fuera).
- `_configured`, `_status` (NOT_CONFIGURED con "macOS only" para apple_*
  fuera de darwin; INSTALLED_BUT_UNCONFIGURED missing-required;
  **sin chequeo de extra**: en el binario único no hay pip extras —
  divergencia documentada; gateway hook inyectable `GatewayStatusFn`;
  fallback a health store inyectado o CONFIGURED "configured — not tested yet").
- Vistas: `listIntegrations(env, ...)` (secret → last4 + configured flag,
  no-secret → value-or-default), `listProviders`, `listConnections`.
- `renderEnvExampleBlock` byte-paridad con Python (mismo orden, mismos
  comentarios); test contra el bloque real generado por Python es la prueba
  reina (el repo bloquea `.env.example` fuera de paso).
- Normalizes puros: `_positiveInt` (DISCORD_MAX_TURNS...), `_notionNormalize`
  (port de `normalize_database_id`: URL → 32 hex del path, o verbatim).
- Surfaces: `nim/src/integrations.nim` (nuevo) + `nim/tests/test_integrations.nim`
  (nuevo). Sin dispatch, sin health en disco, sin probes, sin dotenv write.

## 5d2 — stateful con seams (siguiente unidad)
- Health store (`connections_health.json`, tmp+replace) con home inyectado.
- `ProbeFn` inyectado por key (`_probed`); sin probe → "no test available".
- `recordHealth/invalidateHealth`, `_safeError` (scrub de secretos).
- `applyIntegration` (validación, normalize, required-when-enabled, probe
  salvo force, dotenv set/unset mínimo con rollback, reload hooks
  inyectados, health record) + `testIntegration`.
- `_providerCanServe`, `_adoptable`, `applyProvider` (usa
  `catalog.defaultModelFor`), `applyProviderDisabled`.
- `cliMain` en texto plano (el CLI Nim no usa rich) + recablear `connections`
  en `waku.nim` si toca (solo ese dispatch).
- Surfaces: mismos dos archivos (extensión) + `nim/src/waku.nim` (solo
  dispatch connections) si hace falta.

## Gates
- TDD con RED observado, `nimble test` verde, 0 warnings, sin red.
- Verificación independiente accept / accept-with-notes + notas / reject.
- Commit de unidad en la rama feature, sin push/PR.
- Regla 9: README + nim-port.md en el mismo cambio.
