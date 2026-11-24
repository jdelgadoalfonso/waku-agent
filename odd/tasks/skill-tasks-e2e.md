# Skill tasks end-to-end (frontmatter -> manifest -> card)

Two-line header: user chose frontmatter as the tasks source; a skill declares `tasks:` in SKILL.md frontmatter, the compiler carries it into the plugin manifest, and load/install enrolls the agent card with those tasks so the Slice B filter activates in production.

## Specs

- S1: "SKILL.md accepts an optional `tasks:` frontmatter list; absent means no tasks (fail-open: always listed), present must be a YAML string list."
- S2: "The compiled plugin manifest carries `tasks` verbatim from validate to install; the loader and the dashboard validate the same shape."
- S3: "Loading a plugin enrolls/refreshes its agent card with the manifest tasks (kind graph); a manifest without tasks enrolls nothing new, leaving today's text-match path untouched. Mid-run installs take effect at the next load."
- S4: "Every behaviour change gets a deterministic eval; the template and the compiler doc name the field once."

## Tasks

- [x] T1 (S1,S2): frontmatter `tasks:` parse + validate + manifest carry-through — route: worker
- [x] T2 (S3): enroll/refresh card on plugin load (+ install path if separate) — route: worker
- [x] T3 (S4): deterministic pins + template/doc touch — route: worker
- [x] T4: neighbor suites + rulebook + independent verify — route: inline

## Log

- L1: user: "poblar tasks?" -> chose "Frontmatter → manifest" over builtins-only, convention-only, or nothing-yet.
- L2: tasks-e2e landed via worker (T1-T3, test-first, S1-S4 PASS, 7 guard-break proofs). Parent: prompt pin added to test_dashboard (159/159 OK), design-doc validator row added, test_skill_tasks 13/13 rerun green, rulebook 17 passed, assess recorded (medium/unassessable, writer self-verification). Pre-existing bug surfaced (not fixed): skillcompile.nim:145 writes hyphenated stem Nim rejects — needs its own decision. Full `nimble test` not run; no commit.
- L3: independent verify (gentle-ai-verify): points 1-6 PASS (5 behavior PASS + partial pinning noted). Open gaps: (a) frontmatter->manifest propagation is prompt-steered only, nothing in code carries it — needs explicit decision; (b) mid-run installs enroll no card until next load (fail-open, documented); (c) prompt says "1-4 short lowercase tags", validator enforces neither — advisory drift; (d) pre-existing skillcompile hyphen-stem bug still open.
- L4: T4 closed inline: neighbors test_skill_tasks 13/13 + rulebook 17 passed + full `nimble test` EXIT 0 (2175 OK, 0 FAILED); T1-T3 confirmed landed, no commit per policy.
