# Generic workers

Any loop or graph workflow as a same-binary worker process, behind the
delegation contract the orchestrator already speaks.

## Specs

- S1: "creo recordar que el unico grafo que hemos metido es gather, habría que extenderlo para cualquiera, ¿estoy en lo cierto?"
- S2: "si, vamos con esa siguiente fase de diseño"
- S3 (contexto heredado de `odd/tasks/orchestrator-instances.md` S2): los subagentes son instancias, procesos del mismo binario con rol distinto; un worker corre un loop o un grafo y al orquestador solo le importa el contrato.

## Tasks

- T1 (S1,S2): Proposal — `docs/generic-workers-design.md` + sí maintainer antes de código — route: proposal gate — done: sí 2026-11-09, see L5
- T2 (S1,S3): Worker table en `nim/src/workers.nim` nuevo — una tabla agente→runner con forma común (task→child lines); `workerChildLines` por lookup, `runWorkerCmd` construye contexto (app+model+snapshot); `gather` primera entrada sin cambio — done, see L6
- T3 (S1,S3): First worker headless (`brief`) con pins — done, see L7
- T4 (S1): Evals + docs — done, see L8
- T5 (S1): Third worker (grafo plugin) — el usuario elige grafo plugin; exige antes el diseño de aislamiento fuera-de-proceso; luego mitad headless + pins — in progress, see L10

## Log

- L1 (verbatim): "creo recordar que el unico grafo que hemos metido es gather, habría que extenderlo para cualquiera, ¿estoy en lo cierto?"
- L2 (verbatim): "si, vamos con esa siguiente fase de diseño"
- L3 (confirmación 2026-11-09): solo `gather` tiene mitad worker — `delegateWorkers == @["gather"]` (`nim/src/delegate.nim:30`), `workerChildLines` deriva a `runGatherWorker` para cualquier otro agente (`nim/src/waku.nim:689`), y el pin T17 fija un solo worker productivo. El dispatcher T17 ya reparte N rutas; lo que falta es la ejecución por agente.
- L4 (diseño 2026-11-09): «¿dónde estará esa tabla? ¿cómo se va a implementar?» — respuesta: tabla en `nim/src/workers.nim` nuevo (no en `graph/agents.nim`: topología del gate ≠ ejecución); runner de forma común; `brief` segunda entrada con un half module nuevo.
- L5 (decision, verbatim): "ok, vamos a implementar la propuesta" — sí maintainer a `docs/generic-workers-design.md` con `brief` como primer worker; rama `feat/generic-workers`.
- L6 (T2 in progress 2026-11-09): tabla en `nim/src/workers.nim` con `gather` como primera entrada; `workerChildLines` pasa a lookup; sin cambio de comportamiento.
- L7 (T3 done 2026-11-09): RED `worker_brief` ausente; GREEN `worker_brief.nim` (`BriefFn`, `runBriefWorker`), `brief.nim` `runBriefHeadless` (override+snapshot, sin outbox), tabla con `brief`, `runWorkerCmd` con ambas closures, `delegateWorkers` +`brief`, pins test_cli/test_delegate actualizados al nuevo comportamiento. Hallazgo: `turn`/`endTurn` escribían con tracer silente — guard `silent` en `trace.nim` + pin actualizado al contrato nuevo (un writer por turno). Pins: workers 11/11, workflows T3 4/4, trace silent OK.
- L8 (T4 done 2026-11-09): `nimble test` exit 0, 1821 OK (baseline 1806 + 15 nuevos); `make nim-build` exit 0; `test_repo_docs` sin rojos; commits por unidad en `feat/generic-workers`, sin push.
- L9 (2026-11-09): el usuario elige «tercer worker» como siguiente punto; pendiente elegir el agente (candidatos: loop/full o grafo plugin; triage es el gate y no tiene sentido como worker).
- L10 (2026-11-09): tercer worker = grafo plugin; los plugins corren in-process por `dlopen` y llaman de vuelta vía HostFns, así que moverlos a proceso worker exige diseñar el aislamiento (qué cruza el wire y qué se queda) antes de picar código.
