# Waku Nim port (phase 0)

This folder holds the Nim port of Waku. The port will ship one binary that
reads and writes the same `.waku/` data as Python Waku. Phase 0 is the
skeleton: the package builds, the config module loads, and the CLI entry
point lists the commands the port will implement.

## Build and test

Nim 2.0 or newer is required. The package uses the standard library only, so
`nimble build` and `nimble test` make no network calls.

```sh
cd nim
nimble build    # builds the waku binary
nimble test     # runs the offline phase 0 tests
```

## What phase 0 covers

- `waku.nimble` declares one package that uses the standard library only.
- `src/config.nim` defines the `Settings` object (provider, apiKey, model,
  home) with `WAKU_PROVIDER`, `WAKU_API_KEY`, `WAKU_MODEL` and `WAKU_HOME` env overrides, and
  a small `.env` line parser. This ports the config subset of
  `waku/config.py`.
- `src/waku.nim` is the CLI entry point. `--help` lists the 12 commands,
  `--version` prints the port version, and every other command prints the
  not-yet-implemented reason to stderr and exits 0.
- `tests/test_phase0.nim` tests the env overrides, the `.env` parser and the
  command table offline.

## What is not ported yet

Nothing else runs. The port still needs the `providers.toml` parser, the
SQLite state and memory, the tool registry, the Anthropic and OpenAI loop,
the session assembly, the integrations catalog, MCP, the chat gateways, the
dashboard and the evals. The phase list with its gates lives in
[docs/nim-port-design.md](../docs/nim-port-design.md).
