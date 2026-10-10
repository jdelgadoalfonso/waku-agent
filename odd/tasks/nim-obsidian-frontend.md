# Nim port — Obsidian en el frontend (reemplazo de Notion)

Objetivo: que el port Nim ofrezca Obsidian donde hoy solo aparece Notion.
Rama: actual. Estrategia de entrega: ask-on-risk. Runner: `nimble test` + verificación en navegador para el JS.

## Specs

- **S1** (petición del usuario, verbatim):
  > he visto una cosa que no se como podemos corregir, tomé la decisión de usar obsidian en lugar de notion en el port en Nim, sin embargo, en el frontend solo aparece notion. ¿puedes ayudarme a resolver el conflicto?
- **S2** (decisión previa, verbatim — alcance):
  > Solo port Nim
- **S3** (decisión previa, verbatim — reemplazo):
  > En python no lo vamos a implementar, solo en Nim y es para reemplazar a Notion
- **S4** (decisión actual, verbatim — opción elegida):
  > Frontend genérico + Obsidian en Nim
- **S5** (alcance técnico): en Nim, `nim/src/integrations.nim` expone `key: "notion"` con opciones `sqlite, notion`; el JS compartido `waku/ops/static/js/views.js` tiene textos fijos de Notion (`Could not read episodes from Notion`, `Episodes currently live in Notion`, comentarios). Python (`waku/integrations.py`, `waku/ops/dashboard.py`) sigue con Notion intacto.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/integrations.nim`: fila `notion` -> `obsidian` (choice `sqlite, obsidian`, campo `WAKU_OBSIDIAN_VAULT`, sin extra/import, enabled en `obsidian`) + bloque env-example; `isHexChar`/`normalizeDatabaseId`/`notionNormalize` eliminados por decisión del usuario | S1, S3, S4, S5 | inline, test-first, suite offline | done en `8836e32` (RED L5, GREEN L6) |
| T2 | `waku/ops/static/js/views.js`: mensajes genéricos por `episodes_source` (error, nota de Database, comentarios) sin romper Notion en Python + `obsidian.svg` neutro (MIT) y README de logos | S1, S4, S5 | inline, `node --check` OK | done en `92da9b0` |
| T3 | Pins Nim: `nim/tests/test_integrations.nim` (fila obsidian, opciones, env-example) + `nim/tests/test_dashboard.nim` + `test_supervisor_hookup`/`test_episodes`/`test_obsidian`/`test_embed` en verde; 86 evals Python (`design_system`, `rulebook`, `slash_commands`, `treg_connect`, `first_run_setup`) en verde | S1, S4 | inline | done (suites en `8836e32`, resto en `92da9b0`) |
| T4 | Docs que el cambio vuelve falsos: comentarios en `views.js`/`integrations.nim`, conteo del embed (55→62 archivos) en `nim/src/dashboard.nim` y `nim/README.md` | S1, S4 | doc | done en `92da9b0` |

## Log

- **L1** (usuario, verbatim): "he visto una cosa que no se como podemos corregir, tomé la decisión de usar obsidian en lugar de notion en el port en Nim, sin embargo, en el frontend solo aparece notion. ¿puedes ayudarme a resolver el conflicto?"
- **L2** (investigación): backend Nim ya usa Obsidian (`nim/src/obsidian.nim`, `episodeStoreFor` en `nim/src/app.nim`, `episodesFor`/`stateRows` en `nim/src/dashboard.nim` con `episodes_source` sqlite/obsidian, `notion` en error honesto). El conflicto está en `nim/src/integrations.nim:302` (sigue `key: "notion"`, opciones `sqlite, notion`) y en `waku/ops/static/js/views.js:103,623` (textos fijos de Notion). Python intacto por S2/S3.
- **L3** (decisión del usuario): opción "Frontend genérico + Obsidian en Nim".
- **L4** (base): árbol limpio en `abdb225` (`feat(nim): make mimalloc_nim a mandatory dependency`); `nim/config.nims`, `.codegraph/` y `.pi/` quedan sin commitear (config local y estado de herramientas).
- **L5** (RED, T1): tests reescritos a `obsidian` con el código aún en `notion` → `missing static row: obsidian`, falla el orden de 13 claves y `# Choices: sqlite, obsidian.`; suite en rojo como se esperaba.
- **L6** (GREEN, T1-T3): `test_integrations` 0 FAILED, `test_dashboard` 133 OK / 0 FAILED, `test_supervisor_hookup`/`test_episodes`/`test_obsidian`/`test_embed` en verde, `node --check views.js` OK, 86 evals Python en verde. Python intacto (Notion sigue su fila y su `notion_store.py`).
- **L7** (commits): `8836e32` registry Nim, `92da9b0` frontend/docs; este documento cierra sus evidencias aquí.
