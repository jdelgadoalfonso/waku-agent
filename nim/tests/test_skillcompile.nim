## Skill compiler (T3): validated graph → .so in a child process.
##
## compileSkillGraph writes the generated Nim to a work dir and runs
## `nim c --app:lib` as a child process with a timeout and a minimal
## environment (no inherited secrets). Its combined output is drained WHILE
## it runs, so a child that dumps more than the pipe buffer is reported by
## its exit code instead of deadlocking and being called a timeout (S11).
## Every failure shape returns an error result, never raises into the
## caller's turn.

import std/json
import std/os
import std/strutils
import std/times
import std/unittest

import ../src/graph/skillcompile

proc validManifest(): JsonNode =
  %*{
    "name": "compiledfx",
    "abi": 1,
    "nodes": [
      {"name": "summarize", "kind": "llm", "inKeys": ["message"],
       "outKey": "summary", "needs": ["llm"],
       "prompt": "Summarize: {{message}}"}
    ]
  }

suite "skill compiler child process":

  test "compiles a valid graph to an existing .so":
    let dir = getTempDir() / "waku-skillcompile-ok"
    if dirExists(dir):
      removeDir(dir)
    let res = compileSkillGraph(validManifest(), dir)
    assert res.ok, "compile failed: " & res.error
    assert res.soPath.len > 0
    assert fileExists(res.soPath)
    assert res.soPath.endsWith(".so")
    removeDir(dir)

  test "rejects an invalid graph without compiling":
    let dir = getTempDir() / "waku-skillcompile-invalid"
    createDir(dir)
    var bad = validManifest()
    bad["nodes"][0]["kind"] = %"tool"
    let res = compileSkillGraph(bad, dir)
    assert not res.ok
    assert res.error.len > 0
    # No .so and no generated source for a refused graph
    assert res.soPath == ""
    removeDir(dir)

  test "reports a missing nim compiler as an error result":
    let dir = getTempDir() / "waku-skillcompile-nonim"
    createDir(dir)
    # Auto-detect goes through findExe, which reads PATH: with PATH empty
    # there is no compiler to find, exactly like a machine without Nim.
    let savedPath = getEnv("PATH")
    putEnv("PATH", "")
    var res: SkillCompileResult
    try:
      res = compileSkillGraph(validManifest(), dir)
    finally:
      putEnv("PATH", savedPath)
    assert not res.ok
    assert res.error.contains("nim")
    assert res.soPath == ""
    removeDir(dir)

  test "timeout kills the child and reports an error":
    let dir = getTempDir() / "waku-skillcompile-timeout"
    createDir(dir)
    # 1 ms is below any real compile: the child must be killed, not waited.
    let res = compileSkillGraph(validManifest(), dir, timeoutMs = 1)
    assert not res.ok
    assert res.error.toLowerAscii().contains("timeout")
    removeDir(dir)

  test "compiler failure surfaces compiler output in the error":
    let dir = getTempDir() / "waku-skillcompile-badcc"
    createDir(dir)
    # /bin/false as the "compiler": exits non-zero, no .so produced.
    let falseExe = findExe("false")
    assert falseExe.len > 0
    let res = compileSkillGraph(validManifest(), dir, nimExe = falseExe)
    assert not res.ok
    assert not fileExists(dir / "compiledfx.so")
    removeDir(dir)

  test "exit 0 without a .so is its own error, with the output kept":
    let dir = getTempDir() / "waku-skillcompile-noso"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    # A compiler that claims success and writes nothing: the message must
    # name the missing artifact, not the exit code, and still quote the
    # child's own words.
    let scriptPath = dir / "nosobuild"
    writeFile(scriptPath, "#!/bin/sh\nprintf 'fake: nothing to build\\n'\nexit 0\n")
    setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec})
    let res = compileSkillGraph(validManifest(), dir, nimExe = scriptPath)
    assert not res.ok
    assert res.error.contains("no .so")
    assert res.error.contains("fake: nothing to build")
    assert not res.error.contains("truncated")
    removeDir(dir)

  test "output past the pipe buffer is drained, not reported as a timeout":
    let dir = getTempDir() / "waku-skillcompile-drain"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    # A real compiler error dump easily exceeds the ~64 KB pipe buffer. A
    # parent that reads only after `waitForExit` lets the child block on
    # write, so this case used to be killed and misreported as a timeout.
    # The generous timeoutMs is the point: only the deadlock can trip it.
    let scriptPath = dir / "spew"
    writeFile(scriptPath, """
#!/bin/sh
i=0
while [ $i -lt 20000 ]; do
  printf '%0256d\n' 0
  i=$((i + 1))
done
printf 'LAST-LINE-OF-ERROR\n'
exit 3
""")
    setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec})
    let res = compileSkillGraph(validManifest(), dir, nimExe = scriptPath,
                                timeoutMs = 10_000)
    assert not res.ok
    assert not res.error.toLowerAscii().contains("timeout")
    assert res.error.contains("exited 3")
    # The tail of the dump survives: a compiler's closing errors matter most.
    assert res.error.contains("LAST-LINE-OF-ERROR")
    assert not fileExists(dir / "compiledfx.so")
    removeDir(dir)

  test "captured compiler output is bounded and says it was truncated":
    let dir = getTempDir() / "waku-skillcompile-bound"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    let scriptPath = dir / "spew"
    writeFile(scriptPath, """
#!/bin/sh
i=0
while [ $i -lt 20000 ]; do
  printf '%0256d\n' 0
  i=$((i + 1))
done
printf 'LAST-LINE-OF-ERROR\n'
exit 3
""")
    setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec})
    let res = compileSkillGraph(validManifest(), dir, nimExe = scriptPath,
                                timeoutMs = 10_000)
    assert not res.ok
    # ~5 MB was written; the message keeps a bounded tail and names the cut.
    assert res.error.len <= maxCapturedOutputBytes + 512, $res.error.len
    assert res.error.contains("truncated")
    assert res.error.contains("LAST-LINE-OF-ERROR")
    removeDir(dir)

  test "timeout still kills a child that keeps writing":
    let dir = getTempDir() / "waku-skillcompile-timeout-spew"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    # Spew past the pipe buffer, then hang. Draining must not turn the
    # timeout into an endless wait, and the kill must still land.
    let scriptPath = dir / "spewthenhang"
    writeFile(scriptPath, """
#!/bin/sh
i=0
while [ $i -lt 4000 ]; do
  printf '%0256d\n' 0
  i=$((i + 1))
done
sleep 30
""")
    setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec})
    let started = epochTime()
    let res = compileSkillGraph(validManifest(), dir, nimExe = scriptPath,
                                timeoutMs = 300)
    let elapsed = epochTime() - started
    assert not res.ok
    assert res.error.toLowerAscii().contains("timeout")
    assert elapsed < 10.0, "the child was not killed: " & $elapsed & "s"
    assert not fileExists(dir / "compiledfx.so")
    removeDir(dir)

  test "child env does not inherit secrets":
    let dir = getTempDir() / "waku-skillcompile-env"
    if dirExists(dir):
      removeDir(dir)
    putEnv("WAKU_TEST_SECRET_LEAK", "do-not-leak")
    defer: delEnv("WAKU_TEST_SECRET_LEAK")
    # A fake "compiler" (executable script) that dumps its environment
    # to the .so path. nimExe points straight at it: no extra-args seam.
    createDir(dir)
    let scriptPath = dir / "envdump"
    writeFile(scriptPath,
      "#!/bin/sh\n# args: c --app:lib ... -o:<target> <source>\n" &
      "for a in \"$@\"; do case \"$a\" in -o:*) out=\"${a#-o:}\";; esac; done\n" &
      "env > \"$out\"\n")
    setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec})
    let res = compileSkillGraph(validManifest(), dir, nimExe = scriptPath)
    assert res.ok, "envdump failed: " & res.error
    let dumped = readFile(res.soPath)
    assert not dumped.contains("do-not-leak")
    assert not dumped.contains("WAKU_TEST_SECRET_LEAK")
    removeDir(dir)
