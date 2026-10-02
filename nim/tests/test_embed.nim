## Phase 9a-1 tests: the compile-time dashboard asset embed.
##
## One contract, offline and with no temp home: a bare binary — one with
## no `waku/ops/static/` checkout beside it, which is exactly
## `staticDir: ""` — answers `/` and `/static/...` from the bytes frozen
## into the executable at compile time, and every frozen byte is the
## checkout byte.
##
## The parity suites read the checkout from disk on purpose: a test may
## look at the tree, the binary must not. Where the checkout is missing
## they skip and the shape pins below still run.

import std/algorithm
import std/os
import std/strutils
import std/unittest

import ../src/dashboard

type
  EmbedFile = tuple[name, body: string]
    ## One checkout file, shaped like the embed's own `StaticAsset`.
    ## (Named tuple ANNOTATIONS inline — `seq[(name: string, body: ...)]`
    ## — are rejected by this compiler, so an alias carries the shape.)

proc checkoutStatic(): string =
  ## The `waku/ops/static/` checkout this port was compiled beside,
  ## resolved from this file's own path and never from the working
  ## directory, so the suite behaves the same from `nim/` and from the
  ## repo root. `parentDir` first, on purpose: `normalizedPath` here pops
  ## whatever component precedes a `..`, filename included.
  normalizedPath(currentSourcePath().parentDir / ".." / ".." / "waku" /
    "ops" / "static")

proc checkoutFiles(): seq[EmbedFile] =
  ## The checkout as the same `(name, bytes)` pairs the embed holds, so
  ## a parity assert reads as one line. Skipped suites never call this.
  for f in walkDirRec(checkoutStatic(), relative = true):
    result.add((name: f.replace(DirSep, '/'),
      body: readFile(checkoutStatic() / f)))

proc checkoutNames(): seq[string] =
  for f in checkoutFiles():
    result.add(f.name)
  result.sort(cmp[string])

suite "phase 9a-1 embedded dashboard assets":
  test "the SPA index is served from the embed, not from disk":
    let (status, ctype, body) = serveIndex("")
    assert status == 200
    assert ctype == "text/html; charset=utf-8"
    assert "<title>Waku" in body

  test "an embedded asset keeps its Python content type":
    let (status, ctype, body) = serveStatic("", "/static/js/main.js")
    assert status == 200
    assert ctype == "text/javascript"
    assert body.len > 0

  test "a font embeds byte for byte, NULs and all":
    # The .woff2 files are why this is `staticRead` and not a text
    # template: a binary blob must survive the embed unchanged.
    let (status, ctype, body) = serveStatic("",
      "/static/fonts/PlayfairDisplaySC-400.woff2")
    assert status == 200
    assert ctype == "font/woff2"
    assert body == readFile(checkoutStatic() / "fonts" /
      "PlayfairDisplaySC-400.woff2")

  test "every checkout file is embedded with its exact bytes":
    # No checkout beside the source drop: nothing to compare against, and
    # pretending otherwise would pin the wrong thing.
    if not dirExists(checkoutStatic()):
      skip()
    let files = checkoutFiles()
    assert files.len > 0
    assert embeddedStaticCount == files.len
    for f in files:
      let (status, ctype, body) = serveStatic("", "/static/" & f.name)
      assert status == 200
      assert body == f.body
      assert ctype == contentTypeFor(f.name)

  test "the embed holds nothing the checkout does not":
    # The stale direction: an asset added to the checkout and not
    # embedded must fail here, not 404 in someone's browser.
    if not dirExists(checkoutStatic()):
      skip()
    assert embeddedStaticNames() == checkoutNames()

  test "the design copies are embedded unmodified (rule 8, LICENSE-BRAND)":
    # LICENSE-BRAND allows the design files INCLUDED and UNMODIFIED: they
    # are in the embed, and the bytes are the master's bytes.
    if not dirExists(checkoutStatic()):
      skip()
    for name in ["design/tokens.css", "design/fonts.css", "design/type.css",
        "design/controls.css"]:
      let (found, body) = embeddedAsset(name)
      assert found
      assert body == readFile(checkoutStatic() / name.replace('/', DirSep))

  test "the SPA route answers 200 from the embed with no checkout":
    var d: DashboardDeps
    d.staticDir = ""
    d.home = getTempDir()
    let (status, ctype, body) = handleGet(d, "/")
    assert status == 200
    assert ctype == "text/html; charset=utf-8"
    assert body.len > 0
    # An unknown path still renders the shell (Python's trailing `else`).
    assert handleGet(d, "/deep/link")[0] == 200

suite "phase 9a-1 embed negatives":
  test "an asset the embed does not hold is a 404, never a read":
    assert serveStatic("", "/static/not-an-asset.js")[0] == 404
    assert serveStatic("", "/static/")[0] == 404

  test "traversal cannot escape the embed":
    # Exact-name lookup IS the confinement: none of these are keys, so
    # there is no resolved path left to confine.
    for path in ["/static/../secret.txt", "/static/../../etc/hostname",
        "/static//etc/passwd", "/static/js/../../db.nim",
        "/static/./index.html", "/static/index.html/"]:
      assert serveStatic("", path)[0] == 404

  test "a backslash is not a directory separator in an embed key":
    assert serveStatic("", "/static/js\\main.js")[0] == 404

  test "a configured checkout still wins over the embed":
    # The dev path is unchanged: a static dir on disk is served from disk,
    # so frontend edits need no rebuild (the 8a pins live on this).
    let root = getTempDir() / "waku-embed-checkout"
    if dirExists(root):
      removeDir(root)
    createDir(root / "static" / "js")
    writeFile(root / "static" / "index.html", "<html>checkout</html>")
    writeFile(root / "static" / "js" / "main.js", "console.log(99);")
    try:
      assert serveIndex(root / "static")[2] == "<html>checkout</html>"
      let (status, ctype, body) = serveStatic(root / "static",
        "/static/js/main.js")
      assert status == 200
      assert ctype == "text/javascript"
      assert body == "console.log(99);"
      # An asset the checkout lacks is still a 404 there: the embed does
      # not paper over a broken dev tree.
      assert serveStatic(root / "static", "/static/waku-mark.svg")[0] == 404
    finally:
      removeDir(root)