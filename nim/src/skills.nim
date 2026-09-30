## Skill distribution — port of `waku/memory/procedural/installer.py`
## (phase 5a): `rawSkillUrl` maps GitHub/Gist page URLs to raw-content
## URLs, `installSkill` fetches + validates + drops a SKILL.md into
## `<home>/skills/<name>/`. The fetch is injected, so tests run offline;
## the real HTTP GET lives with the dispatch in `waku.nim`. Validation
## is reused from `memory_admin.validSkillText` — the same gate the
## loader and the create_skill tool run.
##
## Deliberate divergences vs Python (documented, not silent):
## - `installSkill` names the installed folder with the frontmatter name
##   as a lowercase slug (`Weekly Review` -> `weekly-review`), while
##   Python uses the raw frontmatter name. Skills are lowercase slugs
##   everywhere else in the port (createSkill's rule), so the installed
##   folder matches what the loader's trigger matching expects.
## - `installSkill` gates through `validSkillText`, which is stricter
##   than `_parse_text`: an empty description is rejected (see the
##   memory_admin.nim header for why).
## - frontmatter splitting below is plain string work (the loader's
##   regex stays inside `memory_admin`); the fields parse and the
##   `---` markers mean the same on both sides.

import std/os
import std/strutils

import ./memory_admin

type
  FetchFn* = proc(url: string): string {.closure.}
    ## One GET: url -> body text. Injected, so tests never touch the
    ## network; the dispatch wires the real `httpclient` fetch (15s
    ## timeout, like Python's `urlopen(raw, timeout=15)`).

proc rawSkillUrl*(url: string): string =
  ## Turn common GitHub/Gist page URLs into raw-content URLs.
  ## Port of `_raw_url` in `waku/memory/procedural/installer.py`.
  if "github.com" in url and "/blob/" in url:
    return url.replace("github.com", "raw.githubusercontent.com").replace("/blob/", "/")
  if "gist.github.com" in url and not url.endsWith("/raw"):
    return url.strip(leading = false, trailing = true, chars = {'/'}) & "/raw"
  return url

proc frontmatterOf(text: string): string =
  ## The frontmatter lines between the two `---` markers, without a
  ## regex here (see the header note).
  if not text.startsWith("---\n"):
    return ""
  let close = text.find("\n---\n", 4)
  if close < 0:
    return ""
  return text[4 ..< close]

proc frontmatterValue(front, key: string): string =
  ## One frontmatter field, whitespace and quotes stripped (Python's
  ## `k.strip(): v.strip().strip("'\"")` parsing).
  for line in front.splitLines():
    let parts = line.split(":", 1)
    if parts.len == 2 and parts[0].strip().toLowerAscii() == key:
      return parts[1].strip().strip(chars = {'\'', '"'})
  return ""

proc installSkill*(home, url: string, fetch: FetchFn): string =
  ## Fetch + validate + drop a SKILL.md into `<home>/skills/<name>/` via
  ## the `_incoming` staging folder. Port of `install` in installer.py:
  ## the folder is the frontmatter name as a lowercase slug, the file is
  ## written through `_incoming` and moved into place, and an invalid
  ## skill raises the same message Python's SystemExit prints.
  let raw = rawSkillUrl(url)
  echo "Fetching " & raw
  let text = fetch(raw)
  let incoming = home / "skills" / "_incoming"
  createDir(incoming)
  let tmp = incoming / "SKILL.md"
  writeFile(tmp, text)
  let front = frontmatterOf(text)
  if not validSkillText(text) or frontmatterValue(front, "name").len == 0:
    removeFile(tmp)
    raise newException(CatchableError,
      "Invalid skill: SKILL.md needs YAML frontmatter with `name` and `description`. " &
      "See skills/TEMPLATE.md in the repo.")
  let name = frontmatterValue(front, "name").strip().toLower().replace(" ", "-")
  let dest = home / "skills" / name / "SKILL.md"
  createDir(parentDir(dest))
  moveFile(tmp, dest)
  var empty = true  # Python: tmp.parent.rmdir() — only an empty staging dir goes
  for _ in walkDir(incoming):
    empty = false
    break
  if empty:
    removeDir(incoming)
  return "Installed '" & name & "' → " & dest & "\n  " &
    frontmatterValue(front, "description") & "\n" &
    "It loads next time Waku starts. Read it first — skills are instructions."
