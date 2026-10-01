# Nim port — phase 6: MCP connector (hand-rolled, sin SDK Nim)

## Goal
Port `waku/tools/mcp_client.py` (299 líneas), `waku/tools/mcp_cli.py`
(191) y `waku/tools/mcp_oauth.py` (223) a `nim/src/mcp.nim` (+
`oauth.nim`/`mcpcli.nim` si 6b/6c lo piden), en tres unidades para
proteger revisión. No existe SDK MCP para Nim y la regla 3 prohíbe
nuevas dependencias por defecto: JSON-RPC a mano con stdlib
(`json`, `osproc`, `net`), como ya hace `http.nim` con SSE.
Toda E/S por parámetro (`env` como `Table`, `home` para storage),
transporte inyectado; cero red y cero subprocess reales en tests
(regla de fases previas: seams inyectados, tipos puros).

Gate de paridad: el demo `evals/fixtures/mcp_demo_server.py` (dos
tools: `demo_word_count`, `demo_reverse_text`) debe listarse y
llamarse contra respuestas grabadas; `waku mcp` debe mostrar lo
mismo que Python para un `mcp.json` dado. `nim/src/waku.nim` NO se
toca en 6a: el stub `mcp` de phase 4e queda (el cableado del
dispatch llega con la unidad que lo necesite); cambiarlo rompería
`test_cli.nim`.

## 6a — config + stdio JSON-RPC (HECHO, sin commits)
- Tipos puros `McpServerSpec` (name/command/args/env/url/authEnv/
  oauth) + `McpToolMeta` (name/description/inputSchema): el transporte
  se elige por forma (`url` vs `command`), nunca por campo
  `transport`, como `_open_streams`.
- `parseMcpConfig` (el `json.loads(...).get("servers", [])` de
  `start`; sin `servers` → vacío; JSON roto y entrada sin `name` →
  `ValueError`) + `validateSpec` con los tres `ValueError` de Python
  verbatim (ambos transportes, ambas credenciales, `auth_env` sin
  exportar — fallar aquí, no conectar anónimo contra un 401 que
  parece outage) + `connectError` (stdio → `""`; remoto → aplazamiento
  honesto a 6b, patrón 501 del dashboard).
- `modelSafeName` (port de `_model_safe_name`, cola de 64 + `lstrip`
  incluida: `waku_memory` + `memory.remember` vive en el test) +
  `authHint` (port de `_auth_hint`: oauth nunca apunta a `auth_env`).
- JSON-RPC stdio a mano (`initialize` con `protocolVersion` +
  `clientInfo Waku`, `notifications/initialized`, `tools/list`,
  `tools/call` con `name` + `arguments`; una línea + `\n` por
  mensaje, como el `stdio_client` del SDK) + `checkResult` (el
  `message` del servidor, nunca el código pelado) + `parseToolList`
  (defaults `""` y `{"type":"object","properties":{}}`) +
  `parseCallResult` (join de bloques `text`, `[non-text content]`,
  `(no output)` — el `_acall`).
- Seam `ExchangeFn` (una línea request → una línea response) +
  `listToolsVia` (initialize → initialized → list; el `_connect_one`;
  el fallo propaga para que el bridge de 6b saltee con warning) +
  `callToolVia` (el `call`/`_acall`: nil → `not connected`, fallo →
  texto `MCP call <server>_<tool> failed`, nunca raise) +
  `toRegistryTools` (nombre model-safe, `[MCP:server]` + desc, el
  schema, y el `fn` despacha con el nombre ORIGINAL) +
  `startStdioExchange` (adaptador vivo `osproc` con env mergeado,
  jamás llamado en tests).
- Tests: `nim/tests/test_mcp.nim` nuevo, 31 (parse stdio/remoto/
  vacío/JSON-roto/sin-nombre, 5 de validación con mensajes exactos,
  3 de naming, 2 de hint, 3 de builders, 5 de parsers, 5 de
  exchange con respuestas grabadas, 2 de registry, 1 de
  aplazamiento). `nimble test` verde, 0 warnings.
- Surfaces: `nim/src/mcp.nim` (nuevo) + `nim/tests/test_mcp.nim`
  (nuevo). `waku.nim` intacto. Frontend intacto. Evals intactos.

## 6b — HTTP streamable + `waku mcp` CLI (HECHO, sin commits)
- POST `initialize` + `tools/list` + `tools/call` contra `url` con
  `Mcp-Session-Id`, `Authorization: Bearer` desde `authEnv` (tabla
  env, nunca el secreto en `mcp.json`), y el `authHint` de 6a ante
  401; el SSE-stream de respuesta se parsea si el servidor lo usa
  (`extractJsonResponse`: último `data:` no vacío, `[DONE]` salteado;
  el viejo HTTP+SSE queda sin soporte, como en Python).
- Seam `HttpPostFn` propio (`url/body/sessionId/bearer` →
  `status/body/sessionId`; fakes grabados en tests, nunca socket;
  `liveHttpPost` con `std/httpclient` jamás llamado en tests,
  patrón phase 3e) + bridge `connectAll` (un servidor malo no tumba
  al resto, retry una vez cuando aparece el token tras el primer
  fallo, `connectionDeadline` ×2 o `signInTimeout + 60` con oauth sin
  token, como `_deadline`). `connectError` levanta la puerta 6a:
  remoto válido → `""`.
- CLI `mcp` (`mcp_cli.py`): `list` (qué hay + quién eres),
  `login` (olvida el token y reconecta), `logout` (borra el fichero);
  identidad desde claims JWT sin verificar (`decodeClaims` +
  `mcpIdentity`, `nowUnix` por parámetro) + texto de expiración
  (`42m left` / `3h left` / `expired, refreshes on next use`);
  `home` por parámetro, ficheros reales solo bajo `tmp` en tests.
  `login` con `oauth` da error honesto que nombra 6c (sin
  DCR/PKCE/callback/storage todavía). `waku.nim` SOLO suma el
  dispatch `mcp` (`runMcpCmd`); el resto de stubs 4e queda intacto.
- Tests: `test_mcp.nim` +17 (bearer/session round-trip, SSE,
  401→hint vía bridge, call/nil, skip-con-warning, auth_env sin
  hint, retry tras sign-in, deadline ×2/margen, registry http con
  nombre original, claims/identidad/list/logout/login-6c/login-
  bridge) y `test_cli.nim` +4 (list vacío, logout, login
  unknown/oauth, shape sin stub). `nimble test` verde, 0 warnings.

## 6c — OAuth browser flow (HECHO, sin commits, cierra fase 6)
- SHA-256 vendored en stdlib puro (~60 líneas, FIPS 180-4, decisión
  abajo) + `pkceChallenge` S256 + `randomToken` (seam `RandIntFn`,
  `liveRandInt` con rejection sampling) + `base64urlEncode` /
  `formEncode` / `formDecode`.
- `FileTokenStorage` completo: `readTokenDoc` (ausente/corrupto/no-
  objeto → `{}`, nunca raise) + `writeTokenDoc` (mkdir, tmp, chmod
  0600 pre-rename) + `get/setStoredTokens` + `get/setStoredClientInfo`
  (merge, sin pisar la mitad hermana).
- Callback loopback `127.0.0.1:41765` (`callbackPort`/`callbackPath`/
  `redirectUri`, `signInTimeout` 300.0 compartido con el `deadline` de
  6b; `callbackPollAttempts` = 600): `parseCallbackTarget` puro
  (200/404, `error` verbatim) + `callbackError` + `callbackSuccessPage`
  + `waitCallbackLive` (`asynchttpserver`, jamás en tests).
- DCR + discovery + exchange sobre seams (`HttpPostFn`/`HttpGetFn`):
  `resourceMetadataUrl` (RFC 9728 path-insertion), `parseResourceMetadata`
  / `parseServerMetadata`, `dcrBody` (Waku/loopback/`none`),
  `authorizeUrl` (code + S256), `tokenExchangeBody`/`refreshBody`,
  `parseDcrResponse`/`parseTokenResponse` (sin `client_id`/`access_token`
  → `ValueError`).
- `oauthSignIn` (discover → reuse-or-DCR → browser → wait → state-check
  → exchange → store; nunca raise, triple con `timedOut` para el mensaje
  especial de timeout) + `OAuthFlowFn` / `oauthFlowWith` (el wiring de
  una línea que `runMcpCmd` pasará).
- Navegador por seam (`BrowserFn`; `openBrowserLive` imprime la URL
  siempre, como Python; headless → la URL viaja en el timeout).
- Bridge con token guardado: `connectAll`/`connectOneHttp`/
  `listToolsViaHttp` aceptan bearer guardado (`auth_env` manda);
  `storedAccessToken` (margen 60s, sin `exp` = válido) +
  `refreshAccessToken` (sin raise, conserva `refresh_token` viejo).
- `mcpLogin` oauth con flow inyectado: veredicto por fichero + identidad
  (paridad `sign_in`), rama timeout verbatim; sin flow → error honesto
  que nombra el seam, cero I/O (`nimble test` sigue offline).
- Tests: `test_mcp.nim` +28 (NIST ×2, RFC 7636, storage ×4, callback ×3,
  shapes ×5, flow ×7, bearer/refresh/login ×5, constantes). `nimble test`
  verde, 0 warnings (76 en test_mcp, 561 en suite, EXIT=0).
- Surfaces: `nim/src/mcp.nim` + `nim/tests/test_mcp.nim`. `waku.nim`
  intacto (follow-up de una línea abajo). Frontend intacto. Evals intactos.

## Decisiones
- Sin SDK y sin dependencias nuevas (regla 3): el wire MCP son tres
  métodos JSON-RPC estables; el SDK Python solo aporta framing y
  reintentos, ambos porteables a mano y pinnados por tests.
- `ExchangeFn` devuelve `string` para todo método: la notificación
  `initialized` no tiene respuesta y el fake devuelve `""` (el
  `discard` del medio lo documenta).
- Los ids JSON-RPC los lleva `listToolsVia`/`callToolVia` (1, 2, 3):
  un `mcp.json` no necesita multiplexar; el bridge concurrente es
  follow-up, no cambio silencioso (precedente: dashboard 8b
  single-thread).
- `waku.nim` intacto hasta que 6b traiga el bridge: el pin 4e sigue
  verde y el `mcp` del CLI sigue diciendo not-yet-implemented.
- 6b cablea SOLO `mcp` en `waku.nim` (`runMcpCmd`: list/login/logout;
  login oauth → error que nombra 6c): el resto de stubs 4e sigue
  intacto y `test_cli.nim` lo pinna (el shape erróneo de `mcp` da 1,
  ya no 0 de stub).
- SHA-256 vendored en stdlib puro (regla 3): `std/sha1` está deprecado
  (el gate es 0 warnings) y `checksums` sería dependencia nueva;
  `std/md5` no vale (PKCE S256 nombra SHA-256). Pinnado por vectores
  NIST + RFC 7636 apéndice B (precedente: FNV-1a propio en 8d).
- `runMcpCmd` (`waku.nim`) intacto en 6c: fuera de superficie, así que
  el login oauth del binario sigue en error honesto (ahora nombra el
  seam, ya no 6c). Follow-up de una línea: pasar
  `oauthFlowWith(liveHttpPost, liveHttpGet, openBrowserLive,
  waitCallbackLive, liveRandInt)` a `mcpLogin`.

## Divergencias con Python (motivo)
- Spec sin `url` ni `command` → frase con el nombre en vez del
  `KeyError` de `spec["command"]`: un typo en config no vale un
  traceback (precedente: `dashboardPort` 8a).
- `inputSchema` solo (sin alias `input_schema` 1.x): el wire siempre
  dice `inputSchema`; el alias era compat con pins viejos del SDK,
  irrelevante sin SDK.
- `connectError` remoto honesto en vez de conectar: 6a no abre
  sockets; el 501-honesto es patrón de fase 8, no invención.
  (6b levanta la puerta: remoto válido → `""`; el test 6a de
  aplazamiento pasa a assert de puerta abierta.)
- `connectionDeadline` se calcula pero no se espera: Python aguarda en
  un bridge asyncio (`fut.result(deadline)`); el port es síncrono,
  los fakes son instantáneos y el vivo lleva su propio timeout de
  30s. Misma cifra observable, sin espera inventada.
- `connectAll` valida upfront (`validateSpec`) en vez de ramificar
  por tipo de excepción (`ValueError` sin hint): mismos warnings
  observables, sin depender de que un fallo del servidor sea o no
  `ValueError`.
- `mcpLogin` no-oauth reporta el bridge (tools vs warnings): el
  chequeo Python por fichero-token es oauth-shaped y haría fallar
  siempre a key/stdio, que nunca escriben uno. OAuth reserva ese
  chequeo para 6c.
- `sanitizeServerName` ASCII (Python `isalnum` acepta Unicode): los
  nombres son claves de config.
- README de `nim/` sin actualizar (dice "MCP ... are not [ported]"):
  sigue siendo verdad a falta de 6b/6c; se actualiza al cerrar fase
  (regla 9, diferido con motivo, no olvido).
- `client_info` guardado incluye los endpoints descubiertos (el SDK los
  re-descubría por run): el refresh posterior no necesita GETs.
- El `state` mismatch falla cerrado explícito (el SDK lo validaba dentro).
- `mcpLogin` sin flow no toca red ni navegador (seam nil = rechazo):
  `nimble test` hace cero llamadas de red (garantía del `.nimble`).

## Cierre fase 6
- Gate: tools list/call contra respuestas grabadas con formas del demo
  (`word_count`, `memory.remember`) en 6a/6b/6c; `waku mcp`
  list/login/logout con paridad Python salvo el wiring de una línea.
- Pendiente (no 6c): el wiring `runMcpCmd` + `oauthFlowWith` (una línea,
  `waku.nim`, fuera de superficie 6c), el README de `nim/` (regla 9) y
  el bridge concurrente (follow-up declarado en 6a).

## Follow-up — cableado vivo del OAuth en el binario (HECHO, sin commits)
- `runMcpCmd` (`nim/src/waku.nim`) pasa
  `oauthFlowWith(liveHttpPost, liveHttpGet, openBrowserLive,
  waitCallbackLive, liveRandInt)` a `mcpLogin`: los cinco live fns
  existen con esos nombres exactos (cero renombres). El login oauth
  del binario ya no da el error honesto del seam nil; llega al
  browser flow real.
- Tests: `nim/tests/test_cli.nim` +1 (el constructor exacto
  `oauthFlowWith` sobre seams grabados firma y `mcpLogin` reporta la
  cuenta sin el error del seam; cero red). `nimble test` verde,
  0 warnings, 562 OK, EXIT=0.
- README de `nim/` (regla 9): MCP sale de "not ported", matizado a
  lo pendiente real (concurrencia del bridge).
- Estado: fase 6 cerrada salvo el bridge concurrente (sigue pendiente).
