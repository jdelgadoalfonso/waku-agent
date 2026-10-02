# Nim TLS vivo condicional (flag `wakuTls`, default sin TLS)

Objetivo: encender TLS en los paths vivos del port solo bajo
`-d:wakuTls`, sin cambiar el build por defecto (regla 3 intacta:
cero paquetes nuevos; `wrappers/openssl.nim` es stdlib y libssl es
del sistema). Rama `feature/nim-phase0-skeleton`, base HEAD
`5d945a6`.

## Hechos verificados por el padre (no por el mapeo)

- Sin `-d:ssl`, todo `https://` falla en limpio con
  `HttpRequestError("SSL support is not available...")` ANTES de
  mandar bytes (`httpclient.nim:newConnection`): NO hay fuga de
  credenciales en claro. El port es offline de facto.
- Con `-d:ssl` compila (stdlib + libssl del sistema, OpenSSL 3.6.5
  acá) y un GET real a `https://example.com/` da 200 con
  verificación de peer. Refutado: "`-d:ssl` ni compila".
- `std/ssl` (módulo alto nivel) NO existe en este árbol; sí
  `wrappers/openssl.nim` + `net.SslContext` bajo `-d:ssl`. No hay
  `std/sha1`: el accept-key del handshake WS no se puede
  recomputar (divergencia ya documentada en 7d2-1).

## Alcance (opción elegida por el usuario)

- Un helper TLS único (p.ej. en `http.nim`): contexto SSL bajo
  `when defined(wakuTls)`, nil/refusal sin el flag.
- `liveDiscordWire`: dial `wss://gateway.discord.gg` real bajo el
  flag (socket TLS + upgrade RFC 6455 a mano sobre el pump de
  7d2-1); refusal honesto intacto sin el flag (pines 7d2-1/7d2-2
  siguen verdes por defecto).
- Contextos SSL en los paths vivos REST/LLM que hoy crean cliente
  sin contexto (`http.nim`, `telegram.nim`, `whatsapp.nim`,
  `discord.nim` REST, `mcp.nim`, llamadas en `waku.nim` y
  `dashboard.nim` según corresponda).
- Plumbing: `waku.nimble`/`Makefile`/`nim.yml` para pasar el flag
  (`make nim-build-tls` o equivalente + job CI con openssl-dev);
  build por defecto idéntico a hoy.
- Pines nuevos `test_tls.nim`: con flag (contexto existe, dial
  parsea handshake contra fixture grabada, offline) y sin flag
  (refusals intactos). Probar handshake real contra red: NO
  (offline por diseño; el probe del padre ya demostró el 200).

## No-objetivos

- Verificación del accept-key (sin SHA-1: documentar). Cambiar el
  build por defecto. Paquete `ssl` de nimble (innecesario).
  `waku dashboard` servido con TLS. Push/PR/merge.

## Tareas

- [x] T1 TLS condicional en paths vivos + plumbing + pines (route: delegated mur23ng4-r-selo; el primer intento murió sin escribir). Checks OBSERVED: parent spot `test_discord_ws` 60 default / 59 flagged, rulebook 17. Worker: default 899 OK, flagged test_tls 17 OK, buildTls con loader OpenSSL, default sin libssl. Cabos del padre: pin refusal con `when not defined(wakuTls)`, `nim/waku_tls` en .gitignore + binario borrado, README sin "phase 7e" y Landed al día. Hallazgo sin arreglar (otra unidad): 4 seams REST tragan el refusal (try/except en finally) y responden 0 — pineado.
- [x] T2 Verificación cierre (route: delegated verify mur3g41g-s-o6ca). Veredicto ACCEPT. Checks OBSERVED: default 900 OK / 0 FAIL (39 suites), flagged test_tls 17 OK, rulebook 17 passed, cross-count exacto (911 declarados = 900 + 11 flagged-only), default sin referencias libssl (strings), requires idénticos (regla 3). Bloqueadores: ninguno.

## Criterios de aceptación

- Default: byte a byte el comportamiento de hoy (refusals + pines
  viejos verdes).
- Con flag: contextos existen, dial WS arma el handshake, REST
  puede hablar HTTPS (pines offline con fixtures, más el 200 del
  probe como evidencia manual, no pin).
- Regla 3 intacta: ningún paquete nuevo en `waku.nimble`.

## Progreso

- 2026-10-02: documento creado tras mapeo + probes de compilación
  y red del padre. HEAD `5d945a6`. T1 DONE (worker mur23ng4-r-selo
  + cabos del padre: pin con when, gitignore, README). T2 DONE
  (verify ACCEPT: 900 default + 17 flagged, rulebook 17, regla 3
  intacta). PENDIENTE autorización: 3 commits (código,
  plumbing/docs, task doc). Push/PR/merge: decisiones tuyas.

## Commits

- `f742294` TLS vivo bajo el switch (7 src + test_tls.nim nuevo +
  when-gate en test_discord_ws).
- `9e8dc9e` Plumbing del switch (nimble + Makefile + nim.yml +
  README + .gitignore).
- (este archivo) Registro del landing de TLS.
- Assess: limitación conocida con untracked residentes (7
  resultados idénticos hoy); vía cubierta por verify ACCEPT.

## Evidencia de verificación

- Probe padre: `nim c -d:ssl` OK + `GET https://example.com/`
  → 200 (binario en /tmp, fuera del repo).
- (pendiente resto)

## Siguiente paso

- Lanzar T1 con `gentle-ai-worker`.
