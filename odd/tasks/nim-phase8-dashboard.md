# Nim port — phase 8: dashboard backend (Ops + dashboard)

## Goal
Port `waku/ops/dashboard.py` (1271 líneas: servidor + API del dashboard) a
`nim/src/dashboard.nim`, en cuatro unidades para proteger revisión. El
frontend (`waku/ops/static/`) NO se toca: se sirve tal cual desde disco.
Toda lectura por parámetro (`home`, `staticDir`, `env`), fetch inyectado;
cero red saliente, tests 100% offline con transporte stub (regla phase 3e).

Gate de paridad: `evals/deterministic/hosted/test_route_contract.py` debe
seguir verde — las unidades 8x no añaden ni quitan rutas del contrato, solo
implementan las que Python ya sirve. `nim/src/waku.nim` NO se toca en 8a:
el stub `dashboard` de phase 4e queda (el loop servidor vivo llega con la
unidad que lo necesite); cambiarlo rompería `test_cli.nim`.

## 8a — lecturas GET + estáticos (BOUNDED, sin commits, sin push)
- Handlers puros `(status, contentType, body)` vía `handleGet(deps, target)`:
  `/api/data` (SUBSET de estado, no el `collect()` completo), `/api/models`
  (`listModels` con `FetchFn` inyectado), `/api/events` (`events_since`
  con cursor), `/`, `/static/*` (confinado al dir, `STATIC_TYPES` paridad),
  fallback a `index.html` como Python. Rutas pin-pero-posteriores
  (`/api/reveal`, `/api/compare/history`, arenas) responden 501 honesto,
  nunca el shell del SPA como datos; paths API desconocidos 404.
- `DashboardDeps`: home, staticDir, provider/model/smallModel/baseUrl/apiKey,
  providers, env, fetch, `today` + `nowIso` (determinismo en tests).
- `bindHost` (loopback por defecto, sin el print — lo hace el llamador) y
  `dashboardPort` (precedencia `WAKU_DASHBOARD_PORT` → `PORT` → 7777).
- Tests: 22 en `nim/tests/test_dashboard.nim` (tipos estáticos, traversal,
  fallback index, models sin-fetch/fallo/listado, events tail/replay/reset,
  data spend+trace, superficie ⊆ `PINNED_GET`, bind/port).
- Surfaces: `nim/src/dashboard.nim` (nuevo) + `nim/tests/test_dashboard.nim`
  (nuevo). `waku.nim` intacto. Frontend intacto.

## 8b — mutaciones + live server (PENDIENTE)
- POST `/api/chat`, `/api/memory`, `/api/settings`, `/api/query`,
  `/api/session`, `/api/pin`, `/api/connections`, `/api/connections/test`,
  `/api/providers`, más `/api/reveal` (side effect: abre el editor).
- Streams SSE (`/api/chat/stream`, `/api/graph/stream`) y voz (`/api/voice`).
- El loop servidor (puerto walk 7777+10, supervisor gateways) y el dispatch
  `dashboard` en `waku.nim`.

## 8c — arena de modelos (PENDIENTE)
- `/api/compare/history` (+ `history_response`: reprice + aggregate),
  `/api/compare/clear`, `/api/compare/regrade`, `/api/compare/delete_run`,
  `/api/compare/stream`.

## 8d — memory arena + judgment arena (PENDIENTE)
- GET `/api/memory-arena`, `/api/memory-arena/stores`, `/api/judgment-arena`;
  POST `/api/memory-arena/clean`, `/api/memory-arena/stream`,
  `/api/judgment-arena/key`, `/api/judgment-arena/stream`.

## Decisiones
- Static-en-disco por ahora: `staticDir` apunta al checkout
  (`waku/ops/static/`). El embed en compilación es decisión de CIERRE de
  fase (binario único sin Python): anotada como pendiente, no implementada.
- `/api/data` es subset de estado (identidad + spend + health + puntero de
  trace). El `collect()` completo (turnos, introspección db, skills,
  topologías, eval report) se reparte en 8b–8d; el contrato pinea PATHS,
  no claves de payload.
- Cuerpos JSON con `$` stdlib (compacto), no `jsonDumps` espaciado: el
  navegador parsea, la paridad byte a byte solo aplica a archivos que el
  dashboard LEE (usage.jsonl, meta de chat).

## Divergencias con Python (motivo)
- Missing `index.html` → 404, no 500: un frontend ausente es bug de
  despliegue, no traceback.
- `dashboardPort` con env no numérico → 7777; Python levantaría: arrancar
  no debe morir por un typo.
- `parseCursor("--1")` → ausente; Python 500earía en `int()`: un cursor
  de poll no vale un traceback.
- Warning off-loopback fuera de `bindHost`: el print es efecto lateral,
  lo hace el llamador.
- Respuestas `$` compacto vs `json.dumps` espaciado: ver Decisiones.
