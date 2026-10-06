## Observe — port of the v2 core of `waku/ops/observability.py`.
##
## Spec 012 reads one trace line per event: what the call did, where it
## went and what it cost. This module is the derivation half — pure
## functions from a tool event to its `source`/`span`/`ok` fields, its
## redacted args, and its OpenTelemetry GenAI names. The tracer
## (`trace.nim`) and the span exporter (`otel.nim`) call in; the page
## helpers (`read_events`, `group_turns`, `story`, ...) stay with the
## dashboard routes unit, like upstream keeps them in the same file but
## serves them from the page.
##
## Two deliberate reuses, both already ported: `receipt.toolCost` for the
## dollars a treg answer names (its nuance — the endpoint is read off the
## output, not the args — travels with it, documented), and
## `pricing.priceFor` for the llm estimate. Secrets never reach a line:
## `redact` masks secret-named keys and key-shaped strings with `***`.

import std/json
import std/math
import std/os
import std/re
import std/strutils

import ./pricing
import ./receipt
import ./wire

const
  schemaVersion* = 2
    ## The trace-line schema this module writes (`v: 2`).

  argsChars* = 500
    ## What a v2 line keeps of a call's arguments, redacted.

  errorChars* = 200
    ## What a v2 line keeps of a failure, redacted.

  maxMemoryIds* = 20
    ## At most this many memory ids ride a retrieval line.

  tregPrefix* = "treg_"
  wakuMemoryPrefix* = "waku_memory_"

  retrievalTools = ["memory_search", "memory_recall", "memory_get"]
  memoryWriteTools = ["memory_remember", "memory_forget", "memory_import"]

  secretKey = r"(authorization|apikey|token|secret|password|passwd|cookie|credential|privatekey|accesskey|xapikey|bearer)"
  secretValue = r"(Bearer\s+[A-Za-z0-9._~+/=-]{8,}|\b(?:sk|pk|rk)-[A-Za-z0-9_-]{8,}|\bgh[pousr]_[A-Za-z0-9]{16,}|\bxox[abposr]-[A-Za-z0-9-]{8,}|\bAKIA[0-9A-Z]{16}\b|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"
  endpointShape = r"^[A-Za-z0-9_.:/-]{1,120}$"
  traceIdShape = r"^[A-Za-z0-9_.:-]{1,80}$"

let
  secretKeyRe = re(secretKey, {reIgnoreCase})
  secretValueRe = re(secretValue)
  endpointRe = re(endpointShape)
  traceIdRe = re(traceIdShape)

const
  genaiMap* = [
    ("llm", "provider", "gen_ai.provider.name"),
    ("llm", "model", "gen_ai.request.model"),
    ("llm", "usage.in", "gen_ai.usage.input_tokens"),
    ("llm", "usage.out", "gen_ai.usage.output_tokens"),
    ("llm", "stop_reason", "gen_ai.response.finish_reasons"),
    ("tool", "tool", "gen_ai.tool.name"),
    ("tool", "call_id", "gen_ai.tool.call.id"),
    ("tool", "query", "gen_ai.memory.query.text"),
    ("tool", "results", "gen_ai.memory.record.count"),
    ("score", "name", "gen_ai.evaluation.name"),
    ("score", "value", "gen_ai.evaluation.score.value"),
    ("score", "note", "gen_ai.evaluation.explanation")]
    ## The one place a Waku field is mapped to its semconv name. The
    ## JSONL keeps Waku's short keys and adds only the semconv keys Waku
    ## had no name for; the OTel export sends the semconv names. Checked
    ## upstream 2026-10-04 against semantic-conventions-genai at e07f4eb.

  operationName* = [
    ("llm", "chat"), ("tool", "execute_tool"),
    ("retrieval", "search_memory"), ("memory_write", "create_memory")]
    ## `gen_ai.operation.name` per span kind; memory calls use the memory
    ## operations the conventions define rather than execute_tool.

proc operationFor*(span: string): string =
  ## The operation name for one span kind, or "" when it has none.
  for (kind, name) in operationName:
    if kind == span:
      return name
  ""

proc toolSource*(name: string, servers: openArray[string] = []): string =
  ## `treg`, `waku_memory`, `mcp:<server>` or `local`.
  let n = if name.len > 0: name else: ""
  if n.startsWith(tregPrefix):
    return "treg"
  if n.startsWith(wakuMemoryPrefix):
    return "waku_memory"
  for server in servers:
    if server.len == 0 or server == "treg" or server == "waku_memory":
      continue
    if n.startsWith(server & "_"):
      return "mcp:" & server
  "local"

proc spanKind*(name: string): string =
  ## `retrieval` for a Waku Memory read, `memory_write` for a Waku Memory
  ## write, `tool` for every other tool call.
  let n = if name.len > 0: name else: ""
  if n.startsWith(wakuMemoryPrefix):
    let short = n[wakuMemoryPrefix.len .. ^1]
    if short in retrievalTools:
      return "retrieval"
    if short in memoryWriteTools:
      return "memory_write"
  "tool"

proc toolType*(source: string): string =
  ## `gen_ai.tool.type`: `datastore` for Waku Memory, `extension` for a
  ## remote tool (treg, an MCP server), `function` for one on this machine.
  if source == "waku_memory":
    "datastore"
  elif source == "local":
    "function"
  else:
    "extension"

proc redact*(value: JsonNode): JsonNode =
  ## A copy of `value` with every secret-named key's value and every
  ## key-shaped string replaced by `***`. Objects and arrays are walked.
  ## A key matches on itself with every separator removed, so "api-key",
  ## "API_KEY" and "apiKey" all match.
  case value.kind
  of JObject:
    result = newJObject()
    for key, val in pairs(value):
      let bare = key.replace(re"[^A-Za-z]", "")
      if val.kind != JNull and
          not (val.kind == JString and val.getStr().len == 0) and
          contains(bare, secretKeyRe):
        result[key] = %"***"
      else:
        result[key] = redact(val)
  of JArray:
    result = newJArray()
    for item in value:
      result.add(redact(item))
  of JString:
    result = %(value.getStr().replace(secretValueRe, "***"))
  else:
    result = copy(value)

proc trimText*(text: string, limit: int): string =
  ## `text` capped at `limit` characters with an ellipsis.
  if text.len <= limit: text else: text[0 ..< limit - 1] & "…"

proc traceArgs*(args: JsonNode): JsonNode =
  ## The `args` a v2 trace line keeps: redacted, and when the whole thing
  ## is longer than 500 characters, one trimmed string instead of the object.
  let clean = redact(if args.kind == JObject: args else: newJObject())
  let text = $clean
  if text.len <= argsChars: clean else: %(trimText(text, argsChars))

proc outcome*(output: string): tuple[ok: bool, error: string] =
  ## `(ok, error)`. An output whose first line says "failed" or "timed
  ## out", or that starts with "error", failed; so does a JSON answer
  ## whose `status` is 400 or more. Only the first line is read, because
  ## a web search result that quotes the word "failed" in an article
  ## still worked.
  let low = output.strip().toLowerAscii()
  let head = low.split("\n", 1)[0][0 ..< min(200, low.split("\n", 1)[0].len)]
  if "failed" in head or "timed out" in head or low.startsWith("error"):
    return (false, trimText(output.strip(), errorChars))
  var data: JsonNode = nil
  try:
    data = parseJson(output)
  except JsonParsingError:
    discard
  if not data.isNil and data.kind == JObject:
    let status = data.jget("status")
    if (status.kind == JInt) and status.getBiggestInt() >= 400:
      var detail = data.jget("error").getStr()
      if detail.len == 0:
        detail = data.jget("message").getStr()
      if detail.len == 0:
        detail = "status " & $status.getBiggestInt()
      return (false, trimText(detail, errorChars))
  (true, "")

proc memoryFields*(args, output: JsonNode): JsonNode =
  ## `query`, `results`, `memory_ids` and `retrieval_trace_id` for a Waku
  ## Memory call, each only when the answer actually names it.
  result = newJObject()
  if args.kind == JObject:
    let query = args.jget("query")
    if query.kind == JString and query.getStr().len > 0:
      result["query"] = %(trimText(query.getStr(), 200))
  var data: JsonNode = newJNull()
  if output.kind == JString:
    try:
      let parsed = parseJson(output.getStr())
      if parsed.kind == JObject:
        data = parsed
    except JsonParsingError:
      discard
  if data.kind != JObject:
    return result
  let entries = data.jget("entries")
  if entries.kind == JArray:
    result["results"] = %entries.len
    var ids = newJArray()
    for e in entries:
      if e.kind == JObject and e.jget("id").kind == JString:
        ids.add(e.jget("id"))
        if ids.len >= maxMemoryIds:
          break
    result["memory_ids"] = ids
  elif data.jget("id").kind == JString:
    result["memory_ids"] = %[data.jget("id").getStr()]
  let traceId = data.jget("retrieval_trace_id")
  if traceId.kind == JString and match(traceId.getStr(), traceIdRe):
    result["retrieval_trace_id"] = traceId
  return result

proc describe*(event: JsonNode, servers: openArray[string] = []): JsonNode =
  ## What a `tool` event says, derived from its tool name, args and
  ## output. A v2 event's own fields win over what is derived here, so
  ## an old trace shows everything that can be read back out of it.
  let name = if event.jget("tool").kind == JString:
    event.jget("tool").getStr() else: ""
  let args = event.jget("args")
  let output = event.jget("output")
  let outText = if output.kind == JString: output.getStr() else: ""
  let source = toolSource(name, servers)
  let (ok, error) = outcome(outText)
  result = %*{"source": source, "span": spanKind(name), "ok": ok}
  if error.len > 0:
    result["error"] = %error
  let (usd, provider, known) = toolCost(event)
  if known:
    result["cost_usd"] = %usd
    if provider.len > 0:
      result["provider"] = %provider
  var endpoint = ""
  if output.kind == JString:
    try:
      let data = parseJson(outText)
      if data.kind == JObject:
        endpoint = data.jget("endpoint_id").getStr()
        if endpoint.len == 0 and args.kind == JObject:
          endpoint = args.jget("endpoint_id").getStr()
          if endpoint.len == 0:
            endpoint = args.jget("endpoint").getStr()
    except JsonParsingError:
      discard
  if endpoint.len > 0 and match(endpoint, endpointRe):
    result["endpoint_id"] = %endpoint
    if not result.hasKey("provider"):
      let first = endpoint.split(".")[0]
      if first.len > 0:
        result["provider"] = %first
  if source == "waku_memory":
    for key, val in pairs(memoryFields(args, output)):
      result[key] = copy(val)
  if event.jget("v").getInt() == schemaVersion:
    for key in ["source", "span", "ok", "error", "cost_usd",
        "endpoint_id", "provider", "query", "results", "memory_ids",
        "retrieval_trace_id", "duration_ms", "turn_id"]:
      let v = event.jget(key)
      if v.kind != JNull:
        result[key] = copy(v)
  return result

proc genaiAttributes*(kind: string, event: JsonNode): JsonNode =
  ## The OTel GenAI attributes for one trace event, from the GENAI table,
  ## plus any gen_ai.* key the JSONL line already carries.
  result = newJObject()
  if event.kind == JObject:
    for key, val in pairs(event):
      if key.startsWith("gen_ai."):
        result[key] = copy(val)
  for (mapKind, path, name) in genaiMap:
    if mapKind != kind:
      continue
    var value = event
    for part in path.split("."):
      value = if value.kind == JObject: value.jget(part)
              else: newJNull()
    if value.kind == JNull:
      continue
    if value.kind == JString and value.getStr().len == 0:
      continue
    if name == "gen_ai.response.finish_reasons":
      result[name] = %[value]
    else:
      result[name] = copy(value)
  let span = if kind == "llm": "llm"
             elif kind == "tool" and event.kind == JObject:
               event.jget("span").getStr()
             else: ""
  let op = operationFor(span)
  if op.len > 0:
    result["gen_ai.operation.name"] = %op
  if kind == "tool" and event.kind == JObject:
    let source = event.jget("source").getStr()
    if source.len > 0:
      result["gen_ai.tool.type"] = %toolType(source)
      if source != "local":
        result["mcp.method.name"] = %"tools/call"
      if source == "waku_memory":
        result["gen_ai.memory.store.id"] = %"waku_memory"
  let cost = event.jget("cost_usd")
  if cost.kind == JInt or cost.kind == JFloat:
    result["waku.cost.usd"] = copy(cost)
  return result

proc llmCost*(provider, model: string, usage: JsonNode): float =
  ## The pricing estimate for one model call's tokens, six decimals.
  let (pIn, pOut) = priceFor(if provider.len > 0: provider else: "",
                             if model.len > 0: model else: "")
  proc num(key: string): int =
    let v = usage.jget(key)
    if v.kind == JInt: max(int(v.getBiggestInt()), 0) else: 0
  round(num("in").float / 1e6 * pIn + num("out").float / 1e6 * pOut, 6)

proc mcpServerNames*(home: string): seq[string] =
  ## The server names in `mcp.json`, longest first, so a tool name
  ## matches the most specific server. Empty when there is no file —
  ## a missing or broken file is not a turn's problem.
  result = @[]
  var text = ""
  try:
    text = readFile(home / "mcp.json")
  except IOError, OSError:
    return result
  var root: JsonNode = nil
  try:
    root = parseJson(text)
  except JsonParsingError:
    return result
  if root.isNil or root.kind != JObject:
    return result
  let servers = root.jget("servers")
  if servers.kind != JArray:
    return result
  for entry in servers:
    if entry.kind == JObject and entry.jget("name").kind == JString:
      let name = entry.jget("name").getStr()
      if name.len > 0 and name notin result:
        result.add(name)
  # Longest first (insertion sort, stable for the pins).
  for i in 1 ..< result.len:
    let key = result[i]
    var j = i - 1
    while j >= 0 and result[j].len < key.len:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = key
