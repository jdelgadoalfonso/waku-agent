## Node factories — port of `waku/graph/nodes.py`: the common shapes a graph
## node takes.
##
## Everything is just a NodeFn (snapshot in, keys-to-merge out); these helpers
## build the kinds you actually reach for. The important one is `agentNode`: a
## node that IS a whole loop turn. Graphs don't replace the loop — they arrange
## calls around it, and to it.

import std/json
import std/strutils  # startsWith: `_`-prefixed template fields never fill

import ../loop
import ../tools
import ../wire
import ./engine

proc asText(value: JsonNode): string =
  ## Python's str() for a state value: containers render as JSON (`$`), None
  ## renders as "None" — Python's str(None). Deviation in quoting and spacing
  ## of containers only, the same one wire.nim documents.
  case value.kind
  of JString: result = value.getStr()
  of JNull: result = "None"
  else: result = $value

proc formatTemplate*(templateStr: string, state: JsonNode): string =
  ## Port of `prompt_template.format(**state)`: `{key}` fields fill from
  ## state — underscore-prefixed state keys are excluded exactly like
  ## Python's format dict, so `{_x}` raises KeyError like any unknown
  ## field, even when `_x` is pre-seeded in state. An unknown placeholder
  ## raises before any substitution is used, same as Python. `{{` and `}}`
  ## escape like Python's format; format specs (`{key:>10}`) are not ported
  ## — graph templates are short prompts, not report layouts.
  var outp = ""
  var i = 0
  while i < templateStr.len:
    if templateStr[i] == '{' and i + 1 < templateStr.len and
        templateStr[i + 1] == '{':
      outp.add('{')   # {{ -> {
      inc i, 2
      continue
    if templateStr[i] == '}' and i + 1 < templateStr.len and
        templateStr[i + 1] == '}':
      outp.add('}')   # }} -> }
      inc i, 2
      continue
    if templateStr[i] == '}':
      raise newException(ValueError, "single '}' encountered in prompt template")
    if templateStr[i] != '{':
      outp.add(templateStr[i])
      inc i
      continue
    var close = i + 1  # a {key} field: up to the closing brace
    while close < templateStr.len and templateStr[close] != '}':
      inc close
    if close == templateStr.len:
      raise newException(ValueError, "single '{' encountered in prompt template")
    let field = templateStr[i + 1 ..< close]
    # `_`-prefixed state keys are excluded from the format dict exactly like
    # Python (`if not k.startswith("_")`): `{_x}` is an unknown placeholder
    # even when `_x` is pre-seeded in state.
    let value = if field.startsWith("_"): newJNull()
                else: state.jget(field)
    if value.kind == JNull:
      raise newException(KeyError, "no state key filled '{" & field & "}'")
    outp.add(value.asText())
    i = close + 1
  return outp

proc toolNode*(name: string, fn: proc(args: seq[JsonNode]): JsonNode,
               inKeys: seq[string], outKey: string, kind = "tool",
               maxVisits = 1, onError = ""): Node =
  ## A plain function as a node: reads `inKeys` from state, writes `outKey`.
  ## For DB lookups, file reads, pure computation — anything deterministic.
  ## Python spreads `in_keys` as positional args (`fn(*[state.get(k) ...])`);
  ## Nim passes them as one `seq[JsonNode]` (missing keys read as `JNull`).
  let keys = inKeys

  proc run(state: JsonNode, notify: Observer): JsonNode =
    var args: seq[JsonNode] = @[]
    for k in keys:
      args.add(state.jget(k))
    var outp = newJObject()
    outp[outKey] = fn(args)
    return outp

  newNode(name, run, kind = kind, maxVisits = maxVisits, onError = onError)

proc llmNode*(name: string, promptTemplate: string, outKey: string,
              client: LlmClient, model: string, maxTokens = 600,
              kind = "llm", maxVisits = 1, onError = ""): Node =
  ## ONE model call, no tools: the prompt template is formatted from state,
  ## the reply text lands in `outKey`. For classify / score / rewrite steps.
  ## Control flow never lives here — a router reads what this node wrote.

  proc run(state: JsonNode, notify: Observer): JsonNode =
    let prompt = formatTemplate(promptTemplate, state)
    var req = %*{"model": model, "max_tokens": maxTokens,
                 "messages": @[%*{"role": "user", "content": prompt}]}
    let response = client.create(req)
    let text = textOf(response["content"])
    var outp = newJObject()
    outp[outKey] = %text
    return outp

  newNode(name, run, kind = kind, maxVisits = maxVisits, onError = onError)

proc agentNode*(name: string, outKey: string, client: LlmClient,
                model: string, system: string, tools: ToolRegistry,
                maxIterations = 10, maxTokens = 2048, messageKey = "message",
                taskTags: seq[string] = @[],
                kind = "agent", maxVisits = 1, onError = ""): Node =
  ## A full run_loop turn as one node — the sub-agent story. Same loop, same
  ## tracing (the engine tags its llm/tool events with node=), just a scoped
  ## tool registry and its own working memory. runLoop itself is untouched.
  ## Python keeps the LoopResult object in state; JsonNode is the state
  ## dialect here, so the turn serializes to reply / tool_calls / iterations.
  ## `taskTags` is the per-turn filter signal (mcp-per-turn-filter §4.2),
  ## derived by the builder the same way `runFullTurn` derives it — the
  ## turn's message against mcp.json's `tasks`/`when` declarations — and
  ## handed to the node like any other input. Empty means allow-by-default:
  ## the full set (§4.4).

  proc run(state: JsonNode, notify: Observer): JsonNode =
    var messages = @[%*{"role": "user", "content": state[messageKey]}]
    let turn = runLoop(client, model, system, messages, tools,
                       maxIterations, maxTokens, notify,
                       taskTags = taskTags)
    var outp = newJObject()
    outp[outKey] = %*{"reply": turn.reply, "tool_calls": %turn.toolCalls,
                      "iterations": turn.iterations}
    return outp

  newNode(name, run, kind = kind, maxVisits = maxVisits, onError = onError)

proc keyRouter*(key: string, default: string): RouteFn =
  ## The house router: read one state key, return it as the route label
  ## (falling back to `default` when the key is missing, empty, or not a
  ## string). Models write the key; this code reads it.
  result = proc(state: JsonNode): string =
    let value = state.jget(key)
    if value.kind == JString and value.getStr().len > 0:
      return value.getStr()
    return default

proc fnNode*(name: string, fn: NodeFn, kind = "fn", maxVisits = 1,
             onError = ""): Node =
  ## Escape hatch: any (state, notify) -> keys-to-merge as a node, unwrapped.
  newNode(name, fn, kind = kind, maxVisits = maxVisits, onError = onError)
