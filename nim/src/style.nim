## Optional styled CLI output — terminal_style prototype.
##
## The default build stays plain text and dependency-free:
## `plainRenderer()` is the default everywhere. A `-d:wakuStyle`
## build compiles the vendored `terminal_style` under
## `nim/vendor/terminal_style` and turns the same surfaces
## into ANSI styling. There is no `illwill` and no full-screen
## TUI in this unit.
##
## `Renderer` is a value object on purpose: every surface that
## prints takes it as a parameter, so tests inject the plain
## renderer and the styled build never mutates global state.

import std/math
import std/strutils
import std/unicode

when defined(wakuStyle):
  import std/os
  import std/terminal
  import terminal_style

const
  defaultRendererWidth* = 80
    ## Fallback width when the caller has no terminal size.
  minRendererWidth* = 20
    ## A narrower panel would hide more content than it shows.

type
  Renderer* = object
    ## One output style: plain or ANSI, plus a target width.
    styled*: bool
    width*: int

proc plainRenderer*(): Renderer =
  ## The default renderer: identity styles, undecorated panel.
  Renderer(styled: false, width: defaultRendererWidth)

proc terminalRenderer*(width = defaultRendererWidth,
                       assumeTerminal = false): Renderer =
  ## The optional renderer. In a default build it degrades to
  ## plain output; `NO_COLOR`, `TERM=dumb` and a non-terminal
  ## stdout do the same in a styled build. `assumeTerminal`
  ## bypasses only the tty check, so tests can pin the escapes.
  var enabled = false
  when defined(wakuStyle):
    enabled = not (existsEnv("NO_COLOR") or getEnv("TERM") == "dumb") and
      (assumeTerminal or isatty(stdout))
  Renderer(styled: enabled, width: max(minRendererWidth, width))

proc dim*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.dim(text)
    else:
      text

proc bold*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.bold(text)
    else:
      text

proc yellow*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.yellow(text)
    else:
      text

proc green*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.green(text)
    else:
      text

proc cyan*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.cyan(text)
    else:
      text

proc brightCyan*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.brightCyan(text)
    else:
      text

proc boldGreen*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.green(terminal_style.bold(text))
    else:
      text

proc prompt*(r: Renderer, text: string): string =
  ## The input prompt: bold cyan, like Python's `[bold cyan]`.
  r.cyan(r.bold(text))

proc displayWidth*(r: Renderer, text: string): int =
  if not r.styled:
    text.runeLen
  else:
    when defined(wakuStyle):
      terminal_style.displayWidth(text)
    else:
      text.runeLen

proc strip*(r: Renderer, text: string): string =
  if not r.styled:
    text
  else:
    when defined(wakuStyle):
      terminal_style.stripAnsi(text)
    else:
      text

proc plainWrap(text: string, width: int): seq[string] =
  ## The plain renderer's word wrap. It collapses runs of
  ## spaces, which is fine: plain output is not wrapped at all
  ## unless a caller asks for it.
  if text.len == 0:
    return @[""]
  var lines: seq[string] = @[]
  var current = ""
  for word in text.split(' '):
    if current.len == 0:
      current = word
    elif current.len + 1 + word.len <= width:
      current.add(" ")
      current.add(word)
    else:
      lines.add(current)
      current = word
  if current.len > 0:
    lines.add(current)
  if lines.len == 0:
    lines.add("")
  result = lines

proc wrap*(r: Renderer, text: string, width: int): seq[string] =
  ## Wrap to display cells. Styled output keeps its SGR state
  ## across lines; plain output falls back to word wrap.
  let w = max(1, width)
  if not r.styled:
    plainWrap(text, w)
  else:
    when defined(wakuStyle):
      terminal_style.wrapAnsi(text, w)
    else:
      plainWrap(text, w)

proc panel*(r: Renderer, title, body: string): string =
  ## A `rich`-shaped panel: `┌─┐│└┘`, cyan border, title on
  ## the top border. The plain renderer returns the body as it
  ## is, which is what the CLI prints today.
  if not r.styled:
    return body
  when defined(wakuStyle):
    let width = max(minRendererWidth, r.width)
    let lines = body.splitLines()
    var contentWidth = 0
    for line in lines:
      contentWidth = max(contentWidth, terminal_style.displayWidth(line))
    var titleText = if title.len > 0: " " & title & " " else: ""
    contentWidth = max(contentWidth, terminal_style.displayWidth(titleText))
    let inner = min(contentWidth, max(1, width - 4))
    if inner <= 0:
      return body
    if terminal_style.displayWidth(titleText) > inner:
      titleText = terminal_style.sliceAnsi(titleText, 0, inner)
    let borderFill = max(0, inner + 2 - terminal_style.displayWidth(titleText))
    var rendered: seq[string] = @[]
    rendered.add terminal_style.cyan("┌" & titleText & "─".repeat(borderFill) & "┐")
    for line in lines:
      for wrapped in terminal_style.wrapAnsi(line, inner):
        let padded = terminal_style.padAnsi(wrapped, inner)
        rendered.add terminal_style.cyan("│") & " " & padded & " " & terminal_style.cyan("│")
    rendered.add terminal_style.cyan("└" & "─".repeat(inner + 2) & "┘")
    rendered.join("\n")
  else:
    body
