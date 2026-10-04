# Nim port — backend de memoria semántica mem0 (store remoto, REST a mano)

Primer backend-hosted detrás del contrato `FactStore`. Python tiene cinco
(`sqlite`, `supabase`, `mem0`, `zep`, `langmem`); el port tiene cero, así que
esta unidad construye el contrato y el primer implementación que no es local.

## Specs

- **S1** (petición del usuario, verbatim):
  > vamos a empezar por mem0

- **S2** (decisión del usuario, verbatim, `="estoy de acuerdo"` a las dos
  recomendaciones):
  > **REST a mano sobre `newTlsHttpClient`**, cero dependencias. Es lo que ya
  > hicimos con MCP, el WebSocket de Discord y el exporter OTLP: el paquete
  > sigue compilando e instalándose sin red. Un binding Nim de mem0 sería un
  > paquete que nadie mantiene y rompería `nimble test` offline.

- **S3** (decisión del usuario, verbatim, misma respuesta):
  > **Ensanchar `Fact.id` a `string`**, con las rutas sqlite parseando y mem0
  > pasando el string verbatim — el mismo criterio que el docstring: nunca
  > parsees el id de otro backend.

- **S4** (decisión del usuario, verbatim — contra qué versión de la API se
  escribe el cliente, contestada después de encontrar que la v3 eliminó
  `infer`):
  > **v3 en todo, como el SDK** — "add `POST /v3/memories/add/` async ->
  > event_id / search `POST /v3/memories/search/` {query, user_id} / all
  > `POST /v3/memories/` paginado / update `PUT /v1/memories/{id}/` / delete
  > `DELETE /v1/memories/{id}/`". Acepta que `infer:false` no existe, que
  > `add()` deja de garantizar que el fact quede guardado, y que "el
  > conformance suite puede no ser cumplible tal cual".

## Contrato a espejar (ground truth: `waku/memory/semantic/`)

`base.py` es un `Protocol`, no una clase base: en Nim se traduce a un record de
closures. Siete métodos, con quién los llama:

| Método | Quién | Regla que no se puede romper |
|---|---|---|
| `add(subject, content, source)` | el agente, cada turno | promete "guardá esto"; si el backend decide no guardarlo, `add` se vuelve no-op silencioso |
| `search(query, topK=4)` | el agente, cada turno | `[]` significa **"no|matcheó"**, nunca "no pude buscar". Formato `[subject] content` |
| `list(limit=200)` | dashboard | cada dict trae al menos `id`, `subject`, `content` |
| `search_with_ids(query, topK=8)` | correcciones | los ids que devuelve son los que `update`/`delete` aceptan |
| `update(id, content, subject=None)` | dashboard + `manage_memory` | `subject=None` deja el sujeto quieto; id desconocido → `false`, nunca excepción |
| `delete(id)` | dashboard + `manage_memory` | id desconocido → `false`, nunca excepción |
| `settle(timeout)` | quien lee lo que acaba de escribir | "true" debe significar *buscable*, no solo escrito |

Las tres reglas que el docstring de `base.py` vuelve explícitas porque ya
costaron un bug cada una: **nunca levantar ante un miss**; **los ids son
`int | str` y se devuelven verbatim** (sqlite cuenta, mem0 reparte UUIDs); y
**un guard alrededor de un método faltante convierte un bug ruidoso en una
mentira silenciosa** — el `hasattr(search_with_ids, else [])` hacía que el
agente dijera "no hay facts coincidentes" con los facts en la base.

## Qué necesita mem0 (contra la v3 que S4 elige)

- Servicio hosted `api.mem0.ai` con `MEM0_API_KEY` (header
  `Authorization: Token <key>`); `MEM0_USER_ID` con default `"waku"` y **valor
  vacío tratado como ausente** (`env_or`, no `getenv`: el form de Connections
  escribe los campos opcionales aunque los dejes en blanco, así que un
  `MEM0_USER_ID=''` debe caer al default y no dejar la memoria de la persona
  huérfana en un id generado).
- Las rutas, tal como las usa el SDK pineado (`mem0ai 2.2.0`):
  `POST /v3/memories/add/`, `POST /v3/memories/search/`, `POST /v3/memories/`
  (POST, no GET, y paginado con `page`/`page_size`), `PUT /v1/memories/{id}/`
  y `DELETE /v1/memories/{id}/`. Es la misma mezcla v3/v1 que hace el SDK: la
  v3 cubre add/search/get_all y la v1 sigue sirviendo update y delete.
- **`infer=False` ya no existe** (S4). La v3 es el *additive pipeline*:
  extracción con LLM en una llamada, sin UPDATE ni DELETE, y **asíncrona**.
  Consecuencia asumida: `add()` pasa a significar "encolado para extracción",
  no "guardado y buscable".
- Waku separa sujeto y contenido; mem0 guarda un blob. El ida y vuelta es
  `"subject: content"` con el sujeto en minúscula, y `_unpack` parte por
  `": "`.
- `settle()` **mejora** con la v3: `add` devuelve un `event_id` consultable en
  `GET /v1/event/{event_id}/`, así que "settled" se puede preguntar en vez de
  inferido. Es la primera señal de readiness real de esta integración, y
  reemplaza el conteo estabilizado del adaptador de Python (3 lecturas iguales
  cada 2s) porque ahí no había nada mejor. Con `event_id` pendiente se pollea
  hasta que el evento termina; sin evento pendiente —el caso del contestante
  de control del arena, que no siembra nada— `settle` responde `true` de
  inmediato.
- Tolerancia de forma: se acepta lista suelta o `{"results": [...]}` o
  `{"memories": [...]}`. Fijarse a una rompe el día que sube el SDK, y un
  benchmark que se rompe por un bump menor no sirve.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/factstore.nim`: el contrato como record de closures (`Fact`, `FactId` string, `FactStore`), el adaptador `sqliteFactStore*(db)` sobre los procs que ya existen, y la **suite de conformance** `nim/tests/test_factstore.nim` corriendo contra él. Aditivo: no cambia ninguna firma existente | S3 | test-first, suite offline | work unit |
| T2 | `nim/src/mem0.nim`: cliente REST a mano (add/search/get_all/update/delete + `settle` por estabilización) sobre `newTlsHttpClient`, con seams de reloj y de envío para testear sin red. Adaptador `mem0FactStore*` que pasa el conformance suite con un mem0 falso (loopback) | S2 | test-first, suite offline | work unit |
| T3 | Cableado: `semanticStore*` en `Settings` (`WAKU_SEMANTIC_STORE`, default `sqlite`) + `MEM0_USER_ID`, el selector junto a donde se arma el `Waku`, `manageMemory` y los call sites pasan a hablar con el `FactStore` en vez de con `db`, y el dashboard serializa el id como el string opaco que ya viaja | S1, S2 | test-first, pins de dashboard y CLI | work unit |
| T4 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md` (la lista de "what is not ported yet" y la de módulos), `odd/tasks/nim-port.md` (landing) | S1 | doc + pines | work unit |

## Non-goals

- Los otros tres backends (supabase, zep, langmem). Cada uno es una unidad; lo
  que sale de T1+T2 es que ya no falta el contrato.
- `episodic_store=notion`: es otro selector y otro store, y el selector de
  Python no lo mezcla con el semántico.
- Cualquier llamada real a `api.mem0.ai` en un test. El conformance suite de
  Python gatea mem0 detrás de `WAKU_TEST_MEM0=1` por una razón que aquí se
  repite: escribiría facts de test en la cuenta real de alguien. El port
  replica el gate y añade un fake loopback que sí corre siempre.
- Persistencia o migraciones: mem0 no toca el schema de `state.db`.
- Cambiar FTS5, episodic, el ledger o cualquier prompt.

## Verificación

- `nimble test` verde, cero warnings (gate del repo), con las suites tocadas
  compiladas con `--forceBuild`.
- **T1**: la conformance suite corre contra `sqliteFactStore` y pasa las 11
  verificaciones de `test_fact_store_conformance.py` (round-trip, miss sin
  excepción, ids que `update` acepta, update que cambia lo que `search`
  devuelve, delete, id desconocido → `false`, `list`, no-ASCII round-trip,
  `settle` que significa buscable, `settle` seguro en store vacío), más el
  test que se vigila a sí mismo: **todo método del contrato tiene que estar
  ejercitado en la suite**, o el contrato se ensancha en silencio.
- **T2**: el cliente se prueba contra un servidor loopback que asserte método,
  ruta, headers y cuerpo de cada llamada (incluido que `add` NO manda `infer`),
  y el `settle` con un reloj inyectado contra un evento que el fake reporta
  pendiente y luego terminado, más el caso de timeout, el de evento ya listo
  y el de excepción.
- **T3**: con `WAKU_SEMANTIC_STORE=mem0` el `Waku` arma el store remoto y con
  cualquier otro valor (o ninguno) el sqlite, byte-idéntico a hoy. El pin del
  id opaco: el dashboard lo manda como string y el tool lo devuelve verbatim.
- **T4**: `rg -n "supabase/mem0/zep" nim/README.md` ya no los lista como no
  portados sin matiz.

## Log

- **L1** (usuario, verbatim): "vamos a empezar por mem0"
- **L2** (decisión del usuario, `="estoy de acuerdo"`): REST a mano con cero
  dependencias (S2) y `Fact.id` ensanchado a `string` (S3). La razón de S3 es
  el docstring de `base.py`: los ids son `int | str` **a propósito** porque
  mem0 reparte UUIDs y la instrucción es no parsearlos.
- **L3** (investigación): el id de un fact viaja al frontend como **token
  opaco** — `memory.js:6` lo concatena en `"fact-"+id` y `memory.js:17` lo
  devuelve verbatim en el POST — así que ensancharlo a string no rompe nada
  del lado JS. El único cambio observable es `"id": "3"` en vez de `"id": 3`
  en el payload JSON.
- **L4** (investigación): el conformance suite de Python gatea cada backend
 hospedado detrás de un opt-in (`WAKU_TEST_MEM0=1`) porque escribir facts de
  test llena el workspace real de alguien con las preferencias de Priya. El
  port replica el gate y añade un fake loopback que corre siempre, que es lo
  que hace que el conformance suite sea una puerta real y no una opt-in.
- **L5** (decisión de implementador): T1 es **aditivo**. El record de closures
  vive al lado de los procs con `db` que ya existen, y el adaptador sqlite es
  una capa fina encima. Ninguna firma existente cambia hasta T3, que es la
  unidad invasiva y por eso va sola.
- **L6** (hallazgo que forzó la pregunta): el SDK pineado ya no habla v1. En
  `mem0ai 2.2.0`, `add` postea a `/v3/memories/add/`, `search` a
  `/v3/memories/search/` y `get_all` a `/v3/memories/` por POST; `update` y
  `delete` siguen en v1. Consecuencia que conviene mirar aparte: el adaptador
  de Python pasa `infer=False` a `client.add(...)`, pero si la v3 ya no honra
  ese flag, la garantía que su docstring promete ("`add` promete guardar
  esto") **no la está cumpliendo nadie aguas arriba**. No lo arregla esta
  unidad — es un hallazgo para Python — pero es la razón por la que S4 se
  tomó con los ojos abiertos y no por ser la última versión.
- **L7** (decisión de implementador, consecuencia de S4): con la v3, el
  conformance suite no puede prometer round-trip estricto contra mem0 real sin
  una salvedad. Contra el fake loopback sí (el fake cumple lo que la v3
  promete); contra el servicio de verdad el caso se gatea detrás de
  `WAKU_TEST_MEM0=1` y su aserción se centra en lo que la v3 sí garantiza:
  que `add` encoló un evento, que `settle` lo espera, y que `update`/`delete`
  sobre un id desconocido devuelven `false` en vez de excepción. El round-trip
  estricto queda como caso opt-in y documentado, no como una puerta que un
  servicio externo puede poner en rojo sin que nadie haya roto código.
