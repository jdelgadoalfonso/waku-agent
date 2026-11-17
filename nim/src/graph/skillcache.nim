## Skill compile cache (T4): content-hashed .so reuse.
##
## The cache key is a canonical form of the graph (object keys sorted
## recursively), so two manifests that say the same thing share one
## compiled .so. A cache hit never invokes the compiler: that is what
## makes the second turn of a loop cheap.
##
## Concurrency (S12, S13): two turns — often two different processes — can
## be compiling and installing the same skill at once, so no path here may
## come from the name alone. The work directory is per COMPILE
## (`<name>-<hash>-<pid>-<serial>`): the hash says which graph, the pid and
## the call counter say which run, so two compiles of one graph never share
## a source or an output path — uniqueness replaces a lock. The cached
## artifact is still published by renaming a sibling temporary onto the
## final path: a reader sees the old file or the whole new one, never half
## a library, and of two publishers the last one wins.

import std/json
import std/os
import std/strutils

import ./skillcompile

type
  SkillCacheResult* = object
    ok*: bool
    soPath*: string
    recentlyCompiled*: bool
      ## True when this call ran the compiler; false on a cache hit.
    error*: string

var workDirSerial: uint64 = 0
  ## Second half of the work-directory discriminator: a process-wide call
  ## counter. It is bumped by `skillWorkDir` and therefore only by a
  ## compile, never by a cache hit — a hit takes no scratch directory at
  ## all. A process serves its turns one at a time, so a plain counter is
  ## enough to make each compile inside it distinct.

proc fnv1a64(text: string): uint64 =
  ## FNV-1a 64: small, dependency-free and stable across Nim versions,
  ## which is all a cache key needs (this is not a security boundary —
  ## the graph was already validated before it got here).
  const offsetBasis = 0xcbf29ce484222325'u64
  const prime = 0x100000001b3'u64
  result = offsetBasis
  for c in text:
    result = result xor uint64(uint8(c))
    result = result * prime

proc canonicalWrite(node: JsonNode, outp: var string) =
  ## Write `node` canonically: object keys sorted, arrays in order.
  case node.kind
  of JObject:
    var keys: seq[string] = @[]
    for key in node.keys:
      keys.add(key)
    # strict ascending sort; the graph is small, insertion sort is fine
    # and keeps `algorithm` out of the imports
    for i in 1 ..< keys.len:
      var j = i
      while j > 0 and keys[j - 1] > keys[j]:
        let tmp = keys[j - 1]
        keys[j - 1] = keys[j]
        keys[j] = tmp
        dec j
    outp.add("{")
    for i, key in keys:
      if i > 0:
        outp.add(",")
      outp.add($ %key)
      outp.add(":")
      canonicalWrite(node[key], outp)
    outp.add("}")
  of JArray:
    outp.add("[")
    for i in 0 ..< node.len:
      if i > 0:
        outp.add(",")
      canonicalWrite(node[i], outp)
    outp.add("]")
  else:
    outp.add($node)

proc canonicalGraphJson*(manifest: JsonNode): string =
  ## Canonical serializer: object keys sorted recursively, arrays in
  ## order. Two manifests that mean the same thing serialize identically.
  result = ""
  canonicalWrite(manifest, result)

proc skillName(manifest: JsonNode): string =
  ## The manifest name, or "skill" when absent (validation reports the
  ## real problem; the cache path just needs a file-safe stem).
  let n = manifest["name"]
  if n.kind == JString and n.getStr().len > 0:
    var safe = ""
    for c in n.getStr():
      if c.isAlphaNumeric or c in {'-', '_'}:
        safe.add(c)
    if safe.len > 0:
      return safe
  "skill"

proc skillCacheHash*(manifest: JsonNode): string =
  ## FNV-1a 64 of the canonical graph as 16 hex digits. The cache entry
  ## and the per-compile work directory both carry it.
  fnv1a64(canonicalGraphJson(manifest)).toHex(16)

proc skillCachePath*(home: string, manifest: JsonNode): string =
  ## `<home>/skills-compiled/<name>-<hash>.so`.
  home / "skills-compiled" /
    (skillName(manifest) & "-" & skillCacheHash(manifest) & ".so")

proc skillWorkDir*(workDir: string, manifest: JsonNode): string =
  ## `<workDir>/<name>-<hash>-<pid>-<serial>`: one scratch directory per
  ## COMPILE, not per graph. The pid separates two processes; a
  ## process-wide serial separates two calls inside one process (a pid can
  ## be reused after a wrap, a call counter inside a live process cannot
  ## repeat). The generated source and the .so the compiler produces both
  ## live inside it, so no two compiles ever write the same file — which
  ## is what made a half-written work .so copyable into the cache.
  inc workDirSerial
  workDir / (skillName(manifest) & "-" & skillCacheHash(manifest) &
    "-" & $getCurrentProcessId() & "-" & $workDirSerial)

proc skillWorkPaths*(workDir: string, manifest: JsonNode):
    tuple[source, so: string] =
  ## Both paths of ONE compile, allocated together: the generated source
  ## (skillcompile writes `<name>.nim`) and the `.so` the compiler writes
  ## (`-o:`), inside one fresh per-compile directory. They are returned as
  ## a pair on purpose — deriving them in separate calls would allocate
  ## two different directories and hand back a path no compile ever used.
  let dir = skillWorkDir(workDir, manifest)
  result = (source: dir / (skillName(manifest) & ".nim"),
            so: dir / (skillName(manifest) & ".so"))

proc artifactTempPath*(target: string): string =
  ## The temporary an artifact is written to before it is renamed onto
  ## `target`. It is a SIBLING of the target (same directory, so the
  ## final move is a rename and can never fall back to a cross-filesystem
  ## copy) and carries the pid, so two processes never share one.
  target & ".tmp-" & $getCurrentProcessId()

proc publishArtifact*(source, target: string) =
  ## Make `source` visible at `target` atomically: copy into the sibling
  ## temporary, then rename it onto the target. A reader — a cache hit, a
  ## plugin discovery scan — sees either the previous artifact or the
  ## complete new one. The temporary is never mistaken for an artifact
  ## either: it ends in `.tmp-<pid>`, not in `.so`. Raises only after the
  ## temporary is gone.
  let temp = artifactTempPath(target)
  copyFile(source, temp)
  try:
    moveFile(temp, target)
  except IOError, OSError:
    if fileExists(temp):
      try:
        removeFile(temp)
      except IOError, OSError:
        discard  # a leftover temporary is ugly, not dangerous
    raise

proc compileOrLoadSkill*(manifest: JsonNode, home, workDir: string,
                        nimExe: string = "", timeoutMs: int = 60_000):
    SkillCacheResult =
  ## Cache hit → the existing .so, no compiler run. Miss → validate and
  ## compile (skillcompile does both) in a work directory this call owns
  ## alone, then publish the .so into the cache. A refused or failed
  ## compile leaves no cache entry behind. The work .so stays in the work
  ## directory; the cache is the durable copy.
  let target = skillCachePath(home, manifest)
  if fileExists(target):
    return SkillCacheResult(ok: true, soPath: target, recentlyCompiled: false)

  let compiled = compileSkillGraph(manifest, skillWorkDir(workDir, manifest),
    nimExe, timeoutMs)
  if not compiled.ok:
    return SkillCacheResult(error: compiled.error)

  try:
    createDir(home / "skills-compiled")
    publishArtifact(compiled.soPath, target)
  except IOError, OSError:
    return SkillCacheResult(
      error: "cannot store compiled skill: " & getCurrentExceptionMsg())
  result = SkillCacheResult(ok: true, soPath: target, recentlyCompiled: true)
