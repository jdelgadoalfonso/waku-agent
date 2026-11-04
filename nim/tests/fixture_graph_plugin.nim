## Graph fixture plugin for the step-3 eval — NOT a test suite.
##
## Named `fixture_*` (not `test_*`) so `nimble test` never executes it. The
## eval compiles this file with
## `nim c --app:lib --panics:off -o:<tmp>/fixture_graph_plugin.so` and drives
## the result through the REAL host table (`graph/hostfns.nim`), so the whole
## step-3 surface is exercised with a real dynamic library and zero network:
## two chained tool nodes, and an `llm` node that calls `host.llmComplete`
## for its text.
##
## What each node proves:
## - `first` writes `stage1` from its declared `inKeys` — the chain works,
##   and the host merges the patch before the next node runs.
## - `second` reads `stage1` (the first node's outKey, so the chain is real)
##   and asks the host for `message` through `stateKeys`, a key it did NOT
##   declare: the live input indexed by the run's handle is reachable.
## - `summarize` declares `needs: ["llm"]`, builds a Messages request and
##   calls `host.llmComplete`, then merges the text out of the FULL response
##   object (`value.content`), which is what the host promises to hand over.
##
## Two runtimes in one process, so this file mirrors the contract by hand
## instead of importing `graph/hostfns.nim` (importing it would drag the
## host's runtime across the boundary). The struct below must keep the
## contract's field order and types — that layout is the ABI.
##
## Allocator note: every returned string is carved with `alloc0` and
## released with `dealloc` in `waku_plugin_string_free` — the plugin's own
## allocator, never the host's. Symmetrically, a string the HOST returns is
## copied onto this heap BEFORE `host.stringFree` frees it.

import std/json

var runtimeStarted = false
var hostTable: pointer
  ## The table `waku_plugin_init` received. Stored as the raw address: the
  ## host owns the memory and keeps it for the process's lifetime.

type
  HostFns = object
    ## Mirror of `graph/hostfns.HostFns` (docs/graph-plugins-design.md).
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
  ## The host's answer, copied onto THIS heap before the host frees its
  ## copy. Never the other way round: two allocators, one rule.
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
  of "first":
    return okPatch(%*{"stage1": "first:" & state{"message"}.getStr("")})
  of "second":
    # The live input, one key this node never declared: what `stateKeys`
    # exists for. (Its declared `stage1` is already in `state` because the
    # host merged the previous node's patch.)
    if h.stateKeys.isNil:
      return errEnvelope("stateKeys is not enabled for this node")
    let keys = readEnvelope(h.stateKeys(handle, "[\"message\"]".cstring))
    if not keys{"ok"}.getBool(false):
      return errEnvelope(keys{"error"}.getStr("stateKeys failed"))
    let message = keys{"value"}{"message"}.getStr("")
    return okPatch(%*{"stage2": "second:" & state{"stage1"}.getStr("") &
                      "/" & message})
  of "summarize":
    if h.llmComplete.isNil:
      return errEnvelope("llmComplete is not enabled for this node")
    let prompt = state{"stage2"}.getStr("")
    let request = %*{"model": "chain-model", "max_tokens": 64,
                     "messages": [%*{"role": "user", "content": prompt}]}
    let answer = readEnvelope(h.llmComplete(handle, ($request).cstring))
    if not answer{"ok"}.getBool(false):
      return errEnvelope(answer{"error"}.getStr("llmComplete failed"))
    var text = ""
    for part in answer{"value"}{"content"}:
      if part{"type"}.getStr("") == "text":
        text.add(part{"text"}.getStr(""))
    # `reply` is the key every graph door in the port answers from
    # (`triageGraphTurn` reads it), so a plugin graph's last node writes it.
    return okPatch(%*{"reply": text})
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
  retText("""{"name": "chainfx", "abi": 1, "nodes": [
    {"name": "first", "kind": "tool",
     "inKeys": ["message"], "outKey": "stage1", "needs": []},
    {"name": "second", "kind": "tool",
     "inKeys": ["stage1"], "outKey": "stage2", "needs": []},
    {"name": "summarize", "kind": "llm",
     "inKeys": ["stage2"], "outKey": "reply", "needs": ["llm"]}
  ]}""")

proc waku_plugin_node_run(node, stateJson: cstring,
                          handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  try:
    if node.isNil or stateJson.isNil:
      return errEnvelope("node and state must both be strings")
    return runNode($node, parseJson($stateJson), handle)
  except CatchableError as exc:
    # `--panics:off` makes a Defect catchable too, so a bad input turns
    # into `ok:false` (a quiet node) instead of ending Waku.
    return errEnvelope(exc.msg)

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
