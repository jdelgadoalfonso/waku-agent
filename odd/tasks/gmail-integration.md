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

- **T1** — Fila y configuración, sin tools. S4, S7, S9. Inline. Commit 1.
  `waku/integrations.py` (fila + probe), `waku/config.py` (`WAKU_GMAIL*`),
  `.env.example` regenerado, `nim/src/integrations.nim` (fila).
- **T2** — Lectura: `gmail_search` + `gmail_read`, scope `gmail.readonly`.
  S4-S7. Inline. Commit 2. `waku/tools/gmail.py`, registro en
  `waku/tools/__init__.py`, `evals/deterministic/test_gmail.py`.
- **T3** — Envío con guarda: `gmail_send`, borrador por defecto y
  `WAKU_GMAIL_SEND`. S5. Inline. Commit 3 (unidad propia por ser riesgo alto:
  correo saliente real).
- **T4** — Consentimiento: scope de Gmail en el connect de ambas
  implementaciones. S6, S8. Inline. Commit 4.
- **T5** — Docs que el cambio vuelve falsos: `docs/status.md`,
  `docs/architecture.md`, `docs/integrations.md`. S8. Inline. Commit 5.

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
