# textops — the reference graph plugin

Copy `textops.nim` to start your own Waku graph plugin. It implements
the whole ABI v1 contract in one readable file: five exports, the
six-function host table, the JSON envelopes, and the ownership rule.

## What it does

`upper` (tool) uppercases `text`, `summarize` (llm) asks the host
model for one short sentence, `pick_long` (router) jumps to `expand`
when the summary is longer than 120 characters and to `END`
otherwise, and `expand` (tool) appends ` [...]` on the long path.

## Build

Nim stable, no extra dependency:

```sh
nim c --app:lib --panics:off -o:textops.so textops.nim
```

Check the five exports are global (`T`, not local):

```sh
nm -D textops.so | grep waku_plugin_
```

## Install and run

```sh
mkdir -p .waku/plugins
cp textops.so .waku/plugins/
```

Pick `plugin:textops` in the dashboard Connections panel
(per-source `WAKU_GRAPH_<SOURCE>`) or set `WAKU_GRAPH_WORKFLOWS`
to it. A missing or refused plugin fails open to the loop.

## Contract notes for authors

- Ask for `"model": ""` (or `"default"`) to run on the agent's model;
  name an id only when you need a specific one.
- Mirror the `HostFns` struct by hand; never import a host module.
  Field order and types are the ABI.
- Validate at load: `dst` is `END` or a node of the same manifest,
  labels are unique per router, only a `router` entry's `routes`
  reach the engine.
- Never let an exception cross `waku_plugin_node_run`; answer
  `{"ok": false, "error": "..."}` instead.
- Whoever allocates a string frees it: plugin strings via
  `waku_plugin_string_free`, host strings via `HostFns.stringFree`,
  always copying before freeing.
