# Nim port — phase 7: gateways (telegram/discord/whatsapp/voice)

## Goal
Port `waku/gateway/` (`telegram.py` 196, `discord.py` 280,
`whatsapp.py` 338, `voice.py` 360, `runner.py` 138, `supervisor.py` 118,
`cli.py`) to `nim/src/gateway.nim` + one module per gateway, in small
units that protect review. Constraints: no Telegram/Discord SDK exists
for Nim and rule 3 forbids new dependencies, so every wire is hand-rolled
stdlib (`httpclient` + `json`, precedent: MCP hand-rolled in phase 6, SSE
in phase 3); every side effect travels through an injected seam (`env`
as a `Table`, transports as procs); cero red, cero subprocess y cero
audio en tests (regla de fases previas: seams inyectados, tipos puros).
`nim/src/waku.nim` NO se toca en 7a: los stubs `telegram`/`discord`/
`whatsapp`/`voice` de phase 4e quedan (el cableado del dispatch llega
con la unidad que duena el live loop); cambiarlo rompería
`test_cli.nim`.

## 7a — desglose + runner/supervisor + telegram (HECHO, sin commits)
- Infra `nim/src/gateway.nim` (nuevo): `gatewayErrorReply`
  (`GATEWAY_ERROR_REPLY` verbatim) + `safeException` (redacción por
  sufijo `_API_KEY`/`_TOKEN`/`_SECRET`/`_PASSWORD`, valores >= 4 chars,
  longest-first, `no details`, corte en 500) + `RunnerState`
  (`newRunnerState`/`recordError`/`clearError`/`errorStatus`/
  `closeRunner`: la mitad portable de `GatewayAgentRunner`, sin
  executor ni agente — el port es single-thread, decisión abajo) +
  `runGatewayTurn` (`RespondFn`/`SendFn`/`LogFn`: `you ›`/`waku ›`,
  `(no reply)`, error reply, `reply delivery` y `error reply delivery`
  como en `run_gateway_turn`; cerrado → raise nombrando el source) +
  supervisor (`StarterFn`/`StopFn`/`StatusFn`, `GatewayReport`,
  `EnvSnapshot` con present-vs-absent, `newSupervisor`/
  `envFingerprint`/`isConfigured`/`snapshotEnv`/`restoreEnv`/
  `reconcile`/`supervisorStatus`/`supervisorShutdown`: stop-then-start
  ante cambio de fingerprint, `gateway failed to start` ante declive,
  rollback con restore del viejo + retorno del env deseado, `keys`
  vacío = todos los starters ordenados).
- Telegram `nim/src/telegram.nim` (nuevo): `parseAllowedIds`
  (`_allowed_ids`: split coma, trim, sin vacíos) + `posture` (verbatim
  ambas posturas) + `isTelegramAllowed`/`telegramRefusal`/`classifyTelegram`
  (el `handle` de `_build_app` sin el async) + Bot API por HTTP con
  `TelegramHttpFn` (`apiUrl`, `parseUpdates` con skip de no-texto y de
  comandos-por-entidad, `buildSendBody`, `sendTelegramText` con `ok`
  como booleano, `fetchTelegramUpdates` con offset+timeout,
  `nextTelegramOffset` sin rewind) + `liveTelegramHttp` (`httpclient`,
  POST con JSON o GET con payload vacío, timeout 45s para el long-poll
  de 30s; jamás llamado en tests).
- Tests: `nim/tests/test_gateway.nim` nuevo, 29 (3 redacción, 2 estado,
  5 turnos, 8 supervisor, 5 gate telegram, 6 wire telegram con
  payloads grabados). Un solo fichero para gateway+telegram: ambos son
  pequeños y comparten vocabulario turno/gate; se parte si 7b lo hace
  crecer (precedente: `test_mcp.nim` cubre todo `mcp.nim`).
- Surfaces: `nim/src/gateway.nim` + `nim/src/telegram.nim` +
  `nim/tests/test_gateway.nim` (nuevos). `waku.nim` intacto. Frontend
  intacto. Evals intactos. `nimble test` verde, 0 warnings, 591 OK
  (562 + 29), EXIT=0.

## 7b — discord + whatsapp (HECHO, sin commits)
- Discord `nim/src/discord.nim` (nuevo): `parseDiscordIds` (twin de
  `parseAllowedIds`, duplicado como Python duplica `_ids` por fichero)
  + `parseRequireMention` (solo `""`/`"0"` eximen) + `parseTurnCap`
  (`ValueError` como `int()`) + `shouldAnswer` (deny-by-default
  verbatim: `allowed_channels` vacío = ningún canal) + `stripMention`
  (ambas formas `<@id>`/`<@!id>`) + `DiscordBudget`/`newDiscordBudget`/
  `budgetAllow` (`now` requerido) + `describePosture` (4 líneas
  verbatim) + envío por seam REST (`discordMessageUrl`,
  `buildDiscordBody`, `sendDiscordText` con `true` en 2xx) +
  `liveDiscordPost` (`Authorization: Bot …`, jamás en tests) +
  `receiveDiscordEvent` (seam honesto: raise nombrando 7d) + const
  `discordEnvFields` (token primero, para el `isConfigured` de 7d).
  El receive por gateway WebSocket NO se portea: sin SDK, el socket
  vivo queda para 7d (o proceso externo).
- WhatsApp `nim/src/whatsapp.nim` (nuevo): `hmacSha256Hex` (pads RFC
  2104 sobre `sha256Digest` de `mcp.nim`, sin duplicar SHA-256;
  pinnado por vectores RFC 4231 casos 1+2 más tres casos cruzados con
  el `hmac` de Python) + `signaturesEqual` (port de
  `compare_digest`) + `whatsappSignature` (`sha256=` + hex) +
  `verifyWhatsappSignature` + `verifyWhatsapp` (200 con challenge /
  403 `forbidden` / 404) + `parseWhatsappMessages`
  (`entry/changes/value/messages`, skip sin texto) +
  `isWhatsappAllowed` (un teléfono) + `handleWhatsappPost` (404/403/
  400 y 200 rápido siempre con los mensajes allowlistados) + envío
  por seam Graph API (`graphMessageUrl` v21.0, `buildWhatsappBody`,
  `sendWhatsappText`) + `liveWhatsappPost` (Bearer, jamás en tests)
  + `serveWhatsappWebhook` (seam honesto 7d) + const
  `whatsappEnvFields`. El `ThreadingHTTPServer` vivo queda para 7d.
- Tests: `nim/tests/test_chat_gateways.nim` nuevo, 38 (discord 20:
  6 policy + 4 mention/budget + 6 posture/env + 4 wire; whatsapp 18:
  6 hmac + 4 verify/fields + 5 post + 3 wire). Fichero propio en vez
  de extender `test_gateway.nim`: ya cubría 3 concerns (29 tests) y
  dos gateways más lo llevaban past 60; discord+whatsapp forman una
  unidad coherente (policy chat + seams REST + HMAC webhook) y 7c/7d
  tendrán el suyo. TDD: RED observado con stubs (cayó además un JSON
  mal balanceado en un test propio) → GREEN → refactor.
- Divergencias 7b (motivo): `budgetAllow` exige `now` (Python
  defaultea a `time.time()`): determinismo; el vivo pasa `epochTime()`.
  `DiscordHttpFn`/`WhatsappHttpFn` devuelven status `int`, no body:
  el éxito es 2xx y el 429/throttling es outcome `false` (telegram
  devuelve body porque su contrato es el flag `ok`). REST Discord
  hand-rolled (`/api/v10`): el SDK lo esconde; el shape es la
  superficie documentada, como el Bot API en 7a. HMAC reutiliza
  `sha256Digest` (solo pads + hex locales: `sha256Hex` hashea
  strings, no bytes). `handleWhatsappPost` devuelve
  `(status, body, messages)`: el 200 rápido y los turnos 7d salen de
  una sola decisión pura.
- Surfaces: `nim/src/discord.nim` + `nim/src/whatsapp.nim` +
  `nim/tests/test_chat_gateways.nim` (nuevos). `waku.nim` intacto.
  Frontend intacto. Evals intactos. `nimble test` verde, 0 warnings,
  629 OK (591 + 38), EXIT=0.

## 7c — voice texto+comandos, STT/TTS como seams honestos (HECHO, sin commits)
- `nim/src/voice.nim` (nuevo, 614 líneas): `speakable` (`_speakable`
  con los ocho rangos de `_EMOJI`, marcas markdown, colapso `[ \t]{2,}`,
  `splitLines` con los once saltos de `str.splitlines` y `pyStrip` con
  el set de `str.strip`), `normalizeWake` (conserva kana/CJK, deja
  caer el resto), `similarityRatio` (puerto real del
  `difflib.SequenceMatcher` de Python: `find_longest_match` con las
  tres extensiones y recursión por bloques, POR RUNE), `matchesWake`
  (substring + sin espacios + ventana deslizante 0.7 por variantes
  separadas por coma), `handsFree` + `voiceConfig` (env como `Table`,
  nunca `os.environ`) + `wakeLanguage`, `parseMicThreshold`,
  `rms`, `recordCommand`/`waitForSpeech` (máquinas de estado sobre
  `SampleFn`), `captureUtterance`/`transcribe`/`speak` (los cuatro
  seams con error honesto cuando son `nil`), `pushToTalkStep`,
  `shouldTranscribe`/`scanWake`/`wakeStatus`/`wakeScanEvent` (la
  decisión del escáner de `wake_loop`), `voiceTurn` (un turno hablado
  con `RespondFn`/`TtsFn`/`LogFn` de `gateway.nim`) y las líneas de
  terminal verbatim (`banner`, `readyBanner`, `listeningLine`,
  `heardLine`, `followupLine`, `tooShortReply`, `noSpeechReply`,
  `byeLine`).
- Sin audio, sin red, sin subprocess en tests: el audio entra por
  `SampleFn`/`RecordFn` y sale por `SttFn`/`TtsFn`; `nil` raisea
  nombrando el seam y el motor que falta (`faster-whisper`,
  `kokoro`/`say`, `sounddevice`), patrón 501-honesto de fase 8 /
  `oauth` de 6b. `_best_say_voice` y el `Mouth.say` de macOS no se
  portan (subprocess en el hot path); `WAKU_TTS`/`WAKU_VOICE` ni se
  leen, porque serían un knob para un motor que no existe. `WAKU_VOICE`
  sí queda documentado aquí como no portado.
- Tests: `nim/tests/test_voice.nim` nuevo, 46 (speakable 6, wake word
  8, config/env/líneas 10, máquinas de comando 6, seams 6, decisiones
  6, turno hablado 4). Fichero propio (no extender
  `test_chat_gateways.nim`): aquel es la policy de los dos gateways de
  chat y 7b ya le reservó este hueco a 7c. TDD RED observado con un
  stub de firmas (37 de 40 en rojo) → GREEN → refactor.
- Verificación: `nimble test` verde, 0 warnings, 675 OK
  (629 + 46), EXIT=0. Además un differential contra el ground truth
  Python de `_speakable`/`matches_wake` sobre 56 casos (emoji,
  banderas regionales, markdown, NBSP, espacio ideográfico, separadores
  C0, U+2028/U+0085, kana, CJK, cirílico, acentos combinantes, ZWJ,
  tonos de piel, tabs, espacios dobles) da salida idéntica byte a
  byte; ese differential cazó el único bug real del unit (el strip de
  los C0) y ahora está pineado en el suite.
- Divergencias 7c (motivo): `similarityRatio` no porta `autojunk`
  (solo aplica a `b` de 200+ elementos y aquí `b` es una variante
  corta); `pyStrip` = `str.isspace()` (White_Space + U+001C-U+001F),
  no `unicode.strip`; `speakable` acumula en float64 (numpy
  acumula en float32) y un bloque vacío vale 0.0 en vez de NaN (NaN
  compara false, así que ambos quedan en silencio); el umbral de
  llamada es un parámetro y no `os.getenv`; `wakeLanguage` devuelve
  `""` donde Python devuelve `None`; `voiceTurn` deja PROPAGAR un turno
  fallido (`voice.py` no tiene try/except alrededor de
  `waku.respond`: es un comando en foreground, no un gateway
  supervisado, así que no hay error reply que mandar y el accounting
  de `runGatewayTurn` se queda donde Python lo tiene); `shouldTranscribe`
  es el gate `<` del escáner expuesto aparte porque `scanWake` recibe
  la transcripción ya hecha (el loop vivo transcribe solo si el gate
  pasa).

## 7d1 — live loops de telegram + whatsapp + voz (HECHO, d5bc35c,
1b60b02)
- Se parte 7d en dos unidades (decisión del review: el WebSocket de
  Discord a mano + `waku.nim` + dashboard era demasiado para una sola
  revisión). 7d1 = los tres loops vivos y los motores de voz; 7d2 =
  WebSocket de Discord, dispatch y hookup del supervisor.
- Telegram (nuevo en `telegram.nim`): `TelegramLive` (el
  `TelegramHandle` de Python: runner, offset, flags de conflicto y de
  stop), `telegramPoll` (un ciclo: `getUpdates` desde el offset,
  clasificar, `runGatewayTurn` por update, `nextTelegramOffset`),
  `telegramFault` + `telegramRun` (loop bloqueante), y
  `telegramStatus`/`telegramStop` + los tres adaptadores del
  supervisor (`telegramStarter`/`telegramStatusFn`/
  `telegramStopFn`). `timeoutSecs` es parámetro porque el dashboard
  acorta su long-poll (decisión: sin hilos, el tick va entre requests
  del navegador; ver Divergencias 7d1).
- `accountedRespond` NUEVO en `gateway.nim` (7a no lo tenía): es el
  `_respond` de `GatewayAgentRunner`, el que registra
  `message handling` en el runner que el dashboard lee. Sin él, un turno
  roto se veía en la terminal y no en el dashboard. Envuelve el
  `RespondFn` vivo; el puntero al runner es la única aritmética de
  punteros del unit (una closure no puede capturar un `var` parámetro).
- WhatsApp (nuevo en `whatsapp.nim`): `WhatsappRequest`/`WriteFn` +
  `serveWhatsappRequest` (la puerta: decide, responde 200 rápido, y
  DESPUÉS corre los turnos — el orden que mantiene vivo el webhook se
  pinea con dos seams que escriben en un log), `requestPath`/
  `parseQueryParam` (`parse_qs`), `whatsappRejected` (los rechazos que
  7b ya no devolvía), `senderLogLine` (el `you › [sender] …` de Python),
  `readWhatsappRequest`/`writeWhatsappResponse` (framing HTTP mínimo) y
  `serveWhatsapp` (bind + accept + `TakeConn` para que 7d2 lo
  multiplexe con el dashboard) más el handle
  (`whatsappStatus`/`whatsappStop` + adaptadores). El seam honesto
  `serveWhatsappWebhook` de 7b desaparece (con su test): 7d1 entrega lo
  que prometía.
- Voz: `voiceio.nim` NUEVO con los tres motores que este binario no
  puede llevar dentro (faster-whisper 74MB, kokoro 82M, sounddevice) y
  que llegan como EXTERNOS: `WAKU_MIC_COMMAND` (un grabador que escribe
  s16le crudo mono 16kHz en el ÚLTIMO argumento), `WAKU_STT_COMMAND`
  (lee el WAV del último argumento, imprime la transcripción) y
  `WAKU_TTS_COMMAND` (lee el texto en stdin). `decodePcm16` (con carry
  de medio ejemplo), `pcm16Bytes` (escala asimétrica, clip en ±1),
  `encodeWav`/`wavHeader` (pinnados byte a byte contra `wave` de
  Python) y el spool del micro (`externalMic`/`micRead`/`micPending`/
  `micDrain`/`micReadAll`/`needsMicRecycle`/`micClose`).
  El spool es un FICHERO y no una pipe a propósito: una pipe no se
  puede drenar sin bloquear, y `drain()` después de que habla Waku es
  lo que evita que el escáner despierte con la cola de su propia voz
  (el bug que el propio Python ya Suffrió). El spool se recicla entre
  tomas al pasar `spoolCapBytes` (32MB ≈ 17min), nunca a mitad de
  frase.
- Voz (7d1 en `voice.nim`): `VoiceRig` (un valor con los nueve seams
  del rig), `heartbeatLine` (el `
\x1b[2m…` de 72 columnas de Python),
  `wakeLoop` (ventanas de 2.5s con cola de 0.5s, ack, drain,
  `recordCommand`+`voiceTurn`+drain+followup, `waitForSpeech` para el
  seguimiento), `pushToTalk` (las dos `input()`, un grabador por toma,
  la escalera de `pushToTalkStep`, bye con `byeLine`),
  `voiceMain` (preflight honesto de los tres comandos + elegir modo +
  `byeLine` + exit code) e `installVoiceInterrupt` (Ctrl-C con
  `setControlCHook`, el patrón de `cli.nim`). `recordCommand` y
  `waitForSpeech` de 7c ganan un `stop` con default (aditivo: los
  pines de 7c siguen verdes) para que un Ctrl-C aborte una toma de 15s
  en el siguiente bloque.
- Reciclado del spool (añadido en el commit de gravação, tras
  encontrar el hueco en revisión): el `wakeLoop` pide un `recycle` una
  vez por ventana completa (un `stat`), y `voiceMain` lo cablea a un
  `openMic` que cierra el grabador y abre otro cuando el spool pasa
  `spoolCapBytes`; `micClose` borra el fichero, que es lo que hace que
  la siguiente toma de push-to-talk no herede los bytes de la anterior.
  Sin esto, una sesión siempre-lista crecía un fichero sin tope (32KB/s,
  y `/tmp` suele ser tmpfs). Tres pines: el recycle se pide una vez por
  ventana, un rig sin seam no lo pide, y `micClose` borra el spool.
- Tests: `tests/test_live_gateways.nim` NUEVO, 28 (telegram 16:
  offset/timeout en la URL, refusals, error de turno con error reply,
  `reply delivery`, offset que no retrocede, tabla de faults, retry con
  línea, conflicto una sola vez, token muerto, precedencia del status,
  stop entre polls y a mitad de poll, `telegramRun` que muere con el
  token, starter; whatsapp 12: `parse_qs`, verificación GET (éxito,
  token malo, challenge ausente, path ajeno, token redactado), paridad
  con la decisión de 7b, 200-antes-del-turno (orden pineado), firma
  sobre el body crudo, tamper, rechazo del remitente, turno fallido con
  error reply, envío fallido, status/stop/starter, líneas de arranque) +
  `tests/test_voiceio.nim` NUEVO, 21 (pcm16 con carry, clipping, WAV
  contra Python, argv de los tres motores, fallo de motor, spool
  pending/read/drain/timeout/muerto/close/reciclado, take alineado a
  bloque) + 10 en `tests/test_voice.nim` (heartbeat, ventana muda, near
  miss con traza, wake con doble drain y línea de followup, comando
  vacío, Ctrl-C, escalera de push-to-talk, motor sin cablear, boca sin
  cablear, boca cableada). TDD RED observado (símbolo inexistente en
  compilación) → GREEN.
- El differential de 7c re-ejecutado (follow-up que 7c dejó abierto):
  el artefacto nunca se commiteó, así que se reconstruyó el corpus
  (50 casos: emoji, banderas regionales, markdown, NBSP, espacio
  ideográfico, separadores C0, U+2028/U+0085, kana, CJK, cirílico,
  acentos combinantes, ZWJ, tonos de piel, tabs, espacios dobles,
  variantes de wake) contra el ground truth Python de `_speakable` y
  `matches_wake`: salida idéntica, 0 mismatches. El bug que cazó en 7c
  (el strip de los C0) sigue pineado en el suite.
- Surfaces: `src/telegram.nim` + `src/whatsapp.nim` + `src/voiceio.nim`
  (nuevo) + `src/voice.nim` + `src/gateway.nim` (un proc aditivo) +
  `tests/test_live_gateways.nim` (nuevo) + `tests/test_voiceio.nim`
  (nuevo) + `tests/test_voice.nim` + `tests/test_chat_gateways.nim` (el
  test del seam de 7b que 7d1 reemplaza). `waku.nim` intacto: el pin 4e
  sigue verde y `waku telegram|discord|whatsapp|voice` sigue siendo
  scaffolding hasta 7d2. Frontend intacto. Evals intactos.
  `nimble test` verde, 0 warnings, 736 OK (675 - 1 + 28 + 22 + 12),
  EXIT=0, sin ficheros temporales huérfanos en `/tmp`.

## 7d2 — WebSocket de Discord + dispatch + supervisor (SIGUIENTE)
- Discord: el receive del gateway WebSocket escrito a mano (RFC 6455:
  handshake, frames, masking, heartbeat, op 2/10 y `MESSAGE_CREATE`),
  detrás de la costura honesta `receiveDiscordEvent` de 7b, más el
  handle (`discordEnvFields` ya está, el supervisor lo necesita).
- `waku.nim` SOLO suma el dispatch `telegram`/`discord`/`whatsapp`/
  `voice` (precedente 6b: `runMcpCmd`; el resto de stubs 4e queda).
- Dashboard: el supervisor real (starters + `envFields` de los tres
  gateways, `reconcile` al arrancar, `shutdown` al salir, proveedor de
  status + reloader para `integrations.nim`), el tick del long-poll de
  telegram entre requests del navegador y el webhook de whatsapp
  multiplexado por `TakeConn` (o, si no cabe, `whatsapp` se queda con
  su propio comando y el dashboard solo lo reporta).
- Voz en 7d2: solo el dispatch (`waku voice` llama a `voiceMain` con
  el Waku real, `sessionId = "voice"`). Sin hooks del supervisor: en
  Python la voz es un comando en foreground, no un gateway supervisado
  (no hay fila de voz en las integraciones), así que no hay
  `voiceEnvFields` ni entrada en el `reconcile` del dashboard.
- `cli.py` no necesita unidad propia: `_memory_snapshot` y `_observer`
  ya viven en `cli.nim` (phase 4e los pinna); el REPL es `runRepl`.

## Decisiones
- Sin SDK y sin dependencias nuevas (regla 3): el Bot API de Telegram
  son dos endpoints JSON estables; el SDK Python solo aporta polling y
  framing, ambos porteables a mano y pinnados por tests.
- Un solo `TelegramHttpFn(url, payload)` para GET+POST: `getUpdates`
  viaja como GET con payload vacío, `sendMessage` como POST con JSON
  (el vivo decide por longitud; documentado en `liveTelegramHttp`).
- `waku.nim` intacto hasta que 7d traiga un live loop: el pin 4e sigue
  verde y los comandos gateway siguen diciendo not-yet-implemented.
- Fingerprint como join con `\0` sin SHA-256: solo se compara por
  igualdad, así que el hash no aporta nada y evita acoplar `gateway`
  con `mcp` por `sha256Hex` (7b sí lo usará para HMAC real).
- `record_health` fuera de `gateway.nim`: persiste en disco y el disco
  lo dueña `integrations.nim`; el supervisor devuelve `GatewayReport`
  y el caller mapea a `IntegrationStatus` + health store.
- `env` como `Table` en vez de `os.environ` (precedente
  integrations/mcp): sin mutación global, tests paralelizables.
- 7d1 sin hilos (decisión del review, coherente con 8b): el long-poll
  de telegram es una FUNCIÓN (`telegramPoll`) que 7d2 llama entre
  requests del navegador con un timeout corto, y el webhook de whatsapp
  se sirve con la costura `TakeConn` para que el mismo loop lo
  multiplexe. El coste, dicho de frente: un turno de gateway bloquea
  el dashboard mientras dura, que es la postura que 8b ya aceptó para
  los turnos de chat ("a streaming turn briefly queues the polls behind
  it"), y un `stop` del supervisor se ve en el borde del poll, no en
  mitad de una petición en vuelo.
- 7d1 parte 7d en dos unidades: el WebSocket de Discord escrito a mano
  (RFC 6455) es la pieza de riesgo grande y quiere su propia revisión,
  junto con `waku.nim` y el dashboard (los dos archivos con más pines
  del repo). `TakeConn` existe justo para que 7d2 no reescriba el loop
  del webhook.
- Los tres motores de voz son comandos externos opcionales, no
  dependencias ni extras: `WAKU_MIC_COMMAND` / `WAKU_STT_COMMAND` /
  `WAKU_TTS_COMMAND`. Es la traducción honesta de `[voice]` a un binario
  único (una dependencia opcional se convierte en una línea de entorno
  que la persona decide poner), y mantiene el hot path sin subprocess
  fuera del audio.
- El micro es un spool FICHERO y no una pipe: `drain()` tiene que ser
  exacto (Python lo necesitaba para que el escáner no escuchara la cola
  de la voz de Waku) y una pipe no se puede drenar sin bloquear; el
  precio es un fichero que crece, con tope de 32MB, reciclado entre
  ventanas y borrado al cerrar el grabador.
- Un `stop` no interrumpe un `accept` bloqueante (no hay hilo que lo
  interrumpa): el dashboard no lo paga porque `TakeConn` devuelve con
  timeout, que es donde se ve el `stop`; un `waku whatsapp` parado
  necesita un segundo Ctrl-C. Documentado en `serveWhatsapp`.

## Divergencias con Python (motivo)
- `errorStatus` es `""` en sano en vez de `None`: Nim no tiene string
  nil y `""` ya es el centinela sano del módulo.
- Runner cerrado y starters fallidos usan `CatchableError` en vez de
  `RuntimeError`: Nim no tiene `RuntimeError`; el mensaje
  (`<source> gateway runner is closed`, `gateway failed to start`)
  queda verbatim.
- Sin executor de un hilo ni afinidad SQLite: el port es síncrono
  single-thread (precedente: deadline MCP 6b sin espera); los turnos
  corren inline y 7d dueña el loop vivo.
- Comando telegram = entidad `bot_command` en offset 0, no texto con
  `/`: es lo que PTB filtra (`filters.COMMAND` mira entidades); un
  `/texto` sin entidad se responde igual que Python.
- `sendTelegramText` devuelve `ok:false` en vez de raise: un bloqueo o
  chat ido es outcome de delivery, no fallo de transporte (el fallo
  real propaga a `runGatewayTurn`, que lo registra como Python).
- `reconcile` ordena starters y reporta `unknown gateway` ante clave
  ajena: Python itera un set (orden no determinista) y haría
  `KeyError`; determinismo testeable sin cambiar policy.
- `supervisorStatus` devuelve `(present, report)` en vez de `None`:
  `None` polimórfico no existe en Nim; `present=false` es el mismo
  valor con tipo.

## Divergencias 7d1 (motivo)
- Un poll fallido se imprime (redactado) y se reintenta: PTB se
  tragaba los errores y solo hablaba del conflicto, así que un portátil
  que dejó de hablar con Telegram era indistinguible de un bot al que
  nadie escribe. `telegramFault` distingue los tres fallos por la línea
  de estado que `std/httpclient` reporta (409 → conflicto, 401/404 →
  token muerto y el poller para como el `InvalidToken` de Python, resto
  → reintento).
- El refusal de un desconocido que no se puede entregar se registra
  como `reply delivery` en vez de desaparecer en el log de PTB.
- `telegramPoll` cuenta los turnos INTENTADOS (uno que explota igual
  llegó al modelo y se pagó); el refusal no es turno.
- WhatsApp responde al turno fallido con el `gatewayErrorReply`
  compartido: el handler de Python no tiene try/except, la excepción
  escapa a `do_POST` y el remitente no ve nada — un servidor de un
  hilo no puede permitirse que un turno malo se lleve el gateway
  entero, y la pareja merece la misma respuesta que en Telegram.
- El verify token de Meta se imprime como `***` (o `none`), nunca el
  valor: esa línea cae en una terminal y en una traza, y el token es
  una credencial.
- El fallo de envío de WhatsApp imprime la línea de Python
  (`(whatsapp) send failed: …`) Y sube al accounting del runner: Python
  solo imprimía, y un webhook que deja de entregar parecería sano.
- `whatsappStarter` nombra los cuatro credenciales que faltan cuando
  el token sí está puesto (Python devuelve `None` en silencio y el
  supervisor acaba diciendo `gateway failed to start`): el caso
  accionable es exactamente ese.
- La línea de arranque del webhook se compone con el host/puerto real
  (`listeningLine`); con los valores por defecto es la misma cadena de
  Python.
- Los ears del escáner y los del comando son el MISMO motor: Python
  corre `tiny` para escanear y el modelo grande tras la wake word, y un
  comando configurado no puede ser dos modelos. La ventana de 2.5s es
  la que hace barato el escaneo.
- Voz: el scout y la respuesta hablan con el mismo `TtsFn`; sin
  `WAKU_TTS_COMMAND` la boca es un no-op y se avisa UNA vez (Python
  imprimía la línea de "no engine" en cada respuesta).
- `recordCommand`/`waitForSpeech` ganan `stop` (default nil) para que
  el Ctrl-C aborte una toma a mitad; el resto de 7c intacto.
- Los tres `*_Starter` re-arman el handle (runner nuevo, offset a cero,
  flags limpios) pero NO bombean: sin hilo, quien arranca es quien
  llama a `telegramPoll`/`serveWhatsapp`. Está escrito en el doc del
  starter porque un handle arrancado que nadie bombea se reportaría
  sano sin hacer nada, y esa es la forma que este puerto no debe
  enviar.
- `micReadAll` alinea la toma a bloques de 100ms rellenando de ceros el
  final: una toma que no alinearía deja un ejemplo suelto en cada
  herramienta de audio.

## Cierre fase 7 (cuando 7b+7c+7d1+7d2 aterricen)
- Gate: turnos contra `RespondFn`/`SendFn` grabados, allowlists y
  posturas verbatim, `ok:false` sin raise, rollback del supervisor con
  env deseado restaurado; `waku telegram|discord|whatsapp|voice` con
  paridad Python salvo loops vivos documentados.
- Pendiente tras 7b+7c+7d1: 7d2 (WebSocket de Discord + dispatch en
  `waku.nim` + hookup del supervisor en el dashboard).
