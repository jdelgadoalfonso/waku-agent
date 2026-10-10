# Third-party notices for the Nim port vendor directory

This directory holds vendored third-party sources so the
optional styled build (`-d:wakuStyle`) does not add a default
dependency to `waku.nimble`.

## terminal_style

- Upstream: <https://github.com/titanomachy/terminal-style>
- License: MIT (`terminal_style/LICENSE`)
- Used for: optional ANSI colors, attributes, ANSI parsing and
  cell-aware text layout in `nim/src/style.nim`.
- Not used by the default build. The vendored sources add no `requires`
  entry; only `nimble buildStyle` compiles against them. (`nimble build`
  and `nimble test` still need the `requires` dependencies installed,
  now including mandatory `mimalloc_nim`.)

The vendored copy is upstream `src/` plus `LICENSE` and
`README.md`, unmodified. Do not edit it here; sync from
upstream instead.
