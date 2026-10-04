## Research reports (spec 007, unit T2) and the 009 B cap.
##
## Offline only: scripted clients, stub save backends, temp homes.

import std/json
import std/strutils
import std/unittest

import ../src/brain
import ../src/loop
import ../src/memory_live
import ../src/reports

const marked = """Here is what I found so far.

<!-- waku-report v1 -->

# mem0 competitors

## Summary
- mem0 charges per seat
- zep is enterprise-only
- LangMem is the open one

## Findings
Long text that stays in the report."""

proc saveBackend(answer: string, fail = false): SaveBackend =
  result = SaveBackend(save: proc(args: JsonNode): string {.closure.} =
    if fail:
      raise newException(IOError, "server down")
    answer)

proc companyBackend(): SaveBackend =
  saveBackend("""{"id": "42"}""")

suite "find the report":
  test "a marker line opens a report":
    var r: Report
    assert findReport(marked, r)
    assert r.title == "mem0 competitors"
    assert r.summary.len == 3
    assert r.summary[0] == "mem0 charges per seat"
    assert r.body.startsWith(reportMarker)
    assert r.preface == "Here is what I found so far."

  test "no marker means no report":
    var r: Report
    assert not findReport("just a normal answer", r)
    assert not findReport("", r)
    assert not findReport("<!-- waku-report v1 --> inline", r)

suite "chat reply":
  test "the preface leads and the saved line names the report":
    var r: Report
    assert findReport(marked, r)
    let short = chatReply(r)
    assert short.startsWith("Here is what I found so far.")
    assert "Report saved: mem0 competitors." in short
    assert reportMarker notin short, "the report leaves the chat"

  test "no preface falls back to the summary's first bullets":
    var r: Report
    assert findReport(reportMarker & "\n\n# t\n\n## Summary\n- one\n- two", r)
    let short = chatReply(r)
    assert short.startsWith("one. two.")
    assert short.contains("Report saved: t.")

suite "the scope decision":
  test "true means company, anything else personal":
    proc ask(answer: string): (Report, bool) =
      var r: Report
      discard findReport(marked, r)
      let client = LlmClient(create: proc(req: JsonNode): JsonNode =
        %*{"content": [{"type": "text", "text": answer}]})
      var kinds: seq[string] = @[]
      var models: seq[string] = @[]
      let got = isCompanyResearch(client, "mini", r,
        proc(kind: string, ev: JsonNode) {.closure.} =
          if kind == "llm":
            kinds.add(ev["kind"].getStr())
            models.add(ev["model"].getStr()))
      (r, got and kinds == @["report"] and models == @["mini"])
    let (_, boolTrue) = ask("""{"company_research": true}""")
    let (_, strTrue) = ask("""{"company_research": "True"}""")
    let (_, no) = ask("""{"company_research": false}""")
    let (_, absent) = ask("{}")
    assert boolTrue, "a JSON true says company"
    assert strTrue, "so does the string True, like Python's str()"
    assert not no, "false is personal"
    assert not absent, "no flag at all is personal"

  test "an error is personal, never company":
    var r: Report
    discard findReport(marked, r)
    let client = LlmClient(create: proc(req: JsonNode): JsonNode =
      raise newException(IOError, "down"))
    assert not isCompanyResearch(client, "mini", r)

suite "save the report":
  test "company files global, personal files personal":
    var r: Report
    discard findReport(marked, r)
    var savedArgs: seq[JsonNode] = @[]
    var backend = SaveBackend(save: proc(args: JsonNode): string {.closure.} =
      savedArgs.add(args)
      """{"id": "42"}""")
    let company = saveReport(marked, backend,
      proc(one: Report): bool = true)
    assert company.reply != marked
    assert company.event["memory_id"].getStr() == "42"
    assert company.event["scope"].getStr() == companyScope
    let personal = saveReport(marked, backend,
      proc(one: Report): bool = false)
    assert personal.event["scope"].getStr() == personalScope
    # the whole report travels, not the short chat line
    assert savedArgs[0]["content"].getStr().startsWith(reportMarker)
    assert savedArgs[0]["type"].getStr() == reportType
    assert savedArgs[0]["capture_prompt"].getBool() == false

  test "no report, no backend or a failed send leaves the reply whole":
    let backend = companyBackend()
    assert saveReport("a normal answer", backend,
      proc(one: Report): bool = true).event.kind == JNull
    var r: Report
    discard findReport(marked, r)
    assert saveReport(marked, SaveBackend(),
      proc(one: Report): bool = true).reply == marked
    let failed = saveReport(marked, saveBackend("boom", true),
      proc(one: Report): bool = true)
    assert failed.reply == marked and failed.event.kind == JNull
    # an answer that names no id is a send that failed
    let anonymous = saveReport(marked, saveBackend("""{"ok": true}"""),
      proc(one: Report): bool = true)
    assert anonymous.reply == marked and anonymous.event.kind == JNull

suite "the 009 B cap":
  test "a fact the report names is dropped, at most two remain":
    assert aboutReport(%*{"subject": "Mem0"}, "we picked mem0 for the tail")
    assert not aboutReport(%*{"subject": "Alex"}, "we picked mem0")
    assert not aboutReport(%*{"subject": "m"}, "a mem0 report")

  test "the rule reaches the prompt with its cap":
    assert reportTurnMaxFacts == 2
    let prompt = reportRule.replace("{report}", "the report body")
    assert "at most 2" in prompt
    assert "the report body" in prompt