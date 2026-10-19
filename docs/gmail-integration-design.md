# Gmail as a Waku capability

**Status:** proposal — nothing implemented. Needs a maintainer's yes before any
code (conventions §2: a new core tool is a Proposal).

**Related:** [providers-registry.md](providers-registry.md) (the precedent for
"capability as data"), [integrations.md](integrations.md),
[architecture.md](architecture.md).

## The problem

Waku can create a calendar event and draft a message, but it cannot read or
answer mail. Gmail is the one inbox most people actually use, so "check whether
Ana replied" and "answer that thread" are the two asks that make the assistant
worth opening in the morning.

Two things are missing today, and they are different things:

- **Configuration and status.** There is no `gmail` row in
  `waku/integrations.py`, so Connections shows nothing and `.env.example` has
  no block for it.
- **Capability.** There is no tool, so the agent cannot touch a mailbox at all.
  `read_apple_mail` reads Mail.app on macOS only; `send_message` always writes
  a draft and never sends (`waku/tools/messages.py:20`). Nothing in this repo
  has ever sent real mail.

## The shape

A Connections row is configuration and health. A tool is capability. Gmail
needs both, and the proposal keeps them separate so the row can ship without
the tools and vice versa.

### The three tools

| Tool | Arguments | Returns |
|---|---|---|
| `gmail_search` | `query` (Gmail search syntax), `limit` (default 10, max 25) | one line per hit: id, date, from, subject, snippet |
| `gmail_read` | `message_id` | headers plus the plain-text body, truncated at 8000 characters |
| `gmail_send` | `to`, `subject`, `body`, optional `thread_id`, `in_reply_to` | where it went: the outbox path, or the sent message id |

Errors are text, not exceptions: every handler returns a string, and
`Tool.execute` (`waku/tools/registry.py:78`) already wraps a raise into
`Error running <name>: ...`. A missing scope, a revoked token, a quota error or
a 404 must each say what happened in one line, so the model can report it
instead of retrying blindly.

Registration is opt-in, mirroring `WAKU_GOOGLE_CALENDAR` and `WAKU_APPLE_TOOLS`:
`build_registry` (`waku/tools/__init__.py`) adds the three tools only when
`settings.gmail` is true, which is `WAKU_GMAIL`. **This is the part that
answers AGENTS.md §3**: a tool costs prompt space on every call, so an off
default keeps the waist narrow and makes the feature a deliberate act.

### Sending is the risky half

`gmail_send` writes a draft into `~/.waku/outbox/` and answers
"Nothing was sent — review it there", exactly like `send_message`, unless
`WAKU_GMAIL_SEND=true` is set. Real delivery is a separate, visible switch
because it is the first irreversible outbound action in the product: an email
cannot be unsent, and a prompt injection that reaches `gmail_search` output has `gmail_send` one
tool call away.

The honest cost of this default: with the flag off, "send an email to Ana" does
not send an email. The tool's return string says so, and the row's help text
says so, which is the same bargain `send_message` already makes.

### Scopes and credentials

`gmail.readonly` + `gmail.send`, in a **separate** token file,
`~/.waku/gmail-token.json`, with its own consent through the existing loopback
door (`InstalledAppFlow.run_local_server`, the pattern in
`waku/tools/google_calendar.py:87`).

Two reasons for a separate file rather than widening `google-token.json`:

1. **Least surprise on revocation.** Revoking mail access from Google should
   not silently break the calendar, and vice versa.
2. **Least re-consent.** Widening an existing token's `scopes` list forces a
   fresh interactive grant for every current calendar user at once.

The `gcal` extra already carries `google-api-python-client`, `google-auth` and
`google-auth-oauthlib` (`pyproject.toml:59`), which cover the Gmail API. No new
dependency and no new extra, so AGENTS.md rule 3 holds; a machine without the
extra gets the existing honest install hint.

### Failure posture

- No `WAKU_GMAIL`: the tools are not registered at all, so nothing appears in a
  prompt and no failure is possible.
- Flag on, no usable token: the tools register, and every call answers one line
  naming `waku connect google` (the fix), rather than hiding itself. Hiding is
  worse: the model would answer "I cannot read mail" without the user learning
  that a single command fixes it.
- Flag on, token revoked or scope missing: same honest line, quoting the
  provider's reason.

No fail-open path exists here, and that is deliberate: a retrieval gate may pass
when it cannot decide, but a mail read must not answer from an empty mailbox as
if it were empty.

## The Connections row

```toml
[gmail]
key = "gmail", group = "Calendar & Productivity", name = "Gmail"
env = WAKU_GMAIL (BOOL), WAKU_GMAIL_SEND (BOOL), WAKU_GMAIL_QUERY_LIMIT (TEXT, default 10)
extra = "gcal", import_name = "googleapiclient"
setup_url = the Google Cloud console Gmail API page
reload = AGENT
enabled = bool(WAKU_GMAIL)
probe = a cheap profile call (getProfile) that reports the address or the reason
```

Productivity is not a category of its own: the group string is
`"Calendar & Productivity"`, shared with `google_calendar`, `apple_calendar` and
`apple_tools` (`waku/integrations.py:182-196`). Gmail sits beside them.

## Evaluation

One deterministic eval file, `evals/deterministic/test_gmail.py`, offline, no
key, no network, following `test_google_calendar.py`'s injection pattern (fake
`google.*` modules through `monkeypatch.setitem(sys.modules, ...)`).

Each test pins one rule and its observable effect: opt-in default (no flag, no
tools registered), draft-by-default returns the outbox path and leaves the API
untouched, the send flag produces exactly one `send` call with the expected
payload, a 403 maps to a one-line text answer, `gmail_search` never returns more
than `limit`, and a missing token yields the `connect` hint instead of an
exception.

## Nim parity

Parity here means what parity already means for Google Calendar in this port:
**the row plus the sign-in scope**, not a tool. `nim/src/registry.nim` registers
no Google tool today (`nim/src/calendar.nim:1-8` says the Apple/Google sync
branches are out of phase 2), so building `nim/src/gmail.nim` with its own
credential and HTTP seams would make Gmail the only Google capability in the
port, and would put a second, differently-shaped auth path next to
`connect.nim`'s.

So this proposal adds to the port: the `gmail` row in
`nim/src/integrations.nim`, and the Gmail scope in `nim/src/connect.nim`'s
`googleScope`/token record so `waku connect google` can grant it. The Nim binary
therefore reports Gmail's status and can authorise it, while the tools stay in
Python until the port's tool layer grows Google support on purpose. That
asymmetry is written down in `docs/status.md` rather than left for a reader to
discover.

## Hosted

Untouched. `hosted/core/policy.py`'s `ALLOWED_CONNECTIONS` refuses any key other
than `notion`, `tavily` and `treg`, so a hosted tenant cannot save a Gmail row.
That is the correct default for this proposal: real mail sending through a
shared tenant VM is a product and safety question of its own, not a row. Adding
a tool touches no route, so `test_route_contract.py` needs no entry.

## Risks

| Risk | Why it is one | Mitigation |
|---|---|---|
| Real outbound mail | Cannot be unsent; prompt injection reaches it | Draft by default, `WAKU_GMAIL_SEND` must be set, one tool call per message |
| Mailbox data leaves the machine into a prompt | Subject lines and bodies are personal data | Only what a tool call asks for; truncation; no bulk fetch; no logging of bodies in traces |
| OAuth scope creep | A token that can send and read is high privilege | Separate token file, two scopes only, no `gmail.modify` |
| Prompt cost on every turn | Three tool schemas in every call | Opt-in flag, off by default, terse descriptions, tags for task filtering |
| Port drift | A Python-only Google capability | Stated in `docs/status.md` with the reason |

## Alternatives rejected

- **MCP server instead of core tools.** No permanent prompt cost and no proposal
  tier, but it makes the out-of-the-box experience depend on a third party's
  server and puts the send guard outside our code. Worth offering *in addition*
  later, not instead.
- **Always draft, never send.** Safest, but it answers "send an email" with
  something that is not an email, forever, with no switch to fix it.
- **Send by default.** A single misclassified instruction becomes a real email
  from the user's address.
- **Shared `google-token.json`.** One consent for calendar and mail means
  revoking one touches the other, and it forces re-consent on every existing
  calendar user.
- **A full Gmail tool in the Nim port now.** Consistent only with a Google tool
  layer the port does not have.

## Rollout

Four reviewable slices, each with its eval and docs:

1. The row, the Settings flags, `.env.example`, the Nim row. No tool.
2. `gmail_search` + `gmail_read`, read-only scope, eval.
3. `gmail_send` with the draft default, the flag, eval.
4. `connect` support for the Gmail scope in both implementations, `status.md`
   and `architecture.md` updated.

## Open decisions (defaults marked; confirming or flipping them is the approval)

- **D1 — sending**: draft by default, real send behind `WAKU_GMAIL_SEND`
  (default). Alternatives: always draft; send by default.
- **D2 — credentials**: separate `gmail-token.json` with
  `gmail.readonly` + `gmail.send` (default). Alternative: widen the existing
  Google token.
- **D3 — Nim parity**: row plus sign-in scope (default). Alternative: a full
  `nim/src/gmail.nim` tool.
- **D4 — hosted**: allowlist untouched, Gmail refused in hosted (default).
  Alternative: add `gmail` to `ALLOWED_CONNECTIONS`.
