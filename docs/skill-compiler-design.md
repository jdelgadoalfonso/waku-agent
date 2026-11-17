# Skill compiler — a skill that runs as a plugin

**Status:** implemented 2026-11-17 on `feat/skill-compiler`. The validator, the
fixed Nim template, the child compiler, the content cache, the install step, the
dashboard's two authoring actions and the loop's installed-plugin path ship in
`nim/`. "Known gaps" lists what does not work yet.

**Related:** [graph-plugins-design.md](graph-plugins-design.md) (the C boundary
and the host functions a compiled skill calls),
[plugin-workers-design.md](plugin-workers-design.md) (the eligibility gate that
lets a compiled skill run headless),
[agent-graphs-design.md](agent-graphs-design.md) (the engine that executes the
graph), [loop-vs-graph.md](loop-vs-graph.md) (when a turn needs a graph),
[architecture.md](architecture.md) (which box this stage is).

## A skill stops being only prompt text

The skill compiler turns a skill's procedure into a plugin. A human approves a
graph, the graph compiles once, and a matching turn runs that plugin headless
instead of the loop.

Today a skill is prompt text. `matchingSkills` (`nim/src/memory_live.nim`) copies
a matched skill's body into the system prompt, and the model reads the procedure
and decides its steps on every matching turn, so two turns can take different
steps from the same skill.

The graph fixes the steps in code, and the model answers only the prompts the
graph names. A skill with no installed plugin keeps today's behaviour byte for
byte: its body reaches the system prompt, and the loop answers the turn.

## What a skill graph is

A skill graph is a JSON manifest in the plugin schema (ABI 1), restricted to two
node kinds. The manifest names its nodes; the edges follow from the kinds. An
`llm` node flows to the next declared node, and a `router` node flows only along
its `routes`, so a linear chain declares no edges and a branch states its own.
The engine builds the same topology from the manifest
(`buildPluginGraph` in `nim/src/graph/plugins.nim`): it chains the nodes in
order, a router ends the chain, and every node after a router is a jump target.

```json
{
  "name": "swim_plan",
  "abi": 1,
  "nodes": [
    {"name": "outline", "kind": "llm", "inKeys": ["message"],
     "outKey": "outline", "needs": ["llm"],
     "prompt": "Outline a swim plan for: {{message}}"},
    {"name": "pick_route", "kind": "router", "inKeys": ["outline"],
     "outKey": "", "needs": ["llm"],
     "routes": [
       {"label": "short", "dst": "END",
        "when": {"key": "outline", "op": "len_lt", "value": 400}},
       {"label": "long", "dst": "expand"}
     ]},
    {"name": "expand", "kind": "llm", "inKeys": ["outline"],
     "outKey": "", "needs": ["llm"],
     "prompt": "Expand this outline into three sessions: {{outline}}"}
  ]
}
```

`message` (what the user typed) and `mem_text` (the memory this turn read) are
the input keys every run provides. Every other key a node reads comes from a node
that runs before it. The example starts at `outline`, routes on the outline's
length, and answers `reply` from `expand`, which is the last declared node.

## Why the validator restricts it

The model proposes the graph, so the graph is untrusted text until the validator
accepts it. `validateSkillGraph` (`nim/src/graph/skillgraph.nim`) is that gate,
and every path runs it: propose, approve, compile and install.

| Rule | Why the validator enforces it |
|---|---|
| `name` is non-empty, `abi` is 1, `nodes` is non-empty | The host refuses a manifest whose ABI it does not know, so a wrong value would fail at load time instead of at review time. |
| Node names are unique | Routes and the engine address a node by name, and one name with two definitions can only run one of them. |
| Kinds are `llm` and `router` only | A compiled skill runs as a worker, and a worker holds no tools and no sub-agents; a `tool` or `agent` node asks the parent for an effect the worker cannot serve. |
| `needs` holds `llm` and nothing else | `pluginWorkerEligible` refuses a manifest that needs `tool` or `fetch`, so a graph with those needs could compile and never run. |
| A router declares `needs: ["llm"]` | The fallback route decision is a model call, and the host refuses `llmComplete` for a node whose manifest does not name the need. |
| A route destination is `END` or a declared node | The engine resolves a jump by name and refuses an unknown target when it builds the graph, so a typo would fail the headless run instead of compiling. |
| Route labels are unique inside a router | The fallback answers one label and the engine looks that label up by name, so a duplicate makes the answer ambiguous. |
| A `when` condition names a key, an op from the closed catalog and the value type the op needs | `skillgen.nim` emits one expression per op, and an op outside `len_gt`, `len_lt`, `eq` and `contains` has no generated code. |
| The graph is a DAG reachable from the first node | The engine starts at the first node and follows the edges; an unreachable node never runs, and a cycle gives no node its second visit because every node allows one visit and a run stops at 25 steps. |
| Every `{{key}}` is one of the node's `inKeys`, and every `inKey` is `message`, `mem_text` or the `outKey` of a node that runs earlier | A key nobody wrote interpolates an empty string and the graph answers plausible garbage. A key written on a sibling branch may never exist when this node runs, so the check follows forward reachability from each producer instead of trusting declaration order. |

One asymmetry remains. The validator reads a placeholder as a closed `{{` and
`}}` pair, so an unclosed `{{` stays literal prompt text and no rule reports it.

## Where a graph comes from

Two dashboard actions on `POST /api/memory` author a graph, and they are the only
way a skill becomes a plugin. Both ride the existing route, so the served POST
surface does not grow, and both answer before the route opens `state.db`.

`skill_graph_propose` takes a skill slug, reads `<home>/skills/<slug>/SKILL.md`
and asks the configured model for a graph JSON. `<home>` is `.waku` unless
`WAKU_HOME` names another directory. The prompt states the schema the
validator accepts, field by field, so the model is not asked to guess a rule the
validator will enforce. The action validates the draft with the same
`validateSkillGraph` compilation uses. It returns the model's text unchanged
when the draft validates and the validator's own sentence when it does not. It
never compiles and never writes a plugin.

`skill_graph_approve` takes the graph JSON a human submits, validates it,
compiles it and installs it. No model is consulted on this path: the action
compiles exactly the submitted JSON and never re-generates, repairs or defaults
it. The answer names whether a compile happened (`compiled`) and whether a
different library already sat at the plugin path (`replaced`).

The draft's own model call is metered. `makeLiveSkillGraphDraft`
(`nim/src/arena_live.nim`) builds the call the way the turn judge builds its own,
wraps the client in `meteredClient` with kind `skill_graph`, and writes one
`usage.jsonl` row per press. `buildDashboardDeps` wires that function from the
configured provider. With no provider configured the action answers its "no model
backend" error, and approve keeps working because it needs no model.

The Memory tab has no control for either action yet, so a person reaches them
with an HTTP call to `POST /api/memory` until one ships.

## The stages

| Stage | Module | What it does |
|---|---|---|
| Validate | `nim/src/graph/skillgraph.nim` | Refuses every graph the compiler must not accept. |
| Generate | `nim/src/graph/skillgen.nim` | Writes one Nim file from the validated graph, using a fixed template. |
| Compile | `nim/src/graph/skillcompile.nim` | Runs `nim c --app:lib` as a child process with a timeout and a minimal environment. |
| Reuse | `nim/src/graph/skillcache.nim` | Keys the `.so` by the graph's canonical content and publishes it atomically. |
| Install | `nim/src/graph/skillinstall.nim` | Copies the cached library into `<home>/plugins/<name>.so` under a lock. |
| Decide | `nim/src/graph/skillmode.nim` | Answers plugin or text in one place, with the reason for a fallback. |

### Validate

`validateSkillGraph` parses the manifest into `SkillGraph` and raises
`SkillGraphError` with a sentence that names the node and the key. The module
imports nothing that compiles or writes, so it is safe to run on a draft before a
human sees it and safe to run again inside the compiler.

The validator runs first because it is the only thing between model output and
generated code. A graph it accepts is a graph the generator knows how to render:
the kinds decide which code is emitted, the routes decide which jumps exist, and
the data-flow check decides which keys the prompts may read.

### Generate

`generateSkillNim` writes one complete Nim file from the validated graph. The
template is fixed: the model never writes Nim, and only the JSON changes between
skills. The generated file mirrors `nim/tests/fixture_plugin_textops.nim`, the
hand-written reference plugin — the same `HostFns` field order, the same
copy-before-free pattern, the same error envelope — because that file already
holds the ABI.

The generated `describe` returns the manifest without the `prompt` fields, which
stay internal to `node_run`. An `llm` node replaces each declared `{{key}}` with
the state value, sends one user message with `max_tokens: 1024`, and writes its
`outKey` when it declares one. When the last declared node is an `llm` node, that
node also writes `reply`, because `reply` is the key `pluginRunHeadless` answers
with. A model answer with no text becomes an error envelope.

### Compile

`compileSkillGraph` validates the manifest, writes the generated source into a
work directory, and starts the compiler as a child process with these arguments:

```sh
nim c --app:lib --panics:off --hints:off -o:<name>.so <name>.nim
```

The child exists for three reasons: a compiler that crashes
cannot take the assistant with it, a compile that hangs can be killed at a
deadline, and the child can run with an environment of its own.

That environment holds `PATH` and `HOME` and nothing else, so no API key from the
parent's environment rides into the compile. `PATH` lets the compiler find `cc`
and `ld`, and `HOME` lets it find its per-user configuration and cache.
`--panics:off` makes even a `Defect` catchable inside the plugin, which is what
the template's `try` block relies on.

The parent drains the child's combined output while the child runs.
`startProcess` gives the child a pipe with a fixed buffer, so a compiler that
writes more than the buffer blocks on `write` while the parent waits for exit,
and the deadlock reads as a timeout. The drain is `select(2)` on the child's
output handle with a 20 ms wait and a 16 KB tail kept for the error message, and
the deadline is checked between reads. A child still running at 60 s is killed,
the error names the deadline, and a failed compile removes the `.so` it may have
written. `skillcompile.nim` imports `std/posix` for `select`, so the module
builds for POSIX targets only; `config.nims` pins `os=linux`.

Every failure is a returned error, never a raise into the caller's turn.

### Reuse

`compileOrLoadSkill` keys the artifact by the graph's content. `skillCacheHash`
is FNV-1a 64 over `canonicalGraphJson`, which sorts object keys recursively, so
two manifests that mean the same thing name one artifact even when their keys
arrived in a different order — a plausible output variation from a model. A hit
returns the existing `<home>/skills-compiled/<name>-<hash>.so` and never starts a
compiler.

Each compile gets its own work directory, `<name>-<hash>-<pid>-<serial>` under
the work root the caller passes (`<home>/skills-build` for the dashboard). The
pid separates two processes and the call counter separates two compiles inside
one process, so no two compiles ever share a source or an output path. The
artifact is published by copying it to a sibling temporary
(`<target>.tmp-<pid>`) and renaming it onto the target, so a reader sees the old
library or the whole new one, and of two publishers the last one wins.

### Install

`installCompiledSkill` copies the cached library to `<home>/plugins/<name>.so`.
That is the directory `pluginRunHeadless` and the worker resolver read, so a
compiled skill runs through the same code as a hand-written plugin worker. The
path stem is the manifest name for that reason.

An install that finds the same content at the target is a no-op: the check runs
before the lock, and again under it in case the process it waited for just
published that library. A real write takes `<name>.lock` beside the target: an
exclusive create with a 2 s bounded wait and a 25 ms poll, and a lock older than
5 minutes is treated as abandoned and taken over. The lock is a file because two
installs can be two processes. A successful install reports `replaced: true` when
a different library already sat at the path, and the plugin contract never
unloads a library, so the running process keeps serving the old one until it
restarts.

### Decide

`resolveSkillExecution` (`nim/src/graph/skillmode.nim`) answers the plugin-or-text
question in one place, and `describeExecution` writes the answer as one line that
never hides a fallback. Every compile failure becomes text mode with a reason: no
compiler, an invalid graph, a non-zero exit, a timeout, an install error.

The loop does not call it. The loop uses what is installed and compiles nothing,
so `runFullTurn` asks `installedSkill` whether the file exists.
`resolveSkillExecution` is the same decision for a caller that does want to
compile, and its six tests pin the fallbacks.

## The router contract

A route carries an optional `when` condition with a key, an op and a value. The
catalog is closed: `len_gt` and `len_lt` compare the key's string length with an
integer, and `eq` and `contains` compare the string with a string. The generated
router evaluates the conditions in declaration order, and the first match wins.

When no condition matches, the router asks the model to answer exactly one
declared label, with `max_tokens: 32`. An answer outside the declared set becomes
an error envelope that names the label it received, never a silent default. A
route without `when` is reachable only through that fallback.

Because the fallback is a model call, every router declares `needs: ["llm"]`, and
the validator refuses a router without it. The host refuses `llmComplete` for a
node whose manifest does not name the need, so a router without it would fail at
run time instead of at validation time.

The engine calls a router's node function and then its route function for one
visit (`pluginRouter` in `nim/src/graph/plugins.nim`, called from the run loop in
`nim/src/graph/engine.nim`). The generated plugin therefore keeps the fallback's
decision in a memo keyed by node, in a one-handle slot that is cleared when the
handle changes: one visit pays for one model call, and the two calls cannot
disagree. Conditions run first on both calls, so a condition stays authoritative
over a memoized or a fresh fallback.

## What the loop does with an installed plugin

`wireMemory` fills `Session.skillTurn`, and `runFullTurn` consults that seam right
after `buildSystem`. The system prompt is built exactly as before, which is what
makes a turn with no installed plugin identical by construction, and only then
does the turn decide who answers. The prompt is still built, so the turn still
pays the retrieval gate call before the seam is asked; the loop is what the turn
skips.

`skillWorkerTurn` takes the same ranked, capped list `matchingSkills` uses: the
top two matched skills. The first one with `<home>/plugins/<name>.so` answers,
even when a better text match has no plugin. The file's existence is the whole
installation signal: the seam reads no manifest to choose, and it starts no
compiler.

The run is `pluginRunHeadless` (`nim/src/worker_plugin.nim`): load the library,
refuse a manifest that is not worker-eligible, run the graph with the worker's
own model client, and answer `reply`, `usage` and any `log` lines. The run starts
from `{"message": ..., "mem_text": ...}` and nothing else, and `mem_text` is the
retrieval gate's answer for this turn, read through the cell `buildSystem` filled
a moment earlier.

An answer returns `LoopResult(reply: ..., iterations: 1)`. `respond` persists the
exchange, consolidates, writes the receipt and closes the trace exactly as it
does around a loop reply.

Every other outcome declines the turn and leaves the text path to answer it in
the same turn: an empty reply, a load failure, an ineligible manifest and a raise
all become one `skill` trace line with `mode: "text"` and the reason. A turn with
nothing installed writes no such line.

An answered run that reports usage emits the flat `cost` event with
`kind: "skill:<name>"`, and the tracer books it into `usage.jsonl` and stamps
`cost_usd`. An empty or failed run books nothing.

A compiled skill skips what the loop provides. It does not stream, because a
worker answers in one piece. It does not read the company brain first. It does
not filter MCP tools by task. Its worker state carries no chat history, no
SOUL.md and no tools.

## Security posture

The model never writes Nim. It answers JSON, `skillgen.nim` holds the template,
and every skill compiles that template with different data.

The validator is the gate. It refuses a graph before anything compiles, and every
entry point runs it.

The compile child gets `PATH` and `HOME` and nothing else, so the parent's
environment does not follow it. The child runs as the user, on the user's own
filesystem and network: the isolation is the fixed source and the empty
environment, not a sandbox.

The compiled plugin runs in-process through the plugin ABI and its six host
functions. `tool` and `fetch` are refused twice, once by the worker eligibility
gate and once by the host, and a skill graph cannot declare them at all.

A compiled skill spends the user's tokens. The graph's `llm` prompts run on the
configured model, and a router fallback makes a call of its own.

## Known gaps

1. A router fallback's tokens are not metered. The engine's route function
   carries no observer, so the fallback's model call never reaches the usage
   node and only the node call's tokens land in `usage.jsonl`. A run that spends
   tokens and then raises books nothing either.

2. The cache never evicts. Every distinct graph leaves one `.so` in
   `<home>/skills-compiled`, and nothing deletes an old one. The key is FNV-1a
   64, not a cryptographic hash, so a collision would serve an older library for
   the same skill name.

3. `<home>/plugins` is loaded in-process at startup (`loadPluginGraphs` in
   `nim/src/waku.nim`), so an installed skill is also the graph `plugin:<name>`.
   A skill whose name collides with an existing plugin shares that namespace,
   and a replaced library keeps serving the old copy until the process restarts.

4. A compiled skill loses streaming, the research brain reads and the MCP task
   filter, and it sees no chat history, no SOUL.md and no tools.

5. Nothing in the dashboard calls `skill_graph_propose` or
   `skill_graph_approve` yet. The Memory tab edits `SKILL.md`; the two actions
   answer an HTTP call to `POST /api/memory` until a control ships.

6. A failing node inside a compiled skill is not reported to the turn. The run
   continues, and when nothing answers, the turn says "the skill answered
   nothing". `pluginRunHeadless` answers the reply, the usage and the logs, not
   `state["errors"]`, so the failing node's message is not carried back.

7. A graph whose last declared node is a router answers nothing by default. The
   generator writes `reply` when the last declared node is an `llm` node, or when
   a node declares `outKey: "reply"`; a router at the end leaves no such writer.
   The turn falls back to text with a reason, so nothing fails.

8. The validator requires a non-empty `name` and checks nothing else about it.
   The name becomes a file path inside the compile work directory and under
   `<home>/plugins`, so a graph whose name holds a path separator writes outside
   those directories. A person approves the JSON and the draft prompt asks for a
   lowercase slug, but no rule enforces it.

## What pins it

Each module carries its own suite in `nim/tests/`: 42 validator tests, 21
generator tests, 10 compiler tests, 24 cache tests, 7 install tests and 6 mode
tests. The generator suite compiles generated Nim and loads the result through
`loadPlugin`, because the contract is execution and not emitted text.

The loop path is pinned twice. `test_app.nim` compares a wired and an unwired
home byte for byte — the request JSON, the reply, the chat rows and the trace
kinds — and its twin shows the system prompt bytes are equal when a plugin does
answer, and that no request then carries a system prompt. `test_memory_live.nim`
pins the fallbacks, the ranking and the ledger row, and one test asserts a
non-empty skill body reaching the system prompt end to end through `wireMemory`
and `buildSystem`.

The dashboard suite covers both actions. Propose returns the draft's text, a
refused draft carries the validator's sentence, approve compiles exactly the
submitted JSON while a misbehaving model seam stays uncalled, and the existing
route behaviour keeps its response shape.
