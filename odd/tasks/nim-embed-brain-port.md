# Nim port sync: embed one-row toolbar (4b69b32) + Used-from-memory prose (9a62ace)

Port to `nim/` what `origin/main` landed after the merge-base (`975f35d`),
plus the one older behavior gap the port never covered. Ground truth:
commit `4b69b32` (#326) and commit `9a62ace` (#310) on origin/main.
`turn_evals` (`b0f2cc1`, `ba2dfd0`) is already ported (nim-turn-evals T1-T9);
`hosted` (`809f71b`) is out of scope (EL-2.0, the port ships no hosted);
release infra (`ccd7aa8`, `975f35d`, `db2684a`) and the version bump
(`57ae307`) are out of scope (workflows/docs; the port's version is
deliberately `0.0.1`, pinned by `test_version.nim`).

## Specs

### S1 — Embedded chat toolbar is one row (4b69b32, static only)
- `embed.html`: the toolbar holds New chat, History, the model chip and a
  `"..."` (`#moremenu`, `toggleMoreMenu(event)`); `stats` (`#teletoggle`) and
  `Dashboard` (`#opendash`) are gone from the toolbar.
- `dock.js`: `toggleMoreMenu(ev)` opens the `"..."` menu with "Show how it
  answered" (sub on/off, runs `closeMenu();toggleTele()`) and "Open full
  dashboard" (sub "new tab", runs `closeMenu();openDashboard()`), width
  `min(300px, 92vw)`; each item closes the menu first.
- `style.css`: `body.embed .sesshead{flex-wrap:nowrap}`, buttons
  `flex:0 0 auto`, the chip `flex:0 1 auto` (the only part that shrinks),
  and under 400px buttons give back side padding so the row fits at 360px.
- The port serves these files verbatim (compile-time embed of
  `waku/ops/static/`): no `nim/src/` change, the merge carries them and the
  rebuild picks them up. `nim/tests/test_embed.nim` pins serving, not
  toolbar content, so no pin changes.

### S2 — Used from memory reads as prose, reports as title + summary (9a62ace)
- `_title(body)`: a report's `# ` line, when the body still has it.
- `_first_summary_line(body)`: the first `- `/`* ` bullet under a report's
  `## Summary`, when the body still has that section.
- `_prose(text)`: `text` without fenced code, comments (the report marker
  among them) and JSON fragments, on one line (`_FENCE`, `_LONE_FENCE`,
  `_COMMENT`, `_JSON_PAIR`, `_JSON_DEBRIS`, then spacing fixes).
- `_text(entry)`: a report's first Summary line (title shown beside it); a
  fact's prose. Clipped to `TEXT_CHARS`.
- `read_first` with `get`: the whole report body replaces the search
  snippet — `digests[id] = digest(body)`, `title = _title(body) or title`,
  `text = _clip(_first_summary_line(body)) or text`.
- `render.js` `usedLabel`: a report reads as title + first Summary line, a
  fact as its prose (static, arrives with the file, no port).
- Port adapts to both entry shapes the port reads (`jsonEntries` for Waku
  Memory entries, `brainEntries` text rows for Engram): the shared
  `entryText` gains the report branch, and `readFirst` refreshes title/text
  from the whole body it already fetches for the digest (one `get` per
  report, never two).

## Tasks

- T1 — S1: merge `origin/main` (static + Python eval only), rebuild, baseline green.
- T2 — S2 src: `nim/src/brain.nim` (`firstSummaryLine`, `proseOf`, report-aware `entryText`, `readFirst` title/text refresh, one `get` per report) + doc comments the change makes false.
- T3 — S2 pins: `nim/tests/test_brain.nim` (port of `test_used_from_memory.py`: report title+summary not Sources, unread report shows no JSON, fact loses fences/JSON but keeps `<<match>>`, prompt reads the same clean text) + update the stale marker pin.
- T4 — Full `nimble test` + `nimble build` green, zero warnings.

## Log

- L1 (user): "tenemos cambios nuevos en la rama origin/main que debemos portar a Nim" → scope decided: embed + brain prose (9a62ace); turn-evals already ported, hosted/release out of scope.
- L2: `975f35d..origin/main` is exactly `4b69b32` (5 files, static + Python eval); worktree still serves the old toolbar (`#teletoggle`, no `#moremenu`).
- L3 (cierre, 2026-10-12): merge `origin/main` en `4443f75` (limpio, solo los 5 archivos; `nim/` sin conflictos). T2+T3 test-first en `brain.nim`: `reportTitle`, `firstSummaryLine`, `proseOf` (fences, comentarios, pares/debris JSON, mismos regexes que Python), `entryText` con rama de reporte, `readReport` (un solo `get` por reporte) y refresh de título/texto en `readFirst` desde el cuerpo entero. Tres lecciones: (1) en Nim `r"..."` no admite `\"` — los dos patrones con comillas van en `"""..."""` (backslashes literales, comillas peladas OK); (2) el `get` exige id entero (`parseGetId`), así que los pines usan ids numéricos aunque el shape sea Waku; (3) `nim/tests/factstore_fakes` se regenera en cada corrida (deriva pre-existente, L6 de nim-turn-evals) — restaurado a HEAD. Evidencia: RED con 5 fallos, GREEN `test_brain` 27 OK / 0 FAILED / 0 warnings, full `nimble test` 71 suites / 1476 OK / EXIT 0, `nimble build` OK. Sin commits (no pedidos). Work units: código+pines en `b8c380c`, este doc en el commit docs que sigue.
