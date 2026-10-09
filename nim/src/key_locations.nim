## key_locations — port of `waku/key_locations.py` (spec 013).
##
## WHERE A MODEL KEY WAS LOOKED FOR, in the order the
## places win, and what each place holds. The setup page
## and `waku connections` both say this, so a person whose
## key sits in a file Waku did not read learns where to
## put it instead of being told to paste a key they already
## have.
##
## WHAT THIS READS. Only the two `.env` files Waku loads
## at startup: the working directory's, found by walking
## upward, and `<home>/.env`. Values are read and dropped
## here; only names and yes-or-no leave this module, so no
## key ever reaches a return value. Every other file named
## here is checked for existence only — Waku never opens a
## `.env` it does not load, and the report says so.

import std/json
import std/os
import std/strutils
import std/tables

import ./config
import ./providers

proc tilde*(path, userHome: string): string =
  ## A path as a person reads it: their home folder shown
  ## as `~`. Port of `tilde`.
  if path == userHome:
    return "~"
  if path.startsWith(userHome & DirSep):
    return "~" & path[userHome.len .. ^1]
  path

proc worktreeMain*(cwd: string): string =
  ## The main checkout of the git worktree `cwd` sits in,
  ## or "" when `cwd` is not a linked worktree. A worktree's
  ## `.git` is a file whose one line reads
  ## `gitdir: <main>/.git/worktrees/<name>`; this walks up
  ## to the first `.git`, as git does, and reads it only
  ## when it is a file. Port of `_worktree_main`.
  var folder = cwd
  while true:
    let marker = folder / ".git"
    if dirExists(marker):
      return ""
    if fileExists(marker):
      var line = ""
      try:
        line = readFile(marker).strip()
      except IOError:
        return ""
      if not line.startsWith("gitdir:"):
        return ""
      var raw = line
      raw.removePrefix("gitdir:")
      raw = raw.strip()
      let gitdir =
        if isAbsolute(raw):
          raw
        else:
          folder / raw
      let worktreesDir = parentDir(gitdir)
      let mainGitDir = parentDir(worktreesDir)
      if worktreesDir.split(DirSep)[^1] != "worktrees" or
          mainGitDir.split(DirSep)[^1] != ".git":
        return ""
      return parentDir(mainGitDir)
    let parent = parentDir(folder)
    if parent == folder:
      return ""
    folder = parent

proc namesWithValues*(path: string): seq[string] =
  ## The names in a `.env` file that hold a non-empty
  ## value. Port of the `dotenv_values` check: the file's
  ## values are read and discarded here; only the names
  ## leave this function.
  result = @[]
  if not fileExists(path):
    return
  var f: File
  if not open(f, path, fmRead):
    return
  defer: close(f)
  for line in f.lines():
    let (name, value) = parseDotenvLine(line)
    if name.len > 0 and value.len > 0:
      result.add(name)

proc modelKeyNames*(providers: seq[Provider]): seq[string] =
  ## The variables that count as a model key: every
  ## visible provider's `key_env`, the same rows the
  ## setup gate's provider cards are built from. Port of
  ## `_model_key_names`.
  result = @[]
  for p in providers:
    if p.isVisible() and p.keyEnv.len > 0:
      result.add(p.keyEnv)

proc modelKeyLocations*(cwd = getCurrentDir(),
    env: Table[string, string], userHome = getHomeDir(),
    startupNames: seq[string] = startupEnvNames,
    providers: seq[Provider]): JsonNode =
  ## Port of `model_key_locations`: the places Waku looked
  ## for a model key, in the order they win (spec 013).
  ## `env` is the process environment and `startupNames`
  ## the names set before any `.env` was loaded, so a key
  ## that came from a file is not reported as coming from
  ## the environment. Paths and yes-or-no only: no value
  ## is ever returned.
  let keys = modelKeyNames(providers)
  let home = resolveHome(env, cwd, userHome)
  let homeEnv = home.path / ".env"

  proc fileState(path: string): tuple[state: string, hasKey: bool] =
    if not fileExists(path):
      return ("not found.", false)
    for name in namesWithValues(path):
      if name in keys:
        return ("found, with a model key in it.", true)
    return ("found, with no model key in it.", false)

  var envHas = false
  for name in keys:
    if name in startupNames:
      envHas = true
      break

  var places: seq[JsonNode] = @[]
  places.add(%*{"where": "Environment variables", "path": false,
    "state": (if envHas: "a model key is set." else: "no model key."),
    "has_key": envHas})

  let found = findDotenv(cwd)
  if found.len > 0:
    let st = fileState(found)
    places.add(%*{"where": tilde(found, userHome), "path": true,
      "state": st.state, "has_key": st.hasKey})
  else:
    places.add(%*{"where": tilde(cwd / ".env", userHome), "path": true,
      "state": "not found, and no folder above it has a .env.",
      "has_key": false})

  if found.len > 0 and
      absolutePath(found) == absolutePath(homeEnv):
    places.add(%*{"where": tilde(homeEnv, userHome), "path": true,
      "state": "the same file as above.", "has_key": false})
  else:
    let st = fileState(homeEnv)
    places.add(%*{"where": tilde(homeEnv, userHome), "path": true,
      "state": st.state, "has_key": st.hasKey})

  # A file Waku never loads: the main checkout of this
  # worktree, and the older home folders. Each is named
  # for existence only, with where to copy the key's line.
  var unread: seq[string] = @[]
  var readFiles: seq[string] = @[]
  if found.len > 0:
    readFiles.add(absolutePath(found))
  readFiles.add(absolutePath(homeEnv))

  let main = worktreeMain(cwd)
  if main.len > 0 and fileExists(main / ".env") and
      absolutePath(main / ".env") notin readFiles:
    unread.add("This folder is a git worktree. Its main checkout has " &
      tilde(main / ".env", userHome) & ", and Waku does not read that " &
      "file from here. If your key is in that file, start Waku in " &
      tilde(main, userHome) & ", or copy the key's line into " &
      tilde(homeEnv, userHome) & ".")

  let legacyEnv = cwd / ".waku" / ".env"
  if fileExists(legacyEnv) and
      absolutePath(legacyEnv) notin readFiles:
    unread.add(tilde(legacyEnv, userHome) & " exists, and Waku does not " &
      "read it, because Waku now keeps its files in " &
      tilde(home.path, userHome) & ". If your key is in that file, copy " &
      "the key's line into " & tilde(homeEnv, userHome) & ".")

  let globalEnv = userHome / ".waku" / ".env"
  if home.rule != "global" and fileExists(globalEnv) and
      absolutePath(globalEnv) notin readFiles and
      absolutePath(globalEnv) != absolutePath(legacyEnv):
    let why = if home.rule == "WAKU_HOME":
      "WAKU_HOME points Waku at"
    else:
      "the older memory in this folder makes Waku use"
    unread.add(tilde(globalEnv, userHome) & " exists, and Waku does not " &
      "read it, because " & why & " " & tilde(home.path, userHome) &
      ". If your key is in that file, copy the key's line into " &
      tilde(homeEnv, userHome) & ".")

  var anyKey = false
  for place in places:
    if place["has_key"].getBool():
      anyKey = true

  # A file holds a key the running process never loaded:
  # someone edited it after Waku started, and only a
  # restart reads it.
  var fileKey = false
  for i in 1 ..< places.len:
    if places[i]["has_key"].getBool():
      fileKey = true
  var envKey = false
  for name in keys:
    if env.getOrDefault(name, "").len > 0:
      envKey = true
  let restart =
    if fileKey and not envKey:
      "A file above holds a model key that this running Waku has not " &
        "read. Restart Waku to read it."
    else:
      ""

  let target = envWriteTarget(env, cwd, userHome)
  let saveTo = tilde(target.path, userHome)
  let saveNote =
    if target.isHome:
      "A key you paste here is written to " & saveTo &
        ", so Waku finds it from any folder."
    else:
      "A key you paste here is written to " & saveTo &
        ". Waku reads that file only when you start it in " &
        tilde(parentDir(target.path), userHome) &
        " or a folder inside it."

  let intro =
    if anyKey:
      "Waku looked for a model key in these places, in this order:"
    else:
      "Waku looked for a model key in these places, in this order, " &
        "and found none:"

  %*{"intro": intro, "places": places, "unread": unread,
     "restart": restart, "save_to": saveTo, "save_note": saveNote}

proc cliLines*(report: JsonNode): seq[string] =
  ## The same report as plain lines, for `waku connections`.
  ## Paths and yes-or-no only: no value is printed. Port of
  ## `cli_lines`.
  result = @[]
  for place in report["places"]:
    result.add(place["where"].getStr() & ": " & place["state"].getStr())
  for line in report["unread"]:
    result.add(line.getStr())
  if report["restart"].getStr().len > 0:
    result.add(report["restart"].getStr())
  result.add("A key saved from the dashboard is written to " &
    report["save_to"].getStr() & ".")
