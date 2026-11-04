# Plugin grafos con rutas — paso 4

Cambio autorizado. Los manifiestos declaran aristas: un decl `router` trae sus `routes` (label → dst contra nodos del manifiesto) y `buildPluginGraph` construye routers reales en vez de rechazarlos. Además: `log` aterriza en el tracer (además de stderr) y los handles expiran con ventana definida.

Estado al 2026-11-04. Base `c4fb42c`. Implementado, sin commit: rutas
declarativas en el manifiesto (S1), `log` al tracer (S2), handles con
expiracion (S3) y la fixture con el diamante mas sus pins (S4). Decisiones
tomadas donde el spec callaba o se contradecia: ver "Decisions".

## Specs

- **S1 — Rutas declarativas.** El decl `router` del manifiesto trae `routes: [{label, dst}]` (`dst` = `"END"` o nodo del manifiesto; labels únicas por router; router sin routes = rechazo). `buildPluginGraph` añade el nodo + `addRouter` con `pluginRouter`; se conserva la arista de entrada, se omiten las de salida del router (jump-only). Label desconocida en runtime = motor tal cual (errors + drain). Las menciones a "step 4" como futuro (tests + comentarios) se actualizan con el cambio (regla 9).
- **S2 — Log al tracer.** `hostLog` emite `plugin_log` vía el `notify` guardado en el `HostCall` (hereda el tag `node=` gratis), además de stderr. Sin llamada viva = solo stderr. Waterfall/receipt no lo muestran (listas cerradas, sin cambio).
- **S3 — Handles con expiración.** `pluginNode` YA tiene try/finally (verificado en el mapa); falta emparejar `pluginRouter` (hoy sus host fns responden `noLiveCall`). `expireHandle` en `pluginGraphTurn` tras `runGraph` como red de seguridad. Ventana documentada: begin→end del nodo. Doble llamada nodo+router: se ACEPTA (routers stateless; el fn no puede pasar el label por estado, `_`-keys no mezclan).
- **S4 — Testeado.** Fixture con diamante (tool → router → dos ramas) end-to-end offline; pin de log en trace; pin de handle expirado; pin de `dst` inexistente rechazado.

## Tasks

| ID | Tarea | Spec | R |
|---|---|---|---|
| T1 | `routes` en manifiesto + `buildPluginGraph` con routers | S1 | P |
| T2 | `log` al tracer + expiración de handles (try/finally) | S2, S3 | P |
| T3 | Fixture diamante + pins + verificación + commit | S4 | P |

## Decisions

- **Router sin routes se rechaza en `buildPluginGraph`, no en `loadPlugin`.**
  `nim/tests/fixture_plugin.nim` (la fixture del paso 2, fuera de las
  superficies editables de este paso) declara un router sin routes, y
  `test_plugin_loader` tiene que seguir en verde; rechazarlo al cargar rompe
  esa suite sin tocar un archivo que este paso no puede tocar. `loadPlugin`
  sigue validando todo `routes` que reciba (forma, strings no vacios, labels
  unicas, `dst` = `END` o nodo del mismo manifiesto); el router sin aristas se
  rechaza donde vivia el mensaje viejo del paso 4, y `loadPluginGraphs`
  mantiene el fallo fail-open (una linea en stderr, sin registro, la gateway
  cae al loop).
- **La cadena termina en un router.** Un manifiesto es un prefijo lineal que
  puede acabar en router; todo decl posterior al primer router es jump-only
  (un target), nunca un nodo encadenado. Asi "ninguna arista de salida del
  router" vale para todo el build y no solo para el decl siguiente, y
  `describe()` no miente: una ruta es una arista condicional, nunca una
  solida. Un segundo router es el mismo jump-only y se alcanza por el `dst`
  de otro router.
- **Los nombres del manifiesto se ensanchan antes de `addRouter`.**
  `routes.dst` nombra el nodo del manifiesto (`shout`); los nodos del grafo
  son `plugin:<name>/shout`. Ese ensanche es lo que deja a `addRouter`
  re-validar ambos extremos gratis, y por eso el `target` del evento `route`
  nombra el nodo del grafo.
- **`routes` se acepta en cualquier kind.** El spec dice que cada decl lo
  lleva opcional; todos se validan igual y solo las rutas de un `router`
  llegan al motor.
- **La entrada viva de un router no lleva observer.** La firma de `RouteFn`
  en el motor no tiene `notify`, asi que un `log` o una llamada al modelo
  hecha desde dentro de un router queda en stderr / fuera del trace. La
  llamada de un NODO es la que lleva el observer: de ahi salen el evento
  `plugin_log` pineado y el evento llm metereado. Queda como limitacion.
- **Una libreria, cinco nodos.** `chainfx` crece con el router
  (`pick_branch`) y la rama (`shout`) en vez de un segundo `.so`; los asserts
  viejos que pineaban `nodes.len`/`edges.len` se movieron con el. Las formas
  rotas de `routes` son builds del mismo fixture con
  `-d:routeFx=dangling|duplabel|noroutes|badshape`, asi cada rechazo se pinea
  a traves de una libreria real.

## Log

- **L1** (usuario, verbatim): "ok, adelante"
- **L2** (diseño): pasos 1-3 listos (`c5ad777`, `4c993f8`, `c4fb42c`); el manifiesto no declara aristas y `buildPluginGraph` rechaza `router` apuntando a este paso. Base: handoff explorer pendiente.
- **L3** (implementacion): S1-S4 en `graph/plugins.nim`, `graph/hostfns.nim`
  y `dashboard.nim`; fixture `chainfx` con diamante; pins nuevos en
  `test_plugin_graphs.nim`. Conteos: `test_plugin_graphs` 17 OK,
  `test_plugin_loader` 5, `test_plugin_registry` 7, `test_graph` 27,
  `test_workflows` 28, `test_gateway_graph_select` 5, `test_dashboard` 137,
  cero FAILED en todas.
