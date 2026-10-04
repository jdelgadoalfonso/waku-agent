## Scoring tests: battery loading, the deterministic contract and
## message matching. Offline only: a temp dataset file, never the
## checkout's.

import std/json
import std/os
import std/unittest

import ../src/scoring

proc freshDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "scoring":
  test "no tool expected passes only when silent":
    assert checkCase(%*{"id": "c"}, newJArray()) == (true,
      "no tool expected")
    assert checkCase(%*{"id": "c"},
      %*[{"tool": "save_note"}])[0] == false

  test "right tool, right args, enough calls":
    let c = %*{"id": "c", "expect_tool": "save_note",
               "expect_in_args": {"content": "swim"},
               "expect_min_tool_calls": 2}
    let calls = %*[{"tool": "save_note", "args": {"content": "swim!"}},
                   {"tool": "save_note", "args": {"content": "swim?"}}]
    assert checkCase(c, calls) == (true, "ok")
    assert checkCase(c, %*[{"tool": "other", "args": {}}])[1] ==
      "expected save_note, called other"
    assert checkCase(c, %*[{"tool": "save_note",
      "args": {"content": "bike"}}])[1] == "'swim' not in args[content]"
    assert checkCase(c, %*[{"tool": "save_note",
      "args": {"content": "swim"}}])[1] ==
      "only 1 tool calls, wanted >= 2"

  test "messages match battery inputs exactly":
    let dir = freshDir("waku-scoring")
    writeFile(dir / "dataset.jsonl",
      "{\"id\": \"a\", \"input\": \"  hi  \"}\nbad line\n")
    let cases = loadCases(dir / "dataset.jsonl")
    assert cases.len == 1
    assert caseForMessage("hi", cases)["id"].getStr() == "a"
    assert caseForMessage("other", cases).kind == JNull
    assert loadCases(dir / "missing.jsonl").len == 0
    removeDir(dir)
