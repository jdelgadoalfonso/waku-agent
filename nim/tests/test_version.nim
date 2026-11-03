## Phase 9a-2 tests: one version number, written down once.
##
## The Python contract, unchanged: `evals/deterministic/test_version.py:23-36`
## forbids a second copy of the version and a placeholder that is not a
## release number. This port had exactly that defect — `waku.nimble` said
## `0.0.1-phase0` and `src/waku.nim` said `0.0.1-phase0`, with a comment
## asking a human to keep them equal.
##
## The fix keeps the direction nimble needs: `waku.nimble` holds the only
## literal, `src/waku.nim` slurps it at compile time, and `waku --version`
## prints the const that came from there. These pins read both files, so a
## second literal fails here instead of drifting until someone reports the
## wrong number.

import std/os
import std/re
import std/strutils
import std/unittest

import ../src/waku

proc packageDir(): string =
  ## The `nim/` folder, from this file's own path and never from the working
  ## directory, so the pins read the checkout they ship with from any cwd.
  currentSourcePath().parentDir / ".."

proc readPackageFile(name: string): string =
  ## One package file, verbatim: the pins below count literals in the raw
  ## text, so nothing here may normalise what it reads.
  let path = packageDir() / name
  assert fileExists(path), "missing package file: " & path
  readFile(path)

proc declaredNimbleVersion(manifest: string): string =
  ## The `version = "..."` value a nimble manifest declares, read the way
  ## nimble reads it (the first `version` key, quoted). A manifest that
  ## stops declaring one fails here by finding nothing.
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

suite "phase 9a-2 version source of truth":
  test "the version is a release number, not a placeholder":
    # `^\d+\.\d+\.\d+$`, the shape `test_version.py` fullmatches. The
    # `-phase0` suffix that shipped here was a dev marker on a version
    # number nimble would have published.
    assert re.match(version, re"^\d+\.\d+\.\d+$"),
      "not a release number: " & version

  test "the binary prints the version the manifest declares":
    let manifest = readPackageFile("waku.nimble")
    assert declaredNimbleVersion(manifest) == version,
      "waku.nimble says " & declaredNimbleVersion(manifest) &
      ", the binary prints " & version

  test "the version literal is written down once":
    # One editable number across both files: a second copy in `src/waku.nim`
    # is the drift this phase removed, so the count fails instead of a human
    # reading a comment that asks for discipline.
    let manifest = readPackageFile("waku.nimble")
    let source = readPackageFile("src/waku.nim")
    assert manifest.count(version) == 1,
      "waku.nimble holds the number " & $manifest.count(version) & " times"
    assert source.count(version) == 0,
      "src/waku.nim holds a second copy of the version number"

  test "the manifest a human edits declares a release number":
    # The same shape, read from the file itself rather than through the
    # const, so an unquoted or missing version fails here instead of
    # printing an empty `--version`.
    let declared = declaredNimbleVersion(readPackageFile("waku.nimble"))
    assert declared.len > 0, "waku.nimble declares no version"
    assert re.match(declared, re"^\d+\.\d+\.\d+$"),
      "not a release number: " & declared

# --- the frozen Python half's version contract ------------------------------
#
# `evals/deterministic/test_version.py` holds three facts about the Python
# half: `pyproject.toml` must not hardcode a second version, hatchling must
# read the number from `waku/__init__.py`, and that number must be a release
# number. Ported here (S3) so retiring that eval would not lose them, each
# failing on the same fact its Python twin fails on (S5).
#
# There is deliberately NO cross-half equality pin, in either direction: the
# Python half is frozen (spec S1) and its release workflows rewrite
# `waku/__init__.py` on their own schedule, so the two halves are free to
# agree or to differ. What is pinned is one editable literal PER HALF.

proc repoRoot(): string =
  ## The repository root, one level above `nim/`, from this file's own path
  ## and never from the working directory.
  absolutePath(currentSourcePath().parentDir / ".." / "..")

proc readRepoFile(rel: string): string =
  ## One file of the checkout, verbatim, by its repo-relative path.
  let path = repoRoot() / rel.replace('/', DirSep)
  assert fileExists(path), "missing repo file: " & path
  readFile(path)

proc stripTomlComment(line: string): string =
  ## A line with a `#` comment dropped, so a trailing note never joins a
  ## value. The same one-line rule `providers.stripInlineComment` uses,
  ## kept local so this suite reads `pyproject.toml` without importing a
  ## parser it does not need.
  var inQuotes = false
  for i, ch in line:
    if ch == '"':
      inQuotes = not inQuotes
    elif ch == '#' and not inQuotes:
      return line[0 ..< i].strip()
  line.strip()

proc tableBody(text, table: string): seq[string] =
  ## The key/value lines under one `[table]` header, up to the next header.
  ## A line-level read of the TOML subset `pyproject.toml` uses, not a full
  ## parser: all three facts below are top-level keys of one table.
  var inTable = false
  for raw in text.splitLines():
    let line = stripTomlComment(raw)
    if line.len == 0:
      continue
    if line.startsWith("["):
      inTable = line == table
      continue
    if inTable:
      result.add line

proc keyValue(line: string): (string, string) =
  ## One `key = value` line split at its first `=`, both sides stripped. A
  ## line with no `=` reads as empty strings so a caller can skip it.
  let eq = line.find('=')
  if eq <= 0:
    return ("", "")
  (line[0 ..< eq].strip(), line[eq + 1 .. ^1].strip())

proc declaresKey(body: openArray[string], key: string): bool =
  ## Whether this table's body declares `key = ...`. The key matches whole,
  ## so `version` does not match `version_scheme = ...`.
  for line in body:
    let (k, _) = keyValue(line)
    if k == key:
      return true
  false

proc unquoteValue(value: string): string =
  ## A single-quoted TOML string without its quotes, or the text unchanged.
  let text = value.strip()
  if text.len >= 2 and text[0] == '"' and text[^1] == '"':
    return text[1 ..< ^1]
  text

proc stringArrayValue(body: openArray[string], key: string): seq[string] =
  ## The quoted elements of `key = ["a", "b"]`, the one array shape the
  ## `[project]` table uses. Empty when the key is absent or is not an
  ## array, which the pin below reports instead of crashing.
  for line in body:
    let (k, v) = keyValue(line)
    if k != key:
      continue
    if not (v.startsWith("[") and v.endsWith("]")):
      return @[]
    for part in v[1 ..< ^1].split(','):
      let item = part.strip()
      if item.len >= 2 and item[0] == '"' and item[^1] == '"':
        result.add item[1 ..< ^1]
  result

suite "one version literal per half":
  test "pyproject keeps the version dynamic and hardcodes no second one":
    # `test_pyproject_does_not_hardcode_a_second_version`, test_version.py:23-29:
    # a static `[project] version` is how the two numbers drifted apart for
    # four releases.
    let body = tableBody(readRepoFile("pyproject.toml"), "[project]")
    assert body.len > 0, "pyproject.toml has no [project] table"
    assert not declaresKey(body, "version"),
      "pyproject.toml declares its own version again — it must stay dynamic " &
      "so waku/__init__.py is the only place the number lives"
    assert "version" in stringArrayValue(body, "dynamic"),
      "pyproject.toml does not list version in [project] dynamic"

  test "hatchling reads the Python half's version from the package":
    # `test_hatchling_reads_the_version_from_the_package`, test_version.py:32.
    let body = tableBody(readRepoFile("pyproject.toml"),
      "[tool.hatch.version]")
    assert body.len > 0, "pyproject.toml has no [tool.hatch.version] table"
    var path = ""
    for line in body:
      let (k, v) = keyValue(line)
      if k == "path":
        path = unquoteValue(v)
    assert path == "waku/__init__.py",
      "[tool.hatch.version] path is " & path & ", not waku/__init__.py"

  test "the Python half's declared version is a release number":
    # `test_version_is_a_release_number`, test_version.py:36: catches a
    # placeholder or a leftover dev marker going out to PyPI.
    var declared = ""
    for line in readRepoFile("waku/__init__.py").splitLines():
      let text = line.strip()
      if not text.startsWith("__version__"):
        continue
      let first = text.find('"')
      let last = text.rfind('"')
      if first >= 0 and last > first:
        declared = text[first + 1 ..< last]
      break
    assert declared.len > 0, "waku/__init__.py declares no __version__"
    assert re.match(declared, re"^\d+\.\d+\.\d+$"),
      "not a release number: " & declared
