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

suite "browse_navigate ssrf guard":
  test "loopback and private hosts are blocked":
    assert navBlockedUrl("http://localhost:7777/api/data")
    assert navBlockedUrl("http://127.0.0.1/")
    assert navBlockedUrl("http://10.0.0.5/")
    assert navBlockedUrl("http://192.168.1.1/")
    assert navBlockedUrl("http://169.254.169.254/latest/meta-data/")

  test "public hosts pass":
    assert not navBlockedUrl("https://example.com/a")
    assert not navBlockedUrl("https://93.184.216.34/a")

  test "obfuscated numerics fail closed":
    assert navBlockedUrl("http://2130706433/")
    assert navBlockedUrl("http://0x7f.0.0.1/")

  test "ipv6 alternates of loopback and mapped private are blocked":
    assert navBlockedUrl("http://[0:0:0:0:0:0:0:1]/")
    assert navBlockedUrl("http://[::ffff:7f00:1]/")
    assert navBlockedUrl("http://[::ffff:a9fe:a9fe]/")
    assert not navBlockedUrl("http://[2606:4700:4700::1111]/")

  test "non-public ipv4 ranges are blocked":
    assert navBlockedUrl("http://100.64.0.1/")
    assert navBlockedUrl("http://192.0.0.1/")
    assert navBlockedUrl("http://198.18.0.1/")
    assert navBlockedUrl("http://224.0.0.1/")
    assert navBlockedUrl("http://239.255.255.250/")
    assert navBlockedUrl("http://240.0.0.1/")
    assert navBlockedUrl("http://255.255.255.255/")
    assert not navBlockedUrl("http://8.8.8.8/")
    assert not navBlockedUrl("http://1.1.1.1/")

  test "dotted ipv6 outside ::ffff fails closed, mapped public passes":
    assert navBlockedUrl("http://[fe80::8.8.8.8]/")
    assert navBlockedUrl("http://[2001:db8::8.8.8.8]/")
    assert not navBlockedUrl("http://[::ffff:8.8.8.8]/")

  test "mapped new ranges follow the ipv4 verdicts":
    assert navBlockedUrl("http://[::ffff:100.64.0.1]/")
    assert navBlockedUrl("http://[::ffff:192.0.0.1]/")
    assert navBlockedUrl("http://[::ffff:198.18.0.1]/")
    assert navBlockedUrl("http://[::ffff:224.0.0.1]/")
    assert not navBlockedUrl("http://[::ffff:1.1.1.1]/")

suite "browse_navigate read":
  test "a page renders text plus numbered links":
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] =
        assert meth == "GET"
        (true, "<html><body><h1>Hi</h1><p>see <a href=\"/b\">Bee</a> " &
          "and <a href=\"https://other.example/c\">Cee</a></p></body></html>")
    let text = browseNavigate(fetch, "https://example.com/a")
    assert "Hi" in text
    assert "Links:" in text
    assert "Bee" in text
    assert "https://example.com/b" in text
    assert "https://other.example/c" in text

  test "a blocked host is refused without fetching":
    var called = false
    let fetch: SearchFetchFn =
      proc(url, meth, body, agent: string): tuple[ok: bool,
        text: string] =
        called = true
        (true, "")
    let text = browseNavigate(fetch, "http://127.0.0.1/")
    assert not called
    assert "refuse" in text.toLowerAscii() or "will not open" in text
