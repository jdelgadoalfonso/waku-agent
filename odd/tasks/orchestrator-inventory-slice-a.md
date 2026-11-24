# Orchestrator inventory Slice A (read-only)

Two-line header: approved proposal `docs/orchestrator-inventory-design.md`; implements manifest + unified describe + dashboard list only, no selection change.

## Specs

- S1: "Slice A covers only a common manifest and a unified describe() that the dashboard shows. Selection, prompts, and subagent creation stay unchanged."
- S2: "Each entry carries name, kind, tasks, whenToUse, cost, fallback, source, installed; a card without a row, or a row without a card, is refused by name."
- S3: "The dashboard lists what the loop can run: workflowNames() plus installed plugin:<name> entries with whenToUse, cost, installed; Memory tab keeps propose/approve as the only write path."
- S4: "Every behaviour change gets a deterministic eval; prove each test can fail; frontend verified in a browser per data/static/README.md."

## Tasks

- [x] T1 (S1,S2): manifest type + constructors from builtinWorkflows + loadPluginGraphs + installedSkill — route: inline
- [x] T2 (S2,S4): closed-set + drift pins (fixture: 1 builtin + 1 installed plugin + 1 uncompiled skill) — route: inline
- [x] T3 (S3,S4): collect() inventory in /api/data + graphSection list + browser verify — route: inline
- [x] T4: focused tests + nim suite + docs index check — route: inline

## Log

- L1: user request verbatim: "lo que estaba dandole vueltas es a como enlazar las graphs y los plugins con el orquestador para que este último separa de que graphs y plugins dispone para realizar ciertas acciones. Es cierto que los plugins vienen de la consolidación de los skills, no se si por ahí es más natural hacerle saber al orquestador de que graphs dispone para crear a los subagentes según el prompt del usuario"
- L2: user chose option 1 (orchestrator filters by prompt tags from announced inventory), then "primero solo A", then "lo vamos a redactar ya", "si, revísalo", "lo apruebo", "vamos a implementar ya".
- L3: implementation notes: `graphSection` already served plugin graphs via `enabledWorkflows` (explorer claim of hardcode was stale); refusal rule implemented as report-only `inventoryGaps()`; JSON field is `when_to_use` to match card convention.
- L4: T4 closed inline: test_inventory 6/6 + graphSection pin green + rulebook 17 passed + full `nimble test` EXIT 0 (2175 OK); browser verify remains manual per data/static/README.md; no commit per policy.
