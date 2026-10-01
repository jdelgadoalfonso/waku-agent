## The memory arena + the judgment arena — port of `waku/ops/memory_arena.py`
## (the scorer and the store/discovery surface) plus the dashboard-served half
## of `waku/ops/judgment_arena.py` (contestants, the key endpoint, the board,
## the race entry point).
##
## Why ONE new module for both arenas instead of two: the dashboard owns the
## HTTP/SSE plumbing and each arena owns its domain (the 8c precedent —
## `dashboard.py` calls into `arena.py`, never the reverse). The judgment
## domain is the same shape as the memory one (an injected runner, results on
## disk under the home, pure grading helpers), so a second module would only
## double the seam surface. `judgment_cases.py` (the 44 labelled cases) is
## NOT ported here — suites arrive injected (see `judgmentRace`) and the
## cases port is a follow-up in the phase task file.
##
## Every proc stays pure over injected values: the homes are parameters (never
## the process home), the runners are injected fns, the fixtures are read
## from the given paths, readiness from the given env table. No network, no
## process globals — tests run 100% offline with stubs.
##
## `waku/ops/judgment_arena.py` was read as spec only: its tier ids and
## default picks travel verbatim below (a "fix" there would fork the race —
## there is a test pinning them). The live runners (`run_arena`'s harness
## turns, the Jev/LLM judges, mem0/zep hosted calls) have no Nim harness to
## drive yet, so the pipelines run injected `MemoryRunFn`/`JudgmentRaceFn`
## seams instead. A nil runner is an honest done error, the same shape as
## 8b's unwired graph runner and 8c's unwired race.
##
## Divergences from Python, each seam-shaped and documented where it lands:
##
## - `arenaKey` hashes with a vendored FNV-1a-64 (first 48 bits as 12 hex
##   chars), not SHA-256: `std/sha1` is deprecated (a warning the suite
##   forbids) and `checksums` would be a new default dependency (AGENTS.md
##   forbids that too). The construction is identical (`track`, model and
##   seed lines joined by `\n`), so isolation holds — but a Nim race and a
##   Python race over the same track never share a `.waku-arena/` home.
## - Refusal matching folds ASCII case (`toLowerAscii`), not full
##   `casefold`: the phrase list is ASCII and so are the fixtures.
## - The runners own their logs: Python's `race()` persists the judgment
##   board around the threads, but an injected seam already owns its events
##   end to end, so persistence belongs to it too (like `RaceFn`, which
##   returns collected results for the pipeline to persist — except here
##   the result shape is the runner's own).

import std/algorithm
import std/json
import std/math
import std/os
import std/strutils
import std/tables

import db_connector/db_sqlite

import ./arena
import ./db
import ./integrations
import ./memory
import ./pricing
import ./providers

export providers.Provider

const
  memPass* = "pass"
    ## The expected answer is there.
  memStale* = "stale"
    ## A superseded answer is asserted — the dangerous one.
  memInvented* = "invented"
    ## A refusal was correct and it answered anyway — the headline number.
  memMiss* = "miss"
    ## The expected answer is missing and nothing wrong was asserted.
  memControl* = "control"
    ## The contestant told nothing, then asked everything. A probe it
    ## passes measures training data, not memory.
  judgmentBoard* = "judgment_arena.jsonl"
    ## Port of `judgment_arena.BOARD`: one race per line under the home.
  jevSpec* = "typesafe:jev-latest"
    ## The System One contestant, first column by default.
  jevEndpoint* = "https://api.typesafe.ai/v1/systemone"
    ## Where the Jev judge calls (the runner's business, kept as a const
    ## so the seam and the docs name the same URL).
  jevInPerMtok* = 0.042
    ## Jev billing: input tokens per million; output tokens are free.
  judgeTiers* = @[("anthropic", "claude-opus-5",
      "claude-haiku-4-5-20251001"),
    ("openai", "gpt-5.5", "gpt-5.4-mini"),
    ("xai", "grok-4.7", "grok-4.20-0309-non-reasoning")]
    ## Verbatim from `judgment_arena.JUDGE_TIERS` (read as spec, never
    ## "fixed"): flagship + fast model per vendor. Pinned by a test.
  defaultPicks* = @["anthropic:claude-opus-5",
    "anthropic:claude-haiku-4-5-20251001", "openai:gpt-5.4-mini"]
    ## Verbatim from `DEFAULT_PICKS`: Jev plus a frontier, a fast and a
    ## second vendor so it never reads as one company's house race.
  hideProviders* = @["kimi", "gemini"]
    ## Verbatim from `HIDE_PROVIDERS`: hidden from this race only.
  memBackendOrder* = @["mem0", "langmem", "supabase", "zep"]
    ## Column order on the page: slow Zep last so fast columns never wait
    ## behind graph ingestion, like Python's `_available_backends`.
  refusals* = ["don't know", "do not know", "not sure", "no information",
    "no record", "never told", "never mentioned", "never gave",
    "never shared", "didn't tell", "did not tell", "didn't mention",
    "did not mention", "didn't give", "did not give", "haven't told",
    "have not told", "haven't given", "have not given", "haven't mentioned",
    "you haven't", "you have not", "not in my memory", "don't have",
    "do not have", "nothing about", "no details", "wasn't specified",
    "not specified", "unable to find", "couldn't find", "could not find"]
    ## How models decline when they genuinely have nothing. A heuristic
    ## that can never be complete — every verdict resting on it reports
    ## `certain = false` so a judge can settle it.

type
  MemoryRunFn* = proc(backends: seq[string], track, model: string,
                      seedOnly: bool, fixture: JsonNode,
                      emit: arena.SseEmit) {.closure.}
    ## One memory race (`memory_arena.run_arena`): seeds the same
    ## conversation into each backend, asks the same probes, scores. Owns
    ## its events (including `done`) and its persistence end to end.
  JudgmentRaceFn* = proc(suiteId: string, specs: seq[string],
                         suites: JsonNode,
                         emit: arena.SseEmit) {.closure.}
    ## One judgment race (`judgment_arena.race`): every judge over the
    ## same cases through the same policy. Owns its events and its board
    ## write end to end.
  HostedListFn* = proc(store, partition, arenaHome: string): JsonNode {.closure.}
    ## One hosted store's facts (`store_contents`' live round trip):
    ## an array of `{subject, content, created_at}` rows, or a raise the
    ## pipeline reports as that card's error. Nil until a hosted reader
    ## exists — the honest card error, like the unwired runners.
  HostedWipeFn* = proc(store, partition: string): bool {.closure.}
    ## One hosted partition wipe (`clean_stores`' other half): true when
    ## something was deleted, false when already absent (a 404 is the
    ## normal case, not an error — cleaning twice must stay quiet).

proc fieldOf(node: JsonNode, key: string): JsonNode =
  ## `getOrDefault` that never returns nil (see `arena.nim`: `$` on nil
  ## segfaults). Absent reads as JNull.
  if node.isNil or node.kind != JObject:
    return newJNull()
  let v = node.getOrDefault(key)
  if v.isNil: newJNull() else: v

proc strOf(node: JsonNode, key: string): string =
  let v = fieldOf(node, key)
  if v.kind == JString: v.getStr() else: ""

proc isTruthy(node: JsonNode): bool =
  case node.kind
  of JNull: false
  of JBool: node.getBool()
  of JInt: node.getBiggestInt() != 0
  of JFloat: node.getFloat() != 0.0
  of JString: node.getStr().len > 0
  of JArray: node.len > 0
  of JObject: node.len > 0

proc hasAny(haystack: string, needles: openArray[string]): bool =
  ## Port of `memory_arena._has`: any needle as a substring, ASCII
  ## case-insensitive (the refusal list and the fixtures are ASCII;
  ## Python folds full Unicode — same verdicts on real inputs).
  let low = haystack.toLowerAscii()
  for n in needles:
    if n.toLowerAscii() in low:
      return true
  false

proc strSeqOf(node: JsonNode, key: string): seq[string] =
  let v = fieldOf(node, key)
  if v.kind == JArray:
    for item in v:
      if item.kind == JString:
        result.add(item.getStr())

# ---------------------------------------------------------------------------
# The scorer: pure functions over strings, tested with no model, no keys,
# no network — the runner is the part that costs money, deliberately thin.

proc memScore*(answer: string, probe: JsonNode, retrieved = false,
               hasRetrieved = false): (string, bool, string) =
  ## Port of `memory_arena.score`: grade one answer as
  ## `(outcome, certain, why)`. `certain` is false when the verdict rests
  ## on the refusal phrase list — those probes are worth a judge call.
  ## `retrieved`/`hasRetrieved` carry the gate's decision (only waku
  ## reports it); backends that cannot answer it are simply not graded
  ## on it rather than scored as failures for lacking a feature.
  let text = answer
  if fieldOf(probe, "expect_retrieval").kind == JBool and
      not fieldOf(probe, "expect_retrieval").getBool() and
      hasRetrieved and retrieved:
    return (memMiss, true,
      "retrieved memory for a question that needed none")
  if isTruthy(fieldOf(probe, "expect_refusal")):
    if hasAny(text, refusals):
      return (memPass, false, "declined, as it should")
    return (memInvented, false,
      "answered a question it was never given the answer to")
  let expected = strSeqOf(probe, "expect_any")
  if expected.len > 0 and not hasAny(text, expected):
    let stale = strSeqOf(probe, "stale_any")
    if stale.len > 0 and hasAny(text, stale):
      return (memStale, true,
        "asserted the superseded answer (" & stale[0] & ")")
    return (memMiss, true, "expected answer absent")
  let required = strSeqOf(probe, "expect_all")
  if required.len > 0:
    var missing: seq[string] = @[]
    for r in required:
      if not hasAny(text, [r]):
        missing.add(r)
    if missing.len > 0:
      var quoted: seq[string] = @[]
      for m in missing:
        quoted.add("'" & m & "'")
      return (memMiss, true,
        "only half the reasoning — missing [" & quoted.join(", ") & "]")
  let staleOnly = strSeqOf(probe, "stale_any")
  if expected.len == 0 and staleOnly.len > 0 and hasAny(text, staleOnly):
    return (memStale, true, "asserted a superseded answer")
  (memPass, true, "correct")

proc memScoreboard*(results: JsonNode): JsonNode =
  ## Port of `memory_arena.scoreboard`: per-contestant tallies,
  ## worst-behaviour-first so the interesting column is never buried.
  var acc = initTable[string, JsonNode]()
  var order: seq[string] = @[]
  if results.kind == JArray:
    for r in results:
      let name = strOf(r, "contestant")
      if name notin acc:
        acc[name] = %*{"contestant": name, "pass": 0, "stale": 0,
          "invented": 0, "miss": 0, "tokens": 0, "probes": 0,
          "needs_judge": 0}
        order.add(name)
      let row = acc[name]
      let outcome = strOf(r, "outcome")
      if outcome in [memPass, memStale, memInvented, memMiss]:
        row[outcome] = %(row[outcome].getInt() + 1)
      let tokens = fieldOf(r, "tokens")
      if tokens.kind == JInt:
        row["tokens"] = %(row["tokens"].getInt() +
          int(tokens.getBiggestInt()))
      elif tokens.kind == JFloat:
        row["tokens"] = %(row["tokens"].getInt() + int(tokens.getFloat()))
      row["probes"] = %(row["probes"].getInt() + 1)
      if not isTruthy(fieldOf(r, "certain")):
        row["needs_judge"] = %(row["needs_judge"].getInt() + 1)
  var rows: seq[JsonNode] = @[]
  for name in order:
    rows.add(acc[name])
  rows.sort(proc(x, y: JsonNode): int =
    let ix = (x[memInvented].getInt(), x[memStale].getInt(),
      x[memMiss].getInt(), x[memPass].getInt())
    let iy = (y[memInvented].getInt(), y[memStale].getInt(),
      y[memMiss].getInt(), y[memPass].getInt())
    cmp(iy, ix))
  result = newJArray()
  for row in rows:
    result.add(row)

proc renderMemBoard*(rows: JsonNode): string =
  ## Port of `memory_arena.render`: the table, for a terminal and a
  ## thumbnail. No emojis (AGENTS.md).
  let head = alignLeft("contestant", 24) & align("pass", 6) &
    align("stale", 7) & align("invented", 10) & align("miss", 6) &
    align("tokens", 9)
  var lines = @[head, "-".repeat(head.len)]
  var unsure = 0
  if rows.kind == JArray:
    for r in rows:
      lines.add(alignLeft(strOf(r, "contestant")[0 ..<
          min(24, strOf(r, "contestant").len)], 24) &
        align($fieldOf(r, memPass).getInt(), 6) &
        align($fieldOf(r, memStale).getInt(), 7) &
        align($fieldOf(r, memInvented).getInt(), 10) &
        align($fieldOf(r, memMiss).getInt(), 6) &
        align($fieldOf(r, "tokens").getInt(), 9))
      unsure += fieldOf(r, "needs_judge").getInt()
  if unsure > 0:
    lines.add("")
    lines.add($unsure &
      " verdict(s) rest on the refusal heuristic — worth a judge pass.")
  lines.join("\n")

proc probeAssertsRecall*(probe: JsonNode): bool =
  ## Whether a control pass on this probe means the probe leaks: only
  ## probes asserting recalled content count. Refusal and no-retrieval
  ## probes are MEANT to pass with nothing stored — flagging them would
  ## cry leak on every single run, forever, and mean nothing.
  if not (strSeqOf(probe, "expect_any").len > 0 or
      strSeqOf(probe, "expect_all").len > 0):
    return false
  if isTruthy(fieldOf(probe, "expect_refusal")):
    return false
  let noRetrieval = fieldOf(probe, "expect_retrieval")
  if noRetrieval.kind == JBool and not noRetrieval.getBool():
    return false
  true

proc leakedProbes*(results, probes: JsonNode): JsonNode =
  ## The probes the control passed that assert recall — questions that
  ## did not test memory in THIS run, named explicitly rather than left
  ## to be noticed.
  result = newJArray()
  var ids: seq[string] = @[]
  if results.kind == JArray:
    for r in results:
      if strOf(r, "contestant") == memControl and
          strOf(r, "outcome") == memPass:
        let id = strOf(r, "probe")
        var probe = newJNull()
        if probes.kind == JArray:
          for p in probes:
            if strOf(p, "id") == id:
              probe = p
              break
        if probe.kind != JNull and probeAssertsRecall(probe) and
            id notin ids:
          ids.add(id)
  for id in sorted(ids):
    result.add(%id)

# ---------------------------------------------------------------------------
# Arena naming: homes named for what they hold, so seeding once serves many
# races and a race can never probe a store seeded for another question.

proc fnv1a64(text: string): uint64 =
  ## FNV-1a over bytes: enough diffusion for naming throwaway homes
  ## (collisions only ever waste a re-seed, never corrupt live data).
  result = 14695981039346656037u64
  for c in text:
    result = (result xor ord(c).uint64) * 1099511628211u64

proc arenaKey*(track, model: string, seed: seq[string]): string =
  ## The one hash: names the local home AND the hosted partition, so a
  ## race is isolated on both sides by construction.
  toHex(fnv1a64((@[track, model] & seed).join("\n")) shr 16,
    12).toLowerAscii()

proc arenaPartition*(track, model: string, seed: seq[string]): string =
  "waku-arena-" & arenaKey(track, model, seed)

proc arenaBaseDir*(home: string): string =
  ## `.waku-arena/` beside the home (covered by `.waku-*/` in
  ## `.gitignore`: a second agent home's SOUL.md and usage ledger are the
  ## files you least want pushed).
  parentDir(home) / ".waku-arena"

proc arenaHome*(baseDir, backend, key: string): string =
  baseDir / (backend & "-" & key)

# ---------------------------------------------------------------------------
# Probe fixtures: scanned from a directory, never taken as a path from the
# browser. "Read the JSON file at this path" is a file-read primitive
# handed to a web page, and a benchmark tool has no reason to need one.

proc probeFiles*(examplePath, home: string,
                 envOverride = ""): seq[JsonNode] =
  ## Every probe set the arena can offer, as `{name, path}`. The shipped
  ## example first (skipped when no example path is known — a bare binary
  ## answers `available: false`, like a pip-installed Waku whose wheel
  ## never shipped `evals/`), then `<home>/probes/*.json`, then the
  ## `WAKU_MEMORY_PROBES` override when it names something new.
  if examplePath.len > 0:
    result.add(%*{"name": "example (shipped)", "path": examplePath})
  let folder = home / "probes"
  if dirExists(folder):
    var extra: seq[string] = @[]
    for kind, path in walkDir(folder):
      if kind == pcFile and path.endsWith(".json"):
        extra.add(path)
    for path in sorted(extra):
      result.add(%*{"name": lastPathPart(path)[0 .. ^6],
        "path": path})
  if envOverride.strip().len > 0:
    var seen = false
    for f in result:
      if strOf(f, "path") == envOverride:
        seen = true
    if not seen:
      result.add(%*{"name": lastPathPart(envOverride)[0 .. ^1] &
        " (env)", "path": envOverride})

proc probeSets*(files: seq[JsonNode]): JsonNode =
  ## Every runnable question set, flat: one entry per TRACK, not per
  ## file. A file is a container, not a choice — the picker reads like a
  ## list of experiments, which is what it is. Broken files are skipped,
  ## like bad trace lines elsewhere in the port.
  result = newJArray()
  for f in files:
    let path = strOf(f, "path")
    var doc: JsonNode
    try:
      doc = parseJson(readFile(path))
    except OSError, JsonParsingError:
      continue
    let tracks = fieldOf(doc, "tracks")
    if tracks.kind != JObject:
      continue
    for track, spec in tracks:
      let seed = fieldOf(spec, "seed")
      let probes = fieldOf(spec, "probes")
      let labelNode = fieldOf(spec, "label")
      let label = if labelNode.kind == JString: labelNode.getStr()
                  else: strOf(f, "name") & " / " & track
      result.add(%*{"id": path & "::" & track, "path": path,
        "track": track, "label": label,
        "facts": (if seed.kind == JArray: seed.len else: 0),
        "probes": (if probes.kind == JArray: probes.len else: 0)})

proc loadFixture*(path: string; examplePath = ""): JsonNode =
  ## The probes plus where they came from — the UI says so on screen,
  ## because "which questions was this scored against" is the first thing
  ## anyone should ask of a benchmark. Raises on a bad read (the caller
  ## answers `available: false`, like the wheel without `evals/`).
  result = parseJson(readFile(path))
  result["source"] = %path
  result["is_example"] = %(examplePath.len > 0 and path == examplePath)

proc resolveTrack*(wanted: string, sets: JsonNode,
                   fallback: string): (bool, string, string) =
  ## The chosen file must be one the server offered: `(found, track,
  ## path)`. Unwanted paths fall back to the caller's track, never to
  ## disk — a browser-supplied path must never reach the filesystem.
  if sets.kind == JArray:
    for s in sets:
      if strOf(s, "id") == wanted:
        return (true, strOf(s, "track"), strOf(s, "path"))
  (false, fallback, "")

proc trackSeed*(fixture: JsonNode, track: string): seq[string] =
  ## The seed conversation for one track (the staleness guard input).
  let tracks = fieldOf(fixture, "tracks")
  let spec = fieldOf(tracks, track)
  let seed = fieldOf(spec, "seed")
  if seed.kind == JArray:
    for line in seed:
      if line.kind == JString:
        result.add(line.getStr())

proc arenaModels*(pinned: seq[string],
                  providers: seq[Provider]): JsonNode =
  ## Port of `arena_models`: the pinned shortlist, priced, CHEAPEST
  ## FIRST. The arena varies the store and holds the model fixed, so the
  ## model is a constant that cannot move the result — sorting by price
  ## puts the cheap default in the picker itself. Unknown prices read
  ## zero rather than raising, like Python's try/except.
  var rows: seq[JsonNode] = @[]
  for spec in pinned:
    let idx = spec.find(':')
    if idx < 0:
      continue
    let prov = spec[0 ..< idx]
    let modl = spec[idx + 1 .. ^1]
    var pin = 0.0
    var pout = 0.0
    try:
      (pin, pout) = priceFor(prov, modl, providers)
    except CatchableError:
      pin = 0.0
      pout = 0.0
    rows.add(%*{"spec": spec, "provider": prov, "model": modl,
      "price_in": pin, "price_out": pout})
  rows.sort(proc(x, y: JsonNode): int =
    cmp((x["price_in"].getFloat() + x["price_out"].getFloat(),
      x["spec"].getStr()),
      (y["price_in"].getFloat() + y["price_out"].getFloat(),
      y["spec"].getStr())))
  result = newJArray()
  for row in rows:
    result.add(row)

proc availableBackends*(providers: seq[Provider],
                        env: Table[string, string]): seq[string] =
  ## Port of `_available_backends`: sqlite always, a hosted store only
  ## when it is configured AND installed (this page never reports an
  ## error that just means "you have not set this up" — that is what
  ## the Connections tab is for), the control last: it is the integrity
  ## check, not a contestant you rank.
  result = @["sqlite"]
  var ready = initTable[string, bool]()
  for view in listConnections(providers, env):
    if view.status.state in {configured, connected}:
      ready[view.key] = true
  for key in memBackendOrder:
    if ready.getOrDefault(key, false):
      result.add(key)
  result.add(memControl)

# ---------------------------------------------------------------------------
# What is actually in there: per-backend counts plus a sample, read on
# demand — never on the 5s poll, because each hosted call is a live round
# trip to a paid service.

proc storeNote*(key: string, env: Table[string, string]): string =
  ## Why a store's contents cannot be listed, when that is the case.
  if key == memControl:
    return "told nothing, by design — there is no store behind this " &
      "one. It exists so a probe it still passes can be flagged as a " &
      "question that never needed memory."
  if key == "langmem" and
      env.getOrDefault("WAKU_LANGMEM_POSTGRES", "").strip().len == 0:
    return "in-memory store — contents live inside the process that " &
      "wrote them and cannot be read back here. Set " &
      "WAKU_LANGMEM_POSTGRES to persist."
  ""

proc spanOf*(rows: JsonNode): string =
  ## Oldest to newest, as plain dates: three weeks of real use and one
  ## afternoon of benchmark data look identical as a count, and
  ## completely different as a span.
  var stamps: seq[string] = @[]
  if rows.kind == JArray:
    for r in rows:
      let day = strOf(r, "created_at")[0 ..< min(10,
        strOf(r, "created_at").len)]
      if day.strip().len > 0:
        stamps.add(day)
  stamps = sorted(stamps)
  if stamps.len == 0:
    return ""
  if stamps[0] == stamps[^1]:
    return stamps[0]
  stamps[0] & " to " & stamps[^1]

proc sqliteStoreRows*(home: string): JsonNode =
  ## This race's sqlite facts (or the live agent's, when no race scopes
  ## the read): newest first, via the same store the agent uses.
  result = newJArray()
  let db = connectDb(home)
  try:
    for f in listFacts(db, 200):
      result.add(%*{"subject": f.subject, "content": f.content,
        "created_at": f.createdAt})
  finally:
    db.close()

proc storeContents*(providers: seq[Provider], env: Table[string, string],
                    track, model: string, fixture: JsonNode, only: string,
                    limit: int, liveHome: string,
                    hosted: HostedListFn): JsonNode =
  ## Port of `store_contents`. A backend that errors reports the error
  ## rather than an empty list — "0 facts" and "I could not reach the
  ## service" look identical on screen and mean opposite things. Given a
  ## track with a seed this reads the ARENA's own copy (the same
  ## `.waku-arena/` home the race seeded), never the live agent's
  ## `.waku/state.db` — the cards stay genuinely comparable, and the
  ## page stops putting the operator's own facts on screen.
  result = newJArray()
  let seed = trackSeed(fixture, track)
  let partition = arenaPartition(track, model, seed)
  for key in availableBackends(providers, env):
    if only.len > 0 and key != only:
      continue
    let note = storeNote(key, env)
    if note.len > 0:
      result.add(%*{"store": key, "count": 0, "facts": newJArray(),
        "error": "", "span": "", "kind":
        (if key == memControl: "control" else: "live"), "note": note})
      continue
    let store = if key == memControl: "sqlite" else: key
    let home = if seed.len > 0:
      arenaHome(arenaBaseDir(liveHome), key,
        arenaKey(track, model, seed))
    else:
      liveHome
    let kind = if key == memControl: "control"
               elif seed.len > 0: "arena"
               elif key == "sqlite": "live"
               else: "connected"
    try:
      let rows =
        if store == "sqlite": sqliteStoreRows(home)
        elif hosted.isNil:
          raise newException(CatchableError,
            "reads for '" & store &
            "' are not wired in this dashboard build")
        else: hosted(store, partition, home)
      var facts = newJArray()
      let n = if rows.kind == JArray: rows.len else: 0
      if rows.kind == JArray:
        for i in 0 ..< min(n, limit):
          facts.add(%*{"subject": strOf(rows[i], "subject"),
            "content": strOf(rows[i], "content")})
      result.add(%*{"store": key, "count": n, "facts": facts,
        "error": "", "span": spanOf(rows), "kind": kind, "note": ""})
    except CatchableError as exc:
      var msg = $exc.name & ": " & exc.msg
      if msg.len > 160:
        msg = msg[0 ..< 160]
      result.add(%*{"store": key, "count": 0, "facts": newJArray(),
        "error": msg, "span": "", "kind": kind, "note": ""})

proc cleanStores*(baseDir, track, model: string, seed: seq[string],
                  wipe: HostedWipeFn = nil): JsonNode =
  ## Port of `clean_stores`: delete everything THIS race wrote, and
  ## nothing else. Safe only because of the partition: every race owns
  ## `waku-arena-<key>`, so this names precisely what it means — the
  ## `.waku-arena/` homes for this seed and the hosted partition with
  ## the matching name. Reports per store rather than raising: a cleanup
  ## that half-worked and said nothing is how you race against data you
  ## believe is gone.
  if seed.len == 0:
    return %*{"error":
      "no track chosen — nothing can be named, so nothing is deleted"}
  let key = arenaKey(track, model, seed)
  let partition = arenaPartition(track, model, seed)
  var removed = newJArray()
  var errors = newJArray()
  if dirExists(baseDir):
    for kind, path in walkDir(baseDir):
      if lastPathPart(path).endsWith("-" & key):
        try:
          if kind == pcDir:
            removeDir(path)
          else:
            removeFile(path)
          removed.add(%lastPathPart(path))
        except OSError as exc:
          errors.add(%(lastPathPart(path) & ": OSError: " & exc.msg))
  for store in ["mem0", "zep"]:
    if wipe.isNil:
      errors.add(%(store &
        " wipe is not wired in this dashboard build"))
      continue
    try:
      if wipe(store, partition):
        removed.add(%(store & ":" & partition))
    except CatchableError as exc:
      errors.add(%(store & ": " & $exc.name & ": " & exc.msg))
  %*{"partition": partition, "removed": removed, "errors": errors}

# ---------------------------------------------------------------------------
# The judgment arena, dashboard-served half.

proc judgmentContestants*(env: Table[string, string],
                          providers: seq[Provider]): JsonNode =
  ## Port of `contestants`: every pinned tier model, plus Jev. A judge
  ## with no key is listed but not selectable, so the reason is on
  ## screen instead of the column silently missing. Readiness comes from
  ## the injected env table through each provider row's `keyEnv` (the
  ## user key, never logged, never sent anywhere but its own endpoint).
  result = newJArray()
  let jevReady = env.getOrDefault("TYPESAFE_API_KEY", "").strip().len > 0
  result.add(%*{"spec": jevSpec, "label": "Jev", "kind": "system-one",
    "ready": jevReady, "picked": jevReady,
    "why": "set TYPESAFE_API_KEY in .env"})
  let picks = defaultPicks
  for (prov, flagship, fast) in judgeTiers:
    if prov in hideProviders:
      continue
    var keyEnv = prov.toUpperAscii() & "_API_KEY"
    var known = false
    for p in providers:
      if p.name == prov:
        known = true
        if p.keyEnv.strip().len > 0:
          keyEnv = p.keyEnv
        break
    if not known:
      continue
    for modl in [flagship, fast]:
      if modl.len == 0:
        continue
      let spec = prov & ":" & modl
      let ready = env.getOrDefault(keyEnv, "").strip().len > 0
      result.add(%*{"spec": spec, "label": modl, "kind": prov,
        "ready": ready, "picked": ready and spec in picks,
        "why": "set " & keyEnv & " in .env"})

proc checkJudgmentKey*(key: string): string =
  ## The validation half of `save_key` (persistence stays with the
  ## dashboard's dotenv writer): "" when acceptable, else the error.
  ## The key is the user's — written to their `.env`, never logged.
  if key.strip().len == 0:
    return "paste a key first"
  for c in key:
    if ord(c) > 127:
      return "that key has a non-ASCII character in it -- check for " &
        "a smart quote"
  ""

proc judgmentBoardPath*(home: string): string =
  home / judgmentBoard

proc loadJudgmentRuns*(home: string, limit = 20): JsonNode =
  ## Recent judgment races, newest first. Bad lines skipped, like the
  ## compare history and the trace tail.
  result = newJArray()
  let path = judgmentBoardPath(home)
  if not fileExists(path):
    return
  var runs: seq[JsonNode] = @[]
  for line in lines(path):
    if line.strip().len == 0:
      continue
    try:
      runs.add(parseJson(line))
    except JsonParsingError:
      continue
  let start = max(0, runs.len - limit)
  for i in countdown(runs.len - 1, start):
    result.add(runs[i])

proc saveJudgmentRun*(home: string, run: JsonNode) =
  ## Append one finished judgment race to the board.
  let path = judgmentBoardPath(home)
  createDir(parentDir(path))
  var fh: File
  if open(fh, path, fmAppend):
    fh.writeLine($run)
    fh.close()

proc isRight*(kind: string, expected, answer: JsonNode): bool =
  ## Port of `judgment_cases.is_right`: did this answer match the label?
  ## One rule per primitive, none of them a tuned threshold — a Noul
  ## lands on a side of the coin flip, a Choice picks an option, a Score
  ## rounds to a level.
  if kind == "noul":
    var v = 0.0
    let node = fieldOf(answer, "noul")
    case node.kind
    of JFloat: v = node.getFloat()
    of JInt: v = float(node.getBiggestInt())
    else: discard
    return (v >= 0.5) == (expected.kind == JBool and
      expected.getBool())
  if kind == "choice":
    let node = fieldOf(answer, "choice")
    return node.kind == JString and expected.kind == JString and
      node.getStr() == expected.getStr()
  var v = -1.0
  let node = fieldOf(answer, "score")
  case node.kind
  of JFloat: v = node.getFloat()
  of JInt: v = float(node.getBiggestInt())
  else: discard
  expected.kind == JInt and int(round(v)) == int(expected.getBiggestInt())

proc answerShape*(q: JsonNode): string =
  ## Port of `judgment_cases.answer_shape`: what this question may
  ## answer, in one line.
  let criteria = fieldOf(q, "criteria")
  if criteria.kind == JObject:
    var opts: seq[string] = @[]
    for k in keys(criteria):
      opts.add(k)
    return "one of: " & opts.join(", ")
  if criteria.kind == JArray:
    var levels: seq[string] = @[]
    for i in 0 ..< criteria.len:
      let lv = criteria[i]
      levels.add($i & " " & (if lv.kind == JString: lv.getStr()
                             else: $lv))
    return $criteria.len & " levels: " & levels.join(" | ")
  "a probability from 0 to 1"

proc findSuite*(suites: JsonNode, suiteId: string): JsonNode =
  ## The suite with this id, or JNull. Suites arrive injected (the
  ## `judgment_cases` port is a follow-up), so an empty board reads as
  ## "unknown suite" rather than a crash.
  if suites.kind == JArray:
    for s in suites:
      if strOf(s, "id") == suiteId:
        return s
  newJNull()

proc judgmentRace*(suiteId: string, specs: seq[string], suites: JsonNode,
                   race: JudgmentRaceFn, emit: arena.SseEmit) =
  ## Port of `judgment_arena.race` around the injected seam: validate
  ## the suite, run the judges (each answer scored on its own against
  ## the hand-written label), close. The seam owns its events and its
  ## board write end to end.
  if suiteId.len == 0 or findSuite(suites, suiteId).kind == JNull:
    emit("done", %*{"error": "unknown suite '" & suiteId & "'"})
    return
  if race.isNil:
    emit("done", %*{"error":
      "judgment racing is not wired in this dashboard build"})
    return
  try:
    race(suiteId, specs, suites, emit)
  except CatchableError as exc:
    emit("done", %*{"error": exc.msg})

proc memoryRace*(backends: seq[string], track, model: string,
                 seedOnly: bool, fixture: JsonNode, run: MemoryRunFn,
                 emit: arena.SseEmit) =
  ## Port of `run_arena` around the injected seam: resolve the track,
  ## run the backends, close. The seam owns seeding, probing, scoring
  ## and its events end to end — the pipeline only guards the door.
  let tracks = fieldOf(fixture, "tracks")
  if tracks.kind != JObject or fieldOf(tracks, track).kind == JNull:
    let source = strOf(fixture, "source")
    emit("done", %*{"error": "no track '" & track & "' in " &
      (if source.len > 0: source else: "the probe file")})
    return
  let backs = if backends.len == 0: @["sqlite"] else: backends
  if run.isNil:
    emit("done", %*{"error":
      "memory racing is not wired in this dashboard build"})
    return
  try:
    run(backs, track, model, seedOnly, fixture, emit)
  except CatchableError as exc:
    emit("done", %*{"error": exc.msg})
