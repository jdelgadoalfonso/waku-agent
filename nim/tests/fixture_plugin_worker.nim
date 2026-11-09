## Runnable worker fixture: one pure tool node, no router, no needs.
## The loader fixture cannot run end to end (its router declares no
## routes, which `buildPluginGraph` refuses), so the worker tests bring
## their own runnable manifest. Null-safe and raising-free, like the
## loader fixture.

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
  retText("""{"name": "workergreet", "abi": 1, "nodes": [
    {"name": "greet", "kind": "tool",
     "inKeys": ["message"], "outKey": "greeting", "needs": []}
  ]}""")

proc waku_plugin_node_run(node, stateJson: cstring,
                          handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  try:
    let state = parseJson($stateJson)
    let message = state{"message"}.getStr("")
    let greeting = "hello: " & message
    return retText("{\"ok\": true, \"patch\": {\"greeting\": " &
      escapeJson(greeting) & ", \"reply\": " & escapeJson(greeting) &
      "}}")
  except CatchableError as exc:
    return retText("{\"ok\": false, \"error\": " & escapeJson(exc.msg) & "}")

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
