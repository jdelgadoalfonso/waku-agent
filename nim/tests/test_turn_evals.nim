## Turn evals — the five code checks and the on-demand judge (spec 015).
##
## Offline only: crafted turns, no model, no sockets. The judge's model
## call rides an injected seam, so these pins never touch a network.

import std/json
import std/os
import std/strutils
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
