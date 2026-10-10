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
| T1 | `nim/src/integrations.nim`: fila `notion` -> `obsidian` (choice `sqlite, obsidian`, campo `WAKU_OBSIDIAN_VAULT`, sin extra/import, enabled en `obsidian`) + bloque env-example | S1, S3, S4, S5 | inline, test-first, suite offline | pending |
| T2 | `waku/ops/static/js/views.js`: mensajes genéricos por `episodes_source` (error, nota de Database, comentarios) sin romper Notion en Python | S1, S4, S5 | inline, verificación en navegador | pending |
| T3 | Pins Nim: `nim/tests/test_integrations.nim` (fila obsidian, opciones, env-example) + `nim/tests/test_dashboard.nim` (source obsidian intacto) en verde | S1, S4 | inline, `nimble test` | pending |
| T4 | Docs que el cambio vuelve falsos: comentarios en `views.js`/`integrations.nim`, `nim/README.md` si hace falta | S1, S4 | doc | pending |

## Log

- **L1** (usuario, verbatim): "he visto una cosa que no se como podemos corregir, tomé la decisión de usar obsidian en lugar de notion en el port en Nim, sin embargo, en el frontend solo aparece notion. ¿puedes ayudarme a resolver el conflicto?"
- **L2** (investigación): backend Nim ya usa Obsidian (`nim/src/obsidian.nim`, `episodeStoreFor` en `nim/src/app.nim`, `episodesFor`/`stateRows` en `nim/src/dashboard.nim` con `episodes_source` sqlite/obsidian, `notion` en error honesto). El conflicto está en `nim/src/integrations.nim:302` (sigue `key: "notion"`, opciones `sqlite, notion`) y en `waku/ops/static/js/views.js:103,623` (textos fijos de Notion). Python intacto por S2/S3.
- **L3** (decisión del usuario): opción "Frontend genérico + Obsidian en Nim".
- **L4** (base): árbol limpio en `abdb225` (`feat(nim): make mimalloc_nim a mandatory dependency`); `nim/config.nims`, `.codegraph/` y `.pi/` quedan sin commitear (config local y estado de herramientas).
