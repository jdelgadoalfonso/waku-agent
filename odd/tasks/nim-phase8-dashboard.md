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

## 8b — mutaciones + live server (HECHO, sin commits)
- POST JSON vía `handlePost(deps, target, body)`: `/api/chat` (`chat` →
  `chatFn`), `/api/memory` (`memory_action`), `/api/settings`
  (`apply_settings`), `/api/query` (`run_query`), `/api/session`
  (`session_action`), `/api/pin` (`pin_action`), `/api/connections`
  (`apply_integration`), `/api/connections/test` (`test_integration`),
  `/api/providers` (`apply_provider` / `apply_provider_disabled`),
  `/api/voice` (`transcribe_audio` vía `voiceFn`, blob crudo, no SSE).
  `/api/reveal` (`reveal_path`) vive en `handleGet` — en Python es GET.
- Errores como Python: ruta conocida → 200 con `{"error"}` (nunca 500);
  POST desconocido → 404; JSON roto → 400; arena (8c/8d) → 501 honesto.
- Streams vía `handleStream(..., emitFrame)` + `sseFrame(kind, ev)`
  (`data: {...}` con merge `{'kind': kind, **ev}`): `/api/chat/stream`
  (`chat_stream`), `/api/graph/stream` (`graph_stream`, sin runner →
  `unknown workflow` honesto); arenas → un frame done-error (el 501 en
  forma SSE).
- Server loop: `pickPort` (walk base+10, mensaje de Python con en dash),
  `prepareDashboard` (host/port desde env, probe inyectado),
  `defaultServe` (accept loop con `net` stdlib, `Connection: close`),
  `runDashboardCmd` (warning off-loopback del llamador, URL, reconcile →
  serve → shutdown en `finally`). Supervisor gateway = seams nil.
- `waku.nim`: `dashboard` → `runDashboard(dotenvStart, serve)`; el
  binario sirve (`serve=true`), `runCommand` in-process valida sin
  sockets (`checkDashboardCmd` con probe libre) — el pin 4e sigue verde.
- Agente vivo: `WakuBox` perezoso (sin global mutable) tras `chatFn`,
  `chatStreamFn`, `sessionFn`; `donePayload` compartido por ambas
  puertas (regla one-implementation de Python); `graphStreamFn` nil
  (runner de comandos pendiente); `voiceFn` nil (sin backend STT).
- Tests: `test_dashboard.nim` 22 → 74 (52 nuevos: framing SSE, cada POST
  happy+error, reveal GET, superficie ⊆ `PINNED_POST`, 501/404 directos
  de 8a, pickPort/prepare/run con stubs). `nimble test` verde, 0 warnings.
- Divergencias 8b (motivo): accept loop single-threaded, no
  `ThreadingHTTPServer` (un usuario local; los polls esperan tras un
  stream largo — threading es follow-up, no cambio silencioso);
  `settings_info`/vistas de conexiones en subset (el contrato pinea
  PATHS, como `/api/data` en 8a); `run_query` abre state.db normal pero
  la gramática no admite escrituras (equivale al `mode=ro`); `save_skill`
  solo bajo `home/skills` (skills del repo read-only); episodios Notion
  → error honesto; `statusOf` sin `warn` (el seam `app` no lo tiene);
  probes de conexiones sin cablear (apply valida+persiste, test dice
  `no test available`); slash-commands corren como turnos planos;
  POST desconocido → 404 con JSON (Python: 404 vacío).

## 8c — arena de modelos (HECHO, sin commits)
- Nuevo `nim/src/arena.nim` (la arena posee la carrera, el dashboard el
  HTTP/SSE — el espejo del split Python `dashboard.py` → `arena.py`):
  store `<home>/compare/history.jsonl` (`loadRuns`/`saveRuns`/`appendRun`/
  `clearRuns`, cap 50, `slim` con reply a 1000, gate aplanada, tools a
  `[nombres]`), `aggregateRuns`, `history_response` (reprice + aggregate
  con `rate_in`/`rate_out`/`cutoff`), `compareClear`, `compareDeleteRun`,
  `compareRegrade` (`only_missing` default true, filtro `spec`, nunca
  grada error/reply-vacía), `compareStreamRun` (valida → race → grado
  gentil post-carrera → persiste → `done`; hiccup de historial nunca
  falla la carrera) + `judgeDisplayName`.
- Seams: `home` por parámetro, `RaceFn`/`JudgeFn` inyectados, reloj vía
  `ts` explícito (`nowIso` del dashboard); cero red, tests 100% offline.
- GET `/api/compare/history` + POST `clear`/`regrade`/`delete_run` +
  `compare/stream` cableados en `dashboard.nim` (`SseEmit` vive ahora en
  `arena.nim` y se re-exporta; `RaceFn`/`JudgeFn` como alias + campos
  `raceFn`/`judgeFn` en `DashboardDeps`, nil en el wiring vivo).
- Tests: `nim/tests/test_arena.nim` nuevo, 25 (store, slim, aggregate,
  reprice, clear/delete, regrade filtros, pipeline feliz/errores, judge
  name); `test_dashboard.nim` 74 → 80 (6 de cableado 8c; los tests 501
  de 8a/8b recortados a rutas 8d). `nimble test` verde, 0 warnings.
- Divergencias 8c (motivo): sin harness vivo el `RaceFn` es stub/nil →
  done-error honesto (precedente: graph sin runner en 8b); `judge_model`
  viaja opaco al `JudgeFn` (la selección del referee vive en el seam);
  `tools` ya `[nombres]` pasan tal cual en regrade, se extraen al gradar
  en stream (ambos como Python); single-threaded, sin `ThreadPoolExecutor`
  (misma razón que 8b); `fieldOf` en vez de `getOrDefault` (el nil de
  std/json revienta `$` — gotcha para `gotchas.md` en otra unidad).
- `test_route_contract.py` intacto: misma superficie (consts PINNED sin
  tocar, asserts ⊆ verdes en Nim); sus 3 fallos locales son ambientales
  preexistentes (`No module named 'anthropic'` con y sin este cambio).

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
