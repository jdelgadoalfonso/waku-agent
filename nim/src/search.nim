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
import std/uri

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
  except CatchableError:
    return (false, "")
