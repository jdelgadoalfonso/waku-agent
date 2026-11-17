## Skill compile cache (T4): content-hashed .so reuse.
##
## The cache key is a canonical form of the graph (object keys sorted
## recursively), so two manifests that say the same thing — however the
## LLM ordered the keys — share one compiled .so. A cache hit never
## invokes the compiler: that is what makes the second turn of a loop
## cheap.
##
## S12 (T4b) adds the concurrency guard: work files are never shared by two
## graphs, the cached artifact is published by an atomic rename, and the
## install target is guarded by a cross-process lock. The lock itself lives
## in skillinstall, and its tests live here too: the work paths and the
## install target are one contract — two turns must share neither.
##
## S13 (T4c) tightens the work path: it is unique per COMPILE, not per graph,
## so two compiles of one graph — in the same process or in two — never write
## the same source or the same `-o:` target while the cache stays per graph.

import std/json
import std/os
import std/sequtils
import std/strutils
import std/times
import std/unittest

import ../src/graph/skillcache
import ../src/graph/skillinstall

proc manifest(): JsonNode =
  %*{
    "name": "cachefx",
    "abi": 1,
    "nodes": [
      {"name": "summarize", "kind": "llm", "inKeys": ["message"],
       "outKey": "summary", "needs": ["llm"],
       "prompt": "Summarize: {{message}}"}
    ]
  }

proc freshHome(tag: string): string =
  result = getTempDir() / ("waku-skillcache-" & tag)
  if dirExists(result):
    removeDir(result)
  createDir(result)

## A fake compiler that always fails: proves a cache hit never compiles.
proc failingCompiler(dir: string): string =
  let path = dir / "always-fail"
  writeFile(path, "#!/bin/sh\nexit 3\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  path

## A fake compiler that records the source path and the `-o:` target it
## was handed, then fails: the paths are the contract here, not the .so.
proc recordingCompiler(dir: string): string =
  let path = dir / "record-paths"
  writeFile(path, """#!/bin/sh
last=""
out=""
for a in "$@"; do
  case "$a" in
    -o:*) out="${a#-o:}" ;;
  esac
  last="$a"
done
printf 'src=%s out=%s\n' "$last" "$out" >> LOGPATH
exit 5
""".replace("LOGPATH", dir / "compiler-paths.log"))
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  path

## A fake compiler that writes a partial file at the `-o:` path and then
## fails: a crashed or abandoned compile must never reach the cache.
proc partialCompiler(dir: string): string =
  let path = dir / "partial-fail"
  writeFile(path, """#!/bin/sh
out=""
for a in "$@"; do
  case "$a" in
    -o:*) out="${a#-o:}" ;;
  esac
done
if [ -n "$out" ]; then printf 'NOT A LIBRARY' > "$out"; fi
exit 4
""")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  path

proc cacheHash(home: string, m: JsonNode): string =
  ## The 16-hex hash the cache filename carries, read back out of it.
  let stem = splitFile(skillCachePath(home, m)).name
  stem[stem.len - 16 .. ^1]

proc outPathOf(line: string): string =
  ## The `-o:` value the recording compiler saw, read back out of its log.
  const marker = "out="
  let at = line.find(marker)
  if at < 0:
    return ""
  line[at + marker.len .. ^1].strip()

suite "skill compile cache":

  test "canonical json ignores key order":
    let a = parseJson("""{"name":"x","abi":1,"nodes":[]}""")
    let b = parseJson("""{"nodes":[],"abi":1,"name":"x"}""")
    assert canonicalGraphJson(a) == canonicalGraphJson(b)

  test "canonical json ignores nested key order":
    let a = parseJson("""{"name":"x","nodes":[{"name":"n","kind":"llm"}]}""")
    let b = parseJson("""{"nodes":[{"kind":"llm","name":"n"}],"name":"x"}""")
    assert canonicalGraphJson(a) == canonicalGraphJson(b)

  test "different graphs hash differently":
    var other = manifest()
    other["nodes"][0]["prompt"] = %"Different: {{message}}"
    assert skillCachePath("/tmp/home", manifest()) !=
      skillCachePath("/tmp/home", other)

  test "cache path lives under home/skills-compiled and ends in .so":
    let path = skillCachePath("/tmp/home", manifest())
    assert path.startsWith("/tmp/home" / "skills-compiled")
    assert path.endsWith(".so")
    assert path.contains("cachefx")

  test "first call compiles and writes the cached .so":
    let home = getTempDir() / "waku-skillcache-first"
    let work = home / "work"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    let res = compileOrLoadSkill(manifest(), home, work)
    assert res.ok, "compile failed: " & res.error
    assert res.recentlyCompiled
    assert res.soPath == skillCachePath(home, manifest())
    assert fileExists(res.soPath)
    removeDir(home)

  test "second call is a cache hit and never invokes the compiler":
    let home = getTempDir() / "waku-skillcache-hit"
    let work = home / "work"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    let first = compileOrLoadSkill(manifest(), home, work)
    assert first.ok and first.recentlyCompiled
    # A compiler that always fails proves the second call never ran one.
    let second = compileOrLoadSkill(manifest(), home, work,
      nimExe = failingCompiler(home))
    assert second.ok
    assert not second.recentlyCompiled
    assert second.soPath == first.soPath
    removeDir(home)

  test "a graph with reordered keys hits the same cache entry":
    let home = getTempDir() / "waku-skillcache-order"
    let work = home / "work"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    let first = compileOrLoadSkill(manifest(), home, work)
    assert first.ok and first.recentlyCompiled
    let reordered = parseJson("""{"abi":1,"nodes":[{"needs":["llm"],
      "outKey":"summary","inKeys":["message"],"kind":"llm","name":"summarize",
      "prompt":"Summarize: {{message}}"}],"name":"cachefx"}""")
    let second = compileOrLoadSkill(reordered, home, work,
      nimExe = failingCompiler(home))
    assert second.ok
    assert not second.recentlyCompiled
    removeDir(home)

  test "an invalid graph never reaches the cache":
    let home = getTempDir() / "waku-skillcache-invalid"
    let work = home / "work"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    var bad = manifest()
    bad["nodes"][0]["kind"] = %"tool"
    let res = compileOrLoadSkill(bad, home, work)
    assert not res.ok
    assert res.soPath == ""
    assert not dirExists(home / "skills-compiled")
    removeDir(home)

  test "the compiler is handed a work path that carries the graph hash":
    let home = freshHome("workhash")
    let work = home / "work"
    discard compileOrLoadSkill(manifest(), home, work,
      nimExe = recordingCompiler(home))
    let seen = readFile(home / "compiler-paths.log")
    let hash = cacheHash(home, manifest())
    assert hash.len == 16
    assert seen.contains("src="), seen
    assert seen.contains(hash),
      "the work path carries no graph hash, so two graphs share it: " & seen
    removeDir(home)

  test "two graphs that share a name never share a work path":
    let home = freshHome("workpaths")
    let work = home / "work"
    let compiler = recordingCompiler(home)
    var other = manifest()
    other["nodes"][0]["prompt"] = %"Other: {{message}}"
    discard compileOrLoadSkill(manifest(), home, work, nimExe = compiler)
    discard compileOrLoadSkill(other, home, work, nimExe = compiler)
    let runs = readFile(home / "compiler-paths.log").splitLines()
      .filterIt(it.len > 0)
    assert runs.len == 2, $runs
    assert runs[0] != runs[1],
      "two graphs wrote the same work files: " & runs[0]
    removeDir(home)

  test "two calls for the same graph take different work directories":
    let work = getTempDir() / "waku-skillcache-workdir-calls"
    let hash = skillCacheHash(manifest())
    # Two compiles of ONE graph: sharing this directory is what let one
    # process copy the other's half-written library into the cache.
    let first = skillWorkDir(work, manifest())
    let second = skillWorkDir(work, manifest())
    assert first != second,
      "two compiles of one graph share a work directory: " & first
    assert first.contains(hash), first
    assert second.contains(hash), second
    assert first.startsWith(work) and second.startsWith(work)

  test "two compiles of one graph hand the compiler different output paths":
    let home = freshHome("workserial")
    let work = home / "work"
    let compiler = recordingCompiler(home)
    let hash = skillCacheHash(manifest())
    discard compileOrLoadSkill(manifest(), home, work, nimExe = compiler)
    discard compileOrLoadSkill(manifest(), home, work, nimExe = compiler)
    let runs = readFile(home / "compiler-paths.log").splitLines()
      .filterIt(it.len > 0)
    assert runs.len == 2, $runs
    let firstOut = outPathOf(runs[0])
    let secondOut = outPathOf(runs[1])
    assert firstOut.len > 0 and secondOut.len > 0, $runs
    assert firstOut != secondOut,
      "two compiles wrote the same -o: target: " & firstOut
    assert firstOut.contains(hash), firstOut
    assert secondOut.contains(hash), secondOut
    removeDir(home)

  test "the cache path stays per graph while work paths are per compile":
    let home = freshHome("cacheone")
    let work = home / "work"
    let target = skillCachePath(home, manifest())
    let first = compileOrLoadSkill(manifest(), home, work)
    assert first.ok, first.error
    assert first.recentlyCompiled
    assert first.soPath == target
    # Force a second compile of the same graph: it must publish onto the
    # same cache entry. Uniqueness lives in the work path, never here.
    removeFile(target)
    let second = compileOrLoadSkill(manifest(), home, work)
    assert second.ok, second.error
    assert second.recentlyCompiled
    assert second.soPath == target
    assert skillCachePath(home, manifest()) == target
    assert fileExists(target)
    removeDir(home)

  test "a cache hit compiles nothing and takes no new work directory":
    let home = freshHome("hitwork")
    let work = home / "work"
    let first = compileOrLoadSkill(manifest(), home, work)
    assert first.ok, first.error
    assert first.recentlyCompiled
    let workDirs = toSeq(walkDir(work)).len
    assert workDirs >= 1
    # A compiler that always fails proves the hit ran none; the work tree
    # is untouched, so a hit never burns a scratch directory either.
    let second = compileOrLoadSkill(manifest(), home, work,
      nimExe = failingCompiler(home))
    assert second.ok
    assert not second.recentlyCompiled
    assert toSeq(walkDir(work)).len == workDirs,
      "a cache hit created a work directory"
    removeDir(home)

  test "the work source and its .so both carry the graph hash":
    let home = freshHome("worknames")
    let work = home / "work"
    let hash = skillCacheHash(manifest())
    assert hash == cacheHash(home, manifest())
    let paths = skillWorkPaths(work, manifest())
    assert paths.source.contains(hash)
    assert paths.so.contains(hash)
    assert paths.source.startsWith(work)
    # One compile, one directory: both paths always belong together.
    assert paths.source.parentDir == paths.so.parentDir
    var other = manifest()
    other["nodes"][0]["prompt"] = %"Other: {{message}}"
    assert skillWorkPaths(work, other).source != paths.source
    assert skillWorkPaths(work, other).so != paths.so
    removeDir(home)

  test "a partial artifact from a failed compile never reaches the cache":
    let home = freshHome("partial")
    let work = home / "work"
    let res = compileOrLoadSkill(manifest(), home, work,
      nimExe = partialCompiler(home))
    assert not res.ok
    assert not fileExists(skillCachePath(home, manifest()))
    let cacheDir = home / "skills-compiled"
    let entries = toSeq(walkFiles(cacheDir / "*"))
    assert entries.len == 0,
      "a failed compile published something: " & $entries
    removeDir(home)

  test "publishing an artifact goes through a sibling temporary":
    let home = freshHome("publish")
    let dir = home / "skills-compiled"
    createDir(dir)
    let target = dir / "cachefx-0123456789abcdef.so"
    writeFile(target, "old library")
    let source = home / "source.so"
    writeFile(source, "new library")
    let temp = artifactTempPath(target)
    # A sibling, so the final move is a rename: a temporary on another
    # filesystem would fall back to a copy and a reader could see half a
    # library.
    assert parentDir(temp) == parentDir(target)
    assert temp != target
    publishArtifact(source, target)
    assert readFile(target) == "new library"
    assert not fileExists(temp), "the temporary survived the publish"
    removeDir(home)

  test "a compile leaves only the published artifact in the cache":
    let home = freshHome("onlyfinal")
    let res = compileOrLoadSkill(manifest(), home, home / "work")
    assert res.ok, "compile failed: " & res.error
    let entries = toSeq(walkFiles(home / "skills-compiled" / "*"))
    assert entries.len == 1, $entries
    assert entries[0] == res.soPath
    assert not fileExists(artifactTempPath(res.soPath))
    removeDir(home)

  test "a failed compile leaves no cache entry":
    let home = getTempDir() / "waku-skillcache-fail"
    let work = home / "work"
    if dirExists(home):
      removeDir(home)
    createDir(home)
    let res = compileOrLoadSkill(manifest(), home, work,
      nimExe = failingCompiler(home))
    assert not res.ok
    assert not fileExists(skillCachePath(home, manifest()))
    removeDir(home)

suite "skill install lock (S12)":

  test "an install refuses while another process holds the lock":
    let home = freshHome("lockheld")
    createDir(home / "plugins")
    # A fresh lock: another process is publishing right now, not a leftover.
    writeFile(home / "plugins" / "cachefx.lock", "pid 4242\n")
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert not res.ok
    assert res.error.contains("cachefx.lock"), res.error
    assert not fileExists(home / "plugins" / "cachefx.so")
    removeDir(home)

  test "a neighbour skill's lock does not block this one":
    let home = freshHome("lockother")
    createDir(home / "plugins")
    writeFile(home / "plugins" / "neighbour.lock", "pid 7\n")
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert res.ok, "a neighbour's lock blocked this skill: " & res.error
    assert fileExists(home / "plugins" / "cachefx.so")
    removeDir(home)

  test "an install leaves no lock file behind":
    let home = freshHome("lockclean")
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert res.ok, res.error
    # A leaked lock would block every later install for the whole wait.
    assert not fileExists(home / "plugins" / "cachefx.lock")
    removeDir(home)

  test "a stale lock does not block a later install":
    let home = freshHome("lockstale")
    createDir(home / "plugins")
    let lockFile = home / "plugins" / "cachefx.lock"
    writeFile(lockFile, "pid 1\n")
    # Backdate it past the stale bound: whoever took it is long gone.
    setLastModificationTime(lockFile,
      getTime() - initDuration(milliseconds = installLockStaleMs + 1_000))
    let res = installCompiledSkill(manifest(), home, home / "build")
    assert res.ok, "a stale lock blocked the install: " & res.error
    assert fileExists(home / "plugins" / "cachefx.so")
    assert not fileExists(lockFile), "the stale lock was never cleaned up"
    removeDir(home)

  test "an install needs no lock when the target holds this library":
    let home = freshHome("lockfree")
    let first = installCompiledSkill(manifest(), home, home / "build")
    assert first.ok and not first.replaced
    # The target already holds this exact library, so a lock another
    # process is holding must not be waited on at all.
    writeFile(home / "plugins" / "cachefx.lock", "pid 99\n")
    let second = installCompiledSkill(manifest(), home, home / "build")
    assert second.ok, "a cache hit waited on the install lock: " & second.error
    assert not second.replaced
    assert second.soPath == first.soPath
    removeDir(home)
