## Phase 9c tests: the built binary, as a black box.
##
## Phases 9a and 9b pinned the port from the INSIDE — `import ../src/x`,
## then call the same proc the CLI calls. That proves the modules agree
## with each other. It cannot see a dispatch that drops an argument, an
## exit code nobody reads, or a sentence that drifted away from the
## Python line it copies. This suite runs `nim/waku` itself, through
## `osproc`, and compares what a person at the terminal would see: exit
## codes, stdout, stderr.
##
## Three rules keep those comparisons honest:
##
## 1. LOCAL AND OFFLINE. Every child is the binary beside these tests,
##    spawned by `runBinary` and nothing else — no shell, no network, no
##    install. The PROCESS pins skip when that binary is missing
##    (`nimble test` runs before `nimble build` in this repo's own flow),
##    with the guard `tests/test_phase0c.nim:89` and
##    `tests/test_embed.nim:96` already use, and the skip prints why
##    rather than reporting a green run that tested nothing.
##
## 2. AN ENVIRONMENT BUILT HERE, NOT INHERITED. `blackboxEnv` hands each
##    child its own table: `PATH`, `WAKU_PROVIDER=anthropic`, and every
##    credential var PRESENT BUT EMPTY. Empty rather than absent on
##    purpose: `loadDotenvFile` keeps a variable that is already set
##    (`src/config.nim:152`), so a set-but-empty entry is what stops a
##    checkout `.env` from handing a real key to a pin that must watch a
##    refusal. The one pin that wants a key sets a fixture value, which the
##    same rule leaves the file unable to overwrite.
##
## 3. ONE WORKING-DIRECTORY ASSUMPTION, and it is `nim/`. The child runs
##    there because that is where `nimble build` leaves the binary (the
##    path `.gitignore:50` ignores) and where `findProvidersToml`'s second
##    candidate, `../data/providers.toml`, reaches the checkout — so the
##    `connections` pins read the real registry instead of an honest
##    rejection. Every other path in this file is anchored to
##    `currentSourcePath()`, so the suite reads the same tree whether it
##    was compiled from `nim/` or from the repo root.
##
## The second suite is the divergence pin. `pythonPinnedGet` and
## `pythonPinnedPost` in `src/dashboard.nim` are hand copies of
## `PINNED_GET`/`PINNED_POST` in
## `evals/deterministic/test_dashboard_routes.py`, and until this suite
## nothing compared the two. They are read TEXTUALLY here, the precedent
## being `evals/deterministic/hosted/test_route_contract.py:26-38`,
## which reads the same file's constants instead of importing them:
## importing needs the `anthropic` client, and a pin that cannot run
## offline would skip forever. A divergence fails here instead of passing
## in silence. If the two sets HAVE diverged, that is a finding to report
## — this suite never rewrites either side.
##
## ONE DIVERGENCE IS ALREADY ON RECORD: `--help`. Python's `waku --help`
## is an unknown command (usage text, exit 1); this port answers the flag
## with exit 0 and the command list, declared in `src/waku.nim`'s header.
## That pin asserts the port's OWN contract, and says so in its name.

import std/[algorithm, os, osproc, re, sequtils, sets, streams, strtabs,
  strutils, times, unittest]

import ../src/dashboard

type
  Run = tuple[code: int, outText, errText: string]
    ## One finished child: its exit code plus both streams kept APART,
    ## because `chat` refuses on stderr and the gateways answer on stdout
    ## (a declared divergence, `src/waku.nim`'s `gatewayLog`).

const
  binaryName = "waku"

  provider = "anthropic"
    ## The one provider these pins run as: `blackboxEnv` pins it so a
    ## shell that exported something else cannot change what a child says.

  fixtureKey = "blackbox-fixture-key"
    ## A value with no privileges and no meaning anywhere. The pin that
    ## configures a row uses it to make "configured" true; it is never
    ## sent anywhere, because the commands pinned here refuse before any
    ## request is made.

  healthMessage = "401 unauthorized (black-box fixture)"
    ## The message the stored-ERROR fixture writes, pinned back out of
    ## `connections`' stdout: a store that lost its text on the way to
    ## the terminal would still exit 1, and nobody would notice.

  healthCheckedAt = "2026-10-02T00:00:00Z"
    ## Fixed so the `connections` line it renders is a constant the pin
    ## can name, rather than whatever time the test happened to run at.

  healthFixture = "{\"anthropic\": {\"state\": \"error\", \"message\": \"" &
    healthMessage & "\", \"checked_at\": \"" & healthCheckedAt & "\"}}"
    ## `connections_health.json` as the port writes it: the shape
    ## `parseHealthStatus` reads (`state`, `message`, `checked_at`).
    ## Written into a temp home, never into a real one.

  credentialVars = [
    "WAKU_API_KEY", "ANTHROPIC_API_KEY",
    "TELEGRAM_BOT_TOKEN", "DISCORD_BOT_TOKEN",
    "WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID",
    "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_APP_SECRET",
    "WAKU_STT_COMMAND", "WAKU_MIC_COMMAND", "WAKU_TTS_COMMAND"
  ]
    ## Every variable a command pinned below reads to decide whether it
    ## can run. Each one goes into the child's env as EMPTY, so "no
    ## credential" is what the child sees whether or not the developer
    ## who ran `nimble test` has a key exported.

proc packageDir(): string =
  ## The `nim/` folder, from this file's own path and never from the
  ## working directory. `parentDir` comes first on purpose:
  ## `normalizedPath` pops whatever component precedes a `..`, filename
  ## included (the note in `tests/test_embed.nim`).
  normalizedPath(currentSourcePath().parentDir / "..")

proc repoRoot(): string =
  ## The checkout root, anchored the same way. Only `evals/` is read
  ## through it, and read-only.
  normalizedPath(currentSourcePath().parentDir / ".." / "..")

proc binaryPath(): string =
  ## The built binary, or `""` when this checkout has not built it yet.
  let path = packageDir() / binaryName
  if fileExists(path):
    path
  else:
    ""

proc pythonPins(): string =
  ## The Python route pins this suite's second half reads.
  repoRoot() / "evals" / "deterministic" / "test_dashboard_routes.py"

proc needBinary(): bool =
  ## Whether the process pins can run. When they cannot, this prints WHY
  ## and the caller skips — the pattern `tests/test_phase0c.nim:89` and
  ## `tests/test_embed.nim:96` already use. It is a proc because
  ## `unittest.skip` only binds inside a `test` block.
  result = binaryPath().len > 0
  if not result:
    echo "SKIP: no binary at " & (packageDir() / binaryName) &
      " — build it with `nimble build` and these pins run"

proc tmpHome(name: string): string =
  ## A path under the system temp dir for one child's `WAKU_HOME`. It
  ## does NOT exist yet: the `chat` pin's whole point is that a refusal
  ## creates nothing. Pid and time keep two runs, or two tests, from
  ## landing on the same directory.
  getTempDir() / ("waku-blackbox-" & name & "-" & $getCurrentProcessId() &
    "-" & $epochTime())

proc discardHome(path: string) =
  ## Remove a temp home this suite created. Scoped on purpose: only a
  ## path `tmpHome` handed out is ever passed here, never a home a person
  ## owns.
  if dirExists(path):
    removeDir(path)

proc blackboxEnv(): StringTableRef =
  ## The environment every child in this suite sees — this table, not
  ## the developer's shell (see the header, rule 2). `PATH` is carried
  ## over because the child may spawn a tool of its own; the binary
  ## itself is started by absolute path.
  result = newStringTable(mode = modeCaseSensitive)
  result["PATH"] = getEnv("PATH", "/usr/bin:/bin")
  result["WAKU_PROVIDER"] = provider
  for name in credentialVars:
    result[name] = ""

proc runBinary(args: seq[string], home: string,
               extra: seq[tuple[key, value: string]] = @[]): Run =
  ## One child: this binary, `args`, the environment above, and `nim/`
  ## as the working directory (header, rule 3). `extra` is what one pin
  ## needs ON TOP of the blank table — a fixture key, or the three
  ## WhatsApp credentials that must NOT be the missing one. Callers guard
  ## with `needBinary`: with no binary, `startProcess` raises instead of
  ## quietly pinning nothing.
  let env = blackboxEnv()
  env["WAKU_HOME"] = home
  for pair in extra:
    env[pair.key] = pair.value
  # `options = {}` on purpose: osproc's default merges stderr into
  # stdout, and one of these pins is exactly "the refusal is on stderr".
  let child = startProcess(binaryPath(), packageDir(), args, env,
                           options = {})
  # The child's stdin is a pipe this suite never writes to, so it is
  # closed here: a command that reached a prompt would then see EOF and
  # exit instead of hanging the whole suite on a read.
  inputStream(child).close()
  # Both pipes are read to EOF before the wait, and what is pinned here
  # are refusals and short lists — hundreds of bytes, far below a pipe
  # buffer, so neither stream can fill while the other is being read.
  result.outText = outputStream(child).readAll()
  result.errText = errorStream(child).readAll()
  result.code = child.waitForExit()
  child.close()

proc declaredNimbleVersion(manifest: string): string =
  ## The `version = "..."` a nimble manifest declares, read the way nimble
  ## reads it (the first `version` key, quoted) — the same reading as
  ## `tests/test_version.nim`, so the two suites cannot disagree about
  ## what the manifest says.
  for line in manifest.splitLines():
    let text = line.strip()
    if not text.startsWith("version"):
      continue
    let first = text.find('"')
    let last = text.rfind('"')
    if first < 0 or last <= first:
      return ""
    return text[first + 1 ..< last]
  return ""

# ── the Python pins, read as text ──────────────────────────────────
#
# `PINNED_GET` and `PINNED_POST` are Python sets built by union
# (`POST_ROUTES | STREAM_ROUTES | {...}`), so reading them means reading
# the union too. Two shapes are parsed, and only these two: a quoted path
# inside braces, and a name that is itself assigned a brace literal. The
# pinned paths contain no braces, so the brace walk below cannot be
# fooled by a string.

proc literalSpan(source, name: string): tuple[first, last: int] =
  ## The byte span of `name = ...`, from just past its `=` to the brace
  ## that closes the first `{` after it. That span carries the literal
  ## paths AND the names this set unions, which is why the walk starts at
  ## the literal rather than at the assignment. `(-1, -1)` when the file
  ## holds no `name =` at all. The FIRST one wins: for the module-level
  ## constants read here, that is the assignment itself.
  let bounds = source.findBounds(re(escapeRe(name) & r"\s*="))
  if bounds.first < 0:
    return (-1, -1)
  let open = source.find('{', bounds.last)
  if open < 0:
    return (-1, -1)
  var depth = 0
  var i = open
  while i < source.len:
    case source[i]
    of '{': inc depth
    of '}':
      dec depth
      if depth == 0:
        return (bounds.last + 1, i)
    else: discard
    inc i
  return (-1, -1)

proc tokenAt(source: string, start: int): tuple[next: int, name: string] =
  ## The `[A-Za-z_][A-Za-z0-9_]*` token at `start`, or `("", -1)` when
  ## there is none there. Hand-rolled because the tokens are plain ASCII
  ## and this walks one file, at test time.
  if start < 0 or start >= source.len or
      not (source[start].isAlphaAscii or source[start] == '_'):
    return (-1, "")
  var i = start + 1
  while i < source.len and (source[i].isAlphaNumeric or source[i] == '_'):
    inc i
  return (i, source[start ..< i])

proc pythonRoutes(source, name: string,
                  seen: var HashSet[string]): HashSet[string] =
  ## `name` as a set of paths: every quoted path in its span, plus every
  ## set it unions, resolved one level at a time. `seen` stops a name
  ## that (directly or not) refers to itself, and a name that is not a
  ## set literal contributes nothing rather than guessing.
  if name in seen:
    return
  seen.incl name
  let (first, last) = literalSpan(source, name)
  if first < 0:
    return
  # A quoted path, `"/api/chat"`. An ordinary string, not a raw one: the
  # quotes this matches have to be escaped.
  for quoted in source[first .. last].findAll(re("\"(/[^\"]*)\"")):
    result.incl quoted[1 ..< quoted.len - 1]
  var i = first
  while i <= last:
    let (next, token) = tokenAt(source, i)
    if token.len == 0:
      inc i
      continue
    # `contains`, not `match`: `re.match` is anchored at the search
    # start, so it would only ever see the top of the file.
    if source.contains(re(escapeRe(token) & r"\s*=\s*\{")):
      result.incl pythonRoutes(source, token, seen)
    i = if next > i: next else: i + 1

proc pythonPinnedRoutes(source, name: string): HashSet[string] =
  ## `pythonRoutes` with its own `seen`, so one call cannot leave the
  ## next one short a name.
  var seen: HashSet[string]
  pythonRoutes(source, name, seen)

proc routesFile(): string =
  ## The Python pins file, or `""` when this checkout does not carry it.
  if fileExists(pythonPins()):
    pythonPins()
  else:
    ""

suite "phase 9c black-box process pins":
  test "--version prints the version the manifest declares":
    if not needBinary():
      skip()
    else:
      let manifest = packageDir() / "waku.nimble"
      let run = runBinary(@["--version"], tmpHome("version"))
      assert run.code == 0, "exit " & $run.code
      assert run.errText == "", "stderr: " & run.errText
      # Against the FILE, not against `src/waku.nim`'s const: a binary
      # built from an older manifest still prints its own (older) number,
      # and only the file on disk says what is current.
      assert re.match(run.outText.strip, re"^\d+\.\d+\.\d+$"),
        "not a release number: " & run.outText
      assert run.outText.strip == declaredNimbleVersion(readFile(manifest)),
        "binary says " & run.outText.strip & ", " & manifest & " declares " &
        declaredNimbleVersion(readFile(manifest))

  test "an unknown command prints the usage text and exits 1":
    if not needBinary():
      skip()
    else:
      let run = runBinary(@["not-a-command"], tmpHome("bogus"))
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert "Usage: waku <command>" in run.outText, run.outText
      # The command list, not just the header: a usage block that lost
      # its rows would still carry the line above.
      assert "connections" in run.outText and "telegram" in run.outText,
        run.outText

  test "--help exits 0 with the command list (a declared divergence)":
    if not needBinary():
      skip()
    else:
      # Python has no `--help`: there it is an unknown command, usage and
      # exit 1. The port answers the flag like a Unix tool would, which
      # `src/waku.nim`'s header declares. This is the one pin that asserts
      # the port's OWN contract instead of Python's.
      let run = runBinary(@["--help"], tmpHome("help"))
      assert run.code == 0, "exit " & $run.code & ", stdout: " & run.outText
      assert "Usage: waku <command>" in run.outText, run.outText
      assert "Run 'waku --version' for the port version." in run.outText,
        run.outText

  test "mcp in an empty home prints Python's sentence, character for character":
    if not needBinary():
      skip()
    else:
      let home = tmpHome("mcp")
      # `mcp_cli.py:94-96`, the line the Python CLI prints when there is
      # no `mcp.json`. The home is inside the sentence, so a home read
      # from anywhere but `WAKU_HOME` changes the answer.
      let expected = "No MCP servers configured. See docs/integrations.md, " &
        "or write " & (home / "mcp.json")
      let run = runBinary(@["mcp"], home)
      assert run.code == 0, "exit " & $run.code & ", stdout: " & run.outText
      assert run.errText == "", "stderr: " & run.errText
      assert run.outText.strip == expected, "got: " & run.outText.strip &
        "\nwant: " & expected

  test "connections from the checkout exits 0 on a fresh health store":
    if not needBinary():
      skip()
    else:
      # This is the pin that needs the working directory: `nim/` is one
      # level under the checkout, so `findProvidersToml`'s
      # `../data/providers.toml` candidate finds the real registry. A
      # missing registry is an honest exit 1, which the next pin's
      # registry-not-found guard also rules out.
      let run = runBinary(@["connections"], tmpHome("connections-fresh"))
      assert "providers.toml not found" notin run.outText,
        "the registry was not reachable from nim/: " & run.outText
      assert run.code == 0, "exit " & $run.code & ", stdout: " & run.outText
      assert "Anthropic" in run.outText, run.outText
      assert "not configured" in run.outText, run.outText

  test "connections with a stored ERROR on a configured row exits 1":
    if not needBinary():
      skip()
    else:
      # The exit rule from `connectionsFailed`: an ERROR row only fails
      # the command when its own fields are configured. Both halves are
      # needed, so this pin writes the health file AND sets the key.
      let home = tmpHome("connections-error")
      createDir(home)
      writeFile(home / "connections_health.json", healthFixture)
      let run = runBinary(@["connections"], home,
                          extra = @[("ANTHROPIC_API_KEY", fixtureKey)])
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert "error · " & healthMessage in run.outText, run.outText
      assert "checked " & healthCheckedAt in run.outText, run.outText
      discardHome(home)

  test "chat without a key exits 1 on stderr and builds no home":
    if not needBinary():
      skip()
    else:
      # `home` deliberately does not exist. `buildCliApp` builds the
      # client before it opens the state db, so the refusal must leave a
      # person with no half-made Waku directory.
      let home = tmpHome("chat")
      let run = runBinary(@["chat"], home)
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert run.outText == "", "the refusal is not on stderr: " & run.outText
      assert run.errText.startsWith("No API key for provider '" & provider &
        "'."), run.errText
      assert "ANTHROPIC_API_KEY" in run.errText, run.errText
      assert not dirExists(home), "the refusal created " & home

  test "telegram without a token names TELEGRAM_BOT_TOKEN and exits 1":
    if not needBinary():
      skip()
    else:
      # `telegram.py::main`'s SystemExit, verbatim — and on stdout: the
      # port's gateways log their refusals to the same mirror as their
      # banners (the divergence `gatewayLog` documents).
      let run = runBinary(@["telegram"], tmpHome("telegram"))
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert run.errText == "", "stderr: " & run.errText
      assert run.outText.strip == "Set TELEGRAM_BOT_TOKEN in .env " &
        "(message @BotFather to create a bot).", run.outText

  test "discord without a token names DISCORD_BOT_TOKEN and exits 1":
    if not needBinary():
      skip()
    else:
      let run = runBinary(@["discord"], tmpHome("discord"))
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert run.errText == "", "stderr: " & run.errText
      assert run.outText.strip == "Set DISCORD_BOT_TOKEN in .env " &
        "(create a bot in the Discord Developer Portal).", run.outText

  test "whatsapp reports the FIRST missing credential, in Python's order":
    if not needBinary():
      skip()
    else:
      # Python checks the four one by one and exits on the first gap
      # (`whatsapp.py::main`). Setting the last three and leaving the
      # first empty is what makes this an ORDER pin: a port that checked
      # them in another order, or listed all four, fails here.
      let run = runBinary(@["whatsapp"], tmpHome("whatsapp"), extra = @[
        ("WHATSAPP_PHONE_NUMBER_ID", fixtureKey),
        ("WHATSAPP_VERIFY_TOKEN", fixtureKey),
        ("WHATSAPP_APP_SECRET", fixtureKey)])
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert "WHATSAPP_TOKEN" in run.outText, run.outText
      assert "WHATSAPP_PHONE_NUMBER_ID" notin run.outText, run.outText
      assert "WHATSAPP_VERIFY_TOKEN" notin run.outText, run.outText
      assert "WHATSAPP_APP_SECRET" notin run.outText, run.outText

  test "voice without a key refuses before it listens":
    if not needBinary():
      skip()
    else:
      # The port has no `sounddevice`, and its own pre-flight is the three
      # external commands — but the dispatch builds the agent FIRST, so a
      # keyless run stops there, and that is what a person sees. The
      # engine lines are pinned by `tests/test_voice.nim`, which needs no
      # binary.
      let run = runBinary(@["voice"], tmpHome("voice"))
      assert run.code == 1, "exit " & $run.code & ", stdout: " & run.outText
      assert run.outText.contains("No API key for provider '" & provider &
        "'."), run.outText

  test "a blank variable in the child env stays set (config.nim:152 needs it)":
    # The precondition every refusal pin above rests on: an EMPTY entry in
    # the env table reaches the child as a variable that is SET, so
    # `loadDotenvFile`'s `not existsEnv(key)` skips it and a checkout
    # `.env` cannot hand this suite a real key. `env` is the witness that
    # prints what the child was given; an absent variable does not appear
    # there at all, which is also how the second half shows the table
    # REPLACES the inherited environment instead of adding to it.
    let witness = findExe("env")
    if witness.len == 0:
      echo "SKIP: no `env` binary to show what a child was given"
      skip()
    else:
      let child = startProcess(witness, packageDir(), @[], blackboxEnv(),
                               options = {})
      inputStream(child).close()
      let seen = outputStream(child).readAll()
      discard child.waitForExit()
      child.close()
      assert "ANTHROPIC_API_KEY=" in seen, seen
      assert "WAKU_PROVIDER=" & provider in seen, seen
      assert "OPENROUTER_API_KEY" notin seen, seen

suite "phase 9c pinned-surface divergence":
  test "the mirrored GET set is Python's PINNED_GET":
    # No binary needed: the divergence is between two copies of one list in
    # two languages, and a missing binary must not hide it.
    let path = routesFile()
    if path.len == 0:
      echo "SKIP: no " & pythonPins() & " — the Python pins are unreadable"
      skip()
    else:
      let source = readFile(path)
      let mine = toHashSet(pythonPinnedGet)
      let theirs = pythonPinnedRoutes(source, "PINNED_GET")
      assert mine == theirs, "only in src/dashboard.nim: " &
        $(sorted(toSeq(mine - theirs))) &
        "\nonly in test_dashboard_routes.py: " &
        $(sorted(toSeq(theirs - mine)))

  test "the mirrored POST set is Python's PINNED_POST":
    let path = routesFile()
    if path.len == 0:
      echo "SKIP: no " & pythonPins() & " — the Python pins are unreadable"
      skip()
    else:
      let source = readFile(path)
      let mine = toHashSet(pythonPinnedPost)
      let theirs = pythonPinnedRoutes(source, "PINNED_POST")
      assert mine == theirs, "only in src/dashboard.nim: " &
        $(sorted(toSeq(mine - theirs))) &
        "\nonly in test_dashboard_routes.py: " &
        $(sorted(toSeq(theirs - mine)))

  test "the sets parsed here are the ones the Python file declares":
    # The guard on the parser itself. A reader that stopped finding
    # strings would make the two pins above compare two empty sets and
    # pass in silence; these assertions say the unions were RESOLVED (each
    # pinned set is strictly larger than the literal sets it unions) and
    # that every entry read back is a path.
    let path = routesFile()
    if path.len == 0:
      echo "SKIP: no " & pythonPins() & " — the Python pins are unreadable"
      skip()
    else:
      let source = readFile(path)
      let gets = pythonPinnedRoutes(source, "PINNED_GET")
      let posts = pythonPinnedRoutes(source, "PINNED_POST")
      let getPaths = pythonPinnedRoutes(source, "GET_PATHS")
      let postRoutes = pythonPinnedRoutes(source, "POST_ROUTES")
      let streamRoutes = pythonPinnedRoutes(source, "STREAM_ROUTES")
      assert gets.len > 0 and posts.len > 0, "nothing was parsed"
      # Subset AND bigger: the pair says the union resolved into both
      # sets, without relying on a set operator to say "strictly".
      assert getPaths <= gets and gets.len > getPaths.len,
        "PINNED_GET did not resolve its union with GET_PATHS"
      assert postRoutes <= posts and streamRoutes <= posts and
        posts.len > postRoutes.len + streamRoutes.len,
        "PINNED_POST did not resolve its union with POST_ROUTES and " &
        "STREAM_ROUTES"
      for route in gets + posts:
        assert route.startsWith("/") and route.len > 1, route