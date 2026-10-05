# Nim port — backend de memoria semántica Zep (grafo temporal, REST a mano)

Segundo backend hosted detrás del contrato `FactStore`. El contrato, el
conformance suite y el fake compartido ya existen de mem0; esta unidad aporta
el cliente del grafo y su cableado.

## Specs

- **S1** (petición del usuario, verbatim):
  > ok, ahora podemos meterle mano a otro backend

- **S2** (autorización para desbloquear endpoints, verbatim):
  > si

- **S3** (autorización para implementar, verbatim):
  > si

## Qué necesita Zep (ground truth: SDK pineado `zep-cloud 3.29.0` en `/tmp/zep`)

- Base `https://api.getzep.com/api/v2`, header
  `Authorization: Api-Key <key>` (`core/client_wrapper.py:31`).
- Env: `WAKU_SEMANTIC_STORE=zep`, `ZEP_API_KEY` (requerida),
  `ZEP_USER_ID` (default `waku`, por `env_or`), `ZEP_MAX_WAIT_SECONDS`
  (default 120), poll cada 2s.
- Rutas verificadas en los `raw_client` generados por Fern:
  `POST graph` (add, body `data/type/user_id`),
  `GET graph/episodes/user/{user_id}?lastn=N`,
  `POST graph/search` (body `query/user_id/limit`),
  `POST graph/node/user/{user_id}` (body `limit`, NO es GET),
  `GET graph/node/{uuid}`, `DELETE graph/node/{uuid}`,
  `GET graph/edge/{uuid}`, `DELETE graph/edge/{uuid}`,
  `POST users` (body `user_id`).
- `add` = ingesta de grafo (`graph.add(data="{subject}: {content}"`,
  `type="text"`, `user_id)`), NO insert; bloquea con `_wait_processed(uuid)`.
- `settle` tiene el doble evento que mem0 no tenía: todos los episodios
  `processed` Y conteo de nodos quieto 3 veces seguidas
  (`graph.node.get_by_user_id(limit=200)`). Motivo: `processed` describe el
  episodio y los nodos derivados llegan después.
- `update` no edita: verifica `_exists(uuid)` (edge.get o node.get) y
  re-ingiere como `source="correction"`; Zep supersede por fechas de validez.
  Id desconocido → `false`.
- `delete` intenta nodo y edge (un uuid puede ser cualquiera); `true` si
  alguno funcionó.
- `_row`: texto de `fact`/`summary`/`name`, parte por `": "`, id de
  `uuid_`/`uuid`, `source: "zep"`.
- `search`: `graph.search(query, user_id, limit)` devuelve grupos `edges` +
  `nodes`.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `nim/src/zep.nim`: cliente REST a mano (add/search/nodos/episodios/edges/user + `settle` doble evento) sobre `newTlsHttpClient`, con seams de reloj y envío; adaptador `zepFactStore*`; fake loopback que pasa el conformance suite | S1, S2 | test-first, suite offline | `0dd96c8` |
| T2 | Cableado agente: `ZEP_USER_ID` en `Settings`, selector `zep` en `app.nim` (con fallback a sqlite sin key), `manageMemory` por el store | S1, S3 | test-first, pins | `c73fffe` |
| T3 | Cableado dashboard: store por request (`factsFor` exportado) como mem0, serialización de id opaco ya existente | S1, S3 | test-first, pins | `ac35312` |
| T4 | Docs que la unidad vuelve falsos (regla 9): `nim/README.md`, `odd/tasks/nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Los otros dos backends (supabase, langmem).
- Cualquier llamada real a `api.getzep.com` en un test (escribiría nodos de
  prueba en la cuenta real de alguien; gate opt-in como mem0).
- Persistencia o migraciones: zep no toca el schema de `state.db`.
- Cambiar FTS5, episodic, el ledger o cualquier prompt.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: loopback asserta método, ruta, headers y cuerpo de cada llamada;
  `settle` con reloj inyectado (episodios pending→done, nodos 0→N→quieto),
  timeout, store vacío → `true`; conformance suite contra el fake.
- **T2**: con `WAKU_SEMANTIC_STORE=zep` y key se arma remoto, sin key o con
  otro valor se cae a sqlite con aviso en stderr.
- **T3**: dashboard lee/escribe facts por el store cuando `zep` está elegido.
- **T4**: `rg -n "zep" nim/README.md` ya no lo lista como no portado sin matiz.

## Log

- **L1** (usuario, verbatim): "ok, ahora podemos meterle mano a otro backend"
- **L2** (usuario, verbatim): "vamos a continuar por donde lo dejamos ayer"
- **L3** (autorización, verbatim): "si" (descargar SDK y extraer endpoints)
- **L4** (autorización, verbatim): "si" (documento de feature e implementación)
- **L5** (investigación): SDK `zep-cloud==3.29.0` descargado a
  `/tmp/zep/zep_cloud-3.29.0-py3-none-any.whl`; literales extraídos de
  `graph/raw_client.py`, `graph/node/raw_client.py`,
  `graph/edge/raw_client.py`, `graph/episode/raw_client.py`,
  `user/raw_client.py`, `environment.py`, `core/client_wrapper.py`.
- **L6** (decisión de implementador): T1 es aditivo como mem0 T2; ningún cableado
  existente cambia hasta T2, que es la unidad invasiva y va sola. Dashboard en
  T3 aparte porque en mem0 juntarlo habría dejado una unidad sin verificar.
- **L7** (cierre, T1-T3): suite completa **1232 OK, 0 FAILED** (+20 sobre mem0:
  17 pins de `test_zep`, 2 de selector en `test_app`, 1 de `factsFor` en
  `test_dashboard`), cero warnings. T4 añade la sección "Facts can also live
  in a Zep graph" al README con env vars y las dos salvedades del producto
  (ingesta que reinterpreta el texto; doble evento de readiness). Nada tocó la
  red — el conformance contra el servicio real queda opt-in como en mem0 y en
  Python.
