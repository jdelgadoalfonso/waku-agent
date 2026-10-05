# Nim port — backend episódico Obsidian (vault local, sin servicio)

Primer backend episódico no-sqlite del port, y el que ocupa el lugar que
Notion nunca tuvo aquí (el dashboard responde error honesto a `notion`, y así
sigue). Un vault son archivos: cero dependencia, cero red, cero secrets — la
opción estrictamente más local-first, y la memoria episódica se vuelve legible
y editable por la persona en su propio Obsidian.

## Specs

- **S1** (petición del usuario, verbatim):
  > en lugar de Notion, se podría usar obsidian?

- **S2** (decisión del usuario, verbatim — alcance):
  > Solo port Nim

- **S3** (decisión del usuario, verbatim — Notion/Python):
  > En python no lo vamos a implementar, solo en Nim y es para reemplazar a Notion

## Qué necesita (ground truth: `waku/memory/episodic/`)

- Contrato implícito hoy: `add(summary, happened_at)`, `recent(top_k)`,
  `search(query, top_k)`, `list(limit)`, `delete(id)`. En el port son procs
  sqlite directos sin abstracción (`memory.nim`) — esta unidad crea el
  contrato `EpisodeStore` como record de closures, igual que `FactStore`.
- `WAKU_EPISODIC_STORE`: `sqlite` (default) u `obsidian` (`WAKU_OBSIDIAN_VAULT`
  con la raíz del vault). `notion` sigue error honesto: es Python-only.
- Una nota por episodio en `<vault>/waku/episodes/` (carpeta propia, la raíz
  del vault no se toca): `YYYY-MM-DD-HHMMSS-<slug>.md`, frontmatter con
  `happened_at` + cuerpo con el resumen, id = ruta relativa. Archivo por
  episodio (no nota diaria): el update/delete por id lo exige — una sección
  dentro de una nota diaria no tiene id direccionable.
- Frontmatter tolerante: sin `happened_at` se usa mtime; sin frontmatter el
  cuerpo entero es el resumen. Una nota ajena nunca tumba un turno.
- `search` = scan por keywords `[a-zA-Z0-9]{2,}` con word-boundary, vacía →
  `recent` (paridad exacta con el scan de `NotionEpisodeStore`, no con FTS).
- `list` newest-`happened_at` first; el adaptador sqlite conserva su
  `ORDER BY id DESC` byte-idéntico (el contrato dice "newest first" y en la
  práctica inserción ≈ tiempo).
- `delete` resuelve dentro de la raíz (`absolutePath` + prefijo, como los
  SKILLs): fuera o inexistente → `false`. Un resumen `../../SOUL.md` no sale
  del vault — pin de seguridad dedicado (ítem 2, ver Riesgo en el cierre).
- Ids de episodio viajan como string opaco en el JSON (precedente: ids de
  fact en T3b de mem0); el JS los devuelve verbatim, así que no cambia.
- `views.js` ya lee `episodes_source`/`episodes_error`: el JSON los informa
  (`sqlite` u `obsidian`) en vez de estrenar UI.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/episodes.nim`: contrato `EpisodeStore` + adaptador sqlite sobre los procs que ya existen (aditivo, ninguna firma cambia) + suite de contrato `nim/tests/test_episodes.nim` | S1, S2 | test-first, suite offline | `d86d768` |
| T2 | `nim/src/obsidian.nim`: backend del vault (CRUD por archivos, frontmatter tolerante, scan con paridad Notion, traversal que no escapa) pasando la suite de contrato sobre dirs temporales | S1, S2, S3 | test-first, suite offline | `4ff9b3c` |
| T3 | Cableado: `episodicStore` + `obsidianVault` en `Settings`, `episodeStoreFor` en el selector, los 4 call sites (live search/add, admin, dashboard) por el store, ids a string en el JSON, `episodes_source` informado, error `notion` intacto | S1, S3 | test-first, pins | `df3f244` |
| T4 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md` (sección episódica), `odd/tasks/nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Python intacto (S2/S3): `notion_store.py` sigue como está.
- Migrar episodios sqlite existentes al vault al cambiar el selector: como en
  semántico, el switch lee el store nuevo. Se documenta, no se migra.
- Nota diaria, subcarpetas, Dataview, plugins o API REST de Obsidian, vaults
  remotos: archivo por episodio, plano, local.
- Cambiar FTS5, semántico o cualquier prompt.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: la suite de contrato corre contra el adaptador sqlite (round-trip,
  miss vacío sin excepción, ids que delete acepta, desconocido → `false`,
  `list`/`recent`, no-ASCII) + el test que se vigila (todo método ejercitado).
- **T2**: CRUD sobre vault temporal; `../../` en resumen/fecha/id no escapa
  (N casos); frontmatter ausente/roto no tumba; scan con paridad de keywords;
  suite de contrato en verde con 2 backends.
- **T3**: `obsidian` sin vault → `sqlite` con aviso; con vault → `obsidian`;
  `notion` → error honesto intacto; dashboard serializa ids string y sirve la
  página por el store; pines viejos de ids int actualizados con razón.
- **T4**: `rg -n "notion episodes are not supported" nim/src/dashboard.nim`
  sigue (notion), y el README documenta obsidian como el camino no-sqlite.

## Log

- **L1** (usuario, verbatim): "en lugar de Notion, se podría usar obsidian?"
- **L2** (decisión del usuario, alcance): "Solo port Nim"
- **L3** (decisión del usuario, Notion/Python): "En python no lo vamos a implementar, solo en Nim y es para reemplazar a Notion"
- **L4** (investigación): el port no tiene abstracción episódica — 4 call
  sites contra procs sqlite (`memory_live` search/add, `memory_admin`
  list/delete, dashboard stateRows + `memory_action`). `views.js:101,103` ya
  consume `episodes_source`/`episodes_error`: la UI no cambia.
- **L5** (decisión de implementador): archivo por episodio, no nota diaria —
  el CRUD por id exige notas direccionables. Sin migración al cambiar de
  selector (precedente semántico). El adaptador sqlite no reordena su SQL.
- **L6** (cierre, T1-T3): suite completa **1304 OK, 0 FAILED** (+26 sobre
  langmem: 10 de contrato en `test_episodes`, 12 del vault en
  `test_obsidian`, 3 de selector + 1 de página). T4 documenta el vault en el
  README y el aterrizaje en `nim-port.md`. `notion` sigue error honesto;
  Python intacto.
