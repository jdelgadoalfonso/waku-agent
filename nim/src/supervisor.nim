## Supervisor — lot 1 T1.2: spawn one worker, supervise, fail open.
##
## Reuses the `tools.runProcess` deadline pattern (sleep 50ms, kill on
## deadline, `timedOut`, exit 124 on kill, 127 when the binary is
## missing) but carries the task on stdin, because a worker reads one
## task line and emits child lines on stdout (see `delegation.nim`).
## Tests inject `WorkerRunner`; the binary passes `defaultWorkerRunner`
## for the live path. No network, no waiting in tests.

import std/json
import std/monotimes
import std/os
import std/osproc
import std/streams
import std/strutils
import std/times

import ./delegation
import ./tools

type
  WorkerRunner* = proc(argv: seq[string], stdinText: string,
      timeoutSec: int): tuple[res: ProcResult, pid: int] {.closure.}
    ## Run one worker to completion. Tests inject recordings; live
    ## code passes `defaultWorkerRunner`. The `pid` is the observed
    ## child pid (0 when unknown): the parent stamps it on receipt.

  WorkerOutcome* = object
    timedOut*: bool
    exitCode*: int
    childLines*: seq[JsonNode]
    malformed*: int
    shouldFailOpen*: bool
    error*: string
    pid*: int

proc collectChildLines*(output: string): tuple[lines: seq[JsonNode],
    malformed: int] =
  ## Split stdout into lines, keep valid child lines, count the rest.
  ## Blank lines are ignored (never malformed); bad JSON or a failed
  ## `parseChildLine` counts once each.
  var lines: seq[JsonNode] = @[]
  var bad = 0
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len == 0:
      continue
    var node: JsonNode
    try:
      node = parseJson(line)
    except JsonParsingError:
      inc bad
      continue
    var err = ""
    if parseChildLine(node, err):
      lines.add(node)
    else:
      inc bad
  (lines: lines, malformed: bad)

proc defaultWorkerRunner*(argv: seq[string], stdinText: string,
    timeoutSec: int): tuple[res: ProcResult, pid: int] =
  ## Live path: write the task line, wait to `timeoutSec`, kill past
  ## the deadline. Mirrors `tools.runProcess` outcomes. The `pid` is
  ## the observed child pid via `processID`, 0 when the child never
  ## started.
  if argv.len == 0:
    return (res: ProcResult(timedOut: false, code: 127, stdout: "",
      stderr: "no command"), pid: 0)
  var p: Process
  try:
    p = startProcess(argv[0], args = argv[1 .. ^1],
      options = {poUsePath})
  except OSError as exc:
    return (res: ProcResult(timedOut: false, code: 127, stdout: "",
      stderr: exc.msg), pid: 0)
  let observedPid = p.processID
  try:
    write(p.inputStream, stdinText & "\n")
    flush(p.inputStream)
    close(p.inputStream)
  except OSError, IOError:
    discard
  let deadline = getMonoTime() + initDuration(seconds = timeoutSec)
  while p.running and getMonoTime() < deadline:
    sleep(50)
  var timedOut = false
  var code = 0
  if p.running:
    try:
      p.kill()
    except OSError:
      discard
    timedOut = true
    code = 124
  else:
    code = p.waitForExit()
  var stdoutText = ""
  var stderrText = ""
  try:
    stdoutText = readAll(p.outputStream)
  except OSError, IOError:
    discard
  try:
    stderrText = readAll(p.errorStream)
  except OSError, IOError:
    discard
  p.close()
  (res: ProcResult(timedOut: timedOut, code: code, stdout: stdoutText,
    stderr: stderrText), pid: observedPid)

proc runWorker*(argv: seq[string], task: JsonNode, timeoutSec: int,
    runner: WorkerRunner): WorkerOutcome =
  ## Supervise one worker turn. Fails open (caller runs the local
  ## loop) when the deadline fires, the exit is non-zero, or no valid
  ## child line arrived. The observed `pid` stamps every child line
  ## when non-zero (parent truth wins); zero keeps the child value.
  let run = runner(argv, $task, timeoutSec)
  let res = run.res
  let observedPid = run.pid
  var collected = collectChildLines(res.stdout)
  if observedPid != 0:
    for line in collected.lines.mitems:
      if line.kind == JObject:
        line["pid"] = %observedPid
  let failOpen = res.timedOut or res.code != 0 or
    collected.lines.len == 0
  var err = ""
  if res.timedOut:
    err = "worker timed out"
  elif res.code != 0:
    err = "worker exit code " & $res.code
  elif collected.lines.len == 0:
    err = "no valid child lines"
  WorkerOutcome(timedOut: res.timedOut, exitCode: res.code,
    childLines: collected.lines, malformed: collected.malformed,
    shouldFailOpen: failOpen, error: err, pid: observedPid)
