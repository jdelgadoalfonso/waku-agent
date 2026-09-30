# Nim port — phase 5a: skill distribution

## Goal
Port `waku/memory/procedural/installer.py` (47 líneas) + `exporter.py` (108 líneas) a Nim: `skill install` y `skill export` con paridad Python y tests 100% offline.

## Decisions
- `nim/src/skills.nim` nuevo con fetch inyectado (`FetchFn = proc(url: string): string`); la impl real (stdlib httpclient GET, timeout 15s, no-2xx → `HttpRequestError` como urllib's HTTPError) vive con el dispatch en `waku.nim`, así skills.nim queda puro y testeable sin red.
- `installSkill` reusa `memory_admin.validSkillText` (mismo gate del loader y de create_skill; estricto: descripción vacía rechazada) — no duplica el regex; el split de frontmatter es string ops (`frontmatterOf`, equivalente al regex DOTALL de `_parse_text` para los casos de frontmatter real).
- Nombre instalado: slug minúsculas del frontmatter (`Weekly Review` → `weekly-review`, transformación de `createSkill`); el mensaje repite el slug. Python usa el nombre verbatim del frontmatter — divergencia deliberada, documentada en el header de skills.nim.
- Escritura vía `_incoming` igual que Python: tmp `home/skills/_incoming/SKILL.md`, luego move a `home/skills/<slug>/SKILL.md`; en inválido se borra el tmp y se lanza el mismo texto que el `SystemExit` de Python; el staging dir vacío se limpia (Python: `tmp.parent.rmdir()`).
- `exportSkills(targets, home, base, force)` resuelve los bundled internamente vía `bundledSkillDirs()` (cwd-walk estilo `findProvidersToml`: `skills`, `../skills`, `../../skills` + `getAppDir()/skills`; Python resuelve desde la ubicación del paquete). Los tests fijan cwd a un root temp con try/finally para determinismo offline.
- Líneas de export con los mismos textos y columnas que Python (`copied`/`unchanged`/`kept yours ... (it differs; --force replaces it)`); comparación de archivos por set relpath→bytes saltando `__pycache__` y `.DS_Store` (mismos ignore patterns que el copytree).
- Errores de `skill export` (target `memory`, unknown/empty, flags no reconocidos) → stderr + exit 1. Python imprime los arg-errors a stdout y los fallos I/O como traceback — divergencia deliberada (exit codes iguales).
- Dispatch en `waku.nim`: `skill install <url>` y `skill export [flags]` reales antes del stub honesto; `skill` solo o `skill install` sin url → usage + exit 1 (como Python; ya no cae en el stub de fases).
- `parseExportArgs` parsea `--to` (default claude, soporta espacio y `=`), `--project`, `--force`; flags desconocidos lanzan como argparse.

## Surfaces (allowed edit surfaces)
- `nim/src/skills.nim` (nuevo)
- `nim/src/waku.nim` (solo dispatch skill install/export)
- `nim/tests/test_skills.nim` (nuevo)
- `nim/README.md` (solo sección ported/not-ported de skills)
- `odd/tasks/nim-phase5a-skill-distrib.md` (este doc)
- `odd/tasks/nim-port.md` (bookkeeping al cerrar)

## Gates
- TDD: RED observado (`Error: cannot open file: ../src/skills` con la suite previa verde), GREEN con skills.nim mínimo, suite completa verde tras refactor.
- `nimble test`: 204 OK, 0 FAILED, 0 warnings (Nim 2.3.1, warnings on por defecto, hints off en nimble).
- Sin red en tests (fetch stub inyectado; export con cwd fijado a root temp). Sin `.waku/`, sin secrets, sin push/PR.

## Commits
- Install (rawSkillUrl, installSkill con fetch seam, 9 tests): ba1a14b
- Export (listDistribSkills, exportSkills, bundledSkillDirs, parseExportArgs, 10 tests): df659c6
- Dispatch (waku.nim skill install/export + README): ec28531
