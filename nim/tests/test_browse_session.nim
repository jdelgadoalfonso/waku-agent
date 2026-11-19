## `browse_navigate` session store — offline pins, no sockets.
## Home is a tmp dir per test; retention uses injected nowUnix.

import std/os
import std/strutils
import std/tables
import std/tempfiles
import std/unittest

import ../src/browse_session
import ../src/search

proc tmpHome(): string =
  result = createTempDir("waku-browse-", "")
  createDir(result)

suite "browse sessions":
  test "save and load round-trips history and cookies":
    let home = tmpHome()
    var s = newBrowseSession("abc-123", 1000, "https://example.com/a")
    s.history.add("https://example.com/a")
    s.cookies["example.com|sid"] = "abc"
    assert saveBrowseSession(home, s)
    let (ok, back) = loadBrowseSession(home, "abc-123")
    assert ok
    assert back.lastUrl == "https://example.com/a"
    assert back.history == @["https://example.com/a"]
    assert back.cookies.getOrDefault("example.com|sid") == "abc"

  test "invalid ids are refused without touching disk":
    let home = tmpHome()
    var s = newBrowseSession("../x", 1000, "https://example.com/")
    assert not saveBrowseSession(home, s)
    let (ok, _) = loadBrowseSession(home, "../x")
    assert not ok

  test "cookies stay per host and join deterministically":
    var s = newBrowseSession("s1", 1000, "https://a.example/")
    applySetCookies(s, "a.example", @["sid=abc; Path=/; HttpOnly"])
    applySetCookies(s, "b.example", @["sid=other; Path=/"])
    assert cookieHeaderFor(s, "a.example") == "sid=abc"
    assert cookieHeaderFor(s, "b.example") == "sid=other"
    assert cookieHeaderFor(s, "c.example") == ""
    assert parseSetCookiePair("sid=abc; Path=/") == ("sid", "abc")
    assert parseSetCookiePair("bad") == ("", "")

  test "prune drops old sessions and caps count":
    let home = tmpHome()
    discard saveBrowseSession(home, newBrowseSession("old-1", 1000, "https://example.com/"))
    discard saveBrowseSession(home, newBrowseSession("new-1", 600000, "https://example.com/"))
    let removed = pruneBrowseSessions(home, 700000, browseSessionMaxAgeSec, 10)
    assert removed >= 1
    let (okOld, _) = loadBrowseSession(home, "old-1")
    assert not okOld
    let (okNew, _) = loadBrowseSession(home, "new-1")
    assert okNew

suite "browse_navigate session POST":
  test "post sends body and stores set-cookie on disk":
    let home = tmpHome()
    var seenBody = ""
    var seenCookie = "unset"
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        seenBody = body
        seenCookie = cookie
        assert meth == "POST"
        assert url == "https://example.com/form"
        (true, "<p>ok</p>", @["sid=abc; Path=/"], 200, "")
    let text = browseInSession(fetch, home, "s1",
      "https://example.com/form", "POST", "a=1", 20, 1000)
    assert "ok" in text
    assert seenBody == "a=1"
    assert seenCookie == ""
    let (ok, back) = loadBrowseSession(home, "s1")
    assert ok
    assert back.lastUrl == "https://example.com/form"
    assert cookieHeaderFor(back, "example.com") == "sid=abc"

  test "second call sends the stored cookie":
    let home = tmpHome()
    let first: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        (true, "<p>one</p>", @["sid=abc; Path=/"], 200, "")
    discard browseInSession(first, home, "s1", "https://example.com/a",
      "GET", "", 20, 1000)
    var seenCookie = "unset"
    let second: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        seenCookie = cookie
        (true, "<p>two</p>", @[], 200, "")
    discard browseInSession(second, home, "s1", "https://example.com/b",
      "GET", "", 20, 1001)
    assert seenCookie == "sid=abc"

  test "blocked host is refused without fetching":
    let home = tmpHome()
    var called = false
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        called = true
        (true, "", @[], 200, "")
    let text = browseInSession(fetch, home, "s1", "http://127.0.0.1/",
      "GET", "", 20, 1000)
    assert not called
    assert "will not open" in text.toLowerAscii() or "refuse" in text.toLowerAscii()

  test "invalid session id is refused without fetching":
    let home = tmpHome()
    var called = false
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        called = true
        (true, "", @[], 200, "")
    let text = browseInSession(fetch, home, "../x",
      "https://example.com/", "GET", "", 20, 1000)
    assert not called
    assert "session" in text.toLowerAscii()

  test "redirect keeps cookies per host and records both hops":
    let home = tmpHome()
    var cookieAtB = "unset"
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        if url == "https://a.example/":
          assert cookie == ""
          return (true, "", @["sid=a1; Path=/"], 302, "/next")
        if url == "https://a.example/next":
          return (true, "", @[], 302, "https://b.example/")
        if url == "https://b.example/":
          cookieAtB = cookie
          return (true, "<p>bee</p>", @["sid=b1; Path=/"], 200, "")
        return (false, "unexpected " & url, @[], 0, "")
    let text = browseInSession(fetch, home, "s1", "https://a.example/",
      "GET", "", 20, 1000)
    assert "bee" in text
    assert cookieAtB == ""  # a.com cookie never sent to b.com
    let (ok, back) = loadBrowseSession(home, "s1")
    assert ok
    assert back.lastUrl == "https://b.example/"
    assert cookieHeaderFor(back, "a.example") == "sid=a1"
    assert cookieHeaderFor(back, "b.example") == "sid=b1"
    assert back.history == @["https://a.example/", "https://a.example/next",
      "https://b.example/"]

  test "cross-host redirect to private is refused":
    let home = tmpHome()
    var privateCalled = false
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        if navUrlHost(url) == "127.0.0.1":
          privateCalled = true
        if url == "https://a.example/":
          return (true, "", @[], 302, "http://127.0.0.1/")
        return (true, "<p>x</p>", @[], 200, "")
    let text = browseInSession(fetch, home, "s1", "https://a.example/",
      "GET", "", 20, 1000)
    assert not privateCalled
    assert "will not open" in text.toLowerAscii() or "refuse" in text.toLowerAscii()

  test "a visit prunes sessions older than retention":
    let home = tmpHome()
    discard saveBrowseSession(home, newBrowseSession("old-9", 1000,
      "https://example.com/"))
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        (true, "<p>fresh</p>", @[], 200, "")
    discard browseInSession(fetch, home, "s1", "https://example.com/",
      "GET", "", 20, 700000)
    let (okOld, _) = loadBrowseSession(home, "old-9")
    assert not okOld
    let (okNew, _) = loadBrowseSession(home, "s1")
    assert okNew

  test "history keeps only the last 50 visits":
    var s = newBrowseSession("s50", 1000, "https://example.com/0")
    for i in 1 .. 55:
      recordBrowseVisit(s, "https://example.com/" & $i, 1000 + i)
    assert s.history.len == 50
    assert s.history[0] == "https://example.com/6"
    assert s.history[^1] == "https://example.com/55"

  test "a 303 post follows as get without the body":
    let home = tmpHome()
    var secondMeth = ""
    var secondBody = "unset"
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        if url == "https://example.com/form":
          assert meth == "POST"
          return (true, "", @[], 303, "/done")
        secondMeth = meth
        secondBody = body
        return (true, "<p>done</p>", @[], 200, "")
    let text = browseInSession(fetch, home, "s1",
      "https://example.com/form", "POST", "a=1", 20, 1000)
    assert "done" in text
    assert secondMeth == "GET"
    assert secondBody == ""

  test "more than five redirects refuse without dialing further":
    let home = tmpHome()
    var calls = 0
    let fetch: BrowseFetchFn =
      proc(url, meth, body, agent, cookie: string): tuple[ok: bool,
          text: string, setCookies: seq[string], status: int,
          location: string] =
        inc calls
        (true, "", @[], 302, url & "/r")
    let text = browseInSession(fetch, home, "s1", "https://example.com/",
      "GET", "", 20, 1000)
    assert "too many redirects" in text.toLowerAscii()
    assert calls == 6

  test "session file is user-only readable":
    when defined(posix):
      let home = tmpHome()
      discard saveBrowseSession(home, newBrowseSession("s1", 1000,
        "https://example.com/"))
      let perms = getFilePermissions(sessionFile(home, "s1"))
      assert fpUserRead in perms
      assert fpUserWrite in perms
      assert fpGroupRead notin perms
      assert fpOthersRead notin perms
