# Nim-first — congelar Python y portar los guardarraíles a Nim

Cambio grande, autorizado. Congela la mitad Python (`waku/`), pone el port Nim
al frente de la documentación y del `Makefile`, y porta a Nim los guardarraíles
del repo que hoy son pytest. **Retirar `evals/deterministic/` no es parte de
esta feature**: el port es lo que lo habilita, y la decisión de retirarlo queda
para después. `hosted/` queda en Python, sin tocar.

**Estado al 2026-10-31 (reanudación).** En la rama `nim-first` están landed T0
(que vive en `add-cline-provider`), T1, T2, T2b y T3: 10 commits, 16 archivos,
1.203 líneas sobre su base. T3b y T6 siguen sin empezar, bloqueadas por cuota del
proveedor. **T4a y T4b están landed** (`f834ffd` y `f526360`, más `57c60fb` para el
build del tenant que la mudanza rompió); T4c, T5, T7, T8 y T9 sin empezar.

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
del review; (3) T4 en tres rebanadas: T4a y T4b landed, T4c pendiente, y T4
desbloquea T5 y T8; (4) T7; (5) la decisión sobre la roja de `test_tls`; (6) T3b y
T6 en cuanto vuelva la cuota del proveedor de subagentes (L19).

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
