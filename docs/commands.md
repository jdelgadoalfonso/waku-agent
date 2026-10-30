# Commands

Waku ships as one Nim binary, `nim/waku`, built with `nimble build` or
`make nim-build`. The commands in the first table are that binary's. The `make`
targets in the second table either build and test that binary (the `nim-*`
targets) or run the frozen Python half in `waku/`.

From the repo root, write `./nim/waku <command>`; from inside `nim/`, write
`./waku <command>`.

## waku

| Command | Does |
|---|---|
| `waku` | chat in the terminal |
| `waku dashboard` | the live cockpit at localhost:7777 (+ Telegram if `TELEGRAM_BOT_TOKEN` is set) |
| `waku voice` | talk to it — the "waku waku" wake word, or push-to-talk |
| `waku telegram` | message it from your phone (needs `TELEGRAM_BOT_TOKEN`) |
| `waku discord` | answer in a Discord server (needs `DISCORD_BOT_TOKEN`) |
| `waku whatsapp` | answer WhatsApp messages (needs `WHATSAPP_TOKEN` and a public URL) |
| `waku brief` | a morning briefing from calendar + mail + memory, run as a loop |
| `waku gather` | the same job as a graph: four sources fetched together, then one digest |
| `waku evals turns` | grade your own traced turns with the five turn checks and list the failing ones (`--window today`, `7d` or `all`) |
| `waku connections` | every integration and its health, including Waku Memory |
| `waku connect google` | sign in to Google Calendar (opens your browser) |
| `waku connect waku-memory` | connect Waku Memory, the memory shared with your other agents (opens your browser) |
| `waku mcp` | MCP servers, and which account each one knows you as |
| `waku mcp login <name>` | sign in again — as someone else, or after expiry |
| `waku mcp logout <name>` | forget a server's token |
| `waku skill install <url>` | install a community skill from a GitHub or Gist link |
| `waku skill export --to claude,codex` | copy Waku's skills to Claude Code and Codex (`--project` for `./.claude/skills`, `--force` to replace) |

In the dashboard chat, `/connect google` and `/connect waku-memory` do the same
as their `waku connect` commands, and `/help` lists the graph workflows.

## make

| Command | Does |
|---|---|
| `make nim-build` | the one Nim binary, `nim/waku`; the dashboard's files embed at compile time |
| `make nim-test` | the port's offline suite (every `nim/tests/test_*.nim`, no API key) |
| `make nim-build-tls` · `make nim-test-tls` | the same two with live TLS (needs the OpenSSL headers) |
| `make run` | chat with Waku in the terminal |
| `make dashboard` | the dashboard at localhost:7777 (restart it after pulling backend changes) |
| `make voice` | push-to-talk, or always-on with `WAKU_WAKE_WORD` |
| `make telegram` · `make discord` · `make whatsapp` | the messaging gateways |
| `make brief` · `make gather` | the morning briefing, as a loop or as a graph |
| `make eval` | deterministic evals (0/1, no judge involved) |
| `make eval-judge` | LLM-as-judge evals (scored %, needs an API key) |
| `make gate` | the release gate: deterministic must pass, judge must clear its threshold |
| `make lint` | ruff over the code and the evals |
| `make trace` | trace waterfalls in Phoenix at localhost:6006 |
| `make shootout RUNS="…"` | the same tasks on different models, e.g. `RUNS="kimi:kimi-k3 anthropic:claude-opus-4-8"` |
| `make shootout-coding RUNS="…"` | a coding round through pi, scored by tests |

`make` with no argument runs `make run`. Tests live in `evals/`, not `tests/`,
and the port's suites live in `nim/tests/`. [evals.md](evals.md) explains the two
kinds.
