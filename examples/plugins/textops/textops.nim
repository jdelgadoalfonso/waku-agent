## textops — the reference graph plugin for Waku.
##
## Copy this file to start your own plugin. It shows the whole ABI v1
## contract in one place: five exports, the six-function host table, the
## JSON envelopes, and the ownership rule (whoever allocates a string
## frees it through their own free function).
##
## Build (Nim stable, no extra dependency):
##   nim c --app:lib --panics:off -o:textops.so textops.nim
## Install:
##   mkdir -p .waku/plugins && cp textops.so .waku/plugins/
## Then pick `plugin:textops` in the dashboard Connections panel
## (per-source `WAKU_GRAPH_<SOURCE>`) or in `WAKU_GRAPH_WORKFLOWS`.
##
## What the graph does: `upper` uppercases the turn's `message`,
## `summarize` asks the host model for one short sentence, `pick_long`
## routes long summaries to `expand` and short ones straight to END.
##
## The entry state carries the turn's text under `message` (the host
## builds it as `{"message": userMessage}`), so the first node must
## declare `inKeys: ["message"]` — a node asking for any other key
## gets null and summarizes the void.
##
## The manifest below is the contract the host validates at load:
## `dst` is `END` or a node of THIS manifest, labels are unique per
## router, and only a `router` entry's `routes` reach the engine.
##
## Two rules this file follows so you do not have to rediscover them:
## - Never import `graph/hostfns` (or any host module) here. Mirror the
##   `HostFns` struct by hand and keep its field order and types — that
##   layout IS the ABI. Importing host code would drag the host's GC
##   across the boundary.
## - Never let an exception cross `waku_plugin_node_run`. Wrap it in
##   try/except and answer `ok:false`; the engine turns that into a
##   quiet node (`state["errors"]`) instead of ending the run.

import std/json
import std/strutils

var runtimeStarted = false
var hostTable: pointer
  ## The table `waku_plugin_init` received. The host owns the memory
  ## and keeps it for the process's lifetime (a loaded library is
  ## never unloaded), so keeping the raw address is safe.

type
  HostFns = object
    ## Hand-mirror of `nim/src/graph/hostfns.HostFns`
    ## (docs/graph-plugins-design.md). Field order and types must match.
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
  ## A plugin-owned string: carved with the plugin's own allocator,
  ## released by `waku_plugin_string_free`. Never hand out a Nim
  ## string's buffer — it belongs to this runtime's GC.
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc errEnvelope(message: string): cstring =
  retText("{\"ok\": false, \"error\": " & escapeJson(message) & "}")

proc okPatch(patch: JsonNode): cstring =
  retText("{\"ok\": true, \"patch\": " & $patch & "}")

proc readEnvelope(raw: cstring): JsonNode =
  ## A host-owned answer, copied onto THIS heap before the host frees
  ## its copy. Never the other way round: two allocators, one rule.
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
      h.log(handle, 1, "textops: upper ran".cstring)
    let text = state{"message"}.getStr("")
    return okPatch(%*{"upper": text.toUpperAscii()})
  of "summarize":
    if h.llmComplete.isNil:
      return errEnvelope("summarize needs llm: declare needs: [\"llm\"]")
    # Plain-text-only instruction: some models (notably reasoning ones)
    # answer with thinking blocks and no text block at all, which the
    # extractor below would rightly refuse. Asking for only the sentence
    # keeps the plugin path working across models.
    let prompt = "Summarize in one short sentence. Reply with ONLY that " &
      "sentence as plain text — no preamble, no explanation, no thinking: " &
      state{"upper"}.getStr("")
    # Empty model is the point: the host runs this on the agent's own
    # model, so the plugin stays portable across provider registries.
    # Headroom on purpose: a reasoning model spends tokens thinking
    # before answering, and a tight cap can leave zero for the text.
    let request = %*{"model": "", "max_tokens": 256,
                     "messages": [%*{"role": "user", "content": prompt}]}
    let answer = readEnvelope(h.llmComplete(handle, ($request).cstring))
    if not answer{"ok"}.getBool(false):
      return errEnvelope(answer{"error"}.getStr("llmComplete failed"))
    # Any block carrying text counts, not just `type == "text"`: a
    # reasoning model may answer with `reasoning` blocks and no text
    # block at all, and taking only `text` turns that into a silent
    # empty reply — the one outcome nobody can debug.
    var text = ""
    for part in answer{"value"}{"content"}:
      if part{"text"}.kind == JString:
        text.add(part{"text"}.getStr(""))
    if text.strip().len == 0:
      # Loud, not empty: an empty patch would merge `reply: ""` and the
      # turn would answer silence. `ok:false` drains the node and the
      # host fails the turn open to the loop with this message.
      return errEnvelope("summarize got no text from the model")
    # `reply` is the key every graph door answers from, so the last
    # node on the short path writes it too (see `expand` below).
    return okPatch(%*{"summary": text, "reply": text})
  of "pick_long":
    # The label the manifest's `routes` translate into a jump.
    let summary = state{"summary"}.getStr("")
    if summary.len > 120:
      return retText("{\"ok\": true, \"route\": \"long\"}")
    return retText("{\"ok\": true, \"route\": \"short\"}")
  of "expand":
    let summary = state{"summary"}.getStr("")
    if not h.log.isNil:
      h.log(handle, 1, "textops: expand ran".cstring)
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
  retText("""{"name": "textops", "abi": 1, "nodes": [
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
    # `--panics:off` makes even a Defect catchable, so bad input
    # becomes `ok:false` (a quiet node) instead of ending Waku.
    return errEnvelope(exc.msg)

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
