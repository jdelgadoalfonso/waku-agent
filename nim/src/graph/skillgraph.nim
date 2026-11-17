## Skill graph validator — the security boundary before compilation.
##
## Validates the restricted plugin manifest subset that skills may use:
## kinds llm+router only, needs ⊆ {llm}, prompt strings, DAG reachable
## from the first node. The LLM proposes the graph; this module decides
## whether it is safe to compile.
##
## Reuses the plugin manifest schema (ABI v1) but restricts it:
## - Only `llm` and `router` kinds (no tool/agent → worker-eligible).
## - needs ⊆ {llm} (no tool/fetch effects).
## - llm nodes carry a `prompt` string with {{key}} placeholders.
## - Routes validated against manifest nodes; END allowed.
## - Graph must be a DAG reachable from the first node.
## - Data flow: every {{key}} in a prompt is a declared inKey, and every
##   inKey is written by an earlier node or is input state (S9). Structure
##   alone is not enough — a mistyped key must fail here, not interpolate
##   an empty string at runtime.
## - Answerability: the run must produce `reply`, the key
##   `pluginRunHeadless` answers with (S18). A graph that can never answer
##   would compile, install and then fall back to text on every turn; it is
##   refused here instead.
##
## Edge model: llm nodes flow implicitly to the next declared node;
## router nodes branch ONLY to their route destinations (no implicit
## next). This makes linear chains work naturally while keeping
## branching explicit and verifiable.

import std/json
import std/strutils
import std/tables

import ../wire  # jget

const
  skillAbiVersion* = 1
  ## Same ABI as plugins — skills compile to the same .so format.

  allowedKinds = @["llm", "router"]
  ## Skills may only declare these kinds. tool/agent are forbidden
  ## because they carry parent-side effects that break worker isolation.

  allowedNeeds = @["llm"]
  ## The only need a skill node may declare. tool/fetch are forbidden.

  intOps = @["len_gt", "len_lt"]
  ## Condition operators whose value must be an integer.

  strOps = @["eq", "contains"]
  ## Condition operators whose value must be a string.

  inputStateKeys = @["message", "mem_text"]
  ## State keys every skill run provides, so a node may read them without
  ## an earlier node writing them.

type
  SkillGraphError* = object of CatchableError
    ## Raised when a skill graph fails validation.

  SkillRoute* = object
    ## One validated route. `hasWhen` false means the route carries no
    ## condition — in the hybrid model the LAST unconditional route is
    ## still reached only through the LLM fallback, never by default.
    label*: string
    dst*: string
    hasWhen*: bool
    condKey*: string
    condOp*: string
    condInt*: int
    condStr*: string

  SkillNode* = object
    name*: string
    kind*: string
    inKeys*: seq[string]
    outKey*: string
    needs*: seq[string]
    prompt*: string
    routes*: seq[SkillRoute]

  SkillGraph* = object
    name*: string
    nodes*: seq[SkillNode]

proc strSeq(node: JsonNode, key: string): seq[string] =
  ## A string array, or @[] when absent. Non-string entries fail.
  let arr = node.jget(key)
  if arr.kind == JNull:
    return @[]
  if arr.kind != JArray:
    raise newException(SkillGraphError,
      "skill graph key '" & key & "' must be an array of strings")
  for item in items(arr):
    if item.kind != JString:
      raise newException(SkillGraphError,
        "skill graph key '" & key & "' must be an array of strings")
    result.add(item.getStr())

proc parseWhen(item: JsonNode, nodeName, label: string): SkillRoute =
  ## Validate the optional `when` condition of one route: an object
  ## {key, op, value} with op in the closed catalog and the value type
  ## the op demands. Absent `when` leaves hasWhen false.
  let w = item.jget("when")
  if w.kind == JNull:
    return
  if w.kind != JObject:
    raise newException(SkillGraphError,
      "skill graph node '" & nodeName & "': route '" & label &
      "' when must be an object with key, op and value")
  let key = w.jget("key")
  if key.kind != JString or key.getStr().len == 0:
    raise newException(SkillGraphError,
      "skill graph node '" & nodeName & "': route '" & label &
      "' when needs a non-empty key string")
  let op = w.jget("op")
  if op.kind != JString or
      (op.getStr() notin intOps and op.getStr() notin strOps):
    raise newException(SkillGraphError,
      "skill graph node '" & nodeName & "': route '" & label &
      "' when op must be one of len_gt, len_lt, eq, contains")
  let value = w.jget("value")
  result.hasWhen = true
  result.condKey = key.getStr()
  result.condOp = op.getStr()
  if op.getStr() in intOps:
    if value.kind != JInt:
      raise newException(SkillGraphError,
        "skill graph node '" & nodeName & "': route '" & label &
        "' when op '" & op.getStr() & "' needs an integer value")
    result.condInt = value.getInt()
  else:
    if value.kind != JString:
      raise newException(SkillGraphError,
        "skill graph node '" & nodeName & "': route '" & label &
        "' when op '" & op.getStr() & "' needs a string value")
    result.condStr = value.getStr()

proc parseRoutes(def: JsonNode, nodeName: string,
                 nodeNames: seq[string]): seq[SkillRoute] =
  ## Validate routes: array of {label, dst, when?}, labels unique,
  ## dst ∈ {END, manifest nodes}, conditions from the closed catalog.
  let arr = def.jget("routes")
  if arr.kind == JNull or arr.kind != JArray or arr.len == 0:
    raise newException(SkillGraphError,
      "skill graph node '" & nodeName & "': router needs a non-empty routes array")
  for item in items(arr):
    if item.kind != JObject:
      raise newException(SkillGraphError,
        "skill graph node '" & nodeName & "': every route must be an object with label and dst")
    let label = item.jget("label")
    let dst = item.jget("dst")
    if label.kind != JString or label.getStr().len == 0:
      raise newException(SkillGraphError,
        "skill graph node '" & nodeName & "': every route needs a non-empty label string")
    if dst.kind != JString or dst.getStr().len == 0:
      raise newException(SkillGraphError,
        "skill graph node '" & nodeName & "': route '" & label.getStr() & "' needs a non-empty dst string")
    if dst.getStr() != "END" and dst.getStr() notin nodeNames:
      raise newException(SkillGraphError,
        "skill graph node '" & nodeName & "': route '" & label.getStr() & "' names unknown node '" & dst.getStr() & "'")
    for seen in result:
      if seen.label == label.getStr():
        raise newException(SkillGraphError,
          "skill graph node '" & nodeName & "': duplicate route label '" & label.getStr() & "'")
    var route = parseWhen(item, nodeName, label.getStr())
    route.label = label.getStr()
    route.dst = dst.getStr()
    result.add(route)

proc buildAdjacency(nodes: seq[SkillNode]): Table[string, seq[string]] =
  ## The one edge model: llm → next declared node (implicit linear flow);
  ## router → route destinations only (no implicit next).
  for n in nodes:
    result[n.name] = @[]
  for i, n in nodes:
    if n.kind == "router":
      for r in n.routes:
        if r.dst != "END":
          result[n.name].add(r.dst)
    elif i < nodes.len - 1:
      # llm flows implicitly to next declared node
      result[n.name].add(nodes[i + 1].name)

proc promptPlaceholders(prompt: string): seq[string] =
  ## Closed `{{key}}` placeholders in a prompt, in order of appearance,
  ## without duplicates. An unclosed `{{` is not a placeholder any
  ## interpolation step would fill, so it is left alone.
  var i = 0
  while true:
    let open = prompt.find("{{", i)
    if open < 0:
      break
    let close = prompt.find("}}", open + 2)
    if close < 0:
      break
    let key = prompt[open + 2 ..< close]
    if key notin result:
      result.add(key)
    i = close + 2

proc checkDataFlow(nodes: seq[SkillNode]) =
  ## S9: keys must actually flow. Every declared inKey needs a writer —
  ## an earlier node under the same edge model as checkDag, or input
  ## state — and every prompt placeholder must be declared. Reading a key
  ## from a sibling branch is rejected: that branch may never run, so the
  ## value is not guaranteed to exist when this node runs.
  let adj = buildAdjacency(nodes)

  # `earlier[name]` = keys a strictly upstream node writes (non-empty outKey).
  var earlier: Table[string, seq[string]]
  for n in nodes:
    earlier[n.name] = @[]
  for producer in nodes:
    if producer.outKey.len == 0:
      continue
    var seen: Table[string, bool]
    var stack: seq[string] = @[]
    for dst in adj[producer.name]:
      stack.add(dst)
    while stack.len > 0:
      let cur = stack.pop()
      if cur in seen:
        continue
      seen[cur] = true
      if producer.outKey notin earlier[cur]:
        earlier[cur].add(producer.outKey)
      for dst in adj[cur]:
        stack.add(dst)

  for n in nodes:
    if n.kind == "llm":
      for key in promptPlaceholders(n.prompt):
        if key notin n.inKeys:
          raise newException(SkillGraphError,
            "skill graph node '" & n.name & "': prompt placeholder '{{" &
            key & "}}' is not one of its inKeys")
    for key in n.inKeys:
      if key in inputStateKeys or key in earlier[n.name]:
        continue
      raise newException(SkillGraphError,
        "skill graph node '" & n.name & "': inKey '" & key &
        "' is neither produced by an earlier node nor an input state key")

proc checkCanAnswer(nodes: seq[SkillNode]) =
  ## S18: the run must have a way to answer. `pluginRunHeadless` answers
  ## `state["reply"]`, and the generator writes that key in exactly two
  ## shapes: for the LAST declared node when it is an llm node, and for any
  ## llm node that declares `outKey: "reply"` itself. A graph whose last
  ## declared node is a router writes neither, so the skill would validate,
  ## compile, install and answer nothing on every turn — the loop would
  ## silently fall back to text forever. Refuse it at the boundary instead.
  let last = nodes[^1]
  if last.kind == "llm":
    return
  for n in nodes:
    if n.kind == "llm" and n.outKey == "reply":
      return
  raise newException(SkillGraphError,
    "skill graph last declared node '" & last.name & "' is a router and no llm " &
    "node declares outKey \"reply\", so the compiled skill would answer " &
    "nothing: end the graph with an llm node or give an llm node outKey \"reply\"")

proc checkDag(nodes: seq[SkillNode]) =
  ## Verify the graph is a DAG reachable from the first node, using the
  ## shared edge model (see buildAdjacency).
  let adj = buildAdjacency(nodes)

  # DFS from first node, detect cycles and collect reachable
  var visited: Table[string, bool]  # false = in stack, true = done
  var reachable: seq[string]

  proc dfs(name: string) =
    if name in visited:
      if not visited[name]:
        raise newException(SkillGraphError,
          "skill graph has a cycle at node '" & name & "'")
      return
    visited[name] = false
    reachable.add(name)
    for dst in adj[name]:
      dfs(dst)
    visited[name] = true

  dfs(nodes[0].name)

  # Every node must be reachable
  for n in nodes:
    if n.name notin reachable:
      raise newException(SkillGraphError,
        "skill graph node '" & n.name & "' is unreachable from the first node")

proc validateSkillGraph*(manifest: JsonNode): SkillGraph =
  ## Validate a skill graph manifest. Raises SkillGraphError on any
  ## violation. Returns the parsed graph on success.
  if manifest.kind != JObject:
    raise newException(SkillGraphError, "skill graph manifest must be a JSON object")

  let name = manifest.jget("name")
  if name.kind != JString or name.getStr().len == 0:
    raise newException(SkillGraphError, "skill graph needs a non-empty name")

  let abi = manifest.jget("abi")
  if abi.kind != JInt or abi.getInt() != skillAbiVersion:
    raise newException(SkillGraphError,
      "skill graph abi must be " & $skillAbiVersion)

  let defs = manifest.jget("nodes")
  if defs.kind != JArray or defs.len == 0:
    raise newException(SkillGraphError, "skill graph needs a non-empty nodes array")

  # First pass: collect all node names (routes may reference later nodes)
  var nodeNames: seq[string] = @[]
  for def in items(defs):
    if def.kind != JObject:
      raise newException(SkillGraphError, "skill graph node must be a JSON object")
    let n = def.jget("name")
    if n.kind != JString or n.getStr().len == 0:
      raise newException(SkillGraphError, "skill graph node needs a non-empty name")
    if n.getStr() in nodeNames:
      raise newException(SkillGraphError,
        "skill graph has duplicate node name '" & n.getStr() & "'")
    nodeNames.add(n.getStr())

  # Second pass: parse and validate each node
  var nodes: seq[SkillNode] = @[]
  for def in items(defs):
    let n = def.jget("name").getStr()
    let k = def.jget("kind")
    if k.kind != JString or k.getStr() notin allowedKinds:
      raise newException(SkillGraphError,
        "skill graph node '" & n & "' has forbidden kind '" &
        k.getStr("") & "' (only llm and router allowed)")

    let needs = strSeq(def, "needs")
    for need in needs:
      if need notin allowedNeeds:
        raise newException(SkillGraphError,
          "skill graph node '" & n & "' has forbidden need '" & need & "'")
    if k.getStr() == "router" and "llm" notin needs:
      raise newException(SkillGraphError,
        "skill graph router '" & n &
        "' must declare needs [\"llm\"]: its fallback route decision is an LLM call")

    var prompt = ""
    if k.getStr() == "llm":
      let p = def.jget("prompt")
      if p.kind != JString:
        raise newException(SkillGraphError,
          "skill graph llm node '" & n & "' needs a string prompt")
      prompt = p.getStr()

    var routes: seq[SkillRoute] = @[]
    if k.getStr() == "router":
      routes = parseRoutes(def, n, nodeNames)

    nodes.add(SkillNode(
      name: n,
      kind: k.getStr(),
      inKeys: strSeq(def, "inKeys"),
      outKey: def.jget("outKey").getStr(""),
      needs: needs,
      prompt: prompt,
      routes: routes
    ))

  checkDag(nodes)
  checkDataFlow(nodes)
  checkCanAnswer(nodes)

  result = SkillGraph(name: name.getStr(), nodes: nodes)
