## Voice gateway, phase 7c — the gateway with the audio left out.
##
## Port of `waku/gateway/voice.py`, and only the half that does not
## need a sound device: what actually gets voiced (`_speakable`), the
## wake word (`matches_wake`, plus the `difflib` ratio it leans on),
## the mic threshold (`_mic_threshold`), the two command state
## machines over a sample stream (`record_command`,
## `wait_for_speech`), the push-to-talk ladder, the `wake_loop` scan
## decision, one spoken turn and the terminal lines.
##
## The audio is the part that does NOT ship. faster-whisper (a ~74MB
## model downloaded on the first run), kokoro (82M neural, played
## through `sounddevice`) and macOS `say` (a subprocess) would break
## the one binary, rule 3's stdlib-only core and offline operation —
## and a subprocess does not belong in the voice hot path. So all
## three stay seams: `SampleFn`/`RecordFn` for capture, `SttFn` for
## the ears, `TtsFn` for the mouth. A `nil` seam raises an honest
## error naming the seam and the engine it waits for, the same
## honest-501 policy the arena routes (8c/8d) and the OAuth flow (6b)
## use; 7d wires an external engine, or says in plain text what is
## missing. Nothing here pretends to listen.
##
## Everything else is pure or seam-injected, so the tests open no
## device, spawn no subprocess and touch no network: zero audio in
## the suite. `wake_loop`'s always-listening loop, the persistent
## `InputStream`, `drain()` and `main`'s `input()` prompts are 7d,
## like the live loops of the chat gateways in 7a/7b.

import std/json
import std/math
import std/strutils
import std/tables
import std/unicode

import ./gateway

const
  sampleRate* = 16000
    ## `SAMPLE_RATE` verbatim: 16kHz mono float32, what Whisper wants.
  micBlock* = sampleRate div 10
    ## 100ms reads (`block = SAMPLE_RATE // 10` in both command
    ## machines). One read, one decision — and never a fresh stream.
  micThresholdDefault* = 0.005
    ## `float(os.getenv("WAKU_MIC_THRESHOLD", "0.005"))`: RMS below
    ## this is silence. Mics vary wildly, so it is tuned per machine.
  shortUtteranceSamples* = sampleRate div 4
    ## 250ms: under this a push-to-talk take is a slip, not a question.
  wakeWordDefault* = "waku waku,wakuwaku,waku,waka waka,wako wako," &
    "walk walk,わくわく"
    ## Hands-free by default, packing the ways the tiny scout mis-hears
    ## the phrase (no space, waka, kana). `WAKU_WAKE_WORD=""` turns
    ## hands-free off and gives push-to-talk.
  wakeAckDefault* = "Yes?"
    ## `WAKU_WAKE_ACK`: what the mouth says the moment it wakes, before
    ## the big ears take over.
  followupSecondsDefault* = 8.0
    ## `WAKU_FOLLOWUP_SECONDS`: how long a woken conversation stays
    ## open for a follow-up before dropping back to the wake word.
  whisperModelDefault* = "base"
    ## `WAKU_WHISPER_MODEL`, read here so 7d builds the engine from one
    ## config; the model itself is not in this binary.
  tooShortReply* = "(too short, try again)"
  noSpeechReply* = "(didn't catch that)"
  readyBanner* = "Voice Waku ready. Press Enter to talk, Ctrl-C to quit."
  byeLine* = "bye — your memory stays in state.db"
  listeningLine* = "· listening…"
    ## The heartbeat: a scanner that never prints looks dead.

const
  sttSeamMissing* = "voice SttFn is not wired: the faster-whisper " &
    "ears are not part of the stdlib binary (waku voice needs an " &
    "external engine)"
  ttsSeamMissing* = "voice TtsFn is not wired: the kokoro/say mouth " &
    "is not part of the stdlib binary (waku voice needs an external " &
    "engine)"
  recordSeamMissing* = "voice RecordFn/SampleFn is not wired: " &
    "sounddevice has no stdlib port (waku voice needs an external mic)"

# ── what actually gets voiced ──────────────────────────────────────────

proc isPictograph(v: int32): bool =
  ## The ranges of Python's `_EMOJI` class: symbols/pictographs/
  ## emoticons/transport/supplemental, misc symbols + dingbats,
  ## regional-indicator flag letters, arrows, stars and misc
  ## symbols-and-arrows, variation selectors, and the ZWJ plus keycap
  ## joiners. Python's trailing `+` makes the LAST class a run; taking
  ## one rune at a time removes the same characters either way.
  (v >= 0x1F300'i32 and v <= 0x1FAFF'i32) or
    (v >= 0x2600'i32 and v <= 0x27BF'i32) or
    (v >= 0x1F1E6'i32 and v <= 0x1F1FF'i32) or
    (v >= 0x2190'i32 and v <= 0x21FF'i32) or
    (v >= 0x2B00'i32 and v <= 0x2BFF'i32) or
    (v >= 0xFE00'i32 and v <= 0xFE0F'i32) or
    v == 0x200D'i32 or v == 0x20E3'i32

proc isLineBreak(v: int32): bool =
  ## `str.splitlines`'s eleven break characters, minus the `\r\n`
  ## pair handled by its caller: `\n`, `\v`, `\f`, `\x1c`-`\x1e`,
  ## `\x85`, U+2028, U+2029 (and `\r`).
  v == 0x0A'i32 or v == 0x0B'i32 or v == 0x0C'i32 or
    (v >= 0x1C'i32 and v <= 0x1E'i32) or v == 0x85'i32 or
    v == 0x2028'i32 or v == 0x2029'i32

proc splitLines(text: string): seq[string] =
  ## `str.splitlines()`. `strutils.splitLines` only knows `\r` and
  ## `\n`, and a reply that came back through a model can carry any of
  ## the others — U+2028 in an answer would otherwise be read aloud.
  result = @[]
  if text.len == 0:
    return result
  var current = newStringOfCap(text.len)
  var afterCr = false
  for r in text.runes:
    let v = r.int32
    if afterCr:
      afterCr = false
      if v == 0x0A:  # \r\n is ONE break, not two
        continue
    if v == 0x0D'i32:
      afterCr = true
      result.add(current)
      current = newStringOfCap(32)
    elif isLineBreak(v):
      result.add(current)
      current = newStringOfCap(32)
    else:
      current.add(r)
  result.add(current)

proc isPySpace(r: Rune): bool =
  ## `str.isspace()`: Unicode White_Space plus the four C0 separators
  ## (U+001C-U+001F), which Python calls whitespace and Unicode does
  ## not. They are invisible, so the port would not change anything a
  ## person hears — but it should not invent a difference either.
  unicode.isWhiteSpace(r) or (r.int32 >= 0x1C'i32 and r.int32 <= 0x1F'i32)

proc pyStrip(s: string): string =
  ## `str.strip()` (line trims and the final trim of `_speakable`).
  ## `unicode.strip` alone would leave the four C0 separators behind.
  let rs = toRunes(s)
  var lo = 0
  var hi = rs.len
  while lo < hi and isPySpace(rs[lo]):
    inc lo
  while hi > lo and isPySpace(rs[hi - 1]):
    dec hi
  var kept = newStringOfCap(s.len)
  for i in lo ..< hi:
    kept.add(rs[i])
  return kept

proc speakable*(text: string): string =
  ## What a TTS engine is handed (`_speakable`): no emoji, no stray
  ## markdown marks, no gaps left where those glyphs were, and every
  ## line trimmed. A TTS engine reads emoji out loud ("rocket",
  ## "sparkles"), which sounds ridiculous — this is where that is
  ## prevented. Port of `_EMOJI.sub` + the two `re.sub` passes +
  ## `splitlines`/`strip`; the emoji pass and the `[ \t]{2,}` pass
  ## keep Python's order, so "done  three" is "done three" while a
  ## SINGLE tab survives (only runs of two or more collapse).
  if text.len == 0:
    return ""
  var kept = newStringOfCap(text.len)
  for r in text.runes:
    let v = r.int32
    if isPictograph(v):
      continue
    if v < 128 and char(v) in {'*', '_', '`', '#', '>'}:  # markdown marks
      continue
    kept.add(r)
  var collapsed = newStringOfCap(kept.len)
  var run = 0
  for r in kept.runes:
    let v = r.int32
    if v == 0x20'i32 or v == 0x09'i32:  # ' ' or '\t'
      inc run
      if run == 1:
        collapsed.add(r)
      elif run == 2:
        collapsed[^1] = ' '  # the whole run becomes ONE space
    else:
      run = 0
      collapsed.add(r)
  var lines = splitLines(collapsed)
  for i in 0 ..< lines.len:
    # A reply can arrive with an NBSP or an ideographic space at the end
    # of a line, and `str.strip()` takes those in Python too.
    lines[i] = pyStrip(lines[i])
  return pyStrip(lines.join("\n"))

# ── wake word ──────────────────────────────────────────────────────────

type MatchBlock = object
  ## One matched run of a `SequenceMatcher` comparison: `size` runes of
  ## `a` matching `b` at those offsets. Private, like difflib's: the
  ## wake word only ever needs the total, not the runs.
  a, b, size: int

proc findLongestMatch(ra, rb: seq[Rune], alo, ahi, blo,
    bhi: int): MatchBlock =
  ## `SequenceMatcher.find_longest_match` for one slice: the longest
  ## common run inside `[alo, ahi)` x `[blo, bhi)`, extended both ways.
  ## The scratch rows are indexed `j - blo` where Python uses a dict
  ## keyed by the absolute `j` (the `j - 1 < blo` edge reads as 0).
  var besti = alo
  var bestj = blo
  var bestsize = 0
  let width = bhi - blo
  var prev = newSeq[int](width)
  for i in alo ..< ahi:
    var cur = newSeq[int](width)
    for j in blo ..< bhi:
      if ra[i] != rb[j]:
        continue
      var k = 1
      if j > blo:
        k = prev[j - 1 - blo] + 1
      cur[j - blo] = k
      if k > bestsize:
        besti = i - k + 1
        bestj = j - k + 1
        bestsize = k
    prev = cur
  # Non-greedy lookahead, then the same backwards, then forwards again
  # (difflib's three extension passes, in order).
  var i = besti + bestsize
  var j = bestj + bestsize
  while i < ahi and j < bhi and ra[i] == rb[j]:
    inc i
    inc j
  var k = i - besti
  while besti > alo and bestj > blo and ra[besti - 1] == rb[bestj - 1]:
    dec besti
    dec bestj
    inc k
  while besti + k < ahi and bestj + k < bhi and
      ra[besti + k] == rb[bestj + k]:
    inc k
  return MatchBlock(a: besti, b: bestj, size: k)

proc matchedRunes(ra, rb: seq[Rune]): int =
  ## The total matched length of a comparison: every longest-match run,
  ## then the runs of the leftover left and right of each one, until
  ## nothing is left. Python walks that with a deque in the same order;
  ## here it is a stack, which visits the same slices in a different
  ## order and sums to the same total.
  var total = 0
  var pending: seq[(int, int, int, int)] = @[(0, ra.len, 0, rb.len)]
  while pending.len > 0:
    let (alo, ahi, blo, bhi) = pending.pop()
    let m = findLongestMatch(ra, rb, alo, ahi, blo, bhi)
    if m.size > 0:
      total += m.size
      if alo < m.a and blo < m.b:
        pending.add((alo, m.a, blo, m.b))
      if m.a + m.size < ahi and m.b + m.size < bhi:
        pending.add((m.a + m.size, ahi, m.b + m.size, bhi))
  return total

proc similarityRatio*(a, b: string): float =
  ## `difflib.SequenceMatcher(None, a, b).ratio()`: the
  ## Ratcliff/Obershelp similarity `2*M/T` over recursively matched
  ## blocks, where `M` is the matched runes and `T` their total count.
  ## This is what makes "walku waku" wake for the wake word
  ## "waku waku" (0.947 against a floor of 0.7).
  ##
  ## Divergence: comparison is per RUNE, like Python's `str` (byte
  ## comparison would never match kana or CJK), and difflib's
  ## `autojunk` heuristic is not ported — it only ever applies to a
  ## `b` of 200+ elements, and `b` here is always one short wake
  ## variant.
  let ra = toRunes(a)
  let rb = toRunes(b)
  let total = ra.len + rb.len
  if total == 0:
    return 1.0
  return 2.0 * matchedRunes(ra, rb).float64 / total.float64

proc normalizeWake*(s: string): string =
  ## The `norm` inside `matches_wake`: keep latin, digits,
  ## hiragana/katakana (U+3040-U+30FF) and CJK ideographs
  ## (U+4E00-U+9FFF) plus the space; drop everything else (punctuation,
  ## accents, emoji), then trim. Kana and CJK SURVIVE on purpose —
  ## Whisper really does transcribe "waku waku" as わくわく, which a
  ## latin-only normalizer could never match. Divergence: lowercasing
  ## is per rune (`unicode.toLower`) instead of whole-string
  ## `str.lower()`; both drop the expansions Python's full mapping can
  ## produce, because the filter below only keeps ASCII `a-z`.
  var kept = newStringOfCap(s.len)
  for r in s.runes:
    let v = unicode.toLower(r).int32
    if (v >= 0x61'i32 and v <= 0x7A'i32) or   # a-z
        (v >= 0x30'i32 and v <= 0x39'i32) or   # 0-9
        (v >= 0x3040'i32 and v <= 0x30FF'i32) or  # ぀-ヿ
        (v >= 0x4E00'i32 and v <= 0x9FFF'i32) or  # 一-鿿
        v == 0x20'i32:                        # the space
      kept.add(Rune(v))
  return kept.strip()  # only ' ' can be in there, so this is Python's

const wakeFuzzyFloor = 0.7
  ## `SequenceMatcher(...).ratio() >= 0.7` from `matches_wake`.

proc splitWords(s: string): seq[string] =
  ## `str.split()`: whitespace runs collapse and the ends are trimmed.
  ## `split(' ')` does not, and a doubled space would otherwise make a
  ## wake variant look like a three-word phrase.
  result = @[]
  for w in s.split(' '):
    if w.len > 0:
      result.add(w)

proc matchesWake*(text, wakeWord: string): bool =
  ## Does a transcript contain the (customizable) wake word?
  ##
  ## Fuzzy on purpose, because Whisper mangles the phrase in
  ## predictable ways: no space ("wakuwaku"), a stray comma, one wrong
  ## letter ("walku"), or Japanese kana. So `wakeWord` is a
  ## comma-separated list of variants across scripts
  ## ("waku waku,わくわく"), and each variant matches as a substring
  ## of the normalized transcript, as a substring of it with spaces
  ## removed, or through a sliding window of transcript words scored
  ## against the variant with difflib's ratio.
  let heard = normalizeWake(text)
  if heard.len == 0:
    return false
  let squeezed = heard.replace(" ", "")
  let words = splitWords(heard)
  for rawVariant in wakeWord.split(','):
    let variant = normalizeWake(rawVariant)
    if variant.len == 0:
      continue
    if heard.contains(variant) or squeezed.contains(variant.replace(" ", "")):
      return true
    let width = splitWords(variant).len
    for i in 0 ..< max(0, words.len - width + 1):
      if similarityRatio(words[i ..< i + width].join(" "), variant) >=
          wakeFuzzyFloor:
        return true
  return false

# ── mic threshold and env config ───────────────────────────────────────

proc parseMicThreshold*(raw: string): float =
  ## `float(os.getenv("WAKU_MIC_THRESHOLD", "0.005"))`: garbage raises
  ## `ValueError`, like Python's `float()`. Divergence: the raw value is
  ## a parameter (never `os.environ`, so tests pin tuning without
  ## touching the process) and is stripped first — `float()` tolerates
  ## surrounding whitespace, `parseFloat` does not.
  parseFloat(raw.strip())

proc handsFree*(wakeWord: string): bool =
  ## Which mode `main` picks: a non-empty wake word is always-listening,
  ## an empty one is push-to-talk (`if wake_word: … else: …`).
  wakeWord.len > 0

type VoiceConfig* = object
  ## Every knob `voice.py` reads out of the environment, resolved once
  ## from an injected table (precedent: `env` as a `Table` in
  ## `gateway.nim`, `integrations.nim`, `mcp.nim` — no global
  ## mutation, tests stay hermetic). `WAKU_TTS` and `WAKU_VOICE` are
  ## absent on purpose: they configure kokoro/`say`, neither of which
  ## is in this binary, so reading them here would be a knob for an
  ## engine that does not exist.
  wakeWord*: string
  ack*: string
  wakeLang*: string
  whisperModel*: string
  whisperLang*: string
  followupSeconds*: float
  threshold*: float

proc wakeLanguage*(configured, wakeWord: string): string =
  ## The scout's transcription language (`wake_lang`): pinned to match
  ## the wake word's script, because otherwise Whisper hears "waku
  ## waku" and helpfully writes わくわく, which a latin wake word never
  ## matches. `WAKU_WAKE_LANG` wins; otherwise "en" for an ASCII wake
  ## word. Divergence: Python's `None` is `""` here (no nil string), and
  ## 7d passes that on to the engine as "auto-detect".
  if configured.len > 0:
    return configured
  for r in wakeWord.runes:
    if r.int32 >= 128:
      return ""  # not ASCII: let the engine detect, like Python's None
  return "en"

proc voiceConfig*(env: Table[string, string]): VoiceConfig =
  ## The voice knobs, from an env table. `WAKU_MIC_THRESHOLD` and
  ## `WAKU_FOLLOWUP_SECONDS` raise `ValueError` on garbage, like
  ## Python's `float()`; the wake word is stripped (an all-blank value
  ## means push-to-talk, as in `main`).
  result.wakeWord = env.getOrDefault("WAKU_WAKE_WORD", wakeWordDefault).strip()
  result.ack = env.getOrDefault("WAKU_WAKE_ACK", wakeAckDefault)
  result.followupSeconds = parseFloat(
    env.getOrDefault("WAKU_FOLLOWUP_SECONDS", $followupSecondsDefault).strip())
  result.threshold = parseMicThreshold(
    env.getOrDefault("WAKU_MIC_THRESHOLD", $micThresholdDefault))
  result.wakeLang = wakeLanguage(env.getOrDefault("WAKU_WAKE_LANG", ""),
    result.wakeWord)
  result.whisperModel = env.getOrDefault("WAKU_WHISPER_MODEL",
    whisperModelDefault)
  result.whisperLang = env.getOrDefault("WAKU_WHISPER_LANG", "")

# ── terminal lines ─────────────────────────────────────────────────────

proc banner*(wakeWord: string): string =
  ## `print(f'Listening for "{wake_word}" — Ctrl-C to quit.')`
  "Listening for \"" & wakeWord & "\" — Ctrl-C to quit."

proc heardLine*(heard: string): string =
  ## What a near miss shows: `· heard: "…"` (the `status` ternary's
  ## other arm; an empty transcript falls back to `listeningLine`).
  if heard.len == 0:
    return listeningLine
  return "· heard: \"" & heard & "\""

proc followupLine*(seconds: float): string =
  ## `status(f"· still here — just talk, or I'll rest in
  ## {followup:.0f}s")`: whole seconds. `formatFloat(…, ffDecimal, 0)`
  ## rounds the same way Python's `:.0f` does (ties to even) and only
  ## leaves a trailing dot behind.
  var shown = formatFloat(seconds, ffDecimal, 0)
  if shown.len > 0 and shown[^1] == '.':
    shown.setLen(shown.len - 1)
  return "· still here — just talk, or I'll rest in " & shown & "s"

# ── audio seams ────────────────────────────────────────────────────────

type
  SampleFn* = proc(frameCount: int): seq[float32] {.closure.}
    ## ONE block of mono float32 samples from the ONE persistent mic
    ## stream (`stream.read(block)`). Reusing the stream is the
    ## load-bearing part: opening a device per phase is how the first
    ## version froze. The seam is the sounddevice `InputStream` (7d
    ## wires it); `nil` raises naming it. The port does not enforce
    ## the frame count — the live adapter asks the device for it.
  RecordFn* = proc(): seq[float32] {.closure.}
    ## `record_until_enter`: the whole push-to-talk take, captured
    ## between two Enter presses, in one call.
  SttFn* = proc(audio: seq[float32]): string {.closure.}
    ## `Ears.transcribe`: audio in, one transcript out. Nothing else
    ## crosses this seam, and the transcript is stripped by the engine
    ## (Python's `Ears` does the same) — callers treat it as ready.
  TtsFn* = proc(text: string) {.closure.}
    ## The mouth, minus `speakable` (applied here): speakable text in,
    ## sound out.

proc rms*(samples: openArray[float32]): float =
  ## The loudness of one block: `float(np.sqrt((data**2).mean()))`.
  ## Divergence: the sum is accumulated in float64 (numpy's mean over
  ## float32 accumulates in float32) and an EMPTY block reads 0.0
  ## instead of NaN — NaN compares false against the threshold, so
  ## both readings stay quiet, but 0.0 is a number a caller can print.
  if samples.len == 0:
    return 0.0
  var total = 0.0
  for sample in samples:
    let v = sample.float64
    total += v * v
  return sqrt(total / samples.len.float64)

proc recordCommand*(read: SampleFn, threshold: float, maxSeconds = 15.0,
    silenceAfter = 1.2): seq[float32] =
  ## Port of `record_command`: after the wake word, keep reading the
  ## SAME stream until the speaker goes quiet, and give up after
  ## `maxSeconds` whatever happens. A block counts as speech above
  ## TWICE the threshold (`_mic_threshold() * 2`) — the margin is what
  ## keeps room noise from ending the take. The result is every block
  ## read, concatenated: the audio is handed straight to `SttFn` and
  ## never stored anywhere else.
  if read == nil:
    raise newException(CatchableError, recordSeamMissing)
  var quiet = 0
  var spoke = false
  let quietNeeded = int(silenceAfter * 10)
  for _ in 0 ..< int(maxSeconds * 10):
    let data = read(micBlock)
    result.add(data)
    let loud = rms(data) > threshold * 2.0
    spoke = spoke or loud
    quiet = if loud: 0 else: quiet + 1
    if spoke and quiet >= quietNeeded:
      break

proc waitForSpeech*(read: SampleFn, threshold: float,
    timeout: float): bool =
  ## Port of `wait_for_speech`: poll the SAME stream for the onset of
  ## speech, up to `timeout` seconds. `true` the moment a block is
  ## loud, `false` if the room stays quiet — that is what lets a
  ## conversation stay open for follow-ups without the wake word.
  if read == nil:
    raise newException(CatchableError, recordSeamMissing)
  for _ in 0 ..< int(timeout * 10):
    if rms(read(micBlock)) > threshold * 2.0:
      return true
  return false

proc captureUtterance*(record: RecordFn): seq[float32] =
  ## `record_until_enter`: the whole take, or an honest error when no
  ## mic seam is wired.
  if record == nil:
    raise newException(CatchableError, recordSeamMissing)
  return record()

proc transcribe*(stt: SttFn, audio: seq[float32]): string =
  ## `Ears.transcribe` over the seam, or an honest error naming the
  ## engine this binary does not ship.
  if stt == nil:
    raise newException(CatchableError, sttSeamMissing)
  return stt(audio)

proc speak*(tts: TtsFn, text: string) =
  ## `Mouth.speak`: speakable text only, and NOTHING for text that
  ## reduces to nothing (an all-emoji reply is silence, not a hiss).
  if tts == nil:
    raise newException(CatchableError, ttsSeamMissing)
  let said = speakable(text)
  if said.len == 0:
    return
  tts(said)

# ── decisions: the push-to-talk ladder, the wake scan, one turn ────────

type PushToTalkStep* = enum
  ## What `main`'s push-to-talk loop does with a take: too short to be
  ## a question, captured but understood as nothing, or answerable.
  ptTooShort, ptNoSpeech, ptRespond

proc pushToTalkStep*(sampleCount: int, transcript: string): PushToTalkStep =
  ## Port of `main`'s ladder: under 250ms of audio is a slip ("(too
  ## short, try again)"), an empty transcript is a missed utterance
  ## ("(didn't catch that)"), anything else is answered. The engine
  ## strips its transcript (Python's `Ears` does), so the middle branch
  ## fires on an empty string exactly as `if not heard` does.
  if sampleCount < shortUtteranceSamples:
    return ptTooShort
  if transcript.len == 0:
    return ptNoSpeech
  return ptRespond

type
  WakeAction* = enum
    ## What one 2.5s scanner window means: too quiet to transcribe, a
    ## near miss (traced — wake tuning lives in those traces), or the
    ## wake word.
    waQuiet, waNearMiss, waWake
  WakeScan* = object
    ## One scanner decision. `heard` is the transcript it was given
    ## (empty for silence), `matched` whether the wake word was in it.
    action*: WakeAction
    heard*: string
    matched*: bool

proc shouldTranscribe*(level, threshold: float): bool =
  ## The scout's gate (`if float(np.sqrt(...)) < _mic_threshold():
  ## continue`): a window at or above the threshold is worth the
  ## transcription, a quieter one is not. The comparison is `<` in
  ## Python, so a window sitting exactly ON the threshold IS
  ## transcribed — an idle room that happens to average the threshold
  ## gets one (empty) transcription, which is the cheaper mistake.
  level >= threshold

proc scanWake*(level, threshold: float, wakeWord,
    transcript: string): WakeScan =
  ## The `wake_loop` scan branch as one pure decision: a window below
  ## the threshold is silence, a loud window that misses the wake word
  ## is a near miss, and a match ends the scan. Divergence: the live
  ## loop transcribes BEFORE calling this (only when `shouldTranscribe`
  ## says so) — here the transcript is a parameter, so the decision is
  ## testable without an engine. An EMPTY transcript on a loud window
  ## is silence in effect, like Python's `status(… if heard_scan else
  ## "· listening…")` arm.
  if not shouldTranscribe(level, threshold):
    return WakeScan(action: waQuiet, heard: "", matched: false)
  if not matchesWake(transcript, wakeWord):
    if transcript.len == 0:
      return WakeScan(action: waQuiet, heard: "", matched: false)
    return WakeScan(action: waNearMiss, heard: transcript, matched: false)
  return WakeScan(action: waWake, heard: transcript, matched: true)

proc wakeStatus*(scan: WakeScan): string =
  ## The live status line for one scan: silence, or what it heard.
  if scan.heard.len == 0:
    return listeningLine
  return heardLine(scan.heard)

proc wakeScanEvent*(scan: WakeScan): JsonNode =
  ## The `wake_scan` trace payload. Near misses belong in the trace
  ## (that is how a wake word gets tuned), so 7d emits this for
  ## `waNearMiss`; the shape is Python's verbatim.
  %*{"heard": scan.heard, "matched": scan.matched}

proc voiceTurn*(text: string, respond: RespondFn, tts: TtsFn,
    logger: LogFn): bool =
  ## One spoken turn — the ladder both voice loops share, and the whole
  ## reason a voice gateway exists: the transcript goes through the
  ## SAME loop/memory/eval pipeline as typed text, because a gateway
  ## only moves words in and out. An empty transcript says "(didn't
  ## catch that)" and answers nothing; otherwise the agent answers, the
  ## reply is logged and handed to the mouth (an empty reply stays
  ## silent, like `Mouth.speak`). `true` means the turn completed.
  ##
  ## Divergence: a failing turn PROPAGATES. `voice.py` has no
  ## try/except around `waku.respond` — voice is a foreground command,
  ## not a supervised gateway — so there is no error reply to send
  ## here either, and `runGatewayTurn`'s accounting stays where Python
  ## has it. 7d's live loop owns what a voice crash does.
  if text.len == 0:
    logger(noSpeechReply)
    return false
  logger("you › " & text)
  let reply = respond(text)
  logger("waku › " & reply)
  speak(tts, reply)
  return true
