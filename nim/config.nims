import mimalloc/config

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

switch("os", "linux")

# NOTE (2026-10-10): `danger` disabled on purpose. It turns off Nim's
# runtime checks, which turns an empty-query `rows[0][0]` in
# tests/test_app.nim `chatMeta` (quick graph turn) from a clear
# IndexDefect into `SIGSEGV: Illegal storage access`. `release`/`lto`
# below keep the perf build; only the checks-off switch is out.
switch("define", "lto")

switch("passC", "-flto=auto")
switch("passC", "-march=native")
switch("passC", "-Wno-incompatible-pointer-types")
switch("passL", "-Wno-stringop-overflow")
switch("passL", "-Wno-stringop-overread")
switch("passL", "-flto=auto")
switch("passL", "-Wl,--strip-all,--gc-sections")
switch("passL", "-lc")
