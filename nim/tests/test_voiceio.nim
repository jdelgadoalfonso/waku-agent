## Phase 7d1 tests: the three external engines behind the voice seams.
##
## 7c pinned the voice gateway with the audio left out. 7d1 fills in the
## three engines the single stdlib binary cannot ship — faster-whisper
## (a 74MB model), a neural mouth and a sound device — as EXTERNAL
## COMMANDS, which is the same honest posture the rest of the port takes
## towards things it will not vendor.
##
## So this file pins bytes and contracts, not audio: the s16le decode
## and the WAV writer against Python's own output (`struct` and the
## `wave` module), the recorder spool (pending / read / drain, which is
## what keeps the wake scanner from transcribing Waku's own tail), and
## the argv the ears and the mouth are called with. No microphone, no
## process: the recorder and the engines travel through `MicStarter` and
## `RunCommandFn`, and the one real thing a test touches is a spool file
## in the temp dir, which is where the audio would have been.

import std/os
import std/strutils
import std/times
import std/unittest

import ../src/voice
import ../src/voiceio

const
  goldenWav = "524946462c00000057415645666d74201000000001000100803e00" &
    "00007d00000200100064617461080000000000004000c0ff7f"
    ## `wave.open(...)` in Python, 16kHz mono 16-bit, four samples
    ## `0, 16384, -16384, 32767` → 52 bytes. Byte-for-byte, so a
    ## recorder that reads the file sees what Whisper expects.

proc fourFrames(): seq[float32] =
  ## The frames whose ENCODED bytes are the golden: 0 → 0x0000,
  ## 0.5 → 0x4000, -0.5 → 0xC000, 1.0 → 0x7FFF. All exactly
  ## representable in float32, which is why the pins compare with `==`
  ## instead of a tolerance. (Decoded back, 0x7FFF reads 0.999969482421875:
  ## the s16le scale is asymmetric, so 1.0 has no exact round trip.)
  @[0.0f32, 0.5f32, -0.5f32, 1.0f32]

const quietFull = 32767.0f32 / 32768.0f32
  ## What 0x7FFF decodes to: the loudest sample s16le can carry.

proc leAt(s: string, at, width: int): int =
  ## A little-endian integer read straight out of the header bytes, so a
  ## size pin checks the bytes a recorder would see.
  result = 0
  for i in 0 ..< width:
    result = result or (int(byte(s[at + i])) shl (i * 8))

proc unhex(hex: string): string =
  ## The golden as bytes: a hex pin is readable in a diff, a byte string
  ## with escapes is not.
  for i in 0 ..< hex.len div 2:
    result.add(char(parseHexInt(hex[i * 2 .. i * 2 + 1])))

proc spool(): string =
  ## A spool file the test owns, in the temp dir (the same place the
  ## live adapter writes), removed when the test ends.
  result = getTempDir() / ("waku-voiceio-test-" & $getCurrentProcessId() &
    "-" & $epochTime() & ".s16")
  removeFile(result)

proc writeRaw(path: string, values: seq[int16]) =
  var raw = newString(values.len * 2)
  for i, v in values:
    let u = cast[uint16](v)
    raw[i * 2] = char(u and 0xFF)
    raw[i * 2 + 1] = char((u shr 8) and 0xFF)
  writeFile(path, raw)

proc appendRaw(path: string, values: seq[int16]) =
  ## Append, the way a recorder writing into an open file does.
  var raw = newString(values.len * 2)
  for i, v in values:
    let u = cast[uint16](v)
    raw[i * 2] = char(u and 0xFF)
    raw[i * 2 + 1] = char((u shr 8) and 0xFF)
  var existing = ""
  if fileExists(path):
    existing = readFile(path)
  writeFile(path, existing & raw)

# ── the s16le bytes ───────────────────────────────────────────────────

suite "phase 7d1 pcm16":
  test "decodes little-endian samples exactly like Python's struct":
    var carry = ""
    let decoded = decodePcm16(unhex(goldenWav)[44 .. ^1], carry)
    check decoded.len == 4
    check decoded[0] == 0.0f32
    check decoded[1] == 0.5f32       # 16384 / 32768
    check decoded[2] == -0.5f32      # -16384 / 32768
    check decoded[3] == quietFull    # 32767 / 32768
    check carry.len == 0
    # the other direction writes the same four samples
    check pcm16Bytes(fourFrames()) == unhex(goldenWav)[44 .. ^1]

  test "an odd trailing byte waits for its other half":
    let raw = pcm16Bytes(fourFrames())
    var carry = ""
    # 5 bytes: two whole samples plus the first half of the third
    let first = decodePcm16(raw[0 .. 4], carry)
    check first.len == 2
    check first[1] == 0.5f32
    check carry.len == 1
    # the remaining 3 bytes plus the carried one are two whole samples
    let second = decodePcm16(raw[5 .. ^1], carry)
    check second.len == 2
    check carry.len == 0
    check second[0] == -0.5f32
    check second[1] == quietFull

  test "an empty chunk decodes to nothing and keeps the carry":
    var carry = "x"
    check decodePcm16("", carry).len == 0
    check carry == "x"

  test "encoding clips outside [-1, 1], like a sound card does":
    let raw = pcm16Bytes(@[-2.0f32, 2.0f32, 1.0f32, -1.0f32])
    var carry = ""
    let back = decodePcm16(raw, carry)
    check back[0] == -1.0f32
    check back[1] == quietFull
    check back[2] == quietFull
    check back[3] == -1.0f32

# ── the WAV writer ────────────────────────────────────────────────────

suite "phase 7d1 wav":
  test "the header and the samples are Python's byte for byte":
    check encodeWav(fourFrames()) == unhex(goldenWav)

  test "no audio is a valid 44-byte header with a zero data chunk":
    let empty = encodeWav(@[])
    check empty.len == 44
    check empty[0 .. 3] == "RIFF"
    check empty[36 .. 39] == "data"
    check leAt(empty, 40, 4) == 0
    check leAt(empty, 4, 4) == 36  # the RIFF size excludes the 8 bytes
                                 # of the data chunk's own header
  test "the sample rate and width ride in the header":
    let wav = encodeWav(@[0.0f32, 0.0f32], 8000)
    check leAt(wav, 24, 4) == 8000
    check leAt(wav, 28, 4) == 16000  # 8000 * 2 bytes
    check leAt(wav, 34, 2) == 16    # bits per sample
    check leAt(wav, 20, 2) == 1     # PCM, not float

# ── the command contract ──────────────────────────────────────────────

suite "phase 7d1 external engines":
  test "a command is whitespace-split argv":
    check splitCommand("arecord -q -f S16_LE -r 16000 -c 1 -t raw") ==
      @["arecord", "-q", "-f", "S16_LE", "-r", "16000", "-c", "1",
        "-t", "raw"]
    check splitCommand("   say -v Daniel  ") == @["say", "-v", "Daniel"]
    check splitCommand("").len == 0

  test "the ears get the wav path as their last argument":
    var seenArgv: seq[string] = @[]
    var seenStdin = "untouched"
    let run: RunCommandFn =
      proc(argv: seq[string], stdin: string): (int, string) {.closure.} =
        seenArgv = argv
        seenStdin = stdin
        return (0, "  what is on today \n")
    let heard = externalStt(run, "whisper-cli -m model.bin", "/tmp/a.wav")
    check seenArgv == @["whisper-cli", "-m", "model.bin", "/tmp/a.wav"]
    check seenStdin == ""     # the ears read the file, not stdin
    check heard == "what is on today"

  test "a failing engine raises naming the command and its stderr":
    let run: RunCommandFn =
      proc(argv: seq[string], stdin: string): (int, string) {.closure.} =
        return (1, "whisper-cli: cannot open model.bin")
    try:
      discard externalStt(run, "whisper-cli -m model.bin", "/tmp/a.wav")
      assert false, "must raise"
    except CatchableError as exc:
      check "whisper-cli" in exc.msg
      check "cannot open model.bin" in exc.msg

  test "the mouth gets the text on stdin and reports the outcome":
    var seenArgv: seq[string] = @[]
    var seenStdin = ""
    let run: RunCommandFn =
      proc(argv: seq[string], stdin: string): (int, string) {.closure.} =
        seenArgv = argv
        seenStdin = stdin
        return (0, "")
    check externalTts(run, "say -v Daniel", "Here is your day.")
    check seenArgv == @["say", "-v", "Daniel"]
    check seenStdin == "Here is your day."
    let broken: RunCommandFn =
      proc(argv: seq[string], stdin: string): (int, string) {.closure.} =
        return (1, "espeak: no such voice")
    check not externalTts(broken, "say -v Daniel", "hi")

  test "an unwired engine says so instead of pretending":
    for command in ["", "   "]:
      let run: RunCommandFn =
        proc(argv: seq[string], stdin: string): (int, string) {.closure.} =
          return (0, "never")
      try:
        discard externalStt(run, command, "/tmp/a.wav")
        assert false, "must raise"
      except CatchableError as exc:
        check "WAKU_STT_COMMAND" in exc.msg
      check not externalTts(run, command, "hi")
    let noStarter: MicStarter = nil
    try:
      discard externalMic(noStarter, "arecord -q")
      assert false, "must raise"
    except CatchableError as exc:
      check "WAKU_MIC_COMMAND" in exc.msg
    let declining: MicStarter =
      proc(argv: seq[string]): MicProcess {.closure.} = nil
    try:
      discard externalMic(declining, "arecord -q")
      assert false, "must raise"
    except CatchableError as exc:
      check "WAKU_MIC_COMMAND" in exc.msg

# ── the recorder spool ────────────────────────────────────────────────

suite "phase 7d1 external mic":
  test "the recorder argv ends with the spool path, and the file is ours":
    var seenArgv: seq[string] = @[]
    let starter: MicStarter =
      proc(argv: seq[string]): MicProcess {.closure.} =
        seenArgv = argv
        return MicProcess(
          alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard)
    let mic = externalMic(starter, "arecord -q -t raw", "/tmp/waku.s16")
    check seenArgv == @["arecord", "-q", "-t", "raw", "/tmp/waku.s16"]
    check mic.engine == "arecord"
    check mic.path == "/tmp/waku.s16"
    check micPending(mic) == 0

  test "pending counts samples, read takes exactly what it asks for":
    let path = spool()
    defer: removeFile(path)
    writeRaw(path, seq[int16](@[1000i16, 2000i16, 3000i16, 4000i16, 5000i16, 6000i16]))
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    check micPending(mic) == 6
    let first = micRead(mic, 4)
    check first.len == 4
    check first[0] == 1000.0f32 / 32768.0f32
    check first[3] == 4000.0f32 / 32768.0f32
    check micPending(mic) == 2
    let rest = micRead(mic, 2)
    check rest.len == 2
    check micPending(mic) == 0

  test "drain drops the backlog and says how much":
    let path = spool()
    defer: removeFile(path)
    writeRaw(path, seq[int16](@[1000i16, 2000i16, 3000i16]))
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    let dropped = micDrain(mic)
    check dropped == 3
    check micPending(mic) == 0
    check micDrain(mic) == 0
    # audio captured while Waku spoke is gone: the wake scanner cannot
    # hear its own tail
    appendRaw(path, seq[int16](@[9000i16]))
    check micPending(mic) == 1

  test "a read with nothing to read waits, then gives up by name":
    let path = spool()
    defer: removeFile(path)
    writeFile(path, "")
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    try:
      discard micRead(mic, 1600, timeoutMs = 40)
      assert false, "must raise"
    except CatchableError as exc:
      check "cat" in exc.msg
      check "1600" in exc.msg

  test "a dead recorder raises instead of waiting out the timeout":
    let path = spool()
    defer: removeFile(path)
    writeFile(path, "")
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = false,
          stop: proc() {.closure.} = discard), "arecord", path)
    try:
      discard micRead(mic, 1600, timeoutMs = 5000)
      assert false, "must raise"
    except CatchableError as exc:
      check "arecord" in exc.msg

  test "close stops the recorder once and refuses later reads":
    let path = spool()
    writeRaw(path, seq[int16](@[1000i16, 2000i16]))
    var stops = 0
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = inc stops), "cat", path)
    discard micRead(mic, 2)
    micClose(mic)
    micClose(mic)
    check stops == 1
    try:
      discard micRead(mic, 2, timeoutMs = 40)
      assert false, "must raise"
    except CatchableError as exc:
      check "cat" in exc.msg

  test "the spool is recycled once it outgrows its cap":
    let path = spool()
    defer: removeFile(path)
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    check not needsMicRecycle(mic, 1024)
    appendRaw(path, seq[int16](@[1000i16, 2000i16, 3000i16, 4000i16]))  # 8 bytes
    check needsMicRecycle(mic, 4)
    check not needsMicRecycle(mic, 8)
    discard micDrain(mic)
    check not needsMicRecycle(mic, 4)

  test "a take is block-aligned: every pending sample, zero-padded":
    let path = spool()
    defer: removeFile(path)
    writeRaw(path, seq[int16](@[1000'i16, -1000'i16, 2000'i16]))  # 3 samples
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    let take = micReadAll(mic)
    check take.len == micBlock          # zero-padded to one 100ms block
    check take[0] == 1000.0f32 / 32768.0f32
    check take[2] == 2000.0f32 / 32768.0f32
    check take[3] == 0.0f32             # the padding
    check micPending(mic) == 0
    check micReadAll(mic).len == 0      # nothing left: no empty block

  test "a take in whole blocks reads exactly what the recorder wrote":
    let path = spool()
    defer: removeFile(path)
    var whole = newSeq[int16](micBlock * 2)
    for i in 0 ..< whole.len:
      whole[i] = int16(i mod 3000)
    writeRaw(path, whole)
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    let take = micReadAll(mic)
    check take.len == micBlock * 2
    check take[0] == 0.0f32
    check take[1] == 1.0f32 / 32768.0f32

  test "closing removes the spool, so the next take starts clean":
    let path = spool()
    writeRaw(path, seq[int16](@[1000'i16, 2000'i16]))
    check fileExists(path)
    let mic = externalMic(
      proc(argv: seq[string]): MicProcess {.closure.} =
        MicProcess(alive: proc(): bool {.closure.} = true,
          stop: proc() {.closure.} = discard), "cat", path)
    discard micRead(mic, 2)
    micClose(mic)
    check not fileExists(path)
    micClose(mic)   # idempotent: the second call must not raise
