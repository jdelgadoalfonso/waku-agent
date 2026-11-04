## Host capability table — step 3: the six functions a plugin calls back into.
##
## The contract is `docs/graph-plugins-design.md`: `waku_plugin_init` receives
## a pointer to this table and keeps it for the process's lifetime, because a
## loaded library is never unloaded. The table therefore lives in a heap cell
## (`newHostTable`), never on a stack frame, and is built once where a live
## `LlmClient` and `ToolRegistry` exist — `buildCliApp` and `ensureWaku` — so
## the dashboard, the CLI and every gateway reach the same capabilities. The
## cell is also kept alive by this module (`keptTables`): a plugin holds a
## raw address, so an owner that goes away (a gateway box restart, a test's
## local) must not be able to free memory a loaded library still points at.
##
## Two things the type cannot carry, and how this module answers them:
##
## - **There is no user-data slot.** The ABI fixes the six signatures (no
##   context argument), so the functions find their client, their tools and
##   their in-flight input through `activeScope`: one host per process, which
##   is also how many tables the process can own (a library loads once and
##   keeps the pointer its `init` received).
## - **`needs` arrives after `init`.** A manifest is read with
##   `waku_plugin_describe`, and describing needs a started runtime, so the
##   host cannot know a node's capabilities before the table is handed over.
##   The base table therefore carries all six real functions, and `needs` is
##   enforced twice, neither of them by a null deref:
##     `hostFnsFor(base, needs)` is the pointer-level answer — a capability a
##     caller did not enable is a nil pointer, which is what the contract says
##     a narrowed host looks like. The live entry recorded per node call then
##     answers `ok:false` for a capability the node did not declare, so a
##     manifest that under-declares gets a readable error instead of a crash.
##
## Every answer is one envelope, `{"ok":true,"value":...}` or
## `{"ok":false,"error":"..."}`, and nothing here raises across the boundary:
## a model refusal, a tool error or a dead socket becomes `ok:false` with the
## same human sentence the rest of the port shows (`errorText`).
##
## Ownership: the host allocates every string it returns with `alloc0` and
## frees it with `dealloc` in `stringFree` — the plugin never touches the
## host's allocator, and the host never touches the plugin's. The plugin
## copies the text onto its own heap BEFORE calling `stringFree`; the reverse
## rule (host copies a plugin string before the plugin frees it) lives in
## `graph/plugins.nim`.
##
## Concurrency: ONE plugin call at a time. The engine runs a wave's nodes
## sequentially, so a handle's live entry is written before the call and
## removed after it; two overlapping calls for one handle are unsupported.
## `llmComplete` is metered (`kind: "plugin"`) through the observer the node
## call carried, so a model call behind a `.so` still lands in the trace and
## the spend ledger.
##
## Lifecycle: one handle per run. Every visit — a node AND the router on that
## node — publishes its entry and retires it in a `finally`, so the live
## window is begin -> end of that visit. `expireHandle` is the net for a run
## that stopped between visits; `dashboard.pluginGraphTurn` pulls it after
## `runGraph`, so a handle can never outlive its turn.

import std/httpclient
import std/json
import std/strutils
import std/tables

import ../http
import ../loop
import ../tools
import ../wire

const
  pluginAbiVersion* = 1'u32
    ## The only ABI version this host speaks. `waku_plugin_abi_version` must
    ## answer exactly this or the library is refused at load.

  fetchTimeoutMs* = 30_000
    ## `fetch` has no timeout in the ABI, and the host must not hand a
    ## plugin an unbounded socket: one number bounds every call, stated
    ## here so a slower endpoint is a decision someone makes on purpose.

  capabilityNeeds* = ["llm", "tool", "fetch"]
    ## The capability names a manifest's `needs` may gate. `stateKeys` and
    ## `log` are not capabilities (they are the run's own input and a
    ## diagnostic line), and `stringFree` is plumbing.

type
  HostFns* = object
    ## Mirror of the contract (docs/graph-plugins-design.md): the table
    ## handed to `waku_plugin_init`. A null pointer means that capability
    ## was not enabled — the plugin must answer `ok:false` rather than call
    ## a nil through. `nullHostFns()` is the all-null form the step-2 tests
    ## still use; `hostFns(scope)` is the real one.
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

  HostCall* = object
    ## One node call in flight, keyed by its run's handle: what `stateKeys`
    ## reads, what the capability fns check, and the observer the model
    ## call reports through.
    state*: JsonNode
    needs*: seq[string]
    notify*: Observer

  HostScope* = ref object
    ## Everything the six functions need, behind the one process-wide
    ## pointer described in the header.
    client*: LlmClient
    tools*: ToolRegistry
    live*: Table[uint64, HostCall]

var activeScope: HostScope
  ## The table's backing store. One per process, like the loaded libraries:
  ## installed by `hostFns`/`installHostScope`, read by every host function.

var handles: uint64
  ## Monotonic handle source for graph runs (`nextHostHandle`). Never
  ## reused, so a stale call cannot read a later run's input.

# ── the envelope and the host's allocator ─────────────────────────────

proc hostText(text: string): cstring =
  ## A string the PLUGIN frees through `stringFree`. `alloc0` + `copyMem`,
  ## never a Nim string's buffer: that one belongs to the host's GC, and
  ## the plugin's `dealloc` would corrupt it.
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc envelopeOk(value: JsonNode): cstring =
  hostText($(%*{"ok": true, "value": value}))

proc envelopeErr(message: string): cstring =
  hostText($(%*{"ok": false, "error": message}))

proc hostStringFree(value: cstring) {.cdecl, gcsafe.} =
  ## The host's own deallocator, exposed so the plugin never calls the
  ## host's allocator behind its back. Mirrored by the plugin's
  ## `waku_plugin_string_free`.
  if not value.isNil:
    dealloc(value)

# ── the live call, and the capability gate ────────────────────────────

proc liveCall(handle: uint64): bool =
  ## Whether a node call is in flight for `handle`. Outside one (a plugin
  ## calling from `init`, say) there is no input, no observer and no
  ## declared capability, so every capability fn answers `ok:false`.
  not activeScope.isNil and activeScope.live.hasKey(handle)

proc noLiveCall(handle: uint64): cstring =
  envelopeErr("no live node call for handle " & $handle &
    " (host functions are callable from waku_plugin_node_run only)")

proc capabilityDenied(handle: uint64, capability: string): cstring =
  envelopeErr("node did not declare needs: " & $capability &
    " for handle " & $handle)

proc allowed(handle: uint64, capability: string): bool =
  ## The node-level `needs` check, bounded by the three names the host
  ## actually gates (`capabilityNeeds`): a manifest that declares
  ## `needs: ["llms"]` enables nothing, which is the honest reading of a
  ## capability name nobody implements. A handle with no live entry is
  ## refused by `liveCall` before this runs.
  capability in capabilityNeeds and
    capability in activeScope.live[handle].needs

proc beginHostCall*(handle: uint64, state: JsonNode, needs: seq[string],
                    notify: Observer = nil) =
  ## Publish one node call: the snapshot `stateKeys` may read, its declared
  ## capabilities, and the observer a metered model call reports through.
  ## `notify` is nil where the caller carries no observer — a router's
  ## `RouteFn` has none — and a nil observer is not an error: `log` then
  ## keeps its stderr line and every capability call still answers.
  ## A no-op with no scope installed (the null table of step 2 cannot call
  ## back at all), which keeps the loader tests unchanged.
  if activeScope.isNil:
    return
  activeScope.live[handle] = HostCall(state: state, needs: needs,
                                      notify: notify)

proc endHostCall*(handle: uint64) =
  ## Retire one node call. Paired with `beginHostCall` by the node and router
  ## wrappers in `graph/plugins.nim`. The window a call is live for is exactly
  ## begin -> end of one visit: nothing survives a node, so a stale entry can
  ## only come from a wrapper that never reached its `finally`. An overlapped
  ## call for the same handle would overwrite this entry, which is why the
  ## host documents one at a time.
  if activeScope.isNil:
    return
  activeScope.live.del(handle)

proc expireHandle*(handle: uint64) =
  ## The safety net `beginHostCall`/`endHostCall` cannot close by themselves:
  ## a run that stopped between two nodes (a `GraphStateCollision`, a step
  ## limit, an exception out of a router) would leave the last visit's input
  ## reachable through its handle. One handle lives for one turn, so
  ## `dashboard.pluginGraphTurn` drops it after `runGraph` — a later turn can
  ## then never read this one's state, and `noLiveCall` answers every host
  ## function asked afterwards. Idempotent: retiring an unknown handle is a
  ## no-op, so the ordinary case (every visit already retired itself) costs
  ## one lookup.
  if activeScope.isNil:
    return
  activeScope.live.del(handle)

proc nextHostHandle*(): uint64 =
  ## A fresh handle for one graph run.
  inc handles
  return handles

# ── llm ───────────────────────────────────────────────────────────────

proc hostLlmComplete(handle: uint64, requestJson: cstring): cstring
    {.cdecl, gcsafe.} =
  ## One model call, through the same client the rest of the port uses and
  ## metered like every other side call: the answer is the WHOLE assembled
  ## response (`content`, `stop_reason`, `usage`) in `value`, so a plugin
  ## has everything the loop would have seen. A refusal keeps its human
  ## sentence (`errorText`), never a raw body.
  ##
  ## `{.cast(gcsafe).}` (here and on the three functions below) states the
  ## thread fact instead of pretending it away: the fn pointers carry no
  ## context, so they read the process-wide `activeScope`, which the wiring
  ## installs once at startup; graph runs drive plugin calls from the thread
  ## that installed it (a wave's nodes run in order, and the dashboard's
  ## serve loop is single-threaded). A second thread would be a data race,
  ## so the checker is told rather than silenced.
  {.cast(gcsafe).}:
    try:
      if not liveCall(handle):
        return noLiveCall(handle)
      let call = activeScope.live[handle]
      if "llm" notin call.needs:
        return capabilityDenied(handle, "llm")
      if requestJson.isNil:
        return envelopeErr("llmComplete needs a request object")
      var req: JsonNode
      try:
        req = parseJson($requestJson)
      except JsonParsingError as exc:
        return envelopeErr("llmComplete request is not JSON: " & exc.msg)
      if req.kind != JObject:
        return envelopeErr("llmComplete request must be a JSON object")
      let metered = meteredClient(activeScope.client, "plugin",
                                  req.jget("model").getStr(""), call.notify)
      return envelopeOk(metered.create(req))
    except CatchableError as exc:
      return envelopeErr(errorText(exc))

# ── tools ─────────────────────────────────────────────────────────────

proc hostToolCall(handle: uint64, name, argsJson: cstring): cstring
    {.cdecl, gcsafe.} =
  ## One tool call through `ToolRegistry.execute`, which already answers a
  ## failure as text (`"Error: unknown tool 'x'"`). That text rides `value`
  ## with `ok:true`: a tool that failed is an observation the plugin may
  ## reason about, not a broken host call. Only a malformed payload is
  ## `ok:false`.
  {.cast(gcsafe).}:
    try:
      if not liveCall(handle):
        return noLiveCall(handle)
      if not allowed(handle, "tool"):
        return capabilityDenied(handle, "tool")
      if name.isNil:
        return envelopeErr("toolCall needs a tool name")
      var args = newJObject()
      let rawArgs = if argsJson.isNil: "" else: $argsJson
      if rawArgs.strip().len > 0:
        try:
          args = parseJson(rawArgs)
        except JsonParsingError as exc:
          return envelopeErr("toolCall args are not JSON: " & exc.msg)
        if args.kind != JObject:
          return envelopeErr("toolCall args must be a JSON object")
      return envelopeOk(%activeScope.tools.execute($name, args))
    except CatchableError as exc:
      return envelopeErr(errorText(exc))

# ── state ─────────────────────────────────────────────────────────────

proc parseKeyList(raw: string): seq[string] =
  ## `["a","b"]`, `"a"`, or `{"keys":["a"]}` — a key list is small and a
  ## plugin author should not have to remember which of the three the host
  ## wanted. Non-strings are ignored.
  if raw.strip().len == 0:
    return @[]
  let node = parseJson(raw)
  case node.kind
  of JArray:
    for item in items(node):
      if item.kind == JString:
        result.add(item.getStr())
  of JString:
    result.add(node.getStr())
  of JObject:
    for item in items(node.jget("keys")):
      if item.kind == JString:
        result.add(item.getStr())
  else:
    discard

proc hostStateKeys(handle: uint64, keysJson: cstring): cstring
    {.cdecl, gcsafe.} =
  ## A subset of the live input for `handle`: the keys the caller asks
  ## for, `null` when the state does not hold one. `_`-prefixed keys are
  ## the host's own (`_notify` and friends) and never cross, so they read
  ## as `null` exactly like a missing key. Not gated by `needs`: the run's
  ## own input is not a capability.
  {.cast(gcsafe).}:
    try:
      if not liveCall(handle):
        return noLiveCall(handle)
      let state = activeScope.live[handle].state
      let raw = if keysJson.isNil: "" else: $keysJson
      var parsed: seq[string]
      try:
        parsed = parseKeyList(raw)
      except JsonParsingError as exc:
        return envelopeErr("stateKeys expects a JSON array of keys: " &
                           exc.msg)
      var value = newJObject()
      for key in parsed:
        if key.startsWith("_"):
          value[key] = newJNull()
        else:
          value[key] = copy(state.jget(key))
      return envelopeOk(value)
    except CatchableError as exc:
      return envelopeErr(errorText(exc))

# ── fetch ─────────────────────────────────────────────────────────────

proc fetchedStatus(status: string): int =
  ## `"404 Not Found"` -> 404, `0` when the shape is unknown.
  let head = status.split(' ')[0]
  try:
    parseInt(head)
  except ValueError:
    0

proc hostFetch(handle: uint64, requestJson: cstring): cstring
    {.cdecl, gcsafe.} =
  ## The plugin's only door to the network: method, URL, headers and body
  ## in; status, headers and body out. No socket, no resolver and no client
  ## library crosses the boundary, so every outbound connection is a call
  ## the host makes and could record or refuse. The client is the port's
  ## one TLS-aware constructor, bounded by `fetchTimeoutMs`.
  {.cast(gcsafe).}:
    try:
      if not liveCall(handle):
        return noLiveCall(handle)
      if not allowed(handle, "fetch"):
        return capabilityDenied(handle, "fetch")
      if requestJson.isNil:
        return envelopeErr("fetch needs a request object")
      var req: JsonNode
      try:
        req = parseJson($requestJson)
      except JsonParsingError as exc:
        return envelopeErr("fetch request is not JSON: " & exc.msg)
      if req.kind != JObject:
        return envelopeErr("fetch request must be a JSON object")
      let url = req.jget("url").getStr()
      if url.len == 0:
        return envelopeErr("fetch needs a url")
      let verb = req.jget("method").getStr("GET").toUpperAscii()
      var httpVerb: HttpMethod
      case verb
      of "GET": httpVerb = HttpGet
      of "POST": httpVerb = HttpPost
      of "PUT": httpVerb = HttpPut
      of "DELETE": httpVerb = HttpDelete
      of "PATCH": httpVerb = HttpPatch
      of "HEAD": httpVerb = HttpHead
      else:
        return envelopeErr("fetch method '" & verb & "' is not supported")
      var headers = newHttpHeaders()
      let headerObj = req.jget("headers")
      if headerObj.kind == JObject:
        for key, value in pairs(headerObj):
          headers.add(key, value.getStr())
      let client = newTlsHttpClient(timeout = fetchTimeoutMs)
      try:
        let resp = client.request(url, httpVerb,
                                 req.jget("body").getStr(""), headers)
        var outHeaders = newJObject()
        for key, value in resp.headers:
          outHeaders[key] = %value
        return envelopeOk(%*{"status": fetchedStatus(resp.status),
                             "headers": outHeaders, "body": resp.body})
      finally:
        client.close()
    except CatchableError as exc:
      return envelopeErr(errorText(exc))

# ── log ───────────────────────────────────────────────────────────────

proc levelName(level: int32): string =
  case level
  of 0: "debug"
  of 1: "info"
  of 2: "warn"
  of 3: "error"
  else: "level " & $level

proc hostLog(handle: uint64, level: int32, message: cstring)
    {.cdecl, gcsafe.} =
  ## A plugin's diagnostics: a stderr line always, plus a `plugin_log` event
  ## on the run's observer when a call is live for `handle`. The observer is
  ## the engine's, already tagged with `node=`, so the trace line names the
  ## node with no bookkeeping here; the waterfall and the receipt are closed
  ## lists and do not show it. No live call (a plugin logging from `init`)
  ## means stderr only: there is no run to attach the line to, and no
  ## observer to call. Never stdout — stdout is the CLI's reply surface.
  ## A nil message is ignored rather than crashed on. No envelope: `log`
  ## answers nothing.
  ##
  ## `{.cast(gcsafe).}` for the same reason as the capability functions: the
  ## process-wide `activeScope` lives on a heap only the wiring touches, from
  ## the thread that installed it.
  if message.isNil:
    return
  let text = $message
  stderr.writeLine("(plugin " & $handle & ") " & levelName(level) & ": " &
                   text)
  {.cast(gcsafe).}:
    if activeScope.isNil or not activeScope.live.hasKey(handle):
      return
    let notify = activeScope.live[handle].notify
    if notify.isNil:
      return
    notify("plugin_log", %*{"level": levelName(level), "message": text})

# ── the tables ────────────────────────────────────────────────────────

proc newHostScope*(client: LlmClient, tools: ToolRegistry): HostScope =
  ## The live host: the client and the tools every plugin call reaches.
  HostScope(client: client, tools: tools,
            live: initTable[uint64, HostCall]())

proc installHostScope*(scope: HostScope) =
  ## Point the six functions at `scope`. The ABI gives them no argument to
  ## find it with, so the process holds one — which is also the number of
  ## host tables a process can own (a library loads once).
  activeScope = scope

proc hostFns*(scope: HostScope): HostFns =
  ## The base table: ABI version plus all six real functions. The contract's
  ## nulls are a narrowing of THIS (`hostFnsFor`), not a second table.
  installHostScope(scope)
  HostFns(abiVersion: pluginAbiVersion,
          llmComplete: hostLlmComplete,
          toolCall: hostToolCall,
          stateKeys: hostStateKeys,
          fetch: hostFetch,
          stringFree: hostStringFree,
          log: hostLog)

proc nullHostFns*(): HostFns =
  ## The step-2 table: version set, every capability null. Kept for the
  ## loader's own tests and for a host that deliberately enables nothing.
  HostFns(abiVersion: pluginAbiVersion)

var keptTables: seq[ref HostFns]
  ## Every table this process built. A plugin keeps the ADDRESS it got in
  ## `init` and calls through it until the process exits, so the cell must
  ## outlive whoever built it: a `Waku` dropped by a gateway restart would
  ## otherwise free the table a live library still points at. One or two
  ## cells per process, never freed — the same rule as the libraries.

proc newHostTable*(client: LlmClient, tools: ToolRegistry): ref HostFns =
  ## The heap cell a `Waku` keeps: a plugin stores the address of
  ## `table[]` in its `init` and reads it until the process exits, so the
  ## table is kept alive here as well as by its owner — ownership by the
  ## `Waku` is what makes it reachable, this list is what makes it safe.
  new(result)
  result[] = hostFns(newHostScope(client, tools))
  keptTables.add(result)

proc hostFnsFor*(base: HostFns, needs: seq[string]): HostFns =
  ## `base` narrowed to `needs`: a capability the declaration did not ask
  ## for is a null pointer — the contract's "not enabled here", which a
  ## plugin must answer `ok:false` to instead of calling. `abiVersion`,
  ## `stringFree` and `log` always stay: plumbing and diagnostics, not
  ## capabilities.
  result = base
  if "llm" notin needs:
    result.llmComplete = nil
  if "tool" notin needs:
    result.toolCall = nil
  if "fetch" notin needs:
    result.fetch = nil
