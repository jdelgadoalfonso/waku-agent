## Style renderer tests: the plain default every build gets, and
## the optional `-d:wakuStyle` escapes. Plain pins run in
## `nimble test`; styled pins run in `nimble testStyle`, which
## compiles this same file with `-d:wakuStyle` and the vendored
## terminal_style on the search path. Styled pins pass
## `assumeTerminal = true` because a test run's stdout is often
## a pipe. Offline only: no network, no home directory.

import std/json
import std/unittest

import ../src/cli
import ../src/style

when defined(wakuStyle):
  import std/os
  import std/strutils
  import std/terminal

suite "style plain renderer":
  test "plain renderer is identity":
    let r = plainRenderer()
    assert not r.styled
    assert r.width == 80
    assert r.dim("x") == "x"
    assert r.bold("x") == "x"
    assert r.yellow("x") == "x"
    assert r.green("x") == "x"
    assert r.cyan("x") == "x"
    assert r.brightCyan("x") == "x"
    assert r.boldGreen("x") == "x"
    assert r.prompt("you › ") == "you › "

  test "plain renderer measures runes and strips nothing":
    let r = plainRenderer()
    assert r.displayWidth("Nim 界") == 5
    assert r.strip("\e[36mred\e[0m") == "\e[36mred\e[0m"

  test "plain wrap splits words":
    assert plainRenderer().wrap("one two three", 7) ==
      @["one two", "three"]

  test "plain panel returns the body":
    assert plainRenderer().panel("Memory snapshot", "body") == "body"

  test "observer lines keep their plain words":
    let gate = %*{"decision": "allow", "reason": "ok"}
    assert observerLine(plainRenderer(), "gate", gate) ==
      "  gate · allow — ok"
    let consolidated = %*{"new_facts": 3}
    assert observerLine(plainRenderer(), "consolidation", consolidated) ==
      "  memory · consolidated 3 fact(s) from recent chats"
    assert observerLine(plainRenderer(), "unknown", gate) == ""

when defined(wakuStyle):
  suite "style terminal renderer":
    test "terminalRenderer styles when color is allowed":
      let savedTerm = (getEnv("TERM"), existsEnv("TERM"))
      let savedColor = (getEnv("NO_COLOR"), existsEnv("NO_COLOR"))
      delEnv("NO_COLOR")
      putEnv("TERM", "xterm-256color")
      let r = terminalRenderer(40, assumeTerminal = true)
      assert r.width == 40
      assert r.dim("x") == "\e[2mx\e[0m"
      assert r.bold("x") == "\e[1mx\e[0m"
      assert r.yellow("x") == "\e[33mx\e[0m"
      assert r.green("x") == "\e[32mx\e[0m"
      assert r.cyan("x") == "\e[36mx\e[0m"
      assert r.brightCyan("x") == "\e[96mx\e[0m"
      assert r.boldGreen("x") == "\e[32m\e[1mx\e[0m\e[32m\e[0m"
      assert r.prompt("you › ") == "\e[36m\e[1myou › \e[0m\e[36m\e[0m"
      if savedTerm[1]:
        putEnv("TERM", savedTerm[0])
      else:
        delEnv("TERM")
      if savedColor[1]:
        putEnv("NO_COLOR", savedColor[0])
      else:
        delEnv("NO_COLOR")

    test "a non-terminal stdout keeps the renderer plain":
      if isatty(stdout):
        skip()
      else:
        let savedTerm = (getEnv("TERM"), existsEnv("TERM"))
        let savedColor = (getEnv("NO_COLOR"), existsEnv("NO_COLOR"))
        delEnv("NO_COLOR")
        putEnv("TERM", "xterm-256color")
        assert not terminalRenderer(40).styled
        if savedTerm[1]:
          putEnv("TERM", savedTerm[0])
        else:
          delEnv("TERM")
        if savedColor[1]:
          putEnv("NO_COLOR", savedColor[0])
        else:
          delEnv("NO_COLOR")

    test "terminalRenderer clamps a too-narrow width":
      assert terminalRenderer(5, assumeTerminal = true).width == 20

    test "NO_COLOR keeps the renderer plain":
      let savedTerm = (getEnv("TERM"), existsEnv("TERM"))
      let savedColor = (getEnv("NO_COLOR"), existsEnv("NO_COLOR"))
      putEnv("TERM", "xterm-256color")
      putEnv("NO_COLOR", "1")
      let r = terminalRenderer(40, assumeTerminal = true)
      assert not r.styled
      assert r.cyan("x") == "x"
      assert r.panel("Memory snapshot", "body") == "body"
      if savedTerm[1]:
        putEnv("TERM", savedTerm[0])
      else:
        delEnv("TERM")
      if savedColor[1]:
        putEnv("NO_COLOR", savedColor[0])
      else:
        delEnv("NO_COLOR")

    test "TERM=dumb keeps the renderer plain":
      let savedTerm = (getEnv("TERM"), existsEnv("TERM"))
      let savedColor = (getEnv("NO_COLOR"), existsEnv("NO_COLOR"))
      delEnv("NO_COLOR")
      putEnv("TERM", "dumb")
      assert not terminalRenderer(40, assumeTerminal = true).styled
      if savedTerm[1]:
        putEnv("TERM", savedTerm[0])
      else:
        delEnv("TERM")
      if savedColor[1]:
        putEnv("NO_COLOR", savedColor[0])
      else:
        delEnv("NO_COLOR")

    test "strip and displayWidth ignore SGR controls":
      let r = terminalRenderer(40, assumeTerminal = true)
      assert r.strip(r.cyan("red")) == "red"
      assert r.displayWidth("Nim 界") == 6

    test "wrap splits to display cells":
      let r = terminalRenderer(40, assumeTerminal = true)
      assert r.wrap("one two three", 8) == @["one two", "three"]

    test "wrap keeps styling across lines":
      let r = terminalRenderer(40, assumeTerminal = true)
      let lines = r.wrap(r.cyan("one two three"), 8)
      assert lines.len == 2
      assert r.strip(lines[0]) == "one two"
      assert r.strip(lines[1]) == "three"
      assert lines[0].startsWith("\e[36m")
      assert lines[1].startsWith("\e[36m")

    test "panel shape":
      let r = terminalRenderer(40, assumeTerminal = true)
      let p = r.panel("Memory snapshot", "Semantic facts (0)")
      assert p.contains("\e[36m┌")
      assert r.strip(p).splitLines() == @[
        "┌ Memory snapshot " & "─".repeat(3) & "┐",
        "│ Semantic facts (0) │",
        "└" & "─".repeat(20) & "┘",
      ]

    test "panel keeps wide characters aligned":
      let r = terminalRenderer(40, assumeTerminal = true)
      let lines = r.strip(r.panel("Memory snapshot", "Nim 界")).splitLines()
      assert lines.len == 3
      assert lines[1].startsWith("│ Nim 界")
      assert lines[1].endsWith("│")
      for line in lines:
        assert r.displayWidth(line) == 21

    test "panel clamps a long title to the width":
      let r = terminalRenderer(20, assumeTerminal = true)
      let lines = r.strip(r.panel("A very long title", "body")).splitLines()
      assert lines.len == 3
      for line in lines:
        assert r.displayWidth(line) == 20

    test "empty title draws a border with no label":
      let r = terminalRenderer(40, assumeTerminal = true)
      let lines = r.strip(r.panel("", "body")).splitLines()
      assert lines[0] == "┌" & "─".repeat(6) & "┐"
      assert lines[1] == "│ body │"
      assert lines[2] == "└" & "─".repeat(6) & "┘"
