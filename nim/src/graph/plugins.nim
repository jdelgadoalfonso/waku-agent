## Plugin loader — step 2: load real `.so` plugins over the JSON ABI v1.
## Step 3 adds the two things the loader was missing: the REAL host table
## (`graph/hostfns.nim`: model, tools, state, fetch, log) and a graph per
## manifest (`buildPluginGraph`), registered as `plugin:<name>` so the
## gateway can bind it and the dashboard lists it from the registry.
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
## could. Step 3 kept this documented instead of adding a mutex: the
## host's live entry is keyed by the run's handle and written/removed
## around each node call (`hostfns.beginHostCall`), which is what makes
## two sequential turns safe and two overlapping ones unsupported.
##
## Failure rule learned the hard way (step 2): never call into a
## library after `unloadLib` — not even to format an error message.
## Capture everything the message needs BEFORE unloading.

import std/dynlib
import std/json
import std/os
import std/strutils  # strip/split: manifest string fields; startsWith below

import ./engine
import ./hostfns  # HostFns, nullHostFns, the six real functions (re-exported)
import ./registry  # isKnownPluginKind, registerPluginGraph (one direction:
                   # registry NEVER imports this module, so no cycle)
import ../wire

## `HostFns` lives in `graph/hostfns.nim` so `app.nim` can hold one without
## importing this module (which pulls `graph/registry`, which pulls
## `gather`, which pulls `app`). Everything a caller used to read from here
## — the type, `nullHostFns`, the ABI version — still resolves through this
## module.
export hostfns

type
  AbiVersionFn* = proc(): uint32 {.cdecl, gcsafe.}
  InitFn* = proc(host: ptr HostFns): int32 {.cdecl, gcsafe.}
  DescribeFn* = proc(): cstring {.cdecl, gcsafe.}
  NodeRunFn* = proc(node, stateJson: cstring,
                    handle: uint64): cstring {.cdecl, gcsafe.}
  StringFreeFn* = proc(s: cstring) {.cdecl, gcsafe.}

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
  let needs = decl.needs
  proc run(state: JsonNode, notify: Observer): JsonNode =
    var input = newJObject()
    for k in keys:
      input[k] = state.jget(k)  # missing keys read as JNull
    # Publish this call's input and declared capabilities for the host
    # table: `stateKeys` reads the snapshot, and `needs` gates the model,
    # the tools and `fetch`. Paired in a `finally` so a plugin that raises
    # cannot leave a stale entry behind (one call at a time, the entry is
    # per handle and the run's handle is never reused).
    beginHostCall(handle, state, needs, notify)
    var env: JsonNode
    try:
      env = callPlugin(plugin, decl.name, input, handle)
    finally:
      endHostCall(handle)
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
  ## The step-2 surface (its eval pins all-good and one-bad); step 3's
  ## production wiring uses `loadPluginGraphs`, which also registers each
  ## plugin's graph and reports every failure instead of raising.
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

# ── one graph per manifest (step 3) ────────────────────────────────────

const pluginGraphPrefix* = "plugin:"
  ## The name a plugin's graph — and each of its nodes — is registered
  ## under: `plugin:pr_review`, `plugin:pr_review/summarize_diff`.

proc pluginDir*(home: string): string =
  ## Where discovery looks: `<home>/plugins` is `.waku/plugins` with the
  ## default home, the directory step 2 chose.
  home / "plugins"

proc buildPluginGraph*(plugin: LoadedPlugin, decls: seq[PluginNodeDecl],
                       handle: uint64 = 0): Graph =
  ## The graph a manifest implies: START → node1 → … → nodeK → END, one
  ## `pluginNode` per declared `tool`/`llm`/`agent` entry.
  ##
  ## The chain is the only topology a manifest can describe: it lists nodes,
  ## never edges, and an ordered list has exactly one shape. A branched or
  ## conditional shape needs the declarative DSL and its edge syntax, which
  ## is why a `router` entry FAILS the build here instead of being guessed
  ## at — routed plugin graphs are step 4, and a wrong chart is worse than
  ## a refused one.
  ##
  ## `handle` is the run the nodes report under (`stateKeys`, `needs`). One
  ## graph per run means one handle per run, so the gateway rebuilds the
  ## graph with a fresh handle per turn (`nextHostHandle`).
  result = Graph(name: pluginGraphPrefix & plugin.name)
  var previous = START
  for decl in decls:
    if decl.kind == "router":
      raise newException(CatchableError,
        "plugin " & plugin.name & " node '" & decl.name &
        "' is a router: routed plugin graphs arrive in step 4")
    let n = pluginNode(plugin, decl, handle)
    result.addNode(n)
    result.addEdge(previous, n.name)
    previous = n.name
  result.addEdge(previous, END)

var loaded: seq[LoadedPlugin]
  ## Every library this process loaded, in load order. Process lifetime:
  ## a successful load is never unloaded, so no entry ever leaves; the
  ## name is the manifest name, matched case-insensitively because the
  ## gateway selector lowercases what it is given.

proc registerLoadedPlugin*(plugin: LoadedPlugin) =
  ## Add (or replace) one loaded plugin. One entry per manifest name: the
  ## gateway looks a plugin up by name, so a newer file for the same plugin
  ## replaces the old one instead of shadowing it. (`loadPluginGraphs`
  ## separately checks the path, which is what keeps the same library from
  ## being initialized twice — a plugin keeps the table pointer it got.)
  for i in 0 ..< loaded.len:
    if loaded[i].path == plugin.path or
        loaded[i].name.toLowerAscii() == plugin.name.toLowerAscii():
      loaded[i] = plugin
      return
  loaded.add(plugin)

proc findLoadedPlugin*(name: string): LoadedPlugin =
  ## The plugin whose manifest name is `name`, case-insensitively. nil when
  ## absent — which the gateway turns into "no graph, run the plain loop".
  for p in loaded:
    if p.name.toLowerAscii() == name.toLowerAscii():
      return p

proc findLoadedPath(path: string): LoadedPlugin =
  ## The plugin already loaded from `path`, nil when the file is new.
  for p in loaded:
    if p.path == path:
      return p

proc loadPluginGraphs*(dir: string, host: ptr HostFns): seq[LoadedPlugin] =
  ## Discovery + registration in one place: every `.so` under `dir` (the
  ## `.waku/plugins/*.so` of step 2), its graph as `plugin:<name>` in
  ## `graph/registry` — which is what makes the dashboard list it with no
  ## dashboard change — and the plugin in this module's process registry,
  ## which is what lets `resolveGatewayGraph` bind it.
  ##
  ## Fail-open is the point: a file that does not load, and a manifest with
  ## a `router` (step 4), are one line on stderr and the rest keep working.
  ## No plugin, no graph, no stderr line — exactly today's behaviour.
  for path in discoverPluginPaths(dir):
    let already = findLoadedPath(path)
    if not already.isNil:
      result.add(already)
      registerPluginGraph(pluginGraphPrefix & already.name,
                          buildPluginGraph(already, already.nodes).describe())
      continue
    try:
      let plugin = loadPlugin(path, host)
      registerPluginGraph(pluginGraphPrefix & plugin.name,
                          buildPluginGraph(plugin, plugin.nodes).describe())
      registerLoadedPlugin(plugin)
      result.add(plugin)
    except CatchableError as exc:
      stderr.writeLine("(plugins) " & exc.msg)
