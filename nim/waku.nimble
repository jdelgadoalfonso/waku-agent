# Package metadata for the Waku Nim port.
# Offline: `nimble build` and `nimble test` make no network calls.
# `db_connector` is the stdlib db_sqlite successor (same API, links the
# system SQLite); it is the only non-stdlib dependency and ships phase 1+.

version       = "0.0.1"
# The one editable copy of the version number. `src/waku.nim` reads this line
# at compile time (`staticRead("../waku.nimble")`), so `waku --version` and
# nimble cannot disagree. The literal stays here because nimble reads this
# file where `src/` is not beside it (an installed package keeps its sources
# at the package root) and refreshes what it read only when this file changes.
# Shape: `\d+\.\d+\.\d+`, pinned by `tests/test_version.nim`.
author        = "Waku contributors"
description   = "Local-first personal assistant: Nim port skeleton (phase 0)"
license       = "MIT"
srcDir        = "src"
bin           = @["waku"]

requires "nim >= 2.0.0"
requires "db_connector >= 0.1.0"

# The offline suite, written down instead of discovered. `nimble test` finds
# `tests/` on its own, so nothing about what RUNS changes here: the point is
# that the manifest a reader opens states the contract instead of leaving it to
# an auto-discovery nobody can see. Three consequences are now explicit rather
# than lucky:
#
# - A new suite is picked up by naming it `tests/test_*.nim`. That is the whole
#   convention, and the empty case below refuses instead of reporting a green
#   run that tested nothing.
# - Sorted, so the suite that reports a failure first is the same one on every
#   machine — `listFiles` returns whatever the filesystem hands back.
# - The first failure stops the loop, so a suite that failed and a suite that
#   never ran cannot both look like a pass.
#
# Each suite compiles and runs with `nim/` as the working directory, because
# pins read the checkout relative to it (`tests/test_cli.nim` walks up to
# `waku/providers.toml`). `nim c -r` inherits this task's directory, so the
# pins see the same tree they see when a human types the command.
import std/algorithm # `sort` below. Top level: a task body cannot import.

task test, "Compiles and runs every tests/test_*.nim suite (offline, no key)":
  var suites: seq[string] = @[]
  for suite in listFiles("tests"):
    if suite.startsWith("test") and suite.endsWith(".nim"):
      suites.add(suite)
  suites.sort()
  for suite in suites:
    echo "Compiling and running ", suite
    exec "nim c -r --hints:off " & suite
  if suites.len == 0:
    quit("no suites in tests/ — name them tests/test_*.nim")

# The live-TLS build, and the ONE place its switches are typed.
#
# `-d:ssl` is the compiler's own switch: it links the system libssl and
# is what `std/httpclient`'s no-TLS guard checks, so without it every
# `https://` request raises before it connects. `-d:wakuTls` is this
# port's, and it is what says a developer meant it — it attaches the
# `std/net.SslContext` from `http.nim` to every live client and lets
# `liveDiscordWire` dial `wss://gateway.discord.gg`. Both, or neither:
# one alone degrades to the default build rather than compiling
# something half-encrypted.
#
# No new package (rule 3): `std/net` plus `wrappers/openssl` are stdlib
# and libssl is the system's, so this costs a build switch and an
# OpenSSL development package, not a dependency.
#
# The binary is written as `waku_tls`, NOT over `waku`, so a TLS build
# and a default build can sit in the same tree and the default binary
# is still the one `nimble build` produced.
const tlsDefines* = "-d:ssl -d:wakuTls"

task buildTls, "Compiles the same binary with live TLS (needs the OpenSSL headers)":
  exec "nim c --hints:off " & tlsDefines & " -o:waku_tls src/waku.nim"

task testTls, "Runs tests/test_tls.nim in the live-TLS build (offline, no key)":
  exec "nim c -r --hints:off " & tlsDefines &
    " -o:tests/test_tls_flagged tests/test_tls.nim"
