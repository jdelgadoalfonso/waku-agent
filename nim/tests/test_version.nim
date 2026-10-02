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
