## Judgment-case tests: suite shape and counts, the label-free picker,
## the grading rules and the answer shapes. Offline only: the data is
## compiled in, no network, no keys.

import std/json
import std/sequtils
import std/strutils
import std/unittest

import ../src/judgment_cases

suite "judgment suites":
  test "five suites, five cases each, fifteen questions each":
    let suites = allSuites()
    assert suites.len == 5
    for id in ["leads", "refunds", "support", "memory", "investors"]:
      assert suites.hasKey(id), id
    let listed = suiteList(suites)
    assert listed.len == 5
    for s in listed:
      assert s["cases"].len == 5
      assert s["n"].getInt() == 15
      var kinds: seq[string] = @[]
      for c in s["cases"]:
        assert c["questions"].len == 3
        for q in c["questions"]:
          kinds.add(q["type"].getStr())
          assert q.hasKey("id") and q.hasKey("instructions")
      assert kinds.filterIt(it == "noul").len == 5
      assert kinds.filterIt(it == "choice").len == 5
      assert kinds.filterIt(it == "score").len == 5

  test "the picker never carries labels":
    let text = $suiteList(allSuites())
    assert "expected" notin text
    # ...but the race seam still grades against them.
    let suites = allSuites()
    assert suites["leads"]["cases"][0]["questions"][0]["expected"]
      .getBool() == true

  test "questions_of reads fifteen in order":
    let got = questionsOf(allSuites(), "memory")
    assert got.len == 15
    assert got[0][0] == 0
    assert got[14][0] == 4
    assert questionsOf(allSuites(), "nope").len == 0

  test "answer shapes name the options":
    let suites = allSuites()
    let choice = suites["leads"]["cases"][0]["questions"][1]
    assert answerShape(choice) ==
      "one of: a_price, a_sample, a_meeting, support, nothing"
    let score = suites["leads"]["cases"][0]["questions"][2]
    assert answerShape(score).startsWith("4 levels: 0 Not a buyer")
    let noul = suites["leads"]["cases"][0]["questions"][0]
    assert answerShape(noul) == "a probability from 0 to 1"

suite "judgment grading":
  test "noul lands on a side of the coin flip":
    assert isRight("noul", %true, %*{"noul": 0.7}) == true
    assert isRight("noul", %true, %*{"noul": 0.2}) == false
    assert isRight("noul", %false, %*{"noul": 0.5}) == false

  test "choice picks the labelled option":
    assert isRight("choice", %"a_price", %*{"choice": "a_price"}) == true
    assert isRight("choice", %"a_price", %*{"choice": "nothing"}) == false

  test "score rounds half to even, like Python":
    assert roundHalfEven(2.5) == 2
    assert roundHalfEven(3.5) == 4
    assert isRight("score", %2, %*{"score": 2.4}) == true
    assert isRight("score", %2, %*{"score": 2.5}) == true
    assert isRight("score", %2, %*{"score": 2.6}) == false
    assert isRight("score", %3, %*{"score": 3.5}) == false
    assert isRight("score", %4, %*{"score": 3.5}) == true

  test "missing answers are wrong, never a crash":
    assert isRight("noul", %true, newJNull()) == false
    assert isRight("choice", %"a", newJNull()) == false
    assert isRight("score", %1, newJNull()) == false
