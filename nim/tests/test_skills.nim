## Phase 5a tests: skill distribution — `rawSkillUrl`, `installSkill`.
## Offline only: install runs against an injected fetch stub, no network.

import std/os
import std/strutils
import std/unittest

import ../src/skills

const validSkillMd = """---
name: test-skill
description: a skill for tests
---

1. do the thing
"""

proc fetchOk(_: string): string =
  ## The injected fetch: no socket, just the known-good SKILL.md.
  validSkillMd

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "phase 5a rawSkillUrl":
  test "github blob page becomes a raw url":
    assert rawSkillUrl("https://github.com/u/r/blob/main/skills/foo/SKILL.md") ==
      "https://raw.githubusercontent.com/u/r/main/skills/foo/SKILL.md"

  test "gist page gains /raw":
    assert rawSkillUrl("https://gist.github.com/u/abc123") ==
      "https://gist.github.com/u/abc123/raw"

  test "gist raw url passes through":
    assert rawSkillUrl("https://gist.github.com/u/abc123/raw") ==
      "https://gist.github.com/u/abc123/raw"

  test "trailing slash on a gist still gains one /raw":
    assert rawSkillUrl("https://gist.github.com/u/abc123/") ==
      "https://gist.github.com/u/abc123/raw"

  test "github tree url without blob passes through":
    assert rawSkillUrl("https://github.com/u/r") == "https://github.com/u/r"

  test "any other url passes through":
    assert rawSkillUrl("https://example.com/SKILL.md") == "https://example.com/SKILL.md"

suite "phase 5a installSkill":
  test "valid skill lands in home/skills with the python message":
    let home = freshDir("waku-skill-install")
    let msg = installSkill(home,
      "https://github.com/u/r/blob/main/skills/test-skill/SKILL.md", fetchOk)
    let dest = home / "skills" / "test-skill" / "SKILL.md"
    assert msg == "Installed 'test-skill' → " & dest &
      "\n  a skill for tests" &
      "\nIt loads next time Waku starts. Read it first — skills are instructions."
    assert readFile(dest) == validSkillMd
    assert not dirExists(home / "skills" / "_incoming")
    removeDir(home)

  test "frontmatter name becomes a lowercase slug":
    let home = freshDir("waku-skill-install-slug")
    let md = "---\nname: Weekly Review\ndescription: review the week\n---\n\nbody\n"
    let msg = installSkill(home, "https://example.com/SKILL.md",
                           proc(url: string): string = md)
    assert "Installed 'weekly-review' →" in msg
    assert fileExists(home / "skills" / "weekly-review" / "SKILL.md")
    assert not dirExists(home / "skills" / "Weekly Review")
    removeDir(home)

  test "invalid skill raises the python message and cleans the staging file":
    let home = freshDir("waku-skill-install-bad")
    try:
      discard installSkill(home, "https://example.com/SKILL.md",
                           proc(url: string): string = "no frontmatter here")
      assert false, "must raise"
    except CatchableError as exc:
      assert exc.msg ==
        "Invalid skill: SKILL.md needs YAML frontmatter with `name` and `description`. " &
        "See skills/TEMPLATE.md in the repo."
    assert not fileExists(home / "skills" / "_incoming" / "SKILL.md")
    removeDir(home)
