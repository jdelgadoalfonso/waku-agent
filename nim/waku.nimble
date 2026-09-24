# Package metadata for the Waku Nim port, phase 0 skeleton.
# Standard library only: `nimble build` and `nimble test` make no network calls.

version       = "0.0.1-phase0"  # keep in sync with the version const in src/waku.nim
author        = "Waku contributors"
description   = "Local-first personal assistant: Nim port skeleton (phase 0)"
license       = "MIT"
srcDir        = "src"
bin           = @["waku"]

requires "nim >= 2.0.0"
