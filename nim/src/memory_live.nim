## Live memory — the layer that makes Waku remember between turns.
##
## Port of `waku/memory/__init__.py` (facade), `retrieval_gate.py` and
## `consolidation.py`, plus `Memory.export_markdown`. The stores
## themselves (`memory.nim`: facts/episodes CRUD over FTS5) already
## existed; what was missing was everything that USES them:
##
## - the gate: a cheap judge deciding IF a turn needs memory at all
##   (default-on retrieval is slow and biases answers);
## - gated retrieval: gate, then facts + episodes search;
## - skill matching: transparent keyword overlap, no embeddings;
## - consolidation: distill unconsolidated chats every N exchanges;
## - the MEMORY.md mirror, regenerated after every turn.
##
## `wireMemory` fills the nil-able seams (`Session.retrieve`/`skillsFor`,
## `Waku.afterTurn`) the session/app modules declared for this phase.
## Hosted backends (supabase/mem0/zep/langmem/notion) stay Python-only —
## the port's `Settings` carries no store switch, so sqlite answers
## honestly everywhere here.

import std/algorithm
import std/json
import std/os
import std/re
import std/sets
import std/strutils
import std/times
import std/unicode

import db_connector/db_sqlite

import ./app
import ./episodes
import ./factstore
import ./loop
import ./skills
import ./wire

const
  gatePrompt* = """You are a retrieval gate for a personal assistant's long-term memory.
Given the user's message, decide if answering well requires the user's stored
memories (facts about people, projects, preferences, or past events).

Reply with ONLY this JSON, nothing else:
{"retrieve": true/false, "query": "<search keywords if true, else empty>", "reason": "<5 words>"}

General knowledge, math, small talk, or self-contained requests → false.
Anything referencing the user's life, people, plans, or history → true.

User message: {message}"""
    ## Verbatim `GATE_PROMPT` (`{message}` fills like Python's
    ## `.format`; `triagePrompt` uses the same `formatTemplate` seam).

  summarizerPrompt* = """You distill a personal assistant's recent conversation into long-term memory.

From the exchanges below, extract:
1. durable facts about the user, their people, projects, or preferences —
   only things worth remembering in a month; skip chit-chat and one-offs.
2. one single-sentence episode summarizing what happened in this conversation.

Reply with ONLY this JSON:
{"facts": [{"subject": "<who/what>", "content": "<one sentence>"}], "episode": "<one sentence>"}

Exchanges:
{log}"""
    ## Verbatim `SUMMARIZER_PROMPT`.

  reportRule* = """

These exchanges saved a research report, so its findings are already kept
in the report. Do NOT extract facts about the companies, products or markets
it covers. Keep only facts about the user, their people, or a decision they
made, at most 2, and set "company_research" to false.
The report:
{report}"""
    ## Port of `REPORT_RULE` with `REPORT_TURN_MAX_FACTS` (= 2) written
    ## out, added to the prompt when the batch saved a report (spec 009 B).
  reportTurnMaxFacts* = 2

const
  recallRule* = """
These exchanges answered from memory that is already kept, quoted below. Do NOT
extract a fact it already holds, even reworded. Keep only what is new: what
the user said, decided or asked to note.
Memory read this turn:
{recalled}"""
    ## Added to the prompt when the turn answered from memory it read. The
    ## deterministic `restatesFact` check below is what guarantees the drop;
    ## this only saves the summariser proposing what would be dropped.
  recallPromptChars* = 6000
    ## How much of the recalled memory goes into the prompt. The
    ## `restatesFact` check reads all of it.
    ## The most loose facts a report turn keeps, whatever the model
    ## proposed (port of `REPORT_TURN_MAX_FACTS`).

proc formatPrompt*(prompt, message: string): string =
  ## The one substitution both prompts need (`{message}` / `{log}`).
  prompt.replace("{message}", message).replace("{log}", message)

proc shouldRetrieve*(client: LlmClient, smallModel,
    message: string): tuple[retrieve: bool, query, reason: string] =
  ## `(retrieve?, search_query, reason)`, failing open: a gate error — or
  ## a reply with no JSON — retrieves with the raw message, because a
  ## stale memory beats a lost one. The `{...}` slice mirrors Python's
  ## `text.index("{")` → `text.rindex("}")`.
  try:
    let req = %*{"model": smallModel, "max_tokens": 600,
                 "messages": @[%*{"role": "user",
                   "content": formatPrompt(gatePrompt, message)}]}
    let text = textOf(client.create(req)["content"])
    let a = text.find('{')
    if a < 0:
      return (true, message, "gate returned no JSON — failing open")
    let b = text.rfind('}')
    if b < a:
      return (true, message, "gate returned no JSON — failing open")
    let decision = parseJson(text[a .. b])
    return (decision.jget("retrieve").getBool(true),
            decision.jget("query").getStr(message),
            decision.jget("reason").getStr(""))
  except CatchableError as exc:
    return (true, message, "gate failed open (" & $exc.name & ")")

proc gatedRetrieve*(db: DbConn, facts: FactStore, episodes: EpisodeStore,
    client: LlmClient,
    smallModel: string, topK: int, message: string,
    notify: Observer = nil): string =
  ## Port of `Memory.gated_retrieve`: the gate decides (and is announced
  ## on `notify`, like Python), then facts plus 3 episodes join with
  ## newlines. "" means "nothing relevant" — or a skip. The gate's
  ## own call is metered, so its dollars reach the ledger like the loop's.
  let (retrieve, query, reason) = shouldRetrieve(
    meteredClient(client, "gate", smallModel, notify), smallModel,
    message)
  if not notify.isNil:
    notify("gate", %*{"decision": (if retrieve: "retrieve" else: "skip"),
                       "reason": reason})
  if not retrieve:
    return ""
  # Facts and episodes both through their contracts now: the episodic side
  # grew its own backend (Obsidian), so sqlite-direct reads here would
  # silently ignore the vault.
  var found = facts.search(query, topK)
  for e in episodes.search(query, 3):
    found.add(e)
  return found.join("\n")

proc skillWords(text: string): seq[string] =
  ## Lowercase `[a-z0-9]{3,}` runs, like Python's
  ## `re.findall(r"[a-z0-9]{3,}", message.lower())` (unicode-lowered
  ## first, so `ß` behaves the same there as here).
  var cur = ""
  for r in text.toLower().runes:
    if r.ord < 128:
      let c = chr(r.ord)
      if c in {'a' .. 'z', '0' .. '9'}:
        cur.add(c)
        continue
    if cur.len >= 3:
      result.add(cur)
    cur = ""
  if cur.len >= 3:
    result.add(cur)

proc scoredSkills*(home: string, bundled: seq[string],
    message: string): seq[(int, string, string)] =
  ## (overlap, name, body), best first: the shared scorer behind
  ## `matchingSkills` and the research detector, so both read the same
  ## match and cannot drift from each other.
  let msgWords = skillWords(message)
  result = @[]
  for info in listDistribSkills(home, bundled):
    var text = ""
    try:
      text = readFile(info.path)
    except IOError:
      continue
    let desc = frontmatterValue(frontmatterOf(text), "description")
    let skillSet = skillWords(info.name & " " & desc)
    var overlap = 0
    for w in msgWords:
      if w in skillSet:
        inc overlap
    if overlap >= 2:
      let lines = text.splitLines()
      var body = ""
      var bars = 0
      var k = 0
      for i, line in lines:
        if line.strip() == "---":
          inc bars
          if bars == 2:
            k = i + 1
            break
      if bars == 2:
        body = lines[k .. ^1].join("\n").strip()
      result.add((overlap, info.name, body))
  result.sort(proc(a, b: (int, string, string)): int = cmp(b[0], a[0]))

proc matchingSkillNames*(home: string, bundled: seq[string],
    message: string): seq[string] =
  ## Every matched skill name, best first, uncapped: the research detector
  ## asks whether the skill fired at all, not whether it made the top two.
  for (_, name, _) in scoredSkills(home, bundled, message):
    result.add(name)

proc matchingSkills*(home: string, bundled: seq[string],
    message: string, maxSkills = 2): string =
  ## Port of `Memory.matching_skills`: `### name\\nbody` per skill whose
  ## name+description share 2+ keywords with the message (best first).
  ## `listDistribSkills` reads disk on every call, so an added skill is
  ## live next turn — Python's rescan-on-change, without the cache.
  var chunks: seq[string] = @[]
  let scored = scoredSkills(home, bundled, message)
  for i in 0 ..< min(maxSkills, scored.len):
    chunks.add("### " & scored[i][1] & "\n" & scored[i][2])
  return chunks.join("\n\n")

proc aboutReport*(fact: JsonNode, report: string): bool =
  ## A fact whose subject the report names is a finding, and the report
  ## already holds it: "Mem0" in a report on mem0's competitors. Port of
  ## `_about_report` (whole-word, case-insensitive; a subject shorter than
  ## two characters never matches).
  let subject = strutils.splitWhitespace(
    fact.jget("subject").getStr()).join(" ")
  if subject.len < 2:
    return false
  var rx = "(?<!\\w)"
  for r in subject.runes:
    let c = chr(r.ord)
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      rx.add(c)
    else:
      rx.add("\\" & c)
  rx.add("(?!\\w)")
  try:
    let found = report.replace("\n", " ").findAll(
      re(rx, flags = {reIgnoreCase}))
    return found.len > 0
  except RegexError:
    false

proc recallWords*(text: string): HashSet[string] =
  ## The words of a text, lowercased, as `restatesFact` compares them:
  ## `"$10M,"` is `"10m"`, `"Mem0's"` is `"mem0"`, and a date like
  ## `2026-10-05` stays one word, so it never matches a bare `2026`. Port of
  ## `_words` (escaped line breaks and apostrophes read as the characters
  ## they are — a tool's answer is often JSON).
  ##
  ## Case runs on ASCII (`isUpperAscii`): a non-ASCII capital is not a name
  ## here, while Python counts it. The suite is ASCII; the divergence only
  ## matters for words like `"Ünter"`, which keep their fact instead of
  ## dropping it — the safe direction.
  let readable = text.replace("\\n", " ").replace("\\r", " ")
    .replace("\\t", " ").replace("\\u2019", "'").replace("\u2019", "'")
  result = initHashSet[string]()
  for word in readable.findAll(re"[\w$'.,%-]+"):
    var w = word.strip(leading = true, trailing = true, chars = {'\'', '.', ',', '-'})
    w = w.strip(leading = true, trailing = false, chars = {'$'}).toLowerAscii()
    if w.endsWith("'s"):
      w = w[0 .. ^3]
    if w.len > 0:
      result.incl(w)

proc restatesFact*(content, recalled: string): bool =
  ## True when the fact only repeats memory the turn read: it has a number
  ## or a date, and every name, number and date in it (each word with a
  ## capital letter or a digit) is already in `recalled`. Port of `restates`.
  ##
  ## `"Zep raised a $2.3M pre-seed round on 2023-12-27."` restates a report
  ## that holds Zep, $2.3M and 2023-12-27. `"Zep raised again in 2026"`
  ## does not: 2026 is new. A fact with no number is never dropped here,
  ## however familiar its names — something new the user says is never lost;
  ## RECALL_RULE asks the summariser to leave those out instead.
  let clean = content.replace("\u2019", "'")
  # Normalized FIRST, like Python's `_words(" ".join(...))`: the number
  # test reads `"10m"`, not `"$10M"` — checking raw tokens would miss a
  # fact whose only number wears a `$`.
  var key = initHashSet[string]()
  for w in strutils.splitWhitespace(clean):
    var signal = false
    for ch in w:
      if ch.isUpperAscii or ch.isDigit:
        signal = true
        break
    if signal:
      for part in recallWords(w):
        key.incl(part)
  var hasNumber = false
  for w in key:
    if w.len > 0 and w[0].isDigit:
      hasNumber = true
      break
  if not hasNumber:
    return false
  let known = recallWords(recalled)
  for w in key:
    if w notin known:
      return false
  true

proc consolidationPrompt*(log, reportBody, recalled: string): string =
  ## The summarizer prompt: log, plus the report rule, plus the recall rule
  ## (capped). Extracted so tests pin the rules without spending a model
  ## call — the prompt only SAVES proposals, the `restatesFact` filter is
  ## what guarantees the drop.
  result = formatPrompt(summarizerPrompt, log)
  if reportBody.len > 0:
    result = result & reportRule.replace("{report}", reportBody)
  if recalled.len > 0:
    result = result & recallRule.replace("{recalled}",
      recalled[0 ..< min(recalled.len, recallPromptChars)])

proc consolidateIfDue*(db: DbConn, facts: FactStore, episodes: EpisodeStore,
    client: LlmClient,
    smallModel: string, everyN: int, notify: Observer = nil,
    reportBody: string = "", recalled: string = ""): int =
  ## Port of `consolidate_if_due`: fewer than `everyN` exchanges (2 rows
  ## each) pending means not due. A distilled fact needs subject AND
  ## content; the log rows flip to consolidated only after the writes —
  ## a failure anywhere keeps them pending for next time, never loses
  ## them. Returns new facts written. `reportBody` is the research report
  ## this turn saved (spec 009 B): the prompt then caps the batch at two
  ## facts about the person and drops what the report already holds.
  ## `recalled` is the memory this turn read (the gate's text, retained by
  ## the wiring): a proposed fact that only restates it is dropped, and the
  ## prompt carries the rule. Empty disables both — the old behavior.
  var rows: seq[Row] = @[]
  for row in db.getAllRows(sql(
      "SELECT id, role, content FROM chat_log WHERE consolidated = 0 " &
      "ORDER BY id")):
    rows.add(row)
  if rows.len < everyN * 2:
    return 0
  var log: seq[string] = @[]
  for r in rows:
    log.add(r[1] & ": " & r[2])
  var distilled: JsonNode
  let prompt = consolidationPrompt(log.join("\n"), reportBody, recalled)
  try:
    let req = %*{"model": smallModel, "max_tokens": 4096,
                 "messages": @[%*{"role": "user",
                   "content": prompt}]}
    let text = textOf(meteredClient(client, "consolidation",
      smallModel, notify).create(req)["content"])
    if '{' notin text:
      return 0
    distilled = parseJson(text[text.find('{') .. text.rfind('}')])
  except CatchableError:
    return 0
  var count = 0
  if distilled.kind == JObject:
    let items = distilled.jget("facts")
    if items.kind == JArray:
      # Spec 009 B: with a report in the batch, facts about what the report
      # covers are dropped (the report holds them) and at most two about
      # the person survive.
      var kept: seq[JsonNode] = @[]
      for fact in items:
        kept.add(fact)
      if reportBody.len > 0:
        var aboutPerson: seq[JsonNode] = @[]
        for fact in kept:
          if not aboutReport(fact, reportBody):
            aboutPerson.add(fact)
        kept = @[]
        for i, fact in aboutPerson:
          if i >= reportTurnMaxFacts:
            break
          kept.add(fact)
      # A recall turn must not keep what it read: a proposed fact whose
      # every name, number and date is already in `recalled` is dropped.
      # Empty recalled disables the rule — this proc then behaves exactly
      # as before, which is what every older pin asserts.
      if recalled.len > 0:
        var fresh: seq[JsonNode] = @[]
        for fact in kept:
          if not restatesFact(fact.jget("content").getStr(), recalled):
            fresh.add(fact)
        kept = fresh
      for fact in kept:
        let subject = fact.jget("subject").getStr()
        let content = fact.jget("content").getStr()
        if subject.len > 0 and content.len > 0:
          facts.add(subject, content, "consolidation")
          inc count
    let episode = distilled.jget("episode").getStr()
    if episode.len > 0:
      episodes.add(episode, format(now(), "yyyy-MM-dd"))
  var ids: seq[string] = @[]
  for r in rows:
    ids.add(r[0])
  var holders: seq[string] = @[]
  for _ in ids:
    holders.add("?")
  db.exec(sql("UPDATE chat_log SET consolidated = 1 WHERE id IN (" &
    holders.join(",") & ")"), ids)
  return count

proc exportMarkdown*(db: DbConn, home: string) =
  ## Port of `Memory.export_markdown`: the human-readable mirror next to
  ## `state.db`. Generated view, refreshed after every turn — the tables
  ## stay the source of truth.
  var facts: seq[string] = @[]
  for row in db.getAllRows(sql(
      "SELECT subject, content FROM facts ORDER BY subject, id")):
    facts.add("- **" & row[0] & "** — " & row[1])
  var eps: seq[string] = @[]
  for row in db.getAllRows(sql(
      "SELECT happened_at, summary FROM episodes ORDER BY happened_at " &
      "DESC, id DESC")):
    eps.add("- **" & row[0] & "** — " & row[1])
  let text = "# Waku memory\n\n" &
    "_A human-readable mirror of what Waku remembers. The source of truth is " &
    "`state.db` (the `facts` and `episodes` tables, keyword-searchable via " &
    "FTS5); this file is regenerated after every turn._\n\n" &
    "## Facts — semantic memory (" & $facts.len & ")\n\n" &
    (if facts.len > 0: facts.join("\n") else: "_none yet_") & "\n\n" &
    "## Episodes — episodic memory (" & $eps.len & ")\n\n" &
    (if eps.len > 0: eps.join("\n") else: "_none yet_") & "\n"
  writeFile(home / "MEMORY.md", text)

proc wireMemory*(w: var Waku, settings: Settings, db: DbConn,
    client: LlmClient, bundled: seq[string]) =
  ## Fill the seams the session/app modules declared for this phase:
  ## gated retrieval + skill matching behind the prompt, consolidation +
  ## MEMORY.md sync behind `afterTurn`. Builders (CLI, dashboard,
  ## gateways) call this once per agent; tests keep building unwired
  ## agents straight from `newWaku`.
  let cell = w.reportCell   ## the turn's saved report, read through a ref
  let facts = w.facts       ## ditto: a `var Waku` cannot be captured
  let episodes = w.episodes ## the episodic twin of the line above
  ## What the gate found this turn, kept for consolidation: a recall turn
  ## must not keep what it read. A fresh cell per wiring (not per turn) is
  ## right because `afterTurn` consumes it every turn — nothing goes stale.
  var recalledCell = ""
  let home = settings.home
  let smallModel = settings.smallModel
  let topK = settings.retrievalTopK
  let everyN = settings.consolidateEvery
  w.session.retrieve =
    proc(userMessage: string, notify: Observer): string {.closure.} =
      let found = gatedRetrieve(db, facts, episodes, client, smallModel, topK,
        userMessage, notify)
      recalledCell = found
      found
  w.session.skillsFor =
    proc(userMessage: string, notify: Observer): string {.closure.} =
      matchingSkills(home, bundled, userMessage)
  w.session.researchNames =
    proc(message: string): seq[string] {.closure.} =
      matchingSkillNames(home, bundled, message)
  w.afterTurn =
    proc(notify: Observer) {.closure.} =
      # `w` is a `var Waku` and cannot be captured; the report body is
      # read through the agent's own cell, which the turn sets just before
      # (spec 009 B).
      let reportBody = if cell.isNil: "" else: cell[]
      let recalled = recalledCell
      recalledCell = ""
      let fresh = consolidateIfDue(db, facts, episodes, client, smallModel, everyN,
        notify, reportBody, recalled)
      if fresh > 0 and not notify.isNil:
        notify("consolidation", %*{"new_facts": fresh})
      exportMarkdown(db, home)
