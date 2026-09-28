## Phase 1b tests: the FTS5 parity gate.
## Every vector below is ground truth from the real Python `_fts_query`
## (run 2026-09-28 against waku/memory/semantic/store.py). Pure and offline:
## no DB, no network. If any vector fails, the gate is red and nothing may
## build on `ftsQuery` until it is green again.
##
## Deliberately no vector pins the non-ASCII-numeral divergence (it would
## fail by design): see the `isWordRune` doc in `src/memory.nim` before
## "fixing" tokenization.

import std/unittest

import ../src/memory

const vectors = [
  ("Alex and Bob", "alex OR and OR bob"),
  ("waku_agent", "waku OR agent"),
  ("under_score test_case", "under OR score OR test OR case"),
  ("car carpet", "car OR carpet"),
  ("a b cd", "cd"),
  ("x", ""),
  ("", ""),
  ("   ", ""),
  ("hello HELLO hello", "hello"),
  ("a1 b22 c333", "a1 OR b22 OR c333"),
  ("email me@x.com now", "email OR me OR com OR now"),
  ("price 100 and 50 percent", "price OR 100 OR and OR 50 OR percent"),
  ("neko-chan desu", "neko OR chan OR desu"),
  ("hiragana desu", "hiragana OR desu"),
  ("well-known fact", "well OR known OR fact"),
  ("don't stop", "don OR stop"),
  ("user123 test4567", "user123 OR test4567"),
  ("UPPER lower MiXeD", "upper OR lower OR mixed"),
  ("or and not near", "or OR and OR not OR near"),
  ("Muller Munchen", "muller OR munchen"),
  ("Sao Paulo cafe", "sao OR paulo OR cafe"),
  ("lundi 3eme etage", "lundi OR 3eme OR etage"),
  ("M\u00fcller M\u00fcnchen", "m\u00fcller OR m\u00fcnchen"),
  ("S\u00e3o Paulo caf\u00e9", "s\u00e3o OR paulo OR caf\u00e9"),
  ("lundi 3\u00e8me \u00e9tage", "lundi OR 3\u00e8me OR \u00e9tage"),
  ("\u963f\u5386\u514b\u65af\u559c\u6b22\u6e38\u6cf3", "\u963f\u5386\u514b\u65af\u559c\u6b22\u6e38\u6cf3*"),
  ("\u65e5\u672c\u8a9e\u30c6\u30b9\u30c8", "\u65e5\u672c\u8a9e\u30c6\u30b9\u30c8*"),
  ("\u0421\u0435\u0440\u0433\u0435\u0439", "\u0441\u0435\u0440\u0433\u0435\u0439"),
  ("M\u00fcller and M\u00fcnchen and M\u00fcller", "m\u00fcller OR and OR m\u00fcnchen"),
  ("na\u00efve fa\u00e7ade", "na\u00efve OR fa\u00e7ade"),
  ("\u0391\u03b8\u03ae\u03bd\u03b1", "\u03b1\u03b8\u03ae\u03bd\u03b1"),
  ("abc M\u00fcller def", "abc OR m\u00fcller OR def"),
]

suite "phase 1b fts parity gate":
  test "ftsQuery matches the Python ground-truth vectors":
    for (input, expected) in vectors:
      assert ftsQuery(input) == expected,
        "input " & input & ": got " & ftsQuery(input) & ", want " & expected
