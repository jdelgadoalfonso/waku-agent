## Golden bytes for the hand-rolled OTLP encoder.
##
## The risk in this unit is a self-consistent but wrong encoder. A test
## that built its expected bytes by calling `buildRequest` would pass
## with any field number at all, because the writer and the expectation
## would be the same code. So everything below is written from the field
## numbers in `opentelemetry/proto/{common,resource,trace}/v1` and
## `collector/trace/v1`: the walker at the top knows the wire format and
## nothing about `otelproto`, and the literals in the second suite were
## counted by hand.
##
## Offline: no socket, no clock, no key. Every id and timestamp is
## injected, which is also what proves the encoder mints nothing.

import std/re
import std/strutils
import std/unittest

import ../src/otelproto

# ── a protobuf reader written from the wire format ───────────────────

type
  WireField = object
    ## One field, as the wire format describes it. `value` is the
    ## varint, the little-endian number, or the declared length, so a
    ## pin compares against the number it injected instead of against a
    ## second decoding of the writer's own bytes. `tag` is kept because
    ## the tag byte is the first thing a wrong field number breaks.
    number: int
    wireType: int
    value: uint64
    payload: seq[uint8]
    tag: seq[uint8]

proc readVarint(buf: openArray[uint8],
                start: int): tuple[value: uint64, next: int] =
  ## Base-128 varint: seven bits per byte, lowest group first, the high
  ## bit meaning "another byte follows". A zero is one `0x00` byte.
  var value = 0'u64
  var shift = 0
  var i = start
  while true:
    if i >= buf.len:
      raise newException(ValueError, "truncated varint")
    let b = buf[i]
    inc i
    value = value or (uint64(b and 0x7F'u8) shl shift)
    if (b and 0x80'u8) == 0:
      break
    shift += 7
  (value, i)

proc walk(buf: openArray[uint8]): seq[WireField] =
  ## Every top-level field of one message, in the order it arrived. The
  ## three wire types this port emits are all of it: 0 (varint), 1
  ## (fixed64) and 2 (length-delimited). Any other type fails here
  ## rather than being skipped, so a field written under an unexpected
  ## type cannot pass unnoticed.
  var i = 0
  while i < buf.len:
    let tagStart = i
    let (tag, afterTag) = readVarint(buf, i)
    let wireType = int(tag and 7'u64)
    var value = 0'u64
    var payload: seq[uint8] = @[]
    i = afterTag
    case wireType
    of 0:
      let (decoded, after) = readVarint(buf, i)
      value = decoded
      payload = buf[afterTag ..< after]
      i = after
    of 1:
      if i + 8 > buf.len:
        raise newException(ValueError, "truncated fixed64")
      for k in 0 ..< 8:
        value = value or (uint64(buf[i + k]) shl (8 * k))
      payload = buf[i ..< i + 8]
      i += 8
    of 2:
      let (length, afterLen) = readVarint(buf, i)
      if afterLen + int(length) > buf.len:
        raise newException(ValueError, "truncated length-delimited field")
      value = length
      payload = buf[afterLen ..< afterLen + int(length)]
      i = afterLen + int(length)
    else:
      raise newException(ValueError, "unexpected wire type " & $wireType)
    result.add(WireField(number: int(tag shr 3), wireType: wireType,
                         value: value, payload: payload,
                         tag: buf[tagStart ..< afterTag]))

proc fieldShape(fields: seq[WireField]): string =
  ## The field numbers a message actually carries. A missing field is the
  ## failure this suite hunts, so the message has to show what was there
  ## instead — otherwise a wrong field number reads as a bare "no field 9".
  result = ""
  for f in fields:
    result.add(if result.len > 0: ", " else: "")
    result.add($f.number)

proc pick(fields: seq[WireField], number: int): WireField =
  ## The first field carrying that number. An absent field fails here,
  ## which is what pins "a root span writes no `parent_span_id`": a
  ## missing field has to be a failure, not an empty comparison.
  for f in fields:
    if f.number == number:
      return f
  raise newException(ValueError, "no field " & $number & " in this message, " &
    "which carries " & (if fields.len == 0: "nothing" else: fieldShape(fields)))

proc has(fields: seq[WireField], number: int): bool =
  for f in fields:
    if f.number == number:
      return true
  false

proc shape(fields: seq[WireField]): string =
  ## `1:2 2:2 6:0 7:1` — the field-number/wire-type skeleton, so a pin
  ## reads as the `.proto` line it is instead of a list of numbers.
  for f in fields:
    result.add($f.number & ":" & $f.wireType & " ")

proc numbers(fields: seq[WireField]): seq[int] =
  for f in fields:
    result.add(f.number)

proc textOf(payload: openArray[uint8]): string =
  ## A length-delimited field read back as text. Strings are never
  ## walked: their bytes ARE the value, and feeding them to `walk` would
  ## read the first character as a tag.
  for b in payload:
    result.add(char(b))

proc hexOf(buf: openArray[uint8]): string =
  ## Lowercase hex, so a failing pin reads as bytes instead of a
  ## sequence of decimal numbers.
  const digits = "0123456789abcdef"
  for b in buf:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

# ── fixtures ─────────────────────────────────────────────────────────

const
  traceId = "0af7651916cd43dd8448eb211c80319c"
  rootId = "b7ad6b7169203331"
  childId = "b9c7c989f97918e1"
    ## A span id from the OpenTelemetry specification's own worked
    ## example: it shares no digit run with the other two, so a field
    ## carrying the wrong id cannot pass by looking right.
  startNano = 1_700_000_000_000_000_000'u64
    ## 1700000000000000000: the nanosecond shape a Unix clock hands out.
  turnNano = startNano + 4_000_000_000'u64

proc rootSpan(): Span =
  Span(traceId: traceId, spanId: rootId, parentSpanId: "",
    name: "agent_run", kind: skInternal,
    startNano: startNano, endNano: turnNano,
    attributes: @[("waku.user_message", "\"hola\"")])

proc childSpan(): Span =
  Span(traceId: traceId, spanId: childId, parentSpanId: rootId,
    name: "llm.gather", kind: skInternal,
    startNano: startNano, endNano: startNano,
    attributes: @[("waku.in", "10"), ("waku.out", "2")])

# ── navigation, one `.proto` level at a time ─────────────────────────

proc resourceSpansOf(request: openArray[uint8]): seq[WireField] =
  ## ExportTraceServiceRequest field 1 is `resource_spans`.
  walk(pick(walk(request), 1).payload)

proc resourceOf(request: openArray[uint8]): seq[WireField] =
  ## ResourceSpans field 1 is the Resource.
  walk(pick(resourceSpansOf(request), 1).payload)

proc scopeSpansOf(request: openArray[uint8]): seq[WireField] =
  ## ResourceSpans field 2 is `scope_spans`.
  walk(pick(resourceSpansOf(request), 2).payload)

proc scopeOf(request: openArray[uint8]): seq[WireField] =
  ## ScopeSpans field 1 is the InstrumentationScope.
  walk(pick(scopeSpansOf(request), 1).payload)

proc spansOf(request: openArray[uint8]): seq[seq[WireField]] =
  ## ScopeSpans field 2, repeated: the Span entries, in the order they
  ## were sent, each already walked. A list because a repeated field has
  ## no index to ask for and only its position to read.
  for f in scopeSpansOf(request):
    if f.number == 2:
      result.add(walk(f.payload))

proc spanOf(request: openArray[uint8]): seq[WireField] =
  ## The one span of a one-span request, already walked.
  spansOf(request)[0]

# ── the span, field by field ─────────────────────────────────────────

suite "a span carries exactly the fields trace.proto declares":
  test "a root span omits parent_span_id and trace_state":
    # trace.proto declares nine fields on Span: 1 trace_id, 2 span_id,
    # 3 trace_state, 4 parent_span_id, 5 name, 6 kind,
    # 7 start_time_unix_nano, 8 end_time_unix_nano, 9 attributes. A
    # root span writes 3 and 4 not at all.
    let span = spanOf(buildRequest(@[rootSpan()]))
    assert numbers(span) == @[1, 2, 5, 6, 7, 8, 9],
      "root span fields: " & shape(span)
    assert not has(span, 3)
    assert not has(span, 4)

  test "a child span writes field 4 as its parent's eight bytes":
    let span = spanOf(buildRequest(@[childSpan()]))
    assert numbers(span) == @[1, 2, 4, 5, 6, 7, 8, 9, 9],
      "child span fields: " & shape(span)
    let parent = pick(span, 4)
    assert parent.wireType == 2 and parent.value == 8'u64
    assert hexOf(parent.payload) == "b7ad6b7169203331",
      "parent_span_id bytes: " & hexOf(parent.payload)

  test "the ids travel as raw bytes, not as the hex a human reads":
    # trace_id and span_id are `bytes` fields: a collector compares 16
    # and 8 raw bytes. Sending the 32 hex characters instead would put
    # the span in a trace that does not exist.
    let span = spanOf(buildRequest(@[rootSpan()]))
    let trace = pick(span, 1)
    let id = pick(span, 2)
    assert trace.wireType == 2 and trace.value == 16'u64,
      "trace_id length: " & $trace.value
    assert hexOf(trace.payload) == "0af7651916cd43dd8448eb211c80319c",
      "trace_id bytes: " & hexOf(trace.payload)
    assert id.wireType == 2 and id.value == 8'u64,
      "span_id length: " & $id.value
    assert hexOf(id.payload) == "b7ad6b7169203331",
      "span_id bytes: " & hexOf(id.payload)

  test "the name is field 5 as a string":
    let span = spanOf(buildRequest(@[childSpan()]))
    let name = pick(span, 5)
    assert name.wireType == 2
    assert textOf(name.payload) == "llm.gather"

  test "the kind is field 6 as the enum's own ordinal":
    # SpanKind is declared UNSPECIFIED=0, INTERNAL=1, SERVER=2,
    # CLIENT=3, PRODUCER=4, CONSUMER=5, and travels as wire type 0.
    # The ordinal IS the wire value, so both must be one byte.
    let declared = [skUnspecified, skInternal, skServer, skClient,
                    skProducer, skConsumer]
    for index, kind in declared:
      var span = rootSpan()
      span.kind = kind
      let field = pick(spanOf(buildRequest(@[span])), 6)
      assert field.wireType == 0
      assert field.value == uint64(index)
      assert field.payload == @[uint8(index)],
        "kind bytes for " & $kind & ": " & hexOf(field.payload)

  test "the timestamps are fixed64 and read back as injected":
    # 7 start_time_unix_nano and 8 end_time_unix_nano are `fixed64`, so
    # the collector reads eight little-endian bytes, not a varint.
    let span = spanOf(buildRequest(@[rootSpan()]))
    let start = pick(span, 7)
    let finish = pick(span, 8)
    assert start.wireType == 1 and start.value == startNano,
      "start_time_unix_nano: " & $start.value
    assert finish.wireType == 1 and finish.value == turnNano,
      "end_time_unix_nano: " & $finish.value

  test "each attribute is a KeyValue of a key and a string AnyValue":
    # 9 attributes is `repeated KeyValue`; KeyValue is 1 key (string)
    # and 2 value (AnyValue); AnyValue.string_value is field 1. The
    # values are strings because Python's mirror json-dumps them, so a
    # token count arrives as the string "10".
    var pairs: seq[(string, string)] = @[]
    for field in spanOf(buildRequest(@[childSpan()])):
      if field.number != 9:
        continue
      let attribute = walk(field.payload)
      assert numbers(attribute) == @[1, 2],
        "KeyValue fields: " & shape(attribute)
      let anyValue = walk(pick(attribute, 2).payload)
      assert numbers(anyValue) == @[1],
        "AnyValue fields: " & shape(anyValue)
      pairs.add((textOf(pick(attribute, 1).payload),
                 textOf(pick(anyValue, 1).payload)))
    assert pairs == @[("waku.in", "10"), ("waku.out", "2")],
      "attributes: " & $pairs

  test "the request wraps them in one resource and one scope":
    # ExportTraceServiceRequest.resource_spans is field 1;
    # ResourceSpans.resource is field 1 and scope_spans is field 2;
    # Resource.attributes is field 1; ScopeSpans.scope is field 1 and
    # spans is field 2. One turn is one resource, so nothing repeats
    # above the span list.
    let request = buildRequest(@[rootSpan(), childSpan()])
    assert numbers(walk(request)) == @[1],
      "request fields: " & shape(walk(request))
    assert numbers(resourceSpansOf(request)) == @[1, 2],
      "resource_spans fields: " & shape(resourceSpansOf(request))
    assert numbers(resourceOf(request)) == @[1],
      "resource fields: " & shape(resourceOf(request))
    assert numbers(scopeSpansOf(request)) == @[1, 2, 2],
      "scope_spans fields: " & shape(scopeSpansOf(request))
    assert spansOf(request).len == 2

  test "the resource says service.name = waku-agent":
    # Python builds the same attribute through
    # `Resource.create({"service.name": "waku-agent"})`, so both ports
    # land under one service in a collector.
    let attribute = walk(pick(resourceOf(buildRequest(@[rootSpan()])), 1)
      .payload)
    assert textOf(pick(attribute, 1).payload) == "service.name"
    let anyValue = walk(pick(attribute, 2).payload)
    assert numbers(anyValue) == @[1]
    assert textOf(pick(anyValue, 1).payload) == "waku-agent"

  test "the scope says waku and the package version":
    # InstrumentationScope is 1 name and 2 version. The version comes
    # from waku.nimble, so a span in Phoenix names the build that wrote
    # it and the number never becomes a second literal here.
    let scope = scopeOf(buildRequest(@[rootSpan()]))
    assert numbers(scope) == @[1, 2]
    assert textOf(pick(scope, 1).payload) == "waku"
    assert textOf(pick(scope, 2).payload) == scopeVersion
    # The release-number shape `tests/test_version.nim` pins, so a scope
    # carrying a blank or a dev marker fails here too.
    assert re.match(scopeVersion, re"^\d+\.\d+\.\d+$"), scopeVersion

# ── bytes counted by hand from the field numbers ─────────────────────

suite "hand-written bytes":
  test "a one-attribute span's attribute is the literal the proto gives":
    # KeyValue{key:"k", value:AnyValue{string_value:"v"}}, counted by
    # hand from the field numbers: KeyValue field 1 is 0x0A len 'k';
    # KeyValue field 2 is 0x12 len followed by the AnyValue; AnyValue
    # field 1 is 0x0A len 'v'. Two bytes of key and four of AnyValue
    # plus their two lengths: eight.
    var span = rootSpan()
    span.attributes = @[("k", "v")]
    let keyValue = pick(spanOf(buildRequest(@[span])), 9)
    assert hexOf(keyValue.payload) == "0a016b12030a0176",
      "KeyValue bytes: " & hexOf(keyValue.payload)

  test "a fixed64 timestamp is eight little-endian bytes":
    # start_time_unix_nano = 0x0102030405060708 written little-endian is
    # 08 07 06 05 04 03 02 01. A big-endian writer would emit
    # 0102030405060708 and every collector would place the span
    # centuries from now.
    var span = rootSpan()
    span.startNano = 0x0102030405060708'u64
    let start = pick(spanOf(buildRequest(@[span])), 7)
    assert hexOf(start.payload) == "0807060504030201",
      "start_time_unix_nano bytes: " & hexOf(start.payload)

  test "a tag is the field number shifted by three, or the wire type":
    # The bytes below are the tags of Span fields 1, 5, 6, 7 and 9
    # counted from `(number shl 3) or wireType`. They are all one byte
    # because no field here is numbered past 9.
    let span = spanOf(buildRequest(@[rootSpan()]))
    assert hexOf(pick(span, 1).tag) == "0a"
    assert hexOf(pick(span, 5).tag) == "2a"
    assert hexOf(pick(span, 6).tag) == "30"
    assert hexOf(pick(span, 7).tag) == "39"
    assert hexOf(pick(span, 9).tag) == "4a"

# ── varint edges ─────────────────────────────────────────────────────

suite "varint edges":
  test "a 127-byte length is one byte and a 128-byte length is two":
    # A length is a varint, so its prefix grows at 128. The KeyValue
    # around a `("kkk...", "v")` attribute is counted here: the key
    # field is 0x0A plus its length plus the key, and the value field is
    # 0x12 0x03 plus the three-byte AnyValue. 127 keys give 129 + 5 =
    # 134 bytes and 128 keys give 131 + 5 = 136, and only those two
    # totals are reachable with a one-byte and a two-byte length.
    var atLimit = rootSpan()
    atLimit.attributes = @[(repeat("k", 127), "v")]
    var pastLimit = rootSpan()
    pastLimit.attributes = @[(repeat("k", 128), "v")]
    let shortKeyValue = pick(spanOf(buildRequest(@[atLimit])), 9)
    let longKeyValue = pick(spanOf(buildRequest(@[pastLimit])), 9)
    assert shortKeyValue.value == 134'u64,
      "KeyValue length for a 127-byte key: " & $shortKeyValue.value
    assert longKeyValue.value == 136'u64,
      "KeyValue length for a 128-byte key: " & $longKeyValue.value
    assert pick(walk(shortKeyValue.payload), 1).value == 127'u64
    assert pick(walk(longKeyValue.payload), 1).value == 128'u64

  test "a 16383-byte length is two bytes and a 16384-byte one is three":
    # The second boundary: 16383 is the largest value a two-byte varint
    # holds, 16384 needs three. The same count as above gives 16391 and
    # 16393.
    var atLimit = rootSpan()
    atLimit.attributes = @[(repeat("k", 16383), "v")]
    var pastLimit = rootSpan()
    pastLimit.attributes = @[(repeat("k", 16384), "v")]
    let shortKeyValue = pick(spanOf(buildRequest(@[atLimit])), 9)
    let longKeyValue = pick(spanOf(buildRequest(@[pastLimit])), 9)
    assert shortKeyValue.value == 16391'u64,
      "KeyValue length for a 16383-byte key: " & $shortKeyValue.value
    assert longKeyValue.value == 16393'u64,
      "KeyValue length for a 16384-byte key: " & $longKeyValue.value
    # Reading both back without a fourth byte is the only way a varint
    # reader proves it stopped at the right place.
    assert walk(longKeyValue.payload).len == 2
    assert pick(walk(longKeyValue.payload), 1).value == 16384'u64

  test "a present zero is the single byte 0x00":
    # SpanKind UNSPECIFIED is 0. Writing field 6 with no value at all
    # would leave the kind absent rather than set, and every field
    # after it would shift by one byte.
    var span = rootSpan()
    span.kind = skUnspecified
    let kind = pick(spanOf(buildRequest(@[span])), 6)
    assert kind.wireType == 0 and kind.value == 0'u64
    assert kind.payload == @[0x00'u8],
      "kind bytes: " & hexOf(kind.payload)

# ── order and determinism ────────────────────────────────────────────

suite "order and determinism":
  test "the same fixture encodes to the same bytes twice":
    let spans = @[rootSpan(), childSpan()]
    assert buildRequest(spans) == buildRequest(spans)

  test "attributes keep the order they were added in":
    # Python's comprehension walks the event in order. A table would
    # leak its hash order into the bytes, and the same turn would render
    # differently on every run.
    var span = rootSpan()
    span.attributes = @[("waku.z", "1"), ("waku.a", "2"), ("waku.m", "3")]
    var keys: seq[string] = @[]
    for field in spanOf(buildRequest(@[span])):
      if field.number == 9:
        keys.add(textOf(pick(walk(field.payload), 1).payload))
    assert keys == @["waku.z", "waku.a", "waku.m"], keys.join(" ")

  test "fields go out in ascending order at every level":
    let request = buildRequest(@[rootSpan(), childSpan()])
    assert numbers(walk(request)) == @[1]
    assert numbers(resourceSpansOf(request)) == @[1, 2]
    assert numbers(resourceOf(request)) == @[1]
    assert numbers(scopeSpansOf(request)) == @[1, 2, 2]
    assert numbers(scopeOf(request)) == @[1, 2]
    assert numbers(spansOf(request)[0]) == @[1, 2, 5, 6, 7, 8, 9]
    assert numbers(spansOf(request)[1]) == @[1, 2, 4, 5, 6, 7, 8, 9, 9]

# ── the request, and the ids it trusts ────────────────────────────────

suite "the request":
  test "no spans is the zero-length encoding":
    # An ExportTraceServiceRequest with no resource_spans has no field
    # left to write, and a collector reads zero bytes as no spans.
    let empty = buildRequest(@[])
    assert empty.len == 0
    assert walk(empty).len == 0

  test "a request round-trips back to the spans it was given":
    let request = buildRequest(@[rootSpan(), childSpan()])
    let spans = spansOf(request)
    assert spans.len == 2
    assert textOf(pick(spans[0], 5).payload) == "agent_run"
    assert textOf(pick(spans[1], 5).payload) == "llm.gather"
    assert hexOf(pick(spans[0], 1).payload) ==
      "0af7651916cd43dd8448eb211c80319c"
    assert hexOf(pick(spans[1], 4).payload) == "b7ad6b7169203331"

  test "an empty parent omits field 4 and an empty name omits field 5":
    # Omitting is the contract: eight zero bytes for a root span read as
    # a parent that exists and is broken, and Phoenix draws the link.
    var bare = rootSpan()
    bare.name = ""
    let fields = spanOf(buildRequest(@[bare]))
    assert numbers(fields) == @[1, 2, 6, 7, 8, 9],
      "nameless root fields: " & shape(fields)
    assert not has(fields, 5)

  test "a malformed id is refused instead of becoming zeros":
    # A short or non-hex id would otherwise ship a span that belongs to
    # no trace, which a collector drops without a word.
    expect ValueError:
      discard traceIdBytes("0af7651916cd43dd")
    expect ValueError:
      discard spanIdBytes("zzzzzzzzzzzzzzzz")
    expect ValueError:
      discard buildRequest(@[Span(traceId: traceId, spanId: "nothex000000")])