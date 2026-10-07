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

# ---------------------------------------------------------------------------
# 2. one_report
# ---------------------------------------------------------------------------

import ./reports

const
  reportRefusalHead* = "Not sent. Waku saves"
    ## Upstream `REFUSAL[:20]`: a `memory_remember` answer that starts here
    ## refused the save, so it counts no report. The port never writes such
    ## an answer today; the skip stays so one would not count either.
  companyProject* = "Company brain"
    ## Upstream `COMPANY_PROJECT`: a `memory_remember` body filed here whose
    ## text has a "# " title with "## " sections is a report without the
    ## marker.

let
  saveAskRe = re(r"\b(save|saves|saving|store|storing)\b", {reIgnoreCase})
  reportShapeRe = re(r"(?:^|\\n|\n)# \S.*?(?:\\n|\n)## \S", {reIgnoreCase, reDotAll})
    ## A body the model sent to memory_remember that is a report without
    ## the marker: a "# " title and "## " sections, filed in the Company
    ## brain. `\\n` is a literal backslash-n: the body may be JSON text.
  noReportRe = re(r"\b(?:no|without(?: an?| any)?|skip(?: the)?|(?:don't|do not|dont) (?:need|want)(?: an?| any)?)\s+" &
    r"(?:report|reports|brief|snapshot|saving)\b|" &
    r"\b(?:don't|do not|dont|never)\s+(?:save|store)\b|" &
    r"\bjust (?:answer|tell me|reply)\b", {reIgnoreCase})

proc reportSaves*(v: JsonNode): seq[string] =
  ## One entry per report this turn saved, deduplicated by memory id: each
  ## `report` event, and each memory_remember call that Waku Memory took
  ## whose body is a report (it holds the marker, or a "# " title with
  ## "## " sections filed in the Company brain).
  var idx = 0
  for r in v.jget("reports"):
    result.add(if r.kind == JString and r.getStr().len > 0: r.getStr()
      else: "report-" & $idx)
    inc idx
  var i = 0
  for t in v.jget("tools"):
    inc i
    if not t.jget("tool").getStr().endsWith("_memory_remember"):
      continue
    if not t.jget("ok").getBool():
      continue
    if t.jget("output").getStr().startsWith(reportRefusalHead):
      continue
    let args = t.jget("args")
    let body = if args.kind == JObject: args.jget("body") else: args
    let text = if body.kind == JString: body.getStr() else: ""
    let whole = if args.kind == JObject: $args
      else: (if args.kind == JString: args.getStr() else: "")
    if reportMarker notin text and
        not (companyProject in whole and containsRe(text, reportShapeRe)):
      continue
    var memoryId = "remember-" & $i
    try:
      memoryId = parseJson(t.jget("output").getStr())["memory"]["id"].getStr()
    except CatchableError:
      discard
    if memoryId notin result:
      result.add(memoryId)

proc checkOneReport*(v: JsonNode): JsonNode =
  ## A research turn saves exactly one report; any turn that saves two
  ## fails. A turn is research when the research-report skill matched its
  ## message and the turn did research. A question answered from memory
  ## alone is n/a, and so is a turn whose message asks for no report;
  ## saving one anyway fails. With no Waku Memory connected no `report`
  ## event is written and the reply keeps the report, so a reply carrying
  ## the report marker counts as one. An older trace (no turn id) did not
  ## trace reports: n/a.
  let saves = reportSaves(v)
  if saves.len > 1:
    return checkResult("one_report", %0,
      $saves.len & " reports saved in one turn")
  if not v.jget("research").getBool():
    return checkResult("one_report", newJNull(), "not a research turn")
  if not v.jget("v2").getBool():
    return checkResult("one_report", newJNull(),
      "older trace: reports were not traced")
  if containsRe(v.jget("message").getStr(), noReportRe):
    if saves.len > 0:
      return checkResult("one_report", %0,
        "the message asked for no report and one was saved")
    return checkResult("one_report", newJNull(),
      "the message asked for no report")
  if saves.len == 1:
    return checkResult("one_report", %1, "one report saved")
  if reportMarker in v.jget("reply").getStr():
    return checkResult("one_report", %1,
      "the report is in the reply; no Waku Memory to save it to")
  if not containsRe(v.jget("message").getStr(), saveAskRe):
    var memoryOnly = true
    for t in v.jget("tools"):
      if t.jget("source").getStr() != "waku_memory":
        memoryOnly = false
        break
    if memoryOnly:
      return checkResult("one_report", newJNull(),
        "answered from memory: no research tool ran and no save was asked")
  checkResult("one_report", %0,
    "a research turn with no report saved and none in the reply")

# ---------------------------------------------------------------------------
# 3. grounded_numbers
# ---------------------------------------------------------------------------

import std/times

const
  groundedShare* = 0.9
    ## grounded_numbers passes when 90% of the numbers are found.
  groundedMinNumbers* = 3
    ## Below this many numbers the check is n/a.

  monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug",
    "sep", "oct", "nov", "dec"]
  scaleTable = [("thousand", 1e3), ("million", 1e6), ("billion", 1e9),
    ("bn", 1e9), ("mn", 1e6), ("k", 1e3), ("m", 1e6), ("b", 1e9)]

let
  isoDateRe = re(r"\b(\d{4})-(\d{2})-(\d{2})")
  mdyRe = re(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+" &
    r"(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b", {reIgnoreCase})
  dmyRe = re(r"\b(\d{1,2})(?:st|nd|rd|th)?\s+" &
    r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{4})\b",
    {reIgnoreCase})
  numberRe = re(r"(?<![\w.$-])(\$)?\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)" &
    r"(\s?%)?(?:\s?(thousand|million|billion|bn|mn|[kmb])\b)?(?![\w.-]*\w)",
    {reIgnoreCase})
  bareMantissaRe = re(r"\d[\d,]*\.?\d*")
  ordinalRe = re(r"\d+(?:st|nd|rd|th)\b", {reIgnoreCase})
  listNumberRe = re(r"^\s*\d+[.)]\s", {reMultiLine})
  scaleSuffixRe = re(r"(thousand|million|billion|bn|mn|[kmb])$",
    {reIgnoreCase})

proc monthNum(name: string): int =
  for i, m in monthNames:
    if name.toLowerAscii().startsWith(m):
      return i + 1
  0

proc scaleValue(suffix: string): float =
  let low = suffix.toLowerAscii()
  for (name, value) in scaleTable:
    if name == low:
      return value
  1.0

proc dashAscii(text: string): string =
  ## The Unicode dashes read as plain hyphens.
  text.replace("\u2010", "-").replace("\u2011", "-").replace("\u2012", "-")
    .replace("\u2013", "-").replace("\u2014", "-").replace("\u2212", "-")

proc replyDates(text: string): seq[tuple[iso: string, start, stop: int]] =
  ## (ISO date, span) for every date written as 2026-10-05,
  ## Oct 5, 2026 or 5 October 2026.
  var caps = newSeq[string](3)
  var start = 0
  while start <= text.len:
    let b = findBounds(text, isoDateRe, caps, start)
    if b.first < 0: break
    result.add((caps[0] & "-" & caps[1] & "-" & caps[2], b.first, b.last))
    start = b.first + max(b.last - b.first + 1, 1)
  for pat in [mdyRe, dmyRe]:
    let isMdy = pat == mdyRe
    caps = newSeq[string](3)
    start = 0
    while start <= text.len:
      let b = findBounds(text, pat, caps, start)
      if b.first < 0: break
      let month = monthNum(if isMdy: caps[0] else: caps[1])
      let day = parseInt(if isMdy: caps[1] else: caps[0])
      let iso = caps[2] & "-" & (if month < 10: "0" & $month else: $month) &
        "-" & (if day < 10: "0" & $day else: $day)
      result.add((iso, b.first, b.last))
      start = b.first + max(b.last - b.first + 1, 1)

type Wanted = object
  written: string
  isDate: bool
  iso: string
  values: seq[float]
  decimals: int
  scale: float

proc replyNumbers(reply: string, ts: string): seq[Wanted] =
  ## What grounded_numbers looks for: each money amount, percentage, date
  ## and number of two or more digits in the reply's prose. Ordinals, list
  ## numbers and code blocks are skipped, and so is the turn's own date, a
  ## day either side: it says when, not what was found.
  var text = replace(dashAscii(prose(reply)), listNumberRe, " ")
  var near: seq[string] = @[]
  if ts.len >= 10:
    try:
      let day = parse(ts[0 .. 9], "yyyy-MM-dd")
      for d in [-1, 0, 1]:
        near.add(format(day + initDuration(days = d), "yyyy-MM-dd"))
    except TimeParseError:
      discard
  var taken: seq[tuple[a, b: int]] = @[]
  for (iso, a, b) in replyDates(text):
    taken.add((a, b))
    if iso notin near:
      result.add(Wanted(written: text[a .. b], isDate: true, iso: iso))
  for g in findGroups(text, numberRe, 4):
    let whole = g[0]
    let start = text.find(whole)
    if start < 0:
      continue
    var inside = false
    for (a, b) in taken:
      if a <= start and start <= b:
        inside = true
        break
    if inside:
      continue
    var m: array[1, string]
    if match(text[start .. ^1], ordinalRe, m):
      continue
    let raw = g[2]
    let digits = raw.count({'0' .. '9'})
    let marked = g[1].len > 0 or g[3].len > 0 or g[4].len > 0
    if not marked and digits < 2:
      continue
    var value = parseAmount(raw)
    var scale = 1.0
    var sm: array[2, string]
    if find(text[start .. ^1], scaleSuffixRe, sm) >= 0:
      scale = scaleValue(sm[1])
      value *= scale
    let decimals = if "." in raw: raw.split(".")[1].len else: 0
    var values = @[value, value / scale]
    if "%" in whole:
      values.add(value / 100)
    result.add(Wanted(written: whole.strip(), isDate: false, values: values,
      decimals: decimals, scale: scale))

proc jsonStrings(node: JsonNode, depth = 0): seq[string] =
  ## Every string inside a decoded JSON value. A string that is itself
  ## JSON is decoded too, a few levels deep.
  case node.kind
  of JString:
    let s = node.getStr()
    let trimmed = s.strip()
    result = @[s]
    if depth < 3 and trimmed.len > 0 and trimmed[0] in {'{', '['}:
      try:
        result &= jsonStrings(parseJson(s), depth + 1)
      except JsonParsingError:
        discard
  of JObject:
    for _, v in node:
      result &= jsonStrings(v, depth)
  of JArray:
    for v in node:
      result &= jsonStrings(v, depth)
  else:
    result = @[]

proc sourceIndex(texts: seq[string]): tuple[numbers: seq[float], dates: seq[string]] =
  ## The numbers and dates in a turn's sources. A JSON source is read
  ## decoded too, so a memory body sent escaped still reads as written.
  var decoded: seq[string] = @[]
  for text in texts:
    try:
      decoded &= jsonStrings(parseJson(text))
    except JsonParsingError:
      discard
  for text in texts & decoded:
    let clean = dashAscii(text)
    for (iso, _, _) in replyDates(clean):
      if iso notin result.dates:
        result.dates.add(iso)
    for g in findGroups(clean, numberRe, 4):
      var value = parseAmount(g[2])
      var sm: array[2, string]
      if find(g[0], scaleSuffixRe, sm) >= 0:
        value *= scaleValue(sm[1])
      if value notin result.numbers:
        result.numbers.add(value)
    # a bare scaled figure in a source ("4.2M") also stands for its mantissa
    var caps = newSeq[string](0)
    var start = 0
    while start <= clean.len:
      let b = findBounds(clean, bareMantissaRe, caps, start)
      if b.first < 0: break
      let piece = clean[b.first .. b.last]
      start = b.first + max(b.last - b.first + 1, 1)
      if piece[^1].isDigit():
        try:
          let n = parseAmount(piece)
          if n notin result.numbers:
            result.numbers.add(n)
        except ValueError:
          discard

proc numberFound(values: seq[float], decimals: int, numbers: seq[float],
    scale = 1.0): bool =
  for v in values:
    if v in numbers:
      return true
  # "$0.01" is grounded by a source's 0.0089 when it rounds to it
  for n in numbers:
    for v in values:
      if round(n, decimals) == round(v, decimals) and
          abs(n - v) < 10.0 ^ (-decimals.float):
        return true
  # "$1.58M" is grounded by a source's raw 1575000: the source, in the
  # reply's unit, rounds to what the reply wrote
  if scale > 1:
    let half = 0.5 * 10.0 ^ (-decimals.float) + 1e-9
    for n in numbers:
      if n >= scale / 10 and abs(n / scale - values[1]) <= half:
        return true
  false

proc spendFigures(tools: JsonNode): seq[float] =
  ## What the trace says this turn's treg calls cost, each and in total:
  ## "the call cost $0.04" is grounded by the trace even when the call's
  ## own output does not repeat its price.
  var costs: seq[float] = @[]
  for t in tools:
    if t.jget("source").getStr() == "treg":
      let c = t.jget("cost_usd")
      if c.kind in {JInt, JFloat}:
        costs.add(toolCost(t))
  result = @[]
  var total = 0.0
  for c in costs:
    if round6(c) notin result:
      result.add(round6(c))
    total += c
  if costs.len > 0 and round6(total) notin result:
    result.add(round6(total))

proc checkGroundedNumbers*(v: JsonNode): JsonNode =
  ## Every money amount, percentage, date and number of two or more digits
  ## in the reply appears in a tool output, a Waku Memory result or the
  ## user's message of this turn, after normalising the format. The turn's
  ## own date is not a claim. Passes at 90% found; the note names up to
  ## three that were not. n/a below three numbers, for an older trace whose
  ## tool outputs may have been cut, and when a number is missing from a
  ## turn that ran no tool but Waku Memory: such a reply may quote the
  ## chat's earlier turns or recalled facts, which the trace does not keep.
  if not v.jget("v2").getBool():
    return checkResult("grounded_numbers", newJNull(),
      "older trace: tool outputs may be cut")
  let wanted = replyNumbers(v.jget("reply").getStr(), v.jget("ts").getStr())
  if wanted.len < groundedMinNumbers:
    return checkResult("grounded_numbers", newJNull(),
      $wanted.len & " number(s) in the reply; the check needs 3")
  var texts = @[v.jget("message").getStr()]
  for t in v.jget("tools"):
    texts.add(t.jget("output").getStr())
  let (numbers, dates) = sourceIndex(texts)
  var allNumbers = numbers & spendFigures(v.jget("tools"))
  var missing: seq[string] = @[]
  for w in wanted:
    var ok = false
    if w.isDate:
      ok = w.iso in dates
    else:
      ok = numberFound(w.values, w.decimals, allNumbers, w.scale)
    if not ok:
      missing.add(w.written)
  let found = wanted.len - missing.len
  let pass = found.float / wanted.len.float >= groundedShare
  var note = $found & " of " & $wanted.len &
    " numbers found in the turn's sources"
  if missing.len > 0:
    note &= "; not found: " & missing[0 ..< min(3, missing.len)].join(", ")
  if not pass:
    var memoryOnly = true
    for t in v.jget("tools"):
      if t.jget("source").getStr() != "waku_memory":
        memoryOnly = false
        break
    if memoryOnly:
      return checkResult("grounded_numbers", newJNull(),
        note & "; answered from memory, and the chat history and " &
        "recalled facts are not traced")
    return checkResult("grounded_numbers", %0, note)
  checkResult("grounded_numbers", %1, note)
