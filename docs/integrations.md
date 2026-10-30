# Connect it to your life

Everything here is opt-in. None of it changes the loop — a gateway moves text
in and out, an integration is a tool the agent may call. The four pillars work
with none of this installed.

Waku's Nim binary carries these integrations as commands of its own (`connect`,
`mcp`, `voice`, `telegram`, `skill`), so it needs no Python extra to use them. A
`pip install -e '.[extra]'` line below installs the same capability for the
frozen Python half in `waku/`, which is what `make run`, `make voice`,
`make telegram` and `make dashboard` drive. Each section names the half its
command belongs to.

Moved out of the README, which had grown to 569 lines for a project whose
promise is that you can read it in an afternoon. Nothing was rewritten.

## Talk to it

```bash
./nim/waku voice        # the binary: hands-free, always listening for "waku waku"
```

**Hands-free by default.** Both halves listen for the wake word **"waku waku"**, and a
Whisper model scans the mic — `faster-whisper` inside the frozen half, an external
transcriber named by `WAKU_STT_COMMAND` in the binary. When it hears the phrase, the big model
takes over for your command and speaks the reply. Change or disable it:

```bash
WAKU_WAKE_WORD="hey waku"  ./nim/waku voice     # any phrase, no training
WAKU_WAKE_WORD=""          ./nim/waku voice     # push-to-talk instead (Enter, speak, Enter)
```

The matcher is ~15 transparent lines with a deterministic eval; it accepts cross-script
variants (`"waku waku,わくわく"`). A trained openWakeWord model is the efficient v2 upgrade.

The binary ships no mic, no ears and no mouth of its own. It records, transcribes and speaks
through three external commands, `WAKU_MIC_COMMAND`, `WAKU_STT_COMMAND` and
`WAKU_TTS_COMMAND`, and it names the one that is missing. [../nim/README.md](../nim/README.md)
documents the three.

**The frozen half gives you a beautiful voice.** It needs
`uv pip install -e '.[voice]'` for the mic and the ears, and it uses macOS `say` out of the
box — Waku auto-picks the nicest voice you have, preferring a downloaded Premium/Enhanced one
(System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice) over the robotic built-ins.
For the real neural upgrade, install [Kokoro](https://github.com/hexgrad/kokoro) — a fully
local, offline British-butler voice that the frozen half picks up automatically, with no env
var needed:

```bash
uv pip install '.[voice-neural]'          # neural Kokoro (bm_george); pulls torch (~2GB)
make voice                                # the frozen half talks
```

The frozen half overrides either engine with `WAKU_VOICE` (a `say` voice name, or a Kokoro
voice like `bf_emma`).

## Phone to laptop

```bash
# message @BotFather, /newbot, put the token in .env, then:
./nim/waku telegram      # the binary: no extra to install
make telegram            # the frozen half: needs pip install -e '.[telegram]'
```

Text your bot from anywhere and your laptop runs the turn — long-polling, so no
public URL or webhook. Set `TELEGRAM_ALLOWED_USER` to lock it to just you.

## Brief me on my week (Apple Calendar + Mail)

```bash
WAKU_APPLE_TOOLS=1 ./nim/waku brief   # macOS; grant the permission prompts once
make brief                            # the frozen half does the same
```

Waku reads your **real** Calendar.app (including events invited by email) and
recent Apple Mail, cross-references your memory, and writes a focus-first briefing
with clickable `message://` links. Cron it for a morning greeting:

```
30 7 * * *  cd ~/waku-agent && WAKU_APPLE_TOOLS=1 ./nim/waku brief
```

It runs through the normal harness, so it animates on the dashboard like any turn.

## Mirror created events to Google Calendar

**This is the frozen half's section.** The Nim binary reads the signed-in
primary calendar and keeps every new event in its own local database; it does
not write to Google Calendar. The local SQLite database and `calendar.ics` stay
authoritative. To also write `create_event` results to Google Calendar, install
the opt-in extra and configure
[Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc):

```bash
pip install -e '.[gcal]'
# Keep the downloaded client file OUTSIDE the repo — it is only an input to
# gcloud, which stores the resulting credentials in ~/.config/gcloud/.
gcloud auth application-default login \
  --client-id-file=~/.config/waku/gcal-client.json \
  --scopes=https://www.googleapis.com/auth/calendar.events
WAKU_GOOGLE_CALENDAR=1 waku
```

Nothing secret ever needs to live in the repo: the client file is read once by
`gcloud`, and the credentials it mints land in `~/.config/gcloud/`. (`.gitignore`
also blocks `credentials.json` and `*token*.json` as a second line of defence.)

The target defaults to the signed-in user's `primary` calendar; set
`WAKU_GOOGLE_CALENDAR_ID` for another calendar. `list_events` reads every
connected source and says which is which: the signed-in `primary` calendar
when `~/.waku/google-token.json` exists, plus waku's own local database, so
"no events found" is never an answer about a calendar nobody opened. Google
failures never roll back the local event, and attendee notifications are
suppressed (`sendUpdates=none`).

## Read and answer mail (Gmail)

Mail is its own capability behind its own switch, and the Nim binary needs no
client library for it:

```bash
./nim/waku connect google    # grants mail too, in its own token file
WAKU_GMAIL=1 ./nim/waku      # gmail_search and gmail_read join the prompt
```

The frozen half reuses the libraries the calendar already pulled in, after
`pip install -e '.[gcal]'`, and runs the same two commands.

`./nim/waku connect google` asks for mail access in a second, separate approval and
caches `~/.waku/gmail-token.json` with the `gmail.readonly` and `gmail.send`
scopes. Revoking mail therefore leaves the calendar working, and vice versa.
Like the calendar's sign-in it needs your own Desktop OAuth client at
`~/.waku/credentials.json` until a project-owned one ships.

`gmail_send` writes a draft into `~/.waku/outbox/` and answers "Nothing was
sent — review it there", exactly like `send_message`. Real delivery is a
second, separate switch, because an email cannot be unsent:

```bash
WAKU_GMAIL=1 WAKU_GMAIL_SEND=1 ./nim/waku
```

With `WAKU_GMAIL` off the three tools are not registered at all: no prompt
space and no failure possible. With it on and no usable token, every call
answers with the command that fixes it instead of reporting an empty mailbox.

The Nim port carries the same three tools: `WAKU_GMAIL=1` in `nim/` too,
reading the same `~/.waku/gmail-token.json` and refreshing it without a browser.
`gmail_send` registers with them and delivers only under `WAKU_GMAIL_SEND`,
drafting into `~/.waku/outbox/` otherwise. The port reads the calendar the same
way: `list_events` asks the signed-in `primary` Google calendar (its own
`~/.waku/google-token.json`) and labels each source. Creating and syncing
events is not ported, so the port keeps them in its local database only. The
port's live calls need a TLS build — `nimble buildTls` writes `./waku_tls`, and
the default `waku` binary cannot dial `https://` at all. Both capabilities share
one refresh path (`nim/src/google_auth.nim`): the token endpoint is the one
Google call that takes a form body, and sending it as JSON made every refresh
fail, so an expired token read as "not connected" while a valid refresh token
sat on disk. See [status.md](status.md).

## Share one memory with your other agents (Waku Memory)

Waku's own memory is local. Each fact is also written to `~/.waku/memory/`,
one file per fact, the layout the Waku Memory importer already uploads for
Claude Code; episodes, `MEMORY.md` and `state.db` are never written there.
[Waku Memory](https://waku.one) is a hosted memory that several agents share
over MCP: save something in one agent, and recall it in another.

```bash
./nim/waku connect waku-memory     # or /connect waku-memory in the dashboard chat
```

The frozen half needs `pip install -e '.[mcp]'` first, and then runs the same
command.

That adds Waku Memory to `~/.waku/mcp.json`, next to any servers already there,
and opens your browser once to sign in. Restart Waku and its tools appear as
`waku_memory_*`; `./nim/waku mcp` shows which account you are signed in as. A config
still pointing at Waku Memory's old address is moved to the current one.
From then on, each fact consolidation keeps is also sent to Waku Memory
(spec 006). Facts kept before you connected stay in `~/.waku/memory/` for the
importer.

The same memory, in your other agents:

| Agent | How it connects |
|---|---|
| Claude Code, Codex, Hermes | the steps on [waku.one/docs](https://www.waku.one/docs) |
| Grok Bot | Settings → Plugins → custom connector: URL `https://api.waku.one/mcp`, header `Authorization: Bearer <key>`, with a key from waku.one → Account → Keys |
| Muse Code, or any MCP client | a remote (streamable HTTP) server at `https://api.waku.one/mcp` in its MCP settings |

Grok Bot and Muse Code are not yet tested by us. Grok Bot runs in the cloud,
and its connector form takes a URL and a header rather than a browser sign-in,
which is why it needs a key. Keep that key in Grok Bot's own form, never in a
file in this repo.

### Carry your skills too

```bash
./nim/waku skill export --to claude,codex    # ~/.claude/skills/ and ~/.codex/skills/
./nim/waku skill export --project            # ./.claude/skills/, which Muse Code also reads
```

Each skill folder is copied as it is. A copy you changed in the other agent is
kept unless you pass `--force`. Skills that call Waku's own tools (a calendar
skill calls `create_event`) arrive as instructions without those tools behind
them. Saving skills into Waku Memory, so a cloud agent like Grok Bot can recall
them, waits until Waku Memory has a place for skills.

## Live data for research (treg)

[treg](https://treg.to) is an MCP server with thousands of endpoints behind
it: search results, keyword data, companies and people, social profiles, ad
libraries, web pages. With it connected, a question like "research the
competitors of mem0" is answered from live sources rather than the model's
memory.

```bash
./nim/waku connect treg            # or /connect treg in the dashboard chat
```

The frozen half needs `pip install -e '.[mcp]'` first, and then runs the same
command.

That adds `{"name": "treg", "url": "https://treg.to/mcp/", "oauth": true}` to
`~/.waku/mcp.json`, next to any servers already there, and opens treg's own
sign-in page once. Restart Waku and its tools appear as `treg_*`. Running it
again adds nothing; a server you named `treg` that points somewhere else is
left alone, and the command says so. On your own machine treg is your own
account and bills you directly. The **Connections** page shows treg as
connected, not signed in or not added, with a Connect button that runs the
same `/connect treg` in the chat.

A hosted Waku Agent on waku.one needs none of this: its container reaches treg
through the platform's relay, and the calls are charged to its credits
([hosted/README.md](../hosted/README.md)). To use your own treg account there
instead, click Configure on the treg card and paste an org-scoped treg key:
calls then go straight to `https://treg.to/mcp/` and treg bills your account,
not your credits. Clear the key to go back to the relay.

`TREG_API_KEY` works the same way in the frozen half: when it is set in `.env`,
Waku reaches the `treg` server in `mcp.json` at treg.to with that key instead
of the sign-in, and the key is sent only to treg.

## Let Jev decide which memories earn a slot

```bash
TYPESAFE_API_KEY=...      # typesafe.ai
WAKU_SLOT_GATE=jev
```

In the frozen half, with both set, Jev scores every retrieved memory against
your message and only the ones that change the answer go into the prompt; it
also scores facts before consolidation stores them. One call per turn, about a
quarter of a second. Leave either unset, or let TypeSafe be unreachable, and
Waku behaves as before. The TypeSafe card on Connections sets both.

## Connect MCP servers

Create `~/.waku/mcp.json` and any Model Context Protocol server's tools appear to
the agent, namespaced `<server>_<tool>` (and in the dashboard's Tools ▸ MCP tab).
The Nim binary reads the file itself and needs no client library; the frozen half
reads it once `pip install -e '.[mcp]'` has installed one. A server can declare
`tasks` and `when` so its tools reach the model only on matching
turns; a server without `tasks` appears on every turn as before:

```json
{"servers": [{"name": "fs", "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]}]}
```

**Node-free demo** — a tiny self-contained Python MCP server ships in the repo:

```bash
mkdir -p .waku && cp examples/mcp.demo.json .waku/mcp.json   # points at evals/fixtures/mcp_demo_server.py
WAKU_HOME=.waku ./nim/waku dashboard                         # demo_word_count / demo_reverse_text appear in Tools
```

Same pattern scales to any server, yours or a vendor's — no changes to Waku's code.

### Remote servers (Streamable HTTP)

A server that is already running somewhere else is named by `url` instead of
`command`. This is the MCP spec's transport for remote servers; the older
HTTP+SSE transport is deprecated and is not supported.

```json
{"servers": [{"name": "waku_memory",
              "url": "https://your-host/mcp",
              "auth_env": "WAKU_MEMORY_API_KEY"}]}
```

`auth_env` names an **environment variable**; its value is sent as
`Authorization: Bearer <value>`. The credential never goes in `mcp.json` —
that file gets pasted into bug reports, and a bearer token in one is a leaked
credential. If the variable is not exported, Waku says so by name rather than
connecting anonymously and letting the server's 401 look like an outage.

A remote server that restarts forgets every session it had, and answers the
next call with HTTP 404 "Session not found". Waku then opens a new session and
sends that call once more, as the MCP spec asks of a client. Calls that find
the session gone at the same moment share one new session.

### Signing in instead of holding a key

A server that speaks MCP's authorization spec needs no key at all. Say so, and
Waku opens your browser on first use:

```json
{"servers": [{"name": "waku_memory",
              "url": "https://your-host/mcp",
              "oauth": true}]}
```

Nothing is issued out of band and nothing is pasted anywhere. Waku registers
itself with the server, catches the redirect on `127.0.0.1:41765`, and keeps
the result in `~/.waku/mcp-auth/<server>.json`, written `0600` — one file per
server, so a corrupt one costs a single connection rather than all of them.
Delete that file to sign out.

`oauth` and `auth_env` are two answers to one question, so naming both is
refused rather than resolved by precedence.

### Which account am I signed in as?

```bash
./nim/waku mcp                      # every server, and the account each knows you as
./nim/waku mcp login waku_memory    # sign in again — as someone else, or after expiry
./nim/waku mcp logout waku_memory   # forget the token
```

Two agents pointed at the same server as two different people look exactly
like a broken server: you write something in one and the other cannot find it.
`./nim/waku mcp` prints the email, so the mismatch is visible in one line instead of
inferred from missing memories.

`login` signs out first on purpose. Without that the stored token is still
valid, the server never asks who you are, and "sign in as someone else"
silently keeps the account you were trying to leave.

Headless or over SSH there is no browser to open: the authorization URL is
printed, and you can finish the sign-in from any machine that has one.

Try it against the demo server, no remote host required:

```bash
python evals/fixtures/mcp_demo_server.py --http --port 8931
# .waku/mcp.json → {"servers": [{"name": "demo", "url": "http://127.0.0.1:8931/mcp"}]}
```

The frozen half requires `mcp>=2.1` (`pip install -e '.[mcp]'`): its 1.x SDK
spelled this transport differently, and the remote branch does not work on it.
The Nim binary speaks this transport itself.

