## Worker fixture mirroring the textops shape: pure + llm + router.
## NOT a test suite (`fixture_*` so `nimble test` never executes it).
## Manifest: upper (pure) -> summarize (llm) -> pick_long (router) ->
## expand (pure, long path only). The T4 eval compiles this file with
## `nim c --app:lib --panics:off -o:<tmp>/textopsfx.so` and drives it
## through `pluginRunHeadless` with a scripted client, so the
## llm+router combination the worker never exercised is pinned offline.

import std/json
import std/strutils

var runtimeStarted = false
var hostTable: pointer

type
  HostFns = object
    abiVersion: uint32
    llmComplete: proc(handle: uint64,
                      requestJson: cstring): cstring {.cdecl.}
    toolCall: proc(handle: uint64, name,
                   argsJson: cstring): cstring {.cdecl.}
    stateKeys: proc(handle: uint64, keysJson: cstring): cstring {.cdecl.}
    fetch: proc(handle: uint64, requestJson: cstring): cstring {.cdecl.}
    stringFree: proc(value: cstring) {.cdecl.}
    log: proc(handle: uint64, level: int32, message: cstring) {.cdecl.}

proc NimMain() {.importc, cdecl.}

proc host(): ptr HostFns =
  cast[ptr HostFns](hostTable)

proc retText(text: string): cstring =
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc errEnvelope(message: string): cstring =
  retText("{\"ok\": false, \"error\": " & escapeJson(message) & "}")

proc okPatch(patch: JsonNode): cstring =
  retText("{\"ok\": true, \"patch\": " & $patch & "}")

proc readEnvelope(raw: cstring): JsonNode =
  if raw.isNil:
    raise newException(CatchableError, "host returned nil")
  let text = $raw
  host().stringFree(raw)
  return parseJson(text)

proc runNode(name: string, state: JsonNode, handle: uint64): cstring =
  let h = host()
  if h.isNil:
    return errEnvelope("plugin was never given a host table")
  case name
  of "upper":
    if not h.log.isNil:
      h.log(handle, 1, "textopsfx: upper ran".cstring)
    return okPatch(%*{"upper": state{"message"}.getStr("").toUpperAscii()})
  of "summarize":
    if h.llmComplete.isNil:
      return errEnvelope("summarize needs llm: declare needs: [\"llm\"]")
    let prompt = "Summarize in one short sentence: " &
      state{"upper"}.getStr("")
    let request = %*{"model": "", "max_tokens": 64,
                     "messages": [%*{"role": "user", "content": prompt}]}
    let answer = readEnvelope(h.llmComplete(handle, ($request).cstring))
    if not answer{"ok"}.getBool(false):
      return errEnvelope(answer{"error"}.getStr("llmComplete failed"))
    var text = ""
    for part in answer{"value"}{"content"}:
      if part{"text"}.kind == JString:
        text.add(part{"text"}.getStr(""))
    if text.strip().len == 0:
      return errEnvelope("summarize got no text from the model")
    return okPatch(%*{"summary": text, "reply": text})
  of "pick_long":
    if state{"summary"}.getStr("").len > 120:
      return retText("{\"ok\": true, \"route\": \"long\"}")
    return retText("{\"ok\": true, \"route\": \"short\"}")
  of "expand":
    let summary = state{"summary"}.getStr("")
    if not h.log.isNil:
      h.log(handle, 1, "textopsfx: expand ran".cstring)
    return okPatch(%*{"expanded": summary & " [...]",
                      "reply": summary & " [...]"})
  else:
    return errEnvelope("unknown node '" & name & "'")

proc waku_plugin_abi_version(): uint32
    {.exportc: "waku_plugin_abi_version", cdecl, dynlib.} =
  1'u32

proc waku_plugin_init(table: pointer): int32
    {.exportc: "waku_plugin_init", cdecl, dynlib.} =
  if table.isNil:
    return 1
  if not runtimeStarted:
    NimMain()
    runtimeStarted = true
  hostTable = table
  if host().abiVersion != 1'u32:
    return 2
  return 0

proc waku_plugin_describe(): cstring
    {.exportc: "waku_plugin_describe", cdecl, dynlib.} =
  retText("""{"name": "textopsfx", "abi": 1, "nodes": [
    {"name": "upper", "kind": "tool",
     "inKeys": ["message"], "outKey": "upper", "needs": []},
    {"name": "summarize", "kind": "llm",
     "inKeys": ["upper"], "outKey": "summary", "needs": ["llm"]},
    {"name": "pick_long", "kind": "router",
     "inKeys": ["summary"], "outKey": "", "needs": [],
     "routes": [{"label": "long", "dst": "expand"},
                {"label": "short", "dst": "END"}]},
    {"name": "expand", "kind": "tool",
     "inKeys": ["summary"], "outKey": "expanded", "needs": []}
  ]}""")

proc waku_plugin_node_run(node, stateJson: cstring,
                          handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  try:
    if node.isNil or stateJson.isNil:
      return errEnvelope("node and state must both be strings")
    return runNode($node, parseJson($stateJson), handle)
  except CatchableError as exc:
    return errEnvelope(exc.msg)

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
