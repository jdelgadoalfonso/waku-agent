## Phase 2c tests: notes, outbox, memory self-management, skills.
## Offline only: temp homes under getTempDir(), no network.

import std/json
import std/os
import std/strutils
import std/unittest

import db_connector/db_sqlite

import ../src/db
import ../src/episodes
import ../src/factstore
import ../src/memory
import ../src/memory_admin
import ../src/messages
import ../src/notes
import ../src/tools

proc store(db: DbConn): FactStore =
  ## The contract over a fresh sqlite home, which is what every call site in
  ## this file now takes. One helper so the tests exercise the same path the
  ## agent does rather than the raw procs underneath it.
  sqliteFactStore(db)

proc freshDb(name: string): tuple[home: string, db: DbConn] =
  let home = getTempDir() / name
  if dirExists(home):
    removeDir(home)
  result = (home, connectDb(home))

suite "phase 2c save_note":
  test "stores lowercased and says where it went":
    let (home, db) = freshDb("waku-note")
    assert db.saveNote("  ALEX  ", "prefers mornings") ==
      "Saved here. Waku Memory is not connected."
    assert db.searchFacts("alex") == @["[alex] prefers mornings"]
    db.close()
    removeDir(home)

suite "phase 2c send_message":
  test "drafts a deterministic outbox file":
    let (home, db) = freshDb("waku-msg")
    let msg = sendMessage(home, "Amy Lee!", "see you at noon", "20260714T090000")
    assert msg == "Message to Amy Lee! placed in outbox " &
      "(20260714T090000-Amy-Lee-.txt). Nothing was sent — review it there."
    assert readFile(home / "outbox" / "20260714T090000-Amy-Lee-.txt") ==
      "To: Amy Lee!\n\nsee you at noon\n"
    assert safeName("a@b.c/d e", 40) == "a-b-c-d-e"
    db.close()
    removeDir(home)

suite "phase 2c manage_memory":
  test "fact search, update, delete with exact strings":
    let (home, db) = freshDb("waku-manage")
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    db.addFact("alex", "likes sailing")
    db.addFact("bob", "hates sailing")
    assert manageMemory(db, facts, episodes, "search", "fact", "0", "sailing") ==
      "#1 [alex] likes sailing\n#2 [bob] hates sailing"
    assert manageMemory(db, facts, episodes, "SEARCH", "fact", "0", "kayaks") == "no matching facts"
    assert manageMemory(db, facts, episodes, "update", "fact", "1", "", "loves kayaks") ==
      "Updated fact #1."
    assert manageMemory(db, facts, episodes, "update", "episode", "1") ==
      "Only facts can be updated (episodes are historical)."
    assert manageMemory(db, facts, episodes, "update", "fact", "999", "", "ghost") ==
      "No fact with id 999."
    assert manageMemory(db, facts, episodes, "delete", "fact", "2") == "Deleted fact #2."
    assert manageMemory(db, facts, episodes, "delete", "fact", "2") == "No fact with id 2."
    assert manageMemory(db, facts, episodes, "dance", "fact") ==
      "action must be one of: search, update, delete"
    db.close()
    removeDir(home)

  test "episode search filters substrings, delete removes by id":
    let (home, db) = freshDb("waku-manage-ep")
    let facts = store(db)
    let episodes = sqliteEpisodeStore(db)
    db.addEpisode("sailed the island", "2026-09-01")
    db.addEpisode("hiked the ridge", "2026-09-05")
    assert manageMemory(db, facts, episodes, "search", "episode", "0", "SAILED") ==
      "#1 (2026-09-01) sailed the island"
    assert manageMemory(db, facts, episodes, "search", "episode") ==
      "#2 (2026-09-05) hiked the ridge\n#1 (2026-09-01) sailed the island"
    assert manageMemory(db, facts, episodes, "search", "episode", "0", "zzz") == "no episodes"
    assert manageMemory(db, facts, episodes, "delete", "episode", "1") == "Deleted episode #1."
    assert manageMemory(db, facts, episodes, "delete", "episode", "1") == "No episode with id 1."
    db.close()
    removeDir(home)

suite "phase 2c update_soul":
  test "creates, sections, appends, and caps":
    let home = getTempDir() / "waku-soul"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    assert updateSoul(home, "") == "Nothing to add."
    assert updateSoul(home, "- speak pirate") ==
      "Noted, I'll remember to: speak pirate"
    let text = readFile(home / "SOUL.md")
    assert "## Learned rules" in text
    assert "- speak pirate" in text
    assert text.startsWith("You are Waku")
    discard updateSoul(home, "second rule")
    assert readFile(home / "SOUL.md").count("- speak pirate") == 1
    writeFile(home / "SOUL.md", "x".repeat(8001))
    assert updateSoul(home, "late rule") ==
      "SOUL.md is at its size limit — edit it in the dashboard instead."
    removeDir(home)

suite "phase 2c create_skill":
  test "rejects bad slugs and duplicates, writes valid skills":
    let home = getTempDir() / "waku-skill"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    assert createSkill(home, "Bad Name!", "d", "b") ==
      "Skill name must be a short slug like 'weekly-review' (lowercase, hyphens)."
    assert createSkill(home, "good", "", "  ") ==
      "That didn't validate — description must be present and non-trivial."
    assert createSkill(home, "weekly-review", "review the week",
                       "1. list\n2. digest") ==
      "Created skill 'weekly-review'. It will trigger on: review the week"
    let written = readFile(home / "skills" / "weekly-review" / "SKILL.md")
    assert written == "---\nname: weekly-review\ndescription: review the week\n---\n\n1. list\n2. digest\n"
    assert createSkill(home, "weekly-review", "other", "body") ==
      "A skill named 'weekly-review' already exists — pick another name."
    assert validSkillText(written)
    assert not validSkillText("no frontmatter here")
    removeDir(home)

suite "phase 2c registry wiring":
  test "all five tools run through the registry":
    let (home, db) = freshDb("waku-local-reg")
    var reg: ToolRegistry
    reg.register(makeSaveNoteTool(db))
    reg.register(makeSendMessageTool(home))
    reg.register(makeManageMemoryTool(db, store(db), sqliteEpisodeStore(db)))
    reg.register(makeUpdateSoulTool(home))
    reg.register(makeCreateSkillTool(home))
    assert reg.execute("save_note",
      %*{"subject": "alex", "content": "x"}) ==
      "Saved here. Waku Memory is not connected."
    assert "outbox" in reg.execute("send_message",
      %*{"to": "bob", "body": "hi"})
    assert reg.execute("manage_memory", %*{"action": "search",
      "query": "alex"}) == "#1 [alex] x"
    assert reg.execute("update_soul", %*{"rule": "r"}) ==
      "Noted, I'll remember to: r"
    assert reg.execute("create_skill", %*{"name": "ab", "description": "d",
      "body": "b"}).startsWith("Created skill")
    assert reg.schemas().len == 5
    db.close()
    removeDir(home)
