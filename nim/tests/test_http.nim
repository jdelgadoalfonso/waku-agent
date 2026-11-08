## Phase 3e tests: HTTP transport against a localhost stub. Offline by
## construction: a raw-socket stub server in a helper thread serves canned
## JSON/SSE per route; no external network ever. The stub shares no mutable
## state with the main thread (routes are stateless; auth selects the 401).

import std/json
import std/net
import std/os
import std/strutils
import std/unittest

import ../src/http
import ../src/loop
import ../src/tools

const stubPort = 18080

const
  chatJsonBody = """{"choices":[{"message":{"content":"hi from stub","tool_calls":null}}],"usage":{"prompt_tokens":2,"completion_tokens":3}}"""
  chatSseBody = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" &
    "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" &
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"t1\",\"function\":{\"name\":\"ping\",\"arguments\":\"{\\\"x\\\":1}\"}}]}}]}\n\n" &
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":5}}\n\n" &
    "data: [DONE]\n\n"
  msgJsonBody = """{"id":"m1","type":"message","role":"assistant","content":[{"type":"text","text":"hello human"}],"stop_reason":"end_turn","usage":{"input_tokens":6,"output_tokens":2}}"""
  msgSseBody = "event: message_start\n" &
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":6,\"output_tokens\":0}}}\n\n" &
    "event: content_block_start\n" &
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" &
    "event: content_block_delta\n" &
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n" &
    "event: content_block_stop\n" &
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" &
    "event: message_delta\n" &
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" &
    "event: message_stop\n" &
    "data: {\"type\":\"message_stop\"}\n\n"
  refusedBody = """{"error":{"message":"bad key"}}"""
  flakyErrorBody = """{"error":{"message":"unknown parameter: max_completion_tokens"}}"""

type StubCfg = object
  port: int

proc recvExactly(client: Socket, n: int): string =
  result = newStringOfCap(n)
  while result.len < n:
    let chunk = client.recv(n - result.len)
    if chunk.len == 0:
      break
    result.add(chunk)

proc serveStub(cfg: StubCfg) {.thread.} =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(cfg.port), "127.0.0.1")
  server.listen()
  while true:
    var client: Socket
    accept(server, client)
    try:
      var contentLen = 0
      var auth = ""
      var apiKey = ""
      var reqLine = ""
      try:
        reqLine = client.recvLine()
        while true:
          let line = client.recvLine()
          if line.strip().len == 0:
            break
          let parts = line.split(":", 1)
          if parts.len == 2:
            if parts[0].strip().toLowerAscii() == "content-length":
              try: contentLen = parseInt(parts[1].strip())
              except ValueError: discard
            if parts[0].strip().toLowerAscii() == "authorization":
              auth = parts[1].strip()
            if parts[0].strip().toLowerAscii() == "x-api-key":
              apiKey = parts[1].strip()
      except OSError:
        client.close()
        continue
      let body = if contentLen > 0: recvExactly(client, contentLen) else: ""
      var status = "200 OK"
      var ctype = "application/json"
      var respBody = ""
      if auth != "Bearer test-key" and apiKey != "test-key":
        status = "401 Unauthorized"
        respBody = refusedBody
      elif "/v1/chat/completions" in reqLine:
        if "\"stream\":true" in body.replace(" ", ""):
          ctype = "text/event-stream"
          respBody = chatSseBody
        elif "flaky-model" in body and "max_completion_tokens" in body:
          # stateless retry probe: fail only the new key name, succeed legacy
          status = "400 Bad Request"
          respBody = flakyErrorBody
        else:
          respBody = chatJsonBody
      elif "/v1/messages" in reqLine:
        if "\"stream\":true" in body.replace(" ", ""):
          ctype = "text/event-stream"
          respBody = msgSseBody
        else:
          respBody = msgJsonBody
      else:
        status = "404 Not Found"
        respBody = """{"error":{"message":"no such stub route"}}"""
      client.send("HTTP/1.1 " & status & "\r\nContent-Type: " & ctype &
        "\r\nContent-Length: " & $respBody.len &
        "\r\nConnection: close\r\n\r\n")
      if ctype == "text/event-stream" and respBody.len > 60:
        client.send(respBody[0 ..< 60])
        sleep(30)
        client.send(respBody[60 .. ^1])
      else:
        client.send(respBody)
    except OSError:
      discard
    try: client.close()
    except OSError: discard

var serverThread: Thread[StubCfg]
var stubStarted = false

proc waitStub(port: int) =
  for _ in 0 ..< 100:
    try:
      var s = newSocket()
      s.connect("127.0.0.1", Port(port))
      s.close()
      return
    except OSError:
      sleep(50)
  raise newException(CatchableError, "stub server did not start")

proc ensureStub() =
  if not stubStarted:
    stubStarted = true
    createThread(serverThread, serveStub, StubCfg(port: stubPort))
    waitStub(stubPort)

proc openAiTransport(key = "test-key"): Transport =
  Transport(baseUrl: "http://127.0.0.1:" & $stubPort & "/v1", apiKey: key,
            wire: wkOpenAi)

proc anthropicTransport(): Transport =
  Transport(baseUrl: "http://127.0.0.1:" & $stubPort, apiKey: "test-key",
            wire: wkAnthropic)

proc turnReq(): JsonNode =
  %*{"model": "m", "system": "sys",
     "messages": [{"role": "user", "content": "hi"}],
     "tools": [], "max_tokens": 16}

proc toollessReq(): JsonNode =
  %*{"model": "m", "system": "sys",
     "messages": [{"role": "user", "content": "hi"}],
     "max_tokens": 16}

suite "phase 3e transport":
  test "openai json round-trips through the stub":
    ensureStub()
    let msg = openAiTransport().createRemote(turnReq())
    assert msg["content"] == %*[{"type": "text", "text": "hi from stub"}]
    assert msg["usage"] == %*{"in": 2, "out": 3}
    assert msg["stop_reason"].getStr() == "end_turn"

  test "openai sse assembles text and a tool call live":
    ensureStub()
    var deltas: seq[string] = @[]
    let msg = openAiTransport().streamRemote(turnReq(),
      proc(d: string) = deltas.add(d))
    assert deltas == @["Hel", "lo"]
    assert msg["content"][0] == %*{"type": "text", "text": "Hello"}
    assert msg["content"][1] == %*{"type": "tool_use", "id": "t1",
      "name": "ping", "input": {"x": 1}}
    assert msg["stop_reason"].getStr() == "tool_use"
    assert msg["usage"] == %*{"in": 4, "out": 5}

  test "anthropic json maps to the assembled shape":
    ensureStub()
    let msg = anthropicTransport().createRemote(turnReq())
    assert msg["content"] == %*[{"type": "text", "text": "hello human"}]
    assert msg["usage"] == %*{"in": 6, "out": 2}

  test "anthropic sse assembles text with usage":
    ensureStub()
    var deltas: seq[string] = @[]
    let msg = anthropicTransport().streamRemote(turnReq(),
      proc(d: string) = deltas.add(d))
    assert deltas == @["Hi"]
    assert msg["content"] == %*[{"type": "text", "text": "Hi"}]
    assert msg["usage"] == %*{"in": 6, "out": 2}

  test "anthropic json tolerates a toolless request":
    ensureStub()
    let msg = anthropicTransport().createRemote(toollessReq())
    assert msg["content"] == %*[{"type": "text", "text": "hello human"}]
    assert msg["usage"] == %*{"in": 6, "out": 2}

  test "a 401 surfaces as a refusal with status":
    ensureStub()
    try:
      discard openAiTransport("wrong").createRemote(turnReq())
      assert false, "must raise"
    except LlmRefused as e:
      assert e.statusCode == 401
      assert e.msg == "bad key"

  test "legacy key retry recovers after a parameter error":
    ensureStub()
    var req = turnReq()
    req["model"] = %"flaky-model"
    let msg = openAiTransport().createRemote(req)
    assert msg["content"] == %*[{"type": "text", "text": "hi from stub"}]

  test "loop runs end to end against the stub":
    ensureStub()
    var reg: ToolRegistry
    var messages = @[%*{"role": "user", "content": "hi"}]
    let res = runLoop(openAiTransport().toLlmClient(), "m", "sys",
                      messages, reg)
    assert res.reply == "hi from stub"
    assert res.iterations == 1
