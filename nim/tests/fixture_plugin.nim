## Fixture plugin for the step-2 loader eval — NOT a test suite.
##
## Named `fixture_*` (not `test_*`) so `nimble test` never executes it.
## The eval compiles this file with
## `nim c --app:lib --panics:off -o:<tmp>/fixture_plugin.so` and loads
## the result through `graph/plugins.loadPlugin`, so the whole boundary
## (dlopen, version gate, init+NimMain, describe, node_run, string_free)
## is exercised with a real dynamic library and zero network.
##
## Allocator note: every returned string is carved with `alloc0` and
## released with `dealloc` in `waku_plugin_string_free` — the plugin's
## own allocator, never the host's. That IS the ownership rule under
## test on the plugin side.
##
## `-d:fixtureAbi=N` overrides the answered ABI version (default 1) so
## the eval can pin the host's version gate with a second build.

import std/json

const fixtureAbi {.intdefine.} = 1

var runtimeStarted = false

proc NimMain() {.importc, cdecl.}

proc retText(text: string): cstring =
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc waku_plugin_abi_version(): uint32
    {.exportc: "waku_plugin_abi_version", cdecl, dynlib.} =
  uint32(fixtureAbi)

proc waku_plugin_init(host: pointer): int32
    {.exportc: "waku_plugin_init", cdecl, dynlib.} =
  if host.isNil:
    return 1
  if not runtimeStarted:
    NimMain()
    runtimeStarted = true
  return 0

proc waku_plugin_describe(): cstring
    {.exportc: "waku_plugin_describe", cdecl, dynlib.} =
  retText("""{"name": "fixture", "abi": 1, "nodes": [
    {"name": "echo_tool", "kind": "tool",
     "inKeys": ["text"], "outKey": "echoed", "needs": []},
    {"name": "choose", "kind": "router",
     "inKeys": ["pick"], "outKey": "", "needs": []},
    {"name": "failer", "kind": "tool",
     "inKeys": [], "outKey": "", "needs": []}
  ]}""")

proc waku_plugin_node_run(node, stateJson: cstring,
                          handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  try:
    let name = $node
    let state = parseJson($stateJson)
    if name == "echo_tool":
      let text = state{"text"}.getStr("")
      return retText("{\"ok\": true, \"patch\": {\"echoed\": " &
        escapeJson("echo:" & text) & ", \"_secret\": \"never merges\"}}")
    if name == "choose":
      let pick = state{"pick"}.getStr("")
      return retText("{\"ok\": true, \"route\": " & escapeJson(pick) & "}")
    if name == "failer":
      return retText("{\"ok\": false, \"error\": \"fixture refuses\"}")
    return retText("{\"ok\": false, \"error\": \"unknown node '\" & name & \"'\"}")
  except CatchableError as exc:
    let msg = exc.msg
    return retText("{\"ok\": false, \"error\": " & escapeJson(msg) & "}")

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
