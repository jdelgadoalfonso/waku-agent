## Trim tests: old tool results, cut once read (T1 pins).

import std/json
import std/strutils
import std/unittest

import ../src/trim

proc toolMsg(text: string): JsonNode =
  %*{"role": "user", "content": [%*{"type": "tool_result",
    "tool_use_id": "t1", "content": text}]}

proc textMsg(text: string): JsonNode =
  %*{"role": "user", "content": text}

suite "shrink_seen":
  test "a long result before the newest is cut to its opening plus the note":
    let big = "x".repeat(5000)
    var messages = @[toolMsg(big), toolMsg("short")]
    shrinkSeen(messages)
    let got = messages[0]["content"][0]["content"].getStr()
    assert got.startsWith("x".repeat(KEEP_CHARS))
    assert "Cut from 5,000 characters" in got
    assert "write down what you need" in got
    assert messages[1]["content"][0]["content"].getStr() == "short"

  test "short results, newest long results and non-tool blocks stay whole":
    let big = "y".repeat(6000)
    var messages = @[toolMsg("a".repeat(4000)), toolMsg(big)]
    shrinkSeen(messages)
    assert messages[0]["content"][0]["content"].getStr().len == 4000
    assert messages[1]["content"][0]["content"].getStr().len == 6000
    var plain = @[textMsg(big), toolMsg("z")]
    shrinkSeen(plain)
    assert plain[0]["content"].getStr().len == 6000

  test "a cut result is never cut again":
    let big = "x".repeat(5000)
    var messages = @[toolMsg(big), toolMsg("short")]
    shrinkSeen(messages)
    let once = messages[0]["content"][0]["content"].getStr()
    shrinkSeen(messages)
    assert messages[0]["content"][0]["content"].getStr() == once

suite "chain":
  test "steps run in order":
    var order: seq[string] = @[]
    let a: Trim = proc(messages: var seq[JsonNode]) {.closure.} =
      order.add("a")
    let b: Trim = proc(messages: var seq[JsonNode]) {.closure.} =
      order.add("b")
    let run = chainTrim(a, b)
    var messages: seq[JsonNode] = @[]
    run(messages)
    assert order == @["a", "b"]
