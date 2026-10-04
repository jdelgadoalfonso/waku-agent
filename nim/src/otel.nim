## OTLP span exporter — the transport half of the hand-rolled
## OpenTelemetry exporter, mirror of `waku/ops/tracing.py`.
##
## `otelproto` (the module below this one in the dependency graph) writes
## the bytes; this module decides WHAT a turn sends and where it POSTs.
## Python builds the same span tree through the OpenTelemetry SDK
## (`_init_otel`, `turn`, `event`, `end_turn`): a root `agent_run` span
## per turn, one zero-duration child per loop event, one flush per turn.
## The rules copied here are each load-bearing:
##
## - One turn is one trace. `turn()` mints the trace id and the root span
##   id, every child of that turn carries the same trace id and names the
##   root as its parent, and `endTurn()` sends them together. A collector
##   draws a tree, not a bag of spans.
## - Children have ZERO duration (`startNano == endNano`). Python's child
##   span is a `with ...: pass`, and the port does not time the loop's
##   events; a duration here would claim a measurement nobody made.
## - The openinference taxonomy is a STRING attribute, never the OTLP
##   `Span.kind` enum. Python leaves the SDK default (INTERNAL) and only
##   writes `openinference.span.kind`; every span this port sends is work
##   Waku did, so `kind` is `skInternal` and AGENT/LLM/TOOL/CHAIN rides
##   along as the first attribute of each span.
## - An attribute value is the JSON TEXT of the event field
##   (`json.dumps(v, default=str)`), rendered by `jsondump`: a number
##   arrives as "10", a nested `usage` as Python-shaped JSON. `AnyValue`
##   carries it as `string_value`, which is what the mirror is.
## - One POST per turn, and a failure never reaches the turn. An export
##   error is a returned `(ok, detail)` plus ONE bounded stderr line,
##   never a raise: the turn's own record is the JSONL of `trace.nim`, and
##   a collector that is down must not cost the user their run.
##
## No SDK, no gRPC, no queue, no retry: OTLP/HTTP with the protobuf body
## `buildRequest` writes, the encoding every collector accepts. The
## endpoint is `OTEL_EXPORTER_OTLP_ENDPOINT` as `host:port` (optionally
## `http://` or `https://`), the same variable and the same rules as the
## dashboard's `otel` connection probe, so there is no second endpoint
## contract to document. Phoenix serves OTLP/HTTP on 6006, the port its
## own UI is on.
##
## Three seams — the clock, the id minting and the send — are injectable
## so a test can pin a span tree with no wall clock, no randomness and no
## socket. Each has a real default, so wiring the exporter into a turn is
## `newSpanExporter(endpoint)` and nothing else.

import std/httpclient
import std/json
import std/strutils
import std/sysrand
import std/times

import ./http
import ./jsondump
import ./otelproto

# ── the seams, and what an export outcome is ──────────────────────────

type
  ExportResult* = tuple[ok: bool, detail: string]
    ## Whether the collector took a turn's spans, and why not when it
    ## did not. A value rather than a raise because the caller is a live
    ## turn: the caller can act on `ok` but must never be interrupted by
    ## a collector. `detail` is a bounded sentence — a status line or a
    ## short reason, never a payload.

  ClockFn* = proc (): uint64
    ## Nanoseconds since the Unix epoch, read once per timestamp.

  IdFn* = proc (): string
    ## A fresh lowercase hex id: 32 digits for a trace, 16 for a span.

  SendFn* = proc (url, body: string): ExportResult
    ## One POST of the whole turn. `body` is the protobuf request as
    ## bytes-in-a-string, which is what a socket carries; `url` is
    ## already the full `/v1/traces` URL so an injected sender can assert
    ## it without re-deriving the endpoint.

  SpanExporter* = ref object
    ## One turn's span tree, plus the seams that fill it. Fields are
    ## exported because the port's own tests read the tree back, and a
    ## span tree nobody can read is a span tree nobody can pin.
    url*: string
      ## The collector URL from `parseOtlpEndpoint`, `/v1/traces` included.
    spans*: seq[Span]
      ## The open turn, root first: index 0 is `agent_run`, the rest are
      ## its children in call order. Empty between turns and after a
      ## flush, so a second `endTurn` sends nothing twice.
    clock*: ClockFn
    mintTraceId*, mintSpanId*: IdFn
    send*: SendFn

const
  tracesPath = "/v1/traces"
    ## The OTLP/HTTP trace route, `S2`'s encoding. Phoenix, the OTel
    ## collector and every other receiver serve exactly this path.
  protobufMediaType = "application/x-protobuf"
    ## Both directions: OTLP/HTTP with protobuf asks for a protobuf body
    ## and answers `ExportTraceServiceResponse` in the same media type.
  hostPortHint = "OTLP endpoint must be host:port (for example localhost:4317)"
    ## The dashboard's `otel` probe's own sentence, kept word for word so
    ## a user who read one error reads the same message in both places.
  flushTimeoutMs = 2000
    ## The bound Python gives `force_flush(timeout_millis=2000)`. This POST
    ## is synchronous, so without a timeout an unreachable collector
    ## would hang the END of a turn instead of failing it — which is the
    ## one place an export is allowed to cost the user time.
  reasonLimit = 160
    ## Characters of any failure reason kept. Bounded on purpose: this
    ## text goes to a terminal inside somebody else's chat turn.

# ── ids and clock, the two things the encoder must not invent ─────────

proc mintHexId*(byteLen: int): string =
  ## `secrets.token_hex(byteLen)` from Python: `byteLen` random bytes as
  ## lowercase hex, the width OTLP reads `trace_id` and `span_id` at. The
  ## width is the caller's contract rather than an argument here, so a
  ## wrong id cannot reach `buildRequest` from this side.
  result = newStringOfCap(byteLen * 2)
  for b in urandom(byteLen):
    result.add(int(b).toHex(2).toLowerAscii())

proc newTraceId*(): string =
  ## A fresh 32-hex-digit trace id (16 bytes), the width `trace.proto`
  ## requires of `trace_id`.
  mintHexId(16)

proc newSpanId*(): string =
  ## A fresh 16-hex-digit span id (8 bytes), for a root or a parent link.
  mintHexId(8)

proc unixNanoNow*(): uint64 =
  ## Wall-clock nanoseconds since the Unix epoch — what
  ## `start_time_unix_nano` counts (`std/times` has no float-seconds to
  ## `Duration` conversion, so the scale is written out).
  ##
  ## `epochTime` is float seconds, which at today's magnitude carries a
  ## couple of hundred nanoseconds. Nothing here measures that finely:
  ## children are stamped from ONE reading and are zero-duration by
  ## design, and the root's end is only ever compared with its start for
  ## order. An anchored `getMonoTime` pair would buy precision nothing
  ## reads, and a monotonic clock is the wrong one to report anyway — a
  ## collector reads timestamps as wall time.
  uint64(int64(epochTime() * 1_000_000_000.0))

# ── the endpoint, the dashboard probe's rules and nothing else ────────

proc parseOtlpEndpoint*(raw: string): string =
  ## The full collector URL `raw` names: `<scheme>://<host>:<port>` +
  ## `tracesPath`, or a `ValueError` saying why not. `raw` is
  ## `OTEL_EXPORTER_OTLP_ENDPOINT` as Python's `otel_endpoint` setting
  ## carries it, optionally `http://` or `https://` prefixed and
  ## `http` without.
  ##
  ## Every rejection below is the rule the dashboard's `otel` connection
  ## probe (`src/dashboard.nim`) already applies, in the same order and
  ## with the same sentences, so the two can never disagree about what
  ## this variable means: no path, no query, no fragment, no `@`; exactly
  ## one colon with a numeric port in 1..65535. The scheme is this
  ## module's own addition — the probe only has to dial a socket, while
  ## this module has to WRITE a URL, so a scheme that is neither `http`
  ## nor `https` is refused here rather than POSTed to.
  var endpoint = raw.strip()
  var scheme = "http"
  if "://" in endpoint:
    let split = endpoint.split("://", 1)
    scheme = split[0].toLowerAscii()
    endpoint = split[1]
    if scheme != "http" and scheme != "https":
      raise newException(ValueError,
        "OTLP endpoint scheme must be http or https (got " & scheme & ")")
  for bad in ["/", "?", "#", "@"]:
    if bad in endpoint:
      raise newException(ValueError, hostPortHint)
  let parts = endpoint.split(':')
  if parts.len != 2:
    raise newException(ValueError, hostPortHint)
  var port = 0
  try:
    port = parseInt(parts[1])
  except ValueError:
    raise newException(ValueError,
      "OTLP endpoint must be a valid host:port")
  if parts[0].len == 0 or port <= 0 or port > 65535:
    raise newException(ValueError, hostPortHint)
  scheme & "://" & parts[0] & ":" & $port & tracesPath

proc boundedText(text: string, limit: int): string =
  ## `text` cut to `limit` characters with a marker, so a line that has
  ## to stay short can never be made long by whatever it reports.
  if text.len <= limit: text
  else: text[0 ..< limit] & "..."

# ── the one POST ──────────────────────────────────────────────────────

proc postSpans(url, body: string): ExportResult =
  ## The real sender: one POST to `<endpoint>/v1/traces` carrying the
  ## turn's spans as OTLP protobuf. `request` rather than `postContent`
  ## because the outcome that matters is the STATUS — a collector that
  ## answers 500 has not taken the spans, and Python's exporter retries
  ## and reports the failure rather than pretending it worked.
  ##
  ## Through `newTlsHttpClient`, like every live call in the port: a
  ## client built any other way is a context-less one, which
  ## `tests/test_tls.nim` fails on. A fresh client per POST and closed in
  ## the `finally`, the shape the REST seams use, so a long-lived chat
  ## loop does not accumulate sockets (one POST per turn is one
  ## connection, opened and dropped).
  var client = newTlsHttpClient(timeout = flushTimeoutMs)
  try:
    let headers = newHttpHeaders({"Content-Type": protobufMediaType,
                                  "Accept": protobufMediaType})
    let response = client.request(url, HttpPost, body, headers)
    if response.status.startsWith("2"):
      return (ok: true, detail: "")
    return (ok: false, detail: "collector answered " & response.status)
  except CatchableError as exc:
    # A refused connection, a timeout, a TLS failure: a reason, never the
    # payload. Nothing secret can be in this text — the endpoint
    # validator refuses an `@`, so there are no credentials in the URL to
    # echo — but the payload is the user's turn, so it is not here at all.
    return (ok: false, detail: boundedText(exc.msg, reasonLimit))
  finally:
    client.close()

proc bytesToString(buf: seq[uint8]): string =
  ## The protobuf body as the `string` a socket writes.
  ##
  ## Safe without any UTF-8 assumption, because there is no assumption to
  ## make: a Nim `string` is a length-prefixed BYTE buffer, nothing in it
  ## is validated or re-encoded. Protobuf carries `0x00` (an empty field,
  ## a small length, the low byte of every `fixed64` timestamp) and bytes
  ## above `0x7F` (the same timestamps), so the copy is byte for byte and
  ## a text encoder would corrupt exactly the spans whose ids and
  ## timestamps it carries.
  result = newString(buf.len)
  for i in 0 ..< buf.len:
    result[i] = char(int(buf[i]))

# ── naming, the mirror of two Python expressions ──────────────────────

proc valueText(node: JsonNode): string =
  ## Python's f-string of one event value: a string as itself, anything
  ## else through `str()` (`10`, `True`, `{'in': 3}`). Not `$node`: Nim's
  ## `$` on a `JsonNode` prints the node's DEBUG form, which is not what
  ## Python's expression in the name evaluates to.
  if node.isNil: return ""
  if node.kind == JString: node.getStr()
  else: pyStr(node)

proc suffixField(ev: JsonNode): string =
  ## `event.get('tool', event.get('decision', ''))`. Presence, not truth:
  ## Python returns the stored value when the KEY exists, which is why this
  ## asks `hasKey` rather than testing for a value.
  if ev.kind == JObject:
    if ev.hasKey("tool"): return valueText(ev["tool"])
    if ev.hasKey("decision"): return valueText(ev["decision"])
  ""

proc childSpanName(kind: string, ev: JsonNode): string =
  ## `f"{kind}.{event.get('tool', event.get('decision', ''))}".rstrip(".")`
  ## — the trailing-dot strip included, because it is what makes the two
  ## shapes differ: an `llm` event with neither key builds `"llm."` and
  ## is named `llm`, while `tool` with `tool: "search"` is `tool.search`.
  ## `rstrip` removes EVERY trailing dot, so this does too.
  (kind & "." & suffixField(ev)).strip(leading = false, chars = {'.'})

proc spanKindName(kind: string): string =
  ## `{"llm": "LLM", "tool": "TOOL"}.get(kind, "CHAIN")`: the
  ## openinference taxonomy, which is an attribute value here and never
  ## the OTLP enum.
  case kind
  of "llm": "LLM"
  of "tool": "TOOL"
  else: "CHAIN"

# ── the exporter ──────────────────────────────────────────────────────

proc newSpanExporter*(endpoint: string, clock: ClockFn = unixNanoNow,
                      mintTraceId: IdFn = newTraceId,
                      mintSpanId: IdFn = newSpanId,
                      send: SendFn = postSpans): SpanExporter =
  ## The exporter for one `OTEL_EXPORTER_OTLP_ENDPOINT`, or `nil` when
  ## there is nothing to export to. Never raises: a malformed endpoint is
  ## a user typo reported on stderr, not a crash in the middle of a
  ## conversation.
  ##
  ## `nil` is the answer for BOTH empty and invalid, and every proc below
  ## treats it as "no exporter": the caller wires it once and the cost of
  ## an unset variable is one nil check per turn. Python returns `None`
  ## for an unset endpoint and, in its one failure mode, prints and
  ## returns `None` too (the port has no SDK that can be missing).
  if endpoint.strip().len == 0:
    return nil
  var url: string
  try:
    url = parseOtlpEndpoint(endpoint)
  except ValueError as exc:
    stderr.writeLine("(otel) span export off: " &
      boundedText(exc.msg, reasonLimit))
    return nil
  SpanExporter(url: url, spans: @[], clock: clock, mintTraceId: mintTraceId,
               mintSpanId: mintSpanId, send: send)

proc turn*(t: SpanExporter, userMessage: string) =
  ## Open the turn: the root span `agent_run`, carrying
  ## `openinference.span.kind = AGENT` and the user's message.
  ##
  ## The message goes on verbatim, NOT through `jsonDumps`: Python passes
  ## `user_message` to the SDK as a plain attribute value, and this is the
  ## one attribute on this path that is text rather than the JSON text of
  ## a field. The ids are minted here rather than taken from the caller
  ## because a trace id that existed before the turn would let two turns
  ## share one trace — the tree a collector draws has to be per turn.
  if t.isNil: return
  t.spans = @[Span(traceId: t.mintTraceId(), spanId: t.mintSpanId(),
                   name: "agent_run", kind: skInternal,
                   startNano: t.clock(),
                   attributes: @[("openinference.span.kind", "AGENT"),
                                 ("waku.user_message", userMessage)])]

proc event*(t: SpanExporter, kind: string, ev: JsonNode) =
  ## One loop event as a child span, in call order: same trace as the
  ## turn, the root as parent, the openinference kind as an attribute,
  ## and every field of `ev` as `waku.<field>` holding the JSON TEXT of
  ## its value.
  ##
  ## `ev` is the ALREADY-STAMPED payload the loop hands the tracer, the
  ## same `JsonNode` `trace.nim` writes its JSONL row from: `provider`
  ## and `model` are on it for an `llm` event (Python merges them in
  ## before both the row and the span), and `type`/`ts` are NOT, because
  ## those two belong to the JSONL record alone. Every field that IS on
  ## the payload becomes an attribute, which is why the span carries the
  ## model and the token counts a collector shows.
  ##
  ## One clock reading stamps both ends, which is the zero duration
  ## Python's `with ...: pass` has. Ignored for `text` (streaming token
  ## deltas, which Python returns from before it reaches the span) and for
  ## a turn that was never opened — no parent to attach to, and Python
  ## checks the same thing with `self._span_ctx is not None`.
  if t.isNil or kind == "text" or t.spans.len == 0: return
  let root = t.spans[0]
  let stamp = t.clock()
  var attributes: seq[(string, string)] =
    @[("openinference.span.kind", spanKindName(kind))]
  if ev.kind == JObject:
    for key, value in pairs(ev):
      attributes.add(("waku." & key, jsonDumps(value)))
  t.spans.add(Span(traceId: root.traceId, spanId: t.mintSpanId(),
                   parentSpanId: root.spanId,
                   name: childSpanName(kind, ev), kind: skInternal,
                   startNano: stamp, endNano: stamp,
                   attributes: attributes))

proc flush*(t: SpanExporter): ExportResult =
  ## POST the open turn's spans, root first, as one
  ## `ExportTraceServiceRequest`. Silent on success; on failure ONE
  ## bounded stderr line and a returned `ok: false`, so a collector that
  ## refuses or vanishes costs a line and never the turn.
  ##
  ## The spans stay in place after a FAILED flush for the caller to read,
  ## and `endTurn` still resets them: a retry belongs to the next turn,
  ## not to a queue this exporter does not have.
  ##
  ## The send is wrapped, not only `postSpans`: the promise is that NOTHING
  ## an export does reaches the turn, including a seam that raises or a
  ## span whose id is malformed.
  if t.isNil or t.spans.len == 0:
    return (ok: true, detail: "")
  if t.spans[0].endNano == 0:
    # A bare `flush` — the caller forgot `endTurn` — would otherwise put
    # end < start on the wire, because the root's start is a wall clock
    # and its end would still be the zero the constructor left. One extra
    # reading, only on that path: `endTurn` stamps the end itself and
    # lands here with a non-zero one.
    t.spans[0].endNano = t.clock()
  var sent: ExportResult
  try:
    sent = t.send(t.url, bytesToString(buildRequest(t.spans)))
  except CatchableError as exc:
    sent = (ok: false, detail: exc.msg)
  if sent.ok:
    return sent
  # The RETURNED detail is bounded as well as the printed one: one rule
  # for both, so a caller that logs the result cannot print more than the
  # terminal showed.
  result = (ok: false, detail: boundedText(sent.detail, reasonLimit))
  stderr.writeLine("(otel) span export failed: " & result.detail)

proc endTurn*(t: SpanExporter): ExportResult =
  ## Close the turn: stamp the root's end, flush once, reset. The
  ## per-turn flush is Python's `force_flush(2000)` in `end_turn` — the
  ## reason a killed process still leaves a whole turn in the collector.
  ##
  ## The returned result is the flush's, so a caller can assert on it; a
  ## caller that ignores it is following the policy this module exists to
  ## enforce, and the one stderr line has already said it.
  if t.isNil:
    return (ok: true, detail: "")
  if t.spans.len == 0:
    return (ok: true, detail: "")
  t.spans[0].endNano = t.clock()
  result = t.flush()
  t.spans = @[]