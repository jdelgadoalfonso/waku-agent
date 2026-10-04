## Skill distribution — port of `waku/memory/procedural/installer.py` and
## `exporter.py` (phase 5a).
##
## `rawSkillUrl` maps GitHub/Gist page URLs to raw-content URLs,
## `installSkill` fetches + validates + drops a SKILL.md into
## `<home>/skills/<name>/` (the fetch is injected, so tests run offline),
## `listDistribSkills`/`exportSkills` carry skills to other agents'
## folders, `parseExportArgs` parses the `skill export` flags. The real
## HTTP GET lives with the dispatch in `waku.nim`. Validation is reused
## from `memory_admin.validSkillText` — the same gate the loader and the
## create_skill tool run.
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
## - `skill export` arg/file errors print to stderr and exit 1, while
##   Python prints the arg errors to stdout (real I/O failures there are
##   uncaught tracebacks on stderr); parse errors exit 1 (Python argparse
##   exits 2; messages mirror argparse).
## - `bundledSkillDirs` walks the caller's working directory (repo
##   checkout layouts, the `findProvidersToml` convention) and the
##   binary directory last; Python resolves from the package file's
##   location. Exactly one candidate exists per install source, so this
##   is "wherever you installed from, the skills came too", not a
##   double-load.
## - frontmatter splitting below is plain string work (the loader's
##   regex stays inside `memory_admin`); the fields parse and the
##   `---` markers mean the same on both sides, but key matching is
##   case-insensitive in Nim (via `validSkillText` in memory_admin.nim)
##   vs case-sensitive in Python (loader.py); in practice the spec keys
##   are lowercase.

import std/algorithm
import std/os
import std/strutils

import ./memory_admin

type
  FetchFn* = proc(url: string): string {.closure.}
    ## One GET: url -> body text. Injected, so tests never touch the
    ## network; the dispatch wires the real `httpclient` fetch (15s
    ## timeout, like Python's `urlopen(raw, timeout=15)`).

  SkillInfo* = object
    name*: string
    path*: string
    ## Absolute path of the skill's SKILL.md; its folder is the copy source.

proc rawSkillUrl*(url: string): string =
  ## Turn common GitHub/Gist page URLs into raw-content URLs.
  ## Port of `_raw_url` in `waku/memory/procedural/installer.py`.
  if "github.com" in url and "/blob/" in url:
    return url.replace("github.com", "raw.githubusercontent.com").replace("/blob/", "/")
  if "gist.github.com" in url and not url.endsWith("/raw"):
    return url.strip(leading = false, trailing = true, chars = {'/'}) & "/raw"
  return url

proc frontmatterOf*(text: string): string =
  ## The frontmatter lines between the two `---` markers, without a
  ## regex here (see the header note).
  if not text.startsWith("---\n"):
    return ""
  let close = text.find("\n---\n", 4)
  if close < 0:
    return ""
  return text[4 ..< close]

proc frontmatterValue*(front, key: string): string =
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

proc findSkillFiles(root: string): seq[string] =
  ## Every SKILL.md under root, sorted (Python: `sorted(d.rglob("SKILL.md"))`).
  if not dirExists(root):
    return @[]
  for f in walkDirRec(root, {pcFile}):
    if extractFilename(f) == "SKILL.md":
      result.add(f)
  result.sort()

proc listDistribSkills*(home: string, bundled: seq[string]): seq[SkillInfo] =
  ## Every skill Waku loads, one per name. Port of `_skills` in
  ## exporter.py: bundled dirs first, then `<home>/skills`, skipping a
  ## SKILL.md that sits directly in a skills root (its "folder" would be
  ## the whole root) and the `_incoming` staging folder; a home skill
  ## wins over a bundled one of the same name, as it does when Waku
  ## loads them. Invalid SKILL.md files are skipped, like the loader.
  let dirs = bundled & @[home / "skills"]
  var roots: seq[string] = @[]
  for d in dirs:
    if dirExists(d):
      roots.add(absolutePath(d))
  var names: seq[string] = @[]
  for d in dirs:
    for f in findSkillFiles(d):
      let folder = absolutePath(parentDir(f))
      if folder in roots or "_incoming" in folder.split(DirSep):
        continue
      let text = readFile(f)
      if not validSkillText(text):
        continue
      let name = frontmatterValue(frontmatterOf(text), "name")
      if name.len == 0:
        continue  # cannot copy into `<root>/skills/` itself
      let info = SkillInfo(name: name, path: absolutePath(f))
      let idx = names.find(name)
      if idx >= 0:
        result[idx] = info  # later dir (home) wins, position kept
      else:
        names.add(name)
        result.add(info)

proc bundledSkillDirs*(): seq[string] =
  ## Where the skills that ship with Waku live. Port of
  ## `bundled_skill_dirs()` in `waku/memory/__init__.py` with the port's
  ## own location convention (`findProvidersToml`): the caller's working
  ## directory first (repo checkout layouts), the binary directory last.
  ## Exactly one exists per install source (see the header note).
  for candidate in ["skills", "../skills", "../../skills"]:
    if dirExists(candidate):
      result.add(candidate)
  let besideBin = getAppDir() / "skills"
  if dirExists(besideBin):
    result.add(besideBin)

proc targetDir(target: string): string =
  ## Target name -> the folder under your home (or the project) that
  ## holds `skills/`. Port of `TARGETS` in exporter.py.
  case target
  of "claude": ".claude"
  of "codex": ".codex"
  else: ""

proc fileSet(folder: string): seq[(string, string)] =
  ## Relative path -> bytes for every file under folder, skipping
  ## `__pycache__` and `.DS_Store` (Python's `_files`).
  for p in walkDirRec(folder, {pcFile}):
    if "__pycache__" in p.split(DirSep) or extractFilename(p) == ".DS_Store":
      continue
    result.add((relativePath(p, folder), readFile(p)))
  result.sort()

proc copySkillDir(src, dest: string) =
  ## Recursive copy skipping `__pycache__` and `.DS_Store` (Python's
  ## copytree ignore patterns).
  createDir(dest)
  for kind, path in walkDir(src):
    let name = extractFilename(path)
    if kind == pcDir:
      if name != "__pycache__":
        copySkillDir(path, dest / name)
    elif name != ".DS_Store":
      copyFile(path, dest / name)

proc exportSkills*(targets: seq[string], home, base: string, force: bool): seq[string] =
  ## Copy each skill folder to `<base>/<target>/skills/<name>/`, one line
  ## per copy. Port of `export` plus the target checks in exporter.py's
  ## `cli_main`: a copy that differs is kept unless `--force`, the
  ## `memory` target is unavailable, and unknown/empty targets raise the
  ## same messages Python prints before its exit 1.
  if "memory" in targets:
    raise newException(CatchableError,
      "Exporting skills to Waku Memory is not available yet: Waku Memory is adding " &
      "a place for skills first. For now: --to claude,codex")
  var unknown: seq[string] = @[]
  for t in targets:
    if targetDir(t).len == 0:
      unknown.add(t)
  if unknown.len > 0 or targets.len == 0:
    raise newException(CatchableError,
      "Unknown target: " & (if unknown.len > 0: unknown.join(", ") else: "(none)") &
      ". Choose from: claude, codex")
  let skills = listDistribSkills(home, bundledSkillDirs())
  result = @[]
  for target in targets:
    let root = base / targetDir(target) / "skills"
    for skill in skills:
      let src = parentDir(skill.path)
      let dest = root / skill.name
      if dirExists(dest):
        if fileSet(src) == fileSet(dest):
          result.add("  unchanged   " & dest)
          continue
        if not force:
          result.add("  kept yours  " & dest & " (it differs; --force replaces it)")
          continue
        removeDir(dest)
      copySkillDir(src, dest)
      result.add("  copied      " & dest)

proc parseExportArgs*(argv: seq[string]): (seq[string], bool, bool) =
  ## Parse the `skill export` flags. Port of exporter.py's `cli_main`
  ## argparse: `--to` (default claude, comma-separated, lowercased),
  ## `--project`, `--force`. Returns (targets, project, force); an
  ## unrecognized flag raises like argparse does.
  var to = "claude"
  var project = false
  var force = false
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a == "--to":
      if i + 1 >= argv.len:
        raise newException(CatchableError, "argument --to: expected one argument")
      to = argv[i + 1]
      inc i, 2  # the flag and its value
    elif a.startsWith("--to="):
      to = a[5 .. ^1]
      inc i
    elif a == "--project":
      project = true
      inc i
    elif a == "--force":
      force = true
      inc i
    else:
      raise newException(CatchableError, "unrecognized arguments: " & a)
  var targets: seq[string] = @[]
  for t in to.split(","):
    if t.strip().len > 0:
      targets.add(t.strip().toLowerAscii())
  return (targets, project, force)
