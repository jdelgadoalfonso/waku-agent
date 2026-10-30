# Nim-first — congelar Python y portar los guardarraíles a Nim

Cambio grande, autorizado. Congela la mitad Python (`waku/`), pone el port Nim
al frente de la documentación y del `Makefile`, y porta a Nim los guardarraíles
del repo que hoy son pytest. **Retirar `evals/deterministic/` no es parte de
esta feature**: el port es lo que lo habilita, y la decisión de retirarlo queda
para después. `hosted/` queda en Python, sin tocar.

**Estado:** T0, T1 y T2 landed en la rama `nim-first`. T3 en adelante pendiente.

## Estrategia de entrega

`nim-first` nace de `add-cline-provider`, que está 224 commits y 66.388 líneas
por delante de `origin/main` (sin contar lock files). Un PR de `nim-first` hacia
`main` arrastraría todo eso, así que la entrega de esta feature necesita una
decisión que no es mía: mergear `add-cline-provider` primero, o rebasar
`nim-first` sobre `main`. Los 6 commits de trabajo de esta sesión son revisables
por separado sin depender de esa decisión.

## Specs

- **S1 — Python congelado.** `waku/` no gana capacidad nueva ni evals de
  comportamiento nuevos; lo que ya hace, sigue haciéndolo. Cita del usuario:
  "vamos a dejar de mantener la parte de python".
- **S2 — Nim al frente.** El `README.md`, `AGENTS.md`, `docs/` y el `Makefile`
  presentan el binario Nim como la forma de usar Waku, y dicen explícitamente
  que `waku/` está congelado y por qué sigue en el árbol. Cita del usuario: "el
  proyecto se va a focalizar en la versión Nim".
- **S3 — Los guardarraíles se portan a Nim.** Cada pin que hoy corre en pytest
  sobre hechos del repo tiene un pin Nim equivalente, de modo que
  `evals/deterministic/` pueda retirarse después sin perder vigilancia. Cita de
  la opción elegida: "Congelar y portar los guardarraíles a Nim".
- **S4 — `hosted/` no se toca.** Sigue en Python, con su licencia y su test de
  frontera. Cita de la opción elegida: "Queda como está, en Python".
- **S5 — Sin pérdida de cobertura.** Un pin portado falla con el mismo hecho que
  el pin Python que reemplaza. No se afloja un tope, no se borra una regla, no
  se reemplaza un pin por una nota.

## Hallazgo que la especificación incorpora

El port Nim **ya lee archivos que viven dentro de `waku/`**, así que "borrar
Python" nunca iba a ser borrar:

| Lo que el port lee | Dónde | Cómo |
|---|---|---|
| El registry de proveedores | `waku/providers.toml` | `nim/tests/test_cli.nim:61` camina hasta él |
| Los assets del dashboard | `waku/ops/static` | `nim/src/dashboard.nim:414` los embebe (y `:81` lee `../waku.nimble`) |
| El número de versión | `nim/waku.nimble:10` | `nim/src/waku.nim` lo lee con `staticRead` |

`nim/tests/test_repo_gates.nim:405` afirma a propósito que el import a
`waku/ops/static` está **permitido**. Consecuencia: el guardarraíl del design
system no vigila código Python muerto, vigila assets que el binario Nim envía.
Mudar esos datos a un hogar neutral es trabajo propio, no consecuencia automática
del congelamiento.

## Inventario de guardarraíles (evidencia del port)

| # | Dónde | Qué afirma | ¿Importa `waku`? | ¿Muere si `waku/` se va? |
|---|---|---|---|---|
| 1 | `evals/deterministic/test_rulebook.py` (17 pines) | topes de AGENTS.md/README/status, links del rulebook, docs indexados, emojis, gotchas, playbook de `lab/`, licencia ELv2, una definición por nombre | no | no, pero 1h/1o quedan vacíos |
| 2 | `evals/deterministic/test_design_system.py` | tokens, primitivas, colores; los assets copiados coinciden con `SOURCE.md` | sí (`:91`) | **sí** |
| 3 | `evals/deterministic/test_version.py` | una sola versión, dinámica en pyproject | sí (`:17`) | **sí** |
| 4 | `evals/deterministic/test_hosted_boundary.py` | `waku→hosted` prohibido, `hosted→` sólo stdlib, sin `eval`/`exec`, wheel sin `hosted/` | no | no, pero sus pines de wheel mueren |
| 5 | `evals/deterministic/test_brand_mark.py` | las tres copias del mark comparten un `d` | no | **sí** (maestro en `waku/ops/static`) |
| 6 | `evals/deterministic/hosted/test_route_contract.py` | `policy.DECISIONS` == rutas fijadas del dashboard Python | indirecto | **sí** |
| 7 | `scripts/validate_skills.py` + `test_skill_triggers.py` | frontmatter, nombres únicos, largo, y que ninguna skill cargue en mensajes ajenos | sí (loader) | **sí** |
| 8 | `scripts/generate_env_example.py` | el bloque Connections de `.env.example` es idéntico al render del registry | sí (`:9`) | **sí** |

Ya portado en Nim por `nim/tests/test_repo_gates.nim` (fase 9b-1, aditivo): frontera
`nim/`↔`hosted/`, escaneo de `examples/`/`lab/`, una definición por nombre, sha256
de las copias de diseño, y la tabla de CI de AGENTS.md nombrando `nim.yml`.
`test_version.nim` tiene la versión, `test_embed.nim` el embed, `test_dashboard.nim`
la superficie de rutas.

Lo que **no** está cubierto hoy en Nim: el índice de `docs/`, la regla de emojis,
los links del rulebook, los topes de gotchas y status, el playbook de `lab/`, la
licencia ELv2, la validación de skills, la versión cruzando las dos mitades, y
`.env.example` contra el árbol (sólo hay un string dorado en `test_integrations.nim`).

## Tasks

Una por commit. `R` = route: `P` parent inline, `W` worker, `V` verify independiente.

| ID | Tarea | Spec | R |
|---|---|---|---|
| T0 | Sanear el árbol antes de ramificar: commitear el wiring de web search de `gather.nim` como su unidad; commitear aparte el rename de modelo de `providers.toml`; destrackear `nim/tests/factstore_fakes` (ELF de 85 KB, artefacto de build) y agregarlo a `.gitignore` | S1, S3 | P |
| T1 | Rama nueva desde `add-cline-provider` + este documento | — | P |
| T2 | Front door Nim-first: `README.md`, `AGENTS.md`, `docs/status.md`, `architecture.md`, `roadmap.md`, `getting-started.md`, `commands.md`, `tour.md`, `Makefile`. Declara `waku/` congelado y dice por qué sigue en el árbol | S1, S2 | W |
| T3 | Portar a Nim los pines del rulebook que faltan: índice de `docs/`, emojis, links del rulebook, topes de `gotchas`/`status`, playbook de `lab/`, ELv2 | S3, S5 | W |
| T4 | Datos compartidos: decidir y registrar el hogar neutral de `providers.toml`, `ops/static` y el registry que renderiza `.env.example`. Test-first sobre la ruta nueva | S1, S3 | W+V |
| T5 | Reapuntar el guardarraíl de diseño y brand mark al hogar de T4, y portarlo a Nim | S3, S5 | W |
| T6 | Portar validación de skills y trigger test (hoy importan el loader Python) | S3, S5 | W |
| T7 | Versión única entre las dos mitades: `nim/waku.nimble` vs `waku/__init__.py` vs pyproject. Definir "una versión" en un repo Nim-first | S3, S5 | W |
| T8 | `.env.example` contra el registry, en Nim (depende de T4) | S3, S5 | W |
| T2b | Los docs que T2 no tenía en su superficie y que todavía dicen `pip install` como la forma de usar Waku: `docs/integrations.md`, `docs/evals.md`, `CONTRIBUTING.md` y el material de `examples/` | S2, S5 | W |
| T9 | Docs que el cambio vuelve falsos (regla 9) + cierre: qué quedó verde, qué quedó pendiente | S2, S5 | P |

Commits landed (rama `nim-first`):

| Commit | Unidad |
|---|---|
| `7038126` | `docs(graph): propose a native plugin contract for graph nodes` — quedó en `add-cline-provider` |
| `43d031c` | `feat(nim): wire a real web search into gather` — el pendiente de la sesión anterior, en `add-cline-provider` |
| `8b6dd63` | `chore(providers): update the openrouter free model id` — en `add-cline-provider` |
| `a81c3d5` | `chore(nim): stop tracking the compiled factstore_fakes fixture` — en `add-cline-provider` |
| `8d9445c` | `docs(odd): add the nim-first feature document` — T1 |
| `6520c00` | `docs(nim): make the front door Nim-first` — T2 |

## Log

- **L1** (usuario, verbatim): "vamos a dejar de mantener la parte de python, el
  proyecto se va a focalizar en la versión Nim"
- **L2** (usuario, decisión de alcance, verbatim): "Congelar y portar los
  guardarraíles a Nim" — con su descripción: "Como el anterior, más portar a Nim
  los tests que vigilan el repo, para poder retirar pytest más tarde."
- **L3** (usuario, verbatim): "Queda como está, en Python" — sobre `hosted/`.
- **L4** (evidencia, inventario): `gentle-ai-explore` mapeó los 8 guardarraíles y
  los workflows. Seis mueren con `waku/`; dos sobreviven. `test_repo_gates.nim`
  ya cubre cinco invariantes. La tabla de arriba es su handoff.
- **L5** (evidencia, árbol): `waku/providers.toml` tiene un rename de modelo sin
  commitear (`nvidia/nemotron-3-super-120b-a12b:free` → `nvidia/nemotron-3.5-super-vl:free`).
  Es la prueba viva del acoplamiento: editar el registry significa editar `waku/`.
- **L6** (evidencia, árbol): `nim/tests/factstore_fakes` es un ELF de 85 KB
  trackeado en git (`0ed8998`). Cada rebuild ensucia el árbol.
- **L7** (decisión propia, por seguir de L1): el contrato de plugins de
  `docs/graph-plugins-design.md` queda Nim-only; la mitad Python no gana loader.
- **L8** (evidencia, T2 landed en `6520c00`): `test_rulebook.py` 17 passed antes y
  después, re-corrido por el parent de primera mano. El pin Nim que lee el archivo
  editado pasó: `[OK] the CI table names the nim gate` y `[OK] the gate the CI
  table names is a workflow in the tree`. `make -n` sigue resolviendo a `run`, o
  sea que el default goal no cambió. Topes: AGENTS.md 99/100, `status.md` 119/120,
  README 157/200.
- **L9** (corrección del brief): la especificación que le pasé al worker decía
  115 archivos en `evals/deterministic/`. El árbol tiene **166 trackeados**; el 115
  era el conteo de `.py` de primer nivel, que no ve `hosted/` ni el resto. El
  worker se negó a imprimir un número que no podía verificar y lo reportó en vez
  de repetirlo: correcto, y por eso el número no entró en ningún doc.
- **L10** (roja pre-existente, no nuestra): `nimble test` falla en
  `test_tls.nim(311)`, pin `[FAILED] why a finally that catches swallows the
  refusal in flight`. El pin fija una propiedad de las semánticas de excepción de
  Nim (`except` dentro de un `finally` que corre durante el desenrollado) y la
  excepción escapa sin ser atrapada. El compilador de esta máquina es Nim 2.4.0
  **compilado el 2026-10-30** desde `/usr/local/src/Nim`, distinto del que produjo
  el binario `nim/waku` de ayer, y ya había una roja de `test_tls` documentada
  para esta rama. Ni los docs ni `gather.nim` pueden afectar ese pin. Consecuencia
  registrada: **`nimble test` verde no es alcanzable en esta máquina hoy**.
- **L11** (evidencia acotada de T0, por L10): `test_graph.nim` → 27 `[OK]`, 0
  `[FAILED]`, exit 0. Es la suite que el wiring de web search sí afecta.
- **L12** (gotcha propio): `nimble test | tail -40` reporta el exit code de `tail`,
  así que un fallo se lee como éxito. Redirigir a un archivo y capturar `$?`
  aparte es la forma que sí conserva el veredicto.
- **L13** (gotcha de entorno): el toolchain Nim no está en el PATH; vive en
  `/usr/local/src/Nim/bin/` (`nim`, `nimble`, y además `nifler` y `atlas`, o sea
  que los prerequisitos de binny están en esta máquina). `nim --version` respondió
  al inicio de esta sesión y después el binario ya no estaba en la ruta: hay que
  exportar la ruta explícitamente en cada comando.
- **L14** (evidencia, árbol): `nim/tests/factstore_fakes` no coincidía con el
  patrón de `.gitignore` (`nim/tests/test_*`, `!nim/tests/*.nim`), por eso un ELF
  compilado quedó trackeado. Ya no está trackeado y el patrón está en `.gitignore`.
