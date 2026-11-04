# Plugin loader paso 2 — dlopen mínimo JSON

Cambio autorizado. Cargar un plugin `.so` real: `loadLib` → version gate → `init` (llama `NimMain` una vez) → `describe` → nodos `plugin:<plugin>/<nodo>` como closures `NodeFn`/`RouteFn` sobre punteros resueltos. Descubrimiento: escaneo de `.waku/plugins/*.so` (decisión del usuario). Sin unload, sin `HostFns` real todavía (tabla con nulls; basta para nodos `tool` sin `needs`).

Estado al 2026-11-04. Base `c5ad777`. Sin código aún.

## Specs

- **S1 — Carga y validación.** `loadLib` nil y `symAddr` nil se chechean (nunca `checkedSymAddr` sin manejar); `abi_version != 1` rechaza; `init` devuelve 0 o se rechaza. Citas del usuario: "ok, vamos al paso 2" y "nos quedamos con JSON v1".
- **S2 — Llamada segura.** El host serializa solo las `inKeys` declaradas, copia el `cstring` devuelto a su heap **antes** de `string_free`, parsea el envelope; `ok:false` se convierte en raise para reusar `runOne` → `state["errors"]` sin mergear. `route` viaja por `RouteFn` análoga.
- **S3 — Descubrimiento.** El loader escanea `.waku/plugins/*.so` al arrancar (opción elegida: ".waku/plugins/*.so"). Vida del `LibHandle` = proceso; jamás `unloadLib`.
- **S4 — Testeado.** Fixture `nim/tests/fixture_plugin.nim` (no `test_*`, para que la task `test` no lo ejecute) compilado en runtime del eval a temp dir con `--app:lib --panics:off`; pin determinista offline: carga, describe, node_run patch, route, ok:false → errors, versión mala rechazada.

## Tasks

| ID | Tarea | Spec | R |
|---|---|---|---|
| T1 | `nim/src/graph/plugins.nim`: tipos, carga, version gate, init+NimMain, describe, `pluginNode`/`pluginRouter` | S1, S2 | P |
| T2 | Descubrimiento `.waku/plugins/*.so` + registro como `plugin:<p>/<n>` | S3 | P |
| T3 | Fixture plugin + pin determinista + verificación + commit | S4 | P |

## Log

- **L1** (usuario, verbatim): "ok, vamos al paso 2"
- **L2** (usuario, decisión descubrimiento, verbatim opción): ".waku/plugins/*.so"
- **L3** (diseño previo): JSON v1 queda; binario futuro exigiría ABI v2 `(ptr,len)` + `buffer_free` (ver memoria `graph-plugins-abi-design`).
- **L4** (handoff explorer `mw2dfp3s-4-pjsg`): contrato en docs/graph-plugins-design.md:55-125; `std/dynlib` (`loadLib` nil-si-falla, `symAddr` nil-si-falta, sin RTLD_GLOBAL); `--app:lib` POSIX genera `NimMain` exportado **sin** constructor → llamar desde `waku_plugin_init` una vez; procs `{.cdecl, gcsafe.}`; waves secuenciales pero turns HTTP concurrentes sin verificar → documentar "one call at a time" o mutex; fixture se compila en el eval (offline, compilador local).
- **L5** (evidencia paso 2): `nim/src/graph/plugins.nim` nuevo (tipos, `nullHostFns`, `loadPlugin` con gate+init+describe, `callPlugin` con copy-before-free, `pluginNode`/`pluginRouter`, `discoverPluginPaths`/`loadDiscovered` sobre `.waku/plugins/*.so`, `findPluginNode`); fixture `nim/tests/fixture_plugin.nim` (alloc0/dealloc propio, `-d:fixtureAbi`); pin `nim/tests/test_plugin_loader.nim` 5 OK. Vecinos: registry 7, graph 27, workflows 28, gateway 5, dashboard 137 — 0 FAILED. Dos hallazgos: (1) `{.exportc}` sin `dynlib` deja el símbolo local y `symAddr` no lo ve — fixture y ejemplo del doc corregidos a `{.exportc, cdecl, dynlib.}`; (2) el mensaje de rechazo llamaba `$abiFn()` DESPUÉS de `unloadLib` → segfault — regla: capturar todo antes de descargar. La hipótesis intermedia "dos runtimes Nim no coexisten" quedó refutada (dos fixtures inicializados conviven); el muerto era el bug (2).
