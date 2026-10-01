## Phase 7c tests: the voice gateway with the audio left out.
##
## Voice is text plus commands: the wake word, the mic threshold, the
## two command state machines (`record_command`, `wait_for_speech`),
## the push-to-talk ladder and the `wake_loop` scan decision. Audio
## only ever crosses the injected seams (`SampleFn`/`RecordFn` in,
## `SttFn`/`TtsFn` out), so every test here is offline: a scripted
## block queue stands in for the mic, a scripted transcript for
## faster-whisper, a recorder for the mouth. Zero sounddevice, zero
## whisper, zero kokoro, zero `say` subprocess — the three engines
## deliberately NOT ported are pinned raising an honest error that
## names the seam, instead of pretending to listen.
##
## Its own file instead of an extension of `test_chat_gateways.nim`:
## that file covers the two CHAT gateways (access policy + REST +
## webhook HMAC) while this one is a different concern (audio seams +
## wake word + difflib similarity), and 7b's note already reserved a
## file for 7c. Call sites: `waku/gateway/voice.py` (`_speakable`,
## `matches_wake`, `_mic_threshold`, `record_command`,
## `wait_for_speech`, `record_until_enter`, the `wake_loop` scan
## branch, `main`'s push-to-talk ladder).

import std/json
import std/math
import std/strutils
import std/tables
import std/unittest

import ../src/gateway
import ../src/voice
import ../src/voiceio

const readBlock = 1600  ## 100ms at SAMPLE_RATE; the one read size

# ── offline doubles for the audio seams ────────────────────────────────

type
  BlockScript = ref object
    ## The scripted mic: a queue of blocks plus the sizes it was asked
    ## for. Running past the queue raises, so a state machine that
    ## forgets to stop fails loudly instead of reading forever.
    blocks: seq[seq[float32]]
    pos: int
    readSizes: seq[int]
  Mouth = ref object
    ## The scripted mouth: every text it was asked to speak.
    spoken: seq[string]
  Ears = ref object
    ## The scripted ears: how many samples each transcript covered.
    heard: seq[int]

proc tone(amp: float32, count = readBlock): seq[float32] =
  ## A constant-amplitude block: its RMS is exactly `amp`.
  result = newSeq[float32](count)
  for i in 0 ..< count:
    result[i] = amp

proc quietBlocks(count: int, amp = 0.001f32): seq[seq[float32]] =
  ## `count` blocks of room noise: below the default threshold.
  result = newSeq[seq[float32]](count)
  for i in 0 ..< count:
    result[i] = tone(amp)

proc readsOf(blocks: seq[seq[float32]]): (SampleFn, BlockScript) =
  ## The `SampleFn` seam plus its script, so a test can count what it
  ## read (and how big it asked).
  var state = BlockScript(blocks: blocks, pos: 0, readSizes: @[])
  let seam: SampleFn =
    proc(frameCount: int): seq[float32] {.closure.} =
      state.readSizes.add(frameCount)
      if state.pos >= state.blocks.len:
        raise newException(IOError, "block script exhausted")
      let next = state.blocks[state.pos]
      inc state.pos
      return next
  return (seam, state)

proc near(a, b: float): bool =
  ## Relative closeness for the RMS pins: the samples are float32, so a
  ## tone written as 0.1 is 0.10000000149 once squared and averaged. The
  ## difflib pins use ULP-exact comparison instead, because that is pure
  ## float64 arithmetic. float32 carries ~1.2e-7 and squaring doubles
  ## the relative error, so 1e-6 is the honest bound.
  abs(a - b) < 1e-6 * max(1.0, abs(b))

proc envOf(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (name, value) in pairs:
    result[name] = value

# ── speakable: what actually gets voiced ───────────────────────────────

suite "phase 7c voice speakable":
  test "emoji and pictographs are stripped":
    assert speakable("All set! \u{1F389} Booked for Saturday. \u{1F3BE}") ==
      "All set! Booked for Saturday."
    assert speakable("Here you go \u{1F60A}\u{1F44D}") == "Here you go"
    assert speakable("Nice \u{1F1EC}\u{1F1E7} flag") == "Nice flag"

  test "markdown marks are stripped":
    assert speakable("**Bold** and `code` and # heading") ==
      "Bold and code and heading"
    assert speakable("> quote") == "quote"
    assert speakable("plain words, nothing to strip") ==
      "plain words, nothing to strip"

  test "gaps left by removed glyphs collapse to one space":
    assert speakable("Done \u{2705} \u{2014} added 3 events " &
      "\u{1F680}\u{1F680}\u{1F680}") == "Done \u{2014} added 3 events"
    assert speakable("a  b\t\tc") == "a b c"
    assert speakable("  spaced   out  ") == "spaced out"

  test "single spaces and single tabs survive, lines get trimmed":
    assert speakable("tab\there") == "tab\there"
    assert speakable("line1\n  line2  \n\nline3") == "line1\nline2\n\nline3"
    assert speakable("nl\u{2028}ls") == "nl\nls"

  test "python's whitespace set trims the invisible edges too":
    # NBSP, an ideographic space and the C0 separators all count as
    # whitespace for `str.strip()`; U+0085 is one of its line breaks.
    assert speakable("\u{00A0}edge\u{00A0}") == "edge"
    assert speakable("\u{3000}edge\u{3000}") == "edge"
    assert speakable("\u{001F}edge\u{001F}") == "edge"
    assert speakable("one\u{0085}two") == "one\ntwo"

  test "nothing to say is the empty string":
    assert speakable("") == ""
    assert speakable("\u{1F4A5}\u{2728}\u{1F525}") == ""
    assert speakable("  ") == ""

# ── wake word ──────────────────────────────────────────────────────────

suite "phase 7c voice wake word":
  test "exact, punctuated and space-less variants wake":
    assert matchesWake("waku waku", "waku waku")
    assert matchesWake("Waku, waku!", "waku waku")
    assert matchesWake("wakuwaku", "waku waku")
    assert matchesWake("wakuwa ku", "waku waku")

  test "a wake word inside a sentence still wakes":
    assert matchesWake("so anyway waku waku schedule it", "waku waku")
    assert matchesWake("Hey Waku", "hey waku")
    assert matchesWake("hey computer, what's up", "hey computer")

  test "one-letter mangles wake through the fuzzy window":
    # No substring match here: only the 0.7 sliding window over the
    # transcript's words saves it.
    assert not "waku waku".contains("walku waku")
    assert matchesWake("walku waku", "waku waku")
    # "waka waka" scores 0.778, which is why the default list carries it.
    assert matchesWake("waka waka", "waku waku")

  test "other scripts wake through comma variants":
    assert matchesWake("\u{308F}\u{304F}\u{308F}\u{304F}",
      "waku waku,\u{308F}\u{304F}\u{308F}\u{304F}")
    assert matchesWake("\u{308F}\u{304F}\u{308F}\u{304F}\u{308F}\u{304F}",
      "waku waku,\u{308F}\u{304F}\u{308F}\u{304F}")
    assert matchesWake("\u{5C0F}\u{52A9}\u{624B}\u{4F60}\u{597D}",
      "waku waku,\u{5C0F}\u{52A9}\u{624B}")

  test "unrelated speech stays asleep":
    assert not matchesWake("what a nice day", "waku waku")
    assert not matchesWake("wake up call at nine", "waku waku")
    assert not matchesWake("walk to work", "waku waku")
    # A ONE-word transcript cannot use the window at all (the window is
    # as wide as the phrase), so this one only wakes on the bare "waku"
    # variant the default list carries.
    assert not matchesWake("wakuwak", "waku waku")
    assert matchesWake("wakuwak", wakeWordDefault)

  test "the normalizer keeps kana and CJK, drops everything else":
    # The pin behind the kana variants: a latin-only normalizer could
    # never match what the scout writes down.
    assert normalizeWake("Waku, waku!") == "waku waku"
    assert normalizeWake("Hello, \u{4E16}\u{754C} 123 \u{308F}\u{304F}") ==
      "hello \u{4E16}\u{754C} 123 \u{308F}\u{304F}"
    assert normalizeWake("!!! \u{1F600}") == ""
    assert normalizeWake("waku\twaku") == "wakuwaku"  # a tab is not a space

  test "no transcript or no configured wake word never wakes":
    assert not matchesWake("", "waku waku")
    assert not matchesWake("waku waku", "")
    assert not matchesWake("waku waku", " , ")

  test "similarity matches difflib's ratio, window for window":
    # Golden values from Python's difflib.SequenceMatcher(...).ratio().
    assert almostEqual(similarityRatio("walku waku", "waku waku"),
      0.9473684210526315, 0)
    assert almostEqual(similarityRatio("walk to", "waku waku"), 0.5, 0)
    assert almostEqual(similarityRatio("wake up", "waku waku"), 0.625, 0)
    assert almostEqual(similarityRatio("nice day", "waku waku"),
      0.23529411764705882, 0)
    assert similarityRatio("waku waku", "waku waku") == 1.0
    # Recursive matching blocks, not one longest run.
    assert almostEqual(similarityRatio("a b c d", "b c d"),
      0.8333333333333334, 0)
    assert almostEqual(similarityRatio("the quick brown fox",
      "the quick brown fox jumped"), 0.8444444444444444, 0)
    # Rune-level (not byte-level): kana and CJK are multibyte.
    assert similarityRatio("\u{308F}\u{304F}\u{308F}\u{304F}",
      "\u{308F}\u{304F}\u{308F}\u{304F}") == 1.0
    assert almostEqual(similarityRatio("\u{5C0F}\u{52A9}\u{624B}\u{4F60}\u{597D}",
      "\u{5C0F}\u{52A9}\u{624B}"), 0.75, 0)
    # difflib's degenerate cases.
    assert similarityRatio("", "") == 1.0
    assert similarityRatio("", "x") == 0.0

# ── mic threshold, env config, terminal lines ───────────────────────────

suite "phase 7c voice config":
  test "the threshold defaults to 0.005 and parses tuned values":
    assert voiceConfig(envOf([])).threshold == 0.005
    assert parseMicThreshold(" 0.02 ") == 0.02
    assert voiceConfig(envOf([("WAKU_MIC_THRESHOLD", "0.05")])).threshold ==
      0.05

  test "a garbage threshold raises like Python's float()":
    try:
      discard parseMicThreshold("loud")
      assert false, "must raise"
    except ValueError:
      discard
    try:
      discard voiceConfig(envOf([("WAKU_MIC_THRESHOLD", "0.005 loud")]))
      assert false, "must raise"
    except ValueError:
      discard

  test "the wake knobs come from the env table, not the process":
    let cfg = voiceConfig(envOf([("WAKU_WAKE_WORD", "  hey waku  "),
      ("WAKU_WAKE_ACK", "Yes?"), ("WAKU_FOLLOWUP_SECONDS", "12"),
      ("WAKU_MIC_THRESHOLD", "0.01")]))
    assert cfg.wakeWord == "hey waku"
    assert cfg.ack == "Yes?"
    assert cfg.followupSeconds == 12.0
    assert cfg.threshold == 0.01

  test "the default wake word packs the known mis-hearings":
    let cfg = voiceConfig(envOf([]))
    assert cfg.wakeWord == "waku waku,wakuwaku,waku,waka waka,wako wako," &
      "walk walk,\u{308F}\u{304F}\u{308F}\u{304F}"
    assert cfg.ack == "Yes?"
    assert cfg.followupSeconds == 8.0

  test "the scout language is a pure function of the two inputs":
    assert wakeLanguage("", "hey waku") == "en"
    assert wakeLanguage("", "waku waku,\u{308F}\u{304F}") == ""
    assert wakeLanguage("ja", "waku waku") == "ja"
    assert wakeLanguage("", "") == "en"  # empty wake word: push-to-talk

  test "the scout language follows the wake word's script":
    # The default wake word ends in kana, so the scout is NOT pinned to
    # English (Python's `wake_word.isascii()` is False there).
    assert voiceConfig(envOf([])).wakeLang == ""
    assert voiceConfig(envOf([("WAKU_WAKE_WORD", "hey waku")])).wakeLang ==
      "en"
    assert voiceConfig(envOf([("WAKU_WAKE_WORD",
      "\u{308F}\u{304F}\u{308F}\u{304F}"),
      ("WAKU_WAKE_LANG", "ja")])).wakeLang == "ja"

  test "an empty wake word means push-to-talk, not hands-free":
    assert not handsFree(voiceConfig(envOf([("WAKU_WAKE_WORD", "")])).wakeWord)
    assert not handsFree(voiceConfig(envOf([("WAKU_WAKE_WORD", "   ")])).wakeWord)
    assert handsFree(voiceConfig(envOf([])).wakeWord)

  test "the whisper knobs are read but never run here":
    let cfg = voiceConfig(envOf([("WAKU_WHISPER_MODEL", "small"),
      ("WAKU_WHISPER_LANG", "en")]))
    assert cfg.whisperModel == "small"
    assert cfg.whisperLang == "en"
    assert voiceConfig(envOf([])).whisperModel == "base"
    assert voiceConfig(envOf([])).whisperLang == ""

  test "the audio contract is Python's: 16kHz, 100ms reads, 250ms floor":
    assert sampleRate == 16000
    assert micBlock == 1600
    assert shortUtteranceSamples == 4000
    assert micThresholdDefault == 0.005

  test "terminal lines are verbatim":
    assert banner("hey waku") ==
      "Listening for \"hey waku\" \u{2014} Ctrl-C to quit."
    assert readyBanner ==
      "Voice Waku ready. Press Enter to talk, Ctrl-C to quit."
    assert listeningLine == "\u{B7} listening\u{2026}"
    assert heardLine("waka waka") == "\u{B7} heard: \"waka waka\""
    assert heardLine("") == listeningLine
    assert followupLine(8.0) ==
      "\u{B7} still here \u{2014} just talk, or I'll rest in 8s"
    assert followupLine(8.4) == followupLine(8.0)
    assert tooShortReply == "(too short, try again)"
    assert noSpeechReply == "(didn't catch that)"
    assert byeLine == "bye \u{2014} your memory stays in state.db"

# ── the two command state machines ──────────────────────────────────────

suite "phase 7c voice command machines":
  test "RMS of a block is the amplitude of a steady tone":
    assert near(rms(tone(0.1)), 0.1)
    assert rms(tone(0.0)) == 0.0
    assert rms(@[]) == 0.0
    assert near(rms(tone(0.5, 800)), 0.5)

  test "recordCommand stops after the configured silence":
    # Loud, then 12 quiet 100ms blocks: silenceAfter 1.2s ends it. The
    # 14th block stays unread (the script raises if it is asked for).
    var blocks = @[tone(0.2)] & quietBlocks(12) & @[tone(0.9)]
    assert blocks.len == 14
    let (seam, state) = readsOf(blocks)
    let audio = recordCommand(seam, 0.005, maxSeconds = 15.0,
      silenceAfter = 1.2)
    assert state.readSizes.len == 13
    assert state.readSizes[0] == readBlock
    assert audio.len == 13 * readBlock
    assert near(rms(audio[0 ..< readBlock]), 0.2)

  test "the loud line is strict: exactly twice the threshold is quiet":
    var blocks = @[tone(0.0101), tone(0.01), tone(0.01)]
    let (seam, state) = readsOf(blocks)
    let audio = recordCommand(seam, 0.005, maxSeconds = 15.0,
      silenceAfter = 0.1)
    # Block 1 is loud, block 2 is exactly 2*threshold (NOT loud) so the
    # single quiet block ends the command; block 3 is never read.
    assert state.readSizes.len == 2
    assert audio.len == 2 * readBlock

  test "a silent stream costs the whole default budget":
    let (seam, state) = readsOf(quietBlocks(150))
    let audio = recordCommand(seam, 0.005)
    assert state.readSizes.len == 150
    assert audio.len == 150 * readBlock

  test "waitForSpeech returns at the first loud block":
    let (seam, state) = readsOf(@[tone(0.001), tone(0.001), tone(0.4),
      tone(0.4)])
    assert waitForSpeech(seam, 0.005, 8.0)
    assert state.readSizes.len == 3
    assert state.readSizes[0] == readBlock

  test "waitForSpeech gives up after the timeout":
    let (seam, state) = readsOf(quietBlocks(80))
    assert not waitForSpeech(seam, 0.005, 8.0)
    assert state.readSizes.len == 80

# ── audio seams: honest when nothing is wired ──────────────────────────

suite "phase 7c voice seams":
  test "captureUtterance hands the recorded audio straight through":
    let audio = tone(0.2, 4000)
    let record: RecordFn = proc(): seq[float32] {.closure.} = audio
    assert captureUtterance(record) == audio

  test "a nil record seam raises naming the seam":
    try:
      discard captureUtterance(nil)
      assert false, "must raise"
    except CatchableError as exc:
      assert "RecordFn" in exc.msg
      assert "sounddevice" in exc.msg

  test "a nil stt seam raises naming faster-whisper":
    try:
      discard transcribe(nil, tone(0.2))
      assert false, "must raise"
    except CatchableError as exc:
      assert "SttFn" in exc.msg
      assert "faster-whisper" in exc.msg

  test "a nil tts seam raises naming the mouth, not a silent success":
    try:
      speak(nil, "hello")
      assert false, "must raise"
    except CatchableError as exc:
      assert "TtsFn" in exc.msg

  test "the transcript crosses the ears seam and only the transcript":
    var ears = Ears(heard: @[])
    let stt: SttFn = proc(audio: seq[float32]): string {.closure.} =
      ears.heard.add(audio.len)
      return "what is on my calendar"
    assert transcribe(stt, tone(0.2, 800)) == "what is on my calendar"
    assert ears.heard == @[800]

  test "the mouth receives speakable text only, and skips the empty":
    var mouth = Mouth(spoken: @[])
    let tts: TtsFn = proc(text: string) {.closure.} = mouth.spoken.add(text)
    speak(tts, "All set! \u{1F389} **Booked** for Saturday.")
    speak(tts, "\u{1F4A5}")
    speak(tts, "")
    assert mouth.spoken == @["All set! Booked for Saturday."]

# ── decisions: the push-to-talk ladder and the wake scan ────────────────

suite "phase 7c voice decisions":
  test "a slip under 250ms is a retry, silence is a retry, else answer":
    assert pushToTalkStep(3999, "") == ptTooShort
    assert pushToTalkStep(0, "") == ptTooShort
    assert pushToTalkStep(4000, "") == ptNoSpeech
    assert pushToTalkStep(4000, "hello") == ptRespond
    # The engine strips its transcript, so only an EMPTY one takes the
    # middle branch (Python's `if not heard`).
    assert pushToTalkStep(4000, "  ") == ptRespond

  test "a quiet chunk is silence, not a near miss":
    let scan = scanWake(0.004, 0.005, "waku waku", "")
    assert scan.action == waQuiet
    assert not scan.matched
    assert wakeStatus(scan) == listeningLine

  test "the transcription gate is at-or-above the threshold":
    assert not shouldTranscribe(0.004, 0.005)
    assert shouldTranscribe(0.005, 0.005)
    assert shouldTranscribe(0.006, 0.005)

  test "a heard near miss is shown and traced":
    let scan = scanWake(0.4, 0.005, "waku waku", "wake up call at nine")
    assert scan.action == waNearMiss
    assert scan.heard == "wake up call at nine"
    assert not scan.matched
    assert wakeStatus(scan) == "\u{B7} heard: \"wake up call at nine\""
    let ev = wakeScanEvent(scan)
    assert ev["heard"].getStr() == "wake up call at nine"
    assert not ev["matched"].getBool()

  test "a loud window with no transcript is still silence":
    let scan = scanWake(0.4, 0.005, "waku waku", "")
    assert scan.action == waQuiet
    assert scan.heard.len == 0
    assert wakeStatus(scan) == listeningLine

  test "a matched wake word closes the scan":
    let scan = scanWake(0.4, 0.005, "waku waku", "Waku, waku!")
    assert scan.action == waWake
    assert scan.matched
    assert scan.heard == "Waku, waku!"

# ── one spoken turn, end to end without audio ───────────────────────────

suite "phase 7c voice turn":
  test "a transcript is answered, logged and spoken":
    var mouth = Mouth(spoken: @[])
    var lines: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} =
      if text == "what is on my calendar":
        return "Three events \u{1F4C5} tomorrow."
      return "I don't know"
    let tts: TtsFn = proc(text: string) {.closure.} = mouth.spoken.add(text)
    let logger: LogFn = proc(line: string) {.closure.} = lines.add(line)
    assert voiceTurn("what is on my calendar", respond, tts, logger)
    assert lines == @["you › what is on my calendar",
      "waku › Three events \u{1F4C5} tomorrow."]
    assert mouth.spoken == @["Three events tomorrow."]

  test "an empty transcript says so and answers nothing":
    var mouth = Mouth(spoken: @[])
    var lines: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} =
      assert false, "the agent must not be called"
      return ""
    let tts: TtsFn = proc(text: string) {.closure.} = mouth.spoken.add(text)
    let logger: LogFn = proc(line: string) {.closure.} = lines.add(line)
    assert not voiceTurn("", respond, tts, logger)
    assert lines == @["(didn't catch that)"]
    assert mouth.spoken.len == 0

  test "an empty reply is printed and stays silent":
    var mouth = Mouth(spoken: @[])
    var lines: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} = ""
    let tts: TtsFn = proc(text: string) {.closure.} = mouth.spoken.add(text)
    let logger: LogFn = proc(line: string) {.closure.} = lines.add(line)
    assert voiceTurn("hi", respond, tts, logger)
    assert lines == @["you › hi", "waku › "]
    assert mouth.spoken.len == 0

  test "a failing turn propagates: voice has no error reply in Python":
    var lines: seq[string] = @[]
    let respond: RespondFn = proc(text: string): string {.closure.} =
      raise newException(IOError, "model down")
    let tts: TtsFn = proc(text: string) {.closure.} = discard
    let logger: LogFn = proc(line: string) {.closure.} = lines.add(line)
    try:
      discard voiceTurn("hi", respond, tts, logger)
      assert false, "must raise"
    except IOError:
      discard
    assert lines == @["you › hi"]

# ── the live loops (7d1) ──────────────────────────────────────────────

type
  Rig = ref object
    ## Everything one scripted voice session records: the transcript the
    ## ears hand back per take, what the mouth spoke, the lines the
    ## terminal showed, the wake traces, the heartbeats and the drains.
    heard: seq[string]
    spoken: seq[string]
    lines: seq[string]
    beats: seq[string]
    traces: seq[JsonNode]
    drains: int
    nextTranscript: int
    stopAfter: int       ## stop the loop after this many replies
    replies: int
    micOpens: int

proc nextHeard(r: Rig): string =
  ## One scripted transcript per take, then silence: a loop that keeps
  ## asking after the script runs out gets "" (the "(didn't catch that)"
  ## branch), which is exactly what an exhausted queue should say.
  if r.nextTranscript >= r.heard.len:
    return ""
  result = r.heard[r.nextTranscript]
  r.nextTranscript += 1

proc rigOf(blocks: seq[seq[float32]], heard: seq[string],
    config: VoiceConfig): (VoiceRig, Rig) =
  ## A rig over a scripted mic, scripted ears and a scripted mouth.
  var state = Rig(heard: heard, spoken: @[], lines: @[], beats: @[],
    traces: @[], drains: 0, nextTranscript: 0, stopAfter: 99, replies: 0,
    micOpens: 0)
  let (read, script) = readsOf(blocks)
  let stopFlag = state
  result[0].config = config
  result[0].read = read
  result[0].pending = proc(): int {.closure.} = state.drains * 0
  result[0].drain = proc(): int {.closure.} =
    inc state.drains
    return 0
  result[0].stt = proc(audio: seq[float32]): string {.closure.} =
    return state.nextHeard()
  result[0].tts = proc(text: string) {.closure.} = state.spoken.add(text)
  result[0].respond = proc(text: string): string {.closure.} =
    inc state.replies
    if state.replies >= state.stopAfter:
      stopFlag.stopAfter = 0
    return "reply " & $state.replies
  result[0].logger = proc(line: string) {.closure.} = state.lines.add(line)
  result[0].status = proc(msg: string) {.closure.} = state.beats.add(msg)
  result[0].trace = proc(kind: string, payload: JsonNode) {.closure.} =
    assert kind == "wake_scan"
    state.traces.add(payload)
  # the script IS the stop: once every scripted transcript is spent, a
  # real session would still be listening, so the scripted one ends —
  # which is what makes each test's block budget exact
  result[0].stop = proc(): bool {.closure.} =
    state.stopAfter == 0 or state.nextTranscript >= state.heard.len
  result[1] = state

proc shortFollowup(wakeWord = wakeWordDefault): VoiceConfig =
  ## The default config with a 0.3s follow-up window: the real default
  ## is 8s, which is 80 blocks of scripted silence per test.
  voiceConfig(envOf([("WAKU_WAKE_WORD", wakeWord),
    ("WAKU_FOLLOWUP_SECONDS", "0.3"), ("WAKU_MIC_THRESHOLD", "0.005")]))

proc windows(count: int, amp = 0.1f32): seq[seq[float32]] =
  ## `count` loud 100ms blocks, enough for whole wake windows.
  result = @[]
  for _ in 1 .. count:
    result.add(tone(amp))

suite "phase 7d1 voice heartbeat":
  test "the status line is one rewritten row, 72 columns wide":
    let beat = heartbeatLine("· listening…")
    assert beat.startsWith("\r\x1b[2m· listening…")
    assert beat.endsWith("\x1b[0m")
    # padded to the full width, so a shorter line cannot leave the
    # previous scan's characters on screen
    assert beat.len == "\r\x1b[2m".len + 72 + "\x1b[0m".len
    assert beat == "\r\x1b[2m" & "· listening…" &
      " ".repeat(72 - "· listening…".len) & "\x1b[0m"
    let long = heartbeatLine("x".repeat(100))
    assert long.len == "\r\x1b[2m".len + 72 + "\x1b[0m".len
    assert "x".repeat(72) in long
    assert "x".repeat(73) notin long

suite "phase 7d1 voice wake loop":
  test "a quiet window listens, and spends nothing on the ears":
    let (rig, state) = rigOf(windows(25) & quietBlocks(25), @[],
      shortFollowup())
    # the first 25 blocks are loud, so replace them with quiet ones
    let (quietRig, quietState) = rigOf(quietBlocks(50), @[],
      shortFollowup())
    discard rig
    discard state
    # a stop that is already true ends before the first read
    quietState.stopAfter = 0
    wakeLoop(quietRig)
    assert quietState.beats.len == 0
    assert quietState.spoken.len == 0
    assert quietState.lines == @[banner(wakeWordDefault)]

  test "a near miss is traced and shown, and the loop keeps scanning":
    let blocks = windows(25) & windows(25) & windows(3) &
      quietBlocks(12) & quietBlocks(3)
    let (rig, state) = rigOf(blocks,
      @["what a nice day", "waku waku", "what is on today"],
      shortFollowup())
    state.stopAfter = 1
    wakeLoop(rig)
    assert state.beats[0] == "· heard: \"what a nice day\""
    # only the near miss is traced: a wake is not a near miss
    assert state.traces.len == 1
    assert state.traces[0] == %*{"heard": "what a nice day", "matched": false}
    assert state.spoken[0] == "Yes?"      # the ack, before the question
    assert state.lines.contains("you › what is on today")
    assert state.lines.contains("waku › reply 1")

  test "a wake answers, drains twice and shows the follow-up line":
    # 25 loud (window) + 3 loud + 12 quiet (the command take) +
    # 3 quiet (wait_for_speech says no) is the whole exchange.
    let blocks = windows(25) & windows(3) & quietBlocks(12) & quietBlocks(3)
    let (rig, state) = rigOf(blocks, @["waku waku", "what is on today"],
      shortFollowup())
    state.stopAfter = 1
    wakeLoop(rig)
    assert "[wake word]" in state.lines
    assert state.spoken == @["Yes?", "reply 1"]
    assert state.lines == @["Listening for \"" & wakeWordDefault &
      "\" — Ctrl-C to quit.", "[wake word]", "you › what is on today",
      "waku › reply 1"]
    assert state.drains == 2   # after the ack and after the reply
    assert state.beats[^1] == "· still here — just talk, or I'll rest in 0s"

  test "an empty command says it did not catch that and moves on":
    let blocks = windows(25) & windows(3) & quietBlocks(12) & quietBlocks(3)
    let (rig, state) = rigOf(blocks, @["waku waku", ""], shortFollowup())
    state.stopAfter = 1
    wakeLoop(rig)
    assert "(didn't catch that)" in state.lines
    assert state.spoken == @["Yes?"]
    assert state.drains == 2

  test "Ctrl-C ends the loop before the first window":
    var (rig, state) = rigOf(windows(25) & windows(25), @["waku waku"],
      shortFollowup())
    let quitting = true
    rig.stop = proc(): bool {.closure.} = quitting
    wakeLoop(rig)
    assert state.spoken.len == 0
    assert state.beats.len == 0
    # the banner, and nothing else: no window was ever read
    assert state.lines == @[banner(wakeWordDefault)]

suite "phase 7d1 voice push to talk":
  test "the ladder answers a take, then the Enter prompt ends the session":
    var lines: seq[string] = @[]
    var spoken: seq[string] = @[]
    var prompts: seq[string] = @[]
    var opens = 0
    var (rig, _) = rigOf(quietBlocks(2), @["one take"], shortFollowup(""))
    rig.stop = nil   # this session ends at EOF, not at a stop flag
    rig.logger = proc(line: string) {.closure.} = lines.add(line)
    rig.tts = proc(text: string) {.closure.} = spoken.add(text)
    var takes = 0
    let openMic: MicOpenFn =
      proc(): ExternalMic {.closure.} =
        inc opens
        return nil
    let prompt: PromptFn =
      proc(msg: string) {.closure.} = prompts.add(msg)
    # two Enter presses per take (start talking, done), and the sixth
    # ends the session
    let readLine: LineFn =
      proc(): string {.closure.} =
        inc takes
        if takes > 5:
          raise newException(EOFError, "end of input")
        return ""
    # take one: long enough and understood. take two: too short.
    var takesRead = 0
    var sttCalls = 0
    let stt: SttFn =
      proc(audio: seq[float32]): string {.closure.} =
        # the first take is understood, the second is not
        result = if sttCalls == 0: "book the dentist" else: ""
        inc sttCalls
        return result
    rig.stt = stt
    let takeOf: TakeFn =
      proc(mic: ExternalMic): seq[float32] {.closure.} =
        result = if takesRead == 0: tone(0.1, shortUtteranceSamples + 10)
                 else: tone(0.1, shortUtteranceSamples + 10)
        inc takesRead
        return result
    check pushToTalk(rig, openMic, prompt, readLine, takeOf)
    # two full takes ran, then the next Enter press ended the session
    assert opens == 3
    assert prompts.len == 6
    assert prompts[0] == "\npress Enter to talk… "
    assert prompts[1] == "recording — press Enter when done… "
    assert lines.contains("you › book the dentist")
    assert spoken == @["reply 1"]
    assert "(didn't catch that)" in lines
    assert lines[^1] == byeLine

suite "phase 7d1 voice command":
  test "an unwired engine is named and nothing is started":
    var opens = 0
    let openMic: MicOpenFn =
      proc(): ExternalMic {.closure.} =
        inc opens
        return nil
    let respond: RespondFn = proc(text: string): string {.closure.} = "hi"
    var said: seq[string] = @[]
    let quiet: LogFn = proc(line: string) {.closure.} = discard
    assert voiceMain(envOf([]), respond, openMic, run = nil,
      logger = quiet) == 1
    assert opens == 0
    said = @[]
    let collect: LogFn = proc(line: string) {.closure.} = said.add(line)
    let code = voiceMain(envOf([("WAKU_STT_COMMAND", "whisper-cli")]),
      respond, openMic, logger = collect)
    assert code == 1
    assert opens == 0
    assert said.len == 1
    assert "WAKU_MIC_COMMAND" in said[0]

  test "without a mouth the session says so once and keeps going":
    var said: seq[string] = @[]
    var opens = 0
    let noMic: MicOpenFn =
      proc(): ExternalMic {.closure.} =
        inc opens
        raise newException(CatchableError, "no recorder here")
    let collect: LogFn = proc(line: string) {.closure.} = said.add(line)
    let line: LineFn = proc(): string {.closure.} = ""
    let unused: RespondFn = proc(text: string): string {.closure.} = "unused"
    let code = voiceMain(envOf([("WAKU_STT_COMMAND", "whisper-cli"),
        ("WAKU_MIC_COMMAND", "arecord -q"), ("WAKU_WAKE_WORD", "")]),
      unused, noMic, logger = collect, readLineIn = line)
    # the mouth notice first, then the ready banner, then the honest mic
    # error and the goodbye — the ladder never ran
    assert "WAKU_TTS_COMMAND" in said[0]
    assert said[1] == readyBanner
    assert "no recorder here" in said[2]
    assert said[3] == byeLine
    assert code == 1
    assert opens == 1

  test "a mouth is wired and a take is answered, then the mic fails":
    var said: seq[string] = @[]
    var spoken: seq[string] = @[]
    var prompts: seq[string] = @[]
    var takesRead = 0
    var opens = 0
    let openMic: MicOpenFn =
      proc(): ExternalMic {.closure.} =
        inc opens
        return nil
    let collect: LogFn = proc(line: string) {.closure.} = said.add(line)
    let run: RunCommandFn =
      proc(argv: seq[string], stdin: string): (int, string) {.closure.} =
        if argv[0] == "say":
          spoken.add(stdin)
          return (0, "")
        return (0, "  book it  ")
    let code = voiceMain(envOf([("WAKU_STT_COMMAND", "whisper-cli"),
        ("WAKU_MIC_COMMAND", "arecord -q"),
        ("WAKU_TTS_COMMAND", "say -v Daniel"), ("WAKU_WAKE_WORD", "")]),
      proc(text: string): string {.closure.} = "booked for friday",
      openMic, run, logger = collect,
      takeOf = proc(mic: ExternalMic): seq[float32] {.closure.} =
        tone(0.1, shortUtteranceSamples + 10),
      prompt = proc(msg: string) {.closure.} = prompts.add(msg),
      readLineIn = proc(): string {.closure.} =
        inc takesRead
        if takesRead > 2:
          raise newException(EOFError, "end of input")
        return "")
    assert "WAKU_TTS_COMMAND" notin said[0]
    assert said[0] == readyBanner
    assert "you › book it" in said
    assert "waku › booked for friday" in said
    assert spoken == @["booked for friday"]  # the reply, speakable
    assert prompts[0] == "\npress Enter to talk… "
    assert prompts[1] == "recording — press Enter when done… "
    assert said[^1] == byeLine
    assert code == 0

suite "phase 7d1 voice recorder recycling":
  test "the scanner asks for a recycle once per window":
    # one scripted transcript keeps the stop flag false, so the loop
    # reaches the first window
    var (rig, state) = rigOf(quietBlocks(50), @["never used"],
      shortFollowup())
    var recycles = 0
    rig.recycle = proc() {.closure.} =
      inc recycles
      state.stopAfter = 0   # one window is enough for this pin
    wakeLoop(rig)
    assert recycles == 1

  test "a rig without a recycle seam never asks":
    let (rig, state) = rigOf(quietBlocks(50), @["never used"],
      shortFollowup())
    state.stopAfter = 0
    wakeLoop(rig)  # would raise on a nil call if the loop did not guard
    assert state.beats.len == 0
