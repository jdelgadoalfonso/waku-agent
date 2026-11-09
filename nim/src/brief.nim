## Brief — port of `waku/ops/brief.py`: the morning briefing as a loop turn.
##
## The same job as gather, done as a LOOP: one prompt in, the model decides
## which tools to call. Both ship; reading them side by side is the point.
## This just kicks off the turn (through the normal harness, so it traces
## and animates like any turn) and saves the result to the outbox.
##
## Python prints a tip when `WAKU_APPLE_TOOLS` is off; that switch is a
## phase-5 setting, so the tip waits with it. Console printing is 4e's
## (CLI dispatch); this module returns what to print and where it landed.

import std/os
import std/strutils
import std/times

import ./app

export app

const
  briefPrompt* = "Brief me on my week: what's on my calendar, what's in my mail that needs attention, and what I should focus on today."

proc runBriefHeadless*(w: var Waku, model = "",
    memoryText = ""): string =
  ## Headless briefing for a worker turn (T3): the loop answers, nothing
  ## is filed. `model` overrides the worker's model for this turn only;
  ## `memoryText` becomes the turn's retrieval backend, so the parent's
  ## read-only snapshot (T21-D) reaches the loop exactly where wired
  ## memory would land. The app is the worker's own and discarded after
  ## the turn, so neither write escapes it.
  if model.len > 0:
    w.settings.model = model
  if memoryText.strip().len > 0:
    let snapshot = memoryText
    w.session.retrieve = proc(msg: string, notify: Observer): string =
      snapshot
  w.respond(briefPrompt, source = "brief").reply

proc runBrief*(w: var Waku): tuple[reply, path: string] =
  ## Respond through the harness, save the reply to
  ## `outbox/brief-<date>.txt`. Returns both. Creates the outbox (Python
  ## raises FileNotFoundError instead — hardening, documented).
  let reply = runBriefHeadless(w)
  let dest = w.settings.home / "outbox" /
    ("brief-" & format(now(), "yyyy-MM-dd") & ".txt")
  createDir(parentDir(dest))
  writeFile(dest, reply & "\n")
  return (reply, dest)
