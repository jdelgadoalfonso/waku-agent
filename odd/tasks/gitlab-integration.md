# GitLab integration (propio, self-hosted)

## Header
Propia integración GitLab en Productividad para instancia self-hosted (otro servidor), read-only como GitHub, solo `nim/` (`waku/` congelado).

## Specs
- S1: Fila `[gitlab]` en `data/integrations.toml`, grupo `Calendar & Productivity`, con `GITLAB_URL` (default `https://gitlab.com`) + `GITLAB_TOKEN` (secret, required). `halves = ["nim"]` primero.
- S2: Tool read-only `gitlab_*` en `nim/src/gitlab.nim`: allowlist cerrada (`mr list/view/diff`, `issue list/view`), valida `owner/name` o ID numérico, normaliza `GITLAB_URL` → `.../api/v4`, header `Private-Token`. Sin shell-escape, timeout 20s, truncado 8000 chars.
- S3: Registro en `nim/src/registry.nim` gatingado por `Settings` (`gitlabTool` + `gitlabUrl`/`gitlabToken`), orden tras `github`, sin prompt cuando off.
- S4: `Settings` en `nim/src/config.nim`: `GITLAB_URL`, `GITLAB_TOKEN`, `WAKU_GITLAB_TOOL`, `WAKU_GITLAB_PROJECT`. Env-driven, defaults seguros.
- S5: `BEHAVIOUR` en `nim/src/integrations.nim` para clave `gitlab`: `enabled/probe/normalize`. `probe` = `GET $base/user`. Sin token = notConfigured.
- S6: Logo `data/static/logos/gitlab.svg` + docs `docs/integrations.md` + eval determinista `nim/tests/test_gitlab.nim` offline con runner scripteado. `make nim-test` verde.

## Tasks
- T1 (S1,S6): fila TOML + logo + docs (route: worker)
- T2 (S2,S3,S4): tool + registry + settings (route: worker)
- T3 (S5,S6): behaviour + eval + verify build (route: worker)
- T4: Log L1 original + decisiones (route: inline)

## Log
- L1: usuario original verbatim: "ok, ¿como puedo añadir otro elemento en productividad para conectar el agente de waku a un gitlab?"
- L2: usuario: "me gusta que este en propio, lo que pasa es que el gitlab está desplegado en otro servidor"
- L3: usuario: "hagamoslo así, adelante" + "ok" — autorizado read-only propio self-hosted, solo nim/.
- Decisión 2026-11-20: halves=["nim"] primero por AGENTS.md frozen; GitHub (`gh` CLI) no sirve para self-hosted → API directa `/api/v4` con `Private-Token`.
