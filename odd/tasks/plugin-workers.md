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

## Log

- L1 (2026-11-09): el usuario elige grafo plugin como tercer worker; `textops` es el único plugin de ejemplo (`examples/plugins/textops/`, nodos upper/summarize/pick_long/expand, `needs` solo `llm` en summarize).
- L2 (decision 2026-11-09): tercer worker = grafo plugin; el gate ya ofrece rutas `plugin:<nombre>`, lo que falta es la ejecución aislada.
- L3 (diseño 2026-11-09): las seis HostFns son punteros C en el mismo espacio de direcciones — no pueden cruzar procesos; la propuesta acota a plugins `needs ⊆ {llm}` con `llm` servido por el cliente propio del worker.
- L4 (decision, verbatim): "ok, vamos con la implementación" — sí maintainer a `docs/plugin-workers-design.md` (con snapshot read-only para plugins); rama `feat/plugin-workers`.
- L5 (T2 done 2026-11-09): RED `worker_plugin`/`pluginRunHeadless` ausentes; GREEN `pluginWorkerEligible`, `worker_plugin.nim` (`PluginFn`, `runPluginWorker`, `pluginRunHeadless` con scope local + sink de uso/logs), tabla con entrada plugin, `runWorkerCmd` con rama `plugin:`, gate `workerAgents`+`liveDelegateFor` con `extra` en los 5 binders. Hallazgo: `turn`/`endTurn` ya tenían guard (T3 gen-workers); fixture loader no es runnable (router sin routes) → 2 fixtures nuevas. Pins: plugin_workers 20/20.
- L6 (T2+T3 done 2026-11-09): RED `worker_plugin`/`pluginRunHeadless`/gate ausentes; GREEN elegibilidad (`pluginWorkerEligible`), runner (+logs, empty→fail-open), headless con scope local + sink de uso/logs (2 fixtures nuevas), gate `workerAgents`+`liveDelegateFor` con `extra` en 5 binders, `runWorkerCmd` rama `plugin:`. Suite `nimble test` exit 0, 1840 OK (1821+19); `make nim-build` exit 0; commit 69791f4 (604+/13-) con Risk item 3, sin push.
