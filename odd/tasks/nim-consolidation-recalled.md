# Nim port — consolidación que no re-guarda lo que el turno leyó (#298)

Un turno que responde desde memoria leída re-extrae esos mismos hechos en la
consolidación y los guarda de nuevo (upstream: un "qué encontramos de los
competidores de Mem0?" guardó cinco copias). El port tiene el bug hoy:
`consolidateIfDue` no recibe `recalled` ni filtra `restates`.

## Specs

- **S1** (origen upstream, verbatim del docstring porteado):
  > A turn that answered from memory it read (a recall turn) passes that memory as `recalled`.

- **S2** (regla determinista, verbatim):
  > A proposed fact whose every name, number and date already appears in what the turn read is dropped (`restates`).

- **S3** (límite de la regla, verbatim):
  > Something new the user says has a name or a number the memory does not, so it is kept.

## Qué se portea (ground truth: `waku/memory/consolidation.py` en origin/main)

- `_words`: minúsculas; `"$10M,"` es `"10m"`, `"Mem0's"` es `"mem0"`, una
  fecha `2026-10-05` queda una sola palabra (nunca matchea un `2026` suelto);
  `\\n`/`\\u2019` escapados se leen como sus caracteres. Regex
  `[\w$'.,%-]+`, strip de `'.,-`, sin `$` inicial, sin sufijo `'s`.
- `restates(fact, recalled)`: el contenido aporta palabras con mayúscula o
  dígito ("nombres, números y fechas"); exige AL MENOS un número (`w[0]`
  dígito: `"10m"`, `"2023-12-27"`, no `"mem0"`); drop solo si TODAS están en
  `recalled`. Sin número nunca se dropea ("Sean decidió..." se queda, y
  RECALL_RULE le pide al summariser que no lo proponga).
- `RECALL_RULE` en el prompt cuando hay `recalled` (cap 6000 chars,
  `RECALL_PROMPT_CHARS`); el filtro corre sobre lo propuesto ANTES del resto.
- `recalled` del turno en el port: el texto que el gate encontró en ESTE
  turno (retenido en la sesión; el research salvado ya viaja por
  `reportBody`). Los outputs de las propias lecturas del modelo
  (`manage_memory` search) no se rastrean — non-goal documentado.

## Tasks

| # | Task | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `restates` + `_words` puros en `memory_live.nim` + pins espejando los casos Python (5 RESTATED dropean, NEW con 2026 se queda, sin número nunca, JSON escapado como texto, fecha una palabra) | S2, S3 | test-first, suite offline | `3f728e1` |
| T2 | Plomería `recalled`: la sesión retiene el texto del gate, `consolidateIfDue` lo recibe, suma `RECALL_RULE` (cap 6000) y filtra antes del resto; vacío = comportamiento actual | S1, S2 | test-first, pins | `c4f3514` |
| T3 | Docs que la unidad vuelve falsos (regla 9): comentarios del módulo + línea en `nim-port.md` | S1 | doc + pines | work unit |

## Non-goals

- Rastrear outputs de `manage_memory` del modelo como `recalled` (Python
  suma sus reads de Waku Memory; el port no rastrea tool outputs — feature
  aparte, se documenta).
- `slot_gate`/jev, `remember`/`mark_synced` (el port no los tiene; divergencia
  previa, no esta unidad).
- Re-embolsar o re-promptar el summariser más allá de la regla.

## Verificación

- `nimble test` verde, cero warnings, suites tocadas con `--forceBuild`.
- **T1**: los 5 RESTATED contra el cuerpo del REPORT dropean; NEW se queda;
  `{"subject":"X","content":"no numbers here"}` nunca dropea aunque nombre
  lo conocido; `"2026-10-05"` no matchea `"2026"` suelto; `\\n` y `'s`
  normalizan igual que Python.
- **T2**: turno recall (scripted propone RESTATED + recalled del gate) guarda
  0 facts y flipea las filas igual; hecho nuevo del usuario se guarda;
  recalled vacío = suite actual en verde sin cambios.
- **T3**: `rg -n "recalled" nim/src/memory_live.nim` documenta la fuente y el
  límite.

## Log

- **L1** (usuario, vía orden sugerido aceptado): consolidación primero.
- **L2** (investigación): el bug existe hoy en el port — `consolidateIfDue`
  no toma `recalled`; el gate encuentra pero su texto no se retiene
  (`session.nim:130` es local al respond). `reportBody` ya viaja por
  `reportCell`: el patrón a espejar para retener.
- **L3** (decisión de implementador): `recalled` = texto del gate de este
  turno. Sin tool-output tracking (non-goal). Sin `slot_gate` (divergencia
  previa). Los fixtures RESTATED/NEW/REPORT del eval Python son los pines.
- **L4** (cierre, T1-T2): suite completa **1313 OK, 0 FAILED** (+9 sobre
  obsidian: 6 de regla + 3 de plomería). T3 documenta la fuente y el límite
  en el módulo y el aterrizaje en `nim-port.md`.
