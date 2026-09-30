## Phase 5a tests: skill distribution — `rawSkillUrl`, `installSkill`,
## `listDistribSkills`, `exportSkills`, `parseExportArgs`.
## Offline only: install runs against an injected fetch stub, export
## against temp homes with the cwd pinned to a temp root (so the bundled
## skill walk finds nothing outside the temp tree), no network.

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

suite "phase 5a listDistribSkills":
  test "home wins over bundled; roots, _incoming and invalid are skipped":
    let root = freshDir("waku-skill-list")
    let bundled = root / "bundled-skills"
    createDir(bundled / "alpha")
    writeFile(bundled / "alpha" / "SKILL.md",
      "---\nname: alpha\ndescription: bundled\n---\n\nbundled\n")
    createDir(bundled / "beta")
    writeFile(bundled / "beta" / "SKILL.md",
      "---\nname: beta\ndescription: b\n---\n\nbeta\n")
    let home = root / "home"
    createDir(home / "skills" / "alpha")
    writeFile(home / "skills" / "alpha" / "SKILL.md",
      "---\nname: alpha\ndescription: home\n---\n\nhome\n")
    createDir(home / "skills" / "_incoming")
    writeFile(home / "skills" / "_incoming" / "SKILL.md",
      "---\nname: incoming\ndescription: i\n---\n\nx\n")
    writeFile(home / "skills" / "SKILL.md",
      "---\nname: root-level\ndescription: r\n---\n\nx\n")
    createDir(home / "skills" / "invalid-folder")
    writeFile(home / "skills" / "invalid-folder" / "SKILL.md", "no frontmatter")
    let skills = listDistribSkills(home, @[bundled])
    assert skills.len == 2
    assert skills[0].name == "alpha"
    assert skills[0].path == absolutePath(home / "skills" / "alpha" / "SKILL.md")
    assert skills[1].name == "beta"
    removeDir(root)

suite "phase 5a exportSkills":
  test "copies, then unchanged, kept yours, and --force replaces":
    let savedDir = getCurrentDir()
    let root = freshDir("waku-skill-export")
    try:
      setCurrentDir(root)
      let home = root / "home"
      createDir(home / "skills" / "alpha")
      writeFile(home / "skills" / "alpha" / "SKILL.md",
        "---\nname: alpha\ndescription: a\n---\n\none\n")
      let base = root / "base"
      let dest = base / ".claude" / "skills" / "alpha"
      assert exportSkills(@["claude"], home, base, false) == @["  copied      " & dest]
      assert exportSkills(@["claude"], home, base, false) == @["  unchanged   " & dest]
      writeFile(dest / "SKILL.md", "---\nname: alpha\ndescription: a\n---\n\nedited\n")
      assert exportSkills(@["claude"], home, base, false) ==
        @["  kept yours  " & dest & " (it differs; --force replaces it)"]
      assert exportSkills(@["claude"], home, base, true) == @["  copied      " & dest]
      assert readFile(dest / "SKILL.md") == "---\nname: alpha\ndescription: a\n---\n\none\n"
      assert readFile(dest / "SKILL.md") != "edited\n"
    finally:
      setCurrentDir(savedDir)
      if dirExists(root):
        removeDir(root)

  test "memory target raises the python message":
    try:
      discard exportSkills(@["memory"], "/tmp/waku-nowhere", "/tmp/waku-nowhere", false)
      assert false, "must raise"
    except CatchableError as exc:
      assert exc.msg ==
        "Exporting skills to Waku Memory is not available yet: Waku Memory is adding " &
        "a place for skills first. For now: --to claude,codex"

  test "unknown target raises the python message":
    try:
      discard exportSkills(@["muse"], "/tmp/waku-nowhere", "/tmp/waku-nowhere", false)
      assert false, "must raise"
    except CatchableError as exc:
      assert exc.msg == "Unknown target: muse. Choose from: claude, codex"

  test "empty targets raise the python message":
    try:
      discard exportSkills(@[], "/tmp/waku-nowhere", "/tmp/waku-nowhere", false)
      assert false, "must raise"
    except CatchableError as exc:
      assert exc.msg == "Unknown target: (none). Choose from: claude, codex"

suite "phase 5a parseExportArgs":
  test "defaults: claude, no project, no force":
    let (targets, project, force) = parseExportArgs(@[])
    assert targets == @["claude"]
    assert not project and not force

  test "--to claude,codex plus --project and --force":
    let (targets, project, force) =
      parseExportArgs(@["--to", "claude,codex", "--project", "--force"])
    assert targets == @["claude", "codex"]
    assert project and force

  test "--to values are lowercased and trimmed":
    let (targets, _, _) = parseExportArgs(@["--to", " CODEX , "])
    assert targets == @["codex"]

  test "--to=claude equals form":
    let (targets, _, _) = parseExportArgs(@["--to=claude"])
    assert targets == @["claude"]

  test "unrecognized flag raises":
    try:
      discard parseExportArgs(@["--wat"])
      assert false, "must raise"
    except CatchableError as exc:
      assert "unrecognized arguments" in exc.msg
