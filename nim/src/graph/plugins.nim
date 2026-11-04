## Plugin loader — step 2: load real `.so` plugins over the JSON ABI v1.
## Step 3 adds the two things the loader was missing: the REAL host table
## (`graph/hostfns.nim`: model, tools, state, fetch, log) and a graph per
## manifest (`buildPluginGraph`), registered as `plugin:<name>` so the
## gateway can bind it and the dashboard lists it from the registry.
##
## Step 4 gives the manifest edges. A `router` decl carries `routes`
## (`label -> dst`, `dst` either `END` or a node of the SAME manifest) and
## `buildPluginGraph` builds it as a real engine router instead of refusing
## it; a router without routes is refused there, because an edge-less router
## is a chart that cannot happen. Every call — node or router — publishes and
## retires the live host entry around itself, so `log` lines and capability
## calls reach the run's observer.
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
    routes*: seq[tuple[label, dst: string]]
      ## The declarative edges of a `router` entry, in declaration order:
      ## `route(state)` answers a label and the engine jumps to that label's
      ## `dst` (`END` included). Validated against the nodes of the same
      ## manifest; only a router's routes reach the engine, and a router with
      ## none is refused by `buildPluginGraph`.

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

proc routeList(def: JsonNode, pluginName: string,
               names: openArray[string]): seq[tuple[label, dst: string]] =
  ## The `routes` array of one decl, or @[] when absent. Parsed like
  ## `strSeq`: an array of objects, each with non-empty `label` and `dst`
  ## strings, labels unique within the router, and `dst` either `END` or a
  ## node of THIS manifest — a manifest never names the host's builtin
  ## nodes, which it does not own. Anything else fails the load instead of
  ## building a chart the engine would silently drop.
  let nodeName = def.jget("name").getStr()
  let arr = def.jget("routes")
  if arr.kind == JNull:
    return @[]
  if arr.kind != JArray:
    raise newException(CatchableError,
      "plugin " & pluginName & " node '" & nodeName &
      "': routes must be an array of {label, dst} objects")
  for item in items(arr):
    if item.kind != JObject:
      raise newException(CatchableError,
        "plugin " & pluginName & " node '" & nodeName &
        "': every route must be an object with label and dst")
    let label = item.jget("label")
    let dst = item.jget("dst")
    if label.kind != JString or label.getStr().len == 0:
      raise newException(CatchableError,
        "plugin " & pluginName & " node '" & nodeName &
        "': every route needs a non-empty label string")
    if dst.kind != JString or dst.getStr().len == 0:
      raise newException(CatchableError,
        "plugin " & pluginName & " node '" & nodeName &
        "': route '" & label.getStr() & "' needs a non-empty dst string")
    if dst.getStr() != END and dst.getStr() notin names:
      raise newException(CatchableError,
        "plugin " & pluginName & " node '" & nodeName &
        "': route '" & label.getStr() & "' names unknown node '" &
        dst.getStr() & "'")
    for seen in result:
      if seen.label == label.getStr():
        raise newException(CatchableError,
          "plugin " & pluginName & " node '" & nodeName &
          "': duplicate route label '" & label.getStr() & "'")
    result.add((label: label.getStr(), dst: dst.getStr()))

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
  var names: seq[string] = @[]
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
    names.add(n)
  # Routes come second on purpose: a `dst` may name a node declared LATER in
  # the manifest (the diamond shape does exactly that), so every name has to
  # be known before the first edge is checked.
  let pluginName = manifest["name"].getStr()
  for i in 0 ..< nodes.len:
    try:
      nodes[i].routes = routeList(defs[i], pluginName, names)
    except CatchableError:
      unloadLib(lib)  # a refused manifest unloads what it opened
      raise
  LoadedPlugin(name: pluginName, path: path, lib: lib,
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

const pluginGraphPrefix* = "plugin:"
  ## The name a plugin's graph — and each of its nodes — is registered
  ## under: `plugin:pr_review`, `plugin:pr_review/summarize_diff`.

proc pluginNodeName*(plugin: LoadedPlugin, nodeName: string): string =
  ## The name a manifest entry is registered under, `plugin:<plugin>/<node>`:
  ## the one spelling `pluginNode`, `findPluginNode` and `buildPluginGraph`
  ## all agree on.
  pluginGraphPrefix & plugin.name & "/" & nodeName

proc pluginNodeName*(plugin: LoadedPlugin, decl: PluginNodeDecl): string =
  ## `pluginNodeName` for a decl (its manifest name).
  pluginNodeName(plugin, decl.name)

proc pluginNode*(plugin: LoadedPlugin, decl: PluginNodeDecl,
                 handle: uint64 = 0, maxVisits = 1,
                 onError = ""): Node =
  ## A manifest `tool`/`llm`/`agent` entry as a `NodeFn`: sends only the
  ## declared `inKeys`, merges only the returned `patch` (private
  ## `_`-keys never merge, like `runOne`). A `router` entry does not
  ## belong here — use `pluginRouter`.
  let fullName = pluginNodeName(plugin, decl)
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
  ##
  ## The call publishes the same per-handle live entry `pluginNode` does
  ## (input snapshot + declared `needs`) and retires it in a `finally`, so a
  ## router can reach `stateKeys`, the model, the tools and `fetch` instead
  ## of getting `no live node call`. Three consequences, all accepted:
  ##
  ## - The engine calls the node fn AND then the router fn for one router
  ##   visit, so `waku_plugin_node_run` runs twice. Routers are stateless and
  ##   `_`-prefixed keys never merge, so the second call cannot read the
  ##   first one's answer: the label is asked for again, never handed over
  ##   through the state.
  ## - A `RouteFn` carries no observer (the engine's signature), so this live
  ##   entry's observer is nil: a model or tool call made from a router is
  ##   not metered in the trace, and a plugin `log` line from a router stays
  ##   on stderr. A node's call — where the observer rides — has neither
  ##   limit.
  ## - The window a router's entry is live for is begin -> end of its call,
  ##   exactly the node's.
  let needs = decl.needs
  result = proc(state: JsonNode): string =
    var input = newJObject()
    for k in decl.inKeys:
      input[k] = state.jget(k)
    beginHostCall(handle, state, needs)
    var env: JsonNode
    try:
      env = callPlugin(plugin, decl.name, input, handle)
    finally:
      endHostCall(handle)
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
      if pluginNodeName(p, d) == fullName:
        return (true, p, d)
  return (false, nil, PluginNodeDecl())

# ── one graph per manifest (steps 3 and 4) ──────────────────────────────────

proc pluginDir*(home: string): string =
  ## Where discovery looks: `<home>/plugins` is `.waku/plugins` with the
  ## default home, the directory step 2 chose.
  home / "plugins"

proc buildPluginGraph*(plugin: LoadedPlugin, decls: seq[PluginNodeDecl],
                       handle: uint64 = 0): Graph =
  ## The graph a manifest implies. The chain is the only topology a plain
  ## manifest can describe — it lists nodes, never edges, and an ordered list
  ## has exactly one shape: START → node1 → … → nodeK → END.
  ##
  ## A `router` entry adds the edges the manifest can now declare (step 4).
  ## It ends the chain: the edge INTO the router is kept (`previous →
  ## router`), the router's `routes` become its targets (manifest node names
  ## widened to `plugin:<name>/<node>`, `END` passed through), and every decl
  ## AFTER it is jump-only — a target, never a chained node, because a route
  ## is a jump and not a dependency. An edge out of a router would draw a line
  ## the engine never follows, which is the lie this build refuses to chart.
  ##
  ## A router with no routes is refused here: a router the engine cannot jump
  ## from is a chart that cannot happen, and a wrong chart is worse than a
  ## refused one. The failure is per plugin and fail-open (`loadPluginGraphs`
  ## logs it and the rest keep working); a plugin whose graph refuses is never
  ## registered, so the gateway fails open to the loop.
  ##
  ## `handle` is the run the nodes report under (`stateKeys`, `needs`). One
  ## graph per run means one handle per run, so the gateway rebuilds the
  ## graph with a fresh handle per turn (`nextHostHandle`).
  result = Graph(name: pluginGraphPrefix & plugin.name)
  for decl in decls:  # every node first: a route may target a later decl
    result.addNode(pluginNode(plugin, decl, handle))
  var previous = START  # the last node the chain reached
  var chained = true    # false once a router ends the linear prefix
  for decl in decls:
    let name = pluginNodeName(plugin, decl)
    if chained:
      result.addEdge(previous, name)
    if decl.kind == "router":
      if decl.routes.len == 0:
        raise newException(CatchableError,
          "plugin " & plugin.name & " node '" & decl.name &
          "' is a router without routes: a router must declare its edges")
      var targets: seq[tuple[label, dst: string]] = @[]
      for r in decl.routes:
        targets.add((label: r.label,
          dst: (if r.dst == END: END else: pluginNodeName(plugin, r.dst))))
      result.addRouter(name, pluginRouter(plugin, decl, END, handle), targets)
      chained = false
    else:
      previous = name
  if chained:
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
  ## Fail-open is the point: a file that does not load, and a manifest whose
  ## graph cannot be built (a router without routes), are one line on stderr
  ## and the rest keep working. No plugin, no graph, no stderr line — exactly
  ## today's behaviour.
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
