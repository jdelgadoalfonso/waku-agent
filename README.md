<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/waku-mark-on-dark.svg">
  <img src="docs/brand/waku-mark-on-light.svg" alt="Waku" width="76" align="right">
</picture>

# waku-agent

**Your own AI assistant. On your laptop. In code you can read in an afternoon.**

Meet **Waku** — a local-first personal assistant that shows the four pillars behind every
serious agent: **Harness · Loop · Memory · Eval/LLM-Ops**. No frameworks hiding the good parts.
Built by [seanchen.io](https://seanchen.io).

- **One binary.** `nimble build` produces `nim/waku`: no interpreter, no pip extras, and the
  dashboard's files are inside it.
- **Local-first.** Your memory is one SQLite file. Open it. Read it. It's yours.
- **Memory is the hero.** Semantic + episodic + procedural — with a gate that decides *whether*
  to remember, and a pass that decides *what* to keep.
- **The loop is one readable file.** Step through it.
- **Watch it think.** A local dashboard lights up every message as it flows through the harness.
- **Eval built in.** Deterministic tests *and* LLM-as-judge, side by side, with a release gate.

![waku-agent architecture — the whiteboard](docs/architecture-whiteboard.png)

> The system-design whiteboard from the series.
> Every box maps to a file — see [the architecture](docs/architecture.md).

**▶ [Watch the 20-min code walkthrough](https://www.youtube.com/watch?v=rvRyBhILrls&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=42)** — the loop, the memory pillars, the evals, the Telegram gateway and the "Waku Waku" wake word, live.

**[Waku Memory](https://www.waku.one)** — the same memory in Claude Code, Codex, Grok Bot and this agent: [waku.one](https://www.waku.one) · [docs](https://www.waku.one/docs)

[YouTube](https://www.youtube.com/@SeanAIStories) · [X](https://x.com/ShenSeanChen) · [LinkedIn](https://linkedin.com/in/shen-sean-chen) · [Instagram](https://www.instagram.com/sean_ai_stories) · [TikTok](https://www.tiktok.com/@sean_ai_stories) · [Discord](https://discord.gg/ebbdvSCXqu) ·
[哔哩哔哩](https://space.bilibili.com/479332937) · [小红书](https://www.xiaohongshu.com/user/profile/5cf02cfb0000000005014371) · [抖音](https://www.douyin.com/user/MS4wLjABAAAAWCkd62_e8q4n-S34LIL04HsYN3m03l8MFdVYZToojP8)

### [Buy me a coffee](https://buy.stripe.com/5kA176bA895ggog4gh) — it keeps this repo (and the videos) coming

## Quickstart

Waku is one Nim binary. Building it needs Nim 2.0 or newer, and the build reads
this checkout because the dashboard's files embed at compile time:

```bash
git clone https://github.com/ShenSeanChen/waku-agent && cd waku-agent
cd nim && nimble install --depsOnly     # the only step that touches the network
nimble build                            # builds ./waku, dashboard assets inside
cd ..
cp .env.example .env                    # pick a provider, paste ONE key
./nim/waku                              # talk to your Waku in the terminal
./nim/waku dashboard                    # …or the browser cockpit → localhost:7777
```

From the repo root, `make nim-build` runs the same build and `make nim-test`
runs the port's offline suite. On its first run the binary tells you which key
to set. `nim/README.md` says what is ported and what is not.

**Now try it.** *"Remember that Alex prefers morning meetings."* Quit. Restart.
*"Book a catch-up with Alex on Friday."* → it remembers, and books 9am. Your memory is one
file: `~/.waku/state.db`, the same from every folder.

**Use the model you already pay for.** Anthropic (default), OpenAI, Gemini, DeepSeek, MiniMax,
Kimi, GLM, OpenRouter (one key, hundreds of hosted models), OpenCode Zen, or OpenCode Go —
set `WAKU_PROVIDER=`, paste the key, done. One registry names every provider
(`data/providers.toml`, read by `nim/src/providers.nim`), and one adapter in the
loop handles the rest.

New to it? **[Getting started](docs/getting-started.md)** walks the whole setup, with a check
at the end of every step.

## The Python half is frozen

The Nim binary is how you use Waku. The Python half, `waku/`, is frozen: it gains
no new capability and no new behaviour eval, and every new change lands in
`nim/`. `pip install waku-agent` still installs that frozen package.

`waku/` stays in the tree for three reasons, and none of them is nostalgia.

1. **It is the parity oracle.** Every phase of the Nim port was verified
   against what the Python code does, so the Python code is the answer key.
2. **`evals/deterministic/` still runs.** 950 offline evals guard this
   repository on every pull request.
3. **One file the Nim port reads is still there.** `nim/src/waku.nim` reads
   `../waku.nimble`. Everything else the port needs is data, in `data/`: the
   provider registry both halves read, and the dashboard assets it embeds.

`hosted/` stays Python and stays unchanged, with its own Elastic License 2.0.
[docs/status.md](docs/status.md) records what works today, and
[docs/nim-port-design.md](docs/nim-port-design.md) records the phases.

## Connect Waku Memory

Waku's own memory is local. **[Waku Memory](https://www.waku.one)** is the hosted memory you
share across agents: save something in Claude Code, recall it here.

```bash
./nim/waku connect waku-memory          # or /connect waku-memory in the dashboard chat
./nim/waku skill export --to claude,codex   # carry Waku's skills to Claude Code and Codex too
```

Your browser opens once to sign in. To connect Claude Code, Codex, Hermes or Grok Bot to the
same memory, see [integrations](docs/integrations.md#share-one-memory-with-your-other-agents-waku-memory).
For live data when it researches, `./nim/waku connect treg` (or `/connect treg`) signs in to
your own [treg](https://treg.to) account the same way; see
[integrations](docs/integrations.md#live-data-for-research-treg).

## What's inside

| Pillar | In one line | Read more |
|---|---|---|
| **Harness** | gateways (terminal, dashboard, voice, Telegram, Discord, WhatsApp) and tools around one loop | [architecture](docs/architecture.md) |
| **Loop** | one readable file: reason, act, repeat, with two ways to stop | [the tour](docs/tour.md#the-loop) |
| **Memory** | semantic, episodic and procedural (skills); a gate decides *whether* to remember, consolidation decides *what* to keep | [the tour](docs/tour.md#the-retrieval-gate) |
| **Eval / LLM-Ops** | deterministic tests and LLM-as-judge side by side, a release gate, a trace for every turn | [evals](docs/evals.md) |

**How is this different from ChatGPT or Claude Desktop?** Those are products you *use*. This is a
codebase you *own*: the loop, the memory schema, the gate and the eval harness are all yours to
read and change. Versus the big open-source assistants (OpenClaw, Hermes)? Same architecture,
1/100th the code.

## Docs

| Read | For |
|---|---|
| [Getting started](docs/getting-started.md) | building the binary, the first run, connecting Waku Memory |
| [The Nim port](nim/README.md) | the build switches, what is ported, what is not |
| [The tour](docs/tour.md) | the dashboard, things to try, the loop, graph workflows, skills |
| [Architecture](docs/architecture.md) | every box on the whiteboard, and the file behind it |
| [Integrations](docs/integrations.md) | voice, Telegram, calendars, MCP servers, Waku Memory |
| [Commands](docs/commands.md) | every `waku` and `make` command |
| [Evals & tracing](docs/evals.md) | the two kinds of eval, the Docker tier, the release gate, traces and spend |
| [Roadmap](docs/roadmap.md) | what is live, what is still a skeleton, upgrade paths |
| [Whiteboards](docs/README.md#whiteboards) | the editable system-design charts from the videos |
| [lab/](lab/README.md) | Waku meets other agents and models: the video experiments |
| [AGENTS.md](AGENTS.md) · [CONTRIBUTING.md](CONTRIBUTING.md) | the rules, and how to send a PR |

## Community

Star the repo, join the [Discord](https://discord.gg/ebbdvSCXqu), and grab a
[good first issue](https://github.com/ShenSeanChen/waku-agent/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
— that link is the live list, so it's always current. Gateways, memory backends and
community skills are all shaped to be first PRs; the easiest needs no Python at all
(see [contributing a skill](CONTRIBUTING.md)).

**Comment on an issue before you start** and it gets assigned to you, so two people
never build the same thing.

## Also from me

- **[launch-mvp-stripe-nextjs-supabase](https://github.com/ShenSeanChen/launch-mvp-stripe-nextjs-supabase)** — NextJS + Supabase + Stripe, everything you need to ship a SaaS.
- **[AutoManus.io](https://automanus.io)** — my AI startup: a sales lead manager for made-to-order products. It embeds where conversations already happen (WhatsApp, email, web chat) to capture inbound, automate follow-ups and kill CRM busywork. Pre-seed backed by Character VC. ([AutoManus Discord](https://discord.gg/SxXATg9rSK))

Code is MIT — see [LICENSE](LICENSE) — **except `hosted/`, which is Elastic
License 2.0**: run it yourself, including commercially, but not as a service for
others. See [hosted/LICENSE](hosted/LICENSE). `hosted/` stays Python and stays
unchanged. `waku/`, the harness itself and everything PyPI ships, is MIT. The
Waku name, mark and design system belong to AutoManus Technologies, Inc. and are
not MIT — see [LICENSE-BRAND](LICENSE-BRAND). Built by [@ShenSeanChen](https://github.com/ShenSeanChen)
([YouTube](https://www.youtube.com/@SeanAIStories) · [X](https://x.com/ShenSeanChen)).
