## Pins for the hand-rolled OTLP span exporter (`src/otel.nim`): the
## endpoint contract the dashboard probe already owns, the span tree
## `waku/ops/tracing.py` builds, one POST per turn, and a failed export
## that never reaches the turn.
##
## The risk this suite exists for is a self-consistent but wrong mirror:
## an exporter whose own encoder also built the expectation would pass
## with any field naming at all. So the span tree below is written out as
## literal expected `Span` values — names, parents, kinds, attributes and
## their JSON text — and compared field by field, and the loopback test
## compares the bytes ON THE WIRE against `buildRequest` of those same
## literals rather than against anything the exporter said about itself.
##
## Offline by construction: every id and every timestamp is injected, so
## no golden value can move; the ONE real socket is a threaded stub bound
## to `127.0.0.1` (the precedent in `tests/test_http.nim`), and the one
## test that leaves the seams at their real defaults — real `urandom`,
## real clock, real socket — is the last one, so nothing it draws can be
## pinned by accident.

import std/json
import std/net
import std/os
import std/strutils
import std/unittest

import ../src/otel
import ../src/otelproto

# ── injected seams ────────────────────────────────────────────────────

const
  traceA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  rootA = "1111111111111111"
  childA = "2222222222222222"
  childB = "3333333333333333"
  childC = "4444444444444444"
  traceB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  rootB = "5555555555555555"
  childD = "6666666666666666"
    ## Fixed ids and a fixed clock. Every value is 0x-repetitive on
    ## purpose: an id read back with the wrong width shows up as the wrong
    ## string rather than as a coincidence.

proc scriptedClock(readings: seq[uint64]): ClockFn =
  ## A clock that walks a list of readings, repeating the last one once it
  ## runs out — a pinned test must fail on a wrong ORDER of reads, not on
  ## a clock that ran dry. The list is copied into the closure because a
  ## `seq` cannot be captured by reference without the compiler guessing
  ## about the caller's lifetime, and a seam outlives its argument.
  let stamps = readings
  var i = 0
  result = proc (): uint64 =
    let value = stamps[min(i, stamps.high)]
    inc i
    return value

proc scriptedIds(readings: seq[string]): IdFn =
  ## `urandom` replaced by ONE cursor over a fixed list, and passed to
  ## both id seams of one exporter. The order of mints is part of the
  ## tree: a trace id, the root's span id, then one per event, and a
  ## parent link is only right if the id that became the parent is the
  ## one the root carries. Two cursors would read the same list twice and
  ## hand a 32-digit trace id to an 8-byte span field.
  let ids = readings
  var i = 0
  result = proc (): string =
    let value = ids[min(i, ids.high)]
    inc i
    return value

type
  SendCall = object
    ## One POST as the seam saw it.
    url: string
    body: string

  Recorder = ref object
    ## The send seam's record. A `ref` rather than a captured `var seq`
    ## because a closure may not capture a seq by reference, and a
    ## recorder is exactly the thing a test reads after the call.
    calls: seq[SendCall]

proc recordingSend(rec: Recorder): SendFn =
  ## The send seam, captured: one entry per POST, in order.
  result = proc (url, body: string): ExportResult =
    rec.calls.add(SendCall(url: url, body: body))
    return (ok: true, detail: "")

proc failingSend(detail: string): SendFn =
  ## A collector that answered a refusal, or a socket that died: the two
  ## shapes a live turn must survive.
  result = proc (url, body: string): ExportResult =
    return (ok: false, detail: detail)

proc raisingSend(): SendFn =
  ## A sender that never returns an answer at all — the exception a real
  ## transport raises when a connection is refused.
  result = proc (url, body: string): ExportResult =
    raise newException(IOError, "connection refused")

proc byteAt(s: string, i: int): int =
  ## One byte of a captured or injected body, as 0..255. `ord` plus the
  ## mask rather than a cast: whether the platform's `char` is signed is
  ## not this suite's to assume, and the high bytes of a `fixed64`
  ## timestamp are exactly the ones a signed read would turn negative.
  ord(s[i]) and 0xFF

proc bodyBytes(s: string): seq[uint8] =
  ## A body as bytes, the way `buildRequest` produces them: the span tree
  ## this suite pins is compared against the wire byte for byte, so no
  ## text reading may happen on either side.
  result = newSeq[uint8](s.len)
  for i in 0 ..< s.len:
    result[i] = uint8(byteAt(s, i))

const refusedDetail = "collector answered 500 Internal Server Error"
  ## What a collector that took the POST and dropped it says. Status first
  ## and no payload: the one line this exporter prints has to fit inside a
  ## chat turn.

# ── expected trees, written out ───────────────────────────────────────

proc expectSpan(traceId, spanId, parent, name: string,
                startNano, endNano: uint64,
                attributes: seq[(string, string)]): Span =
  Span(traceId: traceId, spanId: spanId, parentSpanId: parent, name: name,
       kind: skInternal, startNano: startNano, endNano: endNano,
       attributes: attributes)

proc checkSpan(actual, expected: Span, label: string) =
  ## Field by field, with both sides printed: a whole-tree `==` on objects
  ## would say only "not equal" and send a reader back to the encoder.
  assert actual.traceId == expected.traceId,
    label & ".traceId " & actual.traceId & " != " & expected.traceId
  assert actual.spanId == expected.spanId,
    label & ".spanId " & actual.spanId & " != " & expected.spanId
  assert actual.parentSpanId == expected.parentSpanId,
    label & ".parentSpanId " & actual.parentSpanId & " != " &
    expected.parentSpanId
  assert actual.name == expected.name,
    label & ".name " & actual.name & " != " & expected.name
  assert actual.kind == expected.kind, label & ".kind"
  assert actual.startNano == expected.startNano,
    label & ".startNano " & $actual.startNano & " != " & $expected.startNano
  assert actual.endNano == expected.endNano,
    label & ".endNano " & $actual.endNano & " != " & $expected.endNano
  assert actual.attributes == expected.attributes,
    label & ".attributes " & $actual.attributes & " != " & $expected.attributes

proc expectedTreeA(rootEnd: uint64): seq[Span] =
  ## The turn below, spelled out: root `agent_run`, then an `llm`, a
  ## `tool` and a `gate`. Five clock readings, in order — root start,
  ## three children, root end. `rootEnd` is a parameter because the root's
  ## end is the ONE field that changes over the turn's life: 0 while the
  ## turn is open, the fifth reading once `endTurn` stamped it.
  @[
    expectSpan(traceA, rootA, "", "agent_run", 1000, rootEnd,
      @[("openinference.span.kind", "AGENT"),
        ("waku.user_message", "what is the weather in Tokyo?")]),
    expectSpan(traceA, childA, rootA, "llm", 2000, 2000,
      @[("openinference.span.kind", "LLM"),
        ("waku.provider", "\"anthropic\""),
        ("waku.model", "\"claude-sonnet-4-5\""),
        ("waku.usage", "{\"in\": 10, \"out\": 3}")]),
    expectSpan(traceA, childB, rootA, "tool.search", 3000, 3000,
      @[("openinference.span.kind", "TOOL"),
        ("waku.tool", "\"search\""),
        ("waku.query", "\"tokyo weather\"")]),
    expectSpan(traceA, childC, rootA, "gate.keep", 4000, 4000,
      @[("openinference.span.kind", "CHAIN"),
        ("waku.decision", "\"keep\"")]),
  ]

proc buildTurnA(t: SpanExporter) =
  ## The turn `expectedTreeA` describes: a stamped `llm` payload (Python
  ## merges `provider`/`model` in before both the JSONL row and the span),
  ## a tool, and a gate.
  t.turn("what is the weather in Tokyo?")
  t.event("llm", %*{"provider": "anthropic", "model": "claude-sonnet-4-5",
                    "usage": %*{"in": 10, "out": 3}})
  t.event("tool", %*{"tool": "search", "query": "tokyo weather"})
  t.event("gate", %*{"decision": "keep"})

proc exporterA(rec: Recorder): SpanExporter =
  ## The first turn's exporter: fixed ids, a fixed clock of five readings
  ## (root start, three children, root end), and a captured send.
  let stampsA = @[1000'u64, 2000, 3000, 4000, 5000]
  let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
  newSpanExporter("localhost:6006", clock = scriptedClock(stampsA),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))

# ── endpoint parsing ──────────────────────────────────────────────────

proc repoRoot(): string =
  ## The checkout root, read from this file's own path so the pins see
  ## the same tree whichever directory `nim c -r` ran from. The precedent
  ## is `tests/test_tls.nim`, which scans the sources the same way.
  absolutePath(currentSourcePath().parentDir / ".." / "..")

proc badCharList(text: string): string =
  ## The literal of the `for bad in [...]` line, verbatim — the four
  ## characters an endpoint may not contain. Comparing the two sources'
  ## copies is the only honest guard against a validator that drifts.
  for line in text.splitLines():
    if "for bad in" in line:
      let start = line.find('[')
      let stop = line.find(']')
      if start >= 0 and stop > start:
        return line[start .. stop]
  ""

proc closedLoopbackEndpoint(): string =
  ## An endpoint on `127.0.0.1` whose port answers nothing: the OS hands
  ## out a free one, this closes it, and the exporter then dials a port
  ## that is closed. The only way to test the real sender's own failure
  ## path — an injected sender never reaches it.
  var probe = newSocket()
  probe.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = probe.getLocalAddr()
  close(probe)
  "127.0.0.1:" & $port

suite "the OTLP endpoint, the dashboard probe's rules":
  test "bare host:port becomes an http traces URL":
    check parseOtlpEndpoint("localhost:6006") ==
      "http://localhost:6006/v1/traces"
    check parseOtlpEndpoint("127.0.0.1:4317") ==
      "http://127.0.0.1:4317/v1/traces"
    # the probe strips before it validates, and so does this
    check parseOtlpEndpoint("  phoenix.local:6006\t") ==
      "http://phoenix.local:6006/v1/traces"

  test "an explicit scheme is the one that is used":
    check parseOtlpEndpoint("http://localhost:6006") ==
      "http://localhost:6006/v1/traces"
    check parseOtlpEndpoint("https://otlp.example.com:443") ==
      "https://otlp.example.com:443/v1/traces"
    check parseOtlpEndpoint("HTTPS://Phoenix.Local:6006") ==
      "https://Phoenix.Local:6006/v1/traces"

  test "every rejection the dashboard otel probe makes":
    # Same refusals, same sentences as `liveProbes()["otel"]` in
    # `src/dashboard.nim`: no path, no query, no fragment, no `@`, exactly
    # one colon, a numeric port in range. Written out here rather than
    # imported from there because the point of the pin is that the two
    # copies agree, which an import could not check.
    let hostPort =
      "OTLP endpoint must be host:port (for example localhost:4317)"
    let rejected: seq[tuple[value, message: string]] = @[
      ("localhost:6006/v1/traces", hostPort),   # a path
      ("localhost:6006?trace=1", hostPort),     # a query
      ("localhost:6006#spans", hostPort),       # a fragment
      ("user@localhost:6006", hostPort),        # credentials
      ("localhost", hostPort),                 # no port
      ("localhost:6006:1", hostPort),          # two colons
      (":6006", hostPort),                     # no host
      ("localhost:0", hostPort),               # port below range
      ("localhost:70000", hostPort),           # port above range
      ("localhost:-1", hostPort),              # negative port
      ("localhost:abc", "OTLP endpoint must be a valid host:port"),
      ("grpc://localhost:4317",
        "OTLP endpoint scheme must be http or https (got grpc)"),
    ]
    for entry in rejected:
      try:
        discard parseOtlpEndpoint(entry.value)
        assert false, "must be refused: " & entry.value
      except ValueError as exc:
        assert exc.msg == entry.message,
          entry.value & ": " & exc.msg & " != " & entry.message
        # bounded: this text is what the constructor prints, inside a turn
        assert exc.msg.len <= 80, "unbounded refusal: " & exc.msg

  test "both copies of the rules are the same rules":
    # `src/otel.nim` cannot import the probe — it is a closure inside a
    # 3700-line dashboard module — so the rules are duplicated and the
    # duplication needs a guard. Restating the table above would not be
    # one: a change to dashboard.nim alone would still leave this suite
    # green. So the two SOURCES are compared instead, on the sentences the
    # probe prints and the characters it walks the endpoint looking for.
    let dashboard = readFile(repoRoot() / "nim" / "src" / "dashboard.nim")
    let exporter = readFile(repoRoot() / "nim" / "src" / "otel.nim")
    for sentence in ["OTLP endpoint must be host:port (for example localhost:4317)",
                     "OTLP endpoint must be a valid host:port"]:
      check sentence in dashboard
      check sentence in exporter
    let forbidden = badCharList(dashboard)
    assert forbidden.len > 0,
      "the probe's bad-character list moved and this pin stopped reading it"
    check badCharList(exporter) == forbidden

  test "an invalid endpoint is one line and no exporter":
    # The constructor is reached while a user is typing; a typo is a
    # message, never a crash in the middle of a conversation. One stderr
    # line each, and nothing left behind that could fail later in a turn.
    check newSpanExporter("localhost:6006/v1/traces").isNil
    check newSpanExporter("localhost:0").isNil

  test "an unset endpoint is no exporter at all":
    check newSpanExporter("").isNil
    check newSpanExporter("   ").isNil
    let none = newSpanExporter("")
    # nil is the "off" answer every proc above accepts, so a caller wires
    # it once and pays one nil check per turn
    none.turn("hello")
    none.event("llm", %*{"model": "m"})
    check none.flush() == (ok: true, detail: "")
    check none.endTurn() == (ok: true, detail: "")

  test "a live exporter is built from an endpoint alone":
    # The defaults T3 will use: real clock, real urandom, real socket. The
    # URL is all it takes to construct one.
    let ex = newSpanExporter("localhost:6006")
    check not ex.isNil
    check ex.url == "http://localhost:6006/v1/traces"
    check ex.spans.len == 0
    check ex.send != nil and ex.clock != nil
    let fresh = newTraceId()
    check fresh.len == 32 and fresh == fresh.toLowerAscii()
    check newSpanId().len == 16

# ── the span tree ─────────────────────────────────────────────────────

suite "the turn's span tree, mirrored from tracing.py":
  test "one root, children in call order, zero-duration children":
    let rec = Recorder()
    let ex = exporterA(rec)
    buildTurnA(ex)
    assert ex.spans.len == 4, "root plus three events"
    let expected = expectedTreeA(0)
    for i in 0 ..< expected.len:
      checkSpan(ex.spans[i], expected[i], "span[" & $i & "]")
    # the tree, said three more ways, because each one is a different
    # mistake: a second trace per event, a flat bag, or a child that
    # measured something nobody measured
    for child in ex.spans[1 .. ^1]:
      check child.traceId == traceA
      check child.parentSpanId == rootA
      check child.startNano == child.endNano
      check child.kind == skInternal
    check ex.spans[0].parentSpanId == ""
    assert ex.spans[0].endNano == 0, "the root is still open"
    # and the flush stamps it with the next reading, which is the whole
    # reason the tree above and the body below are the same turn
    assert ex.endTurn().ok, "an injected sender that answers 200 is silent"
    check rec.calls.len == 1
    check bodyBytes(rec.calls[0].body) == buildRequest(expectedTreeA(5000))

  test "the name is kind.tool, with Python's rstrip, as an attribute":
    # `f"{kind}.{event.get('tool', event.get('decision', ''))}".rstrip(".")`:
    # an `llm` with neither key builds "llm." and is named "llm"; a tool
    # whose name itself ends in a dot loses it, because `rstrip` removes
    # every trailing dot and not one.
    let rec = Recorder()
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
    let stamps = @[1'u64, 2, 3, 4, 5]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))
    ex.turn("q")
    ex.event("llm", %*{"model": "m"})
    ex.event("tool", %*{"tool": "search."})
    ex.event("gate", %*{})
    ex.event("gate", %*{"decision": "drop"})
    check ex.spans[1].name == "llm"
    check ex.spans[2].name == "tool.search"
    check ex.spans[3].name == "gate"
    check ex.spans[4].name == "gate.drop"
    # the taxonomy is attribute one of every span, and never the enum
    assert ex.spans[1].attributes[0] == ("openinference.span.kind", "LLM")
    assert ex.spans[2].attributes[0] == ("openinference.span.kind", "TOOL")
    assert ex.spans[3].attributes[0] == ("openinference.span.kind", "CHAIN")
    assert ex.spans[4].attributes[0] == ("openinference.span.kind", "CHAIN")
    for span in ex.spans:
      check span.kind == skInternal
    # `gate` with no fields at all still carries its kind and nothing else
    check ex.spans[3].attributes.len == 1

  test "every field is waku.<field> holding the JSON TEXT of its value":
    # Python: `{f"waku.{k}": json.dumps(v, default=str) ...}` — so a
    # number is "10", not 10, and `usage` arrives as Python-shaped JSON
    # text rather than as a nested message. `jsondump` is what makes the
    # bytes identical; `$node` would not.
    let rec = Recorder()
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
    let stamps = @[1'u64, 2, 3]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))
    ex.turn("q")
    ex.event("llm", %*{"usage": %*{"in": 10, "out": 3},
                       "ok": true, "nothing": newJNull(), "top": @[%1]})
    let child = ex.spans[1]
    check child.attributes == @[
      ("openinference.span.kind", "LLM"),
      ("waku.usage", "{\"in\": 10, \"out\": 3}"),
      ("waku.ok", "true"),
      ("waku.nothing", "null"),
      ("waku.top", "[1]")]

  test "no waku.type and no waku.ts — those are the JSONL row's own":
    # Python's span attributes come from the EVENT, not from the record
    # `_write` builds: `type` and `ts` exist only on the JSONL line. An
    # exporter that added them would claim a telemetry shape Python does
    # not emit, and `provider`/`model` are the ones that must be there.
    let rec = Recorder()
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
    let stamps = @[1'u64, 2, 3]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))
    ex.turn("q")
    ex.event("llm", %*{"provider": "anthropic", "model": "m"})
    for (key, _) in ex.spans[0].attributes:
      check key != "waku.type" and key != "waku.ts"
    for (key, _) in ex.spans[1].attributes:
      check key != "waku.type" and key != "waku.ts"
    assert ("waku.provider", "\"anthropic\"") in ex.spans[1].attributes
    assert ("waku.model", "\"m\"") in ex.spans[1].attributes

  test "a metered side call carries waku.kind, because Python stamps it":
    # `waku.kind` IS expected: `metered()` in `waku/ops/tracing.py:191`
    # reports `{"kind": "gate", ...}`, so the event that reaches the
    # exporter already has that field and Python turns every one of them
    # into an attribute. An exporter that dropped it would lose the one
    # attribute that says which small model answered.
    let rec = Recorder()
    let mint = scriptedIds(@[traceA, rootA, childA])
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(@[1'u64, 2]),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))
    ex.turn("q")
    ex.event("llm", %*{"kind": "gate", "model": "mini",
                       "usage": %*{"in": 5, "out": 0}})
    assert ("waku.kind", "\"gate\"") in ex.spans[1].attributes
    assert ("waku.model", "\"mini\"") in ex.spans[1].attributes

  test "text events and events outside a turn make no span":
    # Python returns from `event` for streaming `text` deltas before it
    # reaches the span block, and the span block is guarded by
    # `self._span_ctx is not None`: no turn open, no parent, no span.
    let rec = Recorder()
    let mint = scriptedIds(@[traceA, rootA])
    let stamps = @[1'u64, 2]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))
    ex.event("llm", %*{"model": "m"})       # no turn open: dropped
    ex.turn("q")
    ex.event("text", %*{"delta": "tok"})
    assert ex.spans.len == 1, "a text delta is for the live UI, not the trace"

# ── the flush ─────────────────────────────────────────────────────────

suite "one POST per turn":
  test "nothing is sent until endTurn, and the body is the whole turn":
    let rec = Recorder()
    let ex = exporterA(rec)
    buildTurnA(ex)
    assert rec.calls.len == 0, "a turn must not POST on every event"
    let outcome = ex.endTurn()
    check outcome == (ok: true, detail: "")
    check rec.calls.len == 1
    check rec.calls[0].url == "http://localhost:6006/v1/traces"
    check bodyBytes(rec.calls[0].body) == buildRequest(expectedTreeA(5000))
    assert ex.spans.len == 0, "the turn is closed after the flush"

  test "two turns flush twice, independently":
    let rec = Recorder()
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC,
                                   traceB, rootB, childD])
    # eight readings: five for the first turn, three for the second
    let stamps = @[1000'u64, 2000, 3000, 4000, 5000, 6000, 7000, 8000]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = recordingSend(rec))
    buildTurnA(ex)
    check ex.endTurn().ok
    check ex.spans.len == 0
    ex.turn("second")
    ex.event("tool", %*{"tool": "fetch"})
    check ex.endTurn().ok
    check rec.calls.len == 2
    # the second body is the SECOND turn alone: no leaked child, no leaked
    # trace id, and its own root end
    let second = @[
      expectSpan(traceB, rootB, "", "agent_run", 6000, 8000,
        @[("openinference.span.kind", "AGENT"),
          ("waku.user_message", "second")]),
      expectSpan(traceB, childD, rootB, "tool.fetch", 7000, 7000,
        @[("openinference.span.kind", "TOOL"), ("waku.tool", "\"fetch\"")])]
    check bodyBytes(rec.calls[1].body) == buildRequest(second)
    check bodyBytes(rec.calls[0].body) == buildRequest(expectedTreeA(5000))

  test "an endTurn with no turn open sends nothing":
    let rec = Recorder()
    let ex = exporterA(rec)
    check ex.endTurn() == (ok: true, detail: "")
    check ex.endTurn() == (ok: true, detail: "")
    check rec.calls.len == 0
    check ex.flush() == (ok: true, detail: "")

# ── failure policy ────────────────────────────────────────────────────

suite "a failed export never reaches the turn":
  test "a sender that raises is a result, not an exception":
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
    let stamps = @[1'u64, 2, 3]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = raisingSend())
    buildTurnA(ex)
    let outcome = ex.endTurn()          # must not raise
    check not outcome.ok
    check outcome.detail.len > 0
    assert ex.spans.len == 0, "and the exporter is clean for the next turn"

  test "a collector that answers 500 is the same shape":
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
    let stamps = @[1'u64, 2, 3]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = failingSend(refusedDetail))
    buildTurnA(ex)
    let outcome = ex.endTurn()
    check not outcome.ok
    check "500" in outcome.detail
    assert "waku." notin outcome.detail, "a reason never carries the payload"

  test "the exporter keeps working after a failure":
    let rec = Recorder()
    var broken = true
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC,
                                   traceB, rootB, childD])
    let stamps = @[1'u64, 2, 3, 4, 5, 6, 7]
    let send = proc (url, body: string): ExportResult =
      if broken:
        return (ok: false, detail: refusedDetail)
      rec.calls.add(SendCall(url: url, body: body))
      return (ok: true, detail: "")
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = send)
    buildTurnA(ex)
    check not ex.endTurn().ok
    broken = false
    ex.turn("second")
    ex.event("tool", %*{"tool": "fetch"})
    check ex.endTurn().ok
    assert rec.calls.len == 1, "the recovered turn sent exactly once"

  test "the returned reason is bounded":
    # Whatever a sender reports is cut to the same bound the printed line
    # uses, so a caller that logs the result cannot print more than the
    # terminal showed.
    let mint = scriptedIds(@[traceA, rootA, childA, childB, childC])
    let stamps = @[1'u64, 2, 3]
    let ex = newSpanExporter("localhost:6006", clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint,
                  send = failingSend("x".repeat(4000)))
    buildTurnA(ex)
    let outcome = ex.endTurn()
    check not outcome.ok
    assert outcome.detail.len <= 200,
      "one terminal line, not the sender's report: " & $outcome.detail.len
    assert outcome.detail.endsWith("..."), "and the cut says it was cut"

  test "a real collector that is not there fails the same way":
    # The tests above inject a sender, so they pin `flush`'s wrapper. This
    # one leaves the REAL sender in place and points it at a loopback port
    # nothing answers on, because "the collector is down" is the failure a
    # user actually hits — and it is `postSpans`' own `except` that has to
    # catch it, not just the wrapper around it.
    let ex = newSpanExporter(closedLoopbackEndpoint())
    ex.turn("q")
    ex.event("llm", %*{"model": "m"})
    let outcome = ex.endTurn()
    check not outcome.ok
    check outcome.detail.len > 0
    # and the exporter is still good for the next turn: a refused export
    # is a line on stderr, not a broken agent.
    ex.turn("q2")
    assert ex.spans.len == 1
    check not ex.endTurn().ok

# ── one real socket, on loopback ──────────────────────────────────────

const loopbackPort = 18097

type Captured = object
  ## What the stub saw, verbatim: the request line, the headers as they
  ## arrived, and the body as bytes. Recorded here and asserted in the
  ## main thread, so nothing the exporter says about its own request is
  ## what this test checks.
  reqLine: string
  headers: seq[(string, string)]
  body: string

var captures: Channel[Captured]
var loopbackThread: Thread[void]
var loopbackStarted = false

proc recvExactly(client: Socket, n: int): string =
  ## `n` bytes, no more and no less. A protobuf body is binary and
  ## carries `0x00`, so a read has to be byte-counted rather than
  ## line-based; `recv` returns bytes as they came, which is the whole
  ## reason this helper needs no encoding.
  result = newStringOfCap(n)
  while result.len < n:
    let chunk = client.recv(n - result.len)
    if chunk.len == 0:
      break
    result.add(chunk)

proc serveLoopback() {.thread.} =
  ## A stub collector: reads one request, records it, answers `200` with
  ## an empty body — or `500` when the turn says `fail-on-purpose`, the
  ## only way a test can make a real socket refuse without a shared flag.
  ## It opens nothing but `127.0.0.1` and never resolves a name, so the
  ## suite cannot reach the network even by accident.
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(loopbackPort), "127.0.0.1")
  server.listen()
  while true:
    var client: Socket
    accept(server, client)
    try:
      var captured = Captured(reqLine: client.recvLine(), headers: @[],
                              body: "")
      var contentLen = 0
      try:
        while true:
          let line = client.recvLine()
          if line.strip().len == 0:
            break
          let parts = line.split(":", 1)
          if parts.len == 2:
            captured.headers.add((parts[0].strip().toLowerAscii(),
                                  parts[1].strip()))
            if parts[0].strip().toLowerAscii() == "content-length":
              contentLen = parseInt(parts[1].strip())
      except ValueError:
        discard
      if contentLen > 0:
        captured.body = recvExactly(client, contentLen)
      # the readiness probe connects and closes: that is not a request
      if captured.reqLine.len > 0:
        captures.send(captured)
      let status = if "fail-on-purpose" in captured.body:
        "500 Internal Server Error"
      else:
        "200 OK"
      client.send("HTTP/1.1 " & status &
        "\r\nContent-Type: application/x-protobuf" &
        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    except OSError:
      discard
    try: client.close()
    except OSError: discard

proc waitLoopback(port: int) =
  ## The stub may need a moment to reach `listen`; dial until it answers.
  for _ in 0 ..< 100:
    try:
      var s = newSocket()
      s.connect("127.0.0.1", Port(port))
      s.close()
      return
    except OSError:
      sleep(50)
  raise newException(CatchableError, "loopback stub did not start")

proc ensureLoopback() =
  if not loopbackStarted:
    loopbackStarted = true
    open(captures, 8)
    createThread(loopbackThread, serveLoopback)
    waitLoopback(loopbackPort)

proc nextCapture(): Captured =
  ## The next request the stub recorded, or a failure rather than a hang:
  ## a socket that never arrives is a broken test, not a slow one.
  for _ in 0 ..< 500:
    if captures.peek() > 0:
      return captures.recv()
    sleep(10)
  raise newException(ValueError, "the loopback stub recorded no request")

proc headerValue(captured: Captured, name: string): string =
  for (key, value) in captured.headers:
    if key == name:
      return value
  return ""

suite "the POST, for real, on loopback":
  test "one POST carries the whole turn, protobuf and headers and all":
    ensureLoopback()
    let mint = scriptedIds(@[traceA, rootA, childA, childB])
    let stamps = @[1000'u64, 2000, 3000, 4000]
    let ex = newSpanExporter("127.0.0.1:" & $loopbackPort,
                  clock = scriptedClock(stamps),
                  mintTraceId = mint, mintSpanId = mint)
    ex.turn("what is the weather in Tokyo?")
    ex.event("llm", %*{"provider": "anthropic", "model": "m",
                       "usage": %*{"in": 10, "out": 3}})
    ex.event("tool", %*{"tool": "search", "query": "tokyo weather"})
    let outcome = ex.endTurn()
    assert outcome == (ok: true, detail: ""), "a 200 is the silent path"

    let captured = nextCapture()
    let parts = captured.reqLine.split(' ')
    assert parts.len == 3, "a full request line: " & captured.reqLine
    check parts[0] == "POST"
    check parts[1] == "/v1/traces"
    assert headerValue(captured, "content-type") == "application/x-protobuf"
    assert headerValue(captured, "accept") == "application/x-protobuf"
    let declared = parseInt(headerValue(captured, "content-length"))
    assert declared == captured.body.len,
      "the declared length and the body the stub read disagree"
    # the bytes on the wire are the encoded turn, root first
    let expected = @[
      expectSpan(traceA, rootA, "", "agent_run", 1000, 4000,
        @[("openinference.span.kind", "AGENT"),
          ("waku.user_message", "what is the weather in Tokyo?")]),
      expectSpan(traceA, childA, rootA, "llm", 2000, 2000,
        @[("openinference.span.kind", "LLM"),
          ("waku.provider", "\"anthropic\""), ("waku.model", "\"m\""),
          ("waku.usage", "{\"in\": 10, \"out\": 3}")]),
      expectSpan(traceA, childB, rootA, "tool.search", 3000, 3000,
        @[("openinference.span.kind", "TOOL"), ("waku.tool", "\"search\""),
          ("waku.query", "\"tokyo weather\"")])]
    check bodyBytes(captured.body) == buildRequest(expected)
    # the first byte is `ExportTraceServiceRequest.resourceSpans` (field 1,
    # wire type 2) = 0x0A: the byte a truncated or text-mangled body loses
    check captured.body.len > 0
    check byteAt(captured.body, 0) == 0x0A

  test "the real seams export a real turn without being told what to send":
    # No injected clock, no injected ids, no injected send: `urandom`,
    # `epochTime` and the socket do the work, exactly as they will in a
    # run. The pins are the shapes Python's SDK requires of an id and the
    # order a collector draws a tree in.
    ensureLoopback()
    let ex = newSpanExporter("127.0.0.1:" & $loopbackPort)
    ex.turn("hello from the port")
    ex.event("tool", %*{"tool": "search", "query": "waku"})
    # read the tree BEFORE the flush resets it: this is the real minting
    # and the real clock, and the widths here are what a collector reads
    let root = ex.spans[0]
    let child = ex.spans[1]
    check ex.endTurn().ok
    assert ex.spans.len == 0, "flushed and reset"
    check root.traceId.len == 32
    check root.traceId == root.traceId.toLowerAscii()
    check root.spanId.len == 16
    check child.spanId.len == 16 and child.spanId != root.spanId
    check child.parentSpanId == root.spanId
    check child.traceId == root.traceId
    check child.startNano == child.endNano and child.startNano > 0
    # the root's own END is stamped after this copy was taken; the value
    # that reaches the wire is pinned by the body comparison above
    check root.startNano > 0

  test "a real collector that refuses is a failure the turn never sees":
    # The one branch an injected sender cannot cover: the real socket's
    # status handling. The stub answers 500 because the turn's user message
    # says `fail-on-purpose`, so nothing is shared between the threads but
    # the bytes on the wire.
    ensureLoopback()
    let ex = newSpanExporter("127.0.0.1:" & $loopbackPort)
    ex.turn("fail-on-purpose")
    let refused = ex.endTurn()
    assert not refused.ok, "a 500 must not read as a silent success"
    assert "500" in refused.detail,
      "the status is the reason, not a guess: " & refused.detail
    assert ex.spans.len == 0, "and the exporter is clean for the next turn"
    let first = nextCapture()
    assert byteAt(first.body, 0) == 0x0A, "the bytes went out either way"
    ex.turn("hello again")
    assert ex.endTurn().ok, "and the next turn reaches the collector"
    check byteAt(nextCapture().body, 0) == 0x0A

    let captured = nextCapture()
    check captured.reqLine.split(' ')[1] == "/v1/traces"
    check bodyBytes(captured.body).len > 0
    check byteAt(captured.body, 0) == 0x0A

suite "what the exporter writes down":
  test "the clock reads Unix nanoseconds, and the ids are OTLP widths":
    # Not pins of a value (that would be a flaky clock) but of the two
    # things a collector reads: an epoch-scale nanosecond stamp and hex of
    # the width `trace.proto` demands.
    let now = unixNanoNow()
    assert now > 1_600_000_000_000_000_000'u64, "nanoseconds, not seconds"
    check newTraceId().len == 32
    check newSpanId().len == 16
    assert newTraceId() != newTraceId(), "two mints, two traces"
    let minted = mintHexId(8)
    check minted.len == 16 and minted == minted.toLowerAscii()
    for c in minted:
      check c in {'0' .. '9', 'a' .. 'f'}