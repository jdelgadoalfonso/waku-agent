## Skill execution mode (T6): compiled plugin or text fallback.
##
## The Nim toolchain is optional at runtime: a machine without it keeps
## running skills exactly as today (the skill body in the prompt). This
## module is the one place that decides which mode a skill gets, so no
## caller has to know whether a compiler exists.

import std/json

import ./skillinstall

type
  SkillMode* = enum
    smText,    ## The skill body goes into the prompt (today's behaviour).
    smPlugin   ## An installed .so runs the skill as a worker.

  SkillExecution* = object
    skill*: string
    mode*: SkillMode
    pluginPath*: string
      ## The installed .so, empty in text mode.
    reason*: string
      ## Why text mode was chosen; always empty in plugin mode. This is
      ## what the dashboard/trace can show instead of failing silently.

proc resolvedSkillName(manifest: JsonNode): string =
  let n = manifest["name"]
  if n.kind == JString: n.getStr() else: ""

proc resolveSkillExecution*(manifest: JsonNode, home, workDir: string,
                            nimExe: string = "",
                            timeoutMs: int = 60_000): SkillExecution =
  ## Try the plugin path; fall back to text mode for every reason a
  ## compile cannot happen — no compiler, an invalid graph, a compile
  ## failure, a timeout, an install error. Failing to compile is never
  ## fatal: the skill still works the way it does today.
  result.skill = resolvedSkillName(manifest)
  let installed = installCompiledSkill(manifest, home, workDir, nimExe,
    timeoutMs)
  if installed.ok:
    return SkillExecution(skill: result.skill, mode: smPlugin,
      pluginPath: installed.soPath)
  result.mode = smText
  result.reason = installed.error

proc describeExecution*(e: SkillExecution): string =
  ## One line for a log or trace: never hides a fallback.
  if e.mode == smPlugin:
    return "skill '" & e.skill & "' runs as plugin " & e.pluginPath
  "skill '" & e.skill & "' stays in text mode: " & e.reason
