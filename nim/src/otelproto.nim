## OTLP trace encoder — the bytes half of a hand-rolled OpenTelemetry
## exporter, and nothing else.
##
## Python emits spans through the OpenTelemetry SDK
## (`waku/ops/tracing.py`). The port has no SDK and may not take one
## (rule 3: no new default dependency), so this module writes the
## protobuf wire format by hand. The message is
## `ExportTraceServiceRequest` from
## `opentelemetry/proto/collector/trace/v1/trace_service.proto` — the
## same message the SDK's `OTLPSpanExporter` POSTs — so Phoenix or any
## other collector renders both ports the same way.
##
## Pure on purpose: no HTTP, no socket, no clock, no file. Every span
## arrives with its ids and timestamps already filled in, so
## `tests/test_otelproto.nim` can pin the bytes against injected values
## and no golden test can go flaky on a wall clock or on randomness. The
## POST belongs to the module above this one.
##
## Field numbers are the contract, not an implementation detail: they
## come from the `.proto` files, and the test suite reads them back with
## its own walker instead of comparing this writer against itself. A
## self-consistent but wrong field number is the failure the suite
## exists to catch.
##
## Two rules every writer below follows:
## - Fields go out in ascending order, which is what generated writers
##   do and what makes the golden bytes stable.
## - An empty optional field is OMITTED, never written as zero length.
##   `parent_span_id` is the case that matters: a root span carrying
##   eight zero bytes reads as a parent that exists and is broken, and
##   Phoenix draws the orphan link.

import std/parseutils
import std/strutils

# ── wire types ────────────────────────────────────────────────────────

const
  wtVarint = 0'u8
    ## Protobuf wire type 0. Enums, ints and lengths travel this way.
  wtFixed64 = 1'u8
    ## Protobuf wire type 1: eight raw little-endian bytes. `trace.proto`
    ## pins the two timestamps to this type rather than to a varint.
  wtBytes = 2'u8
    ## Protobuf wire type 2: a length then the payload. Every nested
    ## message, every string and every `bytes` field on this path is
    ## this one type.

# ── span input ───────────────────────────────────────────────────────

type
  SpanKind* = enum
    ## `opentelemetry.proto.trace.v1.Span.SpanKind`, encoded as the
    ## varint of `Span.kind` (field 6). The ordinals below ARE the wire
    ## values, so this order is the contract rather than a style choice:
    ## the OTLP enum is declared UNSPECIFIED, INTERNAL, SERVER, CLIENT,
    ## PRODUCER, CONSUMER and a renumbering here would silently relabel
    ## every span a collector reads.
    skUnspecified = 0
    skInternal = 1  ## the only one this port ever sends: a span here is
    skServer = 2    ## work Waku did, so INTERNAL is the truthful kind.
    skClient = 3    ## The openinference taxonomy (AGENT/LLM/TOOL/CHAIN) is
    skProducer = 4  ## a STRING attribute in Python (`tracing.py:141`), not
    skConsumer = 5  ## this enum — the exporter carries it that way.

  Span* = object
    ## One `opentelemetry.proto.trace.v1.Span`, as inputs. The encoder
    ## never mints an id or reads a clock: the exporter above owns both,
    ## and a span that invented them could not be pinned in a test.
    traceId*: string
      ## 32 hex digits, rendered to the 16 bytes of `trace_id` (field 1).
    spanId*: string
      ## 16 hex digits, rendered to the 8 bytes of `span_id` (field 2).
    parentSpanId*: string
      ## 16 hex digits, or "" for a root span — which omits field 4
      ## instead of writing eight zero bytes.
    name*: string
      ## `Span.name` (field 5). Python names the turn's root
      ## `"agent_run"` and a child `f"{kind}.{tool}"`.
    kind*: SpanKind
      ## `Span.kind` (field 6). Python leaves the SDK default, INTERNAL.
    startNano*, endNano*: uint64
      ## `start_time_unix_nano` / `end_time_unix_nano` (fields 7 and 8),
      ## nanoseconds since the Unix epoch as `fixed64`.
    attributes*: seq[(string, string)]
      ## `Span.attributes` (field 9) as key/value pairs in INSERTION
      ## order — the `waku.<field>` pair each loop event contributes.
      ## Values are strings because Python's mirror is
      ## `{f"waku.{k}": json.dumps(v, default=str) ...}`, so a number
      ## arrives as `"10"`. A seq and not a table because a collector
      ## shows the order it was sent, and a table would leak its hash
      ## order into the golden bytes.

# ── package version, read from the manifest ──────────────────────────

proc manifestVersion(manifest: string): string {.noSideEffect.} =
  ## The `version = "..."` value a nimble manifest declares, read the
  ## way nimble reads it. This repeats `waku.nim`'s `declaredVersion`
  ## because the CLI module imports the whole application and a
  ## library cannot import it back; the single source is still
  ## `waku.nimble`, read at compile time, so no second number exists
  ## here for a human to keep in step.
  for line in manifest.splitLines():
    let text = line.strip()
    if not text.startsWith("version"):
      continue
    let first = text.find('"')
    let last = text.rfind('"')
    if first < 0 or last <= first:
      raise newException(ValueError, "no quoted version in: " & text)
    return text[first + 1 ..< last]
  raise newException(ValueError, "waku.nimble declares no version")

const
  nimbleManifest = staticRead("../waku.nimble")
    ## The package manifest, read while the compiler runs, for the same
    ## reason `waku.nim` reads it: one editable version number.
  scopeVersion* = manifestVersion(nimbleManifest)
    ## `InstrumentationScope.version` (field 2). It reports the port's
    ## own package version, so a span in Phoenix names the build that
    ## wrote it without this module carrying a literal.
  scopeName = "waku"
    ## `InstrumentationScope.name` (field 1): the port is the
    ## instrumentation, and the span tree inside it is what Python's
    ## tracer emits.
  serviceName = "waku-agent"
    ## The one `Resource.attributes` entry, mirroring Python's
    ## `Resource.create({"service.name": "waku-agent"})`. Same key, same
    ## value, so both ports land under one service in a collector.

# ── the wire writer ──────────────────────────────────────────────────

proc addVarint(buf: var seq[uint8], value: uint64) =
  ## Protobuf base-128 varint: seven bits per byte, lowest group first,
  ## the high bit marking "another byte follows". A zero is one `0x00`
  ## byte and not nothing — a present field still carries its value, and
  ## a dropped zero byte is the classic one-byte mistake.
  var rest = value
  while rest >= 0x80'u64:
    buf.add(uint8(rest and 0x7F'u64) or 0x80'u8)
    rest = rest shr 7
  buf.add(uint8(rest))

proc addTag(buf: var seq[uint8], field: uint32, wireType: uint8) =
  ## `(field number shl 3) or wire type`, one varint. Every field below
  ## starts here, which is why the numbers in the `.proto` files are the
  ## part of this module that cannot be guessed.
  addVarint(buf, (uint64(field) shl 3) or uint64(wireType))

proc addVarintField(buf: var seq[uint8], field: uint32, value: uint64) =
  ## An enum or int field (wire type 0). `Span.kind` is the only one the
  ## port writes: the timestamps are `fixed64` and everything else is a
  ## nested message or a string.
  addTag(buf, field, wtVarint)
  addVarint(buf, value)

proc addBytesField(buf: var seq[uint8], field: uint32,
                   payload: openArray[uint8]) =
  ## Wire type 2: tag, then the byte count as a varint, then the raw
  ## bytes. Every nesting on this path is one of these — the whole OTLP
  ## trace message is a stack of length prefixes.
  addTag(buf, field, wtBytes)
  addVarint(buf, uint64(payload.len))
  for b in payload:
    buf.add(b)

proc addStringField(buf: var seq[uint8], field: uint32, value: string) =
  ## A proto `string` is a length-delimited byte run. The loop copies
  ## raw UTF-8 rather than casting the string to `openArray[uint8]`,
  ## because the cast is only safe when the compiler can prove the
  ## element sizes line up and this never has to.
  addTag(buf, field, wtBytes)
  addVarint(buf, uint64(value.len))
  for c in value:
    buf.add(uint8(c))

proc addFixed64(buf: var seq[uint8], field: uint32, value: uint64) =
  ## Wire type 1: eight bytes, least significant first. `trace.proto`
  ## pins the two timestamps to `fixed64`, so a collector reads them
  ## without spending a varint continuation byte on a nanosecond count.
  ## The shift ascends on purpose: the low byte is the one that goes
  ## first, and `fixed64` is little-endian on every wire.
  addTag(buf, field, wtFixed64)
  for step in 0 .. 7:
    buf.add(uint8(value shr (8 * step)))

# ── ids ──────────────────────────────────────────────────────────────

proc nibble(hex: string, i: int): int =
  ## One hex digit, refusing anything else. `parseHex` reads a whole
  ## number and reports how many characters it consumed, so a
  ## single-character slice is what turns it into a digit reader: one
  ## hex digit returns 1 and anything else returns 0. That return value
  ## is the whole check — without it a malformed id became zeros and
  ## the span looked like a valid one about a different trace.
  var value: int
  if parseHex(hex[i .. i], value, 0) != 1:
    raise newException(ValueError, "not a hex digit at " & $i &
      " of " & hex)
  value

proc idBytes(hex: string, byteLen: int): seq[uint8] =
  ## Hex text to the raw bytes OTLP carries: `trace_id` and `span_id`
  ## are `bytes` fields, and a collector compares those bytes rather
  ## than the hex a human reads in the JSONL. The width is checked
  ## because a short id is silent data loss — the collector drops the
  ## span as malformed instead of reporting it.
  if hex.len != byteLen * 2:
    raise newException(ValueError, "expected " & $(byteLen * 2) &
      " hex digits, got " & $hex.len)
  result = newSeq[uint8](byteLen)
  for i in 0 ..< byteLen:
    result[i] = uint8(nibble(hex, 2 * i) shl 4 or nibble(hex, 2 * i + 1))

proc traceIdBytes*(hex: string): seq[uint8] =
  ## The 16 bytes of a `trace_id`. Exported so the exporter renders an id
  ## with the same reader its encoder reads it back with; minting the hex
  ## is the caller's job (it owns the randomness).
  idBytes(hex, 16)

proc spanIdBytes*(hex: string): seq[uint8] =
  ## The 8 bytes of a `span_id` or of a `parent_span_id`; the field
  ## numbers differ (2 and 4) but the width is the same.
  idBytes(hex, 8)

# ── the message tree ─────────────────────────────────────────────────

proc encodeAnyValue(value: string): seq[uint8] =
  ## `opentelemetry.proto.common.v1.AnyValue` carrying `string_value`
  ## (field 1). One variant on purpose: every attribute this port writes
  ## is the JSON string of an event field, so the rest of AnyValue
  ## (`array_value`, `kvlist_value`, ...) would be a shape nothing
  ## emits. The string is written even when empty — an attribute's value
  ## is the payload, and omitting it would leave a `KeyValue` whose
  ## `AnyValue` sets no field at all, which no collector can render.
  result = @[]
  addStringField(result, 1, value)

proc encodeAttribute(key, value: string): seq[uint8] =
  ## `opentelemetry.proto.common.v1.KeyValue`: `key` (field 1) then
  ## `value` (field 2), the `AnyValue` above.
  result = @[]
  addStringField(result, 1, key)
  addBytesField(result, 2, encodeAnyValue(value))

proc encodeResource(): seq[uint8] =
  ## `opentelemetry.proto.resource.v1.Resource`, which is a bare
  ## `repeated KeyValue attributes` (field 1). Python builds the same
  ## one attribute through `Resource.create`.
  result = @[]
  addBytesField(result, 1, encodeAttribute("service.name", serviceName))

proc encodeScope(): seq[uint8] =
  ## `opentelemetry.proto.common.v1.InstrumentationScope`: `name`
  ## (field 1) and `version` (field 2).
  result = @[]
  addStringField(result, 1, scopeName)
  addStringField(result, 2, scopeVersion)

proc encodeSpan(span: Span): seq[uint8] =
  ## `opentelemetry.proto.trace.v1.Span`, field by field.
  result = @[]
  addBytesField(result, 1, traceIdBytes(span.traceId))
  addBytesField(result, 2, spanIdBytes(span.spanId))
  # `trace_state` (field 3) is never written: the port's spans carry no
  # W3C trace state, and an empty one reads as present-but-empty.
  if span.parentSpanId.len > 0:
    addBytesField(result, 4, spanIdBytes(span.parentSpanId))
  if span.name.len > 0:
    addStringField(result, 5, span.name)
  addVarintField(result, 6, uint64(ord(span.kind)))
  addFixed64(result, 7, span.startNano)
  addFixed64(result, 8, span.endNano)
  for (key, value) in span.attributes:
    addBytesField(result, 9, encodeAttribute(key, value))

proc encodeScopeSpans(spans: seq[Span]): seq[uint8] =
  ## `opentelemetry.proto.trace.v1.ScopeSpans`: `scope` (field 1) then
  ## `repeated Span spans` (field 2), in the order given.
  result = @[]
  addBytesField(result, 1, encodeScope())
  for span in spans:
    addBytesField(result, 2, encodeSpan(span))

proc encodeResourceSpans(spans: seq[Span]): seq[uint8] =
  ## `opentelemetry.proto.trace.v1.ResourceSpans`: `resource` (field 1)
  ## then `repeated ScopeSpans scope_spans` (field 2). One turn is one
  ## resource and one scope, so the request repeats neither. `schema_url`
  ## (field 3) stays empty — the port emits no schema version.
  result = @[]
  addBytesField(result, 1, encodeResource())
  addBytesField(result, 2, encodeScopeSpans(spans))

proc buildRequest*(spans: seq[Span]): seq[uint8] =
  ## One `ExportTraceServiceRequest` (field 1, `repeated
  ## ResourceSpans`) carrying a whole turn's spans, ready for a POST to
  ## `/v1/traces`. A `seq` and not `openArray` because the exporter
  ## grows one list per turn and flushes it once.
  ##
  ## No spans means no bytes: the wrappers around an empty list would be
  ## a resource and a scope describing nothing, and a collector is better
  ## served by an empty body than by a request it has to empty again.
  if spans.len == 0:
    return @[]
  result = @[]
  addBytesField(result, 1, encodeResourceSpans(spans))