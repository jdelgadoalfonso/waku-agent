# Nim port — backend semántico Postgres+pgvector (SQL directo, sin Supabase)

Tercer backend hosted detrás del contrato `FactStore`, y el primero que no es
un servicio sino una base de datos del usuario. El contrato, el conformance
suite y el patrón de fakes ya existen de mem0/zep; esta unidad aporta el
backend SQL y su cableado.

## Specs

- **S1** (petición del usuario, verbatim):
  > vamos con supabase, aunque yo lo ampliaría a cualquier base de datos postgres con la extensión pgvector

- **S2** (decisión del usuario, verbatim — alcance):
  > Solo el port Nim

- **S3** (decisión del usuario, verbatim — selector):
  > WAKU_SEMANTIC_STORE=postgres

## Qué necesita (ground truth: `waku/memory/semantic/supabase_store.py`)

- Postgres del usuario con extensión `vector` (cualquier distribución, no solo
  Supabase). Conexión por `DATABASE_URL` (conninfo libpq). Sin dependencia
  nueva: `db_connector/db_postgres` ya es dependencia del paquete.
- Embeddings por REST a mano contra OpenAI (`POST {base}/v1/embeddings`,
  `text-embedding-3-small`, 1536d): `OPENAI_API_KEY` (requerida),
  `OPENAI_EMBED_MODEL` (default `text-embedding-3-small`), `OPENAI_BASE_URL`
  opcional. Cada `add` y cada `search` pagan un embedding (red + costo +
  latencia): es el trade de este backend y va al README.
- Tabla `rag_chunks` (`sql/init_postgres.sql` slim: extensión + tabla +
  índices, SIN el RPC `match_chunks` y SIN las políticas RLS de Supabase, que
  usan `auth.jwt()` y no existen en un Postgres vainilla). El port emite el
  coseno directo: `ORDER BY embedding <=> $1::vector LIMIT $2`.
- Mapeo launch-rag: `source`=subject (minúscula), `text`=contenido,
  `chunk_id`=`"fact-"` + 12 hex. `list` reporta `source: ""` (la columna no
  distingue proveniencia) — honesto como en Python, no roto.
- Ids: se expone el `id BIGSERIAL` como string opaco; de vuelta, dígitos→`id`,
  lo demás→`chunk_id` (la misma `_column_for` de Python).
- `search_with_ids` en UN viaje (el SELECT ya trae `id`): mejora sobre los dos
  viajes de Python, documentada aquí y no como bug.
- `update` re-embebe (reescribir el texto sin el embedding deja el vector
  viejo respondiendo lo viejo); id desconocido → `false`.
- `settle` es `true` inmediato: el embedding se computa ANTES del INSERT, la
  fila es buscable al hacer commit. Nada se infiere.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/pgvector.nim`: backend SQL directo (upsert/búsqueda/list/get/update/delete) con seams de conexión y de embedding; fake en memoria con embeddings deterministas + coseno real que pasa el conformance suite; pins de SQL generado; gate en vivo opt-in | S1, S2, S3 | test-first, suite offline | `f378069` |
| T2 | Cableado: rama `postgres` en `app.nim` (`DATABASE_URL` + `OPENAI_API_KEY`, sin alguna → sqlite con aviso); `factsFor` ya es genérico + pin de página | S1, S3 | test-first, pins | `8024242` |
| T3 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md` (setup + costo por embedding), `sql/init_postgres.sql` slim, `odd/tasks/nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Python intacto (S2): `supabase_store.py` sigue con `supabase-py`.
- Embeddings locales o multi-proveedor: solo OpenAI, paridad con Python.
- Migraciones automáticas: el schema lo corre el usuario (init SQL), el port
  nunca hace CREATE/ALTER en la base de nadie.
- Postgres en los tests por defecto: sin extensión `vector` local, la suite es
  fake + pins; lo en vivo queda tras `WAKU_TEST_POSTGRES=1` + `DATABASE_URL` en
  tabla de test propia (`waku_test_chunks`, se crea y se dropea).
- Los otros backends (langmem) y Notion.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: pins de SQL (tabla, `<=>`, `::vector`, `ON CONFLICT (chunk_id)`,
  orden de params, prefijo `fact-`); fake pasa el conformance de 3→4 backends;
  sender que levanta → `[]`/`false`; update sin subject lee el subject;
  `settle` inmediato; live gate skipea sin env.
- **T2**: `postgres` sin alguna key → `sqlite` con aviso; con ambas → `postgres`;
  valor desconocido sigue a sqlite.
- **T3**: `rg -n "supabase" nim/README.md` ya no lo lista como no portado.

## Log

- **L1** (usuario, verbatim): "vamos con supabase, aunque yo lo ampliaría a cualquier base de datos postgres con la extensión pgvector"
- **L2** (decisión del usuario, alcance): "Solo el port Nim"
- **L3** (decisión del usuario, selector): "WAKU_SEMANTIC_STORE=postgres"
- **L4** (investigación): `db_connector/db_postgres` ya es dependencia (regla 3
  a salvo); hay `libpq` y binarios PG 18.6 pero SIN extensión `vector` → lo en
  vivo no corre aquí. `init_supabase.sql` trae RLS con `auth.jwt()` (paso 6):
  no corre en vainilla, de ahí el init slim. El RPC `match_chunks` es
  `ORDER BY embedding <=> $1 LIMIT $2`: el port lo emite directo y no necesita
  la función.
- **L5** (cierre, T1-T2): suite completa **1251 OK, 0 FAILED** (+19 sobre zep:
  16 pins de `test_pgvector`, 2 de selector en `test_app`, 1 de `factsFor` en
  `test_dashboard`), cero warnings. T3 añade la sección "Facts can live in
  your own Postgres" al README (setup, costo por embedding, provenance en
  blanco, `settle` inmediato) y `sql/init_postgres.sql` slim. El gate en vivo
  (`WAKU_TEST_POSTGRES=1` + `DATABASE_URL`) skipea sin env; con env usa filas
  propias `waku-test-` y las borra.
