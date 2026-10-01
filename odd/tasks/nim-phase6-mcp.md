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

## 6b — HTTP streamable + `waku mcp` CLI (siguiente)
- POST `initialize` + `tools/list` + `tools/call` contra `url` con
  `Mcp-Session-Id`, `Authorization: Bearer` desde `authEnv` (tabla
  env, nunca el secreto en `mcp.json`), y el `authHint` de 6a ante
  401; el SSE-stream de respuesta se parsea si el servidor lo usa
  (el viejo HTTP+SSE queda sin soporte, como en Python).
- Seam `HttpPostFn` propio (localhost stub en tests, patrón phase
  3e) + bridge `connectAll` (un servidor malo no tumba al resto,
  retry tras primer sign-in, `deadline` ×2 como Python).
- CLI `mcp` (`mcp_cli.py`): `list` (qué hay + quién eres), `login`
  (olvida el token y reconecta), `logout` (borra el fichero);
  identidad desde claims JWT sin verificar (es tu propia
  credencial descrita de vuelta, no un token en quien confiar) +
  texto de expiración (`42m left` / `3h left` / `expired, refreshes
  on next use`); `home` por parámetro, ficheros reales solo bajo
  `tmp` en tests.

## 6c — OAuth browser flow (última)
- DCR + PKCE + callback loopback `127.0.0.1:41765` (`std/net`,
  `SIGN_IN_TIMEOUT = 300.0` compartido con el `deadline` de 6b) +
  `FileTokenStorage` (un JSON por servidor bajo `mcp-auth/`,
  `0600`, write-then-rename, corrupto = ausente, nunca fatal) +
  `_sanitise` para el nombre de fichero.
- PKCE S256 necesita SHA-256 y `std/sha1` está deprecado (= warning
  prohibido): SHA-256 a mano (~200 líneas, sin dependencia nueva,
  documentado aquí por regla 3) o `checksums` como extra opt-in —
  decisión al abrir 6c, no antes. Abrir navegador vía seam
  (headless/SSH imprime la URL, como Python).

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

## Divergencias con Python (motivo)
- Spec sin `url` ni `command` → frase con el nombre en vez del
  `KeyError` de `spec["command"]`: un typo en config no vale un
  traceback (precedente: `dashboardPort` 8a).
- `inputSchema` solo (sin alias `input_schema` 1.x): el wire siempre
  dice `inputSchema`; el alias era compat con pins viejos del SDK,
  irrelevante sin SDK.
- `connectError` remoto honesto en vez de conectar: 6a no abre
  sockets; el 501-honesto es patrón de fase 8, no invención.
- README de `nim/` sin actualizar (dice "MCP ... are not [ported]"):
  sigue siendo verdad a falta de 6b/6c; se actualiza al cerrar fase
  (regla 9, diferido con motivo, no olvido).
