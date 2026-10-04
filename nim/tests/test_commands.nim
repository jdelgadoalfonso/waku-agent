## Slash-command tests: the pure table plus the chat dispatch with
## stubbed runners. Offline only: no agent is ever built on these paths
## (asserted), no browser, no sockets.

import std/json
import std/os
import std/strutils
import std/unittest

import ../src/commands
import ../src/config
import ../src/dashboard

proc freshHome(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc testBox(home: string): WakuBox =
  WakuBox(providers: @[], dotenvPath: "",
    settings: Settings(provider: "anthropic", home: home))

proc runSlash(message: string, home: string,
    connect: SlashConnectFn = nil,
    gather: SlashWorkflowFn = nil,
    triage: SlashWorkflowFn = nil): (bool, seq[string]) =
  var frames: seq[string] = @[]
  let box = testBox(home)
  let handled = runSlashCommand(message, box, proc(kind: string,
      ev: JsonNode) {.closure.} = frames.add(kind & ":" & $ev),
    connect, gather, triage)
  assert not box.built, "a slash path must never build the agent"
  (handled, frames)

proc doneOf(frames: seq[string]): JsonNode =
  for f in frames:
    if f.startsWith("done:"):
      return parseJson(f[5 .. ^1])
  raise newException(ValueError, "no done frame in " & $frames.len & " frames")

suite "commands table":
  test "parse takes the head, lowercases, keeps the rest":
    assert parseCommand("/gather") == (true, "gather", "")
    assert parseCommand("/triage thanks!") == (true, "triage", "thanks!")
    assert parseCommand("/Graphs") == (true, "graphs", "")
    assert parseCommand("  /connect google  ") == (true, "connect", "google")

  test "paths and prose are not commands":
    assert parseCommand("hello")[0] == false
    assert parseCommand("/ path")[0] == false
    assert parseCommand("see /gather")[0] == false
    assert parseCommand("")[0] == false

  test "a lone slash is an empty command, like Python":
    # `strip` runs before the `"/ "` guard there too, so `"/ "`
    # parses as `("", "")` and lands on the unknown-command reply.
    assert parseCommand("/ ") == (true, "", "")
    let (handled, frames) = runSlash("/",
      freshHome("waku-slash-lone"))
    assert handled == true
    assert "No workflow called" in doneOf(frames)["reply"].getStr()

  test "describe lists every table entry plus the router note":
    let text = describeCommands()
    assert "`/gather`" in text
    assert "`/triage`" in text
    assert "ROUTER" in text

  test "unknown names what exists":
    let text = unknownCommandReply("nope")
    assert "`/nope`" in text
    assert "`/gather`" in text
    assert "`/graphs`" in text

  test "workflow done composes digest, draft, errors and the ignored note":
    let done = composeWorkflowDone(%*{"digest": "morning",
      "draft_path": "outbox/x.txt",
      "errors": {"web": "boom"}}, "gather", 12)
    assert "morning" in done["reply"].getStr()
    assert "outbox/x.txt" in done["reply"].getStr()
    assert "web: boom" in done["reply"].getStr()
    assert done["workflow"].getStr() == "gather"
    assert done["latency_ms"].getInt() == 12

  test "an empty digest and an ignored argument answer honestly":
    let empty = composeWorkflowDone(newJObject(), "gather", 0)
    assert empty["reply"].getStr() == "(the workflow produced no text)"
    let ignored = composeWorkflowDone(%*{"digest": "d",
      "ignored_argument": "extra"}, "gather", 0)
    assert "takes no input" in ignored["reply"].getStr()
    assert "extra" in ignored["reply"].getStr()

suite "chat slash dispatch":
  test "prose is not handled":
    let (handled, _) = runSlash("hello",
      freshHome("waku-slash-prose"))
    assert handled == false

  test "/graphs answers without an agent":
    let (handled, frames) = runSlash("/graphs",
      freshHome("waku-slash-graphs"))
    assert handled == true
    assert "Graph workflows" in doneOf(frames)["reply"].getStr()

  test "unknown commands name what exists":
    let (handled, frames) = runSlash("/nope",
      freshHome("waku-slash-unknown"))
    assert handled == true
    assert "`/gather`" in doneOf(frames)["reply"].getStr()

  test "bare /connect prints usage, never a browser":
    let (handled, frames) = runSlash("/connect",
      freshHome("waku-slash-connectbare"))
    assert handled == true
    assert "available:" in doneOf(frames)["reply"].getStr()

  test "/connect delegates to the injected sign-in":
    let stub: SlashConnectFn =
      proc(arg, home: string): string = "stub:" & arg
    let (handled, frames) = runSlash("/connect google",
      freshHome("waku-slash-connect"), stub)
    assert handled == true
    assert doneOf(frames)["reply"].getStr() == "stub:google"

  test "/gather renders the workflow state":
    let stub: SlashWorkflowFn =
      proc(arg: string, emit: SseEmit): JsonNode =
        emit("node_start", %*{"node": "a"})
        %*{"digest": "morning"}
    let (handled, frames) = runSlash("/gather",
      freshHome("waku-slash-gather"), nil, stub)
    assert handled == true
    var kinds: seq[string] = @[]
    for f in frames:
      kinds.add(f.split(':')[0])
    assert "node_start" in kinds
    let done = doneOf(frames)
    assert done["reply"].getStr() == "morning"
    assert done["workflow"].getStr() == "gather"

  test "/gather with input says it was not used":
    let stub: SlashWorkflowFn =
      proc(arg: string, emit: SseEmit): JsonNode = %*{"digest": "morning"}
    let (handled, frames) = runSlash("/gather extra words",
      freshHome("waku-slash-gatherarg"), nil, stub)
    assert handled == true
    assert "takes no input" in doneOf(frames)["reply"].getStr()

  test "bare /triage prints its usage":
    let (handled, frames) = runSlash("/triage",
      freshHome("waku-slash-triagebare"))
    assert handled == true
    assert "needs a message" in doneOf(frames)["reply"].getStr()

  test "the non-stream chat answers slash without an agent":
    # Regression: `liveChatFn` built the agent before delegating to the
    # stream, so `/graphs` needed an API key. No key is set here and the
    # box must stay unbuilt.
    let box = testBox(freshHome("waku-slash-nonstream"))
    let reply = liveChatFn(box)("/graphs")
    assert "Graph workflows" in reply["reply"].getStr()
    assert not box.built

  test "/triage routes the message through the stub":
    let stub: SlashWorkflowFn =
      proc(arg: string, emit: SseEmit): JsonNode =
        assert arg == "thanks!"
        %*{"digest": "you are welcome"}
    let (handled, frames) = runSlash("/triage thanks!",
      freshHome("waku-slash-triage"), nil, nil, stub)
    assert handled == true
    let done = doneOf(frames)
    assert done["reply"].getStr() == "you are welcome"
    assert done["workflow"].getStr() == "triage"
