# browse_web fase A — fetch_url solo lectura

Feature: realizar el esqueleto `browse_web` como herramienta `fetch_url` de
solo lectura: GET sobre http/https, HTML→texto, topes y errores honestos,
detrás de `WAKU_EXPERIMENTAL`. Sin clics ni navegador (fase B, fuera de
este slice).

## Specs

S1: `fetch_url` solo hace GET sobre URLs `http://` y `https://`. Otro
esquema (`file://`, `ftp://`, sin esquema) se rehúsa con frase honesta,
sin intentar nada.
S2: El cuerpo se convierte a texto con el `stripTags` que ya usa
`search_web` y se trunca a 6000 caracteres con marcador de corte.
Tope de descarga 1 MB antes de convertir.
S3: Fallo de transporte → frase que lo dice; HTTP no-2xx → frase con el
status. Nunca una cadena vacía silenciosa ni una excepción al turno.
S4: El fetch viaja por el seam `SearchFetchFn` ya inyectado (GET con body
vacío); los tests repiten páginas grabadas, sin red.
S5: Registro solo con `settings.experimental`: `fetch_url` real sustituye
al stub `browse_web` en `plannedTools`; el stub desaparece de "Coming soon".

## Tasks

- T1: `fetchUrl` + `makeFetchTool` en `nim/src/search.nim` (S1-S4) — DONE: 4 tests GREEN en test_search
- T2: Registro en `registry.nim` tras la puerta experimental + quitar stub `browse_web` (S5) — DONE: pin en test_registry (`fetch_url` in, `browse_web` notin)
- T3: Roadmap `browse_web` a live (solo lectura) (S5) — DONE: roadmap + benchmarks

## Log

L1: User request verbatim: "vamos a empezar con el punto 1 (browse_web)"
L2: User plan verbatim: "ok, ahora le metería mano (hacer un plan de implementación de los TODOs que vimos en experimental)"
L3: Skill `new-tool`: un fichero por tool en `nim/src/`, `waku/` no se toca; fetch vive en `search.nim` junto a `search_web` (mismo seam, mismo `stripTags`).
