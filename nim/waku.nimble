# Package metadata for the Waku Nim port.
# Offline: `nimble build` and `nimble test` make no network calls.
# `db_connector` is the stdlib db_sqlite successor (same API, links the
# system SQLite); it is the only non-stdlib dependency and ships phase 1+.

version       = "0.0.1-phase0"  # keep in sync with the version const in src/waku.nim
author        = "Waku contributors"
description   = "Local-first personal assistant: Nim port skeleton (phase 0)"
license       = "MIT"
srcDir        = "src"
bin           = @["waku"]

requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0"
