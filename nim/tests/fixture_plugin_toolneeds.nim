## Ineligible worker fixture: one node needing a parent-side tool.
## The worker must refuse it before running anything.

import std/json

proc NimMain() {.importc, cdecl.}

proc retText(text: string): cstring =
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc waku_plugin_abi_version(): uint32
    {.exportc: "waku_plugin_abi_version", cdecl, dynlib.} =
  1

proc waku_plugin_init(host: pointer): int32
    {.exportc: "waku_plugin_init", cdecl, dynlib.} =
  0

proc waku_plugin_describe(): cstring
    {.exportc: "waku_plugin_describe", cdecl, dynlib.} =
  retText("""{"name": "toolhungry", "abi": 1, "nodes": [
    {"name": "fetchit", "kind": "tool",
     "inKeys": ["message"], "outKey": "fetched", "needs": ["tool"]}
  ]}""")

proc waku_plugin_node_run(node, stateJson: cstring,
                          handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  return retText("{\"ok\": false, \"error\": \"must never run\"}")

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
