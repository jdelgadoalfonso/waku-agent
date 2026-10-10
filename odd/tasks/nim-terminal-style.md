# Nim terminal_style CLI prototype

Optional styled CLI output with `terminal_style`, vendored under
`nim/vendor/terminal_style`. The default build stays plain text and
dependency-free; styling exists only under `-d:wakuStyle`. No
`illwill`, no full-screen TUI.

## Specs

### S1 — terminal_style only
- Use `terminal_style` for colors, attributes, ANSI parsing and
  cell-aware layout. Do not add `illwill` or any full-screen TUI
  library.
- `terminal_style` is vendored, not in `requires`; `nimble build`
  and `nimble test` stay offline and dependency-free.

### S2 — default output unchanged
- Without `-d:wakuStyle`, every styled surface prints the same
  plain text it prints today.
- With `-d:wakuStyle`, `dim`, `bold`, `yellow`, `green`, `cyan`
  and `brightCyan` wrap their text in the corresponding SGR.
- `NO_COLOR`, `TERM=dumb` or a non-terminal stdout disables
  styling in the styled build; content must remain identical.
- `terminalRenderer(..., assumeTerminal = true)` bypasses only
  the tty check, for tests that pin the escape bytes.

### S3 — renderer seam
- `src/style.nim` exposes a `Renderer` with `dim`, `bold`,
  `yellow`, `green`, `cyan`, `brightCyan`, `boldGreen`, `panel`,
  `prompt`, `wrap`, `displayWidth` and `strip`.
- `plainRenderer()` returns identity styles and an undecorated
  panel; it is the default and the test seam.
- `terminalRenderer(width, assumeTerminal = false)` uses vendored
  `terminal_style`; it exists only in a `-d:wakuStyle` build.

### S4 — CLI surfaces (v1)
- `src/cli.nim` routes the banner, live observer lines, the
  `/memory` panel, the input prompt, the reply label and the bye
  line through the renderer.
- `memorySnapshot()` keeps returning plain text; the REPL panels
  it, so the pure function and its existing pins stay unchanged.
- `runRepl(w, renderer = plainRenderer())` takes the renderer as a
  parameter; tests inject the plain renderer.

### S5 — panel shape
- Panel border is `┌─┐│└┘`, cyan, with the title on the top
  border: `┌ Memory snapshot ───┐`.
- Content is measured with `displayWidth`, wrapped with
  `wrapAnsi`, padded with `padAnsi`; wide characters and combining
  marks must not misalign the border.
- A plain renderer returns the body without a border.

### S6 — tests
- `tests/test_style.nim` pins plain identity, styled escape
  sequences, `strip`/`displayWidth`, `wrap` and the panel shape.
- Tests run offline; styled pins assert through `stripAnsi` and
  exact SGR bytes, not terminal behavior.

### S7 — docs and licensing
- `nim/README.md` gains the optional-styling section, the
  `nimble buildStyle` command and the vendor notice.
- `nim/vendor/terminal_style` keeps upstream `LICENSE` (MIT) and
  the source modules; `nim/vendor/THIRD_PARTY_NOTICES.md` lists it.
- No emojis in any new output.

## Tasks

- T1 — this document (done)
- T2 — vendor `terminal_style` + notice (done: `nim/vendor/terminal_style`, `nim/vendor/THIRD_PARTY_NOTICES.md`)
- T3 — `src/style.nim` renderer (done; plain and styled checks pass)
- T4 — `src/cli.nim` wiring (done; `runRepl` takes a `Renderer`)
- T5 — `tests/test_style.nim` (done; plain and styled pins pass)
- T6 — README + notices (done; optional-styling section and vendor note)
- T7 — `nimble test` + `nimble buildStyle` + `nimble testStyle` (done)

## Log

- L1 (user): "mire en este repo https://github.com/harrier77/nim_llamaserver_chatbot ... tiene la opción TUI y está hecho en Nim" → investigation found `illwill` is a full-screen TUI library, not a `rich` parity layer.
- L2 (user): chose "illwill TUI" over terminal_style, then: "vamos a quitar illwill, solo usaremos terminal_style" → scope reverts to the terminal_style line-output prototype; no full-screen TUI, no `illwill` dependency.
- L3: implementation landed: vendored `terminal_style`, `src/style.nim`, `src/cli.nim` renderer routing, `src/waku.nim` build-switch selection, `tests/test_style.nim`, `waku.nimble` `buildStyle`/`testStyle`, README and `.gitignore`.
- L4: test pins corrected to upstream composition: `green(bold(x))` is `\e[32m\e[1mx\e[0m\e[32m\e[0m`, and `wrapAnsi("one two three", 8)` is `@["one two", "three"]`.
- L5: the untracked local `nim/config.nims` (`danger`, `lto`, mimalloc) makes `tests/test_app.nim` SIGSEGV at HEAD as well as with these changes; the suite passes with that file moved aside. It is a pre-existing local-config issue, not a regression from this unit.
- L6 (RDD): review lineage `review-cdba658daafbc17f` admitted one CRITICAL finding, `R3-nimble-offline-requires`, because the working tree still carried the pre-existing `mimalloc_nim` git `requires` line. The correction removed that line, restoring the offline, dependency-free contract. Targeted validation approved the corrected candidate; the approved review was acknowledged and burned. `nimble build`, `nimble test`, `nimble buildStyle`, and `nimble testStyle` pass with the local `nim/config.nims` moved aside.
- L7 (user): `mimalloc_nim` is mandatory after all — it optimizes dynamic memory usage. The `requires` line is back by user decision, so L6's offline, dependency-free contract no longer holds. Activation stays manual at compile time (`import mimalloc/config` plus `-d:useMimalloc`); docs now state the mandatory dependency instead of claiming stdlib-plus-`db_connector`.
