# Nim-first — congelar Python y portar los guardarraíles a Nim

Cambio grande, autorizado. Congela la mitad Python (`waku/`), pone el port Nim
al frente de la documentación y del `Makefile`, y porta a Nim los guardarraíles
del repo que hoy son pytest. **Retirar `evals/deterministic/` no es parte de
esta feature**: el port es lo que lo habilita, y la decisión de retirarlo queda
para después. `hosted/` queda en Python, sin tocar.

**Estado al 2026-11-03 (reanudación).** En la rama `nim-first` están landed T0
(que vive en `add-cline-provider`), T1, T2, T2b y T3: 10 commits, 16 archivos,
1.203 líneas sobre su base. T3b y T6 siguen sin empezar, bloqueadas por cuota del
proveedor. **T4a, T4b, T4c-1 y T4c-2 están landed** (`f834ffd`, `f526360` y
`57c60fb` para el build del tenant que la mudanza rompió; T4c-1 en `b30f400`;
**T4c-2 en `1524a45`**), así que **T4 está cerrada**: las dos mitades leen
`data/integrations.toml`. **T5 está landed** en `de4348b` (registro en `L39`) y
**T8 en `91750b2`** (L41). **T7 está landed** en `ab67676` (L43): "una versión"
quiere decir un literal editable por mitad, sin exigir igualdad. Solo T9 queda
sin empezar. **T9 está landed** en `9486dff` (L45), así que la lista de tareas
está cerrada. Lo que queda abierto no son tareas de esta feature: las rojas
deterministas de `add-cline-provider`, la decisión sobre `test_tls`, la cuota que
frena T3b y T6, y la compuerta de review y entrega. **Los writers de esta
feature murieron seis veces con el proveedor
caído** (L19, L33, L34, L36, L39 y L43) y las últimas rebanadas las ejecutó el
padre inline sobre la salida parcial, verificada como evidencia.

El review nativo sigue rechazando el alcance por defecto
(`lens_context_budget_exceeded`), y el 2026-10-31 se estableció por qué el troceo
no lo arregla solo: la base que el controlador usa es `origin/main`, que sólo se
mueve publicando, y `main` está protegido. El usuario eligió **no publicar** y
abrir el review con un `baseRef` explícito en el punto de rama; el mismo día se
comprobó que **esa vía no reduce el alcance** (L26): el `assess` honra el `baseRef`
pero el `inspect` deriva la base del default del repo. La compuerta del review se
abre cuando `origin/main` se mueva, y eso pasa por el aterrizaje del port.

**Reanudar en este orden:** (1) las 7 rojas deterministas de `a81c3d5` (L23), que
son lo que impide aterrizar el port; (2) el aterrizaje del port (hoy: decisión del
usuario de no publicar), que es lo único que mueve `origin/main` y con él la base
del review; (3) **T4 cerrada con T4c-2 landed** (`1524a45`) y **T5 landed** (`de4348b`), que
reapuntó y portó los guardarraíles de diseño y brand mark —con la roja de los
logos por key que dejaba `test_static_assets` cerrada en el mismo commit—; sigue
T8, que porta a Nim el `--check` de `.env.example` (landed en `91750b2`);
(4) **T7 cerrada** (`ab67676`), con la regla por mitad decidida por el usuario y
registrada en L43;
(5) la decisión sobre la roja de `test_tls`; (6) T3b y T6 en cuanto vuelva la cuota
del proveedor de subagentes (L19, L33, L36); (7) la **verificación independiente de
T4c-1**, que sigue sin poder correr (L34): la de T4c-2 **sí corrió** y encontró una
regresión real (L37).

## Estrategia de entrega

`nim-first` nace de `add-cline-provider`, que está 224 commits y 66.388 líneas
por delante de `origin/main` (sin contar lock files). Un PR de `nim-first` hacia
`main` arrastraría todo eso, así que la entrega de esta feature necesita una
decisión que no es mía: mergear `add-cline-provider` primero, o rebasar
`nim-first` sobre `main`. Los commits de trabajo de esta sesión son revisables
por separado sin depender de esa decisión.

**El controlador de review ya se negó a revisar la rama entera, y eso deja de
ser una preferencia de estilo.** El 2026-10-30, `review.start` sobre el candidato
`sha256:329ea680…` (proyección `base-diff` del workspace, `committed-only`,
base-ref `4b69b321`, 250+ paths) falló en `preflight` con
`lens_context_budget_exceeded`: la evidencia completa del revisor excede el
presupuesto de contexto nativo. `mutation_performed: false` y
`mutation_outcome: not_started`, así que **no se creó autoridad** y no hay linaje
que abandonar ni reparar. La continuación que el propio controlador indica es
partir el cambio en una secuencia encadenada de commits más chicos, cada uno
bajo el presupuesto, y advierte que reintentar ese candidato exacto no puede
funcionar. O sea: el troceo no es higiene de revisión, es la única forma de que
el review nativo corra.

**Confirmado una segunda vez, y con la prueba de que el alcance no cambió.** El
mismo día, un commit de docs movió la generación de mutación y el controlador
ofreció un target nuevo (`sha256:d6eb097b…`) con un linaje nuevo
(`review-afedbde466bd45fe`). El `inspect` de ese target devuelve el **mismo
`paths_digest`** (`sha256:a71bdfb87…`) que el candidato rechazado: es el mismo
alcance, no uno más chico, y solo cambiaron `initial_review_tree` y
`current_candidate_tree`. Su `repair.counts.lineages` es 0, que corrobora que el
START fallido no creó autoridad. Por eso no se reintentó el START: la
continuación terminal de `lens_context_budget_exceeded` es reducir el alcance o
desactivar el switch, y reintentar un alcance sin reducir es exactamente el
reintento que el controlador dice que no puede funcionar. **Consecuencia
práctica: mientras la rama siga sin trocear, cada commit nuevo va a regenerar un
candidato que falla igual.** El troceo es la compuerta, no un paso posterior.

**`main` está protegido, así que "mergear la rama del port" no es una merge
local.** `docs/context/maintainers.md` lo fija: `git push origin main` lo rechaza
para todos (`enforce_admins` incluido) y un commit entra sólo por PR con
`gh pr merge --squash` y `skills-and-evals` en verde. Una merge local dejaría un
`main` que nunca se puede pushear y no movería la base del review, que es
`origin/main`.

Medido el 2026-10-31: `git ls-remote origin main` = `4b69b321`, y `origin/main`
**es ancestro** de `add-cline-provider` (0 commits por detrás, 222 por delante), o
sea que la rama ya fue rebasada sobre él y `main` local quedó 12 commits atrás. Un
merge local habría metido esos 12 commits de upstream dentro del aterrizaje del
port, sin ganar nada.

Y el preflight determinista sobre `a81c3d5` da **7 rojas** pre-existentes
(`test_pinned_models` ×5, `test_static_assets`, `test_turn_evals`; 3341 passed, 62
skipped, 2m05s), las mismas documentadas desde `c657414`: el check requerido está
rojo, así que el PR del port no podría mergear hasta arreglarlas. Decisión del
usuario el 2026-10-31: **no publicar por ahora**, y abrir el review con el
`baseRef` explícito.

**Frontera de rebanada.** El corte de esta entrega es el punto de rama `a81c3d5`:
todo lo anterior es el port (`add-cline-provider`, 222 commits y 67.403 líneas
autoradas sobre `origin/main`, lock files aparte) y todo lo posterior es esta
feature (16 archivos, 1.203 líneas). El port se aterriza como su propia entrega;
esta feature se revisa y se entrega aparte, encima.

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
de las copias de diseño, el brand mark (las tres copias dibujan una sola `d`, cada
variante declara su tinta y el README ofrece las dos) y el invariante "un logo por
key" sobre `data/integrations.toml`, y la tabla de CI de AGENTS.md nombrando
`nim.yml`.
`test_version.nim` tiene la versión, `test_embed.nim` el embed, `test_dashboard.nim`
la superficie de rutas.

Lo que **no** está cubierto hoy en Nim: el índice de `docs/`, la regla de emojis,
los links del rulebook, los topes de gotchas y status, el playbook de `lab/`, la
licencia ELv2, la validación de skills, y `.env.example` contra el árbol, cerrado
por T8. La versión cruzando las dos mitades la cerró T7, con la regla contraria a
la que se suponía: no se exige igualdad, se exige un literal por mitad.

## Tasks

Una por commit. `R` = route: `P` parent inline, `W` worker, `V` verify independiente.

| ID | Tarea | Spec | R |
|---|---|---|---|
| T0 | Sanear el árbol antes de ramificar: commitear el wiring de web search de `gather.nim` como su unidad; commitear aparte el rename de modelo de `providers.toml`; destrackear `nim/tests/factstore_fakes` (ELF de 85 KB, artefacto de build) y agregarlo a `.gitignore` | S1, S3 | P |
| T1 | Rama nueva desde `add-cline-provider` + este documento | — | P |
| T2 | Front door Nim-first: `README.md`, `AGENTS.md`, `docs/status.md`, `architecture.md`, `roadmap.md`, `getting-started.md`, `commands.md`, `tour.md`, `Makefile`. Declara `waku/` congelado y dice por qué sigue en el árbol | S1, S2 | W |
| T3 | Portar a Nim los pines estructurales del rulebook: índice de `docs/`, links del rulebook, topes de AGENTS/README/status, emojis, `CLAUDE.md` | S3, S5 | W |
| T3b | Segunda pasada de T3, que su handoff dejó fuera por ser un brief más angosto que esta fila: `gotchas` con fecha y tope, playbook de `lab/`, y el par ELv2 de `hosted/LICENSE` | S3, S5 | W |
| T4 | Datos compartidos mudados a un hogar neutral `data/`, en tres rebanadas: **T4a** el registry de proveedores (`providers.toml`), **T4b** los 64 archivos de `ops/static`, **T4c** los datos del registry que renderiza `.env.example` (hoy código Python) a un formato que ambas mitades lean. Test-first sobre la ruta nueva | S1, S3 | W+V |
| T5 | Reapuntar el guardarraíl de diseño y brand mark al hogar `data/static` de T4b, y portarlo a Nim | S3, S5 | W |
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
| `f834ffd` | `refactor(providers): give the provider registry a home outside the frozen package` — T4a |
| `f526360` | `refactor(static): give the dashboard assets a home outside the frozen package` — T4b |
| `57c60fb` | `fix(hosted): admit data/ in the tenant build context` — consecuencia de T4a y T4b |
| `b30f400` | `refactor(integrations): move the connection registry to data/integrations.toml` — T4c-1 |
| `1524a45` | `refactor(integrations): read the Nim connection registry from data/integrations.toml` — T4c-2 |
| `de4348b` | `test(guards): port the brand mark and the logo invariant to Nim` — T5 |
| `91750b2` | `test(guardrails): pin .env.example against the registry in Nim` — T8 |
| `ab67676` | `test(guardrails): pin one version literal per half instead of one number` — T7 |
| `af32852` | `docs(odd): record the fifth declined branch candidate after T7` — intento de compuerta |
| `9486dff` | `docs(nim-first): retarget the prose the port made false` — T9 |

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
- **L15** (evidencia, T3): nueva suite `nim/tests/test_repo_docs.nim` con 14 pines
  que portan el índice de `docs/`, la resolución de links del rulebook set, los
  topes de AGENTS.md/README/status y el sello de fecha, los emojis, y `CLAUDE.md`
  == `@AGENTS.md`. El descubrimiento por `waku.nimble:47-57` quedó **verificado**,
  no asumido: el suite se compiló y corrió dentro de un `nimble test`. Dos
  semánticas no salen gratis en Nim y el worker las reprodujo en vez de
  aproximarlas: el conteo de líneas de Python, porque `splitLines` de Nim agrega
  un elemento vacío final para `"a\n"` y eso habría corrido **todos** los topes
  en uno; y el conjunto de caracteres emoji, leído del propio regex de Python.
  Cada pin trae su sonda de violación: 5 `[FAILED]` con entradas deliberadamente
  rotas y 14 `[OK]` contra el árbol real.
- **L16** (conflicto entre suites, resuelto): el `RULEBOOK` de Python nombra
  `examples/README.md` y `lab/README.md` como literales, y el ban de
  `nim/tests/test_repo_gates.nim:363-372` prohíbe a todo módulo de `nim/`
  nombrar esos árboles. El worker **se detuvo** en vez de elegir, y ofreció tres
  salidas. Se resolvió con la opción A, que es la forma que Python ya usa en
  `test_rulebook.py:148-156`: exceptuar solo los **literales** de ese archivo del
  escaneo de literales, dejándole el escaneo de imports completo (los dos tests
  son separados, cada uno con su `isThisSuite`). Justificación: un guardarraíl
  que **lee** un README para chequear un invariante no depende de las lecciones,
  mientras que un `import lab` ahí sería igual de incorrecto que en cualquier
  lado. Se rechazó explícitamente la alternativa de armar las rutas con
  fragmentos para esquivar el escáner: evadir un guardarraíl no es exceptuarlo.
  La evidencia exigida es que la excepción sea **angosta**: un literal en otro
  módulo sigue fallando, y un import de un árbol denegado desde el suite nuevo
  sigue fallando.
- **L17** (nota de honestidad del worker): en su corrida de `nimble test` el loop
  se detuvo en `test_repo_gates.nim`, así que `test_tls.nim` **nunca corrió** en
  esa corrida y se negó a reclamar la roja de TLS a partir de ella. La evidencia
  de L10 se mantiene desde la corrida del job-2, donde sí corrió y sí falló.
- **L18** (T3 landed en `ba92282`): 14 pines, 617 líneas, cada uno con su sonda de
  violación. Verificado por el parent de primera mano: las dos suites en 14 `[OK]`
  / 0 `[FAILED]` / exit 0, superficie exacta, sin archivos de sonda sobrantes. La
  excepción angosta se probó en tres direcciones: un literal en otro módulo sigue
  fallando (disparan los dos pines), un import de un árbol denegado sigue
  fallando, y `test_repo_docs.nim` conserva cobertura de imports completa porque
  el único skip del pin de imports es `isThisSuite`, que es falso para él.
- **L19** (interrupción externa, sin daño): T3b y T6 murieron con `assistant
  reported an error (quota)`: el proveedor de subagentes está agotado. Verificado
  que **no dejaron daño**: `git status --porcelain -uall` vacío tras el fallo de
  T3b, y la suite commiteada sigue en 14 `[OK]` / 0 `[FAILED]` / exit 0. Las dos
  unidades quedan sin relanzar: un recurso externo agotado no se reintenta solo,
  y cambiar de agente para esquivar el límite sería un rodeo, no una solución.
  Ambas siguen pendientes y sin empezar.
- **L20** (usuario, decisión, verbatim de la opción elegida): "Mergear
  add-cline-provider a main primero" — cómo abrir paso al review nativo y a la
  entrega de la rama.
- **L21** (hallazgo, el mismo día, y que corrige la premisa de L20): `main` está
  protegido (`docs/context/maintainers.md`), así que la única forma de aterrizar
  es push + PR + squash con `skills-and-evals` verde; una merge local no se puede
  pushear y no mueve la base del review. Además `origin/main` (`4b69b321`) **es
  ancestro** de `add-cline-provider` (0/222): la rama ya fue rebasada sobre él y
  `main` local quedó 12 commits atrás, así que un merge local sólo habría metido
  esos 12 commits de upstream dentro del aterrizaje.
- **L22** (usuario, decisión, verbatim de la opción elegida, tomada con L21 ya
  sobre la mesa): "No publicar: review con baseRef en a81c3d5" — el review se abre
  con `baseRef` explícito en el punto de rama y la entrega queda sin publicar.
- **L23** (evidencia, preflight del 2026-10-31): `pytest evals/deterministic -q`
  sobre `a81c3d5` → **7 failed, 3341 passed, 62 skipped** en 2m05s. Las rojas son
  `test_pinned_models.py` ×5, `test_static_assets.py` y `test_turn_evals.py`, las
  mismas documentadas desde `c657414`: pre-existentes, no causadas por esta rama.
  Consecuencia: el check requerido `skills-and-evals` está rojo y la rama del port
  no puede aterrizar hasta arreglarlas. Es un pendiente nuevo: no estaba en la
  lista de tasks.
- **L24** (usuario, decisión de alcance, verbatim de la opción elegida): "Todos
  los datos a un hogar neutral (data/)" — T4 pasa a mudar el registry de
  proveedores, los 64 archivos de `ops/static` y los datos del registry de
  integraciones, no sólo a declarar las rutas donde están. Tres rebanadas: T4a
  `providers.toml`, T4b `ops/static`, T4c el registry de integraciones a datos que
  ambas mitades lean, que es lo que vuelve real el pin de T8. Alcance descartado y
  por qué: mover 796K de assets mientras la mitad que los lee (`waku/`) se queda
  en el árbol igual no se paga con declarar las rutas, pero por eso mismo T4b es
  la rebanada de mayor radio y va con verificación independiente.
- **L25** (decisión propia, por seguir de L24 y para resolver la tensión con S4):
  mover `ops/static` vuelve falso el puntero de
  `hosted/gateway/static/design/SOURCE.md` y deja apuntando al maestro al
  drift-check `evals/deterministic/hosted/test_login_page.py:71`. S4 congela el
  **lenguaje y el comportamiento** de `hosted/`, no su documentación ni las
  pruebas que vigilan su frontera: la regla 9 de AGENTS.md ("arregla el doc que
  tu cambio vuelve falso") manda sobre el puntero. Las copias byte a byte de
  `hosted/` no se mueven ni se editan; sólo se reapunta el maestro que nombran.
- **L26** (evidencia, 2026-10-31: la ruta de L22 no es implementable como se
  describió). El `assess` con `baseRef=a81c3d5…` **sí** honró la base: devolvió
  `changedPaths: 16`, `changedLines: 1465`, `nativeRisk: medium`,
  `reviewDue: false`, `reviewDueReason: "under_budget"`. El `inspect` **no**: su
  `next_transition` ofrece `review.start` con `--base-ref=4b69b321` (origin/main),
  250+ paths y `paths_digest: sha256:a71bdfb87…`, el mismo digest del candidato ya
  rechazado. O sea que el `inspect` proyecta contra el default del repo y el
  alcance no se reduce por pedirlo. Intentar el `START` con un `baseRef` explícito
  en el input (que la propia fachada documenta) no fue posible desde acá: el
  argumento `input` no sobrevivió a las llamadas directas —el controlador respondió
  `start requires input` y, con un fragmento, `START input must be a JSON string`—
  y `gentle_review` rechaza ejecutarse desde `codemode` ("runs only as a direct
  tool call"). **No se creó autoridad en ningún intento**: el propio controlador
  dijo "No lineage was created; do not call STATUS or ADVANCE for this attempted
  lineage", y `repair.counts.lineages` sigue en 0 con
  `mutation_performed: false`. Consecuencia registrada: la compuerta no se abre por
  `baseRef`; se abre cuando `origin/main` se mueva, o sea cuando el port aterrice, y
  para eso hacen falta las 7 rojas de L23.
- **L27** (decisión propia, diseño de T4a, 2026-10-31): mudar el registry a `data/`
  **no es un `git mv`**. El wheel es `packages = ["waku"]` con un `force-include`,
  así que `waku/providers.toml` viaja dentro del paquete publicado: sacarlo de
  `waku/` sin más dejaría a `pip install waku-agent` sin registry, y
  `license-files` nombra `waku/ops/static/fonts/OFL-*.txt`, que es el mismo problema
  esperando a T4b. El repo ya tenía este problema resuelto y su precedente manda:
  `skills/` vive en la raíz, se copia al wheel con `force-include`
  (`"skills" = "waku/skills"`) y `waku.memory.bundled_skill_dirs()` "looks in both
  places and explains why"; `evals/deterministic/test_packaging.py` fija las dos
  mitades, el build config y el lookup. T4a replica ese patrón exacto: master en
  `data/providers.toml`, `force-include` de `data/providers.toml` a
  `waku/providers.toml`, un `registry_path()` en `waku/loop/models.py` que mira las
  dos formas (checkout `parents[2]`, instalado `parents[1]`), el mismo par de pines
  nuevos en `test_packaging.py`, y en Nim `findProvidersToml`
  (`nim/src/waku.nim:124-129`) pasa de los candidatos `waku/providers.toml` a
  `data/providers.toml` sin dejar candidatos muertos.
- **L28** (evidencia, T4a landed en `f834ffd`, 2026-10-31): 26 archivos,
  +101/−46, con el move contado aparte. Test-first de verdad: los dos pines
  nuevos de `evals/deterministic/test_packaging.py` se agregaron ANTES del
  movimiento y se observaron rojos (`2 failed, 8 deselected`, con
  `assert None == 'waku/providers.toml'` y `AttributeError: module
  'waku.loop.models' has no attribute 'registry_path'`), y verdes después
  (`2 passed`). Differential de la suite completa: **7 failed, 3343 passed, 62
  skipped** contra el baseline de 3341 passed: las mismas 7 rojas de L23, y +2 que
  son los pines nuevos. Nim: `test_dashboard` 136 OK / 0 FAILED — venía de 135/1
  por el **quinto lector**, `nim/tests/test_dashboard.nim:302-303`, que arma la
  ruta por segmentos (`"waku" / "providers.toml"`) y por eso el grep del literal
  no lo veía —, más `test_repo_gates` 14, `test_repo_docs` 14, `test_cli` 28,
  `test_providers` 8 y `test_pricing` 16, todas exit 0.
  Verificación independiente (`gentle-ai-verify`): **accept-with-notes**. Construyó
  el wheel offline con hatchling y encontró `waku/providers.toml` adentro con el
  mismo sha256 (`2db31c5e…63e6`); el sdist también, y un wheel construido desde el
  sdist desempacado también, o sea que la instalación desde fuente también sirve.
  Las dos formas del lookup resuelven por separado en un directorio aislado, y sin
  ninguna de las dos el import tira `FileNotFoundError` en vez de un registry vacío
  en silencio. Revirtiendo cada mitad del arreglo, su pin falla.
  Notas aceptadas y **no** arregladas en esta unidad: el error de "no hay registry"
  nombra el candidato instalado cuando estás en un checkout (ruidoso, pero apunta
  al archivo equivocado); el pin del lookup es un pin sobre el texto fuente, así
  que una reescritura correcta lo rompe (es la misma forma que el pin de `skills/`);
  y nada copia el registry al lado de un binario instalado con nimble
  (pre-existente).
- **L29** (interrupción externa, 2026-10-31): el worker de T4b murió con
  `assistant reported an error (unavailable)` — indisponibilidad del proveedor de
  subagentes, no cuota, y no se reintenta ni se cambia de agente para esquivarlo
  (misma regla que L19). Dejó exactamente un archivo tocado: los dos pines
  test-first en `evals/deterministic/test_packaging.py` (+26 líneas, el paso 1 del
  brief) y **ningún** movimiento: `data/` seguía con solo `providers.toml` y
  `waku/ops/static` intacto con sus 64 archivos. Como el árbol había quedado en un
  rojo a medias, se restauró ese único archivo a `487a4a1` y el árbol volvió a
  estar limpio. **T4b no empezó.** Su diseño es el de L27 aplicado a un directorio,
  más `license-files` (`waku/ops/static/fonts/OFL-*.txt`) y el puntero de `hosted/`
  según L25. Baseline que hay que preservar y que ya se capturó:
  `test_static_assets.py::test_connection_card_logos_are_local_and_complete` ya está
  rojo en HEAD por un logo de MÁS en disco — `Extra items in the left set:
  'obsidian.svg'`, no un faltante — y tras el movimiento tiene que fallar con ese
  mismo texto, o no se puede distinguir la mudanza de ese rojo pre-existente.
- **L30** (evidencia, T4b landed en `f526360`, 2026-10-31): 117 archivos,
  +197/−108, con los 64 assets mudados en R100 y sha256 iguales archivo por
  archivo. Pines test-first rojos antes y verdes después. Differential de la suite:
  **7 failed, 3347 passed, 62 skipped**, y el verificador comparó las dos secciones
  FAILURES normalizando rutas temporales y direcciones de objetos: diff vacío, o
  sea las mismas 7 rojas **por nombre y por texto**. Ese detalle importa acá porque
  `test_static_assets` está rojo dentro del árbol que se movió: se repuntó solo su
  constante de ruta y sigue fallando con las mismas cuatro líneas (`Extra items in
  the left set: 'obsidian.svg'`). Nim: `test_dashboard` 137 (con el pin nuevo de la
  profundidad del walk), `test_repo_gates` 14, `test_repo_docs` 14, `test_embed` 11,
  `test_cli` 28, `test_blackbox` 15, todas exit 0.
  Verificación independiente: **accept-with-notes**. Construyó el wheel, el sdist y
  un wheel desde el sdist desempacado: 64/64 assets byte-idénticos en los tres, las
  fuentes y los tres textos OFL adentro, y `license-files` resolviendo en
  `dist-info/licenses/`. Las dos formas del lookup resuelven por separado, y las
  copias byte a byte de `hosted/` quedaron intactas (solo cambió su `SOURCE.md`).
  El quinto lector acá no fue uno sino **quince** (los 14 archivos de eval que
  aparecen abajo más `nim/README.md`): la lista de superficies salió de los literales
  y no ve los caminos armados por segmentos, así que el worker se detuvo ANTES de
  mover y preguntó, en vez de dejar 66 `FileNotFoundError` y 2 errores de
  colección. Se autorizó la extensión, y los dos lectores que anclan en `__file__`
  pasaron a llamar a `static_dir()` en vez de inventar una segunda ruta.
  Notas aceptadas: `static_dir()` no levanta cuando no existe ninguna de las dos
  formas y el fallo aparece en la primera lectura, igual que `registry_path()` (no
  es regresión, es lo que ya hacía); el pin del lookup es un pin sobre el texto
  fuente; y la sonda que `test_repo_gates.nim` perdió se descartó con su
  justificación escrita en el propio test, en vez de reapuntarla a `data/static`,
  que es un directorio de assets y no un módulo importable.
- **L31** (hallazgo y decisión, `57c60fb`, 2026-10-31): la mudanza **rompió el build
  de la imagen del tenant** y la suite determinista quedó verde igual.
  `pyproject.toml` force-includea tres caminos de `data/` y la allowlist del
  contexto de esa imagen admitía `waku/` y `skills/` pero no `data/`, así que el
  build fallaba con `Forced include not found: …/data/providers.toml` — lo introdujo
  T4a y T4b le sumó la mitad idéntica. Nadie lo veía porque
  `evals/deterministic/hosted/test_image_context.py` fijaba la allowlist de ayer en
  vez de lo que el build necesita.
  Decisión de alcance: **se toca `hosted/`** para arreglar un build que este cambio
  rompió, con la lectura de S4 que ya fijó L25: `hosted/` no se porta a Nim y sus
  copias byte a byte no se mueven, pero un build roto por nuestra mudanza se
  arregla. El arreglo admitió `data/` en el contexto y sobre todo **cambió el pin
  de lista por el pin del invariante**: deriva los `force-include` de
  `pyproject.toml`, descubre por sí mismo qué Dockerfiles construyen el proyecto
  (el de servicios tiene prohibido admitir `waku/`, esa es la frontera de licencia)
  y construye el wheel en un contexto armado solo con las admisiones, offline y en
  cada PR. `LICENSE-BRAND` también nombraba la ruta vieja (regla 9) y quedó
  corregido.
  No verificado: `evals/hosted_docker/test_image.py` es el guard fuerte y necesita
  daemon de Docker, que esta máquina no tiene.
- **L32** (evidencia y diseño de T4c, 2026-10-31): el mapa del registry en las dos
  mitades (`gentle-ai-explore`) cambia el diseño. Los datos de Python son
  `INTEGRATIONS` (`waku/integrations.py:158-286`), una tupla de **16** instancias de
  dataclass con campos que son **código**: `enabled`, `probe` y `normalize` son
  closures. El port Nim tiene **su propia copia** (`nim/src/integrations.nim:200-363`,
  **14** filas) con sus closures (`keyEnabled`, `storeEnabled`, `darwinEnabled`,
  `positiveInt`), y **las dos listas no coinciden**: Python tiene `notion`, `treg` y
  `typesafe`; Nim tiene `obsidian` donde Python tiene `notion`. **No hay ningún pin
  que afirme que las dos mitades coincidan**: el único puente es un string dorado
  copiado a mano en `nim/tests/test_integrations.nim:249-383`. Y hay una tercera
  copia de los grupos: `data/static/js/views.js:281`
  `const CONNECTION_GROUPS = [...]`, fijada como string por
  `test_static_assets.py:53`. El render de `.env.example` sale solo de Python
  (`scripts/generate_env_example.py:9`) y CI lo compara con `--check`
  (`.github/workflows/validate-skills.yml:59`).
  Diseño que se sigue, por seguir de L27: (a) `data/integrations.toml` lleva **solo
  la parte declarativa**; `enabled`, `probe` y `normalize` se quedan en código,
  indexados por `key`, y una fila sin su entrada de comportamiento falla ruidosamente
  en vez de quedar inerte; (b) el archivo lleva la **unión** de las filas de las dos
  mitades con un marcador explícito de qué mitad la registra, para que la divergencia
  `notion`/`obsidian` deje de ser silenciosa **sin cambiar el comportamiento de
  ninguna**: converger es una decisión de capacidad, no de T4c, y S1 la prohíbe para
  la mitad Python; (c) las dos mitades lo leen con un lookup de dos formas (checkout
  vs instalado) y el wheel lo vuelve a empaquetar, igual que el registry de
  proveedores y los assets; (d) T4c se entrega en **dos commits**, Python sobre el
  archivo primero y Nim sobre el archivo más el pin de acuerdo después, y el pin de
  `.env.example` en Nim queda para T8. El oráculo de la mudanza no es un fixture
  nuevo: es el guard que el repo ya tiene, `python scripts/generate_env_example.py
  --check`, que compara el render completo contra el `.env.example` versionado, más
  los evals existentes (`test_integrations.py`, `test_gmail.py` fija `gmail` justo
  detrás de `google_calendar`, `test_static_assets.py` deriva un logo por key) y el
  dorado de Nim. Se corren antes y después.
- **L33** (interrupción externa y cierre de sesión, 2026-10-31): el worker de T4c-1
  murió con `assistant reported an error (quota)` — el proveedor de subagentes está
  agotado otra vez, como en L19 — **sin escribir un byte**: `git status --porcelain
  -uall` vacío, `data/integrations.toml` inexistente y `pyproject.toml` intacto. No se
  reintenta ni se cambia de agente para esquivarlo. Antes de delegar quedó capturado
  de primera mano el baseline del oráculo de la mudanza: `python
  scripts/generate_env_example.py --check` → **exit 0 sin diff**, y el differential de
  la suite sigue en **7 failed, 3347 passed, 62 skipped** (L23 + L30). El brief
  completo de T4c-1 quedó en la sesión del 2026-10-31 y su diseño en L32: alcanza con
  releerlos para relanzar. Estado al cerrar: T0-T3, T4a y T4b landed y verificados,
  más `57c60fb` (el build del tenant); árbol limpio en `0850cae`.
- **L34** (interrupción externa ×2 y ejecución inline, 2026-11-01): el writer de
  T4c-1 volvió a morir con `assistant reported an error (quota)` —el proveedor de
  subagentes sigue agotado, como en L19 y L33— **sin escribir un byte**: `git status
  --porcelain -uall` vacío antes y después. No se reintenta y no se cambia de agente
  para esquivarlo. Decisión: el padre ejecuta la rebanada **inline**, con test-first y
  el differential como prueba. El guard de delegación de writers sí se cumplió (el
  brief llevaba `Spec: odd/tasks/nim-first.md, T4` y las superficies editables
  canónicas), así que lo que falló fue capacidad, no el brief.
  Consecuencia honesta: la ruta **V de T4 no puede correr**, porque el mismo
  proveedor alimenta a `gentle-ai-verify`. Queda registrada como prueba faltante, no
  simulada, y es la única razón por la que T4c-1 no está verificado como T4a y T4b.
- **L35** (evidencia y decisiones de T4c-1, 2026-11-01, `b30f400`): `data/
  integrations.toml`, 432 líneas y 17 filas, **generado** desde el registry vivo por
  un emisor one-shot en un scratch (`mktemp -d`, descartado al terminar) y no
  transcrito a mano: 13 filas compartidas, `notion`/`treg`/`typesafe` solo Python,
  `obsidian` solo Nim (transcrita desde `nim/src/integrations.nim:200-215`).
  Decisión que el diseño (L32) no fijaba y hubo que resolver antes de escribir: el
  **orden**. Se comprobó primero que las listas de keys de las dos mitades son la
  misma secuencia salvo la fila divergente, así que un **único orden de archivo**
  filtrado por `halves` reproduce el orden exacto de cada mitad y ninguna reordena.
  Verificado en Python: 16 keys, mismo orden que antes.
  Semántica del marcador, escrita en el encabezado del propio archivo: nombra las
  mitades que **tienen** la fila, y no afirma que las dos la rendericen igual. Las
  filas compartidas se apoyan en el invariante que el repo ya declara
  (`odd/tasks/google-calendar-nim-read.md`: el texto de las filas es un invariante
  entre ports), y el pin de acuerdo de **T4c-2** es lo que lo hará cumplir por primera
  vez. **Residual honesto**: si alguna de las 13 filas compartidas divergiera en un
  campo, este archivo convertiría la divergencia en convergencia silenciosa dentro de
  T4c-2 en vez de fallo ruidoso. No se comprobó campo por campo en esta rebanada.
  Lo que no puede ser dato: `_BEHAVIOUR`, un dict por `key` con
  `enabled`/`probe`/`normalize`. Una fila marcada `python` sin entrada levanta
  `ValueError` nombrando la key. Falta el guard simétrico (una entrada sin fila es
  código muerto); no lo pide el diseño y queda como pendiente.
  Pines, test-first: el par wheel+lookup en `test_packaging.py` (espejo exacto del
  que dejó T4a) y, en `test_integrations.py`, que el archivo es la fuente de las filas
  **y de su orden**, que una fila `python` sin comportamiento levanta, y que Python no
  gana `obsidian`. Tres rojos antes y verdes después; el cuarto, el de no convergencia,
  verde desde el principio como pin del comportamiento previo.
  Evidencia: oráculo `.venv/bin/python scripts/generate_env_example.py --check` exit 0
  sin diff antes y después; suite determinista **7 failed, 3352 passed, 62 skipped**,
  los mismos 7 nombres de L23/L33 y `3347 + 5` = los cinco pines nuevos; differential
  contra `git archive HEAD` **idéntico** en filas declarativas, campos de env,
  **bytecode** de cada closure, resultados de `enabled`/`normalize` sobre cinco
  entornos sintéticos (uno inválido, con el mismo `ValueError`) y el render completo de
  `.env.example`. Detalle que costó una vuelta: la primera versión del differential
  comparaba `inspect.getsource` de cada closure y marcó 16 diferencias que eran sólo de
  **ubicación** en el archivo; la prueba buena es la huella del bytecode. Las 5 de
  `test_pinned_models` dependen del entorno del desarrollador (`.env`) y no se
  compararon línea por línea: el editable install de hatchling impide correr el código
  previo desde un árbol aparte (`PYTHONPATH` no gana al finder), así que la evidencia
  ahí es el conteo y los nombres idénticos contra el baseline ya registrado. Las dos
  rojas independientes del estado (`test_static_assets`, `test_turn_evals`) fallan
  igual en un árbol sin estado, y `test_static_assets` conserva el texto exacto de L30
  (`Extra items in the left set: 'obsidian.svg'`).
  `ruff`: mis archivos limpios; el único hallazgo es un `F401` en
  `test_observability.py`, que no toqué, así que el paso de lint de esta rama ya estaba
  rojo. Regla 9: `AGENTS.md`, `README.md`, `docs/architecture.md` y el comentario del
  paso de CI en `.github/workflows/validate-skills.yml` enumeraban `data/` sin el
  registry de conexiones, y el docstring del módulo decía que no hacía I/O.
  Tamaño: 647 insertions / 141 deletions en 9 archivos, por encima de la guía de ~400
  líneas, y **no se partió** porque datos y loader son un solo comportamiento —el pin
  rojo lo prueba—: un commit que sólo agregue el archivo deja un archivo que nadie lee
  y ninguna prueba que lo exija.
  El aviso del harness volvió a medir la rama contra `origin/main` (245 commits,
  68.824 líneas): sigue en pie la decisión de **Estrategia de entrega**, que es del
  usuario y no mía.
- **L36** (interrupción externa ×3 y ejecución inline, 2026-11-02): el writer de
  T4c-2 murió con `assistant reported an error (quota)` como los tres anteriores
  (L19, L33, L34) — y esta vez **después de escribir parte del brief**: dejó
  `nim/tests/test_blackbox.nim` con el par de pines end-to-end y el fixture
  (`runBinaryIn`, `registryFreeDir`) ya puestos, y no tocó `nim/src/` (ni un byte
  del arreglo). No se reintenta y no se cambia de agente para esquivarlo. **La
  salida parcial de un writer muerto es evidencia a verificar, no a descartar ni a
  creer**: el padre la leyó, la compiló, **observó el RED con ella** (el binario de
  ese momento, 15 OK, los dos pines nuevos en rojo con la excepción de
  inicialización, EXIT=1) y ejecutó el arreglo del código fuente inline. Esos pines
  recuperados, con un nombre de API distinto al que el padre terminó implementando,
  quedaron reconciliados a favor de los nombres del writer (`loadIntegrationsBestEffort`,
  `integrationRegistryError`) y **fueron los que atraparon la regresión de punta a
  punta**, que ninguna suite de módulo veía.
- **L37** (evidencia, regresión encontrada y decisiones de T4c-2, 2026-11-02,
  `1524a45`): la mitad Nim lee `data/integrations.toml` — filtrado por `halves`, en
  el orden del archivo — y `INTEGRATIONS` pasó de literal a dato. Lo que no puede
  ser dato: `BEHAVIOUR`, un `Table[string, IntegrationBehaviour]` con
  `enabled`/`normalize` por `key` (el `_BEHAVIOUR` de Python). El parser cubre el
  subconjunto que el archivo usa (`[key]`, `[[key.env]]`, string/bool/lista de
  strings) y reusa `unquote`/`stripInlineComment` de `providers.nim`, que ahora se
  exportan sin cambiar una línea de su cuerpo. El lookup vive **en el propio
  módulo** y no en `waku.nim` como `findProvidersToml`, porque `INTEGRATIONS` se
  inicializa acá y `waku.nim` importa este módulo: allá era un ciclo.
  **La verificación independiente encontró una regresión real que las 20 primeras
  suites no veían**: con `INTEGRATIONS` como `let` de módulo, un registro
  inalcanzable levantaba **en la inicialización del módulo**, así que TODOS los
  comandos morían, `--help` incluido (medido con los dos binarios: desde un
  directorio fuera del checkout, `--help` daba exit 1 con el cambio y exit 0
  antes). El arreglo copia el precedente de `providers.toml` en vez de inventar
  otro: `loadIntegrationsBestEffort` degrada a cero filas y devuelve el motivo, y
  los dos comandos que renderizan esas filas (`connections` y `dashboard`) lo
  imprimen en stderr y salen 1. Medición de cierre: desde un temp dir,
  `--help`/`--version` exit 0 y `connections` exit 1 con **una** línea que nombra
  `integrations.toml` (con `data/providers.toml` copiado, porque el guard de
  proveedores corre primero y sin él el pin medía el archivo equivocado); desde el
  repo root y desde `nim/`, `connections` sigue en 0 y lista.
  **Decisiones.** (a) **Un solo commit**, no dos: partir el guard de arranque
  dejaría un estado intermedio donde un registro faltante renderiza una página de
  Connections vacía, que es justo el fallo silencioso que este diseño evita; el
  tamaño (633 líneas en 7 archivos, más la suite nueva) excede la guía de ~400 y se
  registra acá en vez de partirse por la línea. (b) La tabla se llama `BEHAVIOUR` y
  no `INTEGRATION_BEHAVIOUR` porque Nim ignora guiones bajos y mayúsculas salvo la
  primera letra: `INTEGRATION_BEHAVIOUR` y el tipo `IntegrationBehaviour` son el
  mismo identificador, y el choque costó una compilación. (c) El pin de acuerdo
  lee la tabla de Python **como texto** a propósito: el port no puede importar
  Python, y ese pin es lo único que hace ruidoso el desvío de `notion`/`obsidian`
  mientras `waku/` siga en el árbol; muere con la mitad Python. Se lo robusteció
  para que el marcador sea estructural (`_BEHAVIOUR`, …, `{`) y no el nombre del
  tipo anotado al lado.
  **Evidencia.** Differential en dos árboles separados (el módulo de `HEAD` contra
  el nuevo, mismo dumper): 14 filas, mismo orden, 1.598 líneas por lado, 504
  observaciones de `enabled` × `normalize` (incluido el `ValueError` exacto de
  `DISCORD_MAX_TURNS_PER_HOUR`) y **diff vacío**, reproducible byte a byte. Suites
  Nim tocadas: `test_integration_rows` 24, `test_blackbox` 17, `test_integrations`
  70, `test_dashboard` 137, `test_cli` 28, `test_memory_arena` 48, `test_connect`
  32, `test_registry` 7, todas EXIT=0. Oráculo `generate_env_example.py --check`
  exit 0 sin diff.
  **Residuales honestos.** (1) Los pines 1 y 2 de la suite de acuerdo quedan
  tapados por la negativa de inicialización: ante un desvío del lado Nim el
  binario de test muere nombrando la clave y corren 0 pines; el único con poder de
  detección independiente es el de Python (probado con 9 mutaciones, incluida una
  fila `python` sin `halves`, que ahora es una línea de motivo y no un crash).
  (2) Sólo los dos comandos del binario rechazan; otro consumidor de `INTEGRATIONS`
  (el `memory_arena` del banco) vería una lista vacía y no renderizaría nada —
  deliberado, son las superficies de esta unidad. (3) Los conteos fijos (17 filas,
  14 claves) hacen que una conexión nueva legítima cueste editar un pin. (4) La
  roja de `test_static_assets` (`obsidian.svg` de más) **no se toca acá**: el
  invariante "un logo por key" es de T5. (5) El aviso del harness volvió a medir la
  rama contra `origin/main` (69.493 líneas en 247 commits): la Estrategia de
  entrega sigue siendo decisión del usuario.
- **L38** (el usuario declinó este candidato, 2026-11-02): `review.start` sobre el
  target `sha256:8c32ae8c…` devolvió `answer-consent` / `status: skipped` /
  `consent-declined-this-candidate`, con `lineage_created: false`,
  `mutation_performed: false` y `reset_eligible: false`: **no se creó autoridad y
  no se mutó nada**. El sobre, que es la medición más honesta que tenemos del
  candidato que el controlador ofrece, dice **414 archivos y 86.462 líneas, riesgo
  alto**, con evidencia `authentication in nim/src/google_auth.nim` y `shell
  scripting in .github/workflows/nim.yml` — o sea **la rama entera contra
  `origin/main`** (`--base-ref=4b69b321…`, `projection=workspace`), no la unidad de
  T4c-2 (`1524a45`), que ya tiene su verificación independiente y su differential.
  El `inspect` lo dijo con todas las letras: `applicability: unrelated` y 250+ paths
  (`paths_digest sha256:5c749d65…`), la misma clase que el controlador ya rechazó
  dos veces con `lens_context_budget_exceeded` (L26, L31).
  **Una declinación es del candidato, no el kill switch**: el switch sigue on
  global, ningún linaje quedó abierto ni quemado, y un candidato distinto pide
  consentimiento nuevo. Lo que sigue cerrado es la compuerta de la rama, y por la
  razón de siempre: `inspect` proyecta contra `origin/main`, y `origin/main` sólo se
  mueve publicando, que es decisión del usuario (hoy: no publicar). Mientras la
  rama no se trocee, cada commit regenera un candidato de este tamaño.
- **L39** (T5 landed, 2026-11-03, `de4348b`): el writer de T5 murió con
  `provider_unavailable` —cuarta muerte de la feature (L19, L33, L34, L36)—
  después de escribir casi todo: dejó completo el arreglo del pin Python y tres de
  los cuatro pines Nim (148 líneas en los dos archivos), sin compilar ni reportar.
  Como en L36, el padre trató esa salida como **evidencia a verificar, no a creer**:
  la compiló, observó cada RED por su cuenta y **agregó la prueba que faltaba**, la
  cuarta del pin Python (`test_brand_mark.py:36-41`, el README ofrece las dos
  tintas), porque S5 no permite portar dos de tres hechos.
  **Lo que T5 resultó ser.** "Reapuntar" ya estaba hecho por T4b: los dos guards
  Python leen `data/static` desde entonces. El trabajo real fue la mitad Nim y una
  roja que llevaba desde L23.
  **Decisiones.** (a) La llave del invariante "un logo por key" es
  `data/integrations.toml`, no `INTEGRATIONS`: la tupla de Python es su vista, filtra
  las filas cuyo `halves` no dice `python`, así que `obsidian` (fila `halves =
  ["nim"]`) nunca podría satisfacerla y el pin estaba rojo por construcción. El
  archivo compartido es además lo único que sobrevive a retirar `waku/`, que es de
  lo que se trata S3. `treg` no necesitó caso especial: es una fila más (17 filas,
  17 logos), y la afirmación "las tarjetas MCP no están en el registry" que el
  comentario viejo hacía quedó falsa con T4c-1, así que el comentario nuevo dice lo
  que el archivo prueba. (b) Los dos pines nuevos viven en
  `test_repo_gates.nim`, que ya tenía el sha256 de las copias de diseño y la
  ancla `repoRoot()`; un suite aparte sólo se justificaba si la lógica crecía su
  propio parser, y no creció. (c) El lector de geometría usa `find` y no `match`:
  el `re` de Nim ancla `match` al principio de la cadena y el pin Python hace
  `re.search`.
  **Evidencia.** Cada pin visto RED por el hecho que afirma antes de GREEN, con el
  árbol real intacto: las mutaciones se hicieron en una copia en `mktemp -d`. Nim,
  cuatro pruebas en "phase 9b-1 the brand mark and the connection logos": `d`
  desviada en la variante clara → `has drifted from data/static/waku-mark.svg`;
  `<source>` oscura borrada → `only one ink is ever offered`; README sin el archivo
  oscuro → `never references waku-mark-on-dark.svg`; logo huérfano →
  `these logos have no key in data/integrations.toml: @["zzz_orphan.svg"]`; y
  `obsidian.svg` faltante → `no data/static/logos/connections/<key>.svg for:
  @["obsidian.svg"]`, que es justo la fila que el pin Python no podía ver. Suite
  EXIT=0 en el árbol real, compilada sin warnings. Python: el pin de `HEAD` rojo con
  el texto exacto de L30/L35 (`Extra items in the left set: 'obsidian.svg'`), el
  arreglado 7 passed, y sigue rojo en las dos direcciones (huérfano y faltante).
  Suite determinista completa **6 failed, 3353 passed, 62 skipped** contra
  7 failed / 3352 passed: `test_static_assets` sale de la lista de L23 y las seis
  que quedan son las mismas de siempre (5 de `test_pinned_models`, que dependen del
  `.env` del desarrollador, y `test_turn_evals`). `ruff` limpio (`uvx ruff`, porque
  el venv del repo no lo trae).
  **Residuales honestos.** (1) El pin del brand mark compara el **primer** `d` de
  cada archivo, igual que el pin Python: un segundo path que divergiera no lo ve
  ninguno de los dos, y se porta el mismo hecho en vez de mejorarlo en silencio.
  (2) La precisión del lector se pinea con texto, no con un archivo, porque el test
  no puede escribir en el árbol. (3) No se porta el `alt`/`width` del README: no es
  un hecho del pin Python. (4) `test_static_assets.py` ya no importa `INTEGRATIONS`
  ni `treg`; cualquier otro eval que dependiera de ese import fallaría en su propio
  import. (5) La roja de `test_turn_evals` sigue ajena a esta feature. (6) El aviso
  del harness volvió a medir la rama contra `origin/main` (250 commits, 69.754
  líneas): la Estrategia de entrega sigue siendo decisión del usuario.
- **L40** (segundo candidato declinado, 2026-11-03, tras T5): `review.start` sobre el
  target `sha256:df990e0c…` (el árbol con `de4348b` y `ba5bfb1`) volvió con
  `answer-consent` / `status: skipped` / `consent-declined-this-candidate`, y otra vez
  con `lineage_created: false`, `mutation_performed: false`, `reset_eligible: false`:
  **no se creó autoridad y no se mutó nada**. La medición del sobre es la misma foto
  que L38, movida por dos commits: **414 archivos, 86.703 líneas, riesgo alto**,
  evidencia `authentication in nim/src/google_auth.nim` y `shell scripting in
  .github/workflows/nim.yml`, base `4b69b321…` = `origin/main`. El `inspect` volvió a
  decir `applicability: unrelated` con el **mismo `paths_digest`** (`sha256:5c749d65…`)
  que la declinación anterior. Conclusión operativa: **la forma del candidato no la
  mueve el trabajo de las tareas**, porque la base sigue siendo `origin/main`; cada
  commit de la rama vuelve a ofrecer el mismo alcance. La salida es la Estrategia de
  entrega (trocear o publicar), que es decisión del usuario, o `D` para esta copia.
- **L41** (evidencia, T8, 2026-11-03): el pin de `.env.example` contra el registry
  quedó en Nim y, al escribirlo, destapó que el **port del registry no era
  byte-paridad**: el render Nim daba 181 líneas contra las 205 del archivo
  committed, y `python scripts/generate_env_example.py --check` estaba **verde**
  (así que el drift no era del archivo, era del port). Tres causas, las tres
  arregladas en esta unidad:
  (1) `parseProviders` saltaba toda tabla `[[...]]`, así que los
  `[[minimax.endpoints]]` / `[[moonshot.endpoints]]` / `[[zhipu.endpoints]]`
  de `data/providers.toml` nunca se leían y la fila base-url del proveedor no
  existía; ahora hay un `Endpoint` (`label`, `baseUrl`) por fila y el header
  cuelga del row **que nombra**, no del último (mismo semantics que `tomllib`;
  lo cazó el segundo test, que esperaba tres filas y veía dos).
  (2) `integrationFromProvider` documentaba a propósito que omitía el campo
  Base URL `CHOICE`; Python lo agrega cuando la fila tiene `base_url_env` y
  endpoints, y el archivo committed lo muestra para esos tres proveedores.
  (3) el render usaba `INTEGRATIONS` (las filas del half **Nim**), pero el
  archivo committed es el del half **Python**: `data/integrations.toml` marca
  `notion`, `treg` y `typesafe` como `["python"]` y `obsidian` como `["nim"]`,
  así que el bloque dice Notion/treg/TypeSafe y nunca dice Obsidian. Se agregó
  `envExampleIntegrations(rows)` (filtra `"python" in halves`, en orden de
  archivo) y `renderEnvExampleBlock(providers, statics)` toma las filas
  estáticas como parámetro: el pin de repo le pasa el half Python y el test
  dorado del renderer le sigue pasando `INTEGRATIONS`, así que se conservan
  los dos hechos.
  **Evidencia.** Roja conductual observada dos veces: el pin nuevo en el árbol
  real (205 vs 181, primera diferencia en la línea 31) y los dos `compile
  error` de los tipos/procs nuevos antes de implementarlos. Verde: en una copia
  `mktemp` del árbol, editar una línea del bloque la hace fallar con "the
  generated Connections block in .env.example is out of date: first differing
  line 32…", y borrar el marcador la hace fallar con ".env.example is missing
  generated Connections markers: no # BEGIN GENERATED CONNECTIONS"; el árbol
  real no se tocó. Cinco pines nuevos: `test_providers` (endpoints en orden de
  archivo, y que una tabla no se herede de la anterior), `test_integrations`
  (la vista del half Python y el campo choice de base-url, con y sin
  endpoints), `test_repo_gates` (bloque committed == render del registry).
  Suite Nim completa: **74 archivos verdes**, 19 checks en `test_repo_gates`,
  73 en `test_integrations`, 10 en `test_providers`. La única roja es
  `test_tls` ("why a finally that catches swallows the refusal in flight"),
  **pre-existente y ajena**: el mismo fallo aparece compilando y corriendo ese
  archivo en un worktree limpio en `HEAD`.
  **Residual honesto.** `test_integrations` sigue pineando la forma del bloque
  dorado con las filas del half Nim; el hecho del archivo committed es el del
  pin de repo. Y las notas de T5 sobre el candidato de review (L38/L40) no
  cambian: la base sigue siendo `origin/main`.
- **L42** (tercer candidato declinado, 2026-11-03, tras T8): el controlador de RDD
  ofreció `review.start` para el target `sha256:1e58fde0…` (el árbol con
  `91750b2` y `d01a264`), y la compuerta de consentimiento se resolvió **declinada**
  en el host: `action: declined`, `consent: declined_this_candidate`,
  `lineage_created: false`, `mutation_performed: false`, `reset_eligible: false`.
  La medición del sobre es la misma foto que L38 y L40, movida por dos commits:
  **414 archivos, 87.004 líneas, riesgo alto**, evidencia `authentication in
  nim/src/google_auth.nim` y `shell scripting in .github/workflows/nim.yml`, base
  `4b69b321…` = `origin/main`. Ningún intento creó autoridad. Un detalle nuevo de
  la fachada: un `lensesReason` de una línea larga también se rechaza con
  `reason: lenses-reason-invalid` y `field: lensesReason` (no sólo el vacío o el
  multilínea): la versión corta pasó. Conclusión sin cambios: el alcance del
  candidato no lo mueve el trabajo de las tareas; la salida sigue siendo la
  Estrategia de entrega (trocear o publicar), decisión del usuario, o `D`.
- **L43** (T7 landed, 2026-11-03): la decisión, primero. T7 pedía "definir ·una
  versión· en un repo Nim-first", y eso no se resuelve leyendo código: hoy Nim
  dice `0.0.1` (`nim/waku.nimble:10`) y la mitad Python dice `0.1.9`
  (`waku/__init__.py:11`), y **ningún pin cruzaba las dos mitades**. Las tres
  salidas se pusieron sobre la mesa con su costo, y el usuario eligió:
  **"Dos fuentes, una por mitad, sin exigir igualdad"**. La regla quedó escrita en
  el pin, no en una nota: un literal editable **por mitad**, y las mitades quedan
  libres de coincidir o de diferir. Forzar la igualdad habría obligado a tocar la
  mitad congelada (S1) cada vez que el binario sube, y habría puesto a los tres
  workflows de release de Python —que reescriben `__version__`— a mover la
  versión del binario Nim; una `VERSION` en la raíz lo había sido todo lo
  contrario: la más limpia en teoría y la única que obliga a reescribir esos
  workflows y a abandonar el `dynamic` de `pyproject.toml`.
  **Qué se construyó.** El port de S3 vive en `nim/tests/test_version.nim` como
  segunda suite, `"one version literal per half"`: los tres hechos de
  `test_version.py` leídos del árbol (el `[project]` de `pyproject.toml` no
  declara versión y la lista en `dynamic`; `[tool.hatch.version] path` es
  `waku/__init__.py`; el literal de la mitad Python es `^\d+\.\d+\.\d+$`), con un
  lector TOML de línea para las dos tablas —no un parser— y sin escaneo de todo
  el árbol, que sería alcance no pedido y frágil. Y el hecho nuevo que la regla
  necesita: la fila de CI de `AGENTS.md` decía "a second version number", que ya
  es falso, así que dice "a second version literal in either half" y nombra los
  dos guardarraíles. Un pin en `nim/tests/test_repo_docs.nim` sostiene esa fila
  (T3 es su casa), porque una fila que deja de nombrar un guardarraíl deja de
  proteger algo. **El writer murió por sexta vez** (`auth`) dejando 186 líneas
  escritas en 3 archivos y sin reporte; el padre las verificó como evidencia y las
  commiteó sin reescribirlas.
  **Evidencia.** Roja real, no simulada: revertir la fila en una copia `mktemp`
  hace fallar el pin con "the CI table must name both version guards in one row;
  it names 0 such rows", y restaurarla lo pone verde. Cuatro mutaciones en la
  copia, cada una cae por su propio hecho: `version = "9.9.9"` bajo `[project]`
  → "pyproject keeps the version dynamic…"; el `path` de hatch apuntando a otro
  archivo → "hatchling reads the Python half's version from the package"; `0.1`
  en la mitad Python → "not a release number: 0.1"; y el `nimble` con una segunda
  copia sigue cayendo en el pin que ya existía. `make nim-test`: **1.373 `[OK]`,
  una sola roja, `test_tls`**, que aborta la corrida en la suite 65 de 75; las 10
  que quedaron sin correr se corrieron una por una (**222 `[OK]`, 0 rojas**), y
  `test_tls` se reprodujo con el mismo pin en un `git archive HEAD` limpio, así
  que sigue siendo pre-existente y ajena. `pytest test_rulebook.py test_version.py`
  → 20 passed, y `test_version.py` quedó **sin tocar** (`git diff --name-only`).
  **Residual honesto.** El aviso de tamaño de rebanada que imprime el harness en
  cada commit (257 commits, 70.314 líneas sobre `origin/main`) es la condición que
  ya documenta la Estrategia de entrega, no un hallazgo nuevo de T7. Y una deriva
  que T7 no causa ni arregla: `docs/status.md:43` dice "0.1.8 is on PyPI" mientras
  el literal es `0.1.9`; material de T9.
- **L44** (quinto candidato declinado, 2026-11-03, tras T7): el usuario pidió
  reintentar la compuerta. `inspect` volvió a ofrecer `start` sobre el mismo
  candidato de rama (`sha256:ef8cb2868…`, base `4b69b321` = `origin/main`,
  `committed-only`) y el `START` se resolvió **declinado en el host**:
  `changed_files: 414`, `changed_lines: 87.257`, `risk_level: high`, evidencia
  `authentication in nim/src/google_auth.nim` y `shell scripting in
  .github/workflows/nim.yml`, `lenses_required: false`, `lineage_created: false`,
  `mutation_performed: false`, `reset_eligible: false`. Tercera medición idéntica
  salvo el movimiento por commits (L38, L40, L42 → L44). Nada que reintentar: la
  compuerta no la abre el trabajo de las tareas, la abre mover `origin/main`, y
  `main` está protegido. Las dos salidas siguen siendo la Estrategia de entrega
  (trocear la rama o publicar) o `D` para esta copia.
- **L45** (T9 landed, 2026-11-03 — cierre de la feature): T9 pedía "los docs que
  el cambio vuelve falsos (regla 9) + cierre". Se levantó la lista con un
  explorer, no a ojo, y el resultado desarmó la expectativa de la fila: **`T2` y
  `T2b` ya habían hecho su trabajo**. `README.md`, `AGENTS.md`, `CONTRIBUTING.md`,
  el `Makefile`, `docs/README.md`, `status.md`, `architecture.md`,
  `integrations.md`, `evals.md`, `getting-started.md`, `commands.md`, `tour.md`,
  `roadmap.md`, `providers-registry.md`, `docs/context/{design-system,gotchas,
  writing-rules,maintainers}.md`, `nim/README.md`, `data/static/README.md` y
  `examples/README.md` describen el binario como la puerta y la mitad Python como
  congelada. **No se tocaron**.
  **Los cinco que sí mentían** (`9486dff`):
  (1) **`docs/context/conventions.md` §3, la escalera de footprint** — el daño
  mayor, porque `AGENTS.md` manda ahí a quien va a agregar capacidad: ponía las
  herramientas nuevas en `waku/tools/` y los gateways en `waku/gateway/`, y
  cerraba diciendo que no había escalón para un paquete de primer nivel
  "como `waku/graph/`" cuando `nim/src/graph/` ya existe. Ahora los escalones 4 a
  6 nombran `nim/src/`, el flag de build que admite una capacidad
  (`make nim-build-tls`), los vecinos de `gateway.nim` y `tools.nim`, y la
  escalera dice en voz alta que `waku/` no toma capacidad nueva de ningún escalón.
  (2) **`.claude/skills/new-tool/SKILL.md`**, el que `AGENTS.md` recomienda para
  agregar una herramienta: enseñaba `waku/tools/`, `build_registry` y un eval en
  `evals/deterministic/`. Ahora construye un `Tool` en `nim/src/`, lo entrega a
  `register(...)` y pinea comportamiento en `nim/tests/test_*.nim`.
  (3) **`skills/community/README.md`** instalaba con `python -m waku skill
  install`; ahora `waku skill install`, que es el dispatch que el binario ya
  tiene (`nim/src/waku.nim:637`) y la forma que usa `docs/commands.md`.
  (4) **`skills/waku-memory/SKILL.md`** exigía el extra MCP a todo el mundo; solo
  lo necesita la mitad congelada.
  (5) **`docs/nim-port-design.md`** decía "Status: PROPOSED. No Nim code yet" y
  nombraba a Python fuente de verdad "hasta que el port pase los evals fase por
  fase". Queda como registro de la propuesta, en pasado.
  **Evidencia.** `pytest test_rulebook.py test_skill_triggers.py` → 70 passed;
  `scripts/validate_skills.py` → 7 skills OK; `test_repo_docs` 15 OK y
  `test_repo_gates` 19 OK (los links nuevos resuelven y el índice sigue completo).
  Un residual honesto: `docs/status.md:43` dice "0.1.8 is on PyPI" mientras el
  literal de la mitad Python es `0.1.9`. No lo toqué porque no es un hecho que
  este cambio vuelva falso: o el release no se publicó, o la línea está vieja, y
  distinguirlo requiere mirar PyPI, no el repo.
  **Cierre verde**: T0, T1, T2, T2b, T3, T4 (a, b, c-1, c-2), T5, T7, T8 y T9,
  cada una con su commit y su registro; `test_version.py` intacto; suite Nim con
  una sola roja pre-existente y ajena. **Cierre pendiente, y ninguno es una tarea
  de esta feature**: las 6 rojas deterministas de `add-cline-provider` (lo que
  impide aterrizar el port), la decisión sobre la roja de `test_tls`, la cuota
  del proveedor de subagentes que frena T3b y T6, la verificación independiente de
  T4c-1, y la compuerta de review con sus cinco candidatos declinados sin
  autoridad: trocear o publicar, decisión del usuario, o `D`.
