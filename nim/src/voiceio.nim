## The three engines the stdlib binary does not ship, phase 7d1.
##
## `voice.nim` (7c) pinned the voice gateway with the audio left out: a
## `nil` seam raises an honest error naming the engine it waits for. This
## module is what fills those seams in, and it fills them with EXTERNAL
## COMMANDS instead of libraries, because the three things Python gets
## from `pip install 'waku-agent[voice]'` cannot live in one stdlib
## binary: a 74MB faster-whisper model, an 82M-parameter neural voice
## (kokoro) and a sound device. Rule 3's answer to a dependency is an
## opt-in behind an extra; in a single binary the honest equivalent is an
## opt-in command line that the person chooses to set.
##
##   WAKU_MIC_COMMAND  a recorder writing RAW mono s16le at 16kHz to the
##                     file named by its LAST argument
##                       arecord -q -f S16_LE -r 16000 -c 1 -t raw
##                       sox -q -r 16000 -c 1 -t raw
##                       ffmpeg -loglevel quiet -f s16le -ar 16000 -ac 1
##                             -i - -f s16le -y
##   WAKU_STT_COMMAND  the ears: reads the 16kHz mono WAV named by its
##                     last argument, prints the transcript on stdout
##                       whisper-cli -m ~/models/ggml-base.bin -nt
##   WAKU_TTS_COMMAND  the mouth: reads the speakable text on stdin
##                       say -v Daniel
##
## A missing command is not a failure: `voiceMain` says which one is
## missing and exits. That is the same posture as 7c's `sttSeamMissing`,
## one level up — the seam exists, and it is honest about what has to be
## installed to fill it.
##
## Nothing here is clever about audio: the decode is `s16le → float32`
## and the writer is a 44-byte RIFF/WAVE header plus s16le samples, both
## pinned byte-for-byte against Python (`struct.unpack` and the `wave`
## module) in `test_voiceio.nim`. The interesting decision is the
## recorder's SPOOL FILE: the mic writes into a file and the port reads
## from it, instead of a pipe, because a pipe cannot be drained without
## blocking — and `drain()` after Waku speaks is what stops the wake
## scanner from transcribing Waku's own voice. A file's backlog is a file
## offset, so draining is exact (`micDrain` moves the offset to the end),
## which is the whole reason this is a file and not a pipe.

import std/math
import std/os
import std/osproc
import std/streams
import std/strutils

proc le16(value: int): string =
  ## One little-endian 16-bit field (a WAV chunk is a byte layout, not
  ## a computation, and the byte order has to be explicit at every byte).
  result = newString(2)
  result[0] = char(value and 0xFF)
  result[1] = char((value shr 8) and 0xFF)

proc le32(value: int): string =
  ## One little-endian 32-bit field.
  result = newString(4)
  for i in 0 .. 3:
    result[i] = char((value shr (i * 8)) and 0xFF)

const
  externalMicMissing* = "voice mic is not wired: WAKU_MIC_COMMAND is " &
    "unset. The stdlib binary has no sound device, so the ears of the " &
    "mic are an external recorder that writes raw s16le at 16kHz to " &
    "the file named by its last argument (arecord, sox or ffmpeg)"
  externalSttMissing* = "voice SttFn is not wired: WAKU_STT_COMMAND is " &
    "unset. The 74MB faster-whisper ears are an external engine that " &
    "reads the WAV named by its last argument and prints the transcript"
  externalTtsMissing* = "voice TtsFn is not wired: WAKU_TTS_COMMAND is " &
    "unset. The kokoro/say mouth is an external engine that reads the " &
    "text on stdin — without it your replies stay text on screen"
  spoolCapBytes* = 32 * 1024 * 1024
    ## A spool cap of ~17 minutes of audio (16kHz s16le is 32KB/s). The
    ## port recycles the recorder between takes once the file passes it,
    ## because an always-listening session would otherwise grow a
    ## gigabyte-sized file in the temp dir (often a tmpfs, i.e. RAM).
    ## Recycling never happens mid-phrase: that is the freeze Python's
    ## first version had, re-opening the device per phase.
  micReadPollMs* = 5
    ## How often a read waiting for the recorder checks the spool. Small
    ## enough to feel like audio, big enough not to spin a core.

# ── s16le samples ─────────────────────────────────────────────────────

proc decodePcm16*(raw: string, carry: var string): seq[float32] =
  ## Little-endian signed 16-bit samples as float32 in [-1, 1], exactly
  ## what Python's `struct.unpack('<h', …)` / 32768.0 gives. A recorder
  ## hands bytes, not samples, so a chunk boundary can land mid-sample:
  ## the odd byte is left in `carry` and prepended to the next chunk.
  ## `carry` holds at most one byte.
  result = @[]
  var joined = carry
  joined.add(raw)
  carry = ""
  let whole = joined.len div 2
  if whole == 0:
    if joined.len > 0:
      carry = joined
    return result
  if joined.len mod 2 != 0:
    carry = joined[whole * 2 .. ^1]
  for i in 0 ..< whole:
    let lo = byte(joined[i * 2])
    let hi = byte(joined[i * 2 + 1])
    let bits = (int16(hi) shl 8) or int16(lo)
    result.add(bits.float32 / 32768.0f32)

proc pcm16Bytes*(samples: openArray[float32]): string =
  ## The other direction: samples as little-endian s16le, clipped to
  ## [-1, 1] the way a sound card clips. The scale is ASYMMETRIC, as
  ## every s16 encoder is: a full negative is -32768 (which decodes back
  ## to exactly -1.0) while a full positive is 32767 (which has no
  ## 32768 to reach, so +1.0 reads back as 0.999969482421875). Rounding
  ## is half-away-from-zero, which differs from Python's `round` (half to
  ## even) by one LSB on an exact .5 — the port never encodes one, and
  ## the pins against Python's `wave` output are byte-exact.
  result = newString(samples.len * 2)
  for i, sample in samples:
    let v = sample.float64
    var scaled = if v < 0.0: round(v * 32768.0) else: round(v * 32767.0)
    if scaled > 32767.0: scaled = 32767.0
    elif scaled < -32768.0: scaled = -32768.0
    let u = cast[uint16](int16(scaled.int))
    result[i * 2] = char(u and 0xFF'u16)
    result[i * 2 + 1] = char((u shr 8) and 0xFF'u16)

# ── the WAV the ears read ─────────────────────────────────────────────

proc wavHeader*(dataLen, sampleRate: int, channels = 1,
    bits = 16): string =
  ## The 44-byte canonical RIFF/WAVE header (`wave` module layout:
  ## `RIFF`/`fmt `/`data`, PCM, little-endian), with sizes already
  ## resolved. Shared by `encodeWav` and pinned on its own, so a header
  ## change cannot hide behind the data.
  const byteRateMul = 2  # 16-bit samples: two bytes per sample per channel
  let byteRate = sampleRate * channels * byteRateMul
  let blockAlign = channels * (bits div 8)
  result = "RIFF" & le32(36 + dataLen) & "WAVE" &
    "fmt " & le32(16) & le16(1) & le16(channels) &
    le32(sampleRate) & le32(byteRate) & le16(blockAlign) & le16(bits) &
    "data" & le32(dataLen)

proc encodeWav*(samples: openArray[float32],
    sampleRate = 16000): string =
  ## A whole WAV file: header + s16le samples, byte-for-byte what
  ## Python's `wave` module writes for the same frames (pinned in
  ## `test_voiceio.nim`).
  let pcm = pcm16Bytes(samples)
  result = wavHeader(pcm.len, sampleRate) & pcm

# ── the command contract ──────────────────────────────────────────────

type
  RunCommandFn* = proc(argv: seq[string], stdin: string): tuple[
      code: int, output: string] {.closure.}
    ## Run one external engine to completion: argv, optional stdin,
    ## `(exit code, stdout + stderr)`. The live implementation is
    ## `runCommandLive` (a real subprocess, never called in tests);
    ## tests script it and read the argv back.
  MicProcess* = ref object
    ## One running recorder. Two facts about it, no more: is it still
    ## alive, and stop it. The process itself stays private to the live
    ## adapter, because a spool file is the whole interface.
    alive*: proc(): bool {.closure.}
    stop*: proc() {.closure.}
  MicStarter* = proc(argv: seq[string]): MicProcess {.closure.}
    ## Start a recorder whose last argument is the spool path. Nil (or a
    ## starter that returns nil) is an honest failure, not a silent mic.

proc splitCommand*(raw: string): seq[string] =
  ## `WAKU_*_COMMAND` as argv: split on whitespace, blanks dropped. A
  ## quoted path with spaces is NOT supported — the spool path lives in
  ## the temp dir, and a quoting scheme would be a knob nobody sets
  ## right.
  for word in raw.splitWhitespace():
    result.add(word)

proc engineFailure*(command: string, code: int, output: string): string =
  ## The message a failed engine raises: the command, the exit code and
  ## whatever the engine printed, so the terminal says why without the
  ## person re-running it by hand first.
  let name = splitCommand(command)
  let head = if name.len > 0: name[0] else: "the engine"
  var msg = "voice engine " & head & " failed (exit " & $code & ")"
  if output.len > 0:
    msg.add(": " & output.strip())
  msg

proc externalStt*(run: RunCommandFn, command: string, wavPath: string): string =
  ## `Ears.transcribe` over the external engine: the WAV path is the
  ## LAST argument and the transcript comes back on stdout, stripped
  ## (Python's `Ears` joins stripped segments and strips the result, so a
  ## caller can treat what it gets as ready). An unset command raises
  ## naming the variable to set.
  let argv = splitCommand(command)
  if argv.len == 0:
    raise newException(CatchableError, externalSttMissing)
  let (code, output) = run(argv & @[wavPath], "")
  if code != 0:
    raise newException(CatchableError, engineFailure(command, code, output))
  return output.strip()

proc externalTts*(run: RunCommandFn, command: string, text: string): bool =
  ## `Mouth.speak` over the external engine: the speakable text goes on
  ## stdin (an argv would need quoting, and a reply can contain
  ## anything). `true` when the engine exited 0. An unset command
  ## returns `false` — a missing mouth is not a failure, it is the
  ## `(no TTS engine on this platform — …)` branch in plain text, and
  ## `voiceMain` says so once at startup.
  let argv = splitCommand(command)
  if argv.len == 0:
    return false
  let (code, _) = run(argv, text)
  return code == 0

# ── the recorder spool ────────────────────────────────────────────────

type
  ExternalMic* = ref object
    ## The ONE persistent mic (Python's `sd.InputStream`, opened once for
    ## the whole session and never re-opened — re-opening the device per
    ## phase is how the first version froze). Here it is a spool file
    ## plus the recorder writing into it: `pos` is this port's read
    ## offset, so `micDrain` is exact instead of best-effort, and the
    ## file is what makes "is the device still alive" answerable without
    ## a device.
    path*: string
    pos*: int
    engine*: string
    process*: MicProcess
    closed*: bool

proc externalMic*(starter: MicStarter, command: string,
    pathTo = ""): ExternalMic =
  ## Bind the spool and start the recorder with the path as its last
  ## argument. `path` defaults to a file in the temp dir, named after
  ## this process so two Waku voices cannot share a spool. A blank
  ## command, a nil starter or a starter that declines raises naming
  ## `WAKU_MIC_COMMAND` — the honest answer instead of a silent mic.
  let argv = splitCommand(command)
  if argv.len == 0 or starter.isNil:
    raise newException(CatchableError, externalMicMissing)
  var path = pathTo
  if path.len == 0:
    path = getTempDir() / ("waku-voice-" & $getCurrentProcessId() & ".s16")
  let handle = starter(argv & @[path])
  if handle.isNil:
    raise newException(CatchableError, externalMicMissing)
  ExternalMic(path: path, pos: 0, engine: argv[0], process: handle,
    closed: false)

proc micPending*(m: ExternalMic): int =
  ## `isNil` is not paranoia: a caller that could not open a recorder
  ## holds nil, and every mic proc below has to answer for it instead of
  ## taking the whole session down.
  ## Samples the recorder has written and this port has not read — the
  ## spool's answer to `stream.read_available`. Zero once the take is
  ## consumed; a missing file reads as zero (the recorder never wrote).
  if m.isNil or not fileExists(m.path):
    return 0  # the recorder has not written its first byte yet
  let size = getFileSize(m.path)
  if size < m.pos:
    return 0
  (size - m.pos) div 2

proc spoolSize(m: ExternalMic): int =
  ## The recorder's file size right now, zero when it is not there yet.
  if fileExists(m.path): getFileSize(m.path) else: 0

proc micDrain*(m: ExternalMic): int =
  ## Throw the backlog away, exactly like `drain()` after Waku speaks:
  ## the offset jumps to the end of the file, so the wake scanner cannot
  ## transcribe the tail of Waku's own voice. Returns how many samples
  ## were dropped (zero is a valid answer).
  if m.isNil:
    return 0
  let pending = micPending(m)
  m.pos = spoolSize(m)
  pending

proc needsMicRecycle*(m: ExternalMic, cap = spoolCapBytes): bool =
  ## Whether the spool has outgrown its cap (`spoolCapBytes`). The caller
  ## recycles BETWEEN takes, never mid-phrase.
  if m.isNil:
    return false
  (if fileExists(m.path): getFileSize(m.path) else: 0) - m.pos > cap

proc micRead*(m: ExternalMic, frameCount: int, timeoutMs = 1000): seq[float32] =
  ## One block of `frameCount` samples, the `stream.read(block)` every
  ## voice state machine is built on. It WAITS for the recorder: audio
  ## arrives in real time, and a read that returned early would hand the
  ## command machines silence. Two honest failures: the recorder is gone
  ## (it exits, or its device is unplugged) or nothing arrived within
  ## `timeoutMs` (a muted or missing input). Both name the engine and
  ## the sample count, because "voice died" with no numbers is a
  ## miserable thing to debug at 1am.
  if m.isNil:
    raise newException(CatchableError, externalMicMissing)
  if m.closed:
    raise newException(CatchableError,
      "voice mic is closed: " & m.engine)
  var waited = 0
  while micPending(m) < frameCount:
    if not m.process.isNil and not m.process.alive():
      raise newException(CatchableError,
        "voice recorder " & m.engine & " stopped; no audio for " &
        $frameCount & " samples")
    if waited >= timeoutMs:
      raise newException(CatchableError,
        "voice recorder " & m.engine & " produced no audio for " &
        $frameCount & " samples in " & $timeoutMs & "ms")
    sleep(micReadPollMs)
    waited += micReadPollMs
  # one open per read: the recorder holds its own handle on the far end
  # of the spool, and at a 10Hz read rate the open is noise next to the
  # model call that follows it
  var raw = newString(frameCount * 2)
  let f = open(m.path, fmRead)
  try:
    f.setFilePos(m.pos)
    discard f.readBuffer(addr raw[0], raw.len)
  finally:
    f.close()
  m.pos += raw.len
  var carry = ""
  result = decodePcm16(raw, carry)

proc micReadAll*(m: ExternalMic, chunk = 1600): seq[float32] =
  ## Everything the recorder has captured, read in whole `block`-sample
  ## reads. The LAST read is zero-padded when the spool ends mid-block,
  ## because a take that is not block-aligned is a take whose last
  ## millisecond is a partial sample every audio tool has to special-case.
  ## Nothing pending means no block at all (an empty read is silence, and
  ## silence that never happened is not a take).
  result = @[]
  if m.isNil:
    return result
  while micPending(m) > 0:
    let want = min(chunk, micPending(m))
    let got = micRead(m, want, timeoutMs = 0)
    if got.len < chunk:
      var padded = newSeq[float32](chunk)
      for i in 0 ..< got.len:
        padded[i] = got[i]
      result.add(padded)
    else:
      result.add(got)

proc micClose*(m: ExternalMic) =
  ## Stop the recorder, once, and remove its spool. Idempotent, because
  ## the wake loop and the command's own cleanup both call it and
  ## Python's `with sd.InputStream(...)` closed the stream in a `finally`
  ## too. Removing the file is what keeps the next take (push-to-talk
  ## reuses this process's path) from inheriting the last one's bytes; on
  ## POSIX the recorder's own handle stays valid until it exits, so the
  ## unlink cannot truncate audio it is still writing.
  if m.isNil or m.closed:
    return
  m.closed = true
  if not m.process.isNil and m.process.stop != nil:
    m.process.stop()
  try:
    removeFile(m.path)
  except CatchableError:
    discard

# ── the live adapters (never called in tests) ─────────────────────────

proc runCommandLive*(argv: seq[string], stdin: string): tuple[
    code: int, output: string] =
  ## Run one engine and wait: stdout and stderr share a pipe (an engine's
  ## error is usually on stderr and a person needs it), stdin is the text
  ## the mouth speaks. Real subprocess — never called in tests, which
  ## inject `RunCommandFn` scripts and read the argv back.
  var child: Process
  try:
    child = startProcess(argv[0], args = argv[1 .. ^1],
      options = {poUsePath, poStdErrToStdOut})
  except CatchableError as exc:
    return (code: 127, output: exc.msg)
  let toChild = FileStream(child.inputStream)
  if stdin.len > 0:
    try:
      toChild.write(stdin)
      toChild.flush()
    except CatchableError:
      discard
  toChild.close()
  let output = child.outputStream.readAll()
  let code = child.waitForExit()
  child.close()
  (code: code, output: output)

proc startRecorderLive*(argv: seq[string]): MicProcess =
  ## Start a long-running recorder: `argv[0]` is the command, the rest is
  ## its arguments (the spool path is already the last one), and the
  ## child inherits stderr so a recorder that complains (a missing
  ## device, a busy one) says so on the terminal. Real subprocess —
  ## never called in tests.
  let child = startProcess(argv[0], args = argv[1 .. ^1],
    options = {poUsePath})
  result = MicProcess(
    alive: proc(): bool {.closure.} = running(child),
    stop: proc() {.closure.} =
      if running(child):
        terminate(child)
      discard child.waitForExit()
      child.close())
