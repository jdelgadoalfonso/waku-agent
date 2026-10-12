# MCP per-turn filter

Selective MCP activation per task to cut context cost. Proposal approved by user; spec lives in `docs/mcp-per-turn-filter-design.md`.

## Specs

S1: "me gustaría poder añadir MCPs para que el agente tuviera disponible más herramients. Lo ideal sería que no estuvieran siempres activas sino que, dependiendo de la tarea, las utilizara o no para minimizar el impacto en el consumo del contexto"
S2: "Filtro por turno"
S3: "adelante" (authorization to write proposal)
S4: "continua, está bien" (authorization to implement after proposal)
S5: "una cosa importante debe estar implementado tanto en Python como en Nim"

## Tasks

- T1 (S1, S2): Add tags + schemas_for() to ToolRegistry with deterministic eval — route: inline/worker — commit: fbd1309
- T2 (S1, S2): Read per-server tasks/when from mcp.json — route: inline/worker — commit: fbd1309
- T3 (S1, S2): Wire filter into run_loop() with per-turn log — route: inline/worker — commit: fbd1309
- T4 (S1, S2): Keep dashboard catalog and traces on full registry — route: inline/worker — commit: fbd1309
- T5 (S1, S2): Update docs (architecture, integrations, status, getting-started) + make gate/lint — route: inline — commit: fbd1309
- T6 (S5): Port tags + schemas_for() to Nim with Nim-side eval — route: inline/worker — commit: fbd1309
- T7 (S5): Read per-server tasks/when from mcp.json on Nim side + wire filter into Nim loop — route: inline/worker — commit: fbd1309
- T8 (S5): Update Nim docs + pass nim offline suite and build — route: inline — commit: fbd1309

## Log

L1: "Estaba pensando en meter una nueva funcionalidad, primero hagamos una exploración a ver que conclusiones obtenemos."
L2: User custom answer: "me gustaría poder añadir MCPs para que el agente tuviera disponible más herramients. Lo ideal sería que no estuvieran siempres activas sino que, dependiendo de la tarea, las utilizara o no para minimizar el impacto en el consumo del contexto"
L3: User chose "Filtro por turno" for proposal design.
L4: User said "adelante" to write proposal in docs/.
L5: Proposal written at docs/mcp-per-turn-filter-design.md.
L6: User said "continua, está bien" to implement.
L7: User added: "una cosa importante debe estar implementado tanto en Python como en Nim"
L8: T1-T3 implemented and verified (Python evals 9 passed, MCP triangulation 65 passed, related suites green); T4 verified (no ops/ changes); T5 docs updated and rulebook green.
L9: Full deterministic suite: 3306 passed, 2 failed — both pre-existing at HEAD (static-assets logos, turn-evals judge).
L10: T6-T7 Nim port implemented and verified (test_tool_filter.nim 11/11, nimble test 1487 OK, nimble build OK); factstore_fakes recompilation artifact restored.
