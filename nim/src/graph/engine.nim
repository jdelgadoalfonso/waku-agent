## THE GRAPH — port of `waku/graph/engine.py`: nodes, edges, waves. This file
## is the whole mechanism.
##
## A graph workflow is a map of steps: each node does one job, each edge says
## "when this finishes, go there". The engine runs it in waves:
##
##     while some nodes are ready:
##         run every ready node (Python: concurrently; here: in order)
##         merge what they wrote into the shared state
##         fire their edges / ask their routers where to go next
##
## That's it. Three ideas carry everything:
##
##   state    one JSON object (the blackboard). Every node reads a snapshot
##            of it and returns the keys it wants to merge. Nodes in one wave
##            must write DISJOINT keys — a collision raises
##            GraphStateCollision instead of silently losing a write.
##   routers  plain functions over state. Models write state; code reads it
##            and picks the edge. No LLM ever decides control flow directly.
##   guards   the loop's two-guardrail pattern, generalized: per-node
##            maxVisits (bounded cycles) + global maxSteps (never spin
##            forever). A node exception is recorded in `state["errors"]`
##            and surfaced, never raised out of the run — same
##            surface-don't-crash rule as ToolRegistry.execute.
##
## Waves trade a little pipelining for a lot of legibility: execution order
## is deterministic, so traces read the same way twice and evals can pin the
## path. FOUR DIVERGENCES FROM PYTHON, all mechanical:
##
## - Python runs multi-node waves on a ThreadPoolExecutor and merges results
##   in wave order; Nim runs the wave sequentially in that same order, so
##   offline traces and evals pin the same path. Every node_start still fires
##   before the wave runs, so the trace shape is identical.
## - Python rides the observer through the state dict as `_notify`; JSON
##   can't hold a closure, so every node fn takes it as a second argument
##   (the engine passes it tagged with `node=`), and `_`-prefixed output
##   keys still never merge.
## - Python wraps the observer in a threading.Lock because pool threads share
##   the tracer's file append; Nim runs waves sequentially, so there is no
##   lock.
## - A jump to START or an unknown node is skipped silently and the run
##   drains to END — the surface-don't-crash rule again; Python raises
##   KeyError on the lookup.

import std/json
import std/monotimes
import std/strutils
import std/tables
import std/times  # inMilliseconds: monotimes' `-` returns a times.Duration

import ../loop

export Observer

const
  START* = "START"
  END* = "END"

type
  NodeFn* = proc(state: JsonNode, notify: Observer): JsonNode {.closure.}
    ## Reads a snapshot of the state, returns the keys to merge. `notify` is
    ## the engine's observer tagged with `node=` (agentNode passes it through
    ## to run_loop's events); JSON state can't hold a closure, so Python's
    ## `_notify` dict entry rides here as an argument instead.

  RouteFn* = proc(state: JsonNode): string {.closure.}
    ## Reads the state, returns a target label.

  GraphStateCollision* = object of CatchableError
    ## Two nodes in the same wave wrote the same key — a graph bug, not a
    ## race.

  Node* = ref object
    name*: string
    fn*: NodeFn
    kind*: string       ## tool / llm / agent / router label for describe()
    maxVisits*: int     ## >1 only on nodes inside an intended cycle
    onError*: string    ## node to jump to if fn raises ("" = drain to END)

  Router* = ref object
    src*: string        ## the node this router lives on
    route*: RouteFn
    targets*: seq[tuple[label, dst: string]]  ## ordered label -> target

  Graph* = ref object
    name*: string
    nodes*: seq[Node]   ## insertion order (Python's dict keeps it too)
    edges*: seq[tuple[src, dst: string]]
    routers*: seq[Router]  ## insertion order, one router per node

proc newNode*(name: string, fn: NodeFn, kind = "fn", maxVisits = 1,
              onError = ""): Node =
  ## Python's dataclass defaults live here: kind="fn", max_visits=1,
  ## on_error="" ("" drains to END). Build nodes through this — a raw
  ## `Node(name: ..., fn: ...)` object leaves maxVisits at 0 and the engine
  ## would skip the node as already past its budget.
  Node(name: name, fn: fn, kind: kind, maxVisits: maxVisits, onError: onError)

proc node*(g: Graph, name: string): Node =
  ## Lookup by name; nil when absent. (Python indexes `graph.nodes` by name;
  ## here a graph is a seq of nodes, so this is the read.)
  for n in g.nodes:
    if n.name == name:
      return n

proc indexOf(g: Graph, name: string): int =
  ## Position of `name` in the graph's node list; -1 when absent. Private:
  ## run bookkeeping (deps/fired/runs) is indexed by node position.
  for i in 0 ..< g.nodes.len:
    if g.nodes[i].name == name:
      return i
  return -1

proc addNode*(g: Graph, node: Node) =
  ## Add (or replace by name) one node. START and END are reserved.
  if node.name == START or node.name == END:
    raise newException(ValueError, "'" & node.name & "' is reserved")
  for i in 0 ..< g.nodes.len:
    if g.nodes[i].name == node.name:
      g.nodes[i] = node
      return
  g.nodes.add(node)

proc addEdge*(g: Graph, src, dst: string) =
  ## Unconditional: when src finishes, dst gets one step closer to ready.
  ## Add nodes before edges — unknown endpoints fail here, not mid-run.
  for endp in [src, dst]:
    if endp != START and endp != END and g.node(endp).isNil:
      raise newException(ValueError, "unknown node '" & endp & "'")
  g.edges.add((src, dst))

proc addRouter*(g: Graph, src: string, route: RouteFn,
                targets: seq[tuple[label, dst: string]]) =
  ## Conditional: when src finishes, `route(state)` returns a label and
  ## execution jumps to targets[label]. Routers are code, never models.
  if g.node(src).isNil:
    raise newException(ValueError, "unknown node '" & src & "'")
  for t in targets:
    if t.dst != END and g.node(t.dst).isNil:
      raise newException(ValueError,
        "router target '" & t.dst & "' (label '" & t.label & "') is unknown")
  for i in 0 ..< g.routers.len:  # one router per node (Python's dict slot)
    if g.routers[i].src == src:
      g.routers[i] = Router(src: src, route: route, targets: targets)
      return
  g.routers.add(Router(src: src, route: route, targets: targets))

proc routerFor*(g: Graph, src: string): Router =
  ## The router living on `src`; nil when there is none. (Python: `src in
  ## graph.routers`.)
  for r in g.routers:
    if r.src == src:
      return r

proc nodeNames(g: Graph): seq[string] =
  ## Insertion-ordered node names (Python's `list(graph.nodes)`).
  for n in g.nodes:
    result.add(n.name)

proc describe*(g: Graph): JsonNode =
  ## The topology as data — what the dashboard draws. Rendering from this
  ## (never from a hand-copied picture) is what keeps the chart honest.
  var edges = newJArray()
  for e in g.edges:
    edges.add(%*{"src": e.src, "dst": e.dst, "conditional": false})
  for r in g.routers:
    var seen: seq[string] = @[]  # one conditional edge per distinct target
    for t in r.targets:
      if t.dst in seen:
        continue
      seen.add(t.dst)
      edges.add(%*{"src": r.src, "dst": t.dst, "conditional": true})
  var nodes = newJArray()
  for n in g.nodes:
    nodes.add(%*{"name": n.name, "kind": n.kind})
  result = %*{"name": g.name, "nodes": nodes, "edges": edges}

type
  NodeRun = object
    ## What one node run produced (Python's run_one tuple): the keys it wants
    ## merged, its error text, its duration in milliseconds.
    node: string
    merge: JsonNode
    error: string
    ms: int

proc allFired(deps, fired: seq[string]): bool =
  ## True when every static in-edge of one node has fired (Python's
  ## `deps[n] <= fired[n]`).
  for d in deps:
    if d notin fired:
      return false
  return true

proc runOne(g: Graph, name: string, state: JsonNode, notify: Observer): NodeRun =
  ## Run one node against a snapshot of the state. A node exception is
  ## surfaced as `error_text`, never raised out of the run — this string is
  ## shown to whoever ran the workflow, and a provider that refused the call
  ## already wrote a sentence for them ("Free tier used up. Add your own key
  ## in Models."); repr() would hand them `Refused('Free tier used up...')`
  ## instead, and with a real SDK error it drags the raw JSON error body onto
  ## the screen too. Snapshot depth: std/json's `copy` is a deep copy;
  ## Python's `dict(state)` is shallow — invisible to nodes that only read,
  ## which is the contract.
  result.node = name
  let node = g.node(name)  # the wave only holds known nodes, so never nil
  let snapshot = copy(state)  # Python's `dict(state)` — nodes read, never write
  let t0 = getMonoTime()
  var tagged: Observer = nil
  if not notify.isNil:
    tagged = proc(kind: string, ev: JsonNode) =
      if ev.kind != JObject:
        # Python's `{**ev, ...}` raises TypeError on a non-mapping, which the
        # run_one wrapper surfaces; a Nim assert would crash out of the run.
        raise newException(CatchableError,
          "node event must be an object to carry node=" & name)
      var passed = copy(ev)   # Python's `{**ev, "node": _n}` — a new event
      passed["node"] = %name  # passthrough: agentNode's llm/tool events
      notify(kind, passed)
  try:
    let outp = node.fn(snapshot, tagged)
    # `out or {}`: a node that returns nothing merges nothing. Python would
    # crash iterating a string's characters; the port refuses the bug.
    result.merge = if outp.isNil or outp.kind != JObject: newJObject() else: outp
    result.ms = int((getMonoTime() - t0).inMilliseconds)
  except CatchableError as exc:
    result.error = errorText(exc)
    # an errored node merges nothing — Python's `out or {}` with `out = None`
    result.merge = newJObject()
    result.ms = int((getMonoTime() - t0).inMilliseconds)

proc nextWave(g: Graph, jumps: seq[string], deps, fired: seq[seq[string]],
              runs: var seq[int], errors: JsonNode): seq[string] =
  ## Forcible router/error jumps first, then nodes whose static deps have all
  ## fired (insertion order). A candidate past its visit budget records
  ## `max_visits` in `errors` — once, like Python's `setdefault` — and is
  ## skipped, never crash. A jump to an unknown node is skipped too: the run
  ## drains to END (Python would crash on the lookup).
  var candidates: seq[string] = @[]
  for j in jumps:
    candidates.add(j)
  for i in 0 ..< g.nodes.len:
    if deps[i].len > 0 and allFired(deps[i], fired[i]) and runs[i] == 0:
      candidates.add(g.nodes[i].name)
  for name in candidates:
    if name == END or name in result:
      continue
    let idx = g.indexOf(name)
    if idx < 0:
      continue
    if runs[idx] >= g.nodes[idx].maxVisits:
      if not errors.hasKey(name):
        errors[name] = %("max_visits=" & $g.nodes[idx].maxVisits & " reached")
      continue
    result.add(name)

proc runGraph*(g: Graph, state: var JsonNode, observer: Observer = nil,
               maxSteps = 25): JsonNode =
  ## Run one graph workflow to completion. Port of `run_graph`: the final
  ## state is `state` (mutated in place, also returned for chaining); errors
  ## land in `state["errors"]` and the graph_end event — they are never
  ## raised. Pre-seeded error entries survive the run; a malformed `errors`
  ## entry is replaced, not trusted. A state that is not a JSON object starts
  ## as an empty one (Python's `dict` default; Python itself would crash on a
  ## non-dict).
  let notify: Observer = if observer.isNil:
    proc(kind: string, ev: JsonNode) = discard
  else:
    observer
  var errors: JsonNode
  if state.kind != JObject:
    state = newJObject()
  if not state.hasKey("errors") or state["errors"].kind != JObject:
    state["errors"] = newJObject()
  errors = state["errors"]

  # Static in-edges per node (by node position): an edge into END starts no
  # wave — it only marks the graph's drain. Unknown endpoints are inert,
  # exactly like Python's defaultdict entries for nodes that don't exist.
  var deps: seq[seq[string]] = @[]
  var fired: seq[seq[string]] = @[]
  var runs: seq[int] = @[]
  for n in g.nodes:
    deps.add(@[])
    fired.add(@[])
    runs.add(0)
  for e in g.edges:
    if e.dst != END:
      let di = g.indexOf(e.dst)
      if di >= 0:
        deps[di].add(e.src)

  var path: seq[string] = @[]
  let t0 = getMonoTime()
  notify("graph_start", %*{"workflow": g.name, "nodes": nodeNames(g)})

  for e in g.edges:  # START fires its edges before the first wave
    if e.src == START:
      let di = g.indexOf(e.dst)
      if di >= 0:
        fired[di].add(START)

  var wave = nextWave(g, @[], deps, fired, runs, errors)

  while wave.len > 0:
    if path.len + wave.len > maxSteps:
      if not errors.hasKey("engine"):
        errors["engine"] = %("max_steps=" & $maxSteps & " reached")
      break
    for name in wave:  # every node_start fires before the wave runs
      let idx = g.indexOf(name)
      inc runs[idx]
      let visit = runs[idx]
      notify("node_start", %*{"workflow": g.name, "node": name, "visit": visit})
    var results: seq[NodeRun] = @[]
    for name in wave:  # sequential: Python's ThreadPoolExecutor, same order
      results.add(runOne(g, name, state, notify))

    var jumps: seq[string] = @[]
    var waveWrites = initTable[string, string]()
    for r in results:  # merge in wave order — deterministic
      path.add(r.node)
      var keys: seq[string] = @[]  # private keys never merge
      for key, _ in pairs(r.merge):
        if not key.startsWith("_"):
          keys.add(key)
      for key in keys:
        if waveWrites.hasKey(key) and waveWrites[key] != r.node:
          raise newException(GraphStateCollision,
            "'" & r.node & "' and '" & waveWrites[key] & "' both wrote '" &
            key & "' — parallel branches must write disjoint keys")
        waveWrites[key] = r.node
        state[key] = r.merge[key]
      notify("node_end", %*{"workflow": g.name, "node": r.node, "ms": r.ms,
                            "keys": keys,
                            "error": (if r.error.len > 0: %r.error
                                      else: newJNull())})
      if r.error.len > 0:
        errors[r.node] = %r.error
        let onError = g.node(r.node).onError
        if onError.len > 0:
          jumps.add(onError)
        continue  # no on_error → fire nothing; the run drains to END
      let router = g.routerFor(r.node)
      if not router.isNil:
        let label = router.route(state)
        var target = ""
        var found = false
        for t in router.targets:
          if t.label == label:
            target = t.dst
            found = true
            break
        var routeEv = newJObject()
        routeEv["workflow"] = %g.name
        routeEv["router"] = %r.node
        routeEv["target"] = (if found: %target else: %END)
        routeEv["reason"] = %label
        notify("route", routeEv)
        if not found:
          errors[r.node] = %("router returned unknown label '" & label & "'")
        elif target != END:
          jumps.add(target)  # a route is a jump, not a dependency
      else:
        for e in g.edges:
          if e.src == r.node and e.dst != END:
            let di = g.indexOf(e.dst)
            if di >= 0 and r.node notin fired[di]:
              fired[di].add(r.node)
    wave = nextWave(g, jumps, deps, fired, runs, errors)

  var firstError = newJNull()
  for _, value in pairs(errors):  # insertion order: Python's values() order
    firstError = value
    break
  notify("graph_end", %*{"workflow": g.name,
                         "ms": int((getMonoTime() - t0).inMilliseconds),
                         "steps": path.len, "path": path, "error": firstError})
  return state
