## Pins for the Obsidian vault backend — files, not a service
## (`nim/src/obsidian.nim`).
##
## The conformance suite in `test_episodes.nim` proves the ADAPTER obeys the
## contract, against a temp vault. This file proves the VAULT mechanics no
## contract can state: filenames that cannot escape, frontmatter that degrades
## instead of crashing, and keyword parity with the Notion scan.
##
## Offline by construction: temp dirs only, no network, no account — which is
## the whole point of Obsidian over Notion.

import std/os
import std/strutils
import std/unittest

import ../src/episodes
import ../src/obsidian

proc freshVault(name: string): tuple[store: ObsidianStore, dir: string] =
  result.dir = getTempDir() / ("waku-obsidian-" & name)
  if dirExists(result.dir):
    removeDir(result.dir)
  result.store = newObsidianStore(result.dir)

suite "filenames":
  test "sanitize keeps runs, drops everything else, never empties":
    assert sanitizePart("Sailed Around the Island!") == "sailed-around-the-island"
    assert sanitizePart("../../SOUL.md") == "soul-md"
    assert sanitizePart("") == "note"
    assert sanitizePart("!!!") == "note"
    assert sanitizePart("2026-09-28 10:00") == "2026-09-28-10-00"

  test "stamps are flat dates, undated when there is no date":
    assert stampOf("2026-09-28 10:00") == "2026-09-28-10-00"
    assert stampOf("") == "undated"

  test "add writes date-slug notes and returns vault-relative ids":
    let (store, dir) = freshVault("names")
    let id = store.addNote("sailed around the island", "2026-09-01 10:00")
    assert id == "2026-09-01-10-00-sailed-around-the-island.md", "got: " & id
    assert fileExists(dir / "waku" / "episodes" / id)
    removeDir(dir)

  test "collisions count up instead of clobbering":
    let (store, dir) = freshVault("collide")
    let first = store.addNote("same summary", "2026-09-01 10:00")
    let second = store.addNote("same summary", "2026-09-01 10:00")
    assert first != second, "second write ate the first"
    assert store.scanNotes().len == 2
    removeDir(dir)

  test "a traversal summary dies in the slug":
    let (store, dir) = freshVault("traverse")
    let id = store.addNote("../../SOUL", "2026-09-01 10:00")
    assert "/" notin id and ".." notin id, "escaped the episodes dir: " & id
    assert fileExists(dir / "waku" / "episodes" / id)
    assert not fileExists(dir / "SOUL.md")
    removeDir(dir)

suite "frontmatter":
  test "round-trips happened_at and body":
    let (store, dir) = freshVault("roundtrip")
    discard store.addNote("sailed around the island", "2026-09-01 10:00")
    let notes = store.scanNotes()
    assert notes.len == 1
    assert notes[0].happenedAt == "2026-09-01 10:00"
    assert notes[0].summary == "sailed around the island"
    removeDir(dir)

  test "a hand-edited note without frontmatter still reads":
    let (store, dir) = freshVault("handmade")
    createDir(store.root)
    writeFile(store.root / "random-thoughts.md", "just some words, no frontmatter")
    let notes = store.scanNotes()
    assert notes.len == 1
    assert notes[0].summary == "just some words, no frontmatter"
    assert notes[0].happenedAt.len > 0, "mtime fallback must fill the date"
    removeDir(dir)

  test "a broken frontmatter block degrades instead of dying":
    let (store, dir) = freshVault("broken")
    createDir(store.root)
    writeFile(store.root / "broken.md", "---\nhappened_at: never closed\nbody here")
    let notes = store.scanNotes()
    assert notes.len == 1, "one bad note must not empty the scan"
    removeDir(dir)

  test "unreadable locations read as empty, never raise":
    let store = newObsidianStore("/proc/definitely-not-here-" & $getCurrentProcessId())
    assert store.scanNotes() == @[]
    assert store.obsidianEpisodeStore().recent(3) == @[]
    assert store.obsidianEpisodeStore().list(10) == @[]

suite "deletion stays inside":
  test "missing, empty, absolute and climbing ids are false":
    let (store, dir) = freshVault("delete")
    discard store.addNote("sailed", "2026-09-01 10:00")
    assert store.deleteNote("no-such-note.md") == false
    assert store.deleteNote("") == false
    assert store.deleteNote("/etc/hostname") == false
    assert store.deleteNote("../SOUL.md") == false
    assert store.deleteNote("..") == false
    assert store.scanNotes().len == 1, "a refused delete must not touch rows"
    removeDir(dir)

  test "a real id deletes exactly its note":
    let (store, dir) = freshVault("deleteral")
    let id = store.addNote("sailed", "2026-09-01 10:00")
    discard store.addNote("hiked", "2026-09-02 10:00")
    assert store.deleteNote(id) == true
    assert store.deleteNote(id) == false, "second delete of the same id"
    assert store.scanNotes().len == 1
    removeDir(dir)

suite "search parity":
  test "keywords match whole words, newest first, empty falls back":
    let (store, dir) = freshVault("search")
    let episodes = store.obsidianEpisodeStore()
    episodes.add("sailed around the island", "2026-09-01 10:00")
    episodes.add("island hopping by boat", "2026-09-05 10:00")
    episodes.add("hiked the ridge trail", "2026-09-06 10:00")
    let hits = episodes.search("island boat", 8)
    assert hits.len == 2, "both island notes, not the hike: " & $hits
    assert "hopping" in hits[0], "newest first: " & $hits
    assert episodes.search("", 3).len == 3, "empty query reads recent"
    assert episodes.search("xyzzy", 3) == @[]
    removeDir(dir)
