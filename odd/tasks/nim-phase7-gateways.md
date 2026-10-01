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

## 7b — discord + whatsapp (PENDIENTE)
- Discord (`discord.py`): `should_answer` tal cual (deny-by-default,
  `allowed_channels` vacío = ningún canal), `_strip_mention`
  (`<@id>`/`<@!id>`), `TurnBudget` (techo/hora con `now` por
  parámetro), `describe_posture` (4 líneas verbatim). Envío por seam
  REST (`POST /channels/{id}/messages` con `Authorization: Bot …`);
  el receive por gateway WebSocket NO se portea: sin SDK, el socket
  vivo queda para 7d (o proceso externo); los tests pinnarán policy +
  shapes REST con fakes.
- WhatsApp (`whatsapp.py`): verificación GET (`hub.mode`/
  `hub.verify_token`/`hub.challenge`), firma POST `X-Hub-Signature-256`
  (HMAC-SHA256: reutilizar `sha256Hex` de `mcp.nim` + pads
  inner/outer, nuevo `hmacSha256Hex` puro pinnado por vector RFC),
  parse del payload (`entry/changes/value/messages`, `from`/`text`,
  allowlist de teléfono, 200 rápido siempre), envío por seam contra
  Graph API (`/{phone_number_id}/messages`). El `ThreadingHTTPServer`
  vivo queda para 7d.

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
- Pendiente tras 7a: 7b (discord+whatsapp), 7c (voice con seams
  honestos), 7d (loops vivos + dispatch + hookup dashboard).
