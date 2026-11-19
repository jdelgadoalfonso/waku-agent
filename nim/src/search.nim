## Web search — Tavily when keyed, DuckDuckGo otherwise.
##
## Port of `waku/tools/search.py`. The fetch is injected
## (`SearchFetchFn`: GET when `body` is empty, POST otherwise), so tests
## replay recorded pages and the binary passes the live adapter over
## `http.nim`'s one TLS helper. Messages are verbatim Python, including
## the no-results DDG hint that names the free Tavily key.

import std/httpclient
import std/json
import std/os
import std/strutils
import std/times
import std/uri
import std/nativesockets

import ./browse_session
import ./http
import ./tools
import ./wire

const
  tavilyUrl* = "https://api.tavily.com/search"
  duckUrl* = "https://html.duckduckgo.com/html/?q="
  duckAgent* = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " &
    "AppleWebKit/537.36"
    ## The browser fingerprint the DDG endpoint tolerates.

type
  SearchFetchFn* = proc(url, meth, body, agent: string): tuple[ok: bool,
      text: string] {.closure.}
    ## One HTTP round trip: `meth` is `"GET"` (empty body) or `"POST"`.
    ## `(false, _)` is a transport failure, like Python's `urlopen`
    ## raising.

proc tavilyResults*(doc: JsonNode, maxResults: int): seq[(string, string,
    string)] =
  ## `(title, snippet≤400, url)` per hit, like `_tavily`.
  if doc.kind != JObject:
    return @[]
  let hits = doc.jget("results")
  if hits.kind != JArray:
    return @[]
  var n = 0
  for r in hits:
    if n >= maxResults:
      break
    let content = r.jget("content").getStr()
    result.add((r.jget("title").getStr(),
      content[0 ..< min(400, content.len)], r.jget("url").getStr()))
    inc n

proc stripTags*(html: string): string =
  ## `html.unescape(re.sub("<[^>]+>", ""))`, by hand:Dropbox tags, keep text.
  var text = newStringOfCap(html.len)
  var inTag = false
  for c in html:
    if c == '<':
      inTag = true
    elif c == '>':
      inTag = false
    elif not inTag:
      text.add(c)
  result = text.strip()
  result = result.replace("&amp;", "&").replace("&lt;", "<")
    .replace("&gt;", ">").replace("&quot;", "\"")
    .replace("&#x27;", "'").replace("&#39;", "'")

proc duckLinkTarget*(href: string): string =
  ## DDG wraps results in a redirect: unwrap `uddg=`, like Python.
  let i = href.find("uddg=")
  if i < 0:
    return href
  var target = href[i + 5 .. ^1]
  let amp = target.find('&')
  if amp >= 0:
    target = target[0 ..< amp]
  return decodeUrl(target)

proc duckResults*(page: string,
    maxResults: int): seq[(string, string, string)] =
  ## `(title, snippet, url)` out of a DDG html page, like `_duckduckgo`.
  var links: seq[(string, string)] = @[]
  var snips: seq[string] = @[]
  var i = 0
  while true:
    let a = page.find("result__a", i)
    if a < 0:
      break
    let hrefKey = page.find("href=\"", a)
    if hrefKey < 0:
      break
    let hrefStart = hrefKey + 6
    let hrefEnd = page.find('"', hrefStart)
    if hrefEnd < 0:
      break
    let closeTag = page.find('>', hrefEnd)
    if closeTag < 0:
      break
    let endA = page.find("</a>", closeTag)
    if endA < 0:
      break
    links.add((page[hrefStart ..< hrefEnd],
      page[closeTag + 1 ..< endA]))
    i = endA + 4
  i = 0
  while true:
    let s = page.find("result__snippet", i)
    if s < 0:
      break
    let closeTag = page.find('>', s)
    if closeTag < 0:
      break
    let endA = page.find("</a>", closeTag)
    if endA < 0:
      break
    snips.add(page[closeTag + 1 ..< endA])
    i = endA + 4
  for idx in 0 ..< min(links.len, maxResults):
    let (href, title) = links[idx]
    let snip = if idx < snips.len: stripTags(snips[idx]) else: ""
    result.add((stripTags(title), snip, duckLinkTarget(href)))

proc renderResults*(query, engine: string,
    hits: seq[(string, string, string)]): string =
  ## The numbered `title/snippet/url` block, like `search_web` renders it.
  var lines = @["Web results for '" & query & "' (via " & engine & "):"]
  for i, (title, snippet, link) in hits:
    lines.add($(i + 1) & ". " & title & "\n   " & snippet & "\n   " & link)
  return lines.join("\n")

proc searchWeb*(fetch: SearchFetchFn, apiKey, query: string,
    maxResults = 5): string =
  ## Port of `search_web`: Tavily when keyed, DuckDuckGo otherwise,
  ## always text back — a failure answers from knowledge or asks for
  ## the key instead of raising.
  if query.strip().len == 0:
    return "No results found. Try a more specific query."
  if apiKey.len > 0:
    let body = $(%*{"api_key": apiKey, "query": query,
                    "max_results": maxResults, "include_answer": false})
    var text = ""
    try:
      let (ok, res) = fetch(tavilyUrl, "POST", body, "")
      if not ok:
        return "Web search failed (transport). Answer from what you " &
          "know, or ask the user."
      text = res
    except CatchableError as exc:
      return "Web search failed (" & exc.msg & "). Answer from what " &
        "you know, or ask the user."
    var hits: seq[(string, string, string)] = @[]
    try:
      hits = tavilyResults(parseJson(text), maxResults)
    except JsonParsingError:
      return "Web search failed (bad response). Answer from what you " &
        "know, or ask the user."
    if hits.len == 0:
      return "No results found. Try a more specific query."
    return renderResults(query, "Tavily", hits)
  var page = ""
  try:
    let (ok, res) = fetch(duckUrl & encodeUrl(query), "GET", "", duckAgent)
    if not ok:
      page = ""
    else:
      page = res
  except CatchableError:
    page = ""
  let hits = if page.len > 0: duckResults(page, maxResults)
             else: @[]
  if hits.len == 0:
    return "No results — DuckDuckGo's free endpoint often blocks automated " &
      "requests. For reliable search set a free TAVILY_API_KEY in .env " &
      "(https://tavily.com); see .env.example. Meanwhile, tell the user " &
      "you couldn't search and ask them to add the key."
  return renderResults(query, "DuckDuckGo", hits)

proc searchApiKey*(): string =
  ## `TAVILY_API_KEY`, else `WAKU_SEARCH_API_KEY` — read per call, like
  ## Python, so a key added mid-process works without rebuilding.
  let tavily = getEnv("TAVILY_API_KEY")
  if tavily.len > 0:
    return tavily
  return getEnv("WAKU_SEARCH_API_KEY")

proc makeSearchTool*(fetch: SearchFetchFn): Tool =
  ## Registry wiring for `search_web`.
  Tool(name: "search_web",
    description: "Search the public web and get back the top results " &
      "(title, snippet, URL). Use when the user asks about current events, " &
      "facts, schedules, or anything you don't already know — then act on " &
      "what you find (e.g. create calendar events).",
    inputSchema: %*{"type": "object",
      "properties": {
        "query": {"type": "string", "description": "the search query"},
        "max_results": {"type": "integer",
                        "description": "how many results (default 5)"}},
      "required": ["query"]},
    fn: proc(args: JsonNode): string =
      searchWeb(fetch, searchApiKey(), strArg(args, "query"),
        intArg(args, "max_results", 5)))

const
  fetchTextMax* = 6000
    ## Roughly this many characters of converted text a `fetch_url`
    ## answer carries: the cut backs up to a UTF-8 codepoint boundary.
  fetchBytesMax* = 1000000
    ## Raw body bytes read before converting; a bigger page is cut first
    ## (also on a codepoint boundary) so one huge download cannot swell
    ## the turn.

proc navUrlHost*(url: string): string =
  ## Lowercased host of an http(s) URL, or "" when it cannot be read.
  ## Strips userinfo, port, brackets and one trailing dot. No DNS.
  var t = url.strip()
  let scheme = t.find("://")
  if scheme < 0:
    return ""
  t = t[scheme + 3 .. ^1]
  for stop in ['/', '?', '#']:
    let i = t.find(stop)
    if i >= 0:
      t = t[0 ..< i]
  let at = t.rfind('@')
  if at >= 0:
    t = t[at + 1 .. ^1]
  if t.startsWith("["):
    let close = t.find(']')
    if close < 0:
      return ""
    result = t[1 ..< close].strip().toLowerAscii()
  else:
    let colon = t.find(':')
    if colon >= 0:
      result = t[0 ..< colon].strip().toLowerAscii()
    else:
      result = t.strip().toLowerAscii()
  while result.endsWith(".") and result.len > 1:
    result = result[0 ..< ^1]

proc parseIpv6Groups*(h: string): tuple[ok: bool,
    groups: array[8, int]] =
  ## Parse a bare IPv6 literal (no brackets, no port, no zone id) into
  ## eight hextets. Accepts one `::` compression; rejects dotted tails
  ## here (the caller judges those as IPv4). Fails closed on garbage.
  var groups: array[8, int] = [0, 0, 0, 0, 0, 0, 0, 0]
  let dbl = h.find("::")
  if dbl >= 0 and h.find("::", dbl + 2) >= 0:
    return (false, groups)
  proc parseHextet(s: string, v: var int): bool =
    if s.len == 0 or s.len > 4:
      return false
    var n = 0
    for c in s:
      n = n * 16
      case c
      of '0' .. '9': n += ord(c) - ord('0')
      of 'a' .. 'f': n += ord(c) - ord('a') + 10
      of 'A' .. 'F': n += ord(c) - ord('A') + 10
      else: return false
    v = n
    return true
  if dbl < 0:
    let parts = h.split(':')
    if parts.len != 8:
      return (false, groups)
    for i in 0 .. 7:
      if not parseHextet(parts[i], groups[i]):
        return (false, groups)
    return (true, groups)
  let left = if dbl > 0: h[0 ..< dbl].split(':') else: @[]
  let right = if dbl + 2 < h.len: h[dbl + 2 .. ^1].split(':')
              else: @[]
  if left.len + right.len > 7:
    return (false, groups)
  var idx = 0
  for p in left:
    if not parseHextet(p, groups[idx]):
      return (false, groups)
    inc idx
  idx = 8 - right.len
  for p in right:
    if not parseHextet(p, groups[idx]):
      return (false, groups)
    inc idx
  return (true, groups)

proc ipv6GroupsBlocked*(g: array[8, int]): bool =
  ## Fail-closed verdict on parsed hextets: only global unicast
  ## (2000::/3) passes, and IPv4-mapped (::ffff:0:0/96) is judged by
  ## its embedded IPv4 octets instead.
  var allZero = true
  for v in g:
    if v != 0:
      allZero = false
      break
  if allZero:
    return true
  if g[0] == 0 and g[1] == 0 and g[2] == 0 and g[3] == 0 and
     g[4] == 0 and g[5] == 0 and g[7] == 1:
    var leadingZero = true
    for i in 0 .. 5:
      if g[i] != 0:
        leadingZero = false
        break
    if leadingZero and g[6] == 0:
      return true
  if (g[0] and 0xFF00) == 0xFF00:
    return true
  if (g[0] and 0xFE00) == 0xFC00:
    return true
  if (g[0] and 0xFFC0) == 0xFE80:
    return true
  if g[0] == 0x2001 and g[1] == 0x0DB8:
    return true
  if g[0] == 0 and g[1] == 0 and g[2] == 0 and g[3] == 0 and
     g[4] == 0 and g[5] == 0xFFFF:
    let o = @[(g[6] shr 8) and 0xFF, g[6] and 0xFF,
              (g[7] shr 8) and 0xFF, g[7] and 0xFF]
    if o[0] == 0 or o[0] == 127:
      return true
    if o[0] == 10:
      return true
    if o[0] == 100 and o[1] >= 64 and o[1] <= 127:
      return true  # 100.64.0.0/10 CGNAT
    if o[0] == 172 and o[1] >= 16 and o[1] <= 31:
      return true
    if o[0] == 192 and o[1] == 168:
      return true
    if o[0] == 192 and o[1] == 0 and o[2] == 0:
      return true  # 192.0.0.0/24 IETF protocol assignments
    if o[0] == 198 and (o[1] == 18 or o[1] == 19):
      return true  # 198.18.0.0/15 benchmarking
    if o[0] == 169 and o[1] == 254:
      return true
    if o[0] >= 224:
      return true  # 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
    return false
  if (g[0] and 0xE000) == 0x2000:
    return false
  return true

proc navBlockedHost*(host: string): bool =
  ## Fail-closed literal check for `browse_navigate` (fase B only).
  ## `fetch_url` keeps its current policy; this guard is the new tool's.
  var h = host.strip().toLowerAscii()
  while h.endsWith(".") and h.len > 1:
    h = h[0 ..< ^1]
  if h.len == 0:
    return true
  if h == "localhost" or h.endsWith(".localhost"):
    return true
  if h.endsWith(".local") or h.endsWith(".internal"):
    return true
  if ':' in h:
    # IPv6 literal (brackets already stripped by navUrlHost).
    if '.' in h:
      # Only ::ffff:0:0/96 embeds IPv4 (dotted tail judged as IPv4);
      # any other dotted form (fe80::8.8.8.8, 2001:db8::8.8.8.8) fails
      # closed: it is either link-local, documentation, or garbage.
      if h.startsWith("::ffff:") or
         h.startsWith("0:0:0:0:0:ffff:"):
        let tail = h[h.rfind(':') + 1 .. ^1]
        if tail != h and '.' in tail:
          return navBlockedHost(tail)
      return true
    let (ok, groups) = parseIpv6Groups(h)
    if not ok:
      return true
    return ipv6GroupsBlocked(groups)
  let parts = h.split('.')
  if parts.len == 1:
    # No dot and no colon: single-label intranet name or integer IP.
    return true
  var allDigits = true
  for p in parts:
    if p.len == 0:
      allDigits = false
      break
    for c in p:
      if c notin {'0' .. '9'}:
        allDigits = false
        break
    if not allDigits:
      break
  if allDigits and parts.len == 4:
    # Standard dotted decimal: judge the ranges.
    var octs: array[4, int] = [0, 0, 0, 0]
    try:
      for i in 0 .. 3:
        octs[i] = parseInt(parts[i])
        if octs[i] < 0 or octs[i] > 255:
          return true
    except ValueError:
      return true
    if octs[0] == 0 or octs[0] == 127:
      return true
    if octs[0] == 10:
      return true
    if octs[0] == 100 and octs[1] >= 64 and octs[1] <= 127:
      return true  # 100.64.0.0/10 CGNAT, also resolved literally
    if octs[0] == 172 and octs[1] >= 16 and octs[1] <= 31:
      return true
    if octs[0] == 192 and octs[1] == 168:
      return true
    if octs[0] == 192 and octs[1] == 0 and octs[2] == 0:
      return true  # 192.0.0.0/24 IETF protocol assignments
    if octs[0] == 198 and (octs[1] == 18 or octs[1] == 19):
      return true  # 198.18.0.0/15 benchmarking
    if octs[0] == 169 and octs[1] == 254:
      return true  # link-local + cloud metadata
    if octs[0] >= 224:
      return true  # 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
    return false
  # Non-standard numerics (0x, octal, bare integer) fail closed.
  if allDigits:
    return true
  for p in parts:
    if p.startsWith("0x") or p.startsWith("0X"):
      return true
    if p.len > 1 and p.startsWith("0"):
      var octal = true
      for c in p:
        if c notin {'0' .. '9'}:
          octal = false
          break
      if octal:
        return true
  return false

proc navBlockedUrl*(url: string): bool =
  ## True when `browse_navigate` must refuse this URL before dialing.
  ## Only called after the http(s) scheme check; non-http answers
  ## false here so the scheme refusal keeps its own message.
  let t = url.strip()
  if not (t.startsWith("http://") or t.startsWith("https://")):
    return false
  return navBlockedHost(navUrlHost(t))

proc fetchUrl*(fetch: SearchFetchFn, url: string): string =
  ## Port of nothing: `browse_web` fase A. GET one `http(s)` page and
  ## render it as text. Caps and honest refusals, never a silent empty.
  let target = url.strip()
  if not (target.startsWith("http://") or target.startsWith("https://")):
    return "refused: fetch_url only reads http:// and https:// URLs, " &
      "got: " & (if target.len > 0: target else: "(empty)")
  var page: string
  try:
    let (ok, res) = fetch(target, "GET", "", duckAgent)
    if not ok:
      let why = if res.strip().len > 0: res.strip() else: "transport failure"
      return "could not fetch " & target & " (" & why & ")"
    page = res
  except CatchableError as e:
    return "could not fetch " & target & " (" & e.msg & ")"
  if page.len > fetchBytesMax:
    var cut = fetchBytesMax
    # Back up to a UTF-8 codepoint boundary: continuation bytes match
    # 0b10xxxxxx, and strings are byte-indexed.
    while cut > 0 and (ord(page[cut]) and 0xC0) == 0x80:
      dec cut
    page = page[0 ..< cut]
    # A cut inside an open tag would make stripTags drop everything
    # after it; fall back to the last unclosed '<' so text survives.
    if page.find('>') < page.rfind('<'):
      page = page[0 ..< page.rfind('<')]
  var text = stripTags(page).strip()
  if text.len == 0:
    return "fetched " & target & " but it held no readable text."
  if text.len > fetchTextMax:
    var cut = fetchTextMax
    while cut > 0 and (ord(text[cut]) and 0xC0) == 0x80:
      dec cut
    text = text[0 ..< cut] & "\n…[truncated]"
  return text

proc navBaseRoot*(base: string): string =
  ## `scheme://authority` of an http(s) URL, or "" when unreadable.
  let t = base.strip()
  let scheme = t.find("://")
  if scheme < 0:
    return ""
  var rest = t[scheme + 3 .. ^1]
  for stop in ['/', '?', '#']:
    let i = rest.find(stop)
    if i >= 0:
      rest = rest[0 ..< i]
      break
  if rest.len == 0:
    return ""
  return t[0 .. scheme + 2] & rest

proc resolveNavUrl*(base, href: string): string =
  ## Resolve one anchor href against its page URL. "" means skip.
  var h = href.strip()
  if h.len == 0 or h.startsWith("#"):
    return ""
  let low = h.toLowerAscii()
  if low.startsWith("mailto:") or low.startsWith("javascript:") or
     low.startsWith("tel:") or low.startsWith("data:"):
    return ""
  if h.startsWith("http://") or h.startsWith("https://"):
    return h
  if h.startsWith("//"):
    return "https:" & h
  let root = navBaseRoot(base)
  if root.len == 0:
    return ""
  if h.startsWith("/"):
    return root & h
  # Relative path: join against the page directory, popping ../.
  var dir = base.strip()
  for stop in ['?', '#']:
    let i = dir.find(stop)
    if i >= 0:
      dir = dir[0 ..< i]
  let scheme = dir.find("://")
  var path = if scheme >= 0: dir[scheme + 3 .. ^1] else: dir
  let slash = path.find('/')
  var hostPart = if slash >= 0: path[0 ..< slash] else: path
  var pagePath = if slash >= 0: path[slash .. ^1] else: "/"
  let lastSlash = pagePath.rfind('/')
  var cur = if lastSlash > 0: pagePath[0 ..< lastSlash] else: ""
  while h.startsWith("../"):
    h = h[3 .. ^1]
    let i = cur.rfind('/')
    cur = if i >= 0: cur[0 ..< i] else: ""
  while h.startsWith("./"):
    h = h[2 .. ^1]
  discard hostPart
  let rootClean = root
  if cur.len == 0:
    return rootClean & "/" & h
  return rootClean & cur & "/" & h

proc extractNavLinks*(html, baseUrl: string, maxLinks = 20): seq[(string,
    string)] =
  ## `(title, absoluteUrl)` anchors of one page, in order, capped.
  ## Skip fragments, mailto/javascript/tel/data and unresolvable hrefs.
  var i = 0
  while result.len < maxLinks:
    let a = html.find("<a", i)
    if a < 0:
      break
    let hrefKey = html.find("href=\"", a)
    let squoteKey = html.find("href='", a)
    var keyPos = -1
    var quote = '"'
    if hrefKey >= 0 and (squoteKey < 0 or hrefKey < squoteKey):
      keyPos = hrefKey + 6
      quote = '"'
    elif squoteKey >= 0:
      keyPos = squoteKey + 6
      quote = '\''
    else:
      i = a + 2
      continue
    let hrefEnd = html.find(quote, keyPos)
    if hrefEnd < 0:
      break
    let closeTag = html.find('>', hrefEnd)
    if closeTag < 0:
      break
    let endA = html.find("</a", closeTag)
    if endA < 0:
      break
    let endBrace = html.find('>', endA)
    if endBrace < 0:
      break
    let rawHref = html[keyPos ..< hrefEnd]
    let title = stripTags(html[closeTag + 1 ..< endA]).strip()
    i = endBrace + 1
    let resolved = resolveNavUrl(baseUrl, rawHref)
    if resolved.len == 0:
      continue
    var dup = false
    for seen in result:
      if seen[1] == resolved:
        dup = true
        break
    if dup:
      continue
    let linkTitle = if title.len > 0: title else: resolved
    result.add((linkTitle, resolved))

proc renderBrowsePage*(target, pageIn: string, maxLinks = 20): string =
  ## Shared renderer: byte cap, links, text cap, numbered list.
  var page = pageIn
  if page.len > fetchBytesMax:
    var cut = fetchBytesMax
    while cut > 0 and (ord(page[cut]) and 0xC0) == 0x80:
      dec cut
    page = page[0 ..< cut]
    if page.find('>') < page.rfind('<'):
      page = page[0 ..< page.rfind('<')]
  let links = extractNavLinks(page, target, maxLinks)
  var text = stripTags(page).strip()
  if text.len == 0 and links.len == 0:
    return "fetched " & target & " but it held no readable text."
  if text.len == 0:
    text = "(no readable text)"
  if text.len > fetchTextMax:
    var cut = fetchTextMax
    while cut > 0 and (ord(text[cut]) and 0xC0) == 0x80:
      dec cut
    text = text[0 ..< cut] & "\n…[truncated]"
  if links.len == 0:
    return text
  var lines = @[text, "", "Links:"]
  for idx, (title, link) in links:
    lines.add($(idx + 1) & ". " & title)
    lines.add("   " & link)
  return lines.join("\n")

proc browseNavigate*(fetch: SearchFetchFn, url: string,
    maxLinks = 20): string =
  ## Fase B step: GET one http(s) page, render text plus numbered links.
  ## SSRF guard fails closed before any byte goes out; `fetch_url`
  ## keeps its own policy untouched.
  let target = url.strip()
  if not (target.startsWith("http://") or target.startsWith("https://")):
    return "refused: browse_navigate only reads http:// and https:// " &
      "URLs, got: " & (if target.len > 0: target else: "(empty)")
  if navBlockedUrl(target):
    return "refused: browse_navigate will not open private or local " &
      "hosts, got host: " & navUrlHost(target)
  var page: string
  try:
    let (ok, res) = fetch(target, "GET", "", duckAgent)
    if not ok:
      let why = if res.strip().len > 0: res.strip() else: "transport failure"
      return "could not fetch " & target & " (" & why & ")"
    page = res
  except CatchableError as e:
    return "could not fetch " & target & " (" & e.msg & ")"
  return renderBrowsePage(target, page, maxLinks)

type
  BrowseFetchFn* = proc(url, meth, body, agent, cookie: string): tuple[
      ok: bool, text: string, setCookies: seq[string], status: int,
      location: string] {.closure.}
    ## Single-hop session-aware round trip: `cookie` is the `Cookie:`
    ## value for the target host ("" when none). `status` is the HTTP
    ## code (0 on transport failure, where `text` carries the reason);
    ## `location` carries the `Location` header on 3xx else "".
    ## Redirects are followed by `browseInSession`, never here, so every
    ## hop keeps its own host cookies. Tests inject recordings.

proc adaptSearchFetch*(fetch: SearchFetchFn): BrowseFetchFn =
  ## Bridge for cookie-unaware seams: cookies are ignored on the way out
  ## and nothing new is learned on the way in. Redirects are already
  ## followed inside the wrapped fetch, so no `location` is reported;
  ## production always passes the live single-hop fetch instead.
  result = proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
      text: string, setCookies: seq[string], status: int,
      location: string] {.closure.} =
    let (ok, text) = fetch(url, meth, body, agent)
    if ok:
      (true, text, @[], 200, "")
    else:
      (false, text, @[], 0, "")

proc dnsResolvesToBlocked*(host: string): bool =
  ## Live-only DNS check: true when `host` resolves to any loopback,
  ## private, link-local or metadata literal. No resolution (NXDOMAIN
  ## etc.) answers false so the fetch reports the honest transport
  ## error; a successful resolution to a blocked IP refuses first.
  ## Never called in tests (needs real DNS).
  var list: ptr AddrInfo = nil
  try:
    list = getAddrInfo(host, Port(80), AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP)
  except OSError:
    return false
  if list == nil:
    return false
  try:
    var ai = list
    while ai != nil:
      if ai.ai_addr != nil:
        let ip = getAddrString(ai.ai_addr)
        if ip.len > 0 and navBlockedHost(ip):
          return true
      ai = ai.ai_next
    return false
  finally:
    freeAddrInfo(list)

proc browseNowUnix*(): int64 =
  toUnix(getTime())

proc browseInSession*(fetch: BrowseFetchFn, home, sessionId, url: string,
    meth = "GET", body = "", maxLinks = 20, nowUnix: int64 = 0): string =
  ## Fase B with a session: per-hop cookies, redirect walk (max 5) with
  ## a literal SSRF check on every hop, history + jar on disk, retention
  ## enforced after every successful visit. Fails closed on bad session
  ## ids, schemes and SSRF hosts before dialing.
  if not validBrowseSessionId(sessionId):
    return "refused: browse_navigate needs a session id of " &
      "[a-z0-9-]{1,64}, got: " &
      (if sessionId.len > 0: sessionId else: "(empty)")
  let first = url.strip()
  if not (first.startsWith("http://") or first.startsWith("https://")):
    return "refused: browse_navigate only reads http:// and https:// " &
      "URLs, got: " & (if first.len > 0: first else: "(empty)")
  let now = if nowUnix != 0: nowUnix else: browseNowUnix()
  let (found, loaded) = loadBrowseSession(home, sessionId)
  var sess = if found: loaded
             else: newBrowseSession(sessionId, now, first)
  var curUrl = first
  var curMeth = meth
  var curBody = body
  var hops = 0
  while true:
    if navBlockedUrl(curUrl):
      return "refused: browse_navigate will not open private or local " &
        "hosts, got host: " & navUrlHost(curUrl)
    let host = navUrlHost(curUrl)
    let cookie = cookieHeaderFor(sess, host)
    var res: tuple[ok: bool, text: string, setCookies: seq[string],
      status: int, location: string]
    try:
      res = fetch(curUrl, curMeth, curBody, duckAgent, cookie)
    except CatchableError as e:
      return "could not fetch " & first & " (" & e.msg & ")"
    if res.status == 0 and not res.ok:
      let why = if res.text.strip().len > 0: res.text.strip()
                else: "transport failure"
      return "could not fetch " & curUrl & " (" & why & ")"
    applySetCookies(sess, host, res.setCookies)
    if res.status >= 300 and res.status < 400:
      if hops >= 5 or res.location.strip().len == 0:
        if hops >= 5:
          return "could not fetch " & first & " (too many redirects)"
        return "could not fetch " & curUrl & " (" &
          (if res.text.strip().len > 0: res.text.strip()
           else: "redirect without location") & ")"
      let next = resolveNavUrl(curUrl, res.location)
      if next.len == 0:
        return "could not fetch " & curUrl & " (bad redirect target)"
      if res.status == 303 or
         (res.status in [301, 302] and curMeth == "POST"):
        curMeth = "GET"
        curBody = ""
      sess.history.add(curUrl)
      if sess.history.len > browseHistoryMax:
        sess.history = sess.history[^browseHistoryMax .. ^1]
      curUrl = next
      inc hops
      continue
    if res.status < 200 or res.status >= 300:
      let why = if res.text.strip().len > 0: res.text.strip()
                else: "HTTP " & $res.status
      return "could not fetch " & curUrl & " (" & why & ")"
    recordBrowseVisit(sess, curUrl, now)
    if not saveBrowseSession(home, sess):
      return renderBrowsePage(curUrl, res.text, maxLinks) &
        "\n\n(note: session was not saved)"
    discard pruneBrowseSessions(home, now, browseSessionMaxAgeSec,
      browseSessionMaxCount)
    return renderBrowsePage(curUrl, res.text, maxLinks)

proc makeFetchTool*(fetch: SearchFetchFn): Tool =
  ## Registry wiring for `fetch_url` (fase A de `browse_web`).
  Tool(name: "fetch_url",
    description: "Fetch one public http(s) page and get back its text " &
      "(read-only, capped). Use for a URL the user names or a search hit " &
      "— never for local files; file:// and other schemes are refused.",
    inputSchema: %*{"type": "object",
      "properties": {
        "url": {"type": "string", "description": "the http(s) page to read"}},
      "required": ["url"]},
    fn: proc(args: JsonNode): string =
      fetchUrl(fetch, strArg(args, "url")))

proc liveSearchFetch*(url, meth, body, agent: string): tuple[ok: bool,
    text: string] =
  ## The live round trip over `http.nim`'s one helper: `https://` gets
  ## the TLS context in a `-d:wakuTls` build and is refused before any
  ## byte goes out in the default one. Real socket — never in tests.
  var client = newTlsHttpClient(timeout = 20 * 1000)
  try:
    if meth == "POST":
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      return (true, client.postContent(url, body))
    if agent.len > 0:
      client.headers = newHttpHeaders([("User-Agent", agent)])
    return (true, client.getContent(url))
  except CatchableError as e:
    # The message carries the reason (a non-2xx status line included),
    # so callers can report it instead of a bare transport failure.
    # `searchWeb` ignores this text when `ok` is false; `fetchUrl`
    # surfaces it with the url.
    return (false, e.msg)

proc liveBrowseFetch*(url, meth, body, agent, cookie: string): tuple[
    ok: bool, text: string, setCookies: seq[string], status: int,
    location: string] =
  ## Live single-hop round trip: literal SSRF guard plus a DNS check
  ## (any resolved IP blocked refuses before dialing), one request,
  ## `Set-Cookie` and `Location` captured for the session layer, which
  ## owns the redirect walk and the per-host jar. Real socket — never
  ## in tests.
  let target = url.strip()
  if navBlockedUrl(target):
    return (false, "refused: browse_navigate will not open private " &
      "or local hosts, got host: " & navUrlHost(target), @[], 0, "")
  if dnsResolvesToBlocked(navUrlHost(target)):
    return (false, "refused: browse_navigate will not open private " &
      "or local hosts, got host: " & navUrlHost(target), @[], 0, "")
  var client = newTlsHttpClient(timeout = 20 * 1000, maxRedirects = 0)
  try:
    let curMeth = if meth == "POST": "POST" else: "GET"
    var headers = newHttpHeaders()
    if agent.len > 0:
      headers["User-Agent"] = agent
    if cookie.len > 0:
      headers["Cookie"] = cookie
    if curMeth == "POST" and not headers.hasKey("Content-Type"):
      headers["Content-Type"] = "application/x-www-form-urlencoded"
    let reqBody = if curMeth == "POST": body else: ""
    let resp = client.request(target,
      if curMeth == "POST": HttpPost else: HttpGet, reqBody, headers)
    var setCookies: seq[string] = @[]
    var location = ""
    for k, v in resp.headers.pairs:
      let lk = k.toLowerAscii()
      if lk == "set-cookie":
        setCookies.add(v)
      elif lk == "location" and location.len == 0:
        location = v
    let code = int(resp.code)
    if code >= 200 and code < 300:
      let text = resp.body
      client.close()
      return (true, text, setCookies, code, "")
    if code >= 300 and code < 400:
      client.close()
      return (true, "", setCookies, code, location)
    client.close()
    return (false, $resp.status, setCookies, code, "")
  except CatchableError as e:
    try:
      client.close()
    except CatchableError:
      discard
    return (false, e.msg, @[], 0, "")

proc makeBrowseNavigateTool*(fetch: BrowseFetchFn, home: string): Tool =
  ## Registry wiring for `browse_navigate` (fase B): session links +
  ## basic forms behind `WAKU_EXPERIMENTAL`, SSRF guard on every hop.
  Tool(name: "browse_navigate",
    description: "Navigate the public web with a session: read a page " &
      "with numbered links, follow one, or submit a basic form. " &
      "Private/local hosts are refused. Uses session_id in the agent " &
      "home's browse_sessions dir to keep cookies and history.",
    inputSchema: %*{"type": "object",
      "properties": {
        "url": {"type": "string",
          "description": "the http(s) page or form target to open"},
        "session_id": {"type": "string",
          "description": "browse session id [a-z0-9-] (default default)"},
        "method": {"type": "string",
          "description": "GET (default) or POST for a basic form"},
        "body": {"type": "string",
          "description": "form body for POST (url-encoded)"}},
      "required": ["url"]},
    fn: proc(args: JsonNode): string =
      let sid = strArg(args, "session_id", "default")
      var meth = strArg(args, "method", "GET").toUpperAscii().strip()
      if meth.len == 0:
        meth = "GET"
      if meth notin ["GET", "POST"]:
        return "refused: browse_navigate method must be GET or POST, " &
          "got: " & strArg(args, "method", "(empty)")
      browseInSession(fetch, home, sid, strArg(args, "url"), meth,
        strArg(args, "body"), 20, browseNowUnix()))
