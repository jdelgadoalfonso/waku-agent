# Orchestrator instances

Thin orchestrator of same-binary role processes with single dashboard and dual Overview.

## Specs

- S1: "quiero transformar waku-agent en un orquestador de waku-agents que puedan delegar en grafos o en loops"
- S2: "los subagentes serían instancias" / "había pensado procesos del mismo binario con rol distinto"
- S3: "tambien quiero mantener que siempre tengan un dashboard pero quiero modificar drasticamente ese dashboard"
- S4: "quiero mantener overview, gateway, loop, memory, tools, database, observability, evals y el resto de cosas. Pero el Overview quiero que se muestre el arnés en caso de funcionar como un agente o el grafo en caso de usar un plugin de grafo. Y que se muestren las mismas animaciones que se ven ahora mismo además de tener la observabilidad y la trazabilidad."
- S5: "lo del dashboard único en el orquestador me parece genial, pero tenemos que seguir teniendo la trazabilidad y la observabilidad completa, no solo del orquestador, sino también de los subagentes que se ejecuten."
- S6: "ok, vamos a abrir la propuesta con los tres lotes"
- S7: "también tendriamos que tener en el dashboard la posibilidad de ver los subagentes con su tipo y la comunicación entre si"
- S8: "y que se vea en tiempo real como pasan los mensajes en el grafo"

## Tasks

- T1 (S1,S2,S6): Lot 1 — done: T1.1 contract 1acf693, T1.2 supervisor c7b08fb, T1.3 aggregate c40f24e, T1.4 gather worker 59d753f, T1.5 evals+tracking 59daade
- T2 (S1,S2,S6): Lot 2 — done T2.1 registry 82f0734, T2.2 router 419a986, T2.3 plumbing def1430; T2.4 evals+docs in progress (53/53 focused green; .env.example mention deferred)
- T3 (S3,S4,S5,S6,S7,S8): Lot 3 — single dashboard, dual Overview, agents panel with kind loop|graph, inter-agent edges, real-time message waves, same animations, per-agent observability — route: proposal only — commit: -
  - T3.1 Overview dual: expand archSVG for loop turns, graphPanel for graph-plugin turns by last turn graph.route; archSVG byte-frozen — done, see L7
  - T3.2 Agents panel: new agentsPanel in Overview with {name, kind, pid, state, cost, last_route} from registry describe in /api/data — proposal only
  - T3.3 Edges + realtime waves: delegation/message events in same JSONL, reuse animateGraphStage + existing 450ms/100ms tickers, no new loop — proposal only
  - T3.4 Per-agent observability: /api/observability + /api/events aggregate per agent, SSE done extends agents:[{agent,route,reason,path,cost}], backward compat — proposal only
  - T3.5 Evals + docs: nim/tests/test_orchestrator_*.nim + static/design/observability pins, docs same PR, make nim-build for embed — proposal only
- T4 (S1-S6): Maintainer yes on docs/orchestrator-instances-design.md before any code — route: proposal gate — done: maintainer yes total 2026-11-05 (L6) — commit: e42f634

## Log

- L1 (verbatim): "quiero transformar waku-agent en un orquestador de waku-agents que puedan delegar en grafos o en loops / los subagentes serían instancias / había pensado procesos del mismo binario con rol distinto / si, tambien quiero mantener que siempre tengan un dashboard pero quiero modificar drasticamente ese dashboard / quiero mantener overview, gateway, loop, memory, tools, database, observability, evals y el resto de cosas. Pero el Overview quiero que se muestre el arnés en caso de funcionar como un agente o el grafo en caso de usar un plugin de grafo. Y que se muestren las mismas animaciones que se ven ahora mismo además de tener la observabilidad y la trazabilidad. / lo del dashboard único en el orquestador me parece genial, pero tenemos que seguir teniendo la trazabilidad y la observabilidad completa, no solo del orquestador, sino también de los subagentes que se ejecuten. / ok, vamos a abrir la propuesta con los tres lotes"
- L2 (verbatim): "también tendriamos que tener en el dashboard la posibilidad de ver los subagentes con su tipo y la comunicación entre si"
- L3 (verbatim): "y que se vea en tiempo real como pasan los mensajes en el grafo"
- L4 (decision, verbatim): "vamos a commitear T1.5 y vamos a arregar esos test despues" — full-suite `test_integrations` failure (whatsapp/discord field counts, golden env block) recorded as pre-existing and deferred; lot-1 evals (15/15 focused) stay green.
- L5 (decision, verbatim): "si" — abrir lote 3 en T3.1-T3.5 y empezar por propuesta T3.1 sin codigo hasta si de T4.
- L6 (decision, verbatim): "si total" — T4 maintainer yes total sobre docs/orchestrator-instances-design.md; T3.1-T3.5 pueden pasar a codigo por slices.
- L7 (T3.1): RED `overviewMode` undeclared in `nim/tests/test_orchestrator_overview.nim`; GREEN `overviewMode(turns)` + `overview_mode` in `/api/data` (`nim/src/dashboard.nim`) and dual `<details>` in `data/static/js/views.js` with `overview_mode` fallback to `turns[0].graph.route`; archSVG untouched. Evidence: new 3/3, `test_dashboard` 137 OK, `test_design_system+test_observability` 68 passed, `test_static_assets` 7 passed.
