## Episodic memory in your Obsidian vault — one note per event, no service.
##
## The port of the `notion` slot with local files instead of an API: each
## episode is a markdown note under `<vault>/waku/episodes/`, frontmatter
## carrying the date, the body carrying the summary. No dependency, no
## network, no secrets — and the memory becomes readable and editable by its
## owner in Obsidian, which a Notion database never is from here.
##
## ## One file per episode, not a daily note
##
## CRUD by id needs addressable notes: a section inside a daily note has no
## id to update or delete. The filename carries the date and a slug
## (`2026-09-28-1000-sailed-around-the-island.md`); the id is the path
## relative to the episodes dir, so it survives vault moves.
##
## ## Frontmatter tolerance
##
## A note the port did not write — edited by hand, an old format, a merge
## artifact — must never crash a turn. Missing `happened_at` falls back to
## the file's mtime; a broken frontmatter block is ignored and the whole body
## reads as the summary; an unreadable file is skipped. The scan is flat
## (no subdirs) and only `*.md`.
##
## ## Filenames cannot escape
##
## Summaries and dates become filename parts, so both are sanitized to
## `[a-z0-9-]` runs before they touch the disk, and `delete` resolves every
## id inside the episodes dir (`absolutePath` + prefix, the same discipline
## as the SKILL writes). `../../SOUL.md` as a summary writes a note literally
## named `so-ul-md` — the traversal dies in the slug.

import std/os
import std/algorithm
import std/re
import std/strutils
import std/times

import ./episodes

const
  episodeSubdir* = "waku/episodes"
    ## The port's own folder inside the vault. The vault root is never
    ## listed, read or written — a scan that escaped it could ingest a whole
    ## second brain, and a write that escaped it could clobber one.

type
  VaultNote* = object
    ## One parsed note: the row both the scan and the adapter read.
    id*: string
    happenedAt*: string
    summary*: string
    createdAt*: string

  ObsidianStore* = ref object
    ## One `<vault>/waku/episodes` dir. Missing dirs read as empty and are
    ## created on the first `add` — a fresh vault is not an error.
    root*: string

proc sanitizePart*(text: string, maxLen = 40): string =
  ## Anything-but-alphanumerics becomes one `-`: dates, summaries and slugs
  ## all pass through here before reaching the disk. Empty in, `"note"` out —
  ## a filename must never be empty and never carry a separator.
  var runs: seq[string] = @[]
  var cur = ""
  for ch in text.toLowerAscii():
    if ch in {'a'..'z', '0'..'9'}:
      cur.add(ch)
    elif cur.len > 0:
      runs.add(cur)
      cur = ""
  if cur.len > 0:
    runs.add(cur)
  let slug = runs.join("-")
  if slug.len == 0: "note"
  elif slug.len > maxLen: slug[0 ..< maxLen]
  else: slug

proc stampOf*(happenedAt: string): string =
  ## The filename date: digits and dashes only, so any timestamp shape lands
  ## flat on every filesystem Obsidian supports.
  let clean = sanitizePart(happenedAt, 16)
  if clean == "note": "undated" else: clean

proc newObsidianStore*(vaultDir: string,
                       subdir = episodeSubdir): ObsidianStore =
  ObsidianStore(root: vaultDir / subdir)

proc fmtMtime*(path: string): string =
  ## A file's modification time in the same `yyyy-MM-dd HH:mm` shape the
  ## sqlite rows carry, so vault and sqlite dates sort and render alike.
  format(getLastModificationTime(path).local, "yyyy-MM-dd HH:mm")

proc parseNote*(root, path: string): tuple[ok: bool, note: VaultNote] =
  ## Read one note into a row. Never raises: an unreadable file is skipped
  ## by the caller, and a malformed one degrades (mtime for the date, whole
  ## body for the summary) instead of dying.
  var text: string
  try:
    text = readFile(path)
  except CatchableError:
    return (false, VaultNote())
  var happened = ""
  var body = text
  let lines = text.splitLines()
  if lines.len >= 2 and lines[0].strip() == "---":
    var closeAt = -1
    for i in 1 ..< lines.len:
      if lines[i].strip() == "---":
        closeAt = i
        break
    if closeAt > 0:
      for i in 1 ..< closeAt:
        let kv = lines[i].split(':', maxsplit = 1)
        if kv.len == 2 and kv[0].strip().toLowerAscii() == "happened_at":
          happened = kv[1].strip()
      body = lines[closeAt + 1 .. ^1].join("\n").strip()
  if happened.len == 0:
    try:
      happened = fmtMtime(path)
    except CatchableError:
      happened = ""
  var rel: string
  try:
    rel = relativePath(path, root).replace('\\', '/')
  except CatchableError:
    return (false, VaultNote())
  var created = ""
  try:
    created = fmtMtime(path)
  except CatchableError:
    discard
  (true, VaultNote(id: rel, happenedAt: happened, summary: body,
                   createdAt: created))

proc scanNotes*(store: ObsidianStore): seq[VaultNote] =
  ## Every `*.md` directly inside the root, newest `happened_at` first. A
  ## missing dir is empty, not an error; an unreadable note is skipped.
  result = @[]
  var paths: seq[string] = @[]
  try:
    for kind, path in walkDir(store.root):
      if kind == pcFile and path.toLowerAscii().endsWith(".md"):
        paths.add(path)
  except CatchableError:
    return result
  paths.sort()
  for path in paths:
    let (ok, note) = parseNote(store.root, path)
    if ok and note.summary.len > 0:
      result.add(note)
  result.sort(proc(a, b: VaultNote): int = cmp(b.happenedAt, a.happenedAt))

proc keywords*(query: string): seq[string] =
  ## `[a-zA-Z0-9]{2,}` runs, deduplicated in order — the same tokenization
  ## the Notion scan uses, so the parity is exact rather than approximate.
  result = @[]
  for m in query.toLowerAscii().findAll(re"[a-zA-Z0-9]{2,}"):
    if m notin result:
      result.add(m)

proc addNote*(store: ObsidianStore, summary, happenedAt: string): string =
  ## Write one note, creating the dir on demand. The filename is
  ## `<date>-<slug>.md` with a counter on collision; the returned id is the
  ## vault-relative path. Never raises: a failed write returns "".
  try:
    createDir(store.root)
  except CatchableError:
    return ""
  let base = stampOf(happenedAt) & "-" & sanitizePart(summary)
  var candidate = base & ".md"
  var n = 2
  while fileExists(store.root / candidate):
    candidate = base & "-" & $n & ".md"
    inc n
  let text = "---\nhappened_at: " & happenedAt.strip() &
    "\nsource: waku\n---\n\n" & summary.strip() & "\n"
  try:
    writeFile(store.root / candidate, text)
  except CatchableError:
    return ""
  candidate.replace('\\', '/')

proc deleteNote*(store: ObsidianStore, id: string): bool =
  ## Remove one note by its vault-relative id. Anything that does not
  ## resolve to a file strictly inside the root is `false`: missing, empty,
  ## absolute, or climbing out with `..`.
  if id.len == 0:
    return false
  let target = store.root / id
  var absRoot, absTarget: string
  try:
    absRoot = absolutePath(store.root)
    absTarget = absolutePath(target)
  except CatchableError:
    return false
  if absTarget != absRoot and
     not absTarget.startsWith(absRoot & DirSep):
    return false
  if not fileExists(absTarget):
    return false
  try:
    removeFile(absTarget)
    return true
  except CatchableError:
    return false

proc obsidianEpisodeStore*(store: ObsidianStore): EpisodeStore =
  ## The contract, over vault files. `search` scans bodies for keyword runs
  ## (Notion parity); an empty query falls back to `recent`, like both
  ## Python backends agree.
  result.add = proc(summary, happenedAt: string) =
    discard store.addNote(summary, happenedAt)

  result.recent = proc(topK: int): seq[string] =
    let notes = store.scanNotes()
    var hits: seq[string] = @[]
    for i in 0 ..< min(topK, notes.len):
      hits.add("(" & notes[i].happenedAt & ") " & notes[i].summary)
    hits

  result.search = proc(query: string, topK: int): seq[string] =
    let keys = keywords(query)
    if keys.len == 0:
      return store.obsidianEpisodeStore().recent(topK)
    var hits: seq[string] = @[]
    for note in store.scanNotes():
      let lowered = note.summary.toLowerAscii()
      var any = false
      for k in keys:
        if find(lowered, re("\\b" & k & "\\b")) >= 0:
          any = true
          break
      if any:
        hits.add("(" & note.happenedAt & ") " & note.summary)
      if hits.len >= topK:
        break
    hits

  result.list = proc(limit: int): seq[EpisodeRec] =
    let notes = store.scanNotes()
    var recs: seq[EpisodeRec] = @[]
    for i in 0 ..< min(limit, notes.len):
      recs.add(EpisodeRec(id: notes[i].id, happenedAt: notes[i].happenedAt,
                          summary: notes[i].summary,
                          createdAt: notes[i].createdAt))
    recs

  result.delete = proc(id: EpisodeId): bool =
    store.deleteNote(id)
