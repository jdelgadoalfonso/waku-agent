# Plugin HostFns real + primer nodo en producción — paso 3

Cambio autorizado. Construir la tabla `HostFns` de verdad donde ya viven cliente y tools, y enchufar al menos un nodo plugin en un graph real. El loader (paso 2) hoy pasa tabla de nulls; este paso le da capacidad.

Estado al 2026-11-04. Base `4c993f8`. Sin código aún.

## Specs

- **S1 — Tabla real con ciclo de vida de proceso.** `HostFns` se construye una vez donde hay `LlmClient` + `ToolRegistry` + home, vive lo que los plugins, y cada fn responde el envelope `{"ok":true,"value":...}` / `{"ok":false,"error":...}`. Cita del usuario: "ok, vamos con el paso 3".
- **S2 — Capacidades por alcance decidido.** Qué fns son reales en este paso y cuáles siguen null (el plugin que pida una null recibe puntero null y debe responder `ok:false`).
- **S3 — Grafos nuevos desde el manifiesto.** `buildPluginGraph` encadena los nodos tool/llm/agent del manifiesto en orden (el manifiesto no declara aristas, la cadena es la única topología derivable); un `router` rechaza el registro (llega en el paso 4). Registro como `plugin:<nombre>`, resoluble por el gateway y visible en el dashboard vía registry. Fail-open: sin `.so`, el graph no existe y todo resuelve como hoy.
- **S4 — Testeado.** Pin determinista offline (cliente scripteado como en test_graph, sin red) de tabla + inserción + fail-open sin plugin.

## Tasks

| ID | Tarea | Spec | R |
|---|---|---|---|
| T1 | Construir `HostFns` real (ciclo de vida + envelope) | S1, S2 | P |
| T2 | `buildPluginGraph` + registro `plugin:<nombre>` + resolución gateway/dashboard | S3 | P |
| T3 | Pin determinista + verificación + commit | S4 | P |

## Log

- **L1** (usuario, verbatim): "ok, vamos con el paso 3"
- **L2** (diseño): pasos 1 (registry, `c5ad777`) y 2 (loader, `4c993f8`) listos; el loader pasa tabla de nulls. Base: handoff explorer `mw2hha5b-5-kuy4` (devuelto 2026-11-04).
- **L3** (decisiones del paso 3, CORREGIDO por el usuario): la idea es **crear grafos nuevos desde plugins**, no insertar ramas en gather. HostFns **completo** (las 6 reales; verbatim usuario: "Completo"). Inserción: **`buildPluginGraph` desde el manifiesto** (cadena de nodos tool/llm/agent en orden; un `router` en el manifiesto rechaza el registro — los grafos con rutas llegan en el paso 4, el manifiesto no declara aristas). La rama scan en gather queda descartada (ver explicación en el hilo, pero el usuario aclaró: verbatim "la idea que te estaba transmitiendo era el crear nuevos grafos"). Micro-decisiones: (a) `llmComplete.value` = objeto response completo (content + stop_reason + usage); (b) `log` → stderr en este paso; (c) `handle` indexa inputs vivos del run para `stateKeys`; (d) `fetch` = wrapper fino propio sobre `http.nim`; (e) `needs` → null según contrato; (f) tabla con ciclo de vida de proceso (tras `buildRegistry`, guardada en `Waku`).
- **L5** (verificación del parent + commit): suites observadas por el parent — plugin_graphs 12, loader 5, registry 7, graph 27, workflows 28, gateway 5, dashboard 137, 0 FAILED. `make nim-test` completo tropieza en `test_integrations`, VERIFICADO pre-existente (falla igual en árbol limpio vía `git stash`). Desviaciones asumidas y documentadas: (a) los grafos plugin NO se filtran por `WAKU_PLUGINS` — cargar el `.so` es el acto de habilitar (registry L:62-66, test lo pinea); (b) `arena_live.nim` construye su propio `Waku` fuera de los dos puntos de wiring → turnos de arena sin tabla ni grafos plugin; (c) `fetch`/`llmComplete`/`toolCall` de plugin caen en trace+ledger por construcción (metered `kind:"plugin"`), sin eval de ledger dedicado.
