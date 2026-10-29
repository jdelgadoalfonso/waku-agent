# Google Calendar en el port Nim: `list_events` lee el calendario real

Tier: bugfix + port (conventions §2). No hay proposal: el pedido es del usuario
(S1-S2) y el alcance lo fija la asimetría que él mismo encontró. El Log L4
guarda la única decisión que sigue en su cancha.

## Specs

- **S1** (petición del usuario, verbatim):
  > está funcionando, sin embargo si le pregunto por el calendario mira lo que
  > me dice:
  >
  > ¿qué tengo hoy en mi calendario de google?
  >
  > No hay ningún evento en tu calendario para hoy (miércoles 2026-10-28). He
  > revisado el calendario local de Waku y está vacío.
  >
  > Ten en cuenta que esto es el calendario local de Waku; no puedo
  > confirmarte si hay algo en tu Google Calendar que no se haya sincronizado
  > con este sistema. Si quieres, puedo programar algo en tu calendario local.

- **S2** (alcance, verbatim):
  > Por otro lado centrate en la versión hecha en Nim

- **S3**: `list_events` del port consulta el calendario `primary` de la cuenta
  que ya inició sesión (`~/.waku/google-token.json`, scope
  `calendar.events.readonly`) además de su sqlite local, y cada sección dice de
  qué calendario viene.
- **S4**: una respuesta "No events found" solo puede nombrar fuentes que
  realmente se leyeron; sin `~/.waku/google-token.json`, la línea `Checked:` no
  menciona Google.
- **S5**: ningún fallo de Google (token ausente o vencido, refresh rechazado,
  4xx/5xx, cuerpo ilegible) lanza ni se disfraza de lista vacía: es una frase,
  y la sección de Google desaparece cuando no hay nada real que agregar.
- **S6**: la lectura usa la ventana local del usuario (`timeMin`/`timeMax`
  RFC3339 con offset, medianoche local a medianoche local) y `singleEvents=true`,
  para que una reunión recurrente sea la instancia del día y no la serie.
- **S7**: el refresh del token de Google viaja como
  `application/x-www-form-urlencoded`. Mandarlo como JSON era la razón por la
  que *todo* refresh del port fallaba, Gmail incluido (L3).
- **S8**: crear y sincronizar eventos (`sync_to_google_calendar` en Python)
  queda fuera: es un camino de escritura y sigue sin portar. La fila de
  Connections en el port sobreestima esa mitad (L4).

## Tasks

- **T1** — Diversión compartida + fix del refresh: `nim/src/google_auth.nim`
  (nuevo), `nim/src/gmail.nim` adelgazado a un reenvío, `wantsFormBody`, el
  pin del 403 en `nim/tests/test_gmail.nim`. S7. Inline. Commit 1 = `ecd88a8`.
  Unidad propia por riesgo alto (credenciales: es el refresh de un token).
- **T2** — Lectura de Google: `nim/src/google_calendar.nim` (nuevo) con el
  token propio, el scope readonly, la ventana local y `eventLine`. S3, S5, S6,
  S8. Inline. Commit 2 = `990dd25` (junto con T3: sin el cableado la tool no
  existe).
- **T3** — Composición y cableado: `listEventsComposed` en `nim/src/calendar.nim`
  (etiquetas + línea `Checked:`), `makeListEventsTool` con `home`/`googleFetch`/
  `clock`, `registry.nim` y `dashboard.nim`. S3, S4. Inline. Commit 2 =
  `990dd25`. Pins: `nim/tests/test_google_calendar.nim` (20).
- **T4** — La mitad Python que el bug destapó, porque las dos implementaciones
  comparten un `.waku/`: `reason()` + `MAX_ERROR_CHARS` + `token_info()` en
  `waku/tools/google_calendar.py`, `waku/tools/gmail.py` narrándose por ahí.
  S1, S5. Inline (ver `odd/tasks/gmail-integration.md`, L15/T10). Commit 3 =
  `a4be26d`.
- **T5** — Docs que el cambio vuelve falsos: `nim/README.md`,
  `docs/integrations.md`, `docs/status.md`, y el hueco de la fila anotado en el
  encabezado de divergencias de `nim/src/integrations.nim`. S8. Inline.
  Commit 4 = este commit.

## Log

- **L1** (petición original, verbatim):
  > está funcionando, sin embargo si le pregunto por el calendario mira lo que
  > me dice:
  >
  > ¿qué tengo hoy en mi calendario de google?
  >
  > No hay ningún evento en tu calendario para hoy (miércoles 2026-10-28). He
  > revisado el calendario local de Waku y está vacío.
  >
  > Ten en cuenta que esto es el calendario local de Waku; no puedo
  > confirmarte si hay algo en tu Google Calendar que no se haya sincronizado
  > con este sistema. Si quieres, puedo programar algo en tu calendario local.

- **L2** (alcance, verbatim):
  > Por otro lado centrate en la versión hecha en Nim

  El port es el destino. La mitad Python entra igual (T4) porque no es una
  preferencia sino un contrato: un solo `.waku/` y dos lectores.

- **L3** (el defecto grande que salió al portar): `liveGmailFetch` mandaba
  `Content-Type: application/json` en **todas** las llamadas, incluido el
  refresh, que es el único endpoint de Google que toma
  `application/x-www-form-urlencoded`. Respuesta real:
  `400 "Invalid JSON payload received. Unexpected token.\nclient_id=7714099517"`.
  Consecuencia: al vencer el access token (una hora), Gmail **y** el calendario
  habrían contestado "not connected" con el `refresh_token` intacto en disco.
  Arreglado con `wantsFormBody(url)` en `google_auth.nim`; verificado en vivo
  (refresh 400 -> 200). Que la mitad compartida exista es lo que hizo que un
  solo arreglo cubriera las dos capacidades.

- **L4** (decisión del usuario, resuelta en L7: opción 1 -- dejarlo como
  está): la fila `google_calendar` de
  Connections dice, en **ambos** ports, *"Lets Waku create and update Google
  Calendar events"*. En Python es cierto; en el port no existe crear ni
  sincronizar. Corregir solo el texto del port rompe
  `nim/tests/test_integrations.nim`: `renderEnvExampleBlock` debe reproducir
  `.env.example` byte a byte, y ese archivo se genera desde
  `waku/integrations.py`. El texto de las filas es un invariante entre ports.
  Estado actual = opción 1 (paridad intacta, hueco documentado en prosa).
  Opciones: (2) cambiar el texto en ambos ports y regenerar `.env.example` +
  el golden de Nim, o (3) dar al render del port su propia fila y romper el
  invariante a propósito. Recomendación: la 2 — subestimar una capacidad
  cuesta un descubrimiento; sobreestimarla cuesta una respuesta falsa del
  asistente, que es exactamente lo que trajo S1.

- **L5** (evidencia, verificada de nuevo al continuar): live, refresh 400 ->
  200, el calendario devuelve el día de hoy y el siguiente, Gmail sigue
  devolviendo correos tras el refactor. Nim: `test_google_calendar` 20,
  `test_gmail` 30, `test_calendar` 7, `test_registry` 7, `test_integrations`
  70, `test_dashboard` 136, todas exit 0. Python: 53 passed en
  `test_google_calendar.py` + `test_gmail.py` + `test_gcal_oauth.py`.
  RED observado revirtiendo cada arreglo por separado (tres de Python, dos de
  Nim). `nimble test` corta en `tests/test_tls.nim`, que falla igual sin estos
  cambios (preexistente, ver `waku-branch-known-red-checks`).

- **L6** (continuación al día siguiente): recuperado el estado desde la sesión
  del 2026-10-28, re-verificada la evidencia (L5) y aterrizado el trabajo en
  cuatro commits de unidad en `add-cline-provider`, sin push. `waku/providers.toml`
  y `nim/config.nims` quedaron fuera: son cambios previos del usuario.
  Sigue abierta la decisión de L4 y, de la feature de Gmail, la de
  `nim/config.nims` en `.gitignore` (bloquea la admisión del review nativo).
  Entrega: la rama acumula ~65k líneas sobre `origin/main`; cualquier review
  nativo tiene que ser por rebanada, nunca por rama.

- **L7** (decisiones del usuario, 2026-10-29):
  1. La fila `google_calendar` **se queda como está** (opción 1 de L4): paridad
     byte a byte entre ports y el hueco de la escritura documentado en prosa.
     No hay cambio de código por esta decisión; el costo aceptado es que un
     usuario del port lee una capacidad que solo Python tiene.
  2. `nim/config.nims` **se commitea** (commit `a48ab2d`), que además
     desbloquea la admisión del review nativo (era el archivo sin declarar que
     hacía responder `unassessable`). No es parte de esta feature: es una
     decisión de build del repo, y su consecuencia es que lto y
     `-march=native` ahora aplican a todo el que compile el port, CI incluido.
  3. Con el árbol ya sin archivos sin declarar, la unidad completa de ayer
     queda revisable: `assess` sobre el rango de los seis commits.
