## Rewrite the generated Connections block in `.env.example` from the registry.
##
## Nim twin of `scripts/generate_env_example.py`: reads
## `data/providers.toml` + `data/integrations.toml`, renders with
## `renderEnvExampleBlock`, splices between the markers. Run from `nim/`
## via `nimble envExample`. The T8 pin in `tests/test_repo_gates.nim`
## checks the committed file matches this render.

import std/os
import std/strutils

import ./src/integrations
import ./src/providers

const
  BeginMarker = "# BEGIN GENERATED CONNECTIONS"
  EndMarker = "# END GENERATED CONNECTIONS"

proc repoRoot(): string =
  absolutePath(currentSourcePath().parentDir / "..")

proc main(): int =
  let writeIt = "--write" in commandLineParams()
  let path = repoRoot() / ".env.example"
  var contents: string
  try:
    contents = readFile(path)
  except IOError as e:
    stderr.writeLine("cannot read " & path & ": " & e.msg)
    return 1
  let begin = contents.find(BeginMarker)
  let finish = contents.find(EndMarker)
  if begin < 0 or finish < 0 or finish < begin:
    stderr.writeLine(".env.example is missing generated Connections markers")
    return 1
  let rendered = renderEnvExampleBlock(
    loadProviders(repoRoot() / "data" / "providers.toml"),
    envExampleIntegrations(parseIntegrationRows(
      readFile(repoRoot() / "data" / "integrations.toml"))))
  let afterEnd = finish + EndMarker.len
  # The Python splicer keeps exactly the render through EndMarker plus a
  # trailing newline; mirror that so both writers produce the same bytes.
  let expected = contents[0 ..< begin] & rendered.strip(leading = false) &
    contents[afterEnd .. ^1]
  if expected == contents:
    echo "Connections block is up to date."
    return 0
  if not writeIt:
    stderr.writeLine("Connections block is out of date: re-run with --write " &
      "(explicit) or scripts/generate_env_example.py --write.")
    return 1
  try:
    writeFile(path, expected)
  except IOError as e:
    stderr.writeLine("cannot write " & path & ": " & e.msg)
    return 1
  echo "Rewrote the Connections block in " & path
  return 0

when isMainModule:
  quit(main())
