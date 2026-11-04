## T4c-2 pins: the connection registry is DATA, and each half registers only
## the rows `data/integrations.toml` names for it.
##
## Offline: the document comes from the checkout, the behaviour table is
## injected, and `loadIntegrations` reads nothing else.
##
## The last suite is the headline of this unit. It reads BOTH halves' behaviour
## tables — Nim's here, Python's out of `waku/integrations.py` as text — and
## fails when one of them registers a key the registry file does not mark for
## it. Until `waku/` is retired that is the only thing that makes the
## `notion`/`obsidian` divergence loud instead of silent: the file carries BOTH
## rows, so a half that quietly drifts away from its own marker is a finding,
## not a preference.

import std/algorithm
import std/os
import std/sequtils
import std/strutils
import std/tables
import std/unittest

import ../src/integrations

const CheckoutRoot = ".."
  ## `nim/` is one level under the checkout, which is the working directory
  ## `nimble test` gives every suite.

const SimpleRegistry = """
[telegram]
halves = ["nim"]
group = "Channels"
name = "Telegram"
what = "Lets Waku receive and send Telegram messages."
setup_url = ""
reload = "gateway"

[[telegram.env]]
name = "TELEGRAM_BOT_TOKEN"
label = "Bot token"
required = true
secret = true
"""

proc checkoutPath(parts: varargs[string]): string =
  result = CheckoutRoot
  for part in parts:
    result = result / part

proc stubBehaviour(keys: openArray[string]): Table[string, IntegrationBehaviour] =
  ## Only `enabled` is ever missing from a refusal: the behaviour table is
  ## what the loader looks up, so a stub is enough to exercise one rule.
  result = initTable[string, IntegrationBehaviour]()
  for key in keys:
    result[key] = IntegrationBehaviour(enabled:
      (proc(env: Table[string, string], hostOs: string): bool {.closure.} = true))

proc keysOf(rows: seq[Integration]): seq[string] =
  rows.mapIt(it.key)

proc keysOf(rows: seq[IntegrationRow]): seq[string] =
  rows.mapIt(it.key)

proc rowOf(rows: seq[IntegrationRow], key: string): IntegrationRow =
  for row in rows:
    if row.key == key:
      return row
  raise newException(AssertionDefect, "no row named " & key)

proc refusal(load: proc(): seq[Integration]): string =
  ## Run one load and return the message it refused with. A load that returns
  ## is the failure: every case below exists to be refused.
  try:
    discard load()
  except ValueError as error:
    return error.msg
  raise newException(AssertionDefect, "this load was expected to refuse")

proc parseRefusal(text: string): string =
  ## The message `parseIntegrationRows` refuses a document with.
  try:
    discard parseIntegrationRows(text)
  except ValueError as error:
    return error.msg
  raise newException(AssertionDefect, "this document was expected to refuse")

proc pythonBehaviourKeys(): seq[string] =
  ## The keys of `_BEHAVIOUR` in `waku/integrations.py`, read as text.
  ##
  ## Deliberately text, not an import: the port cannot run Python, and this
  ## pin exists to speak for the half that is frozen but still in the tree.
  ## A missing file raises here, which is the loud failure a repo pin wants.
  var inTable = false
  for line in readFile(checkoutPath("waku", "integrations.py")).splitLines():
    if not inTable:
      # Structural rather than a literal annotation: the marker is the
      # assignment's SHAPE, so renaming `_Behaviour` (a cosmetic edit in the
      # frozen half) does not fail this pin.
      let marker = line.strip()
      inTable = marker.startsWith("_BEHAVIOUR") and marker.endsWith("{")
      continue
    let text = line.strip()
    if text == "}":
      break
    if not text.startsWith("\""):
      continue
    let close = text.find("\":")
    if close > 0:
      result.add(text[1 ..< close])
  sort(result)

suite "T4c-2 the registry file":
  test "is reachable from the checkout layout":
    let path = findIntegrationsToml()
    check path.len > 0
    check path.endsWith("data" / "integrations.toml")
    check fileExists(path)

  test "carries all 17 rows in the file's order":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    check rows.keysOf == @[
      "telegram", "discord", "whatsapp", "google_calendar", "gmail",
      "apple_calendar", "apple_tools", "notion", "obsidian", "mem0", "zep",
      "langmem", "supabase", "tavily", "treg", "typesafe", "otel"]

  test "reads the row fields the panel renders":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    let telegram = rows.rowOf("telegram")
    check telegram.group == "Channels"
    check telegram.name == "Telegram"
    check telegram.what.len > 0
    check telegram.extra == "telegram"
    check telegram.importName == "telegram"
    check telegram.setupUrl == "https://t.me/BotFather"
    check telegram.reload == gateway
    check telegram.env.len == 3
    check telegram.env[0].name == "TELEGRAM_BOT_TOKEN"
    check telegram.env[0].label == "Bot token"
    check telegram.env[0].required
    check telegram.env[0].secret
    check telegram.env[1].required == false
    check telegram.env[2].name == "WAKU_GRAPH_TELEGRAM"
    check telegram.env[2].kind == choiceField
    check telegram.env[2].options == @["loop", "triage", "gather"]
    check telegram.env[2].default == "loop"

  test "reads the choice and bool env fields":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    let discord = rows.rowOf("discord")
    check discord.env[3].name == "DISCORD_REQUIRE_MENTION"
    check discord.env[3].kind == boolField
    let notion = rows.rowOf("notion")
    check notion.env[0].kind == choiceField
    check notion.env[0].options == @["sqlite", "notion"]
    check notion.env[0].default == "sqlite"
    check notion.env[1].secret

  test "splits the halves as the file names them":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    check rows.rowOf("telegram").halves == @["python", "nim"]
    check rows.rowOf("notion").halves == @["python"]
    check rows.rowOf("obsidian").halves == @["nim"]

  test "refuses a key written twice, naming it":
    let message = parseRefusal("""[a]
halves = ["nim"]

[a]
halves = ["nim"]
""")
    check "twice" in message
    check "[a]" in message

  test "keeps a row's order when its env tables are interleaved":
    let rows = parseIntegrationRows("""[a]
halves = ["nim"]
group = "G"
name = "A"
what = "w"
setup_url = ""
reload = "agent"

[[a.env]]
name = "ONE"
label = "One"

[[a.env]]
name = "TWO"
label = "Two"

[b]
halves = ["nim"]
group = "G"
name = "B"
what = "w"
setup_url = ""
reload = "agent"

[[b.env]]
name = "THREE"
label = "Three"
""")
    check rows.keysOf == @["a", "b"]
    check rows.rowOf("a").env.mapIt(it.name) == @["ONE", "TWO"]
    check rows.rowOf("b").env.mapIt(it.name) == @["THREE"]

suite "T4c-2 loadIntegrations":
  test "registers the 14 rows this half owns, in the file's order":
    let rows = loadIntegrations(findIntegrationsToml(), "nim", BEHAVIOUR)
    check rows.keysOf == @[
      "telegram", "discord", "whatsapp", "google_calendar", "gmail",
      "apple_calendar", "apple_tools", "obsidian", "mem0", "zep", "langmem",
      "supabase", "tavily", "otel"]
    check INTEGRATIONS.keysOf == rows.keysOf

  test "drops the rows the file marks for the other half only":
    let keys = loadIntegrations(findIntegrationsToml(), "nim",
      BEHAVIOUR).keysOf
    for key in ["notion", "treg", "typesafe"]:
      check key notin keys

  test "keeps the behaviour the row had before it moved to data":
    let rows = loadIntegrations(findIntegrationsToml(), "nim", BEHAVIOUR)
    var telegram: Integration
    for row in rows:
      if row.key == "telegram":
        telegram = row
    check telegram.enabled != nil
    check telegram.enabled({"TELEGRAM_BOT_TOKEN": "x"}.toTable, "linux")
    check telegram.enabled({"TELEGRAM_BOT_TOKEN": ""}.toTable, "linux") == false
    var discord: Integration
    for row in rows:
      if row.key == "discord":
        discord = row
    check discord.normalize != nil

  test "a row for this half with no behaviour entry is refused, naming the key":
    let rows = parseIntegrationRows(SimpleRegistry)
    check "telegram" in refusal(proc(): seq[Integration] =
      registerIntegrations(rows, "nim", stubBehaviour([])))

  test "a behaviour entry with no row is refused, naming the key":
    let rows = parseIntegrationRows(SimpleRegistry)
    check "ghost" in refusal(proc(): seq[Integration] =
      registerIntegrations(rows, "nim", stubBehaviour(["telegram", "ghost"])))

  test "a row marked for no half is refused, naming the key":
    let rows = parseIntegrationRows("""[telegram]
group = "Channels"
name = "Telegram"
what = "w"
setup_url = ""
reload = "gateway"
""")
    check "telegram" in refusal(proc(): seq[Integration] =
      registerIntegrations(rows, "nim", stubBehaviour(["telegram"])))

  test "a half that is neither python nor nim is refused, naming it":
    let rows = parseIntegrationRows(SimpleRegistry.replace(
      """halves = ["nim"]""", """halves = ["rust"]"""))
    let message = refusal(proc(): seq[Integration] =
      registerIntegrations(rows, "nim", stubBehaviour(["telegram"])))
    check "telegram" in message
    check "rust" in message

  test "an env kind that is not text, bool or choice is refused":
    let document = SimpleRegistry.replace(
      "label = \"Bot token\"", "label = \"Bot token\"\nkind = \"toggle\"")
    check document != SimpleRegistry
    check "toggle" in parseRefusal(document)

  test "a reload that is not live, agent or gateway is refused":
    let document = SimpleRegistry.replace(
      "reload = \"gateway\"", "reload = \"boot\"")
    check document != SimpleRegistry
    check "boot" in parseRefusal(document)

  test "an env entry with no name is refused, naming the row":
    let document = SimpleRegistry.replace(
      "name = \"TELEGRAM_BOT_TOKEN\"\n", "")
    check document != SimpleRegistry
    check "telegram" in refusal(proc(): seq[Integration] =
      registerIntegrations(parseIntegrationRows(document), "nim",
        stubBehaviour(["telegram"])))

suite "T4c-2 startup is best effort":
  test "a registry path that does not exist is a reason, not a crash":
    # The regression this seam exists for: `INTEGRATIONS` was built by a
    # module-level `let`, so an unreachable registry raised during module
    # initialization and took every command with it, `--help` included.
    # The value now degrades to no rows plus the sentence a command prints.
    let (rows, error) = loadIntegrationsBestEffort(
      checkoutPath("data", "no-such-registry.toml"), "nim", BEHAVIOUR)
    check rows.len == 0
    check "integrations.toml" in error

  test "a found but contradictory registry is a reason, not an exception":
    # The loud refusals stay loud: a row marked for this half with no
    # behaviour entry is still refused, it just lands in the startup reason
    # instead of escaping as an unhandled exception at init.
    let (rows, error) = loadIntegrationsBestEffort(
      checkoutPath("data", "integrations.toml"), "nim", stubBehaviour([]))
    check rows.len == 0
    check "telegram" in error
    check "behaviour entry" in error

  test "what startup exported is either the rows or the reason, never both":
    check (INTEGRATIONS.len == 0) == (integrationRegistryError.len > 0)
    # And from the checkout, the shape that renders: the 14 rows, no reason.
    check INTEGRATIONS.len == 14
    check integrationRegistryError == ""

  test "an empty row list still refuses a behaviour table with entries":
    # Why the best-effort loader may not hand an empty row list to
    # `registerIntegrations`: with this half's behaviour table in hand, the
    # "entry with no row" rule fires. Degrading to no rows has to skip that
    # call, not sneak past it.
    check "telegram" in refusal(proc(): seq[Integration] =
      registerIntegrations(@[], "nim", stubBehaviour(["telegram"])))

suite "T4c-2 the two halves agree with the registry file":
  test "every row names a half, and no key is written twice":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    var seen: seq[string] = @[]
    for row in rows:
      check row.halves.len > 0
      for half in row.halves:
        check half in ["python", "nim"]
      check row.key notin seen
      seen.add(row.key)

  test "the Nim half registers exactly the rows the file marks for nim":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    var marked: seq[string] = @[]
    for row in rows:
      if "nim" in row.halves:
        marked.add(row.key)
    check BEHAVIOUR.keys.toSeq.sorted == marked.sorted
    check INTEGRATIONS.keysOf == marked

  test "the Python half's behaviour table registers exactly its marked rows":
    let rows = parseIntegrationRows(readFile(findIntegrationsToml()))
    var marked: seq[string] = @[]
    for row in rows:
      if "python" in row.halves:
        marked.add(row.key)
    sort(marked)
    check marked.len == 16
    check pythonBehaviourKeys() == marked
