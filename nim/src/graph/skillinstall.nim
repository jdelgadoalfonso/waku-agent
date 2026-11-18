## Skill install (T5): a compiled skill joins the worker plugin channel.
##
## Installing copies the cached .so into `<home>/plugins/<manifest name>.so`
## — the one directory `pluginRunHeadless` and the worker resolver read —
## so a compiled skill runs headless with the same code path a hand-written
## plugin worker uses. The path stem MUST equal the manifest name: the
## worker route resolves `<home>/plugins/<name>.so` from the manifest name.
##
## Concurrency (S12): two turns installing the same skill would otherwise
## copy onto one target at once, and a reader could load half a library.
## The write is therefore guarded by a lock file beside the target, and the
## copy itself goes through a sibling temporary that is renamed into place
## — so even a reader that takes no lock sees a whole file. The lock is a
## lock FILE, not an in-process mutex: two turns can be two processes.

import std/json
import std/os
import std/times

when defined(posix):
  import std/posix

import ./skillcache
import ./skillgraph

const
  installLockWaitMs* = 2_000
    ## How long an install waits for another process's lock. The lock
    ## covers one file copy, measured in milliseconds, so waiting longer
    ## would only delay a turn that can fall back to text mode.
  installLockStaleMs* = 300_000
    ## A lock older than this is presumed abandoned (a process killed
    ## mid-copy) and is taken over. Minutes-old means nobody is coming
    ## back; the bound is far above the copy it guards.
  installLockPollMs = 25
    ## Poll interval while another process holds the lock.

type
  SkillInstallResult* = object
    ok*: bool
    soPath*: string
    recentlyCompiled*: bool
      ## This call compiled the skill (false on a cache hit).
    replaced*: bool
      ## A different library already sat at the install path, so a running
      ## process keeps serving the old one until restart (plugin contract).
    error*: string

proc installLockPath(pluginsDir, name: string): string =
  ## `<plugins>/<name>.lock`, beside the target it guards.
  pluginsDir / (name & ".lock")

proc createLockFile(path: string): bool =
  ## Exclusively create the lock: true only for the creator, so two
  ## installers can never both believe they own it. `open` with
  ## O_CREAT|O_EXCL is the atomic primitive; mkdir is its portable twin.
  when defined(posix):
    while true:
      let fd = posix.open(path.cstring, O_CREAT or O_EXCL or O_WRONLY, 0o644)
      if fd >= 0:
        discard posix.close(fd)
        return true
      if osLastError() == OSErrorCode(EINTR):
        continue
      return false
  else:
    result = createDir(path)

proc dropLockFile(path: string) =
  ## Release the lock. A missing lock is not an error: the stale escape
  ## may have taken ours over already.
  try:
    when defined(posix):
      removeFile(path)
    else:
      removeDir(path)
  except OSError:
    discard

proc lockAgeMs(path: string): int64 =
  ## How long ago the lock was created, in milliseconds.
  (getTime() - getLastModificationTime(path)).inMilliseconds

proc isStaleLock(path: string, staleMs: int): bool =
  ## True when a lock exists and is older than the bound, so its owner is
  ## gone. A lock that disappears mid-check is not stale: the next create
  ## attempt simply wins it.
  if not (fileExists(path) or dirExists(path)):
    return false
  try:
    result = lockAgeMs(path) > staleMs
  except OSError:
    result = false

proc acquireInstallLock(pluginsDir, name: string,
                        lockWaitMs, lockStaleMs: int):
    tuple[ok: bool, path: string, error: string] =
  ## Poll for the lock until `lockWaitMs` runs out. A lock older than
  ## `lockStaleMs` is abandoned, so it is removed and the wait continues
  ## instead of deadlocking every later install behind a crashed process.
  result = (ok: false, path: installLockPath(pluginsDir, name), error: "")
  let deadline = getTime() + initDuration(milliseconds = lockWaitMs)
  while true:
    if createLockFile(result.path):
      result.ok = true
      return
    if isStaleLock(result.path, lockStaleMs):
      dropLockFile(result.path)
      continue
    if getTime() >= deadline:
      result.error = "cannot install skill plugin: another process holds " &
        result.path & " (gave up after " & $lockWaitMs & "ms)"
      return
    sleep(installLockPollMs)

proc targetFromSkillCache*(target, home, name: string): bool =
  ## S25: true when the installed `<name>.so` matches a cached build of the
  ## same skill. A previous skill install always matches one
  ## `skills-compiled/<name>-<hash>.so` entry; a hand-written plugin matches
  ## none. Best-effort reads: an unreadable target or cache means "not from
  ## cache", which is the safe refusal side.
  try:
    if not fileExists(target):
      return false
    let want = readFile(target)
    # Sanitize exactly like skillCachePath does (skillName): the cache stem
    # drops everything but alnum/-/_ — and glob metacharacters with it — so
    # the raw name must never reach the pattern.
    let stem = skillName(%*{"name": name})
    for path in walkFiles(home / "skills-compiled" / (stem & "-*.so")):
      try:
        if readFile(path) == want:
          return true
      except IOError, OSError:
        discard
    false
  except OSError:
    false

proc installMarkerPath*(pluginsDir, name: string): string =
  ## `<plugins>/<name>.so.skill`: written by our installs under the lock,
  ## so provenance survives pruneSkillCache evictions (the HIGH OCR finding:
  ## the cache entry proving an install was ours is exactly what S24 evicts).
  pluginsDir / (name & ".so.skill")

proc installedBySkill*(target, home, pluginsDir, name: string): bool =
  ## True when the installed `<name>.so` came from a skill install: the
  ## marker beside the target says so, or — for installs predating markers —
  ## the target matches a cached build. A hand-written plugin matches neither.
  if fileExists(installMarkerPath(pluginsDir, name)):
    return true
  targetFromSkillCache(target, home, name)

proc holdsSameContent(target, source: string): bool =
  ## True when the target already carries exactly this library: the cheap
  ## path that must not take the lock at all.
  fileExists(target) and readFile(target) == readFile(source)

proc installCompiledSkill*(manifest: JsonNode, home, workDir: string,
                           nimExe: string = "", timeoutMs: int = 60_000):
    SkillInstallResult =
  ## Compile (or reuse the cache) and install into the plugin channel.
  ## A refused or failed compile touches nothing. Path stems equal the
  ## manifest name because the worker route resolves by manifest name.
  var graph: SkillGraph
  try:
    graph = validateSkillGraph(manifest)
  except SkillGraphError as exc:
    return SkillInstallResult(error: exc.msg)

  let compiled = compileOrLoadSkill(manifest, home, workDir, nimExe, timeoutMs)
  if not compiled.ok:
    return SkillInstallResult(error: compiled.error)

  let pluginsDir = home / "plugins"
  let target = pluginsDir / (graph.name & ".so")
  var locked = false
  var lockPath = ""
  try:
    createDir(pluginsDir)
    # A hit that is already installed is not a write: no lock, no copy.
    if holdsSameContent(target, compiled.soPath):
      return SkillInstallResult(ok: true, soPath: target,
        recentlyCompiled: compiled.recentlyCompiled, replaced: false)
    # S25: never silently overwrite a hand-written plugin. A previous skill
    # install carries the marker (or, pre-marker, matches a cached build)
    # and may be replaced; anything else is a manual file and refuses.
    if fileExists(target) and
        not installedBySkill(target, home, pluginsDir, graph.name):
      return SkillInstallResult(error: "cannot install skill '" & graph.name &
        "': plugins/" & graph.name &
        ".so already exists and did not come from the skill cache" &
        " (manual plugin with the same name)")

    let lock = acquireInstallLock(pluginsDir, graph.name,
      installLockWaitMs, installLockStaleMs)
    lockPath = lock.path
    if not lock.ok:
      return SkillInstallResult(error: lock.error)
    locked = true

    # Re-check under the lock: the process we waited for may have just
    # published exactly this library, which makes this a no-op, not a
    # replacement.
    if holdsSameContent(target, compiled.soPath):
      return SkillInstallResult(ok: true, soPath: target,
        recentlyCompiled: compiled.recentlyCompiled, replaced: false)
    if fileExists(target) and
        not installedBySkill(target, home, pluginsDir, graph.name):
      return SkillInstallResult(error: "cannot install skill '" & graph.name &
        "': plugins/" & graph.name &
        ".so already exists and did not come from the skill cache" &
        " (manual plugin with the same name)")
    let replaced = fileExists(target)
    publishArtifact(compiled.soPath, target)
    # Record provenance beside the target, under the same lock: the marker
    # is what future upgrades check first, so pruning the cache entry can
    # never turn a self-upgrade into a refusal. Best-effort: the copy above
    # already succeeded, so a marker failure degrades to the cache fallback
    # instead of failing the install.
    try:
      writeFile(installMarkerPath(pluginsDir, graph.name),
        skillCacheHash(manifest))
    except IOError, OSError:
      discard
    return SkillInstallResult(ok: true, soPath: target,
      recentlyCompiled: compiled.recentlyCompiled, replaced: replaced)
  except IOError, OSError:
    return SkillInstallResult(
      error: "cannot install skill plugin: " & getCurrentExceptionMsg())
  finally:
    if locked:
      dropLockFile(lockPath)
