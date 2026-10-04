## `github_read` tests: argv validation, formatting and the runner
## paths with a stubbed `gh`. Offline only: the binary is never executed.

import std/strutils
import std/unittest

import ../src/github

proc stubRun(outputs: openArray[(string, tuple[ok: bool,
    text: string])]): GhRunner =
  ## `gh <rest...>` → recording, matched by the joined command words.
  var table: seq[(string, tuple[ok: bool, text: string])] = @[]
  for (k, v) in outputs:
    table.add((k, v))
  result = proc(argv: seq[string]): tuple[ok: bool,
      text: string] {.closure.} =
    for (k, v) in table:
      if argv.join(" ") == k:
        return v
    raise newException(ValueError, "unstubbed gh call: " & argv.join(" "))

suite "github argv":
  test "unknown commands are refused before any subprocess":
    let (ok, argv, refusal) = ghArgv("merge it", 0, "", 10)
    assert ok == false
    assert argv.len == 0
    assert "read-only" in refusal

  test "a hostile repo is refused, not escaped":
    let (ok, _, refusal) = ghArgv("pr list", 0, "o/r; rm -rf ~", 10)
    assert ok == false
    assert "owner/name" in refusal

  test "views need a positive number":
    assert ghArgv("pr view", 0, "", 10)[2].contains("positive")
    assert ghArgv("issue view", -3, "", 10)[0] == false

  test "list commands clamp the limit and ask for JSON":
    let (ok, argv, _) = ghArgv("pr list", 0, "o/r", 999)
    assert ok == true
    assert argv == @["gh", "pr", "list", "--repo", "o/r", "--limit", "50",
      "--json", ghJsonFields]

  test "a view carries its number":
    let (ok, argv, _) = ghArgv("pr diff", 12, "", 10)
    assert ok == true
    assert argv == @["gh", "pr", "diff", "12"]

suite "github_read":
  test "a list formats rows":
    let run = stubRun([("gh pr list --limit 10 --json " & ghJsonFields,
      (true, """[{"number": 7, "title": "Fix it",
        "author": {"login": "ana"}, "updatedAt": "2026-10-01T00:00:00Z",
        "url": "https://x/7"}]"""))])
    let text = ghRead(run, "pr list", 0, "", 10)
    assert "#7 Fix it — @ana (updated 2026-10-01)" in text

  test "an empty list says none open":
    let run = stubRun([("gh issue list --limit 10 --json " & ghJsonFields,
      (true, "[]"))])
    assert ghRead(run, "issue list", 0, "", 10) == "(none open)"

  test "non-JSON from gh is reported with a sample":
    let run = stubRun([("gh pr list --limit 10 --json " & ghJsonFields,
      (true, "not json at all"))])
    assert "not JSON" in ghRead(run, "pr list", 0, "", 10)

  test "a runner failure is the reply":
    let run = stubRun([("gh pr view 3", (false, "gh auth trouble"))])
    assert "gh auth trouble" in ghRead(run, "pr view", 3, "", 10)

  test "long output truncates with a terminal pointer":
    let run = stubRun([("gh pr diff 3", (true, "x".repeat(ghMaxChars + 5)))])
    let text = ghRead(run, "pr diff", 3, "", 10)
    assert "truncated at 8000 chars" in text
    assert "in a terminal" in text
