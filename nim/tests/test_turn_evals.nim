## Turn evals — the five code checks and the on-demand judge (spec 015).
##
## Offline only: crafted turns, no model, no sockets. The judge's model
## call rides an injected seam, so these pins never touch a network.

import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import ../src/turn_evals

proc madeTurn(turnId = "t_abc123"): JsonNode =
  %*{"turn_id": turnId, "ts": "2026-10-05T10:00:00+00:00",
    "user_message": "research cheap leads", "reply": "two calls, all in.",
    "unfinished": false,
    "events": [
      {"type": "tool", "tool": "treg_call", "args": {},
        "output": "{\"endpoint_id\": \"tomba.leads\"}"},
      {"type": "report", "memory_id": "m1"}]}

suite "turn view":
  test "one grouped turn reads as message, reply, tools, reports and flags":
    let v = view(madeTurn(), usd = %0.0089, research = true)
    assert v["message"].getStr() == "research cheap leads"
    assert v["reply"].getStr() == "two calls, all in."
    assert v["tools"].len == 1
    assert v["tools"][0]["tool"].getStr() == "treg_call"
    assert v["tools"][0]["output"].getStr() ==
      "{\"endpoint_id\": \"tomba.leads\"}"
    assert v["tools"][0]["source"].getStr() == "treg"
    assert v["tools"][0]["endpoint_id"].getStr() == "tomba.leads"
    assert v["reports"].len == 1
    assert v["reports"][0].getStr() == "m1"
    assert v["usd"].getFloat() == 0.0089
    assert v["v2"].getBool()
    assert v["ts"].getStr() == "2026-10-05T10:00:00+00:00"
    assert v["research"].getBool()
    assert not v["unfinished"].getBool()

  test "a turn with no id is not v2 and non-string fields stay empty":
    let v = view(%*{"user_message": "hi", "reply": "yo",
      "events": [{"type": "tool", "tool": 7, "output": 7}]})
    assert not v["v2"].getBool()
    assert v["tools"][0]["tool"].getStr() == ""
    assert v["tools"][0]["output"].getStr() == ""
    assert v["usd"].kind == JNull

  test "an unfinished flag survives the view":
    var t = madeTurn()
    t["unfinished"] = %true
    assert view(t)["unfinished"].getBool()

suite "reply reading":
  test "prose drops fences, inline code, links and emphasis":
    assert prose("```nim\nlet x = 1\n```\nIt costs $4.") == " \nIt costs $4."
    assert prose("Use `treg_call` now.") == "Use   now."
    assert prose("see (https://x.com/a) today") == "see   today"
    assert prose("see https://x.com/a today") == "see   today"
    assert prose("**bold** and _it_ ~gone~") == "bold and it gone"

  test "sentences split lines and stops before a space":
    assert sentences("Hello. World") == @["Hello.", "World"]
    assert sentences("One!\nTwo? Yes") == @["One!", "Two?", "Yes"]
    assert sentences("  spaced  ") == @["spaced"]

suite "money and budget":
  test "zero, sub-cent and usual figures render like Python":
    assert money(0.0) == "$0.00"
    assert money(0.0089) == "$0.0089"
    assert money(1.5) == "$1.50"
    assert money(1234.5) == "$1,234.50"

  test "the budget defaults when the env is missing, bad or not positive":
    delEnv("WAKU_TURN_BUDGET_USD")
    assert budgetUsd() == 1.00
    putEnv("WAKU_TURN_BUDGET_USD", "2.50")
    assert budgetUsd() == 2.50
    putEnv("WAKU_TURN_BUDGET_USD", "much")
    assert budgetUsd() == 1.00
    putEnv("WAKU_TURN_BUDGET_USD", "-3")
    assert budgetUsd() == 1.00
    delEnv("WAKU_TURN_BUDGET_USD")

proc tregTool(output: string): JsonNode =
  %*{"type": "tool", "tool": "treg_call", "args": {}, "output": output}

proc spendView(reply: string, outputs: seq[string],
    usd = 0.0089): JsonNode =
  var events: seq[JsonNode] = @[]
  for o in outputs:
    events.add(tregTool(o))
  view(%*{"turn_id": "t_abc123", "ts": "2026-10-05T10:00:00+00:00",
    "user_message": "x", "reply": reply, "events": events}, usd = %usd)

const tombaOut = "{\"status\": 200, \"endpoint_id\": " &
  "\"tomba.companies.similar\", \"cost_usd\": 0.0089}"

suite "spend claim":
  test "a $0.00 reply against $0.0089 of treg fails and names both":
    let check = checkSpendClaim(spendView("The research cost $0.00.", @[tombaOut]))
    assert check["value"].getInt() == 0
    assert check["note"].getStr() ==
      "reply says $0.00; this turn's treg calls cost $0.0089", check["note"].getStr()

  test "a named treg figure is checked against its own calls":
    let ok = checkSpendClaim(spendView("The treg cost was $0.0089.", @[tombaOut]))
    assert ok["value"].getInt() == 1, ok["note"].getStr()
    let bad = checkSpendClaim(spendView("The treg cost was $0.40.", @[tombaOut]))
    assert bad["value"].getInt() == 0
    assert "$0.40" in bad["note"].getStr()
    assert "$0.0089" in bad["note"].getStr()

  test "a price offered for later is not a claim":
    let check = checkSpendClaim(
      spendView("Want me to enrich them? That'd run ~$0.002 each.", @[tombaOut]))
    assert check["value"].kind == JNull

  test "a free claim passes when treg charged nothing":
    let free = "{\"status\": 200, \"endpoint_id\": " &
      "\"leadsforge.lookalike.preview\", \"cost_usd\": 0.0}"
    let check = checkSpendClaim(spendView(
      "Both lists came from LeadsForge's free preview ($0.00).", @[free]))
    assert check["value"].getInt() == 1, check["note"].getStr()

  test "N calls at $X each states N times X":
    let aviato = "{\"status\": 200, \"endpoint_id\": \"aviato.search\", " &
      "\"cost_usd\": 0.04}"
    let check = checkSpendClaim(spendView(
      "Four Aviato calls at $0.01 each covered it; the spend was $0.04.",
      @[aviato]))
    assert check["value"].getInt() == 1, check["note"].getStr()

  test "an unscoped figure without the treg word is not checked":
    let check = checkSpendClaim(spendView("Total: $0.04.", @[tombaOut]))
    assert check["value"].kind == JNull

proc plainTool(source: string, ok = true): JsonNode =
  %*{"tool": "search_web", "args": {}, "output": "Web results",
    "ok": ok, "source": source, "cost_usd": newJNull(),
    "endpoint_id": "", "provider": ""}

proc reportView(message, reply: string, tools: seq[JsonNode] = @[],
    reports: seq[string] = @[], research = true): JsonNode =
  var reps: seq[JsonNode] = @[]
  for r in reports:
    reps.add(%r)
  %*{"message": message, "reply": reply, "tools": tools,
    "reports": reps, "usd": 0.1, "v2": true, "ts": "2026-10-05T10:00:00+00:00",
    "research": research, "unfinished": false}

proc rememberTool(body, output: string, tool = "waku_memory_memory_remember",
    ok = true, company = false): JsonNode =
  let args = if company: %*{"body": body, "scope": "project:Company brain"}
    else: %*{"body": body}
  %*{"tool": tool, "args": args, "output": output,
    "ok": ok, "source": "waku_memory", "cost_usd": newJNull(),
    "endpoint_id": "", "provider": ""}

suite "one report":
  test "a research turn with no report saved fails":
    let check = checkOneReport(reportView("research the competitors of Letta",
      "Letta competes with Zep.", @[plainTool("local")]))
    assert check["value"].getInt() == 0
    let asked = checkOneReport(
      reportView("research the competitors of Letta and save a report",
        "Letta competes with Zep."))
    assert asked["value"].getInt() == 0

  test "two saves in one turn fail, even off research":
    let check = checkOneReport(reportView("hi", "yo", @[], @["m1", "m2"],
      research = false))
    assert check["value"].getInt() == 0
    assert check["note"].getStr() == "2 reports saved in one turn"

  test "one report event passes, and the marker counts without memory":
    let one = checkOneReport(reportView("research the competitors of Letta",
      "Letta competes with Zep.", @[plainTool("local")], @["m1"]))
    assert one["value"].getInt() == 1
    let marker = checkOneReport(reportView("research the competitors of Letta",
      "Letta competes with Zep.\n\n<!-- waku-report v1 -->\n# Letta\n"))
    assert marker["value"].getInt() == 1

  test "an everyday message is not owed a report":
    let check = checkOneReport(
      reportView("what's on my calendar", "Nothing today.", research = false))
    assert check["value"].kind == JNull

  test "asking for no report is n/a, saving one anyway fails":
    let na = checkOneReport(reportView("Just answer, no report",
      "Forty-two."))
    assert na["value"].kind == JNull
    let saved = checkOneReport(reportView("Just answer, no report",
      "Forty-two.", @[], @["m1"]))
    assert saved["value"].getInt() == 0

  test "a memory_remember whose body is a report counts as the save":
    let body = "<!-- waku-report v1 -->\n# Letta\n\n## Findings\n- x\n"
    let check = checkOneReport(reportView("research the competitors of Letta",
      "Saved.", @[rememberTool(body, "{\"memory\": {\"id\": \"mx\"}}")]))
    assert check["value"].getInt() == 1
    let shaped = checkOneReport(reportView("research the competitors of Letta",
      "Saved.", @[rememberTool("# Letta\\n## Findings\\n- x",
        "{\"memory\": {\"id\": \"my\"}}", company = true)]))
    assert shaped["value"].getInt() == 1, shaped["note"].getStr()

  test "a refused save and a duplicate id save nothing twice":
    let refused = checkOneReport(reportView("research the competitors of Letta",
      "Could not save.",
      @[rememberTool("<!-- waku-report v1 -->\n# L", "Not sent. Waku saves nothing.")]))
    assert refused["value"].getInt() == 0
    let dup = checkOneReport(reportView("research the competitors of Letta",
      "Saved.", @[rememberTool("<!-- waku-report v1 -->\n# L",
        "{\"memory\": {\"id\": \"m1\"}}")], @["m1"]))
    assert dup["value"].getInt() == 1

  test "an older trace did not trace reports":
    var v = reportView("research the competitors of Letta", "No save.",
      @[plainTool("local")])
    v["v2"] = %false
    assert checkOneReport(v)["value"].kind == JNull

proc groundedView(message, reply: string, outputs: seq[string],
    sources: seq[string] = @[]): JsonNode =
  var tools: seq[JsonNode] = @[]
  for i, o in outputs:
    let src = if i < sources.len: sources[i] else: "local"
    tools.add(%*{"tool": "search_web", "args": {}, "output": o,
      "ok": true, "source": src, "cost_usd": newJNull(),
      "endpoint_id": "", "provider": ""})
  %*{"message": message, "reply": reply, "tools": tools,
    "reports": newJArray(), "usd": 0.1, "v2": true,
    "ts": "2026-10-05T10:00:00+00:00", "research": false,
    "unfinished": false}

const numSource = "{\"revenue_usd\": 1200, \"share\": 0.04, " &
  "\"founded\": \"2026-10-05\", \"employees\": 37, \"growth_pct\": 12}"

suite "grounded numbers":
  test "other formats match: commas, $0.04, percents, written dates":
    let reply = "They earn $1,200 a month, hold $0.04 of share, have 37 " &
      "staff, grew 12% and launched Oct 5, 2026."
    let check = checkGroundedNumbers(groundedView("x", reply, @[numSource]))
    assert check["value"].getInt() == 1, check["note"].getStr()

  test "a scaled figure mid-reply grounds the raw source figure":
    let reply = "It raised $1.5M, kept $2K and paid $300."
    let check = checkGroundedNumbers(groundedView("x", reply,
      @["{\"raised\": 1500000, \"kept\": 2000, \"paid\": 300}"]))
    assert check["value"].getInt() == 1, check["note"].getStr()

  test "a reply ending in a scale word scales nothing":
    let reply = "Costs were $5,000, fees $600 and tax $700 on the web"
    let check = checkGroundedNumbers(groundedView("x", reply,
      @["{\"big\": 5000000000000, \"fees\": 600000000000, " &
        "\"tax\": 700000000000}"]))
    assert check["value"].getInt() == 0

  test "an invented figure fails and is named":
    let reply = "Revenue was $1,200, profit $9,999 and tax $8,888."
    let check = checkGroundedNumbers(groundedView("x", reply, @[numSource]))
    assert check["value"].getInt() == 0
    assert "9,999" in check["note"].getStr(), check["note"].getStr()

  test "below three numbers is n/a, and code and lists do not count":
    let thin = checkGroundedNumbers(
      groundedView("x", "Only 5 and 7 here.", @[numSource]))
    assert thin["value"].kind == JNull
    let coded = checkGroundedNumbers(groundedView("x",
      "```\n100 200 300\n```\n1. First\n2. Second", @[numSource]))
    assert coded["value"].kind == JNull, coded["note"].getStr()

  test "the user's message counts as a source too":
    let reply = "Revenue was $1,200, staff 37 and tax $8,888."
    let check = checkGroundedNumbers(groundedView(
      "remember tax $8,888", reply, @[numSource]))
    assert check["value"].getInt() == 1, check["note"].getStr()

  test "the trace's own treg dollars ground a spend sentence":
    var v = groundedView("x",
      "The call cost $0.04 over 25 rows and 30 tries.",
      @["{\"rows\": 25, \"tries\": 30}"], @["treg"])
    v["tools"][0]["cost_usd"] = %0.04
    let check = checkGroundedNumbers(v)
    assert check["value"].getInt() == 1, check["note"].getStr()

  test "a memory-only miss is n/a: history is not traced":
    let mem: seq[string] = @[]
    var v = groundedView("x", "It cost $5.00, took 25 days and 30 tries.",
      @["{}"], @["waku_memory"])
    discard mem
    let check = checkGroundedNumbers(v)
    assert check["value"].kind == JNull
    assert "answered from memory" in check["note"].getStr()

  test "an older trace gets n/a, its outputs may be cut":
    var v = groundedView("x", "Revenue was $1,200, profit $9,999 and tax $8,888.",
      @[numSource])
    v["v2"] = %false
    assert checkGroundedNumbers(v)["value"].kind == JNull

proc errTool(tool, source: string, ok: bool, provider = "",
    endpoint = ""): JsonNode =
  %*{"tool": tool, "args": {}, "output": "boom", "ok": ok,
    "source": source, "cost_usd": newJNull(), "endpoint_id": endpoint,
    "provider": provider}

proc errView(reply: string, tools: seq[JsonNode],
    usd = 0.1): JsonNode =
  %*{"message": "x", "reply": reply, "tools": tools,
    "reports": newJArray(), "usd": usd, "v2": true,
    "ts": "2026-10-05T10:00:00+00:00", "research": false,
    "unfinished": false}

suite "errors handled":
  test "a retried failure passes":
    let check = checkErrorsHandled(errView("Done.",
      @[errTool("treg_call", "treg", false),
        errTool("treg_call", "treg", true)]))
    assert check["value"].getInt() == 1

  test "a mentioned failure passes, by tool, endpoint part or plain words":
    let named = checkErrorsHandled(errView("Tomba returned nothing.",
      @[errTool("tomba_lookup", "treg", false, provider = "tomba")]))
    assert named["value"].getInt() == 1, named["note"].getStr()
    let part = checkErrorsHandled(errView("YouTube gave no rows.",
      @[errTool("treg_call", "treg", false,
        endpoint = "tikhub.youtube.search_video")]))
    assert part["value"].getInt() == 1, part["note"].getStr()
    let words = checkErrorsHandled(errView("The search failed, trying again.",
      @[errTool("search_web", "local", false)]))
    assert words["value"].getInt() == 1

  test "a silent failure fails and names the tool":
    let check = checkErrorsHandled(errView("All good, here are results.",
      @[errTool("tomba_lookup", "treg", false, provider = "tomba")]))
    assert check["value"].getInt() == 0
    assert "tomba_lookup" in check["note"].getStr()

  test "a second failure stays silent when the reply reports another":
    let check = checkErrorsHandled(errView("The search web call failed.",
      @[errTool("search_web", "local", false),
        errTool("tomba_lookup", "treg", false, provider = "tomba")]))
    assert check["value"].getInt() == 0, check["note"].getStr()
    assert "search_web" notin check["note"].getStr()
    assert "tomba_lookup" in check["note"].getStr()

  test "no failure is n/a":
    let check = checkErrorsHandled(
      errView("Done.", @[errTool("treg_call", "treg", true)]))
    assert check["value"].kind == JNull

suite "under budget":
  test "a $1.34 turn fails the default budget":
    delEnv("WAKU_TURN_BUDGET_USD")
    let check = checkUnderBudget(errView("x", @[], usd = 1.34))
    assert check["value"].getInt() == 0
    assert check["note"].getStr() == "$1.34 is over the $1.00 budget"

  test "the budget comes from the environment":
    putEnv("WAKU_TURN_BUDGET_USD", "2.00")
    let check = checkUnderBudget(errView("x", @[], usd = 1.34))
    assert check["value"].getInt() == 1
    assert check["note"].getStr() == "$1.34 of the $2.00 budget"
    delEnv("WAKU_TURN_BUDGET_USD")

  test "no recorded cost is n/a":
    var v = errView("x", @[])
    v["usd"] = newJNull()
    assert checkUnderBudget(v)["value"].kind == JNull

suite "run checks":
  test "one grouped turn gets the five code scores":
    let turn = %*{"turn_id": "t_abc123",
      "ts": "2026-10-05T10:00:00+00:00", "user_message": "hi",
      "reply": "Forty-two.", "events": []}
    let scores = runChecks(turn, usd = %0.1)
    assert scores.len == 5
    assert scores[0]["name"].getStr() == "spend_claim"
    assert scores[4]["name"].getStr() == "under_budget"
    for s in scores:
      assert s["source"].getStr() == "code"

  test "a check that raises is n/a and the page still builds":
    proc broken(v: JsonNode): JsonNode =
      raise newException(CatchableError, "boom")
    let turn = %*{"turn_id": "t_abc123",
      "ts": "2026-10-05T10:00:00+00:00", "user_message": "hi",
      "reply": "Forty-two.", "events": []}
    let scores = runChecks(turn, usd = %0.1,
      checks = @[("spend_claim", CheckFn(broken))])
    assert scores.len == 1
    assert scores[0]["value"].kind == JNull
    assert scores[0]["note"].getStr() == "check error"

proc judgeTurnJson(turnId, reply: string, tools: JsonNode = newJArray(),
    message = "do it"): JsonNode =
  %*{"turn_id": turnId, "ts": "2026-10-05T10:00:00+00:00",
    "user_message": message, "reply": reply, "events": tools}

proc judgeHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc fakeJudge(text: string, nIn = 100, nOut = 10,
    calls: ptr int = nil): JudgeCallFn =
  result = proc(prompt, model: string): JsonNode {.closure.} =
    if not calls.isNil:
      calls[] += 1
    %*{"text": text, "in": nIn, "out": nOut}

const goodVerdict =
  "{\"addresses_question\": 9, \"grounded\": 3, \"reason\": \"says it\"}"

suite "judge prompt and offer":
  test "the prompt comes from the stored turn only":
    let tools = %*[{"type": "tool", "tool": "treg_call",
      "output": "x".repeat(2000)}]
    let p = judgePrompt(judgeTurnJson("t_aaa111", "did " & "y".repeat(5000),
      tools, message = "do it"))
    assert "do it" in p
    assert ("did " & "y".repeat(3996)) in p
    assert ("y".repeat(3997)) notin p
    assert ("[treg_call] " & "x".repeat(800)) in p
    assert ("x".repeat(801)) notin p
    let bare = judgePrompt(judgeTurnJson("t_aaa111", "done"))
    assert "(no tools ran this turn)" in bare

  test "the offer names the model and its estimate, else null":
    let t = judgeTurnJson("t_aaa111", "done")
    let offer = judgeOffer(t, "prov", "m")
    assert offer["model"].getStr() == "m"
    assert offer["usd"].getFloat() == judgeEstimate(judgePrompt(t), "prov", "m")
    assert judgeOffer(judgeTurnJson("", "done"), "prov", "m").kind == JNull
    assert judgeOffer(judgeTurnJson("t_aaa111", "  "), "prov", "m").kind == JNull
    assert judgeOffer(t, "prov", "").kind == JNull

  test "the verdict is the lower mark over ten, or null":
    let v = parseVerdict("lead " & goodVerdict & " tail")
    assert v["value"].getFloat() == 0.3
    assert v["addresses_question"].getInt() == 9
    assert v["grounded"].getInt() == 3
    assert v["reason"].getStr() == "says it"
    assert parseVerdict("no json here").kind == JNull
    assert parseVerdict("{\"addresses_question\": 99, \"grounded\": -2}")[
      "value"].getFloat() == 0.0

suite "judge writes once":
  test "one score event with cost and model, plus the ledger line":
    let home = judgeHome("waku-judge-ok")
    let turn = judgeTurnJson("t_aaa111", "did it",
      %*[{"type": "tool", "tool": "treg_call", "output": "rows"}])
    var calls = 0
    let at = "2026-10-06T12:00:00+00:00"
    let ev = judgeTurn(home, turn, newJArray(),
      fakeJudge(goodVerdict, calls = addr calls), "m", "prov", at)
    assert calls == 1
    assert ev["turn_id"].getStr() == "t_aaa111"
    assert ev["source"].getStr() == "judge"
    assert ev["value"].getFloat() == 0.3
    assert ev["judge"].getStr() == "m"
    assert "says it (judged by m, " in ev["note"].getStr()
    let day = format(now().utc, "yyyy-MM-dd")
    let lines = readFile(home / "traces" / (day & ".jsonl")).strip().splitLines()
    assert lines.len == 1, $lines.len
    let stored = parseJson(lines[0])
    assert stored["turn_id"].getStr() == "t_aaa111"
    assert stored["value"].getFloat() == 0.3
    assert stored["ts"].getStr().len > 0
    let usage = parseJson(readFile(home / "usage.jsonl").strip())
    assert usage["kind"].getStr() == "judge"
    assert usage["in"].getInt() == 100
    removeDir(home)

  test "an exact charge wins over the estimate":
    let home = judgeHome("waku-judge-charged")
    let turn = judgeTurnJson("t_ddd444", "did it")
    let call = proc(prompt, model: string): JsonNode {.closure.} =
      %*{"text": goodVerdict, "in": 100, "out": 10, "charged_usd": 0.05}
    let ev = judgeTurn(home, turn, newJArray(), call, "m", "prov",
      "2026-10-06T12:00:00+00:00")
    assert ev["cost_usd"].getFloat() == 0.05
    removeDir(home)

  test "unknown turns and repeats within a minute are refused":
    let grouped = %*[judgeTurnJson("t_bbb222", "did it")]
    expect JudgeRefused:
      discard findTurn(grouped, newJArray(), "xyz")
    expect JudgeRefused:
      discard findTurn(grouped, newJArray(), "t_deadbeef")
    expect JudgeRefused:
      discard findTurn(%*[judgeTurnJson("t_bbb222", "  ")], newJArray(),
        "t_bbb222")
    let home = judgeHome("waku-judge-repeat")
    var calls = 0
    let at = "2026-10-06T12:00:00+00:00"
    let (turn, judged) = findTurn(grouped, newJArray(), "t_bbb222")
    discard judgeTurn(home, turn, judged, fakeJudge(goodVerdict,
      calls = addr calls), "m", "prov", at)
    expect JudgeRefused:
      discard judgeTurn(home, turn, judged, fakeJudge(goodVerdict,
        calls = addr calls), "m", "prov", at)
    assert calls == 1
    removeDir(home)

  test "a written score from seconds ago refuses without calling":
    var calls = 0
    let judged = %*[{"type": "score", "turn_id": "t_eee555",
      "source": "judge", "ts": "2026-10-06T11:59:40+00:00"}]
    expect JudgeRefused:
      discard judgeTurn("/nonexistent-xyz", judgeTurnJson("t_eee555", "did"),
        judged, fakeJudge(goodVerdict, calls = addr calls), "m", "prov",
        "2026-10-06T12:00:00+00:00")
    assert calls == 0

  test "an unreadable verdict spends but writes no score":
    let home = judgeHome("waku-judge-badverdict")
    var calls = 0
    try:
      discard judgeTurn(home, judgeTurnJson("t_ccc333", "did it"),
        newJArray(), fakeJudge("no json here", calls = addr calls), "m",
        "prov", "2026-10-06T12:00:00+00:00")
      assert false, "should have refused"
    except JudgeRefused as exc:
      assert "readable score" in exc.msg
    assert calls == 1
    assert not dirExists(home / "traces")
    assert readFile(home / "usage.jsonl").strip().splitLines().len == 1
    removeDir(home)

suite "check table":
  test "the page lists the five checks in order":
    assert turnChecks.len == 5
    assert turnChecks[0][0] == "spend_claim"
    assert turnChecks[4][0] == "under_budget"

  test "a result carries source code with its note":
    let r = checkResult("spend_claim", %1, "match")
    assert r["source"].getStr() == "code"
    assert r["value"].getInt() == 1
    assert r["note"].getStr() == "match"
