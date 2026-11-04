# Graph plugins — a Nim node from a dynamic library

**Status:** proposal. No code exists yet. [conventions §2](context/conventions.md#2-how-much-process-a-change-needs)
puts a change to the graph engine in the proposal tier, so this doc asks for a
maintainer's yes before any code.

**Related:** [agent-graphs-design.md](agent-graphs-design.md) (the engine this
extends), [loop-vs-graph.md](loop-vs-graph.md) (when a workflow earns a graph),
[nim-port-design.md](nim-port-design.md) (the port that would load a plugin).

## The problem

Every graph workflow in this repo ships inside the binary. A node is a Nim
procedure or a Python function that the engine already holds a reference to, so
a new workflow means a new release of Waku.

A dynamic library removes that constraint: a person compiles a node in Nim,
leaves the `.so` beside their other plugins, and the engine runs it. The
obstacle is the boundary. Two Nim runtimes in one process break five things.

| What crosses the boundary | Why it breaks |
|---|---|
| A `JsonNode` or a `ref object` | Two garbage collectors own one set of bytes. One side frees memory the other still reads, or neither frees it. |
| A closure | A closure carries the environment it captured. A C function pointer carries no environment, so the call needs a live environment on the far side. |
| An exception | A Nim exception cannot unwind across the C boundary. The host sees a crash or an error it cannot attribute. |
| `LlmClient` and `ToolRegistry` | These are Nim objects with no C representation, so the host cannot hand one over. |
| An ownership hook | `=destroy` and `=copy` live in the producer. The consumer's compiler emits its own. |

The build side adds a sixth cost. Typed bindings from compiler metadata, the
approach binny takes, need a Nim devel compiler with `--genBif` and `nifler`,
and the two sides must then agree on compiler, memory manager, allocator and
target.

## The decision

Nothing a garbage collector owns crosses the boundary, and a plugin asks the
host for capability instead of receiving host objects.

The boundary carries C numbers, C strings and one `uint64` handle that means
"this run". A node's input and output are JSON: the host serializes the keys the
node declared, and the plugin returns a JSON patch to merge. When a plugin needs
the model or a tool, it calls a host function and passes its handle back.

WebAssembly host functions, language servers and MCP servers already use this
contract. It is the standard way to run foreign code without sharing a heap.

A second rule follows from the first: the model call goes through the host. The
host records every host-function call in the run trace and the spend ledger, so
a plugin that brought its own HTTP client would spend money Waku cannot see.

## The contract

### What the plugin exports

Five C functions, all `{.exportc, cdecl, dynlib.}` (`dynlib` is what
makes the symbol dynamic — without it the name stays local and
`symAddr` never sees it).

| Export | Signature | Job |
|---|---|---|
| `waku_plugin_abi_version` | `() -> uint32` | Answers the ABI version. The host refuses a version it does not know. |
| `waku_plugin_init` | `(ptr HostFns) -> int32` | Starts the plugin's runtime, stores the host table, and answers 0 on success. |
| `waku_plugin_describe` | `() -> cstring` | Returns the manifest: the plugin's name and the nodes it provides. |
| `waku_plugin_node_run` | `(node, stateJson: cstring, handle: uint64) -> cstring` | Runs one node and returns the result envelope. |
| `waku_plugin_string_free` | `(cstring)` | Releases a string the plugin returned. |

The manifest lists each node with its kind, its `inKeys`, its `outKey`, and the
capabilities it needs:

```json
{
  "name": "pr_review",
  "abi": 1,
  "nodes": [
    {"name": "summarize_diff", "kind": "tool",
     "inKeys": ["diff"], "outKey": "summary", "needs": ["llm"]}
  ]
}
```

### What the host exports

The host passes one table of function pointers to `waku_plugin_init`. The plugin
stops receiving a capability the person did not enable, because the host leaves
that pointer null.

```nim
type HostFns* = object
  abiVersion*: uint32
  llmComplete*: proc (handle: uint64, requestJson: cstring): cstring {.cdecl.}
  toolCall*: proc (handle: uint64, name, argsJson: cstring): cstring {.cdecl.}
  stateKeys*: proc (handle: uint64, keysJson: cstring): cstring {.cdecl.}
  fetch*: proc (handle: uint64, requestJson: cstring): cstring {.cdecl.}
  stringFree*: proc (value: cstring) {.cdecl.}
  log*: proc (handle: uint64, level: int32, message: cstring) {.cdecl.}
```

Every host function answers a JSON envelope, so the plugin reads one shape:
`{"ok": true, "value": ...}` or `{"ok": false, "error": "..."}`. A `fetch`
request carries the method, the URL, the headers and the body, and the answer
carries the status, the headers and the body.

`fetch` is the plugin's only door to the network. The host hands over no socket,
no resolver and no client library, so every outbound connection is a call the
host makes on the plugin's behalf and a call the host can record and refuse.

### What a node returns

```json
{"ok": true, "patch": {"summary": "Three files move the token refresh into one module."}}
{"ok": true, "route": "quick_reply"}
{"ok": false, "error": "the model call failed: 429"}
```

An `ok` result carries a `patch`, a `route`, or both. An error result is text.
The engine already catches a raising node, writes the message into
`state["errors"]`, and drains the run unless the node names an `on_error` target
(`waku/graph/engine.py:149`), so a plugin that cannot answer turns its node
quiet instead of ending the run.

### Ownership

One rule keeps both heaps honest: whoever allocates a string frees it, through
its own function. The plugin frees what `waku_plugin_node_run` and
`waku_plugin_describe` returned by calling `waku_plugin_string_free`. The host
frees what it returned by calling `HostFns.stringFree`. Neither side ever calls
the other's allocator.

That rule buys a freedom worth naming: the two sides share no memory manager and
no allocator. The Nim port already builds with `-d:useMimalloc`, and a plugin may
use mimalloc, the C allocator or its own pool, because no allocation crosses the
boundary in either direction.

### The two sides in Nim

The producer is ordinary Nim with five exported wrappers:

```nim
proc wakuPluginNodeRun*(node, stateJson: cstring, handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  try:
    result = runNode($node, $stateJson, handle).cstring
  except CatchableError as error:
    result = errorEnvelope(error.msg).cstring
```

The consumer loads the library and reads one symbol out of it:

```nim
let library = loadLib(pluginPath)
let abi = cast[proc (): uint32 {.cdecl, gcsafe.}](library.symAddr("waku_plugin_abi_version"))
```

`runNode` receives the model through the host table. It never touches an
`LlmClient`, a `ToolRegistry` or the live state:

```nim
let answer = $host.llmComplete(handle, request.cstring)
```

### The encoding

Every call in this contract carries JSON. The choice costs a little speed and
buys three things.

- A person reads a plugin's input and output with `jq`.
- Any language can write a plugin, because a Rust, Zig or Python plugin that
  speaks C and JSON is compatible.
- The repo adds no dependency, because `std/json` is already there.

Two families of candidates argue against JSON, and both cost more than they
return here.

- `std/marshal` and NIF are Nim's own binary formats. They are fast and they are
  Nim-native, and both are tied to the Nim version that produced them: `std/marshal`
  encodes Nim's type layout, and NIF is a compiler cache format with no stability
  promise. `std/marshal` also warns that it is unsafe on untrusted input, which a
  plugin boundary is. Either one would make the format, and not only the language,
  Nim's, and a plugin in another language would stop being possible.
- A schema format such as FlatBuffers or Cap'n Proto is fastest for a large fixed
  payload, and graph state is the wrong shape for it: a small dictionary whose
  keys a workflow author picks.

The honest position is to measure first. A node call copies a handful of keys
once, and the model call inside that node takes seconds, so no encoding change is
measurable for a triage or a briefing graph. One case would pay: a node that
moves a large payload, such as a full diff or a document. That case earns a
measurement before it earns a format.

The design keeps the choice reversible. `waku_plugin_describe` already answers a
manifest, so the manifest can carry the encoding a plugin speaks, and a later ABI
can accept a binary encoding beside `json` without a second contract.

## How each problem closes

| Problem from the list above | What closes it |
|---|---|
| Two garbage collectors own one object | The object never crosses. Only strings and numbers cross, and each side allocates and frees its own. |
| A closure carries no environment across a C pointer | No closure crosses. A plugin uses its own closures inside its own runtime. |
| An exception cannot unwind across the boundary | The plugin wraps every node in `try/except` and returns `ok: false` with the message. It compiles with `--panics:off` so a defect is catchable too. |
| `LlmClient` and `ToolRegistry` have no C form | The host passes handles and function pointers instead. The model and the tools stay in the host's heap. |
| Two `=destroy` implementations | The host owns the state, so the host runs the one that matters. |
| A Nim devel toolchain and a matched memory manager | The ABI is C-only. A plugin builds on Nim stable, and the two sides share no memory manager, no allocator and no compiler version. |

The one problem this design does not close is a crash. A native library that
segfaults ends Waku with it, and the design answers that with a trust tier
rather than with the contract.

## The node kinds

A plugin declares four kinds, and each one matches a factory the engine already
has. The difference is where the work runs.

| Kind | Engine factory | What the plugin does | What the host does |
|---|---|---|---|
| `tool` | `tool_node` | Reads its input keys, computes, returns a patch. | Serializes the input keys, merges the patch. |
| `llm` | `llm_node` | Builds the prompt and calls `llmComplete`. | Runs the model, records the call and its cost. |
| `agent` | `agent_node` | Loops over `llmComplete` and `toolCall` until it stops. | Runs every model call and every tool, and records each one. |
| `router` | `key_router` | Reads the state and returns `route`. | Follows the same edge a built-in router would. |

An `agent` node is the payoff for the second rule. The plugin orchestrates a
full turn, and the host still owns the model, the tools, the trace and the
ledger.

The engine's fifth factory, `fn_node`, takes a `NodeFn` — a Nim procedure with
its closure environment. That is exactly the value the boundary refuses, so no
plugin can express `fn_node`. The relationship is clean instead: `fn_node` is
the escape hatch for a function the host already holds, and a plugin node is the
escape hatch for a function the host has never seen.

## How a run uses a plugin

1. Waku loads the library, reads `waku_plugin_abi_version`, and refuses a
   version it does not know.
2. Waku calls `waku_plugin_init` with the host table, with a pointer left null
   for every capability the person did not enable.
3. Waku reads the manifest from `waku_plugin_describe` and registers each node
   as `plugin:<plugin name>/<node name>`.
4. A declarative graph names that node the same way it names a built-in:

```yaml
nodes:
  - name: revisar
    plugin: pr_review
    node: summarize_diff
    in_keys: [diff]
    out_key: summary
```

5. The engine reaches the node, collects the declared keys from the state as
   JSON, and calls `waku_plugin_node_run`.
6. The host merges the patch or follows the route, and frees the returned string
   through `waku_plugin_string_free`.

## What the dashboard shows

A plugin node has to be visible where a built-in node is visible, or the Graph
tab lies about what ran.

The trace already reaches the dashboard. A graph run writes `graph_start`,
`node_start`, `node_end`, `route` and `graph_end` into the same JSONL the
dashboard reads, and `/api/graph/stream` streams those events. The engine
emits them around a plugin call exactly as it does around a built-in one, so a
plugin node appears in a run's path with its duration like any other node.

One thing is missing today. `graphSection` in `nim/src/dashboard.nim` builds its
`workflows` list from `triageTopology()` and `gatherTopology()`, and it hardcodes
that pair, so a plugin's workflow would never appear in the list. Reading the node
registry instead of those two functions is what makes a plugin's workflow show
up, and that change belongs with the loader.

## Trust tiers

The contract above describes calls, not a transport, so a stricter tier adds a
transport instead of a second design.

| Tier | Transport | What it isolates | When |
|---|---|---|---|
| native | The library loads into Waku's process. | Nothing. A plugin reads what the process reads, and its crash ends Waku. | v1 |
| child process | The same calls travel as JSON-RPC over stdio. | The plugin's crash ends the child. | [roadmap.md](roadmap.md) |
| WebAssembly | The same calls become wasm imports. | Memory, syscalls and lifetime, inside a sandbox. | [roadmap.md](roadmap.md) |

The native tier is honest about its own limit: it gives no isolation, so a
plugin is a deliberate act, named in configuration, off by default. That matches
the rule this repo already applies to every capability in
[conventions §3](context/conventions.md#3-where-new-capability-goes-the-footprint-ladder).

## Where binny fits

Binny is optional here, and a plugin author does not need it.

The v1 contract is five C exports and six host functions, so a plugin author
writes those wrappers by hand on Nim stable. Binny earns its place in a different
job: exporting a Nim library's own rich types to another Nim program, with the
ownership hooks and layouts reconstructed for the consumer. The graph boundary
never needs that, because the graph boundary carries JSON.

Binny also supplies a per-library initializer name for the producer's runtime.
The hand-written version calls `NimMain` from `waku_plugin_init`, and Binny's
version is the robust form of the same step.

## What it costs

| Cost | Detail |
|---|---|
| Trust | A native plugin runs with the person's privileges and can read `.waku/`. The design cannot prevent that; it makes the plugin a visible, named decision. |
| Serialization | Every node call copies its declared keys as JSON. Against a model call that takes seconds, this is noise. |
| ABI versioning | The host table is a contract. A new field is a new ABI version, and the host refuses what it does not know. |
| Platform | A plugin builds per platform and per target, so there is no single artifact. |
| No unload | The library stays mapped until the process exits, which keeps finalizers from running while the host still holds a returned string. |

## The smallest version that ships

- The native tier only, in-process.
- The five exports, the six host functions, and the result envelope above.
- Node kinds `tool`, `llm`, `agent` and `router`.
- A manifest that declares capabilities, and an existing switch that gates them,
  off by default.
- `--app:lib --panics:off` for the plugin, which picks its own memory manager and
  its own allocator.
- One plugin call at a time. The Nim port runs a wave's nodes sequentially today,
  so two calls into one plugin never overlap and the plugin needs no lock.
- No unload and no hot reload.

## Decisions taken

**Every outbound connection goes through a host function.** A plugin receives no
socket, and a request travels to the host as `fetch` instead. The rule costs a
plugin nothing it cannot get from `fetch`, and it keeps the run trace and the
spend ledger complete, because the host sees every connection the plugin makes.
A future tier can relax the rule for a plugin that runs in its own process,
where the host could not see the socket anyway.

**The stricter trust tiers wait.** This proposal ships the native tier only. The
child-process transport and the WebAssembly transport stay unscheduled, because
neither is needed to prove the contract and each is a second implementation to
keep honest.

**The plugin contract is Nim-only.** The project is focusing on the Nim port, so
the Python half does not gain a plugin loader. One implementation with no parity
work keeps this contract honest instead of twice-implemented.

## Open decisions

1. **Where does the enable list live?** A `[plugins]` table in the existing
   configuration, or one file per plugin under `.waku/plugins/`.
2. **May a plugin declare a node kind the engine does not know?** A new kind
   would be a plugin-visible contract, and the four above cover every workflow
   in the repo today.
3. **Which encoding crosses the boundary?** See
   [the encoding](#the-encoding) below.

## Not this

- This does not replace the tool registry. A plugin whose only job is to wrap an
  HTTP API is a tool, and tools already have a home.
- This does not let a plugin replace the loop or the engine.
- This does not define the declarative DSL that names a plugin node. That schema
  and its registry of built-in nodes are a sibling proposal; this design only
  says how a node name in a graph reaches a plugin.
- This does not share a live Nim object in either direction, in any tier.
