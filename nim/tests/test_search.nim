## `search_web` tests: Tavily + DuckDuckGo paths with a stubbed fetch.
## Offline only: no sockets, the live adapter is never called.

import std/strutils
import std/unittest

import ../src/search

const duckPage = """
<html><body>
<div><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">First <b>Hit</b></a>
<a class="result__snippet" href="s">snip one</a></div>
<div><a class="result__a" href="https://example.com/b">Second Hit</a>
<a class="result__snippet" href="s">snip <i>two</i></a></div>
</body></html>
"""

const tavilyDoc = """{"results": [
  {"title": "T1", "content": "long body here", "url": "https://t.example/1"},
  {"title": "T2", "content": "", "url": "https://t.example/2"}]}"""

proc stubFetch(tavily, duck: string): SearchFetchFn =
  result = proc(url, meth, body, agent: string): tuple[ok: bool,
      text: string] {.closure.} =
    if meth == "POST":
      assert url == tavilyUrl
      assert "api_key" in body
      return (true, tavily)
    assert url.startsWith(duckUrl)
    assert agent == duckAgent
    return (true, duck)

suite "search_web":
  test "tavily hits render numbered with engine line":
    let text = searchWeb(stubFetch(tavilyDoc, ""), "key", "nim lang", 5)
    assert "via Tavily" in text
    assert "1. T1" in text
    assert "long body here" in text
    assert "https://t.example/1" in text

  test "duckduckgo unwraps redirects and strips tags":
    let text = searchWeb(stubFetch("", duckPage), "", "nim lang", 5)
    assert "via DuckDuckGo" in text
    assert "1. First Hit" in text
    assert "https://example.com/a" in text
    assert "snip two" in text
    assert "<b>" notin text
    assert "<i>" notin text

  test "empty results name the free tavily key":
    let text = searchWeb(stubFetch("", "<html></html>"), "", "zzz", 5)
    assert "TAVILY_API_KEY" in text
    assert "tavily.com" in text

  test "tavily with no hits asks for a better query":
    let text = searchWeb(stubFetch("""{"results": []}""", ""), "key",
      "zzz", 5)
    assert text == "No results found. Try a more specific query."

  test "a dead transport answers from knowledge":
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] = (false, "")
    assert "Answer from what you know" in searchWeb(fetch, "key", "q", 5)

  test "duckduckgo link without redirect passes through":
    assert duckLinkTarget("https://example.com/b") ==
      "https://example.com/b"

  test "stripTags unescapes entities":
    assert stripTags("<b>a &amp; b</b>") == "a & b"

suite "fetch_url":
  test "a page renders as text without tags":
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] =
        assert meth == "GET"
        assert url == "https://example.com/a"
        (true, "<html><body><h1>Hi</h1><p>body text</p></body></html>")
    let text = fetchUrl(fetch, "https://example.com/a")
    assert "Hi" in text
    assert "body text" in text
    assert "<h1>" notin text

  test "a long page truncates with a marker":
    let big = "<p>" & repeat("x", 9000) & "</p>"
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] = (true, big)
    let text = fetchUrl(fetch, "https://example.com/big")
    assert "truncated" in text.toLowerAscii()
    assert text.len < big.len

  test "a non-http scheme is refused without fetching":
    var called = false
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] =
        called = true
        (true, "")
    let text = fetchUrl(fetch, "file:///etc/passwd")
    assert not called
    assert "file://" in text or "refuse" in text.toLowerAscii()

  test "a dead transport says so with the url":
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] = (false, "dns boom")
    let text = fetchUrl(fetch, "https://example.com/down")
    assert "https://example.com/down" in text
    assert "dns boom" in text

  test "a refused fetch names the status":
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] = (false, "404 Not Found")
    let text = fetchUrl(fetch, "https://example.com/gone")
    assert "https://example.com/gone" in text
    assert "404" in text

  test "truncation backs up to a UTF-8 boundary":
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] = (true, "<p>a" & repeat("é", 4000) & "</p>")
    let text = fetchUrl(fetch, "https://example.com/accents")
    # Byte 6000 would split an é; the cut must stop before it.
    assert text == "a" & repeat("é", 2999) & "\n…[truncated]"

  test "a byte cap inside a tag keeps the readable text":
    let page = repeat("A", 999995) & "<script>" & repeat("B", 20)
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] = (true, page)
    let text = fetchUrl(fetch, "https://example.com/huge")
    assert "no readable text" notin text
    assert "AAA" in text
    assert "truncated" in text.toLowerAscii()
