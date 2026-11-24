# Engram memory alternative — relevo local a Waku Memory

Feature: usar Engram MCP (`engram_mem_*`) como alternativa cuando Waku Memory no está disponible. Sin cambiar el loop: `waku connect engram` + reconocimiento en observabilidad.

## Specs

S1: `waku connect engram` da de alta un server `engram` en `~/.waku/mcp.json` como `{"name":"engram","command":"engram","args":["mcp"]}` stdio por defecto, con estados added/present/conflict como `waku-memory` y `treg`.
S2: El nombre `engram` es obligatorio porque `brain.nim` busca literal `engram_mem_search` / `engram_mem_get_observation` y `reports.nim` busca `engram_mem_save`.
S3: `observe.nim` reconoce `engram_mem_*` como fuente memoria (`mcp:engram` o `memory`), con `spanKind` retrieval/write igual que `waku_memory_*`.
S4: `observability.nim` y `turn_evals.nim` cuentan Engram en el bucket de memoria, no en `other`.
S5: Docs (`docs/integrations.md`, `skills/waku-memory/SKILL.md` o nota aparte) explican la vía manual y `connect engram` sin prometer precios ni planes.

## Tasks

- T1: `connect engram` en `nim/src/connect.nim` (S1) — route: inline — DONE: connectorNames + addEngramServer/engramConnect + dispatcher, 3 tests en test_connect
- T2: Reconocimiento en `observe.nim` + `observability.nim` + `turn_evals.nim` + `receipt.nim` check (S3, S4) — route: inline — DONE: engramPrefix + spanKind + toolType datastore + buckets memoria, test_observe actualizado
- T3: Docs + tests (`test_connect`, `test_observe`, `test_brain`) — route: inline — DONE: docs/integrations.md Local alternative Engram; suites observe/connect/observability/turn_evals/brain/receipt GREEN

## Log

L1: User request verbatim: "Estoy viendo que Waku Memory no está disponible, tendríamos que buscarle una alternativa a esta memoria"
L2: User constraint verbatim: "Ya tenemos un MCP de engram"
L3: User authorization verbatim: "1. preparalo tal y como lo propones"
L4: Explorer map done (task mwnc0g4d-1-uzw7): connect.nim:35,54-56,238-313,436-449; mcp.nim:60-91,212-224,344-369,897-912; brain.nim:58-77,112-119; reports.nim:51; receipt.nim:100-106; observe.nim:42,91-98; observability.nim:998,1256; turn_evals.nim:476,757
L5: Gate report tracked separately: "en cada aparece gate failed open (LlmRefused) aunque luego me responde" — dashboard chat, lo elimina tras responder, modelo nemotron OpenRouter, sin WAKU_SLOT_GATE [2026-11-24: CERRADO en odd/tasks/gate-failopen-quiet.md fases A+B+extensión, commit `bda7f7b`: el aviso lleva el mensaje del proveedor, `(repeats)`, y el gate degrada ante LlmRefused sin más llamadas]
