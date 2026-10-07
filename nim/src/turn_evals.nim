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
import std/sequtils
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

# ---------------------------------------------------------------------------
# 1. spend_claim
# ---------------------------------------------------------------------------

import std/re

let
  dollarRe = re(r"\$\s?(\d+(?:,\d{3})*(?:\.\d+)?)(?!\d|,\d|\.\d)" &
    r"(?!\s?(?:[kmb]|bn|mn|thousand|million|billion)\b)", {reIgnoreCase})
    ## A dollar figure, but not a scaled one: "$10M" is a funding round,
    ## never what a few tool calls cost.
  zeroRe = re(r"(?<!feel )\bfree\b(?![ -](?:tier|plan|trial|version|account|text|form|preview|credits?)\b)|\bno (?:cost|charge)\b|" &
    r"\b(?:cost|costs|spent|spend|billed|charged|paid)\s+(?:us\s+|me\s+)?(?:nothing|zero)\b|" &
    r"\$\s?0(?:\.0+)?\b(?!\.\d)", {reIgnoreCase})
  spendWordRe = re(r"\b(cost|costs|spent|spend|billed|charged|total|paid)\b",
    {reIgnoreCase})
  priceWordRe = re(r"\b(free|paid|price|priced|fee|charge)\b", {reIgnoreCase})
  laterRe = re(r"\b(would|will|that'd|that would|each|per row|per call|per result|if)\b|'ll\b",
    {reIgnoreCase})
  futureRe = re(r"\b(would|will|that'd|that would|if)\b|'ll\b", {reIgnoreCase})
  timesRe = re(r"\b(\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten|" &
    r"eleven|twelve)\s+(?:[\w.'-]+\s+){0,3}?" &
    r"(?:calls?|requests?|lookups?|queries|searches|pulls?|rows|results|records)\s+" &
    r"(?:at|for)\s+(?:about\s+|~)?\$\s?(\d[\d,]*(?:\.\d+)?)\s*(?:each|apiece|per\s+\w+|a\s+call)\b",
    {reIgnoreCase})

const
  countWords = ["zero", "one", "two", "three", "four", "five", "six",
    "seven", "eight", "nine", "ten", "eleven", "twelve"]
  spendToleranceUsd = 0.01
  spendToleranceShare = 0.20

proc countWord(word: string): int =
  let low = word.toLowerAscii()
  for i, w in countWords:
    if w == low:
      return i
  -1

proc parseAmount(raw: string): float =
  parseFloat(raw.replace(",", ""))

proc round6(x: float): float =
  floor(x * 1e6 + 0.5) / 1e6

proc findGroups(s: string, pat: Regex, groups: int): seq[seq[string]] =
  ## Every match as [whole, g1, ...] for a pattern with `groups` groups.
  var caps = newSeq[string](groups)
  var start = 0
  while start <= s.len:
    let bounds = findBounds(s, pat, caps, start)
    if bounds.first < 0:
      break
    var row = @[s[bounds.first .. bounds.last]]
    for c in caps:
      row.add(c)
    result.add(row)
    let whole = bounds.last - bounds.first + 1
    start = bounds.first + (if whole > 0: whole else: 1)

proc containsRe(s: string, pat: Regex): bool =
  var m: array[1, string]
  find(s, pat, m) >= 0

proc tregTools(tools: JsonNode): seq[JsonNode] =
  for t in tools:
    if t.jget("source").getStr() == "treg":
      let c = t.jget("cost_usd")
      if c.kind in {JInt, JFloat}:
        result.add(t)

proc toolCost(t: JsonNode): float =
  let c = t.jget("cost_usd")
  if c.kind == JInt: c.getInt().float else: c.getFloat()

proc namedTools(sentence: string, calls: seq[JsonNode]): seq[JsonNode] =
  ## The treg calls whose provider or endpoint the sentence names.
  let low = sentence.toLowerAscii()
  for t in calls:
    var names: seq[string] = @[]
    for k in ["provider", "endpoint_id"]:
      let n = t.jget(k).getStr().toLowerAscii()
      if n.len > 0 and n notin names:
        names.add(n)
    for n in names:
      var m: array[1, string]
      if find(low, re("(?<![a-z0-9])" & escapeRe(n) & r"(?![a-z0-9])"), m) >= 0:
        result.add(t)
        break

proc claimAmounts(sentence: string): tuple[skipped: bool, amounts: seq[float],
    written: seq[string]] =
  ## (figures stated for this turn) or skipped when the sentence only
  ## offers a price for later. "N calls at $X each" states N times X; any
  ## other "each" or "per call" is a price, not a spend.
  let times = findGroups(sentence, timesRe, 2)
  if times.len > 0 and not containsRe(sentence, futureRe):
    var amounts: seq[float] = @[]
    var written: seq[string] = @[]
    for g in times:
      let n = if g[1][0].isDigit(): parseInt(g[1]) else: countWord(g[1])
      let total = round6(n.float * parseAmount(g[2]))
      amounts.add(total)
      written.add(money(total))
    let rest = replace(sentence, timesRe, " ")
    for g in findGroups(rest, dollarRe, 1):
      amounts.add(parseAmount(g[1]))
      written.add(g[0].replace(" ", ""))
    return (false, amounts, written)
  if containsRe(sentence, laterRe):
    return (true, @[], @[])
  var amounts: seq[float] = @[]
  var written: seq[string] = @[]
  for g in findGroups(sentence, dollarRe, 1):
    amounts.add(parseAmount(g[1]))
    written.add(g[0].replace(" ", ""))
  (false, amounts, written)

proc checkSpendClaim*(v: JsonNode): JsonNode =
  ## The reply's spend matches the trace. A sentence states this turn's
  ## spend when it carries a dollar amount, "free" or "no cost" beside a
  ## spend word, or names a treg provider or endpoint of this turn beside
  ## a price word. "N calls at $X each" states N times X; any other price
  ## offered for later is skipped, and so is a scaled figure ("$10M") and
  ## "nothing" or "zero" away from a spend word. Fails when the reply
  ## claims $0, "free" or "no cost" while the calls cost more, or a figure
  ## off by more than $0.01 and 20%. n/a when the reply claims nothing.
  let calls = tregTools(v.jget("tools"))
  var claims = 0
  for sentence in sentences(prose(v.jget("reply").getStr())):
    let (skipped, amounts, written) = claimAmounts(sentence)
    if skipped:
      continue
    let zero = containsRe(sentence, zeroRe) and amounts.allIt(it == 0)
    let named = namedTools(sentence, calls)
    if amounts.len == 0 and not zero:
      continue
    if not (containsRe(sentence, spendWordRe) or
        (named.len > 0 and containsRe(sentence, priceWordRe))):
      continue
    let scope = if named.len > 0: named else: calls
    var actual = 0.0
    for t in scope:
      actual += toolCost(t)
    actual = round6(actual)
    var whose: string
    if named.len > 0:
      var providers: seq[string] = @[]
      for t in named:
        let p = if t.jget("provider").getStr().len > 0:
          t.jget("provider").getStr() else: t.jget("endpoint_id").getStr()
        if p notin providers:
          providers.add(p)
      whose = "the " & providers.join(", ") & " calls"
    else:
      whose = "this turn's treg calls"
    if named.len == 0 and not zero:
      var hasTreg = false
      var m: array[1, string]
      if find(sentence, re(r"\btreg\b", {reIgnoreCase}), m) >= 0:
        hasTreg = true
      if not hasTreg:
        continue
    inc claims
    let said = if written.len > 0: written[0] else: "free"
    if zero or (amounts.len > 0 and amounts.allIt(it == 0)):
      if actual > 0:
        return checkResult("spend_claim", %0,
          "reply says " & said & "; " & whose & " cost " & money(actual))
      continue
    var matches = false
    for a in amounts:
      if abs(a - actual) <= spendToleranceUsd or
          abs(a - actual) <= spendToleranceShare * actual:
        matches = true
        break
    if not matches:
      return checkResult("spend_claim", %0,
        "reply says " & said & "; " & whose & " cost " & money(actual))
  if claims == 0:
    return checkResult("spend_claim", newJNull(), "the reply states no spend")
  checkResult("spend_claim", %1,
    $claims & " spend claim" & (if claims != 1: "s" else: "") &
    " match the trace")
