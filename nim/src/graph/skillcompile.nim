## Skill compiler — validated graph → .so in a child process (T3).
##
## compileSkillGraph validates the manifest (skillgraph is the security
## boundary), generates the Nim source (skillgen's fixed template), and
## runs `nim c --app:lib` as a child process with a timeout and a minimal
## environment — the child never inherits the parent's secrets.
## The child's combined output is drained WHILE it runs (S11): reading only
## after `waitForExit` lets a child that writes more than the pipe buffer
## block on write forever, and the deadlock was reported as a "compile
## timeout" — a diagnosis naming the wrong subsystem. The captured output is
## bounded, so a compiler that never stops writing cannot exhaust memory.
## Every failure is an error result, never a raise into the caller's turn.

import std/json
import std/os
import std/osproc
import std/posix  # select() on the child's pipe; the target is linux-only
import std/strtabs
import std/strutils
import std/times

import ./skillgraph
import ./skillgen

const defaultTimeoutMs* = 60_000
  ## One minute is generous for a single-file template compile; a child
  ## still running past it is killed, never waited on forever.

const maxCapturedOutputBytes* = 16 * 1024
  ## How much of the child's output an error message may carry: the last
  ## 16 KB. A real error dump is far smaller and its tail is the part that
  ## names the failure; a hostile compiler gets a fixed budget, not the heap.

const drainPollMs = 20
  ## Longest single wait on the pipe. Bounds how late an exit or the
  ## deadline is noticed, and how long a final drain may sit on a quiet
  ## pipe, so a grandchild holding the write end cannot stall the parent.

const readChunkBytes = 8 * 1024

type
  SkillCompileResult* = object
    ok*: bool
    soPath*: string
    error*: string

  CapturedOutput = object
    ## The child's output, bounded to its tail. `totalBytes` counts
    ## everything read so the truncation note can say what was cut.
    text: string
    totalBytes: int
    truncated: bool

proc addCaptured(captured: var CapturedOutput, chunk: string) =
  captured.totalBytes += chunk.len
  captured.text.add(chunk)
  if captured.text.len > maxCapturedOutputBytes:
    captured.truncated = true
    captured.text = captured.text[^maxCapturedOutputBytes .. ^1]

proc boundedText(captured: CapturedOutput): string =
  ## What an error message may quote. The marker is part of the shape: an
  ## error that silently stops mid-line would look like the whole story.
  let tail = captured.text.strip()
  if captured.truncated:
    result = "[compiler output truncated: kept the last " &
      $maxCapturedOutputBytes & " of " & $captured.totalBytes &
      " bytes]\n" & tail
  else:
    result = tail

proc waitReadable(fd: cint, waitMs: int): bool =
  ## True when the pipe has data or is at end of file within `waitMs`.
  ## `select` is what keeps the drain loop off a blocking read: a blocking
  ## read with no output would sail past the compiler deadline.
  var readSet: TFdSet
  FD_ZERO(readSet)
  FD_SET(fd, readSet)
  var timeout = Timeval(tv_sec: posix.Time(waitMs div 1000),
                        tv_usec: Suseconds((waitMs mod 1000) * 1000))
  result = select(fd + 1, addr readSet, nil, nil, addr timeout) > 0

proc drainChunk(fd: cint, captured: var CapturedOutput, waitMs: int): bool =
  ## Wait up to `waitMs` for output and append at most one chunk of it.
  ## False means the pipe stayed quiet or hit end of file; the caller owns
  ## the clock, so it decides whether that is a timeout or just a pause.
  if not waitReadable(fd, waitMs):
    return false
  var buffer = newString(readChunkBytes)
  let got = posix.read(fd, addr buffer[0], buffer.len)
  if got <= 0:
    return false
  captured.addCaptured(buffer[0 ..< got])
  result = true

proc drainRemaining(fd: cint, captured: var CapturedOutput) =
  ## Read what the child already wrote, then stop at EOF or at the first
  ## quiet window — a surviving grandchild may hold the pipe open, and the
  ## parent must never wait on that.
  while drainChunk(fd, captured, drainPollMs):
    discard

proc minimalEnv(): StringTableRef =
  ## The child's whole environment: PATH so nim can find its own tools
  ## (cc, ld), HOME so nim can resolve its per-user config/cache, and
  ## nothing else — no API keys, no WAKU_* secrets ride into the compile.
  result = newStringTable(modeCaseSensitive)
  result["PATH"] = getEnv("PATH")
  result["HOME"] = getEnv("HOME")

proc compileSkillGraph*(manifest: JsonNode, workDir: string,
                        nimExe: string = "",
                        timeoutMs: int = defaultTimeoutMs):
    SkillCompileResult =
  ## Validate, generate, compile. `nimExe` empty means "find nim on PATH";
  ## an explicit path is used as-is (the tests inject fake compilers).
  ## Success: ok true + the .so path. Any failure: ok false + the reason,
  ## and no .so left behind for a failed compile.
  var graph: SkillGraph
  try:
    graph = validateSkillGraph(manifest)
  except SkillGraphError as exc:
    return SkillCompileResult(error: exc.msg)

  let nim = if nimExe.len > 0: nimExe else: findExe("nim")
  if nim.len == 0:
    return SkillCompileResult(
      error: "nim compiler not found on PATH: skills stay in text mode")

  try:
    createDir(workDir)
  except OSError as exc:
    return SkillCompileResult(error: "cannot create work dir: " & exc.msg)

  # The child runs with `workDir` as its working directory, so every path
  # handed to it must be absolute: a relative one resolves inside the work
  # dir, where the parent never wrote the source. The dashboard's default
  # home is ".waku", and the live smoke hit exactly this shape -
  # "cannot open '.waku/skills-build/…/greeter.nim'" — because the test
  # suites always used temp-dir absolute homes.
  let absWorkDir = absolutePath(workDir)
  let nimFile = absWorkDir / graph.name & ".nim"
  let soFile = absWorkDir / graph.name & ".so"
  try:
    writeFile(nimFile, generateSkillNim(graph))
  except IOError as exc:
    return SkillCompileResult(error: "cannot write generated source: " & exc.msg)

  let args = @["c", "--app:lib", "--panics:off", "--hints:off",
               "-o:" & soFile, nimFile]
  var process: Process
  try:
    process = startProcess(nim, workDir, args, minimalEnv(),
      {poStdErrToStdOut, poUsePath})
  except OSError as exc:
    return SkillCompileResult(error: "cannot start compiler: " & exc.msg)

  # Drain and watch the clock in one loop: the child can never block on a
  # full pipe, and a child that hangs is still killed on time.
  let outputFd = cint(process.outputHandle())
  var captured: CapturedOutput
  var timedOut = false
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while true:
    if process.peekExitCode() != -1:
      break
    if epochTime() > deadline:
      if process.peekExitCode() == -1:
        timedOut = true
        try:
          process.kill()
        except OSError:
          discard  # it exited as the deadline passed; the verdict stands
      break
    let remainingMs = int((deadline - epochTime()) * 1000.0)
    discard drainChunk(outputFd, captured, min(remainingMs, drainPollMs))
  drainRemaining(outputFd, captured)
  let code = process.waitForExit()
  process.close()

  if timedOut:
    if fileExists(soFile):
      removeFile(soFile)
    return SkillCompileResult(
      error: "compile timeout after " & $timeoutMs & "ms: child killed")
  let output = captured.boundedText()
  if code != 0:
    if fileExists(soFile):
      removeFile(soFile)
    return SkillCompileResult(
      error: "compiler exited " & $code & ": " & output)
  if not fileExists(soFile):
    return SkillCompileResult(
      error: "compiler exited 0 but produced no .so: " & output)
  result = SkillCompileResult(ok: true, soPath: soFile)
