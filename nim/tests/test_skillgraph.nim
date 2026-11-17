## Skill graph validator (T1): the security boundary before compilation.
##
## Validates the restricted plugin manifest subset that skills may use:
## kinds llm+router only, needs ⊆ {llm}, prompt strings, DAG reachable
## from the first node. Every rejection shape is pinned here.

import std/json
import std/strutils
import std/unittest

import ../src/graph/skillgraph

proc validGraph(): JsonNode =
  ## Minimal valid skill graph: one llm node.
  %*{
    "name": "summarize",
    "abi": 1,
    "nodes": [
      {"name": "summarize", "kind": "llm", "inKeys": ["message"],
       "outKey": "summary", "needs": ["llm"],
       "prompt": "Summarize: {{message}}"}
    ]
  }

suite "skill graph validator":

  test "accepts a minimal valid llm node":
    let g = validateSkillGraph(validGraph())
    assert g.name == "summarize"
    assert g.nodes.len == 1
    assert g.nodes[0].kind == "llm"
    assert g.nodes[0].prompt == "Summarize: {{message}}"

  test "accepts llm + router with valid routes":
    let graph = %*{
      "name": "summarize-translate",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"],
         "prompt": "Summarize: {{message}}"},
        {"name": "route", "kind": "router",
         "inKeys": ["summary"], "outKey": "", "needs": ["llm"],
         "routes": [{"label": "long", "dst": "translate",
                     "when": {"key": "summary", "op": "len_gt", "value": 120}},
                    {"label": "short", "dst": "END"}]},
        {"name": "translate", "kind": "llm", "inKeys": ["summary"],
         "outKey": "reply", "needs": ["llm"],
         "prompt": "Translate to French: {{summary}}"}
      ]
    }
    let g = validateSkillGraph(graph)
    assert g.nodes.len == 3
    assert g.nodes[1].kind == "router"
    assert g.nodes[1].routes.len == 2

  test "rejects non-object manifest":
    expect SkillGraphError:
      discard validateSkillGraph(%*"not an object")

  test "rejects missing name":
    let graph = validGraph()
    graph.delete("name")
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects empty name":
    let graph = validGraph()
    graph["name"] = %""
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects wrong abi":
    let graph = validGraph()
    graph["abi"] = %2
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects missing nodes":
    let graph = validGraph()
    graph.delete("nodes")
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects empty nodes":
    let graph = validGraph()
    graph["nodes"] = %*[]
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects tool kind":
    let graph = validGraph()
    graph["nodes"][0]["kind"] = %"tool"
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects agent kind":
    let graph = validGraph()
    graph["nodes"][0]["kind"] = %"agent"
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects unknown kind":
    let graph = validGraph()
    graph["nodes"][0]["kind"] = %"bogus"
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects needs tool":
    let graph = validGraph()
    graph["nodes"][0]["needs"] = %*["tool"]
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects needs fetch":
    let graph = validGraph()
    graph["nodes"][0]["needs"] = %*["fetch"]
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects llm node without prompt":
    let graph = validGraph()
    graph["nodes"][0].delete("prompt")
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects llm node with non-string prompt":
    let graph = validGraph()
    graph["nodes"][0]["prompt"] = %42
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects duplicate node names":
    let graph = validGraph()
    graph["nodes"].add(graph["nodes"][0])
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects node without name":
    let graph = validGraph()
    graph["nodes"][0].delete("name")
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects router without routes":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "route", "kind": "router", "needs": ["llm"], "routes": []}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects route to unknown node":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "needs": ["llm"],
         "routes": [{"label": "go", "dst": "nonexistent"}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects duplicate route labels":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END"},
                    {"label": "go", "dst": "summarize"}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects cycle in graph":
    let graph = %*{
      "name": "cyclic",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "a"},
        {"name": "r1", "kind": "router", "inKeys": ["x"], "needs": ["llm"],
         "routes": [{"label": "next", "dst": "b"}]},
        {"name": "b", "kind": "llm", "inKeys": ["x"],
         "outKey": "y", "needs": ["llm"], "prompt": "b"},
        {"name": "r2", "kind": "router", "inKeys": ["y"], "needs": ["llm"],
         "routes": [{"label": "back", "dst": "a"}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects unreachable node":
    let graph = %*{
      "name": "unreachable",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "a"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "done", "dst": "END"}]},
        {"name": "orphan", "kind": "llm", "inKeys": ["x"],
         "outKey": "y", "needs": ["llm"], "prompt": "orphan"}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "accepts END route":
    let graph = %*{
      "name": "simple",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["summary"],
         "needs": ["llm"],
         "routes": [{"label": "done", "dst": "END"}]}
      ]
    }
    let g = validateSkillGraph(graph)
    assert g.nodes.len == 2

  test "accepts routes with when conditions":
    let graph = %*{
      "name": "cond",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["summary"],
         "needs": ["llm"],
         "routes": [
           {"label": "long", "dst": "END",
            "when": {"key": "summary", "op": "len_gt", "value": 120}},
           {"label": "has_error", "dst": "END",
            "when": {"key": "summary", "op": "contains", "value": "error"}},
           {"label": "short", "dst": "END"}]}
      ]
    }
    let g = validateSkillGraph(graph)
    assert g.nodes[1].routes[0].hasWhen
    assert g.nodes[1].routes[0].condKey == "summary"
    assert g.nodes[1].routes[0].condOp == "len_gt"
    assert g.nodes[1].routes[0].condInt == 120
    assert g.nodes[1].routes[1].condOp == "contains"
    assert g.nodes[1].routes[1].condStr == "error"
    assert not g.nodes[1].routes[2].hasWhen

  test "accepts eq and len_lt conditions":
    let graph = %*{
      "name": "cond2",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [
           {"label": "yes", "dst": "END",
            "when": {"key": "x", "op": "eq", "value": "yes"}},
           {"label": "tiny", "dst": "END",
            "when": {"key": "x", "op": "len_lt", "value": 10}},
           {"label": "other", "dst": "END"}]}
      ]
    }
    let g = validateSkillGraph(graph)
    assert g.nodes[1].routes[0].condStr == "yes"
    assert g.nodes[1].routes[1].condInt == 10

  test "rejects router without llm need":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": [],
         "routes": [{"label": "done", "dst": "END"}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when with unknown op":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END",
                     "when": {"key": "x", "op": "regex", "value": ".*"}}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when with wrong value type for len_gt":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END",
                     "when": {"key": "x", "op": "len_gt", "value": "big"}}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when with wrong value type for contains":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END",
                     "when": {"key": "x", "op": "contains", "value": 5}}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when with empty key":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END",
                     "when": {"key": "", "op": "len_gt", "value": 5}}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when that is not an object":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END", "when": "len_gt"}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when missing op":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END",
                     "when": {"key": "x", "value": 5}}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects when missing value":
    let graph = %*{
      "name": "bad",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "x"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "go", "dst": "END",
                     "when": {"key": "x", "op": "len_gt"}}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  # ---- Data flow (T1c / S9): a graph must be coherent, not just shaped. ----

  test "rejects prompt placeholder that is not an inKey":
    let graph = validGraph()
    graph["nodes"][0]["prompt"] = %"Summarize: {{sumary}}"
    var msg = ""
    try:
      discard validateSkillGraph(graph)
    except SkillGraphError as e:
      msg = e.msg
    check msg.contains("summarize")   # names the node
    check msg.contains("sumary")      # names the key

  test "rejects message placeholder when message is not declared in inKeys":
    let graph = %*{
      "name": "doc",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm", "inKeys": ["mem_text"],
         "outKey": "summary", "needs": ["llm"],
         "prompt": "Summarize: {{message}}"}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "accepts message and mem_text placeholders when declared in inKeys":
    let graph = %*{
      "name": "memo",
      "abi": 1,
      "nodes": [
        {"name": "summarize", "kind": "llm",
         "inKeys": ["message", "mem_text"],
         "outKey": "summary", "needs": ["llm"],
         "prompt": "Memory: {{mem_text}} Message: {{message}}"}
      ]
    }
    let g = validateSkillGraph(graph)
    assert g.nodes[0].prompt == "Memory: {{mem_text}} Message: {{message}}"

  test "rejects prompt placeholder for a produced key not declared in inKeys":
    let graph = %*{
      "name": "undeclared",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "a"},
        {"name": "b", "kind": "llm", "inKeys": ["message"],
         "outKey": "reply", "needs": ["llm"], "prompt": "Use {{x}}"}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "accepts inKey produced by an earlier node":
    let graph = %*{
      "name": "chain",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"],
         "prompt": "Summarize: {{message}}"},
        {"name": "b", "kind": "llm", "inKeys": ["summary"],
         "outKey": "reply", "needs": ["llm"],
         "prompt": "Translate: {{summary}}"}
      ]
    }
    let g = validateSkillGraph(graph)
    assert g.nodes.len == 2

  test "rejects inKey that no earlier node produces":
    let graph = validGraph()
    graph["nodes"][0]["inKeys"] = %*["summary"]
    graph["nodes"][0]["prompt"] = %"Summarize: {{summary}}"
    var msg = ""
    try:
      discard validateSkillGraph(graph)
    except SkillGraphError as e:
      msg = e.msg
    check msg.contains("summarize")   # names the node
    check msg.contains("'summary'")   # names the key

  test "rejects inKey produced only by a later node":
    let graph = %*{
      "name": "backwards",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["summary"],
         "outKey": "reply", "needs": ["llm"],
         "prompt": "Summarize: {{summary}}"},
        {"name": "b", "kind": "llm", "inKeys": ["message"],
         "outKey": "summary", "needs": ["llm"],
         "prompt": "Produce: {{message}}"}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects router inKey that no earlier node produces":
    let graph = %*{
      "name": "badrouter",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "a"},
        {"name": "route", "kind": "router", "inKeys": ["missing"],
         "needs": ["llm"],
         "routes": [{"label": "done", "dst": "END"}]}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)

  test "rejects inKey produced only on a sibling branch":
    # `b` runs only on the "b" route; `d` is reached through "c", so a
    # run may reach `d` without `b` ever writing `y`. Declaration order
    # alone would accept this; the edge model must not.
    let graph = %*{
      "name": "siblings",
      "abi": 1,
      "nodes": [
        {"name": "a", "kind": "llm", "inKeys": ["message"],
         "outKey": "x", "needs": ["llm"], "prompt": "a"},
        {"name": "route", "kind": "router", "inKeys": ["x"],
         "needs": ["llm"],
         "routes": [{"label": "left", "dst": "b"},
                    {"label": "right", "dst": "c"}]},
        {"name": "b", "kind": "llm", "inKeys": ["message"],
         "outKey": "y", "needs": ["llm"], "prompt": "b"},
        {"name": "r2", "kind": "router", "inKeys": ["message"],
         "needs": ["llm"],
         "routes": [{"label": "done", "dst": "END"}]},
        {"name": "c", "kind": "llm", "inKeys": ["x"],
         "outKey": "z", "needs": ["llm"], "prompt": "c {{x}}"},
        {"name": "d", "kind": "llm", "inKeys": ["y"],
         "outKey": "reply", "needs": ["llm"], "prompt": "{{y}}"}
      ]
    }
    expect SkillGraphError:
      discard validateSkillGraph(graph)
