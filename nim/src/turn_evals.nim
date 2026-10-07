## Turn evals — port of `waku/ops/turn_evals.py` (spec 015).
##
## Checks that grade a person's own turns, from the trace the agent already
## wrote. Five **code checks** are pure functions of one turn's trace events
## (pass = 1, fail = 0, n/a = null); the page runs them on every read, so
## nothing is written to disk for a code check. One **AI-judge check** runs
## only when the person presses "Judge this turn" and is written once, as a
## `score` trace event. A check grades a finished turn: it never stops,
## rewrites or delays a reply, and a check that raises is n/a ("check
## error"), never a broken page.
##
## `view` is what the checks read from one grouped turn
## (`observability.group_turns`); `research` rides in as a bool because the
## skill match (`matchingSkillNames` + `isResearch`) needs the home, and the
## checks stay pure. `ts` is kept as the raw stamp string; readers that need
## a clock parse it with `observability.parseTsMs`.

import std/json
import std/math
import std/os
import std/strutils
import ./observe
import ./wire

const
  defaultBudgetUsd* = 1.00
    ## `WAKU_TURN_BUDGET_USD` when unset, unreadable or not positive.
  budgetEnv* = "WAKU_TURN_BUDGET_USD"

  turnChecks* = [
    ("spend_claim", "the reply's spend matches the trace's treg dollars"),
    ("one_report", "a research turn saves exactly one report"),
    ("grounded_numbers",
      "the reply's numbers appear in a tool output, a memory or the message"),
    ("errors_handled",
      "every failed tool call was retried or mentioned in the reply"),
    ("under_budget", "the turn cost less than the per-turn budget (" &
      budgetEnv & ")"),
  ]
    ## What each check answers, in the order the Evals page lists them.

proc checkResult*(name: string, value: JsonNode, note: string): JsonNode =
  ## One score with source `code`: value 1 (pass), 0 (fail) or null (n/a).
  %*{"source": "code", "name": name, "value": value, "note": note}

proc budgetUsd*(): float =
  ## The per-turn budget: `WAKU_TURN_BUDGET_USD`, or $1.00 when it is unset
  ## or not a positive number.
  try:
    let raw = getEnv(budgetEnv, "")
    if raw.strip().len == 0:
      return defaultBudgetUsd
    let value = parseFloat(raw.strip())
    return if value > 0: value else: defaultBudgetUsd
  except ValueError:
    return defaultBudgetUsd

proc view*(turn: JsonNode, usd: JsonNode = newJNull(),
    research = false, servers: openArray[string] = []): JsonNode =
  ## What the checks read from one grouped turn: the message, the reply,
  ## each tool call with its whole output, the report events, the turn's
  ## dollars and whether the trace is v2 (it has a turn id, so its tool
  ## outputs are kept whole and its reports are traced).
  var tools: seq[JsonNode] = @[]
  var reports: seq[string] = @[]
  let events = turn.jget("events")
  if events.kind == JArray:
    for ev in events:
      if ev.jget("type").getStr() != "tool":
        if ev.jget("type").getStr() == "report":
          reports.add(ev.jget("memory_id").getStr())
        continue
      let info = describe(ev, servers)
      let toolName = ev.jget("tool")
      let outNode = ev.jget("output")
      tools.add(%*{"tool": (if toolName.kind == JString: toolName.getStr() else: ""),
        "args": ev.jget("args"),
        "output": (if outNode.kind == JString: outNode.getStr() else: ""),
        "ok": info.jget("ok"),
        "source": info.jget("source"),
        "cost_usd": info.jget("cost_usd"),
        "endpoint_id": info.jget("endpoint_id").getStr(),
        "provider": info.jget("provider").getStr()})
  %*{"message": turn.jget("user_message").getStr(),
    "reply": turn.jget("reply").getStr(),
    "tools": tools,
    "reports": reports,
    "usd": usd,
    "v2": turn.jget("turn_id").getStr().len > 0,
    "ts": turn.jget("ts").getStr(),
    "research": research,
    "unfinished": (turn.jget("unfinished").kind == JBool and
      turn.jget("unfinished").getBool())}

proc money*(usd: float): string =
  ## $0.00 for nothing, four places under a cent ($0.0089), else two.
  if usd == 0:
    return "$0.00"
  if abs(usd) < 0.01:
    return "$" & formatFloat(usd, ffDecimal, 4)
  var whole = int(abs(usd))
  let cents = int(round(abs(usd) * 100)) mod 100
  var digits = $whole
  var grouped = ""
  while digits.len > 3:
    grouped = "," & digits[^3 .. ^1] & grouped
    digits = digits[0 .. ^4]
  grouped = digits & grouped
  let sign = if usd < 0: "-" else: ""
  sign & "$" & grouped & "." & (if cents < 10: "0" & $cents else: $cents)

proc prose*(reply: string): string =
  ## The reply without its code blocks, inline code, links and emphasis.
  var text = reply
  # Fenced blocks first (they may hold backticks, links and emphasis).
  while true:
    let open = text.find("```")
    if open < 0:
      break
    let close = text.find("```", open + 3)
    if close < 0:
      text = text[0 ..< open] & " "
      break
    text = text[0 ..< open] & " " & text[close + 3 .. ^1]
  # Inline code (no newlines inside, like `[^`\n]*`).
  var noCode = ""
  var pos = 0
  while pos < text.len:
    let open = text.find('`', pos)
    if open < 0:
      noCode.add(text[pos .. ^1])
      break
    let close = text.find('`', open + 1)
    if close < 0:
      noCode.add(text[pos .. ^1])
      break
    if '\n' in text[open + 1 ..< close]:
      noCode.add(text[pos .. open])
      pos = open + 1
    else:
      noCode.add(text[pos ..< open] & " ")
      pos = close + 1
  text = noCode
  # Links and bare URLs: the URL goes, the words around it stay.
  var noUrls = ""
  var i = 0
  while i < text.len:
    var stop = -1
    if text[i] == '(' and (text[i + 1 .. ^1].startsWith("http://") or
        text[i + 1 .. ^1].startsWith("https://")):
      stop = i + 1
      while stop < text.len and text[stop] notin {' ', '\t', '\n', ')'}:
        inc stop
      if stop < text.len and text[stop] == ')':
        inc stop
    elif text[i .. ^1].startsWith("http://") or
        text[i .. ^1].startsWith("https://"):
      stop = i
      while stop < text.len and text[stop] notin {' ', '\t', '\n'}:
        inc stop
    if stop > i:
      noUrls.add(" ")
      i = stop
    else:
      noUrls.add(text[i])
      inc i
  text = noUrls
  # Emphasis runs.
  result = ""
  for ch in text:
    if ch notin {'*', '_', '~'}:
      result.add(ch)

proc sentences*(text: string): seq[string] =
  ## Sentences and list items: split at line breaks and after . ! ? before
  ## a space.
  for line in text.splitLines():
    var start = 0
    var i = 0
    while i < line.len:
      if line[i] in {'.', '!', '?'} and i + 1 < line.len and
          line[i + 1] in {' ', '\t'}:
        let piece = line[start .. i].strip()
        if piece.len > 0:
          result.add(piece)
        i += 2
        while i < line.len and line[i] in {' ', '\t'}:
          inc i
        start = i
      else:
        inc i
    let tail = line[start .. ^1].strip()
    if tail.len > 0:
      result.add(tail)
