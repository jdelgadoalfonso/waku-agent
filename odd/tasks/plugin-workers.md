# Plugin workers

Graph plugins as same-binary worker processes: the plugin runs isolated
in the worker, the orchestrator keeps owning every effect.

## Specs

- S1: tercer worker = grafo plugin (decisión del usuario 2026-11-09, see L2)
- S2: los plugins corren hoy in-process por `dlopen` y llaman de vuelta vía las seis HostFns (`llmComplete`, `toolCall`, `stateKeys`, `fetch`, `stringFree`, `log`); moverlos a proceso worker exige diseñar qué cruza el wire
- S3 (heredado): un worker corre un loop o un grafo y al orquestador solo le importa el contrato; reglas slice-9 (sin writes, tracer silente, sin DB)

## Tasks

- T1 (S1,S2): Proposal — `docs/plugin-workers-design.md` + sí maintainer antes de código — route: proposal gate — done: sí 2026-11-09 (snapshot para plugins confirmado), see L4
- T2 (S1-S3): First plugin worker — done, see L5
- T3 (S1): Evals + docs — done, see L6
- T4 (S1-S3): textops as first real plugin proof — done, see L10-L11

## Log

- L1 (2026-11-09): el usuario elige grafo plugin como tercer worker; `textops` es el único plugin de ejemplo (`examples/plugins/textops/`, nodos upper/summarize/pick_long/expand, `needs` solo `llm` en summarize).
- L2 (decision 2026-11-09): tercer worker = grafo plugin; el gate ya ofrece rutas `plugin:<nombre>`, lo que falta es la ejecución aislada.
- L3 (diseño 2026-11-09): las seis HostFns son punteros C en el mismo espacio de direcciones — no pueden cruzar procesos; la propuesta acota a plugins `needs ⊆ {llm}` con `llm` servido por el cliente propio del worker.
- L4 (decision, verbatim): "ok, vamos con la implementación" — sí maintainer a `docs/plugin-workers-design.md` (con snapshot read-only para plugins); rama `feat/plugin-workers`.
- L5 (T2 done 2026-11-09): RED `worker_plugin`/`pluginRunHeadless` ausentes; GREEN `pluginWorkerEligible`, `worker_plugin.nim` (`PluginFn`, `runPluginWorker`, `pluginRunHeadless` con scope local + sink de uso/logs), tabla con entrada plugin, `runWorkerCmd` con rama `plugin:`, gate `workerAgents`+`liveDelegateFor` con `extra` en los 5 binders. Hallazgo: `turn`/`endTurn` ya tenían guard (T3 gen-workers); fixture loader no es runnable (router sin routes) → 2 fixtures nuevas. Pins: plugin_workers 18/18.
- L6 (T2+T3 done 2026-11-09): RED `worker_plugin`/`pluginRunHeadless`/gate ausentes; GREEN elegibilidad (`pluginWorkerEligible`), runner (+logs, empty→fail-open), headless con scope local + sink de uso/logs (2 fixtures nuevas), gate `workerAgents`+`liveDelegateFor` con `extra` en 5 binders, `runWorkerCmd` rama `plugin:`. Suite `nimble test` exit 0, 1840 OK (1821+19); `make nim-build` exit 0; commit 55106ff (605+/13-) con Risk item 3, sin push.
- L7 (fix 2026-11-09): la verificación independiente halló bug bloqueante — `runWorkerCmd` leía `task["message"]` pero el wire lleva `task`, así que toda delegación plugin corría con mensaje vacío. GREEN: `taskMessage` en `delegation.nim` + `pluginTaskRunner` testeable en `worker_plugin.nim` (pin end-to-end con fixture que ecos el mensaje); `runWorkerCmd` es un bind de una línea. Números L5/L6 corregidos (18/18, 55106ff). Suite `nimble test` exit 0, 1842 OK; `make nim-build` exit 0.
- L8 (smoke 2026-11-09): binario real `waku --role worker --agent plugin:workergreet` con home temporal (solo `plugins/`) responde `event` + `done{reply:"hello: echo hi"}` exit 0 y no escribe nada (sin `state.db`, sin `traces`, sin outbox). Cierra el hueco que la verificación dejó sin cubrir (ningún test lanza el proceso real).
- L9 (T4 open 2026-11-12): el usuario pide meter los plugins como clase con `textops` como prueba real; verificación VERIFIED sin bloqueos (elegible, path genérico sin cambio de wire, `.so` presente) + 5 no-bloqueantes (forma llm+router solo probada in-process, precondición nombre de fichero, 2 divergencias de docs, hazard WAKU_AGENTS vs WAKU_GRAPH); rama `feat/plugin-textops`.
- L10 (T4 smoke 2026-11-12): binario real `waku --role worker --agent plugin:textops` con home temporal (solo `plugins/textops.so` recompilado del ejemplo, 5 exports) y LLM inalcanzable responde `error{plugin answered nothing}` exit 0 y no escribe nada (solo el `.so` plantado; sin `state.db`, sin `traces`, sin outbox); el camino feliz (short+long con `expand`) queda pinnado offline con cliente scripteado en `test_plugin_workers.nim` T4.
- L11 (T4 done 2026-11-12): RED fixture ausente; GREEN `nim/tests/fixture_plugin_textops.nim` nuevo (forma textops: pure+llm+router, short y long) + pin T4 (elegible + headless con cliente scripteado, ambas ramas); `test_plugin_workers` 19 OK exit 0; `nimble build` OK (5.2M). Full `nimble test` detenido en `test_tls` preexistente fuera de superficie (dashboard.nim:3303, voice.nim:904 `except` en `finally`, del commit STT 87a0c80). Docs: `docs/plugin-workers-design.md` (estado T4, elegibilidad real, error real, WAKU_AGENTS vs WAKU_GRAPH). Commit en `feat/plugin-textops`, sin push.
