## T3: the rulebook pins, ported from `evals/deterministic/test_rulebook.py`.
##
## That Python file holds 17 pins. The five carried here are the ones that
## read the rulebook itself — the docs index, the links the rulebook routes
## through, the caps, the no-emoji rule and the `CLAUDE.md` import — so
## retiring `evals/deterministic/` would otherwise lose them (S3), and each
## of them fails on the same fact its Python twin fails on (S5). The Python
## tests stay exactly where they are: this suite is additive, never a
## replacement, the same way `test_repo_gates.nim` is.
##
## What the other Nim suites already hold is not repeated here.
## `test_repo_gates.nim` owns the reach bans, one definition per name, the
## copied design digests and the CI table; `test_version.nim` owns the
## version, `test_embed.nim` the embed, `test_dashboard.nim` the served
## route surface.
##
## Every path is anchored to this file's own location, so the suite reads
## the checkout it ships with from `nim/`, from the repo root or from
## anywhere else. Read-only: file reads only, no network, no subprocess,
## nothing written anywhere.

import std/[algorithm, os, sets, strutils, unicode, unittest]

const
  AgentsCap = 100
    ## `test_rulebook.py:22`, `README_CAP`'s sibling. AGENTS.md is the first
    ## file every contributor and every agent reads; detail goes down into
    ## `docs/context/`, not into it.

  ReadmeCap = 200
    ## `test_rulebook.py:22`, `README_CAP`. The README grew to 493 lines
    ## once; the long material lives in `docs/` now.

  StatusCap = 120
    ## `test_rulebook.py:118-122`. `docs/status.md` is rewritten whole, so
    ## it cannot become a changelog by accreting paragraphs.

  StatusStamp = "**Last updated:** "
    ## The line `docs/status.md` has to keep, from the same pin: the literal
    ## before the date. `test_rulebook.py` spells the whole shape as
    ## `\*\*Last updated:\*\* \d{4}-\d{2}-\d{2}`.

  DocsIndex = "README.md"
    ## `test_rulebook.py:98-105` reads `docs/README.md` as the index of
    ## `docs/`. It is the one file the pin does not require to be listed.

  LinkPrefixes = ["http://", "https://", "mailto:", "#"]
    ## `_local_links` (`test_rulebook.py:59-63`): everything else is a path
    ## that has to exist on disk, so a link to another site or to an anchor
    ## on the same page is not a path at all.

  EmojiBlocks = [(0x1F300'i32, 0x1FAFF'i32)]
    ## `EMOJI` (`test_rulebook.py:49-56`), first alternative: the emoji
    ## blocks, which render as colour emoji with no variation selector.
    ## Written as code points because AGENTS.md rule 6 forbids the
    ## characters themselves in this repo, this file included.

  EmojiWithSelector = [(0x2600'i32, 0x27BF'i32), (0x2B00'i32, 0x2BFF'i32)]
    ## The second alternative: dingbats and the older symbols, but only when
    ## U+FE0F FORCES emoji presentation. A bare arrow or a plain star stays
    ## typography, which is why this is not folded into the list below.

  EmojiSelector = 0xFE0F'i32
    ## U+FE0F VARIATION SELECTOR-16, the character that decides the
    ## alternative above.

  EmojiAlone = [
    (0x231A'i32, 0x231B'i32), # watch, hourglass
    (0x23E9'i32, 0x23F3'i32), # the six fast-forward/reverse signs and the timers
    (0x2614'i32, 0x2615'i32), # umbrella with rain drops, hot beverage
    (0x26A1'i32, 0x26A1'i32), # high voltage
    (0x26AA'i32, 0x26AB'i32), # medium white and black circle
    (0x26BD'i32, 0x26BE'i32), # soccer ball, baseball
    (0x26C4'i32, 0x26C5'i32), # snowman without snow, sun behind cloud
    (0x26D4'i32, 0x26D4'i32), # no entry
    (0x26EA'i32, 0x26EA'i32), # church
    (0x26F2'i32, 0x26F3'i32), # fountain, flag in hole
    (0x26F5'i32, 0x26F5'i32), # sailboat
    (0x26FA'i32, 0x26FA'i32), # tent
    (0x26FD'i32, 0x26FD'i32), # fuel pump
    (0x2705'i32, 0x2705'i32), # white heavy check mark
    (0x270A'i32, 0x270B'i32), # raised fist, raised hand
    (0x2728'i32, 0x2728'i32), # sparkles
    (0x274C'i32, 0x274C'i32), # cross mark
    (0x274E'i32, 0x274E'i32), # negative squared cross mark
    (0x2753'i32, 0x2755'i32), # red, white and black question mark ornament
    (0x2757'i32, 0x2757'i32), # heavy exclamation mark
    (0x2795'i32, 0x2797'i32), # heavy plus, minus and division signs
    (0x27B0'i32, 0x27B0'i32), # curly loop
    (0x27BF'i32, 0x27BF'i32), # double curly loop
    (0x2B1B'i32, 0x2B1C'i32), # large black and white square
    (0x2B50'i32, 0x2B50'i32), # white medium star
    (0x2B55'i32, 0x2B55'i32)  # heavy large circle
  ]
    ## The third alternative: the handful of older symbols that default to
    ## emoji presentation, spelled out in `EMOJI` one by one. Ranges are the
    ## runs Python writes with a dash; the rest are single characters.

  ForeignBreaks = [0x0B'i32, 0x0C'i32, 0x1C'i32, 0x1D'i32, 0x1E'i32,
    0x85'i32, 0x2028'i32, 0x2029'i32]
    ## The line boundaries Python's `str.splitlines()` honours and Nim's
    ## `splitLines` does not. `pyLines` below counts lines the way the caps
    ## were measured, so the file a cap is read from must not contain one of
    ## these: if it did, the two counts would disagree and the pin would be
    ## measuring something else. The pin says so rather than guessing.

# --- paths, and the one way this suite finds the tree -----------------------

proc repoRoot(): string =
  ## The repo root, from this file's own path and never from the working
  ## directory: `absolutePath` so a compiler handed a relative path still
  ## lands on the same tree.
  absolutePath(currentSourcePath().parentDir / ".." / "..")

proc at(base, rel: string): string =
  ## One path under `base`, from a slash-separated name, so the pins below
  ## read like the Python they came from on any platform.
  base / rel.replace('/', DirSep)

proc join(root: string, parts: openArray[string]): seq[string] =
  ## The same for a list, which is how `RULEBOOK` reads.
  for part in parts:
    result.add at(root, part)

# --- reading markdown: lines, links and characters --------------------------

proc pyLines(text: string): seq[string] =
  ## The lines of `text` counted the way Python's `str.splitlines()` counts
  ## them, because that is how every cap in `test_rulebook.py` is measured.
  ## The two differences from Nim's own `splitLines` both show up on real
  ## files: Python produces no trailing empty element for text that ends in
  ## a line break (so `"a\n"` is one line, not two) and no element at all
  ## for empty text. A byte loop is safe here: `\r` and `\n` are ASCII and
  ## never continue a UTF-8 sequence.
  var i = 0
  var start = 0
  while i < text.len:
    if text[i] == '\n' or text[i] == '\r':
      result.add text[start ..< i]
      if text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n':
        i.inc
      i.inc
      start = i
    else:
      i.inc
  if start < text.len:
    result.add text[start ..< text.len]

proc runesOf(line: string): seq[Rune] =
  ## The code points of one line. The emoji set is a set of CHARACTERS, and
  ## every one of them is multi-byte in UTF-8, so a byte scan would read the
  ## same bytes as several unrelated characters.
  for rune in line.runes:
    result.add rune

proc linkTargets(markdown: string): seq[string] =
  ## Every `[text](target)` target in one document: `LINK` in
  ## `test_rulebook.py:44`, `\[[^\]]*\]\(([^)\s]+)\)`, read by hand.
  ##
  ## The equivalent of the regex is worth stating, because two details are
  ## easy to lose: the link text may not contain `]`, so the first `]` is
  ## the one that counts, and the target stops at the first `)` or
  ## whitespace. When the `](` is not there the scan resumes at the NEXT
  ## character, not past the bracket, which is how a regex engine retries —
  ## `[a] [b](c)` therefore finds `c`. An image `![alt](x)` is found too, as
  ## it is by the regex.
  var i = 0
  while i < markdown.len:
    if markdown[i] != '[':
      i.inc
      continue
    var close = i + 1
    while close < markdown.len and markdown[close] != ']':
      close.inc
    if close + 1 >= markdown.len or markdown[close + 1] != '(':
      i.inc
      continue
    var k = close + 2
    var target = ""
    while k < markdown.len and markdown[k] notin {' ', '\t', '\n', '\r', '\v', '\f', ')'}:
      target.add markdown[k]
      k.inc
    if target.len == 0 or k >= markdown.len or markdown[k] != ')':
      i.inc
      continue
    result.add target
    i = k + 1

proc isLocalLink(target: string): bool =
  ## Whether a link target is a path on disk rather than a site, an address
  ## or a fragment of the page it sits on. `_local_links`, `:76-81`.
  for prefix in LinkPrefixes:
    if target.startsWith(prefix):
      return false
  true

proc localLinks(markdown: string): seq[string] =
  ## The targets of one document that have to resolve.
  for target in linkTargets(markdown):
    if isLocalLink(target):
      result.add target

proc resolved(baseDir, target: string): string =
  ## Where a link target lands, with its `#fragment` dropped at the FIRST
  ## `#` (Python's `target.split("#", 1)[0]`) and its `.` and `..` folded.
  ##
  ## `normalizedPath` and not `expandFilename`: the latter calls `realpath`
  ## on POSIX and so raises for a path that does not exist, which is exactly
  ## the input these pins compare and report. The price is that this folds
  ## names without following symlinks where Python's `resolve()` does; the
  ## docs-index pin refuses to rely on that difference.
  let path = target.split('#', 1)[0]
  normalizedPath(absolutePath(baseDir) / path.replace('/', DirSep))

proc existsAt(baseDir, target: string): bool =
  ## `Path.exists()`: true for a file or a directory. The rulebook links to
  ## both — `hosted/README.md` and `docs/whiteboards/` are the same kind of
  ## claim.
  let path = resolved(baseDir, target)
  fileExists(path) or dirExists(path)

proc brokenLinks(baseDir, markdown: string): seq[string] =
  ## The local targets of one document that land nowhere. `baseDir` is the
  ## document's own directory, as `doc.parent` is in Python.
  for target in localLinks(markdown):
    if not existsAt(baseDir, target):
      result.add target

# --- the docs index --------------------------------------------------------

proc markdownFilesIn(dir: string): seq[string] =
  ## Every `*.md` file directly under one directory, absolute and sorted. A
  ## glob, not a walk: `test_rulebook.py:103` reads `docs/*.md` and
  ## `docs/context/*.md`, and a doc nested deeper is not its business.
  for kind, path in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".md"):
      result.add path
  result.sort(cmp[string])

proc missingFromIndex(indexText, docsDir: string,
    docs: openArray[string]): seq[string] =
  ## The docs the index does not link to. `docs` are names relative to
  ## `docsDir`, which is what makes this drivable on a constructed index
  ## without touching the tree.
  var linked = initHashSet[string]()
  for target in localLinks(indexText):
    linked.incl resolved(docsDir, target)
  for doc in docs:
    if resolved(docsDir, doc) notin linked:
      result.add doc

# --- the rulebook set ------------------------------------------------------

proc labTopics(root: string): seq[string] =
  ## Every `lab/` topic that is a topic: a directory whose name does not
  ## start with `_` (the template) or `.` (never a topic). `LAB_TOPICS`,
  ## `test_rulebook.py:20`.
  for kind, path in walkDir(at(root, "lab")):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let name = path.lastPathPart
    if name.len > 0 and name[0] notin {'_', '.'}:
      result.add path
  result.sort(cmp[string])

proc rulebook(root: string): seq[string] =
  ## The documents whose links have to resolve and whose lines have to stay
  ## emoji-free: `RULEBOOK`, `test_rulebook.py:23-42`, in the order Python
  ## builds it. `docs/context/*.md` and the topic READMEs are read from the
  ## tree rather than listed, exactly as the Python list does, so a new
  ## context file joins the rulebook without anyone editing this suite.
  ##
  ## Two of these documents live in `examples/` and `lab/`: the Python list
  ## names them, so this one has to as well, which is the one place this
  ## suite spells those trees out. Reading a README from them is not the
  ## reach AGENTS.md rules 1 and 5 forbid — that rule is about product code
  ## and the gate depending on the lessons' content — and
  ## `test_repo_gates.nim`'s reach scan says so: its `LiteralExempt` set
  ## holds this file's name, so the literal scan skips it while both import
  ## scans still cover it. That set is the twin of the exemption
  ## `test_rulebook.py:148-156` grants `test_hosted_boundary.py`, and it is
  ## a name in one place rather than a hole in the guard. Dropping the two
  ## documents instead would be the weakening S5 forbids, because `RULEBOOK`
  ## is exactly the set that may not shrink.
  result.add join(root, ["README.md", "AGENTS.md", "CONTRIBUTING.md",
    "docs/README.md", "docs/status.md"])
  for name in ["getting-started.md", "tour.md", "evals.md", "commands.md",
      "roadmap.md"]:
    result.add at(root, "docs/" & name)
  for path in markdownFilesIn(at(root, "docs/context")):
    result.add path
  result.add join(root, ["examples/README.md", "hosted/README.md",
    "lab/README.md"])
  for topic in labTopics(root):
    result.add topic / "README.md"

proc relativeToRoot(root, path: string): string =
  ## One path as the rulebook writes it, so a failure names `docs/status.md`
  ## and not an absolute path from the machine that ran it.
  try:
    relativePath(path, root, '/')
  except ValueError:
    path

# --- emoji, cap by cap -----------------------------------------------------

proc within(value: int32, spans: openArray[(int32, int32)]): bool =
  ## Whether one code point falls inside any of these closed ranges.
  for span in spans:
    if value >= span[0] and value <= span[1]:
      return true
  false

proc rendersAsEmoji(runes: seq[Rune], index: int): bool =
  ## Whether the code point at `index` is one `EMOJI` matches in any of its
  ## three alternatives.
  let value = int32(runes[index])
  if within(value, EmojiBlocks):
    return true
  if within(value, EmojiWithSelector) and index + 1 < runes.len and
      int32(runes[index + 1]) == EmojiSelector:
    return true
  within(value, EmojiAlone)

proc emojiHits(label, text: string): seq[string] =
  ## One entry per line that holds an emoji, numbered from 1 like
  ## `test_rulebook.py:200-207` numbers it.
  let lines = pyLines(text)
  for n in 0 ..< lines.len:
    let runes = runesOf(lines[n])
    for i in 0 ..< runes.len:
      if rendersAsEmoji(runes, i):
        result.add label & ":" & $(n + 1)
        break

proc hasForeignBreak(text: string): bool =
  ## Whether the text holds a line boundary `pyLines` and Python disagree
  ## about. A file that did would make the cap below a count of something
  ## other than lines, so the pins refuse instead of counting.
  for rune in text.runes:
    if int32(rune) in ForeignBreaks:
      return true
  false

proc hasStatusStamp(text: string): bool =
  ## Whether the text carries `**Last updated:** <date>`, the second half of
  ## `test_status_is_short_and_dated` (`:118-123`). The date is
  ## `\d{4}-\d{2}-\d{2}`, and Python searches the WHOLE text rather than a
  ## line, so the scan does too.
  var start = 0
  while true:
    let hit = text.find(StatusStamp, start)
    if hit < 0:
      return false
    let first = hit + StatusStamp.len
    const DateLen = 10
    if first + DateLen <= text.len:
      let date = text[first ..< first + DateLen]
      var shaped = true
      for i, c in date:
        let isDigit = c in {'0' .. '9'}
        let isDash = c == '-' and i in {4, 7}
        if not (isDigit or isDash):
          shaped = false
          break
      if shaped:
        return true
    start = hit + 1

proc claudeImportsOnlyAgents(text: string): bool =
  ## `CLAUDE.md` is the one-line import and nothing else (`:82-86`).
  text.strip() == "@AGENTS.md"

# --- the pins --------------------------------------------------------------

suite "T3 the docs index":
  test "every doc under docs/ is linked from docs/README.md":
    # `test_every_doc_is_indexed`, test_rulebook.py:98-105. A doc nobody
    # links to is a doc nobody reads.
    let root = repoRoot()
    let docsDir = at(root, "docs")
    let index = docsDir / DocsIndex
    var docs: seq[string] = @[]
    for path in markdownFilesIn(docsDir) & markdownFilesIn(docsDir / "context"):
      if path != index:
        docs.add relativePath(path, docsDir, '/')
    # `Path.resolve()` follows a symlink; a name comparison does not, so a
    # symlinked doc could be indexed under its target's name and still read
    # as missing here. No doc is a symlink today, and the pin says so rather
    # than trusting it.
    for doc in docs:
      assert not symlinkExists(docsDir / doc),
        "docs/" & doc & " is a symlink; this pin compares real paths"
    let missing = missingFromIndex(readFile(index), docsDir, docs)
    assert missing.len == 0,
      "add these to docs/README.md: " & $missing

  test "the index reader tells an indexed doc from a forgotten one":
    # The pin above passes on a tree where every doc is listed; that says
    # nothing about what it would do with one that is not. Driven on a
    # constructed index, against the real docs/ directory so the resolution
    # is the pin's own.
    let docsDir = at(repoRoot(), "docs")
    let index = "- [a](indexed.md) and [b](context/listed.md) and " &
      "[elsewhere](https://example.com/forgotten.md)\n"
    let docs = ["indexed.md", "context/listed.md", "forgotten.md"]
    assert missingFromIndex(index, docsDir, docs) == @["forgotten.md"],
      "expected the unlisted doc, got: " & $missingFromIndex(index, docsDir, docs)
    assert missingFromIndex("[a](forgotten.md#a-fragment)", docsDir,
      ["forgotten.md"]).len == 0, "a fragment on a listed doc is still listed"

suite "T3 the links the rulebook routes through":
  test "every local link in the rulebook resolves":
    # `test_rulebook_links_resolve`, test_rulebook.py:88-95, over the set at
    # :23-64. A rulebook is a router; a broken route is a dead end for every
    # reader who follows it.
    let root = repoRoot()
    var broken: seq[string] = @[]
    for doc in rulebook(root):
      for target in brokenLinks(doc.parentDir, readFile(doc)):
        broken.add relativeToRoot(root, doc) & " -> " & target
    assert broken.len == 0,
      "broken links:\n  " & broken.join("\n  ")

  test "the rulebook reader read the set it says it read":
    # A scan that finds nothing must not be able to look like a clean tree:
    # a wrong root or an empty glob would pass the pin above with nothing
    # checked. Both halves are counted — the fixed list and the two the
    # tree supplies (`docs/context/*.md` and the lab topics).
    let root = repoRoot()
    let docs = rulebook(root)
    assert docs.len >= 20, "the rulebook is only " & $docs.len & " files"
    var fromTree = 0
    for doc in docs:
      assert fileExists(doc), "the rulebook names a file that is not there: " & doc
    for doc in markdownFilesIn(at(root, "docs/context")):
      fromTree.inc
    for topic in labTopics(root):
      assert fileExists(topic / "README.md"),
        "the topic " & topic.lastPathPart & " has no README.md"
      fromTree.inc
    assert fromTree >= 10,
      "the rulebook took only " & $fromTree & " files from the tree"

  test "the link reader takes a local target and drops a site or an anchor":
    # The negative the pin above cannot show: a reader that took every
    # bracket for a link, or that took a URL for a path, would either fail
    # on a clean tree or pass on a tree with real broken links. Driven on
    # text and on the real docs/ directory, both owned by the pin.
    let docsDir = at(repoRoot(), "docs")
    let text = "[site](https://example.com/a.md) [mail](mailto:a@b.example) " &
      "[anchor](#a-section) [real](README.md) [gone](no-such-doc.md) " &
      "[fragment](README.md#a-heading)"
    assert localLinks(text) == @["README.md", "no-such-doc.md",
      "README.md#a-heading"],
      "the local links read were: " & $localLinks(text)
    assert brokenLinks(docsDir, text) == @["no-such-doc.md"],
      "the broken links read were: " & $brokenLinks(docsDir, text)
    # A directory is a target that exists, as it is for Python's `exists()`.
    assert brokenLinks(docsDir, "[w](whiteboards/)").len == 0,
      "a link to a directory was reported broken"

suite "T3 the caps":
  test "AGENTS.md fits its 100-line cap":
    # `test_agents_md_fits_its_cap`, test_rulebook.py:66-70, cap at :22.
    let text = readFile(at(repoRoot(), "AGENTS.md"))
    assert not hasForeignBreak(text),
      "AGENTS.md holds a line boundary this pin and Python would count differently"
    let lines = pyLines(text).len
    assert lines >= 90, "AGENTS.md is only " & $lines & " lines; was it truncated?"
    assert lines <= AgentsCap,
      "AGENTS.md is " & $lines & " lines; push detail down into docs/context/ " &
      "instead of growing it"

  test "README.md stays a landing page":
    # `test_readme_stays_a_landing_page`, test_rulebook.py:73-79.
    let text = readFile(at(repoRoot(), "README.md"))
    assert not hasForeignBreak(text),
      "README.md holds a line boundary this pin and Python would count differently"
    let lines = pyLines(text).len
    assert lines <= ReadmeCap,
      "README.md is " & $lines & " lines (cap " & $ReadmeCap &
      "); move the detail into docs/ and link it from the Docs table"

  test "status.md is short and dated":
    # `test_status_is_short_and_dated`, test_rulebook.py:118-122: the file is
    # rewritten whole, and a reader has to know how current it is.
    let text = readFile(at(repoRoot(), "docs/status.md"))
    assert not hasForeignBreak(text),
      "docs/status.md holds a line boundary this pin and Python would count differently"
    let lines = pyLines(text).len
    assert lines <= StatusCap,
      "docs/status.md is " & $lines & " lines; it is rewritten whole, not " &
      "appended to"
    assert hasStatusStamp(text),
      "docs/status.md has no \"" & StatusStamp & "YYYY-MM-DD\" line"

  test "the cap reader counts lines the way the caps were measured":
    # The probe each cap above needs: a count that was off by the trailing
    # newline would pass a 101-line file as 100 and fail a 100-line file as
    # 101, and neither would be the fact the Python pin measures. Both
    # directions are pinned on text, not by editing the tree.
    assert pyLines("").len == 0, "empty text is no lines"
    assert pyLines("one line").len == 1
    assert pyLines("one line\n").len == 1, "a trailing newline does not add a line"
    assert pyLines("one\n\n").len == 2, "a blank last line does count"
    assert pyLines("a\r\nb").len == 2, "CRLF is one boundary"
    assert pyLines("a\rb").len == 2, "a bare CR is a boundary too"
    let over = "a line of prose\n".repeat(AgentsCap + 1)
    assert pyLines(over).len == AgentsCap + 1,
      "the breaker string is not " & $(AgentsCap + 1) & " lines"
    assert pyLines(over).len > AgentsCap,
      "the cap accepts text over it: this is the failing direction"
    assert "a line of prose\n".repeat(AgentsCap).len > 0 and
      pyLines("a line of prose\n".repeat(AgentsCap)).len == AgentsCap,
      "the cap rejects text at it"
    assert hasForeignBreak("a\vb"), "a vertical tab is a boundary Python counts"
    assert hasForeignBreak("a\u2028b"), "U+2028 is a boundary Python counts"
    assert not hasForeignBreak("a\nb"), "a plain newline is agreed on"
    # And the stamp reader, on the two ways it can be wrong: a date that is
    # not a date, and the label without its bold markers.
    assert hasStatusStamp("intro\n\n" & StatusStamp & "2026-10-19\n")
    assert not hasStatusStamp(StatusStamp & "soon")
    assert not hasStatusStamp(StatusStamp & "2026-1-19")
    assert not hasStatusStamp("Last updated: 2026-10-19")

suite "T3 no emoji in the rulebook":
  test "no emoji in the rulebook or the README it starts from":
    # `test_no_emoji_in_rulebook_or_readme`, test_rulebook.py:200-207.
    let root = repoRoot()
    var hits: seq[string] = @[]
    for doc in rulebook(root):
      hits.add emojiHits(relativeToRoot(root, doc), readFile(doc))
    assert hits.len == 0, "no emojis in docs prose: " & $hits

  test "the emoji probe matches the character set it claims":
    # Three alternatives, three probes, plus the two characters that look
    # like emoji and are not: a bare dingbat renders as typography until
    # U+FE0F forces it, which is the whole reason `EMOJI` has a second
    # alternative instead of one wide range. Built from code points because
    # rule 6 forbids writing the characters themselves here.
    let face = $Rune(0x1F600)  # an emoji block character: matched alone
    let sun = $Rune(0x2600)    # a dingbat: matched only with the selector
    let cup = $Rune(0x2615)    # listed by name: matched alone
    let arrow = $Rune(0x2192)  # a typographic arrow: never matched
    let star = $Rune(0x2605)   # a plain star: never matched
    assert emojiHits("probe.md", "plain prose with an arrow " & arrow &
      " and a star " & star).len == 0, "a typographic mark read as emoji"
    assert emojiHits("probe.md", "a face " & face) == @["probe.md:1"],
      "an emoji block character was not read as emoji"
    assert emojiHits("probe.md", "a sun " & sun).len == 0,
      "a bare dingbat was read as emoji"
    assert emojiHits("probe.md", "a sun " & sun & $Rune(EmojiSelector)) ==
      @["probe.md:1"], "a dingbat forced to emoji was not read as emoji"
    assert emojiHits("probe.md", "a cup " & cup) == @["probe.md:1"],
      "a symbol listed by name was not read as emoji"
    assert emojiHits("probe.md", "line one\nline two " & cup) ==
      @["probe.md:2"], "the hit is reported on the wrong line"

suite "T3 CLAUDE.md is one import":
  test "CLAUDE.md only imports AGENTS.md":
    # `test_claude_md_only_imports_agents_md`, test_rulebook.py:82-85. One
    # rulebook for every agent: Claude Code reads `CLAUDE.md`, the rest read
    # `AGENTS.md`, and the import is what keeps the two from drifting apart.
    assert claudeImportsOnlyAgents(readFile(at(repoRoot(), "CLAUDE.md"))),
      "CLAUDE.md is not exactly \"@AGENTS.md\""

  test "the import check refuses a second line and a trailing sentence":
    # The probe: a file that repeats the import, or that grows a sentence
    # beside it, is two rulebooks again — and a checker that only looked at
    # the first line would pass it.
    assert claudeImportsOnlyAgents("@AGENTS.md\n")
    assert claudeImportsOnlyAgents("\n@AGENTS.md\n\n")
    assert not claudeImportsOnlyAgents("@AGENTS.md\n@AGENTS.md\n"),
      "a repeated import passed"
    assert not claudeImportsOnlyAgents("@AGENTS.md\n\nthe rest is in docs/\n"),
      "a second line passed"
    assert not claudeImportsOnlyAgents("@AGENTS.md @CLAUDE.md\n"),
      "a second import on the same line passed"

suite "T3 the pins read this repo":
  test "the pins read this repo, not whatever the working directory holds":
    # The anchor every pin above leans on. If this fails, the paths resolved
    # somewhere else and the pins above passed for the wrong reason, so it is
    # pinned rather than trusted.
    let root = repoRoot()
    for rel in ["AGENTS.md", "README.md", "CLAUDE.md", "CONTRIBUTING.md",
        "docs", "docs/README.md", "docs/context", "docs/status.md",
        "hosted/README.md"]:
      # `examples/` and `lab/` are not in this list: the rulebook pin above
      # already asserts every file it reads exists, and the trees this suite
      # may not name are named in exactly one place, for the reason given
      # there.
      let path = at(root, rel)
      assert fileExists(path) or dirExists(path),
        "the repo root this suite anchored to has no " & rel

# --- T7: one version literal per half, pinned in the CI table --------------

proc ciTableRows(markdown: string): seq[seq[string]] =
  ## The rows of the table under `## What CI blocks`, cells split the same
  ## way `test_repo_gates.nim` reads it — backticks dropped, since markdown's
  ## inline code is not what the cell says. A copy of that reader rather than
  ## a reach into another suite: the two pins guard different facts and must
  ## not share a helper that one edit could quietly move.
  var inTable = false
  for line in markdown.splitLines():
    if line.startsWith("## What CI blocks"):
      inTable = true
      continue
    if not inTable:
      continue
    if line.startsWith("|"):
      let parts = line.split('|')
      var cells: seq[string] = @[]
      for i, cell in parts:
        if i > 0 and i < parts.len - 1:
          cells.add cell.strip().replace("`", "")
      result.add cells
    elif result.len > 0 and line.len > 0 and not line.startsWith("#"):
      break

suite "T7 one version literal per half":
  test "the CI table states the version rule per half and names both guards":
    # The row `AGENTS.md` used to carry — `| a second version number |
    # evals/deterministic/test_version.py |` — demanded ONE number across the
    # repo. That is false now, and false on purpose. The Python half is frozen
    # (spec S1) and its release workflows rewrite `waku/__init__.py` on their
    # own schedule (`release-due.yml` does `sed -i` on that line), so the two
    # halves are not required to agree and are not required to differ either.
    # What holds is one editable version literal PER HALF, each guarded by its
    # own suite. This pin holds the table to that; it fails if a reword drops
    # either guard or the per-half rule.
    let rows = ciTableRows(readFile(at(repoRoot(), "AGENTS.md")))
    assert rows.len >= 5, "the CI table in AGENTS.md was not found"
    var named: seq[seq[string]] = @[]
    for row in rows:
      if row.len >= 2 and "test_version.py" in row[1] and
          "test_version.nim" in row[1]:
        named.add row
    assert named.len == 1,
      "the CI table must name both version guards in one row; it names " &
      $named.len & " such rows"
    assert "half" in named[0][0],
      "the version row must state the per-half rule, not one number: " &
      named[0][0]
