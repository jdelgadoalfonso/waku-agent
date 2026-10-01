## Gateway infra, phase 7a — one runner policy + one lifecycle policy.
##
## Port of `waku/gateway/runner.py` (`GATEWAY_ERROR_REPLY`,
## `safe_exception`, the `GatewayAgentRunner` error/close accounting and
## `run_gateway_turn`) plus `waku/gateway/supervisor.py`
## (`GatewaySupervisor`: fingerprint, configured-check, reconcile with
## stop-then-start and rollback, shutdown, status).
##
## Everything async or threaded stays out on purpose: Python runs one
## thread-owned Waku per async gateway (a single-worker executor
## serializes turns and keeps one SQLite connection on one thread) and
## one daemon thread per background poller. The Nim port is synchronous
## and single-threaded (precedent: the MCP bridge in 6b computes the
## deadline without awaiting it): turns run inline through the injected
## `RespondFn`, and the live polling loops are a 7d follow-up. Same
## observable policy, no invented concurrency.
##
## Every side effect travels through an injected seam (`RespondFn` /
## `SendFn` / `LogFn` for turns; `StarterFn` / `StopFn` / `StatusFn` for
## lifecycle; `env` as a `Table`, never `os.environ`): zero network,
## zero threads, zero disk in tests. Health persistence (`record_health`
## in Python) stays with the caller — `integrations.nim` owns the store —
## so this module never touches disk.

import std/algorithm
import std/sequtils
import std/sets
import std/strutils
import std/tables

const
  gatewayErrorReply* =
    "Waku couldn't process that message. Check the dashboard terminal."
    ## What a chat partner receives when a turn blows up (Python's
    ## `GATEWAY_ERROR_REPLY` verbatim): no internals, no secrets.

# ── safe_exception ────────────────────────────────────────────────────

const secretSuffixes = ["_API_KEY", "_TOKEN", "_SECRET", "_PASSWORD"]

proc safeException*(excName, excMsg: string,
    env: Table[string, string]): string =
  ## Concise local diagnostic with configured credentials redacted.
  ## Port of `safe_exception`: values of env vars whose names end in a
  ## secret suffix and are at least 4 chars long are replaced longest
  ## first; an empty message becomes `"no details"`; the detail truncates
  ## at 500 chars. `env` is a parameter (never `os.environ`) so tests pin
  ## redaction without touching the process environment.
  var message = if excMsg.len > 0: excMsg else: "no details"
  var secrets: seq[string] = @[]
  for name, value in pairs(env):
    if value.len >= 4 and secretSuffixes.anyIt(name.toUpperAscii().endsWith(it)):
      secrets.add(value)
  secrets.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for secret in secrets:
    message = message.replace(secret, "***")
  return excName & ": " & message[0 ..< min(500, message.len)]

# ── runner state ──────────────────────────────────────────────────────

type
  RunnerState* = object
    ## The portable half of `GatewayAgentRunner`: which gateway this is,
    ## the last dashboard-visible error, and whether it is retired. The
    ## executor, the owned agent and its thread affinity are deliberately
    ## absent (no threads in this port, see the module header): the live
    ## loop owns the single Waku itself, and every live gateway hands its
    ## `RespondFn` through `accountedRespond` so the failure lands on this
    ## runner exactly where Python's `_respond` puts it.
    source*: string
    lastError*: string
    closed*: bool

proc newRunnerState*(source: string): RunnerState =
  ## A fresh runner for one gateway (`source` names it in every log).
  RunnerState(source: source, lastError: "", closed: false)

proc recordError*(r: var RunnerState, excName, excMsg: string,
    env: Table[string, string], action: string): string =
  ## Remember `action failed (<Name>) — see dashboard terminal` for the
  ## status line and return the redacted detail for the terminal log.
  ## Port of `GatewayAgentRunner.record_error`.
  let detail = safeException(excName, excMsg, env)
  r.lastError = action & " failed (" & excName & ") — see dashboard terminal"
  return detail

proc clearError*(r: var RunnerState) =
  ## A delivered reply clears the failure (port of `clear_error`).
  r.lastError = ""

proc errorStatus*(r: RunnerState): string =
  ## The dashboard-visible error, or `""` when healthy. Divergence:
  ## Python returns `None`; Nim has no nil string, and `""` is already
  ## the module's healthy sentinel (callers test `len == 0`).
  r.lastError

proc closeRunner*(r: var RunnerState) =
  ## Retire the runner: later turns raise instead of answering. Python
  ## also drains the executor and closes the agent's connection here;
  ## with no worker thread there is nothing to drain (7d owns that).
  r.closed = true

# ── run_gateway_turn ──────────────────────────────────────────────────

type
  RespondFn* = proc(text: string): string {.closure.}
    ## One agent turn: the live loop passes `waku.respond`; tests pass a
    ## script. Raises on failure, like `Waku.respond`.
  SendFn* = proc(text: string) {.closure.}
    ## Deliver one reply: the live loop passes `reply_text` / `reply` /
    ## the send API; tests record. Raises on delivery failure.
  LogFn* = proc(line: string) {.closure.}
    ## Terminal mirror (`you › …` / `waku › …` plus failure lines).

proc accountedRespond*(runner: var RunnerState, respond: RespondFn,
    env: Table[string, string] = initTable[string, string]()): RespondFn =
  ## Port of `GatewayAgentRunner._respond` (7d1): run one turn, remember a
  ## failure as `message handling` and let it propagate, exactly where
  ## Python records it. `runGatewayTurn` logs the failure and sends the
  ## error reply, but the STATUS the dashboard shows is recorded HERE, on
  ## the same runner — so every live gateway passes this as its
  ## `RespondFn` instead of its bare agent call. Without it a broken turn
  ## would be visible in the terminal and invisible in the dashboard.
  # A `var` parameter cannot be captured by a closure (Nim would not know
  # the caller keeps it alive), so the closure holds its address. Every
  # live gateway keeps the runner inside a `ref` handle, which outlives
  # the seam — the same invariant Python gets from the runner's own
  # lifetime.
  let self = addr runner
  result = proc(text: string): string {.closure.} =
    try:
      let reply = respond(text)
      self[].clearError()
      return reply
    except CatchableError as exc:
      discard self[].recordError($exc.name, exc.msg, env,
        "message handling")
      raise

proc runGatewayTurn*(runner: var RunnerState, text: string,
    respond: RespondFn, send: SendFn, logger: LogFn,
    env: Table[string, string] = initTable[string, string]()): bool =
  ## Run one agent turn, deliver it, and expose failures without secrets.
  ## Port of `run_gateway_turn`, synchronous: `true` means the partner got
  ## a reply. `respond` raising sends the error reply (a second failure
  ## there is recorded as `error reply delivery`); `send` raising is
  ## recorded as `reply delivery`; both log the redacted detail. A closed
  ## runner raises `CatchableError` (`"source gateway runner is closed"`, like
  ## Python's `RuntimeError`) naming its source.
  if runner.closed:
    raise newException(CatchableError,
      runner.source & " gateway runner is closed")
  logger("you › " & text)
  var reply: string
  try:
    reply = respond(text)
  except CatchableError as exc:
    logger("(" & runner.source & ") message handling failed: " &
      safeException($exc.name, exc.msg, env))
    try:
      send(gatewayErrorReply)
    except CatchableError as sendExc:
      let detail = runner.recordError($sendExc.name, sendExc.msg, env,
        "error reply delivery")
      logger("(" & runner.source & ") error reply delivery failed: " & detail)
    return false
  logger("waku › " & reply)
  try:
    send(if reply.len > 0: reply else: "(no reply)")
  except CatchableError as exc:
    let detail = runner.recordError($exc.name, exc.msg, env, "reply delivery")
    logger("(" & runner.source & ") reply delivery failed: " & detail)
    return false
  runner.clearError()
  return true

# ── supervisor ────────────────────────────────────────────────────────

type
  StarterFn* = proc(): bool {.closure.}
    ## Start one gateway: `true` means a live handle (Python returns the
    ## handle), `false` means it declined (`None` in Python — no token,
    ## extra missing — which reconcile reports as `gateway failed to
    ## start`). Raises when the start itself blows up. The live starters
    ## (background pollers) arrive in 7d; tests count calls and script
    ## outcomes.
  StopFn* = proc(key: string) {.closure.}
    ## Stop one gateway (`handle.stop()` in Python). Runs on the caller's
    ## thread, like the dashboard thread in Python.
  GatewayReport* = object
    ## One gateway's standing after reconcile/status. Maps to
    ## `IntegrationStatus` at the `integrations.nim` boundary (the caller
    ## maps `ok` to `connected` and `not ok` to `error` and persists via
    ## the health store): this module never touches disk.
    ok*: bool
    message*: string
  StatusFn* = proc(key: string): GatewayReport {.closure.}
    ## Read one running gateway (`handle.status()` in Python). Raising
    ## here becomes an error report, like Python's `status()`.
  EnvSnapshot* = object
    ## The exact environment a gateway started under, so a failed restart
    ## can bring the old instance back and then put the desired values
    ## back. `absent` matters: a var that was UNSET must be unset again,
    ## not set to `""` (Python stores `None` from `os.environ.get`).
    values*: Table[string, string]
    absent*: HashSet[string]
  Supervisor* = object
    ## Adapter-agnostic lifecycle manager (port of `GatewaySupervisor`).
    ## `running`/`fingerprints`/`snapshots` are the three dicts in Python;
    ## `stop` is a seam so tests observe ordering without threads.
    starters*: Table[string, StarterFn]
    envFields*: Table[string, seq[string]]
    stop*: StopFn
    running*: Table[string, bool]
    fingerprints*: Table[string, string]
    snapshots*: Table[string, EnvSnapshot]

proc newSupervisor*(starters: openArray[(string, StarterFn)],
    envFields: openArray[(string, seq[string])],
    stop: StopFn): Supervisor =
  ## Wire starters + the registry's env fields (Python builds the second
  ## from `INTEGRATIONS` rows with `reload == gateway` in the dashboard).
  ## `openArray` keeps call sites literal; the supervisor owns the tables.
  var st = initTable[string, StarterFn]()
  for (key, fn) in starters:
    st[key] = fn
  var ef = initTable[string, seq[string]]()
  for (key, fields) in envFields:
    ef[key] = fields
  Supervisor(starters: st, envFields: ef, stop: stop,
    running: initTable[string, bool](),
    fingerprints: initTable[string, string](),
    snapshots: initTable[string, EnvSnapshot]())

proc envFingerprint*(env: Table[string, string],
    fields: seq[string]): string =
  ## What a gateway was started under. Divergence: Python hashes the
  ## `\0`-joined values with SHA-256; a fingerprint is only ever compared
  ## for equality, so the joined string itself is the fingerprint here —
  ## same change detection, no crypto import for a comparison.
  var parts: seq[string] = @[]
  for f in fields:
    parts.add(env.getOrDefault(f, ""))
  return parts.join("\0")

proc isConfigured*(env: Table[string, string],
    fields: seq[string]): bool =
  ## The registry declares the token as the first gateway field: a gateway
  ## without its token is not configured (port of `_configured`).
  fields.len > 0 and env.getOrDefault(fields[0], "").len > 0

proc snapshotEnv*(env: Table[string, string],
    fields: seq[string]): EnvSnapshot =
  ## Capture the exact environment for rollback (present vs absent kept).
  result = EnvSnapshot(values: initTable[string, string](),
    absent: initHashSet[string]())
  for f in fields:
    if env.hasKey(f):
      result.values[f] = env[f]
    else:
      result.absent.incl(f)

proc restoreEnv*(env: var Table[string, string], snap: EnvSnapshot) =
  ## Put a snapshot back: present values return, absent names vanish.
  for name, value in pairs(snap.values):
    env[name] = value
  for name in snap.absent:
    env.del(name)

proc fieldsFor(sup: Supervisor, key: string): seq[string] =
  ## The registry fields for one gateway; unknown keys behave as
  ## unconfigured (ensure stopped) instead of raising `KeyError`.
  sup.envFields.getOrDefault(key, @[])

proc reconcile*(sup: var Supervisor, env: var Table[string, string],
    keys: seq[string], statusOf: StatusFn): Table[string, GatewayReport] =
  ## Bring gateways to their configured state (port of `reconcile`). An
  ## empty `keys` means every known starter, like Python's
  ## `keys or set(self._starters)`; sorted, so multi-gateway runs are
  ## deterministic (Python iterates a set). Unconfigured keys stop and are
  ## forgotten; a changed fingerprint restarts stop-THEN-start (gateway
  ## tokens cannot run concurrently); a failed start reports the error
  ## and rolls back — the old environment is temporarily restored, the
  ## old instance is brought back, then the desired environment returns.
  result = initTable[string, GatewayReport]()
  var wanted = keys
  if wanted.len == 0:
    for key in keys(sup.starters):
      wanted.add(key)
    wanted.sort()
  for key in wanted:
    if key notin sup.starters:
      result[key] = GatewayReport(ok: false,
        message: "unknown gateway: " & key)
      continue
    let fields = sup.fieldsFor(key)
    try:
      if not isConfigured(env, fields):
        if sup.running.getOrDefault(key, false):
          sup.stop(key)
        sup.running.del(key)
        sup.fingerprints.del(key)
        sup.snapshots.del(key)
        continue
      let fingerprint = envFingerprint(env, fields)
      if sup.running.getOrDefault(key, false) and
          sup.fingerprints.getOrDefault(key, "") == fingerprint:
        result[key] = statusOf(key)
        continue
      if sup.running.getOrDefault(key, false):
        sup.stop(key)
      if not sup.starters[key]():
        raise newException(ValueError, "gateway failed to start")
      sup.running[key] = true
      sup.fingerprints[key] = fingerprint
      sup.snapshots[key] = snapshotEnv(env, fields)
      result[key] = statusOf(key)
    except CatchableError as exc:
      sup.running.del(key)
      sup.fingerprints.del(key)
      if sup.snapshots.hasKey(key):
        let desired = snapshotEnv(env, fields)
        restoreEnv(env, sup.snapshots[key])
        try:
          if sup.starters[key]():
            sup.running[key] = true
            sup.fingerprints[key] = envFingerprint(env, fields)
        except CatchableError:
          discard
        restoreEnv(env, desired)
      result[key] = GatewayReport(ok: false, message: exc.msg)

proc supervisorStatus*(sup: Supervisor, key: string,
    statusOf: StatusFn): tuple[present: bool, report: GatewayReport] =
  ## One gateway's standing (`None` in Python when it is not running;
  ## here `present` is false). A raising status becomes an error report,
  ## like Python.
  if not sup.running.getOrDefault(key, false):
    return (false, GatewayReport(ok: false, message: ""))
  try:
    return (true, statusOf(key))
  except CatchableError as exc:
    return (true, GatewayReport(ok: false, message: exc.msg))

proc supervisorShutdown*(sup: var Supervisor) =
  ## Stop everything, forget everything (port of `shutdown`; a raising
  ## stop never blocks the rest).
  for key in keys(sup.running):
    try:
      sup.stop(key)
    except CatchableError:
      discard
  sup.running.clear()
  sup.fingerprints.clear()
  sup.snapshots.clear()
