## Experimental tools — `delegate_task` is live, the rest are honest stubs.
##
## Port of `waku/tools/experimental.py` (plus the `workspace.py` helpers
## delegation actually uses and `delegate_env` from `_env.py`). The pi
## subprocess runs through an injected `PiRunner`, so tests replay
## recordings and the binary shells to the real `pi`:
##
## - `_run_pi_json`'s threading/queue exists so a silent pi cannot eat
##   the deadline; here `runProcess` owns the deadline instead, and the
##   JSON event parsing (`message_update`/`message_end`/`turn_end` →
##   reply + tokens + cost) is the tested pure part. Subagent events
##   cannot stream live: `Tool.fn` takes no observer (the loop's
##   `wantsNotify` passthrough is still deferred), so the full transcript
##   lands in a log file instead — same words, after completion.
## - `sys.executable` has no meaning inside this binary: auto-run uses
##   `python3` from PATH (else `python`), documented where it happens.

import std/algorithm
import std/json
import std/monotimes
import std/os
import std/strtabs
import std/strutils
import std/tables
import std/times

import ./tools
import ./trace
import ./wire

const
  piInstallHint* = "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
  delegateTimeoutSec* = 300
  autorunTimeoutSec* = 30

  piProviders* = {"anthropic": "anthropic", "openai": "openai",
    "gemini": "google", "kimi": "moonshotai", "xai": "xai", "glm": "zai",
    "deepseek": "deepseek", "minimax": "minimax",
    "openrouter": "openrouter", "opencode_zen": "opencode_zen",
    "opencode_go": "opencode_go"}.toTable
    ## Waku provider id → pi's built-in provider id (`pi --list-models`).

  plannedTools* = [
    ("run_command", "Terminal tool",
     "Run a shell command in a sandbox and read the output — Hermes's 'Terminal' " &
     "tool. Needs a real sandbox + safety surface first."),
    ("browse_web", "Browser tool",
     "Open a page and read/click it — Hermes's 'Browser' tool. (search_web already " &
     "covers read-only web lookups.)"),
    ("schedule_task", "Cron Job",
     "Let the agent schedule its own recurring runs. Today `make brief` + a system " &
     "cron line already does scheduled runs; this would move it in-app."),
  ]
    ## Port of `PLANNED`: name → whiteboard box, still skeletons.

type
  PiRunner* = proc(argv: seq[string], workdir: string, timeoutSec: int,
      env: StringTableRef): ProcResult {.closure.}
    ## One pi (or python) subprocess, captured. `runProcess` is the live
    ## one; tests inject recordings.
  PiSeams* = object
    piBin*: string
      ## "" when pi is not installed (the honest early reply).
    jsonMode*: bool
      ## Whether this pi speaks `--mode json` (`_pi_supports_json` live).
    run*: PiRunner
    runPy*: PiRunner
      ## Auto-run for scratch entries (`python3 <entry>`, same shape).
    workspaceRoot*: string
      ## Resolved `WAKU_WORKSPACE` (live) — scratch folders land under it.
    pythonBin*: string
      ## `sys.executable` has no meaning here: `python3`, else `python`.
    autorunOff*: bool
      ## `WAKU_DELEGATE_AUTORUN` in 0/false/no (live).
    recordUsage*: proc(tin, tout: int) {.closure.}
      ## The arena's ledger line (`kind="subagent"`); nil skips it.
    projectFlags*: seq[string]
      ## `_project_pi_flags` live: this repo's extensions + skills ride
      ## along (empty in tests).

proc delegateEnv*(deny: string): StringTableRef =
  ## Copy of the process environment minus `WAKU_DELEGATE_ENV_DENY`
  ## (comma-separated, exact names). The deny var itself propagates, so
  ## a nested waku inside the delegate inherits the same policy.
  result = newStringTable()
  var denied: seq[string] = @[]
  for name in deny.split(','):
    if name.strip().len > 0:
      denied.add(name.strip())
  for key, value in envPairs():
    if key notin denied:
      result[key] = value

proc liveDelegateEnv*(): StringTableRef =
  ## The live policy: deny list read at call time, never cached.
  delegateEnv(getEnv("WAKU_DELEGATE_ENV_DENY"))

proc slugWords*(text: string, n: int): string =
  ## `[a-z0-9]+` runs, first `n` joined — or `"task"` when empty.
  var words: seq[string] = @[]
  var cur = ""
  for c in text.toLowerAscii():
    if c in {'a' .. 'z', '0' .. '9'}:
      cur.add(c)
    else:
      if cur.len > 0:
        words.add(cur)
        cur = ""
  if cur.len > 0:
    words.add(cur)
  if words.len == 0:
    return "task"
  return words[0 ..< min(n, words.len)].join("-")

proc newRunFolder*(root, model, task, stamp: string): string =
  ## A fresh dated run folder: `<root>/<date>/<HHMMSS>-<model>-<task>/`.
  ## `stamp` is `"yyyy-MM-dd/HHmmss"` joined (tests pin it; live stamps
  ## `now`). Mirrors `new_run_folder` (2-word model slug, full task slug).
  let parts = stamp.split('/')
  let folder = root / parts[0] / (parts[1] & "-" & slugWords(model, 2) &
    "-" & slugWords(task, 4))
  createDir(folder)
  return folder

proc createdFiles*(folder: string): seq[string] =
  ## Everything pi wrote, minus our own manifest/logs and caches, newest
  ## first — like `workspace.created_files`.
  const ours = ["MANIFEST.md", "run.log", "pi-transcript.log"]
  var files: seq[(string, int64)] = @[]
  for path in walkDirRec(folder):
    if not fileExists(path):
      continue
    let name = lastPathPart(path)
    if name in ours or "__pycache__" in path:
      continue
    files.add((path, toUnix(getLastModificationTime(path))))
  files.sort(proc(a, b: (string, int64)): int = cmp(b[1], a[1]))
  for (path, _) in files:
    result.add(path)

proc pickEntry*(files: seq[string]): string =
  ## The auto-run entry: `main/app/run/game.py`, else the file with a
  ## `__main__` guard, else the single `.py` — "" when nothing runnable.
  var py: seq[string] = @[]
  for f in files:
    if f.endsWith(".py"):
      py.add(f)
  if py.len == 0:
    return ""
  var byName = initTable[string, string]()
  for f in py:
    byName[lastPathPart(f)] = f
  for pref in ["main.py", "app.py", "run.py", "game.py"]:
    if byName.hasKey(pref):
      return byName[pref]
  for f in py:
    var text = ""
    try:
      text = readFile(f)
    except IOError:
      continue
    if "__main__" in text:
      return f
  if py.len == 1:
    return py[0]
  return ""

proc safeInt(n: JsonNode): int =
  ## Ledger numbers default to 0 when missing or mistyped.
  case n.kind
  of JInt: int(n.getBiggestInt())
  of JFloat: int(n.getFloat())
  else: 0

proc parsePiStream*(lines: seq[string]): tuple[reply: string, tin, tout: int,
    cost: float] =
  ## The `_run_pi_json` event parsing without the threads: `message_end`
  ## texts join into the reply, usage accumulates, `turn_end` closes the
  ## loop. Non-JSON lines are skipped, like Python.
  var texts: seq[string] = @[]
  for line in lines:
    var ev: JsonNode
    try:
      ev = parseJson(line)
    except JsonParsingError:
      continue
    if ev.kind != JObject:
      continue
    let kind = ev.jget("type").getStr()
    if kind == "message_end":
      let msg = ev.jget("message")
      if msg.jget("role").getStr() != "assistant":
        continue
      let usage = msg.jget("usage")
      result.tin += safeInt(usage.jget("input"))
      result.tout += safeInt(usage.jget("output"))
      result.cost += usage.jget("cost").jget("total").getFloat(0.0)
      for c in msg.jget("content"):
        if c.jget("type").getStr() == "text":
          let t = c.jget("text").getStr()
          if t.len > 0:
            texts.add(t)
  result.reply = texts.join("\n")

proc writeManifest*(folder, provider, model, task: string,
    files: seq[string],
    run: tuple[entry: string, code: int, output: string,
      secs: float]) =
  ## The dated MANIFEST beside the work, like `write_manifest` (`code`
  ## is always set here — the still-running shape stays in the reply).
  let stamp = lastPathPart(parentDir(folder)) & " " &
    lastPathPart(folder).split('-')[0]
  var lines = @["# Delegated coding run — " & stamp, "",
    "- Model: `" & provider & ":" & model & "`",
    "- Task: " & task, "", "## Files created"]
  if files.len == 0:
    lines.add("- (none)")
  for p in files:
    var size = 0
    try:
      size = int(getFileSize(p))
    except OSError:
      discard
    let rel = if p.startsWith(folder): p[folder.len + 1 .. ^1] else: p
    lines.add("- `" & rel & "` (" & $size & " bytes)")
  lines.add("")
  lines.add("## Auto-run: `python3 " & run.entry & "` — exit " &
    $run.code & " in " & $run.secs & "s")
  lines.add("")
  lines.add("```")
  lines.add(run.output[0 ..< min(2000, run.output.len)])
  lines.add("```")
  writeFile(folder / "MANIFEST.md", lines.join("\n") & "\n")

proc delegateTask*(seams: PiSeams, provider, model, home: string,
    task, cwd: string, timeoutSec, delegateTimeout: int,
    stamp: string): string =
  ## Port of `delegate_task`: real coding work goes to pi running
  ## locally. The return string says exactly what happened (done /
  ## failed / timed out / pi not installed); the full transcript lands
  ## in a log file either way.
  if task.strip().len == 0:
    return "delegate_task needs a 'task' — a plain-English description " &
      "of the coding job, e.g. 'fix the failing test in this repo'."
  if seams.piBin.len == 0:
    return "pi isn't installed, so I can't delegate. Install it with: " &
      piInstallHint
  var workdir = ""
  var inWorkspace = false
  if cwd.len > 0:
    workdir = expandTilde(cwd)
    if not dirExists(workdir):
      return "delegate_task: the working directory '" & cwd &
        "' doesn't exist."
  else:
    workdir = newRunFolder(seams.workspaceRoot,
      if model.len > 0: model else: provider, task, stamp)
    inWorkspace = true
  let timeout = if timeoutSec > 0: timeoutSec else: delegateTimeout
  var cmd = @[seams.piBin]
  if piProviders.hasKey(provider) and model.len > 0:
    cmd.add("--provider")
    cmd.add(piProviders[provider])
    cmd.add("--model")
    cmd.add(model)
  if seams.jsonMode:
    cmd.add("--mode")
    cmd.add("json")
  for flag in seams.projectFlags:
    cmd.add(flag)
  cmd.add("-p")
  cmd.add(task)
  cmd.add("-a")
  cmd.add("--no-session")
  var reply = ""
  var stderr = ""
  var rawLines: seq[string] = @[]
  var tin = 0
  var tout = 0
  var cost = 0.0
  var code = 0
  if seams.jsonMode:
    let res = seams.run(cmd, workdir, timeout, liveDelegateEnv())
    if res.timedOut:
      return "pi was still working after " & $timeout &
        "s so I stopped it — try a smaller task, or raise " &
        "WAKU_DELEGATE_TIMEOUT."
    stderr = res.stderr
    for line in res.stdout.splitLines():
      rawLines.add(line & "\n")
    let parsed = parsePiStream(rawLines)
    reply = parsed.reply
    tin = parsed.tin
    tout = parsed.tout
    cost = parsed.cost
    code = res.code
  else:
    let res = seams.run(cmd, workdir, timeout, liveDelegateEnv())
    if res.timedOut:
      return "pi was still working after " & $timeout &
        "s so I stopped it — try a smaller task, or raise " &
        "WAKU_DELEGATE_TIMEOUT."
    code = res.code
    reply = res.stdout
    stderr = res.stderr
  if not seams.recordUsage.isNil:
    seams.recordUsage(tin, tout)
  let transcript = if inWorkspace: workdir / "pi-transcript.log"
                   else: home / "outbox" /
                     "delegate-" & stamp.split('/')[1] & ".log"
  try:
    createDir(parentDir(transcript))
    var head = "$ " & cmd[0 ..< max(0, cmd.len - 4)].join(" ") &
      " -p " & task & "   (cwd: " & workdir & ")\n\n--- reply ---\n" &
      reply & "\n--- stderr ---\n" & stderr
    writeFile(transcript, head)
  except IOError:
    discard
  if rawLines.len > 0:
    try:
      let stem = transcript[0 ..< transcript.len - 4]
      writeFile(stem & "-events.jsonl", rawLines.join(""))
    except IOError:
      discard
  if code != 0:
    let tail = (if stderr.len > 0: stderr else: reply).strip()
    let err = (if tail.len > 0: tail else: "no output")
    return "pi hit an error: " & err[0 ..< min(200, err.len)] &
      " (full log: " & transcript & ")"
  var summary = reply.strip()
  if summary.len > 500:
    summary = summary[^500 .. ^1]
  if summary.len == 0:
    summary = "(pi finished but printed nothing)"
  if cost > 0.0:
    summary &= "\n(sub-agent spend: ~$" & formatFloat(cost, ffDecimal, 4) &
      ", logged to usage.jsonl)"
  if not inWorkspace:
    return "pi finished the delegated task in " & workdir & ".\n" &
      summary & "\n(full log: " & transcript & ")"
  let files = createdFiles(workdir)
  let made = block:
    var names: seq[string] = @[]
    for f in files[0 ..< min(6, files.len)]:
      names.add(lastPathPart(f))
    if names.len > 0: names.join(", ") else: "no files"
  var lines = @["pi finished. Files saved to " & workdir & " (" & made &
    ").", summary]
  var runEntry = ""
  var runCode = 0
  var runOut = ""
  var runSecs = 0.0
  var ran = false
  if not seams.autorunOff:
    let entry = pickEntry(files)
    if entry.len > 0:
      let t0 = getMonoTime()
      let res = seams.runPy(@[seams.pythonBin, lastPathPart(entry)],
        workdir, autorunTimeoutSec, liveDelegateEnv())
      runSecs = float((getMonoTime() - t0).inMilliseconds) / 1000.0
      runSecs = float(int(runSecs * 10)) / 10.0
      runEntry = lastPathPart(entry)
      if res.timedOut:
        runOut = "(still running after " & $autorunTimeoutSec &
          "s — likely interactive; stopped)"
      else:
        runCode = res.code
        runOut = (res.stdout & res.stderr).strip()
      ran = true
      try:
        writeFile(workdir / "run.log", "$ python3 " & runEntry &
          "\nexit: " & (if res.timedOut: "None" else: $runCode) &
          "\n\n" & runOut & "\n")
      except IOError:
        discard
  writeManifest(workdir, provider,
    if model.len > 0: model else: "(default)", task, files,
    (runEntry, runCode, runOut, runSecs))
  if ran:
    let verdict = if runCode == 0: "ran clean"
                  else: "exited " & $runCode
    lines.add("\nAuto-ran " & runEntry & ": " & verdict & " in " &
      $runSecs & "s.\n" & runOut[^min(400, runOut.len) .. ^1])
  return lines.join("\n")

proc makeDelegateTool*(seams: PiSeams, provider, model,
    home: string): Tool =
  ## Registry wiring for `delegate_task`. Timeout default and stamp
  ## resolve at call time (env + wall clock), like Python.
  Tool(name: "delegate_task",
    description: "Delegate a CODING task (fixing tests, multi-file " &
      "edits, writing programs) to pi, a specialist coding agent running " &
      "locally on this machine. Give it a self-contained task and, when " &
      "the work targets an existing project, that project's absolute " &
      "path as cwd. Use this for real programming work instead of " &
      "describing code in chat.",
    inputSchema: %*{"type": "object",
      "properties": {
        "task": {"type": "string",
                 "description": "Plain-English description of the coding job, self-contained"},
        "cwd": {"type": "string",
                "description": "Absolute path of the repo/directory to work in; omit for a scratch sandbox"},
        "timeout_seconds": {"type": "integer",
                            "description": "Max seconds to let pi work (default 300)"}},
      "required": ["task"]},
    wantsNotify: true,
    fn: proc(args: JsonNode): string =
      let timeout = block:
        let raw = getEnv("WAKU_DELEGATE_TIMEOUT")
        if raw.len > 0:
          try: parseInt(raw)
          except ValueError: delegateTimeoutSec
        else: delegateTimeoutSec
      delegateTask(seams, provider, model, home, strArg(args, "task"),
        strArg(args, "cwd"), intArg(args, "timeout_seconds", 0), timeout,
        format(now(), "yyyy-MM-dd/HHmmss")))

proc makeStubTool*(name, description, box: string): Tool =
  ## A coming-soon box: honest refusal pointing at the roadmap.
  Tool(name: name,
    description: "[coming soon] " & description,
    inputSchema: %*{"type": "object", "properties": {}},
    fn: proc(args: JsonNode): string =
      "'" & name & "' maps to the '" & box & "' box on the architecture " &
      "chart and isn't wired in yet — it's on the roadmap (coming " &
      "soon). Tell the user honestly.")

proc makeExperimentalTools*(seams: PiSeams, provider, model,
    home: string): seq[Tool] =
  ## `delegate_task` live plus the still-skeleton boxes, like
  ## `experimental.make_tools`.
  result.add(makeDelegateTool(seams, provider, model, home))
  for (name, box, description) in plannedTools:
    result.add(makeStubTool(name, description, box))

proc liveProjectFlags*(): seq[string] =
  ## This repo's own extensions + skills ride along (`_project_pi_flags`):
  ## walk up from the working directory so a delegated run started
  ## anywhere under the checkout carries them. No-op when absent.
  var dir = getCurrentDir()
  while true:
    var flags: seq[string] = @[]
    let exts = dir / ".pi" / "extensions"
    if dirExists(exts):
      var names: seq[string] = @[]
      for kind, path in walkDir(exts):
        if kind == pcFile and path.endsWith(".ts"):
          names.add(path)
      for name in sorted(names):
        flags.add("--extension")
        flags.add(name)
    let skills = dir / ".agents" / "skills"
    if dirExists(skills):
      flags.add("--skill")
      flags.add(skills)
    if flags.len > 0:
      return flags
    let parent = parentDir(dir)
    if parent == dir:
      return @[]
    dir = parent

proc livePiSeams*(home, provider, model: string): PiSeams =
  ## The live seams over real subprocesses. Real `pi`, real clock, the
  ## usage ledger behind `recordUsage` — never in tests.
  let piBin = findExe("pi")
  var jsonMode = false
  if piBin.len > 0:
    let probe = runProcess(@[piBin, "--help"], timeoutSec = 10)
    jsonMode = "--mode" in probe.stdout
  let pyBin = block:
    let p3 = findExe("python3")
    if p3.len > 0: p3 else: "python"
  let root = absolutePath(expandTilde(getEnv("WAKU_WORKSPACE",
    "waku_workspace")))
  PiSeams(piBin: piBin, jsonMode: jsonMode,
    run: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      runProcess(argv, workdir, timeoutSec, env),
    runPy: proc(argv: seq[string], workdir: string, timeoutSec: int,
        env: StringTableRef): ProcResult {.closure.} =
      runProcess(argv, workdir, timeoutSec, env),
    workspaceRoot: root, pythonBin: pyBin,
    autorunOff: getEnv("WAKU_DELEGATE_AUTORUN", "1") in
      ["0", "false", "no"],
    recordUsage: proc(tin, tout: int) {.closure.} =
      if tin == 0 and tout == 0:
        return
      let line = $(%*{"ts": utcStamp(), "provider": provider,
        "model": model, "kind": "subagent", "in": tin, "out": tout})
      try:
        createDir(home)
        let f = open(home / "usage.jsonl", fmAppend)
        f.writeLine(line)
        f.close()
      except IOError, OSError:
        discard,
    projectFlags: liveProjectFlags())
