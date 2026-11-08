## `delegate_env` pinned like `evals/deterministic/test_delegate_env.py`
## pins it: the helper's contracts, a REAL child process, and the spawn
## wiring. Offline only — no network, no key.
##
## A denylist that has quietly stopped working looks EXACTLY like one that
## works: the call still succeeds, the child still runs, nothing logs a
## warning. So the helper is asked what it returned, and a real witness
## process is asked what it can SEE — with its twin, the same witness under
## no policy, which is what makes the denial mean anything. Without the
## pair, a helper that returned an empty table, or one that stripped
## nothing at all, would pass just as happily.
##
## The last suite guards the wiring, the half most likely to rot: adding a
## spawn point is a one-line change and forgetting the policy is invisible
## at review. Python counts AST `subprocess.run/Popen` nodes across three
## files; this port funnels every delegate spawn through one of two seam
## fields (`PiSeams.run` for pi, `.runPy` for the auto-run), so the seam
## name is the call node and the count is the pin.

import std/[os, strtabs, strutils, unittest]

import ../src/experimental
import ../src/tools

const denyVar = "WAKU_DELEGATE_ENV_DENY"

proc packageDir(): string =
  ## The `nim/` folder, from this file's own path and never from the working
  ## directory, so the wiring pin reads the checkout it ships with from any
  ## cwd.
  currentSourcePath().parentDir / ".."

template withEnv(vars: openArray[tuple[key: string, value: string]],
                 body: untyped) =
  ## Set `vars` for the duration of `body`, then put every earlier value
  ## back — a pin must not leak its policy into the next one (the Python
  ## fixture's autouse `clean_policy` makes the same promise). A variable
  ## that did not exist before is unset again, not left set-but-empty.
  block:
    var saved: seq[tuple[key: string, existed: bool, old: string]] = @[]
    for (key, value) in vars:
      saved.add((key, existsEnv(key), getEnv(key)))
      putEnv(key, value)
    try:
      body
    finally:
      for (key, existed, old) in saved:
        if existed: putEnv(key, old)
        else: delEnv(key)

suite "delegate_env, the helper":
  test "no policy strips nothing":
    # Opt-in: with nothing configured, the delegate sees what it always saw.
    withEnv({"SOME_KEY": "value", denyVar: ""}):
      let env = liveDelegateEnv()
      assert env.hasKey("SOME_KEY")
      assert env["SOME_KEY"] == "value"

  test "the policy is read at call time, never cached":
    # A host application configures the policy after `import waku`, and a
    # value captured at module load would miss it — or go stale in a
    # long-running process. The three reads below are the whole claim.
    withEnv({"SECRET": "hunter2", denyVar: ""}):
      assert liveDelegateEnv().hasKey("SECRET")
      putEnv(denyVar, "SECRET")
      assert not liveDelegateEnv().hasKey("SECRET")
      delEnv(denyVar)
      assert liveDelegateEnv().hasKey("SECRET")

  test "vars the policy does not name survive":
    withEnv({"SECRET": "hunter2", "KEEP": "fine"}):
      let env = delegateEnv("SECRET")
      assert not env.hasKey("SECRET")
      assert env.hasKey("KEEP")
      assert env["KEEP"] == "fine"

  test "the policy var itself is never stripped":
    # A nested waku inside the delegate must inherit the same policy. Strip
    # the denylist itself and the second hop silently runs wide open.
    withEnv({"SECRET": "hunter2", denyVar: "SECRET"}):
      let env = liveDelegateEnv()
      assert not env.hasKey("SECRET")
      assert env.hasKey(denyVar)
      assert env[denyVar] == "SECRET"

  test "the list tolerates spaces and empty entries":
    withEnv({"A1": "x", "B2": "y", "C3": "z"}):
      let env = delegateEnv(" A1 , ,B2 ")
      assert not env.hasKey("A1")
      assert not env.hasKey("B2")
      assert env.hasKey("C3"), "an unnamed var did not survive"

  test "names match exactly, case included":
    # `WAKU_DELEGATE_ENV_DENY` is matched against the environment keys as
    # written; a differently cased name is a different name.
    withEnv({"MiXeD": "x"}):
      assert delegateEnv("mixed").hasKey("MiXeD")
      assert not delegateEnv("MiXeD").hasKey("MiXeD")

  test "naming a var that is not set is not an error":
    let env = delegateEnv("NEVER_SET_ANYWHERE")
    assert env.len > 0, "the copy came back empty"
    assert not env.hasKey("NEVER_SET_ANYWHERE")

proc witness(): string =
  ## The absolute path of `env`: it prints every variable the child was
  ## handed, which is what "the child can see it" means here. Empty when the
  ## platform has none, and the pins below skip instead of passing.
  findExe("env")

suite "a real child process":
  test "a denied var does not reach the child":
    let witnessBin = witness()
    if witnessBin.len == 0:
      echo "SKIP: no `env` binary to report what a child was given"
      skip()
    else:
      withEnv({"MY_SECRET": "hunter2", denyVar: "MY_SECRET"}):
        let child = runProcess(@[witnessBin], env = liveDelegateEnv())
        assert child.code == 0, child.stderr
        # Absent, not set-but-empty: an empty entry would still tell the
        # child the variable exists.
        assert "MY_SECRET=" notin child.stdout, child.stdout
        assert "MY_SECRET=hunter2" notin child.stdout, child.stdout
        # The policy rides along, so a nested waku inherits it.
        assert (denyVar & "=MY_SECRET") in child.stdout, child.stdout

  test "the control child normally can read it":
    # The twin that makes the test above mean something. Drop the policy
    # from the spawn and THIS one keeps passing while the one above fails —
    # which is exactly the signal we want.
    let witnessBin = witness()
    if witnessBin.len == 0:
      echo "SKIP: no `env` binary to report what a child was given"
      skip()
    else:
      withEnv({"MY_SECRET": "hunter2"}):
        let child = runProcess(@[witnessBin], env = delegateEnv(""))
        assert child.code == 0, child.stderr
        assert "MY_SECRET=hunter2" in child.stdout, child.stdout

proc spawnCalls(source: string): seq[string] =
  ## Every `seams.run(...)` / `seams.runPy(...)` call as one string, from
  ## the callee name through its balanced closing paren. Lines that are only
  ## a comment are dropped first, so prose that names a spawn is not counted
  ## as one (a trailing comment that spells one out would be; the file has
  ## none, and the count below fails loudly if that changes).
  var text = ""
  for line in source.splitLines():
    if line.strip().startsWith("#"):
      continue
    text.add(line)
    text.add('\n')
  var pos = 0
  while true:
    var start = -1
    for marker in ["seams.run(", "seams.runPy("]:
      let at = text.find(marker, pos)
      if at >= 0 and (start < 0 or at < start):
        start = at
    if start < 0:
      break
    var depth = 0
    var stop = text.find('(', start)
    while stop < text.len:
      if text[stop] == '(':
        inc depth
      elif text[stop] == ')':
        dec depth
        if depth == 0:
          break
      inc stop
    result.add(text[start .. stop])
    pos = stop + 1

suite "the spawn wiring":
  const spawnSource = "src/experimental.nim"

  const delegateSpawns = 3
    ## Two `delegate_task` spawns (json mode and plain) plus the auto-run
    ## python child. The Python eval counts 7 `subprocess.run/Popen` nodes
    ## across `experimental.py`, `workspace.py` and `coding_eval.py`; in
    ## this port every delegate spawn goes through `PiSeams.run`/`.runPy`,
    ## so three is the whole surface. A new spawn — even a correctly wired
    ## one — changes this number, which is the point: update the pin in the
    ## same change, deliberately.

  test "the scan finds a spawn, its policy, and its continuation":
    # The scanner is what the pins below rest on, so it is shown biting: two
    # spawns (one wrapped over two lines), a comment that names a third and
    # must not count.
    let sample = """
# seams.run(cmd, workdir, timeout) in prose is not a spawn
let a = seams.run(cmd, workdir, timeout, liveDelegateEnv())
let b = seams.runPy(@[py, entry],
  workdir, timeout, liveDelegateEnv())
"""
    let calls = spawnCalls(sample)
    assert calls.len == 2, $calls.len & " calls: " & $calls
    for call in calls:
      assert "liveDelegateEnv()" in call, call
    assert "entry" in calls[1], "the continuation was cut off: " & calls[1]

  test "the scan would catch a spawn without the policy":
    let calls = spawnCalls("let a = seams.run(cmd, workdir, timeout, nil)")
    assert calls.len == 1
    assert "liveDelegateEnv()" notin calls[0]
    assert "nil" in calls[0]

  test "every delegate spawn passes the live delegate env":
    let calls = spawnCalls(readFile(packageDir() / spawnSource))
    assert calls.len == delegateSpawns,
      $calls.len & " delegate spawn sites, expected " & $delegateSpawns
    for call in calls:
      assert "liveDelegateEnv()" in call,
        "spawn without the policy: " & call

  test "no delegate spawn leaks a raw environment copy":
    # `newStringTable()` filled from `envPairs()`, or a bare `env = nil`
    # that inherits everything, is the exact anti-pattern the helper
    # replaces: it looks deliberate, so it survives review.
    for call in spawnCalls(readFile(packageDir() / spawnSource)):
      assert "newStringTable" notin call,
        "spawn builds its own table: " & call
      assert "envPairs" notin call, "spawn copies the live environ: " & call
      assert "nil" notin call, "spawn inherits the environment: " & call

  test "no spawn bypasses the seam the count can see":
    # The premise of the count above: a direct `startProcess` in this module
    # would be invisible to it. `livePiSeams` itself is the seam's live
    # implementation and calls `runProcess`, not `startProcess`.
    let source = readFile(packageDir() / spawnSource)
    assert "startProcess" notin source
    assert "execProcess" notin source
