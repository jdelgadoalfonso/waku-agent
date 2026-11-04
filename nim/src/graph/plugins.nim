## Plugin loader — step 2: load real `.so` plugins over the JSON ABI v1.
##
## `loadPlugin` opens one library, gates its ABI version, runs its init
## (which calls `NimMain` once on the plugin side), reads its manifest,
## and returns a `LoadedPlugin` whose `pluginNode`/`pluginRouter`
## closures are plain `NodeFn`/`RouteFn` values — the engine never knows
## a `.so` is behind them. Discovery scans `.waku/plugins/*.so`;
## a successful load is never unloaded (process lifetime).
##
## Two rules from the contract, enforced here, not trusted:
## - Copy before free: the host copies every plugin-owned `cstring`
##   onto its own heap (`$cs`) BEFORE `waku_plugin_string_free`.
## - `ok:false` becomes a raise, so `runOne` writes `state["errors"]`
##   and merges nothing — a plugin that cannot answer turns its node
##   quiet instead of ending the run.
##
## Concurrency assumption (unverified against dashboard HTTP turns):
## one plugin call at a time. The engine runs waves sequentially, so a
## single `runGraph` never re-enters a plugin; two concurrent turns
## could. Until that is measured, treat concurrent turns over one
## plugin as unsupported — a mutex belongs to step 3 if needed.
##
## Failure rule learned the hard way (step 2): never call into a
## library after `unloadLib` — not even to format an error message.
## Capture everything the message needs BEFORE unloading.

import std/dynlib
import std/json
import std/os
import std/strutils  # strip/split: manifest string fields; startsWith below

import ./engine
import ./registry  # isKnownPluginKind only (one direction: registry never imports here)
import ../wire

const pluginAbiVersion* = 1'u32
  ## The only ABI version this host speaks. `waku_plugin_abi_version`
  ## must answer exactly this or the library is refused at load.

type
  AbiVersionFn* = proc(): uint32 {.cdecl, gcsafe.}
  InitFn* = proc(host: ptr HostFns): int32 {.cdecl, gcsafe.}
  DescribeFn* = proc(): cstring {.cdecl, gcsafe.}
  NodeRunFn* = proc(node, stateJson: cstring,
                    handle: uint64): cstring {.cdecl, gcsafe.}
  StringFreeFn* = proc(s: cstring) {.cdecl, gcsafe.}

  HostFns* = object
    ## Mirror of the contract (docs/graph-plugins-design.md): the table
    ## handed to `waku_plugin_init`. A null pointer means the person did
    ## not enable that capability. Step 2 passes a table of nulls (good
    ## enough for `tool` nodes with no `needs`); step 3 fills the real
    ## fns where client and tools live. The table must outlive every
    ## plugin (process lifetime) — the plugin stores this pointer.
    abiVersion*: uint32
    llmComplete*: proc(handle: uint64,
                       requestJson: cstring): cstring {.cdecl, gcsafe.}
    toolCall*: proc(handle: uint64, name,
                    argsJson: cstring): cstring {.cdecl, gcsafe.}
    stateKeys*: proc(handle: uint64,
                     keysJson: cstring): cstring {.cdecl, gcsafe.}
    fetch*: proc(handle: uint64,
                 requestJson: cstring): cstring {.cdecl, gcsafe.}
    stringFree*: proc(value: cstring) {.cdecl, gcsafe.}
    log*: proc(handle: uint64, level: int32,
               message: cstring) {.cdecl, gcsafe.}

  PluginNodeDecl* = object
    ## One validated manifest entry.
    name*: string
    kind*: string
    inKeys*: seq[string]
    outKey*: string
    needs*: seq[string]

  LoadedPlugin* = ref object
    name*: string
    path*: string
    lib*: LibHandle
    nodeRun*: NodeRunFn
    stringFree*: StringFreeFn
    nodes*: seq[PluginNodeDecl]

proc nullHostFns*(): HostFns =
  ## Step-2 host table: version set, every capability null. A plugin
  ## that needs a capability finds a null pointer and must answer
  ## `ok:false` instead of calling it.
  HostFns(abiVersion: pluginAbiVersion)

proc symOrRaise(lib: LibHandle, path, sym: string): pointer =
  ## `symAddr`, but a missing symbol fails the load with its name —
  ## never a nil call through.
  result = symAddr(lib, sym)
  if result.isNil:
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " misses symbol '" & sym & "'")

proc strSeq(node: JsonNode, key: string): seq[string] =
  ## A manifest string array, or @[] when absent. Non-string entries
  ## fail the load — a manifest is data the host trusts structurally.
  let arr = node.jget(key)
  if arr.kind == JNull:
    return @[]
  if arr.kind != JArray:
    raise newException(CatchableError,
      "plugin manifest key '" & key & "' must be an array of strings")
  for item in items(arr):
    if item.kind != JString:
      raise newException(CatchableError,
        "plugin manifest key '" & key & "' must be an array of strings")
    result.add(item.getStr())

proc loadPlugin*(path: string, host: ptr HostFns): LoadedPlugin =
  ## Open, gate, init, describe, validate. Raises (never nil) on any
  ## failure; a failed load unloads what it opened. A SUCCESSFUL load
  ## is never unloaded — process lifetime, per the contract.
  let lib = loadLib(path)
  if lib.isNil:
    raise newException(CatchableError, "cannot load plugin " & path)
  let abiFn = cast[AbiVersionFn](symOrRaise(lib, path, "waku_plugin_abi_version"))
  let initFn = cast[InitFn](symOrRaise(lib, path, "waku_plugin_init"))
  let describeFn =
    cast[DescribeFn](symOrRaise(lib, path, "waku_plugin_describe"))
  let nodeRunFn =
    cast[NodeRunFn](symOrRaise(lib, path, "waku_plugin_node_run"))
  let freeFn =
    cast[StringFreeFn](symOrRaise(lib, path, "waku_plugin_string_free"))
  let version = abiFn()
  if version != pluginAbiVersion:
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " speaks ABI " & $version & ", host wants " &
      $pluginAbiVersion)
  if initFn(host) != 0:
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " init refused the host table")
  let raw = describeFn()
  if raw.isNil:
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " returned nil manifest")
  let text = $raw  # copy to the host heap BEFORE the plugin frees its copy
  freeFn(raw)
  var manifest: JsonNode
  try:
    manifest = parseJson(text)
  except JsonParsingError as exc:
    raise newException(CatchableError,
      "plugin " & path & " manifest is not JSON: " & exc.msg)
  if manifest.kind != JObject or
      manifest.jget("name").kind != JString or
      manifest.jget("name").getStr().len == 0:
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " manifest needs a non-empty name")
  if manifest.jget("abi").getInt(-1) != int(pluginAbiVersion):
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " manifest abi is not " & $pluginAbiVersion)
  let defs = manifest.jget("nodes")
  if defs.kind != JArray:
    unloadLib(lib)
    raise newException(CatchableError,
      "plugin " & path & " manifest needs a nodes array")
  var nodes: seq[PluginNodeDecl] = @[]
  for def in items(defs):
    let n = def.jget("name").getStr()
    let k = def.jget("kind").getStr()
    if n.len == 0:
      unloadLib(lib)
      raise newException(CatchableError,
        "plugin " & path & " has a node without a name")
    if not isKnownPluginKind(k):
      unloadLib(lib)
      raise newException(CatchableError,
        "plugin " & path & " declares unknown kind '" & k & "'")
    nodes.add(PluginNodeDecl(name: n, kind: k, inKeys: strSeq(def, "inKeys"),
                             outKey: def.jget("outKey").getStr(),
                             needs: strSeq(def, "needs")))
  LoadedPlugin(name: manifest["name"].getStr(), path: path, lib: lib,
               nodeRun: nodeRunFn, stringFree: freeFn, nodes: nodes)

proc callPlugin*(plugin: LoadedPlugin, nodeName: string, input: JsonNode,
                 handle: uint64 = 0): JsonNode =
  ## One call across the boundary. Serializes `input`, copies the
  ## answer before freeing it, and turns `ok:false` into a raise so
  ## `runOne` records it in `state["errors"]` and merges nothing.
  let req = $input
  let cs = plugin.nodeRun(nodeName.cstring, req.cstring, handle)
  if cs.isNil:
    raise newException(CatchableError, "plugin " & plugin.name &
      " returned nil for node " & nodeName)
  let text = $cs  # host-side copy BEFORE the plugin frees its buffer
  plugin.stringFree(cs)
  var env: JsonNode
  try:
    env = parseJson(text)
  except JsonParsingError as exc:
    raise newException(CatchableError, "plugin " & plugin.name &
      " node " & nodeName & " returned non-JSON: " & exc.msg)
  if not env.jget("ok").getBool(false):
    raise newException(CatchableError,
      env.jget("error").getStr("plugin " & plugin.name & " failed"))
  return env

proc pluginNode*(plugin: LoadedPlugin, decl: PluginNodeDecl,
                 handle: uint64 = 0, maxVisits = 1,
                 onError = ""): Node =
  ## A manifest `tool`/`llm`/`agent` entry as a `NodeFn`: sends only the
  ## declared `inKeys`, merges only the returned `patch` (private
  ## `_`-keys never merge, like `runOne`). A `router` entry does not
  ## belong here — use `pluginRouter`.
  let fullName = "plugin:" & plugin.name & "/" & decl.name
  let keys = decl.inKeys
  let kind = decl.kind
  proc run(state: JsonNode, notify: Observer): JsonNode =
    var input = newJObject()
    for k in keys:
      input[k] = state.jget(k)  # missing keys read as JNull
    let env = callPlugin(plugin, decl.name, input, handle)
    var outp = newJObject()
    let patch = env.jget("patch")
    if patch.kind == JObject:
      for key, value in pairs(patch):
        if not key.startsWith("_"):
          outp[key] = copy(value)
    return outp
  newNode(fullName, run, kind = kind, maxVisits = maxVisits,
          onError = onError)

proc pluginRouter*(plugin: LoadedPlugin, decl: PluginNodeDecl,
                   default: string, handle: uint64 = 0): RouteFn =
  ## A manifest `router` entry as a `RouteFn`: reads the returned
  ## `route` label, falling back to `default` exactly like `keyRouter`.
  result = proc(state: JsonNode): string =
    var input = newJObject()
    for k in decl.inKeys:
      input[k] = state.jget(k)
    let env = callPlugin(plugin, decl.name, input, handle)
    let route = env.jget("route")
    if route.kind == JString and route.getStr().len > 0:
      return route.getStr()
    return default

proc discoverPluginPaths*(dir: string): seq[string] =
  ## Every `.so` under `dir`, sorted for determinism. A missing dir is
  ## not an error — a fresh machine simply has no plugins.
  if not dirExists(dir):
    return @[]
  for path in walkFiles(dir / "*.so"):
    result.add(path)

proc loadDiscovered*(dir: string, host: ptr HostFns): seq[LoadedPlugin] =
  ## Load everything `discoverPluginPaths` finds, in order. One bad
  ## library does not poison the rest: its error is raised to the
  ## caller only when it is the ONLY plugin — otherwise it is skipped.
  ## (Step 2 keeps this honest and simple: production wiring in step 3
  ## decides the surface policy; the eval pins all-good and one-bad.)
  var failures: seq[string] = @[]
  for path in discoverPluginPaths(dir):
    try:
      result.add(loadPlugin(path, host))
    except CatchableError as exc:
      failures.add(path & ": " & exc.msg)
  if result.len == 0 and failures.len > 0:
    raise newException(CatchableError,
      "no plugin loaded: " & failures.join("; "))

proc findPluginNode*(plugins: seq[LoadedPlugin],
                     fullName: string): tuple[found: bool, plugin: LoadedPlugin,
                                             decl: PluginNodeDecl] =
  ## Look up `plugin:<plugin>/<node>` across loaded plugins.
  for p in plugins:
    for d in p.nodes:
      if "plugin:" & p.name & "/" & d.name == fullName:
        return (true, p, d)
  return (false, nil, PluginNodeDecl())
