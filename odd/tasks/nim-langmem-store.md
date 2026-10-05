# Nim port — backend semántico langmem (store local + PG, sin servicio)

Cuarto y último backend hosted detrás del contrato `FactStore`. El raro de la
serie: no es un servicio sino una librería sobre un store que el usuario pone —
en memoria (default, efímero) o en su Postgres. El contrato, el conformance y
los fakes ya existen; esta unidad aporta el store en proceso y su variante PG.

## Specs

- **S1** (petición del usuario, verbatim):
  > vvamos con langmem

- **S2** (decisión del usuario, verbatim — modo Postgres):
  > Ambos modos

## Qué necesita (ground truth: `waku/memory/semantic/langmem_store.py`)

- Sin cuenta ni API key propias; lo que factura son embeddings OpenAI
  (`OPENAI_API_KEY` requerida, `OPENAI_EMBED_MODEL` default
  `"openai:text-embedding-3-small"` con prefijo de proveedor — se parsea a
  `text-embedding-3-small`).
- Namespace fijo `("waku", "facts")` → prefijo con separador `\x1f`
  (unit separator), como el `ns_to_str` de referencia.
- Items: key `"fact-"` + 12 hex, value `{subject, content, source}`,
  `created_at`/`updated_at` ISO. `put` sobre key existente SOBRESCRIBE,
  preserva `created_at` y **re-embebe** (un vector viejo respondiendo lo viejo
  es la falla silenciosa que todo este archivo evita).
- Lo embebido es el JSON canónico del value (fields por defecto `["$"]` =
  value entero, no solo subject:content) con keys ordenadas.
- `search` embebe la query y ordena por coseno (score ∈ [-1,1], sin umbral);
  formato `"[subject] content"`, sin subject → solo contenido.
- `list` = scan con límite. DIVERGENCIA DOCUMENTADA: el upstream ordena por
  `(prefix,key)`; el contrato del port exige **newest first**, así que el port
  ordena por `created_at DESC` (ISO de ancho fijo = orden cronológico).
- `update`: `get` → `None` es `false`; si no, merge (subject vacío = se queda)
  + re-embed. `delete`: `get` primero, missing es `false`.
- `settle` inmediato en ambos modos: memoria es un dict, PG es escritura
  síncrona. Nada se infiere.
- Modo memoria: filas en el cliente (vive lo que vive el proceso del agente;
  el dashboard por-request lo ve vacío — paridad con el per-collect de
  Python, divulgado, no bug).
- Modo PG (`WAKU_LANGMEM_POSTGRES` no vacío): tabla `langmem_store`
  (`prefix,key` PK compuesta, `value` JSONB, `created_at/updated_at`, columna
  `embedding VECTOR(1536)` nullable + índice HNSW coseno — el default de la
  implementación de referencia `langgraph-store-postgres 0.1.0`). Upsert
  `ON CONFLICT (prefix,key)`. Conexiones por operación, como `pgvector.nim`.
- Nombres del selector: `langmem` (memoria) / `langmem-pg` (reportado; el
  valor que lo activa es `langmem` + `WAKU_LANGMEM_POSTGRES`).

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/langmem.nim`: store en proceso (put/get/delete/search/list por coseno) con seams de embedding; adaptador `langmemFactStore*`; conformance contra cliente en memoria con `fakeEmbed`; pins de prefijo `\x1f`, JSON embebido y re-embed en update | S1 | test-first, suite offline | `1ad69ac` |
| T2 | Variante PG: mismo contrato sobre `langmem_store` (upsert/scan/vector-search/delete por SQL a mano); pins de SQL; gate en vivo opt-in con keys propias `waku-test-` que se borran | S1, S2 | test-first, suite offline | `8c394ee` |
| T3 | Cableado: rama `langmem` en `app.nim` (`OPENAI_API_KEY` requerida; con `WAKU_LANGMEM_POSTGRES` → modo PG, sin key → sqlite con aviso) + pins de agente y página | S1, S2 | test-first, pins | `ed72b00` |
| T4 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md` (efimeridad EN GRANDE, modos, por qué el arena lo reporta ilegible), `sql/init_langmem.sql`, `odd/tasks/nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Python intacto: el pin `langgraph==1.2.12` no provee `langgraph.store`
  (ver L5) — arreglarlo es PR Python, no esta unidad.
- Interop byte a byte con DBs escritas por el `PostgresStore` histórico de
  langgraph: la tabla es la de la implementación de referencia actual
  (`langgraph_store` como default ajeno; la del port se llama `langmem_store`
  y lo dice). Si los pins de Python se arreglan y se quiere interop, el nombre
  es una constante.
- Embeddings locales o multi-proveedor: solo OpenAI, paridad con Python.
- Namespaces múltiples o filtros `$eq`/operadores: el contrato es un solo
  namespace sin filtros; no se porta lo que nadie llama.
- Migraciones automáticas: el schema lo corre el usuario; el port nunca hace
  CREATE/ALTER en base ajena (el gate en vivo asume la tabla creada).

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: prefijo `"waku\x1ffacts"`; cuerpo del embed = JSON con keys
  ordenadas; key con prefijo `fact-`; update re-embebe y preserva subject
  vacío; `get` missing → `false`; conformance de 4→5 backends en verde.
- **T2**: pins de SQL (tabla, `<=>`, `::vector`, `ON CONFLICT (prefix,key)`,
  escape de LIKE); id nunca interpolado; gate vivo skipea sin env.
- **T3**: `langmem` sin key → `sqlite`; con key → `langmem`; con DSN →
  `langmem-pg`; página sigue al selector.
- **T4**: README ya no lista langmem como no portado; init SQL con extensión
  + PK compuesta + HNSW.

## Log

- **L1** (usuario, verbatim): "vvamos con langmem"
- **L2** (decisión del usuario, modo PG): "Ambos modos"
- **L3** (pregunta previa a T1): modo PG — "Solo InMemory" vs "Ambos modos".
  Elegido ambos: el vector persistido ya vive en el backend `postgres`, pero
  el usuario pidió la variante langmem también.
- **L4** (investigación): `langgraph` 1.2.12 NO trae `langgraph.store`
  (tampoco 0.2.76, 0.6.11, 1.2.10 ni latest; `langgraph-store-memory` no existe
  en PyPI; `langgraph-store-core/postgres 0.1.0` son consumidores del mismo
  namespace ausente). Referencia de comportamiento usada en su lugar:
  `langgraph-store-core 0.1.0` (`KVStore`: prefijo `\x1f`, upsert con
  `created_at` preservado, `_vector_search` = coseno, `score` ∈ [-1,1]) y
  `langgraph-store-postgres 0.1.0` (tabla única + HNSW + `ON CONFLICT`).
- **L5** (hallazgo para Python, FUERA de alcance): con el lock actual,
  `LangMemFactStore._make_store()` levanta `ModuleNotFoundError` — ni el
  default ni el modo PG se pueden construir. El `lab/.../langmem_native.py`
  dice "verified live 1.2.10", pero ese wheel tampoco trae `store/`. Arreglo
  sugerido (no aplicado): issue Python — pineo o dependencia que provea
  `langgraph.store`.
- **L6** (decisión de implementador): cada backend del port es autocontenido
  (mem0/zep/pgvector duplican `bounded`/seams en vez de compartir) — langmem
  trae su propio REST de embeddings en vez de refactorizar `pgvector.nim`
  landed. Lo embebido es el JSON del value (fidelidad a fields `["$"]`), no
  el packing `subject: content` de los otros backends.
- **L7** (cierre, T1-T3): suite completa **1278 OK, 0 FAILED** (+27 sobre
  postgres: 15 pins de memoria + 9 del gemelo PG y gate en `test_langmem`,
  2 de selector en `test_app`, 1 de `factsFor` en `test_dashboard`), cero
  warnings. T4 añade la sección "Facts can live in LangMem" al README
  (efimeridad EN GRANDE, modos, arena ilegible) y `sql/init_langmem.sql`
  (extensión + PK compuesta + HNSW). Los gates en vivo skipean sin env.
