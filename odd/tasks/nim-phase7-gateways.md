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

## 7c — voice texto+comandos, STT/TTS como seams honestos (PENDIENTE)
- Puro y testeable (`voice.py`): `_speakable` (strip emoji + marcas
  markdown + colapso de espacios), `matches_wake` (norm que conserva
  kana/CJK, substring + ventana deslizante 0.7, variantes por coma),
  `_mic_threshold` (`WAKU_MIC_THRESHOLD` por parámetro),
  `record_command`/`wait_for_speech` como máquinas de estado sobre
  `SampleFn` inyectado (sin `sounddevice`).
- Estrategia audio (decisión explícita): faster-whisper (red neuronal
  Whisper, ~74MB de modelo descargado en el primer run) y kokoro
  (neural 82M, `KPipeline` + `sounddevice`) NO se portan al binario —
  romperían binario único, stdlib-only y offline. Quedan como seams
  `SttFn`/`TtsFn`/`RecordFn`: el binario usará motor externo o dirá en
  texto qué motor falta (patrón 501-honesto de fase 8 / `oauth` de 6b).
  `_best_say_voice` y `Mouth.say` (subprocess `say` macOS) tampoco se
  portan: subprocess en el hot path de voz no pertenece al binario.

## 7d — live loops + dispatch (POSIBLE, según tamaño de 7b/7c)
- Loops vivos: long-poll telegram (offset + timeout, usa
  `fetchTelegramUpdates`/`nextTelegramOffset`/`classifyTelegram` de
  7a), receive discord, servidor webhook whatsapp, mic loop voice;
  handles con `stop`/`status` + `start_in_background` de cada gateway.
- `waku.nim` SOLO suma el dispatch `telegram`/`discord`/`whatsapp`/
  `voice` (precedente 6b: `runMcpCmd`; el resto de stubs 4e queda) +
  hookup del supervisor en el dashboard (proveedor de status +
  reloader, como `dashboard.py` con `INTEGRATIONS` gateway).
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

## Cierre fase 7 (cuando 7b+7c+7d aterricen)
- Gate: turnos contra `RespondFn`/`SendFn` grabados, allowlists y
  posturas verbatim, `ok:false` sin raise, rollback del supervisor con
  env deseado restaurado; `waku telegram|discord|whatsapp|voice` con
  paridad Python salvo loops vivos documentados.
- Pendiente tras 7b: 7c (voice con seams honestos), 7d (loops vivos
  + dispatch + hookup dashboard).
