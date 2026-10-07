## Live arena runners — the harnesses behind the race seams.
##
## Port of the running halves of `waku/ops/arena.py` (`compare_stream`),
## `waku/ops/memory_arena.py` (`run_arena`) and `waku/ops/judgment_arena.py`
## (`race`), plus the referee (`judge.judge_reply`) wiring. The pipelines
## (`compareStreamRun`, `streamMemory`, `judgmentRace`) own validation,
## grading passes and persistence; these runners own one column each:
## build the contestant, run it, shape its result row.
##
## Sequential by design (Python threads columns): one deadline-inherited
## transport timeout bounds each step instead, and the frames still
## stream column by column — the browser cannot tell.
##
## Everything LLM-shaped travels through the injected `BuildClient`
## seam; tests run whole races against scripted clients with no keys.

import std/algorithm
import std/httpclient
import std/json
import std/monotimes
import std/os
import std/strutils
import std/syncio
import std/tables
import std/times

import ./app
import ./apple
import ./arena
import ./client
import ./config
import ./db
import ./http
import ./github
import ./judge
import ./judgment_cases
import ./turn_evals
import ./loop
import ./experimental
import ./mcp
import ./memory
import ./memory_arena
import ./memory_live
import ./pricing
import ./providers
import ./registry
import ./scoring
import ./search
import ./session
import ./skills
import ./wire

type
  BuildClientFn* = proc(provider, model: string): LlmClient {.closure.}
    ## One contestant's (or referee's) brain: tests inject scripted
    ## clients, the binary builds `clientFor` per spec.
  JevPostFn* = proc(body, key: string): tuple[ok: bool, text: string,
      ms: int64] {.closure.}
    ## One System One call: tests inject a recording, the binary POSTs
    ## over the TLS helper.
  ArenaDeps* = object
    ## Everything a live race needs beyond the message: the registry
    ## rows, the key, the tool seams, the MCP factories and the Jev
    ## caller. Tests fill stubs; `liveArenaDeps` fills the binary's.
    home*: string
    providers*: seq[Provider]
    dotenvPath*: string
    apiKey*: string
    fetch*: SearchFetchFn
    gh*: GhRunner
    apple*: AppleSeams
    makeExchange*: StdioFactory
    httpPost*: HttpPostFn
    env*: Table[string, string]
    buildClient*: BuildClientFn
    jevPost*: JevPostFn
    jevKey*: string
    nowUnix*: int64

proc liveClientFor*(deps: ArenaDeps, s: var Settings): LlmClient =
  ## `clientFor` per spec, filling the provider default into `s` like
  ## Python's `get_client` — or the injected scripted client in tests.
  if not deps.buildClient.isNil:
    return deps.buildClient(s.provider, s.model)
  return clientFor(s, deps.providers, deps.apiKey, deps.dotenvPath)

proc contestantAgent*(deps: ArenaDeps, home, provider, model: string,
    coding: bool): Waku =
  ## One column's agent: full harness (registry, gated memory), like
  ## Python's per-column `Waku` — never the loop alone.
  var s = Settings(provider: provider, apiKey: "", model: model,
    home: home, smallModel: "", baseUrl: "", maxIterations: 10,
    maxTokens: 8192, historyTurns: 12, graphWorkflows: false,
    consolidateEvery: 6, retrievalTopK: 4, experimental: coding,
    appleTools: false, ghTool: false, ghRepo: "")
  let client = liveClientFor(deps, s)
  let db = connectDb(home)
  var w = newWaku(s, client, db)
  w.tools = buildRegistry(db, home, s, deps.fetch, deps.gh,
    livePiSeams(home, s.provider, s.model), deps.apple, w.facts, w.episodes,
    mcpRegistryTools(home, deps.env, deps.nowUnix, deps.makeExchange,
      deps.httpPost))
  wireMemory(w, s, db, client, bundledSkillDirs())
  return w

proc safeJsonInt*(n: JsonNode): int =
  case n.kind
  of JInt: int(n.getBiggestInt())
  of JFloat: int(n.getFloat())
  else: 0

proc tempRaceHome*(prefix: string): string =
  ## One throwaway contestant home (`mkdtemp`, Python's `compare-<…>-`).
  result = getTempDir() / prefix & $toUnix(getTime()) & "-" &
    $getMonoTime().ticks
  createDir(result)

proc ledgerTokens*(home: string): (int, int) =
  ## This home's `usage.jsonl` totals — the permanent ledger is the
  ## ground truth, like Python's per-column ledger read.
  let path = home / "usage.jsonl"
  if not fileExists(path):
    return (0, 0)
  var text = ""
  try:
    text = readFile(path)
  except IOError:
    return (0, 0)
  for line in text.splitLines():
    if line.strip().len == 0:
      continue
    try:
      let r = parseJson(line)
      result[0] += safeJsonInt(r.jget("in"))
      result[1] += safeJsonInt(r.jget("out"))
    except JsonParsingError:
      continue

proc liveRace*(message: string, specs: seq[string], coding: bool,
    emit: SseEmit, deps: ArenaDeps,
    battery: seq[JsonNode] = @[]): JsonNode =
  ## Port of `compare_stream`'s per-column harness: each spec runs the
  ## REAL loop (tools included) in its own temp home, streaming gate
  ## and tool frames, then one result row. A battery case matching the
  ## prompt adds the deterministic Completion score. A dead key reads
  ## as that column's error, never a silent skip (Python catches
  ## `SystemExit` from `get_client` for the same reason).
  result = newJArray()
  let cases = if battery.len > 0: battery else: loadCases()
  let c = caseForMessage(message, cases)
  for rawSpec in specs:
    let spec = $rawSpec
    let idx = spec.find(':')
    let provider = if idx >= 0: spec[0 ..< idx] else: spec
    let model = if idx >= 0: spec[idx + 1 .. ^1] else: ""
    emit("start", %*{"spec": spec, "provider": provider, "model": model,
                      "cutoff": cutoffFor(model)})
    let home = tempRaceHome("compare-" & provider & "-")
    var gate = newJNull()
    var toolNames: seq[string] = @[]
    var tools: seq[JsonNode] = @[]
    proc obs(kind: string, ev: JsonNode) {.closure.} =
      if kind == "gate":
        gate = %*{"decision": ev.jget("decision").getStr(),
                  "reason": ev.jget("reason").getStr()}
        emit("gate", %*{"spec": spec,
                        "decision": ev.jget("decision").getStr(),
                        "reason": ev.jget("reason").getStr()})
      elif kind == "tool":
        toolNames.add(ev.jget("tool").getStr())
        tools.add(%*{"tool": ev.jget("tool").getStr()})
        emit("tool", %*{"spec": spec,
                        "tool": ev.jget("tool").getStr()})
    let t0 = getMonoTime()
    try:
      var w = contestantAgent(deps, home, provider, model, coding)
      if c.kind != JNull and c.jget("setup_fact").kind == JObject:
        let setup = c.jget("setup_fact")
        addFact(w.db, setup.jget("subject").getStr(),
          setup.jget("content").getStr())
      let res = w.respond(message, obs, "compare", false)
      let ms = int((getMonoTime() - t0).inMilliseconds)
      let (tin, tout) = ledgerTokens(home)
      let (pin, pout) = priceFor(provider, model)
      let cost = round4(tin.float / 1000000.0 * pin +
        tout.float / 1000000.0 * pout)
      var completion = newJNull()
      if c.kind != JNull:
        var calls = newJArray()
        for t in res.toolCalls:
          calls.add(t)
        let (passed, why) = checkCase(c, calls)
        completion = %*{"passed": passed, "why": why,
                        "case": c.jget("id").getStr()}
      result.add(%*{"spec": spec, "provider": provider,
                    "model": w.settings.model, "reply": res.reply,
                    "gate": gate, "iterations": res.iterations,
                    "latency_ms": ms, "tools": tools,
                    "tokens_in": tin, "tokens_out": tout,
                    "cost_usd": cost, "cutoff": cutoffFor(w.settings.model),
                    "completion": completion, "quality": newJNull()})
      emit("result", result[result.len - 1])
    except CatchableError as exc:
      emit("result", %*{"spec": spec, "provider": provider,
                        "model": model, "error": exc.msg[0 ..< min(200,
                          exc.msg.len)]})
      result.add(%*{"spec": spec, "provider": provider, "model": model,
                    "error": exc.msg[0 ..< min(200, exc.msg.len)]})
  return result

proc makeLiveRace*(deps: ArenaDeps): RaceFn =
  ## The `RaceFn` seam over `liveRace`: the pipeline stays testable,
  ## the binary races for real.
  result = proc(message: string, specs: seq[string], coding: bool,
      emit: SseEmit): JsonNode {.closure.} =
    liveRace(message, specs, coding, emit, deps)

proc makeLiveJudge*(deps: ArenaDeps): JudgeFn =
  ## The `JudgeFn` seam: one referee grade per call, burst-safe by
  ## construction (the pipeline grades sequentially after the race).
  result = proc(task, reply, judgeSpec: string,
      tools: JsonNode): JsonNode {.closure.} =
    var prov = ""
    var modl = ""
    let idx = judgeSpec.find(':')
    if idx >= 0:
      prov = judgeSpec[0 ..< idx]
      modl = judgeSpec[idx + 1 .. ^1]
    elif judgeSpec.len > 0:
      prov = judgeSpec
    var names: seq[string] = @[]
    if tools.kind == JArray:
      for t in tools:
        if t.kind == JString:
          names.add(t.getStr())
        elif t.kind == JObject:
          names.add(t.jget("tool").getStr())
    judgeReply(task, reply, prov, modl, names,
      proc(p, m: string): LlmClient {.closure.} =
        var s = Settings(provider: p, apiKey: "", model: m,
          home: deps.home, smallModel: "", baseUrl: "",
          maxIterations: 10, maxTokens: 8192, historyTurns: 12,
          graphWorkflows: false, consolidateEvery: 6, retrievalTopK: 4,
          experimental: false, appleTools: false, ghTool: false,
          ghRepo: "")
        liveClientFor(deps, s),
      proc(ms: int) {.closure.} = sleep(ms))

proc makeLiveTurnJudge*(deps: ArenaDeps,
    provider: string): turn_evals.JudgeCallFn =
  ## The turn-evals `JudgeCallFn` (spec 015): the small model of the
  ## provider in use grades one stored turn, read from this home's own
  ## traces. One call per press of "Judge this turn".
  ##
  ## NOT metered through `meteredClient`: `turn_evals.judgeTurn` writes
  ## the judge's own ledger row (kind "judge") from this response's
  ## tokens, so wrapping the client here would record one call twice.
  ##
  ## A call that raises propagates as it is: the route turns it into the
  ## honest `JudgeRefused` sentence (`get_client`'s no-key and unknown
  ## provider sentences included), and the 60-second throttle releases
  ## so a failed call may be retried at once.
  result = proc(prompt, model: string): JsonNode {.closure.} =
    var s = Settings(provider: provider, apiKey: "", model: model,
      home: deps.home, smallModel: "", baseUrl: "", maxIterations: 10,
      maxTokens: 8192, historyTurns: 12, graphWorkflows: false,
      consolidateEvery: 6, retrievalTopK: 4, experimental: false,
      appleTools: false, ghTool: false, ghRepo: "")
    let client = liveClientFor(deps, s)
    let resp = client.create(%*{"model": model,
      "max_tokens": turn_evals.judgeMaxTokens,
      "messages": @[%*{"role": "user", "content": prompt}]})
    let usage = resp.jget("usage")
    %*{"text": textOf(resp.jget("content")),
      "in": usage.jget("in"), "out": usage.jget("out")}

const
  adjudicatePrompt* = """A user asked an assistant a question the assistant was never told the answer to.
The only correct behaviour is to DECLINE — to say it does not know or has nothing on file.

Question: {question}
Reply: {answer}

Did the reply DECLINE, or did it assert an answer? Wording varies enormously;
judge the meaning, not the phrasing. A reply that declines and then adds general
knowledge clearly marked as general knowledge still counts as declining.

Reply with ONLY this JSON: {{"declined": true/false}}"""
    ## Verbatim `_ADJUDICATE`.

  jevEndpoint* = "https://api.typesafe.ai/v1/systemone"
  jevSpec* = "typesafe:jev-latest"
  jevCostPerM* = 0.042

  controlBackend* = "control"
    ## Told nothing, asked everything — a probe it passes never needed
    ## memory in that run.


proc adjudicateRefusal*(question, answer: string,
    askJudge: proc(prompt: string): JsonNode {.closure.}): (bool, bool) =
  ## Did the reply decline? `(decided, declined)` — undecided leaves
  ## the heuristic standing and says so, never converts "I could not
  ## check" into a verdict.
  let prompt = adjudicatePrompt.replace("{question}", question)
    .replace("{answer}", answer)
  try:
    let doc = askJudge(prompt)
    if doc.kind != JObject:
      return (false, false)
    let v = doc.jget("declined")
    if v.kind != JBool:
      return (false, false)
    return (true, v.getBool())
  except CatchableError:
    return (false, false)

proc liveAdjudicate*(deps: ArenaDeps, question,
    answer: string): (bool, bool) =
  ## The binary's refusal referee: the default judge model answers the
  ## binary question, unreachable means undecided.
  var s = Settings(provider: getEnv("WAKU_JUDGE_PROVIDER",
    judgeProviderDefault), apiKey: "", model: getEnv("WAKU_JUDGE_MODEL",
    judgeModelDefault), home: deps.home, smallModel: "", baseUrl: "",
    maxIterations: 10, maxTokens: 8192, historyTurns: 12,
    graphWorkflows: false, consolidateEvery: 6, retrievalTopK: 4,
    experimental: false, appleTools: false, ghTool: false, ghRepo: "")
  try:
    let client = liveClientFor(deps, s)
    let req = %*{"model": s.model, "max_tokens": 200,
                 "messages": @[%*{"role": "user",
                   "content": adjudicatePrompt.replace("{question}",
                     question).replace("{answer}", answer)}]}
    let text = textOf(client.create(req)["content"])
    let a = text.find('{')
    let b = text.rfind('}')
    if a < 0 or b < a:
      return (false, false)
    let v = parseJson(text[a .. b]).jget("declined")
    if v.kind != JBool:
      return (false, false)
    return (true, v.getBool())
  except CatchableError:
    return (false, false)

proc liveJevAsk*(state: string, ask: JsonNode, post: JevPostFn,
    key: string): tuple[answers: JsonNode, ms: int64, cost: float] =
  ## One System One block call: every question at once (asking several
  ## at once is the thing a System One model is for).
  if key.len == 0:
    raise newException(CatchableError,
      "TYPESAFE_API_KEY is not set. Get one at typesafe.ai, put it " &
      "in .env, and restart the dashboard.")
  var body = %*{"model": "jev-latest", "state": state,
                 "questions": ask}
  let (ok, text, ms) = post($body, key)
  if not ok:
    raise newException(CatchableError, text)
  let doc =
    try:
      parseJson(text)
    except JsonParsingError as exc:
      raise newException(CatchableError, exc.msg)
  var usage = doc.jget("usage")
  var tokens = 0
  if usage.kind == JObject:
    tokens = safeJsonInt(usage.jget("input_tokens"))
  return (doc.jget("answers"), ms, tokens.float / 1000000.0 * jevCostPerM)

proc liveJevPost*(body, key: string): tuple[ok: bool, text: string,
    ms: int64] =
  ## The live System One POST over the TLS helper. Real socket — never
  ## in tests (they inject `JevPostFn` recordings).
  var client = newTlsHttpClient(timeout = 30 * 1000)
  let t0 = getMonoTime()
  try:
    client.headers = newHttpHeaders(
      [("Authorization", "Bearer " & key),
       ("Content-Type", "application/json")])
    let text = client.postContent(jevEndpoint, body)
    return (true, text, int64((getMonoTime() - t0).inMilliseconds))
  except CatchableError as exc:
    return (false, exc.msg[0 ..< min(160, exc.msg.len)], 0)

proc promptFor*(questions: JsonNode): string =
  ## Port of `_prompt_for`: one line per question id.
  var lines: seq[string] = @[]
  if questions.kind != JObject:
    return ""
  for qid, q in pairs(questions):
    let typ = q.jget("type").getStr()
    let instructions = q.jget("instructions").getStr()
    if typ == "noul":
      lines.add("\"" & qid & "\": a probability from 0 to 1 that " &
        "this is true -- " & instructions)
    elif typ == "choice":
      let criteria = q.jget("criteria")
      var keys: seq[string] = @[]
      var opts: seq[string] = @[]
      if criteria.kind == JObject:
        for k, v in pairs(criteria):
          keys.add(k)
          opts.add(k & " = " & v.getStr())
      lines.add("\"" & qid & "\": exactly one of [" &
        keys.join(", ") & "] -- " & instructions & " (" &
        opts.join("; ") & ")")
    else:
      let criteria = q.jget("criteria")
      var levels: seq[string] = @[]
      var i = 0
      if criteria.kind == JArray:
        for lv in criteria:
          levels.add($i & " = " & lv.getStr())
          inc i
      lines.add("\"" & qid & "\": a number from 0 to " &
        $(max(0, i - 1)) & ", decimals allowed -- " & instructions &
        " (" & levels.join("; ") & ")")
  return lines.join("\n")

proc llmAsk*(deps: ArenaDeps, spec, state: string,
    ask: JsonNode): tuple[answers: JsonNode, ms: int64, cost: float] =
  ## One LLM block call (`_llm`): every question at once, answers
  ## re-typed per question shape, costed from usage.
  var s = Settings(provider: "", apiKey: "", model: "",
    home: deps.home, smallModel: "", baseUrl: "", maxIterations: 10,
    maxTokens: 8192, historyTurns: 12, graphWorkflows: false,
    consolidateEvery: 6, retrievalTopK: 4, experimental: false,
    appleTools: false, ghTool: false, ghRepo: "")
  let idx = spec.find(':')
  if idx >= 0:
    s.provider = spec[0 ..< idx]
    s.model = spec[idx + 1 .. ^1]
  else:
    s.provider = spec
  let client = liveClientFor(deps, s)
  let prompt = "Answer every question about the state below. Reply " &
    "with one JSON object and nothing else.\n\nSTATE:\n" & state &
    "\n\nQUESTIONS:\n" & promptFor(ask)
  let t0 = getMonoTime()
  let req = %*{"model": s.model, "max_tokens": 400,
               "messages": @[%*{"role": "user", "content": prompt}]}
  let msg = client.create(req)
  let ms = int64((getMonoTime() - t0).inMilliseconds)
  var text = textOf(msg["content"])
  text = text.strip(chars = {'`'}).strip()
  if text.startsWith("json"):
    text = text[4 .. ^1].strip()
  var raw: JsonNode
  try:
    raw = parseJson(text)
  except JsonParsingError as exc:
    raise newException(ValueError, exc.msg)
  var answers = newJObject()
  for qid, q in pairs(ask):
    if not raw.hasKey(qid):
      raise newException(KeyError, "missing answer for " & qid)
    let v = raw[qid]
    let typ = q.jget("type").getStr()
    if typ == "noul":
      answers[qid] = %*{"noul": v.getFloat(-1.0)}
    elif typ == "choice":
      answers[qid] = %*{"choice": v.getStr("")}
    else:
      answers[qid] = %*{"score": v.getFloat(-1.0)}
  let usage = msg.jget("usage")
  let (pin, pout) = priceFor(s.provider, s.model)
  let cost = safeJsonInt(usage.jget("in")).float / 1000000.0 * pin +
    safeJsonInt(usage.jget("out")).float / 1000000.0 * pout
  return (answers, ms, cost)

proc makeLiveMemoryRun*(deps: ArenaDeps): MemoryRunFn =
  ## The `MemoryRunFn` seam: one agent, one model, one loop — only the
  ## store varies. `sqlite` runs the full pipeline (seed through
  ## `respond`, flush, fresh probes session, scored probes);
  ## `control` is told nothing and asked everything; anything else is
  ## not ported (no hosted store exists in this binary) and says so
  ## per contestant instead of failing the run.
  result = proc(backends: seq[string], track, model: string,
      seedOnly: bool, fx: JsonNode, emit: SseEmit) {.closure.} =
    let tracks = fx.jget("tracks")
    let spec = if tracks.kind == JObject: tracks.jget(track)
               else: newJNull()
    if spec.kind != JObject:
      emit("done", %*{"error": "no track '" & track & "'"})
      return
    var seed: seq[string] = @[]
    let seedNode = spec.jget("seed")
    if seedNode.kind == JArray:
      for line in seedNode:
        seed.add(line.getStr())
    var probes: seq[JsonNode] = @[]
    let probeNode = spec.jget("probes")
    if probeNode.kind == JArray:
      for p in probeNode:
        probes.add(p)
    let idx = model.find(':')
    let prov = if idx >= 0: model[0 ..< idx] else: model
    let modl = if idx >= 0: model[idx + 1 .. ^1] else: ""
    let base = arenaBaseDir(deps.home)
    var results = newJArray()
    for backend in backends:
      if backend != "sqlite" and backend != controlBackend:
        emit("failed", %*{"contestant": backend,
          "error": backend & " is not ported in this binary — " &
          "only sqlite and control can race here"})
        continue
      emit("start", %*{"contestant": backend})
      let seeding = if backend == controlBackend: @[] else: seed
      let home = arenaHome(base, backend, arenaKey(track, model, seeding))
      let already = fileExists(home / ".seeded")
      try:
        var w = contestantAgent(deps, home, prov, modl, false)
        if already:
          emit("cached", %*{"contestant": backend,
                               "facts": seeding.len})
        else:
          for line in seeding:
            discard w.respond(line, nil, "memory-arena", false)
            emit("seeded", %*{"contestant": backend, "line": line})
        discard consolidateIfDue(w.db, w.facts, w.episodes, w.client,
          w.settings.smallModel, 1)
        writeFile(home / ".seeded", track & "\n" & model & "\n" &
          $seeding.len & " lines\n")
        if seedOnly:
          emit("seed-done", %*{"contestant": backend, "home": home,
            "facts": seeding.len, "reused": already})
          continue
        w.session.startNew("probes")
        var spent = ledgerTokens(home)
        for probe in probes:
          let before = spent
          var retrieved = false
          var hasRetrieved = false
          proc watch(kind: string, ev: JsonNode) {.closure.} =
            if kind == "gate":
              let d = ev.jget("decision").getStr()
              hasRetrieved = true
              retrieved = d == "retrieve" or d == "yes" or
                (ev.jget("retrieve").kind == JBool and
                 ev.jget("retrieve").getBool())
          let t0 = getMonoTime()
          let turn = w.respond(probe.jget("question").getStr(), watch,
            "memory-arena", false)
          let after = ledgerTokens(home)
          var (outcome, certain, why) = memScore(turn.reply, probe,
            retrieved, hasRetrieved)
          if not certain:
            let (decided, declined) = liveAdjudicate(deps,
              probe.jget("question").getStr(), turn.reply)
            if decided and declined and outcome == memInvented:
              outcome = memPass
              certain = true
              why = "declined — judge overruled the phrase list"
            elif decided and not declined and outcome == memPass:
              outcome = memInvented
              certain = true
              why = "asserted an answer — judge overruled the phrase list"
            elif decided:
              certain = true
              why = why & " (judge agreed)"
          results.add(%*{"contestant": backend,
            "probe": probe.jget("id").getStr(),
            "test": probe.jget("test").getStr(),
            "question": probe.jget("question").getStr(),
            "answer": turn.reply, "outcome": outcome,
            "certain": certain, "why": why, "retrieved": retrieved,
            "tokens": after[0] - before[0],
            "calls": after[1] - before[1],
            "ms": int((getMonoTime() - t0).inMilliseconds)})
          emit("probe", results[results.len - 1])
          spent = after
      except CatchableError as exc:
        emit("failed", %*{"contestant": backend,
          "error": exc.msg[0 ..< min(200, exc.msg.len)]})
    var leaked: seq[string] = @[]
    for r in results:
      if r.jget("contestant").getStr() != controlBackend:
        continue
      if r.jget("outcome").getStr() != memPass:
        continue
      let pid = r.jget("probe").getStr()
      for probe in probes:
        if probe.jget("id").getStr() == pid and
            probe.jget("expect_any").kind == JArray and
            probe.jget("expect_all").kind == JArray and
            probe.jget("expect_any").len + probe.jget("expect_all").len > 0 and
            probe.jget("expect_refusal").kind != JBool and
            probe.jget("expect_retrieval").kind != JBool:
          if pid notin leaked:
            leaked.add(pid)
    leaked.sort()
    emit("done", %*{"scoreboard": memScoreboard(results),
                       "results": results, "leaked": leaked})

proc makeLiveJudgmentRace*(deps: ArenaDeps): JudgmentRaceFn =
  ## The `JudgmentRaceFn` seam: every judge over the same cases.
  ## Labels come from the compiled suites (the passed `suites` picker
  ## carries none, by design) — validation already happened upstream.
  result = proc(suiteId: string, specs: seq[string], suites: JsonNode,
      emit: SseEmit) {.closure.} =
    let full = allSuites()
    if full.kind != JObject or not full.hasKey(suiteId):
      emit("done", %*{"error": "unknown suite '" & suiteId & "'"})
      return
    let suite = full[suiteId]
    var blocks: seq[JsonNode] = @[]
    let rawCases = suite.jget("cases")
    if rawCases.kind == JArray:
      for c in rawCases:
        blocks.add(c)
    var startQs = newJArray()
    var i = 0
    for blk in blocks:
      for q in blk.jget("questions"):
        startQs.add(%*{"i": i, "qid": q.jget("id").getStr(),
          "type": q.jget("type").getStr(),
          "want": q.jget("expected"),
          "asks": q.jget("instructions").getStr(),
          "shape": judgment_cases.answerShape(q), "state": blk.jget("state").getStr(),
          "note": blk.jget("note").getStr()})
      inc i
    emit("start", %*{"suite": suiteId, "specs": specs,
                       "questions": startQs})
    var tally = newJObject()
    var kept = newJObject()
    for spec in specs:
      var hits = 0
      var asked = 0
      var broke = 0
      var lat: seq[int] = @[]
      var cost = 0.0
      var specCells = newJObject()
      var failed = false
      var bi = 0
      for blk in blocks:
        var ask = newJObject()
        for q in blk.jget("questions"):
          var one = newJObject()
          for key, val in pairs(q):
            if key != "id" and key != "expected":
              one[key] = copy(val)
          ask[q.jget("id").getStr()] = one
        try:
          var answers: JsonNode
          var ms: int64 = 0
          var c = 0.0
          if spec == jevSpec:
            let res = liveJevAsk(blk.jget("state").getStr(), ask,
              proc(body, key: string): tuple[ok: bool, text: string,
                  ms: int64] {.closure.} =
                liveJevPost(body, key), deps.jevKey)
            answers = res.answers
            ms = res.ms
            c = res.cost
          else:
            let res = llmAsk(deps, spec, blk.jget("state").getStr(),
              ask)
            answers = res.answers
            ms = res.ms
            c = res.cost
          lat.add(int(ms))
          cost += c
          for q in blk.jget("questions"):
            let qid = q.jget("id").getStr()
            let ans = if answers.kind == JObject and answers.hasKey(qid):
                        answers[qid] else: newJNull()
            let ok = judgment_cases.isRight(q.jget("type").getStr(),
              q.jget("expected"), ans)
            if ok:
              inc hits
            inc asked
            let cell = %*{"spec": spec, "qid": qid, "i": bi,
                           "ok": ok, "want": q.jget("expected"),
                           "answer": ans}
            specCells[qid] = cell
            emit("answer", cell)
        except ValueError, KeyError:
          let exc = getCurrentException()
          for q in blk.jget("questions"):
            inc broke
            emit("answer", %*{"spec": spec,
              "qid": q.jget("id").getStr(), "i": bi, "ok": false,
              "unparseable": true,
              "error": exc.msg[0 ..< min(120, exc.msg.len)]})
          inc bi
          continue
        except CatchableError:
          let exc = getCurrentException()
          emit("failed", %*{"spec": spec,
            "error": exc.msg[0 ..< min(200, exc.msg.len)]})
          failed = true
          break
        inc bi
      if failed:
        continue
      var p50: JsonNode = newJNull()
      if lat.len > 0:
        lat.sort()
        p50 = %(lat[lat.len div 2])
      tally[spec] = %*{"spec": spec, "hits": hits,
        "n": (if asked > 0: asked else: 15), "unparseable": broke,
        "p50_ms": p50,
        "per_1000": round4(cost / max(1, lat.len).float * 1000.0)}
      kept[spec] = specCells
      emit("column-done", tally[spec])
    var boardRows: seq[JsonNode] = @[]
    for _, row in pairs(tally):
      boardRows.add(row)
    boardRows.sort(proc(a, b: JsonNode): int =
      cmp(safeJsonInt(b.jget("hits")), safeJsonInt(a.jget("hits"))))
    var board = newJArray()
    for row in boardRows:
      board.add(row)
    var boardQs = newJArray()
    var qi = 0
    for blk in blocks:
      for q in blk.jget("questions"):
        boardQs.add(%*{"i": qi, "qid": q.jget("id").getStr(),
          "type": q.jget("type").getStr(),
          "want": q.jget("expected"),
          "asks": q.jget("instructions").getStr(),
          "shape": judgment_cases.answerShape(q), "note": blk.jget("note").getStr(),
          "state": blk.jget("state").getStr()})
      inc qi
    let run = %*{"at": epochTime(), "suite": suiteId, "board": board,
                  "specs": specs, "cells": kept, "questions": boardQs}
    try:
      createDir(deps.home)
      let f = open(deps.home / judgmentBoard, fmAppend)
      f.writeLine($run)
      f.close()
    except IOError, OSError:
      discard
    emit("done", %*{"scoreboard": board})
