## Skill Nim template generator — validated SkillGraph → Nim source.
##
## Produces a complete .nim file that compiles to a .so with the plugin
## ABI v1. The LLM never writes Nim — only the JSON manifest changes
## between skills. The generated code mirrors fixture_plugin_textops.nim:
## same HostFns layout, same copy-before-free pattern, same error envelope.
##
## The generated plugin:
## - describe returns the manifest WITHOUT prompt fields (internal only)
## - node_run for llm: interpolates {{key}} placeholders, calls llmComplete
## - node_run for router: returns a route label based on state
## - No tool/fetch references — skills are worker-eligible by design
##
## Router fallback memo (S10): the engine calls the node fn AND THEN the
## route fn for ONE router visit (see `pluginRouter` in graph/plugins.nim),
## so `waku_plugin_node_run` runs twice with the same node name and handle.
## The generated router therefore keeps its chosen fallback label in a
## per-plugin memo keyed by (handle, node), and the second call hands that
## label over instead of paying for a second model call that could also
## disagree with the first. Declarative `when` conditions still run first on
## every call: they are cheap and authoritative. One handle slot bounds the
## memo — handles are monotonic per run, so a different handle is a
## different run and drops what the previous one decided.

import std/json

import ./skillgraph

proc escapeNimString(s: string): string =
  ## Escape a string for embedding in Nim source as a string literal.
  result = "\""
  for c in s:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(c)
  result.add("\"")

proc buildManifestJson(graph: SkillGraph): string =
  ## Build the manifest JSON for waku_plugin_describe.
  ## Excludes prompt fields (internal to node_run, not part of ABI).
  var nodes: seq[JsonNode] = @[]
  for n in graph.nodes:
    var node = %*{
      "name": n.name,
      "kind": n.kind,
      "inKeys": n.inKeys,
      "outKey": n.outKey,
      "needs": n.needs
    }
    if n.kind == "router":
      var routes: seq[JsonNode] = @[]
      for r in n.routes:
        var route = %*{"label": r.label, "dst": r.dst}
        if r.hasWhen:
          let value = if r.condOp in ["len_gt", "len_lt"]: %r.condInt
                      else: %r.condStr
          route["when"] = %*{"key": r.condKey, "op": r.condOp, "value": value}
        routes.add(route)
      node["routes"] = %routes
    nodes.add(node)
  let manifest = %*{
    "name": graph.name,
    "abi": skillAbiVersion,
    "nodes": nodes
  }
  result = $manifest

proc genLlmNode(n: SkillNode, isLast: bool): string =
  ## Generate the case branch for an llm node.
  ## Interpolates {{key}} placeholders from state, calls llmComplete.
  ## The LAST node also writes `reply`: that is the key `pluginRunHeadless`
  ## answers with, so a skill without it would run headless and say nothing.
  result = "  of " & escapeNimString(n.name) & ":\n"
  result.add("    if h.llmComplete.isNil:\n")
  result.add("      return errEnvelope(\"" & n.name & " needs llm: declare needs: [\\\"llm\\\"]\")\n")
  # Build prompt interpolation
  result.add("    var prompt = " & escapeNimString(n.prompt) & "\n")
  # Replace {{key}} with state values
  for key in n.inKeys:
    result.add("    prompt = prompt.replace(\"{{" & key & "}}\", state{" &
      escapeNimString(key) & "}.getStr(\"\"))\n")
  result.add("    let request = %*{\"model\": \"\", \"max_tokens\": 1024,\n")
  result.add("                     \"messages\": [%*{\"role\": \"user\", \"content\": prompt}]}\n")
  result.add("    let answer = readEnvelope(h.llmComplete(handle, ($request).cstring))\n")
  result.add("    if not answer{\"ok\"}.getBool(false):\n")
  result.add("      return errEnvelope(answer{\"error\"}.getStr(\"llmComplete failed\"))\n")
  result.add("    var text = \"\"\n")
  result.add("    for part in answer{\"value\"}{\"content\"}:\n")
  result.add("      if part{\"text\"}.kind == JString:\n")
  result.add("        text.add(part{\"text\"}.getStr(\"\"))\n")
  result.add("    if text.strip().len == 0:\n")
  result.add("      return errEnvelope(\"" & n.name & " got no text from the model\")\n")
  if n.outKey.len > 0:
    if isLast and n.outKey != "reply":
      result.add("    return okPatch(%*{" & escapeNimString(n.outKey) &
        ": text, \"reply\": text})\n")
    else:
      result.add("    return okPatch(%*{" & escapeNimString(n.outKey) & ": text})\n")
  else:
    result.add("    return okPatch(%*{\"reply\": text})\n")

proc routeEnvelope(label: string): string =
  ## The generated "answer this label" line. `okRoute` escapes the label with
  ## `escapeJsonUnquoted`, so a memoized label and a literal one reach the
  ## wire identically.
  "      return okRoute(" & escapeNimString(label) & ")\n"

proc genCondition(r: SkillRoute): string =
  ## The Nim boolean expression for one validated `when` condition.
  let val = "state{" & escapeNimString(r.condKey) & "}.getStr(\"\")"
  case r.condOp
  of "len_gt": val & ".len > " & $r.condInt
  of "len_lt": val & ".len < " & $r.condInt
  of "eq": val & " == " & escapeNimString(r.condStr)
  of "contains": val & ".contains(" & escapeNimString(r.condStr) & ")"
  else: "false"  # unreachable: the validator gates the op catalog

proc genRouterNode(n: SkillNode): string =
  ## Generate the case branch for a router node — the hybrid model:
  ## declarative `when` conditions in declaration order (first match
  ## wins); if none matches, an LLM call picks one declared label and
  ## an answer outside the set is a loud error, never a silent default.
  result = "  of " & escapeNimString(n.name) & ":\n"
  if n.routes.len == 0:
    return result & "    return errEnvelope(\"router has no routes\")\n"
  for r in n.routes:
    if r.hasWhen:
      result.add("    if " & genCondition(r) & ":\n")
      result.add(routeEnvelope(r.label))
  # One fallback decision per (handle, node): this same function runs twice
  # for one router visit (node fn, then route fn), so the second call hands
  # the decision over. Conditions above stay first and authoritative.
  result.add("    if handle == routeMemoHandle and routeMemo.hasKey(" &
    escapeNimString(n.name) & "):\n")
  result.add("      return okRoute(routeMemo[" &
    escapeNimString(n.name) & "])\n")
  # LLM fallback: ask the model to answer exactly one declared label.
  result.add("    if h.llmComplete.isNil:\n")
  result.add("      return errEnvelope(\"" & n.name &
    " needs llm for its fallback route decision\")\n")
  var labelList = ""
  for i, r in n.routes:
    if i > 0: labelList.add(", ")
    labelList.add(r.label)
  result.add("    var choosePrompt = \"You are a routing step. Answer with exactly one of these labels and nothing else: " &
    labelList & ".\\nState:\\n\"\n")
  for key in n.inKeys:
    result.add("    choosePrompt.add(" & escapeNimString(key & ": ") & " & state{" &
      escapeNimString(key) & "}.getStr(\"\") & \"\\n\")\n")
  result.add("    let chooseReq = %*{\"model\": \"\", \"max_tokens\": 32,\n")
  result.add("                       \"messages\": [%*{\"role\": \"user\", \"content\": choosePrompt}]}\n")
  result.add("    let chooseAns = readEnvelope(h.llmComplete(handle, ($chooseReq).cstring))\n")
  result.add("    if not chooseAns{\"ok\"}.getBool(false):\n")
  result.add("      return errEnvelope(chooseAns{\"error\"}.getStr(\"llmComplete failed\"))\n")
  result.add("    var label = \"\"\n")
  result.add("    for part in chooseAns{\"value\"}{\"content\"}:\n")
  result.add("      if part{\"text\"}.kind == JString:\n")
  result.add("        label.add(part{\"text\"}.getStr(\"\"))\n")
  result.add("    label = label.strip()\n")
  result.add("    case label\n")
  for r in n.routes:
    result.add("    of " & escapeNimString(r.label) & ":\n")
    result.add("      rememberRoute(handle, " & escapeNimString(n.name) & ", " &
      escapeNimString(r.label) & ")\n")
    result.add(routeEnvelope(r.label))
  result.add("    else:\n")
  result.add("      return errEnvelope(\"" & n.name &
    " fallback returned unknown route label '\" & label & \"'\")\n")

proc generateSkillNim*(graph: SkillGraph): string =
  ## Generate Nim source for a validated skill graph.
  ## The output compiles with: nim c --app:lib --panics:off -o:<name>.so
  let manifest = buildManifestJson(graph)

  result = """## Auto-generated skill plugin — DO NOT EDIT.
## Generated from skill graph: """ & graph.name & """
## Compile: nim c --app:lib --panics:off -o:""" & graph.name & """.so this_file.nim

import std/json
import std/strutils
import std/tables

var runtimeStarted = false
var hostTable: pointer

var routeMemoHandle: uint64
  ## The run the memo below belongs to. Handles are monotonic per run
  ## (nextHostHandle), so anything older is dead weight.
var routeMemo = initTable[string, string]()
  ## Router fallback decisions for routeMemoHandle only: node name -> label.
  ## The engine calls the node fn AND the route fn for one router visit, so
  ## the fallback is decided once and handed over instead of paid twice.

type
  HostFns = object
    abiVersion: uint32
    llmComplete: proc(handle: uint64,
                      requestJson: cstring): cstring {.cdecl.}
    toolCall: proc(handle: uint64, name,
                   argsJson: cstring): cstring {.cdecl.}
    stateKeys: proc(handle: uint64, keysJson: cstring): cstring {.cdecl.}
    fetch: proc(handle: uint64, requestJson: cstring): cstring {.cdecl.}
    stringFree: proc(value: cstring) {.cdecl.}
    log: proc(handle: uint64, level: int32, message: cstring) {.cdecl.}

proc NimMain() {.importc, cdecl.}

proc host(): ptr HostFns =
  cast[ptr HostFns](hostTable)

proc retText(text: string): cstring =
  let buf = cast[cstring](alloc0(text.len + 1))
  if text.len > 0:
    copyMem(buf, unsafeAddr text[0], text.len)
  return buf

proc errEnvelope(message: string): cstring =
  retText("{\"ok\": false, \"error\": " & escapeJson(message) & "}")

proc okPatch(patch: JsonNode): cstring =
  retText("{\"ok\": true, \"patch\": " & $patch & "}")

proc okRoute(label: string): cstring =
  retText("{\"ok\": true, \"route\": \"" & escapeJsonUnquoted(label) & "\"}")

proc rememberRoute(handle: uint64, node, label: string) =
  ## Keep this run's fallback decision for `node`'s second call. One handle
  ## slot is the bound: a new handle means the previous run is over, so its
  ## decisions are dropped here and the memo never grows across runs.
  if handle != routeMemoHandle:
    routeMemoHandle = handle
    routeMemo.clear()
  routeMemo[node] = label

proc readEnvelope(raw: cstring): JsonNode =
  if raw.isNil:
    raise newException(CatchableError, "host returned nil")
  let text = $raw
  host().stringFree(raw)
  return parseJson(text)

proc runNode(name: string, state: JsonNode, handle: uint64): cstring =
  let h = host()
  if h.isNil:
    return errEnvelope("plugin was never given a host table")
  case name
"""

  for i, n in graph.nodes:
    if n.kind == "llm":
      result.add(genLlmNode(n, i == graph.nodes.len - 1))
    elif n.kind == "router":
      result.add(genRouterNode(n))

  result.add("""  else:
    return errEnvelope("unknown node '" & name & "'")

proc waku_plugin_abi_version(): uint32
    {.exportc: "waku_plugin_abi_version", cdecl, dynlib.} =
  1'u32

proc waku_plugin_init(table: pointer): int32
    {.exportc: "waku_plugin_init", cdecl, dynlib.} =
  if table.isNil:
    return 1
  if not runtimeStarted:
    NimMain()
    runtimeStarted = true
  hostTable = table
  if host().abiVersion != 1'u32:
    return 2
  return 0

proc waku_plugin_describe(): cstring
    {.exportc: "waku_plugin_describe", cdecl, dynlib.} =
  retText(""" & escapeNimString(manifest) & """)

proc waku_plugin_node_run(node, stateJson: cstring,
                          handle: uint64): cstring
    {.exportc: "waku_plugin_node_run", cdecl, dynlib.} =
  try:
    if node.isNil or stateJson.isNil:
      return errEnvelope("node and state must both be strings")
    return runNode($node, parseJson($stateJson), handle)
  except CatchableError as exc:
    return errEnvelope(exc.msg)

proc waku_plugin_string_free(s: cstring)
    {.exportc: "waku_plugin_string_free", cdecl, dynlib.} =
  if not s.isNil:
    dealloc(s)
""")
