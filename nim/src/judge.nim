## The referee — port of `waku/ops/judge.py`'s `judge_reply`.
##
## Grades one reply 0-10 against the rubric, with the tools that ACTUALLY
## fired passed as ground truth (so "I saved that" with `save_note` in
## the list is not mistaken for a hallucination). `JNull` when there is
## nothing to grade or the judge is unreachable — a judge hiccup must
## never fail a race. Retries only the API call (growing backoff, like
## Python); an answer that arrives but won't parse is not retried.

import std/json
import std/os
import std/strutils

import ./loop
import ./wire

const
  judgeProviderDefault* = "openai"
  judgeModelDefault* = "gpt-5.6-sol"
    ## Who the referee is when the payload names none (`WAKU_JUDGE_*`
    ## win at call time; also mirrored as `arena.defaultJudgeModel`).

  judgeRubric* = """You are a strict, fair judge scoring an AI assistant's reply.

The user asked:
{task}

The assistant replied:
{reply}
{actions}
Score how well the reply serves the user's request on a 0-10 scale:
- 9-10: fully addresses the request, correct, concise, honest about any limits.
- 5-8: mostly addresses it, minor gaps, padding, or small errors.
- 1-4: partial, vague, or partly wrong.
- 0: ignores the request, or claims an action that is NOT in the tool list above.

IMPORTANT: the tools listed above REALLY ran — this assistant can take those
actions. Do NOT penalize the reply for saying it did something that appears in
that list; those claims are true. Only "hallucinating" counts against it when it
claims an action with no matching tool call.

Reply with ONLY a JSON object, no prose:
{{"score": <int 0-10>, "reason": "<one short sentence>"}}"""
    ## Verbatim `_RUBRIC` (`{task}`/`{reply}`/`{actions}` fill below).

type
  JudgeClientFn* = proc(provider, model: string): LlmClient {.closure.}
    ## The referee's client: tests inject a scripted one, the binary
    ## builds `clientFor` per call (a burst of grades must not share
    ## one client any more than Python shares one).

proc judgeReply*(task, reply: string, provider, model: string,
    tools: seq[string], buildClient: JudgeClientFn,
    sleeper: proc(ms: int) {.closure.} = nil): JsonNode =
  ## Grade one reply, or `JNull`. Empty replies are not graded at all.
  if reply.strip().len == 0:
    return newJNull()
  let prov = if provider.len > 0: provider
             else: getEnv("WAKU_JUDGE_PROVIDER", judgeProviderDefault)
  let modl = if model.len > 0: model
             else: getEnv("WAKU_JUDGE_MODEL", judgeModelDefault)
  let actions =
    if tools.len > 0:
      "\nTools the assistant actually ran this turn (ground truth): " &
      tools.join(", ") & ".\n"
    else:
      "\nThe assistant ran no tools this turn.\n"
  let prompt = judgeRubric.replace("{task}", task[0 ..< min(2000,
      task.len)]).replace("{reply}", reply[0 ..< min(4000, reply.len)])
    .replace("{actions}", actions)
  var text = ""
  var ok = false
  for attempt in 0 ..< 4:
    try:
      let client = buildClient(prov, modl)
      let req = %*{"model": modl, "max_tokens": 300,
                   "messages": @[%*{"role": "user", "content": prompt}]}
      text = textOf(client.create(req)["content"])
      ok = true
      break
    except CatchableError:
      if attempt < 3 and not sleeper.isNil:
        sleeper(int(1200.0 * float(attempt + 1)))
  if not ok:
    return newJNull()
  try:
    let a = text.find('{')
    let b = text.rfind('}')
    if a < 0 or b < a:
      return newJNull()
    let obj = parseJson(text[a .. b])
    var score = 0
    let raw = obj.jget("score")
    if raw.kind == JInt:
      score = int(raw.getBiggestInt())
    elif raw.kind == JFloat:
      score = int(raw.getFloat())
    score = max(0, min(10, score))
    return %*{"score": score,
              "reason": obj.jget("reason").getStr()[0 ..< min(200,
                obj.jget("reason").getStr().len)],
              "judge": modl}
  except CatchableError:
    return newJNull()
