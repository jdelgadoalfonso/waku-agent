# Frontend + CLI per-turn graph select

Authorized change. The browser chat and the CLI join the per-source,
per-turn graph selector the three chat gateways already use. No new
bools, no engine change: reuse `graphSelectorFor` + `resolveGatewayGraph`
with two new source names.

## Specs

- **S1 — Browser chat re-resolves per turn.** `liveChatStreamFn` re-reads
  the selector with source `"dashboard"` after `ensureWaku` and before
  `respond`, mirroring the `gatewayAgents` per-turn pattern. `WAKU_GRAPH_DASHBOARD`
  wins, fallback `WAKU_GRAPH_WORKFLOWS`. Vocabulary is the gateway one:
  empty/`loop`/`off`/… → loop, `triage` (and legacy `1`/`true`/`yes`/`on`) →
  triage, `gather` → injected gather turn, `plugin:<name>` → that plugin's
  graph (nil when not loaded → loop), unknown → loop. Any failure fails
  open to the loop, like every other source.
- **S2 — CLI re-resolves per turn.** `runRepl` re-reads the selector with
  source `"cli"` before each `respond`, same helpers and vocabulary, env
  `WAKU_GRAPH_CLI` with the same fallback. `buildCliApp` keeps its current
  startup value as the initial seam; the per-turn step overwrites it.
- **S3 — One env-table rule.** Both paths read the same live table the
  gateways read (`envOf()` process env overlaid with the dashboard's saved
  `d.env`, saved values winning), so a Connections save and an exported
  variable behave identically in the browser and in Telegram. No new bool
  parsing: `WAKU_GRAPH_WORKFLOWS` keeps its two jobs (bool door at startup,
  string fallback in the selector).
- **S4 — Testeado.** `test_gateway_graph_select` gains `dashboard`/`cli`
  source cases (selector precedence + vocabulary, incl. `plugin:` miss →
  nil); a dashboard test pins that the live browser path re-resolves between
  two turns (change env, second turn follows it); the `respond` gate keeps
  passing with a seam that changes between turns. No test touches a tty loop.

## Tasks

| ID | Tarea | Spec | R |
|---|---|---|---|
| T1 | Re-resolve in `liveChatStreamFn` (source `dashboard`) + helper for the live table | S1, S3 | P |
| T2 | Re-resolve in `runRepl` (source `cli`) via the same helpers | S2, S3 | P |
| T3 | Selector cases `dashboard`/`cli` + live-path pins + full suite green | S4 | P |

## Decisions

- **Source names `dashboard` / `cli`.** They match the strings both paths
  already pass to `respond` (`dashboard.nim:3041`, `cli.nim:118`), so
  `graphSelectorFor` derives `WAKU_GRAPH_DASHBOARD` / `WAKU_GRAPH_CLI`
  with no new mapping table.
- **No UI rows, no `integrations.toml` entries.** Dashboard/CLI are not
  external connections; their selectors are env-only in this step. A
  Connections card for them is a separate UI decision.
- **Startup values stay.** `ensureWaku` and `buildCliApp` keep assigning
  the triage door; the per-turn step overwrites the seam, so a failure in
  the selector still leaves the last good value, and a nil resolve means
  loop via the existing `respond` gate.

## Log

- **L1** (usuario, verbatim): "si, vamos a igualar el frontend y el CLI"
- **L2** (implementación): T1+T2 en `dashboard.nim` (+82/-22: `WakuBox` movido sobre `DashboardDeps` + campo `box`, `liveProcessEnv` + `reselectGraphTurn` con fail-open a nil, `envOf` en `liveChatStreamFn`/`liveChatFn`, rebind en `serveDashboardCmd`), `cli.nim` (hook `graphReselect` en `runRepl`), `waku.nim` (`runChat` pasa el hook con `WAKU_GRAPH_CLI`). Desviación del plan: `reselectGraphTurn` captura `addr w` porque Nim rechaza capturar un parámetro `var` en un closure (codegen, no `nim check`); documentado en el comentario. T3: 2 casos en `test_gateway_graph_select` (7 OK), 1 pin de rebind en `test_app` (42 OK), `test_dashboard` 137 OK, 0 FAILED en las tres. Sin commit.
