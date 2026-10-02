## Phase 9b-1 tests: the repo gates that do not reach `nim/`.
##
## `evals/deterministic/test_rulebook.py` and `test_hosted_boundary.py`
## walk `waku/`, `evals/` and `scripts/`. Neither has a `nim/` glob, so a
## Nim module that reached into `examples/`, `lab/` or `hosted/`, a module
## that defined one top-level name twice, or a design copy edited by hand
## would all pass CI in silence. These pins read the same invariants out of
## the tree instead, and they are read-only: file reads only, no network, no
## subprocess, nothing written anywhere (rule 8 keeps `design/` untouched).
##
## Additive, never a replacement, as `docs/nim-port-design.md` section 6
## requires. What the other suites already hold is not repeated here:
## `test_version.nim` owns the one version number, `test_embed.nim` owns
## embed-equals-checkout, and the 8a `test_dashboard.nim` owns the served
## route surface. What lives here is the five invariants nobody else says.
##
## Every path is anchored to this file's own location, so the suite reads
## the checkout it ships with from `nim/`, from the repo root or from
## anywhere else — the same anchoring as `test_version.nim` and
## `test_embed.nim`, and the reason no pin below names a relative path.

import std/[algorithm, os, re, strutils, tables, unittest]

import ../src/mcp # `sha256Hex`, for the design copies (pin D)

type
  Line = tuple[at: int, text: string]
    ## One source line with its 1-based number, so a pin can say which line
    ## it found and not only which file. (A named tuple annotated INLINE —
    ## `seq[(at: int, text: string)]` — is rejected by this compiler, so
    ## the shape lives in an alias, as in `test_embed.nim`.)

  Decl = tuple[name, signature: string, at: int]
    ## One top-level definition: the name, the signature (everything before
    ## the `=` that starts the body) and the line it sits on.

const
  DeniedComponents = ["examples", "lab"]
    ## Trees `nim/` may never reach (AGENTS.md rules 1 and 5). Path
    ## COMPONENTS, read that way because a component check is the one that
    ## survives a rename: `labelled.nim` and `exam/ples` are not reaches.

  HostedComponent = "hosted"
    ## `hosted/` is Elastic License 2.0 and `nim/` is MIT: an import across
    ## that line moves code between licences, so the direction is pinned
    ## the way `test_hosted_boundary.py` pins the other one.

  CopiedDesign = ["tokens.css", "controls.css"]
    ## The files `design/SOURCE.md` records as copied UNCHANGED from Waku
    ## Memory, written down here exactly as `test_design_system.py` writes
    ## its own list down. The pin compares two independent lists on purpose:
    ## a sync that stopped copying a file must fail as a MISMATCH, not pass
    ## by agreeing with a list this suite had quietly shrunk to match.

const
  DeclKeywords = ["proc", "func", "template", "macro", "converter", "type",
    "const", "let", "var"]
    ## The keywords that declare a top-level name in Nim. `converter` is
    ## here for the same reason `func` is: it defines a name at module
    ## level like any other. A `type`/`const`/`let`/`var` SECTION header
    ## has no name after it and so declares nothing.

  DeclFirstChars = {'p', 'f', 't', 'm', 'c', 'l', 'v'}
    ## The first letters of `DeclKeywords`, as a cheap gate in front of the
    ## pattern: most lines of a module are neither.

  NimGate = ".github/workflows/nim.yml"
    ## The gate `AGENTS.md` promises. Both the table row and the workflow
    ## file are read: a table that names a workflow nobody added is the
    ## same silent gap as a gate that never runs.

let
  DeclHead = re("^(" & DeclKeywords.join("|") &
      ")[ \t]+([A-Za-z_][A-Za-z0-9_]*)")
    ## A top-level declaration with a name after the keyword.

  ImportHead = re"^(import|include)[ \t]+"
    ## A top-level import, or an `include`, which pulls code in just as an
    ## import does. Column 0 only: that is the shape a module reaches
    ## another tree with, and it is the shape this scan can read from text.

  HashLine = re"^([0-9a-f]{64})  (\S+)$"
    ## One `sha256  name` line of a `sha256sum` listing, which is how
    ## `design/SOURCE.md` records the master's digests.

proc capture(line: string, pattern: Regex): seq[string] =
  ## The pattern's two captures on this line, or an empty seq when the line
  ## does not match. The buffer is a `seq` sized BEFORE the call and read
  ## from index 0: this compiler's `re.match` writes into the memory it is
  ## handed (its own note says the memory must exist first) and numbers
  ## the captures from 0, not 1.
  var groups = newSeq[string](2)
  if match(line, pattern, groups):
    return groups
  @[]

proc declName(line: string): string =
  ## The name a top-level declaration line declares, or `""` when the line
  ## is not one.
  let groups = capture(line, DeclHead)
  if groups.len == 2:
    return groups[1]
  ""

proc repoRoot(): string =
  ## The repo root, from this file's own path and never from the working
  ## directory. `absolutePath` rather than a bare concatenation, so a
  ## compiler handed a relative path still lands on the same tree.
  absolutePath(currentSourcePath().parentDir / ".." / "..")

proc designDir(): string =
  ## The copied design files, read only: AGENTS.md rule 8 forbids editing
  ## them here, and this suite holds to it in both directions — it reads
  ## the bytes and writes nothing back.
  repoRoot() / "waku" / "ops" / "static" / "design"

proc isThisSuite(path: string): bool =
  ## Whether a path is this file. The boundary scans below hold the denied
  ## names as DATA, so without this exemption the checker fails on its own
  ## source — which is why `test_rulebook.py` skips its own file too.
  absolutePath(path) == absolutePath(currentSourcePath())

proc nimModules(): seq[string] =
  ## Every module the port ships (`src/`) and every suite that pins it
  ## (`tests/`), absolute and sorted. Sorted because `walkDirRec` hands
  ## back whatever the filesystem returns, and the first failure a reader
  ## sees must not depend on which machine ran it.
  for top in ["src", "tests"]:
    let root = repoRoot() / "nim" / top
    for rel in walkDirRec(root, relative = true):
      if rel.endsWith(".nim"):
        result.add(root / rel)
  result.sort(cmp[string])

# --- pin A and B: the trees nim/ may not reach -----------------------------

proc pathComponents(path: string): seq[string] =
  ## The components of one path, whatever the separator. Dots split too, so
  ## `examples.lesson` is caught the way `test_rulebook.py` catches it out
  ## of the AST, and a dot-free `../src/mcp` is unchanged by that.
  for part in path.replace('\\', '/').split({'/', '.'}):
    let text = part.strip()
    if text.len > 0:
      result.add(text)

proc deniedComponent(path: string, denied: openArray[string]): string =
  ## The first denied component this path names, or `""`. A COMPONENT
  ## match, which is the whole point: read as a substring, `labelled` and
  ## `exam/ples` would fail too, and a pin that cries wolf teaches its
  ## reader to skip it.
  for part in pathComponents(path):
    for name in denied:
      if part == name:
        return name
  return ""

proc importLines(source: string): seq[Line] =
  ## The import/include lines a module starts at column 0. One line, one
  ## line number: a pin that says only the file leaves the reader to
  ## re-find the line themselves.
  # `splitLines` is an ITERATOR in this compiler's strutils and a `func`
  # beside it, and a `for` picks the iterator, which yields one string: the
  # lines are indexed here so each hit keeps its number.
  let lines = source.splitLines()
  for n in 0 ..< lines.len:
    if lines[n].len == 0 or lines[n][0].isSpaceAscii:
      continue
    if not match(lines[n], ImportHead):
      continue
    result.add((at: n + 1, text: lines[n].strip()))

proc importPath(line: string): string =
  ## The path an import line names: the keyword and any quotes dropped, so
  ## the component scan reads the path and not the punctuation.
  var text = line
  let gap = text.find({' ', '\t'})
  if gap >= 0:
    text = text[gap .. ^1].strip()
  text.replace("\"", "")

proc importReachers(source: string, denied: openArray[string]): seq[Line] =
  ## The imports of one module that name a denied tree.
  for line in importLines(source):
    if deniedComponent(importPath(line.text), denied) != "":
      result.add(line)

proc literals(line: string): seq[string] =
  ## The quoted literals on one line, escapes honoured, so a `\"` inside a
  ## string does not end it. Known limit: a literal written across several
  ## lines with `"""` is read line by line, which can only cost a false
  ## POSITIVE on a line of prose about a denied path — the same direction
  ## the pin is meant to fail.
  var i = 0
  while i < line.len:
    if line[i] != '"':
      i.inc
      continue
    var j = i + 1
    var literal = ""
    while j < line.len and line[j] != '"':
      if line[j] == '\\' and j + 1 < line.len:
        j.inc
      literal.add(line[j])
      j.inc
    result.add(literal)
    i = if j < line.len: j + 1 else: j

proc literalReachers(source: string, denied: openArray[string]): seq[Line] =
  ## The lines that name a denied tree as DATA. A path in a string is a
  ## reach just as much as a path in an import: the gate is that product
  ## code never reads, runs or links anything in those trees, and a
  ## `readFile("examples/…")` does the reading. A whole-line comment is
  ## skipped — prose about a boundary is not a reach through it.
  let lines = source.splitLines()
  for n in 0 ..< lines.len:
    if lines[n].len > 0 and lines[n][0] == '#':
      continue
    for literal in literals(lines[n]):
      for name in denied:
        if name & "/" in literal:
          result.add((at: n + 1, text: lines[n].strip()))

# --- pin C: one definition per top-level name -------------------------------

proc bodyEquals(header: string): int =
  ## Offset of the `=` that starts the body, or -1 when the header holds
  ## none. Depth-tracked and string-aware, so a default value (`ts = ""`)
  ## inside the parameter list is not mistaken for a body and a brace
  ## inside a literal is not a block.
  var depth = 0
  var inString = false
  var escaped = false
  for i, c in header:
    if escaped:
      escaped = false
    elif c == '\\':
      escaped = inString
    elif c == '"':
      inString = not inString
    elif inString:
      discard
    elif c in {'(', '[', '{'}:
      depth.inc
    elif c in {')', ']', '}'}:
      depth = max(0, depth - 1)
    elif c == '=' and depth == 0:
      return i
  return -1

proc isContinuation(line: string): bool =
  ## Whether the line under a declaration header still belongs to it: a
  ## wrapped signature, a blank line, or a doc comment. Anything else at
  ## column 0 is the next top-level thing, and a forward declaration ends
  ## there with no `=`.
  line.len == 0 or line[0] in {' ', '\t', '#'}

proc normalizeSignature(header: string, at: int): string =
  ## The signature with its export stars, wrapping and spacing gone, so
  ## `proc f(\n    x: int)` and `proc f(x: int)` compare equal — and so
  ## `proc f*` and `proc f` do NOT read as two different names.
  var kept = newStringOfCap(at)
  for c in header[0 ..< at]:
    if c notin {'*', ' ', '\t'}:
      kept.add(c)
  kept

proc topLevelDecls(source: string): seq[Decl] =
  ## Every top-level DEFINITION in a module, in file order. Three shapes
  ## are read the way Nim reads them, which is why this is not a copy of
  ## the Python check:
  ## - `proc f(x: int): int` with no `=` below it is a FORWARD declaration,
  ##   not a second definition. `src/mcp.nim` forward-declares
  ##   `storedBearerFor` at line 425 and defines it in the 6c section;
  ## - two definitions sharing a name with DIFFERENT signatures are the
  ##   overloads Nim is built on. `src/arena.nim` takes `appendRun` as a
  ##   `JsonNode` and as a `seq[JsonNode]`;
  ## - a `type`/`const`/`let`/`var` section header has no name after the
  ##   keyword, so it declares nothing.
  let lines = source.splitLines()
  var i = 0
  while i < lines.len:
    if lines[i].len == 0 or lines[i][0] notin DeclFirstChars:
      i.inc
      continue
    let name = declName(lines[i])
    if name.len == 0:
      i.inc
      continue
    var header = lines[i]
    while bodyEquals(header) < 0 and i + 1 < lines.len and
        isContinuation(lines[i + 1]):
      header.add(" " & lines[i + 1].strip())
      i.inc
    let at = bodyEquals(header)
    if at >= 0:
      result.add((name: name,
        signature: normalizeSignature(header, at), at: i + 1))
    i.inc

proc duplicateNames(module, source: string): seq[string] =
  ## One entry per name defined twice with ONE signature — the Python
  ## defect, where a later definition silently replaces an earlier one. A
  ## name keyed with its signature, so a legit overload is a different key
  ## and never shows up here.
  var seen = initTable[string, Decl]()
  for decl in topLevelDecls(source):
    let key = decl.name & " " & decl.signature
    if key in seen:
      result.add(module & ": `" & decl.name & "` at lines " &
        $seen[key].at & " and " & $decl.at)
    else:
      seen[key] = decl

# --- pin D and E: the copied design bytes and the gate that checks them -----

proc recordedDigests(source: string): Table[string, string] =
  ## The master's digests as `design/SOURCE.md` records them: file name to
  ## sha256, read the way `sha256sum` prints them so the two cannot drift
  ## apart in format.
  var groups: seq[string]
  for line in source.splitLines():
    groups = capture(line, HashLine)
    if groups.len == 2:
      result[groups[1]] = groups[0]

proc tableRows(markdown: string, heading: string): seq[seq[string]] =
  ## The rows of the table under one `##` heading, cells split. The heading
  ## is found first, so a table added elsewhere in the file cannot stand in
  ## for this one. The prose between the heading and the table is skipped
  ## (a table opens wherever the first row opens) and the first line after
  ## the rows that is neither a row nor blank ends it.
  var inTable = false
  for line in markdown.splitLines():
    if line.startsWith(heading):
      inTable = true
      continue
    if not inTable:
      continue
    if line.startsWith("|"):
      let parts = line.split('|')
      var cells: seq[string] = @[]
      for i, cell in parts:
        if i > 0 and i < parts.len - 1:
          # Backticks are markdown's inline code, not part of what the cell
          # says: the table names `.github/workflows/nim.yml`, and a reader
          # matching that name should not have to know the markup.
          cells.add(cell.strip().replace("`", ""))
      result.add(cells)
    elif result.len > 0 and line.len > 0 and not line.startsWith("#"):
      break

suite "phase 9b-1 the trees nim/ may not reach":
  test "no module imports examples/ or lab/":
    var offenders: seq[string] = @[]
    for module in nimModules():
      if isThisSuite(module):
        continue
      for hit in importReachers(readFile(module), DeniedComponents):
        offenders.add(module.extractFilename & ":" & $hit.at & " " & hit.text)
    assert offenders.len == 0,
      "these import into examples/ or lab/:\n  " & offenders.join("\n  ")

  test "no module names examples/ or lab/ in a string literal":
    var offenders: seq[string] = @[]
    for module in nimModules():
      if isThisSuite(module):
        continue
      for hit in literalReachers(readFile(module), DeniedComponents):
        offenders.add(module.extractFilename & ":" & $hit.at & " " & hit.text)
    assert offenders.len == 0,
      "these read, write or run a path in examples/ or lab/:\n  " &
      offenders.join("\n  ")

  test "no import anywhere in nim/ names a hosted path component":
    # `hostedListFn` and a comment about the hosted row are not reaches:
    # the pin reads path components on an import line, so the licence
    # boundary is crossed by an import and by nothing else.
    var offenders: seq[string] = @[]
    for module in nimModules():
      if isThisSuite(module):
        continue
      for hit in importReachers(readFile(module), [HostedComponent]):
        offenders.add(module.extractFilename & ":" & $hit.at & " " & hit.text)
    assert offenders.len == 0,
      "these import across the MIT / Elastic licence line:\n  " &
      offenders.join("\n  ")

  test "the boundary scan read the tree it says it read":
    # A scan that finds nothing must not be able to look like a clean
    # tree: a wrong root or a pattern that stopped matching would pass
    # every pin above with nothing checked.
    var modules = 0
    var imports = 0
    for module in nimModules():
      if isThisSuite(module):
        continue
      modules.inc
      imports += importLines(readFile(module)).len
    assert modules >= 40, "found only " & $modules & " modules under nim/"
    assert imports >= 100, "found only " & $imports & " import lines to read"

  test "the boundary reader names components, not substrings":
    # The negative that keeps the pin honest in both directions: a real
    # reach fails, and the words that merely CONTAIN a denied name pass.
    for line in ["import ../waku/ops/static", "import std/strutils",
        "import ../labelled", "import evals/deterministic/helpers",
        "include ./lab_brief"]:
      assert deniedComponent(importPath(line), DeniedComponents) == "",
        "an allowed import was denied: " & line
    for line in ["import ../../examples/lesson_one", "include ../../lab/play",
        "import examples.lesson_one"]:
      assert deniedComponent(importPath(line), DeniedComponents) != "",
        "a denied import passed: " & line
    assert deniedComponent(importPath("import ../hosted/app"),
        [HostedComponent]) == HostedComponent
    assert deniedComponent(importPath("import ../hosted_deploy/app"),
        [HostedComponent]) == "", "hosted_deploy is not hosted/"

  test "a denied path written as data is read too":
    # The direction the import scan cannot see: a reach spelled as a string
    # in code that never names the module it would pull in.
    let src = ["let seed = \"examples/seed.sql\"",
        "let home = \"waku/memory.db\""].join("\n")
    let hits = literalReachers(src, DeniedComponents)
    assert hits.len == 1, "expected one denied literal, found " & $hits.len
    assert hits[0].at == 1
    let prose = ["## the examples/ tree is read by the Python port only",
        "let label = \"lab\"  # a name, not a path"].join("\n")
    assert literalReachers(prose, DeniedComponents).len == 0,
      "a comment and a bare name must not read as reaches"

suite "phase 9b-1 one definition per top-level name":
  test "no module defines the same top-level name twice with one signature":
    # The Python contract (`test_rulebook.py`), read with Nim's rules: a
    # second definition of a module-level name silently replaces the first.
    var offenders: seq[string] = @[]
    for module in nimModules():
      for dup in duplicateNames(module.extractFilename, readFile(module)):
        offenders.add(dup)
    assert offenders.len == 0,
      "a module-level name is defined more than once — the later one wins " &
      "and the earlier is dead:\n  " & offenders.join("\n  ")

  test "the name scan read the tree it says it read":
    var decls = 0
    for module in nimModules():
      decls += topLevelDecls(readFile(module)).len
    assert decls >= 500, "found only " & $decls & " top-level definitions"

  test "the reader tells a forward decl, an overload and a duplicate apart":
    # The three shapes, on text the suite controls, so a scan that stopped
    # reading bodies (and would then report every real module as a
    # duplicate) fails here instead of in the tree.
    let src = [
      "proc declaredLater(): string",
      "proc declaredLater(): string =",
      "  \"defined below\"",
      "proc twice(x: int): int = x",
      "proc twice(x: string): string = x",
      "proc twice(x: int): int =",
      "  x + 1"
    ].join("\n")
    let dup = duplicateNames("probe", src)
    assert dup.len == 1, "expected one real duplicate, found: " & $dup
    assert "twice" in dup[0], "the duplicate reported was: " & dup[0]
    assert topLevelDecls("const\n  Answer = 42\n").len == 0,
      "a const SECTION header declares no name"

suite "phase 9b-1 the repo gates this suite reads":
  test "the pins read this repo, not whatever the working directory holds":
    # The anchor the other pins lean on. If this fails, every path below
    # resolved somewhere else and the pins above passed for the wrong
    # reason — so it is pinned rather than trusted.
    let root = repoRoot()
    for rel in ["AGENTS.md", "waku", "waku/ops/static/design",
        "waku/ops/static/design/SOURCE.md", "nim/src/waku.nim", "nim/tests"]:
      assert dirExists(root / rel.replace('/', DirSep)) or
          fileExists(root / rel.replace('/', DirSep)),
        "the repo root this suite anchored to has no " & rel

  test "the copied design files match the master's hashes in SOURCE.md":
    # Rule 8 from the other end: a hand edit to a copied file fails here.
    # Change it in Waku Memory, then run `scripts/sync_design.py`. The
    # digest is the file's, because `readFile` hands the bytes back as a
    # string and the copies are UTF-8 text.
    if not dirExists(designDir()):
      skip()
    let recorded = recordedDigests(readFile(designDir() / "SOURCE.md"))
    assert recorded.len == CopiedDesign.len,
      "SOURCE.md records " & $recorded.len & " hashes for " &
      $CopiedDesign.len & " copied files"
    for name in CopiedDesign:
      assert name in recorded, "SOURCE.md records no hash for design/" & name
      let got = sha256Hex(readFile(designDir() / name))
      assert got == recorded[name],
        "design/" & name & " differs from the copy recorded in SOURCE.md: " &
        got & " is not " & recorded[name]

  test "the copy reader takes a sha256sum line and nothing else":
    # The reader cannot be exercised by editing a design copy (rule 8), so
    # its precision is pinned here on text instead: a line that is not a
    # `sha256  name` listing must not be read as one, or the pin above
    # would compare a file against a digest pulled out of a paragraph.
    let digest = "89f2150e9e54292fc1d8a6c190a57124a051b9c4f81bd33cd8c9b22be5686963"
    let listed = ["```", digest & "  tokens.css",
      digest[0 .. 62] & "  short.css",
      digest.toUpperAscii() & "  upper.css",
      digest & " one-space.css", digest].join("\n")
    let recorded = recordedDigests(listed)
    assert recorded.len == 1,
      "the reader took " & $recorded.len & " lines as hashes"
    assert "tokens.css" in recorded, "the one real listing was not read"

  test "the CI table names the nim gate":
    # The row 9a-3 added, pinned so a reworded or dropped row is a failing
    # test rather than a promise nobody is keeping.
    let rows = tableRows(readFile(repoRoot() / "AGENTS.md"),
      "## What CI blocks")
    assert rows.len >= 5, "the CI table in AGENTS.md was not found"
    var named: seq[seq[string]] = @[]
    for row in rows:
      if row.len >= 2 and row[1] == NimGate:
        named.add(row)
    assert named.len == 1,
      "the CI table names " & NimGate & " " & $named.len & " times"
    assert "Nim" in named[0][0],
      "the row naming the nim gate does not say what it blocks: " & named[0][0]

  test "the gate the CI table names is a workflow in the tree":
    assert fileExists(repoRoot() / NimGate.replace('/', DirSep)),
      "AGENTS.md points at " & NimGate & ", which is not in the tree"
