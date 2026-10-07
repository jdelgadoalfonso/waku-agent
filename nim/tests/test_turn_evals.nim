## Turn evals — the five code checks and the on-demand judge (spec 015).
##
## Offline only: crafted turns, no model, no sockets. The judge's model
## call rides an injected seam, so these pins never touch a network.

import std/json
import std/os
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
