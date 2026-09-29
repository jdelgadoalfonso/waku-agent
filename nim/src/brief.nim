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
import std/times

import ./app

export app

const
  briefPrompt* = "Brief me on my week: what's on my calendar, what's in my mail that needs attention, and what I should focus on today."

proc runBrief*(w: var Waku): tuple[reply, path: string] =
  ## Respond through the harness, save the reply to
  ## `outbox/brief-<date>.txt`. Returns both. Creates the outbox (Python
  ## raises FileNotFoundError instead — hardening, documented).
  let res = w.respond(briefPrompt, source = "brief")
  let dest = w.settings.home / "outbox" /
    ("brief-" & format(now(), "yyyy-MM-dd") & ".txt")
  createDir(parentDir(dest))
  writeFile(dest, res.reply & "\n")
  return (res.reply, dest)
