# Gmail como capacidad de Waku (fila en Connections + tres tools core)

Tier Proposal (conventions §2): la propuesta vive en
`docs/gmail-integration-design.md` y las decisiones D1-D4 de ese documento son
la aprobación. Nada de código antes de ese sí.

## Specs

- **S1** (petición del usuario, verbatim):
  > ok, ahora me gustaría añadir otra nueva funcionalidad, en connections => productivity me gustaría añadir Google gmail

- **S2** (alcance elegido, verbatim de la opción):
  > Leer y enviar correo
  >
  > gmail_search / gmail_read / gmail_send
  >
  > + guardas de envío (borrador primero, como el outbox de send_message)
  > + scopes de escritura = riesgo mayor
  > + superficie de revisión más amplia

- **S3** (implementaciones, verbatim de la opción): `Python + paridad Nim`.

- **S4** (grupo de la fila): el grupo no se llama "productivity"; el string
  existente es `"Calendar & Productivity"` (`waku/integrations.py:182`), y la
  fila `gmail` se ubica junto a `google_calendar`, `apple_calendar` y
  `apple_tools`. Su `extra` es `gcal`, que ya provee `google-api-python-client`
  y `google-auth` (`pyproject.toml:59-61`); sin dependencia nueva.

- **S5** (D1, envío): `gmail_send` escribe un borrador en `~/.waku/outbox/` y
  responde "Nothing was sent — review it there", igual que `send_message`; el
  envío real por la API ocurre solo con `WAKU_GMAIL_SEND=true`.

- **S6** (D2, credenciales): token propio `~/.waku/gmail-token.json` con los
  scopes `gmail.readonly` y `gmail.send`, con su propio consentimiento por el
  loopback existente. No se toca `google-token.json` ni el scope del calendario.

- **S7** (opt-in): las tres tools se registran solo si `WAKU_GMAIL` está activo
  (`Settings.gmail`), siguiendo el patrón de `WAKU_GOOGLE_CALENDAR` y
  `WAKU_APPLE_TOOLS`. Con el flag apagado no hay tool en el prompt ni fallo
  posible. Con el flag encendido y sin token usable, cada llamada devuelve una
  línea que nombra `waku connect google`; nunca inventa un resultado vacío.

- **S8** (D3, paridad Nim): la paridad es la que ya existe para Google Calendar
  en el port — fila en `nim/src/integrations.nim` más el scope de Gmail en
  `nim/src/connect.nim`. No se crea `nim/src/gmail.nim`; la asimetría se declara
  en `docs/status.md`.

- **S9** (D4, hosted): el allowlist de `hosted/core/policy.py` no se toca, así
  que una fila Gmail se rechaza en hosted. Ninguna tool añade ruta, así que
  `test_route_contract.py` no cambia.

## Tasks

- **T1** — Fila y configuración, sin tools. S4, S7, S9. Inline. Commit 1 =
  `a3f7cf2`. `waku/integrations.py` (fila), `waku/config.py` (`WAKU_GMAIL*`),
  `.env.example` regenerado, `nim/src/integrations.nim` (fila) y su pin en
  `nim/tests/test_integrations.nim`, `waku/ops/static/logos/connections/gmail.svg`.
- **T2** — Lectura: `gmail_search` + `gmail_read`, scope `gmail.readonly`.
  S4-S7. Inline (el writer delegado se abortó y dejó la suite RED; ver L4).
  Commit 2 = `f5e0c9d`. `waku/tools/gmail.py`, registro en
  `waku/tools/__init__.py`, `evals/deterministic/test_gmail.py`.
- **T3** — Envío con guarda: `gmail_send`, borrador por defecto y
  `WAKU_GMAIL_SEND`. S5. Inline. Commit 3 = `9b2db15` (unidad propia por ser
  riesgo alto: correo saliente real), más `cc82288` (un borrador no pisa a otro)
  y `9ab2492` (topes de 25 hits y 8000 caracteres, ver L5).
- **T4** — Consentimiento: scope de Gmail en el connect de ambas
  implementaciones. S6, S8. Inline. Commit 4 = `f6e598c`.
  `waku/tools/gmail.py` (`connect`), `waku/connect.py`, `nim/src/connect.nim`.
- **T5** — Docs que el cambio vuelve falsos: `docs/status.md`,
  `docs/architecture.md`, `docs/integrations.md`, `docs/gmail-integration-design.md`
  (estado y fila enviada). S8. Inline. Commit 5 = este commit.

## Log

- **L1** (petición original, verbatim):
  > ok, ahora me gustaría añadir otra nueva funcionalidad, en connections => productivity me gustaría añadir Google gmail

- **L2** (alcance y destino, verbatim de las opciones elegidas):
  > Leer y enviar correo / Python + paridad Nim

- **L3** (cuestionario de las cuatro decisiones cancelado por el usuario): se
  toman los defaults del proposal — borrador por defecto, token propio, paridad
  Nim de fila + sign-in, hosted intacto — y quedan escritos como D1-D4 en
  `docs/gmail-integration-design.md` para que el usuario los confirme o los
  cambie antes de que empiece T1.
- **L4** (T2 delegado y abortado): el writer de `gentle-ai-worker` alcanzó a
  dejar la suite RED completa de T2 (`evals/deterministic/test_gmail.py`, +280
  líneas) y la corrida se abortó antes de escribir `waku/tools/gmail.py`. T2 se
  terminó inline sobre esos tests: RED observado quitando `gmail.py`
  (`Interrupted: 1 error during collection`), GREEN 14/14. Único cambio sobre lo
  heredado: el fake capturaba solo el último `list`, así que el pin del tope
  comparaba contra la llamada equivocada.
- **L5** (decisiones de implementación, sin cambiar specs): los topes que el
  proposal prometía no estaban en el primer código (`MAX_LIMIT` 25 y cuerpo
  truncado a 8000 caracteres) y se alinearon con `9ab2492`; la fila se queda con
  dos campos BOOL y sin probe, como la fila del calendario que tiene al lado, y
  ambas reducciones quedan escritas en `docs/gmail-integration-design.md`.
- **L6** (evidencia de T3-T4): verificación independiente del commit `9b2db15`
  (items de riesgo 1 y 2: efecto externo irreversible y scope `gmail.send`):
  PASS en los seis puntos, con el único defecto real ya previsto — sin T4 el
  envío real no era alcanzable — y un solapamiento de nombres de borrador, que
  quedó arreglado en `cc82288`. `nimble test` corta en `test_tls` (falla también
  en el commit base, no es de esta feature); las suites que tocan los módulos
  cambiados pasan: test_connect 26, test_integrations 70, test_cli 28,
  test_dashboard 133, test_key_locations 14, test_supervisor_hookup 39.
  Deterministas: 3335 pasan, 7 fallan y esos 7 ya fallaban en `c657414`
  (5 de `test_pinned_models.py`, `test_static_assets.py` por
  `notion.svg`/`obsidian.svg`, y `test_turn_evals.py`).
