"""Gmail — search and read real mail, with a sign-in the user can revoke.

Read-only is the half that ships by default, for the same reason the calendar
ships read-only: the blast radius of a stolen token is a copy of your inbox,
not a message sent in your name. Sending is a second, separate switch
(WAKU_GMAIL_SEND) and lives in its own commit, because an email cannot be
unsent.

Two things this module will not do:

  * read the calendar's token (`google-token.json`). Gmail has its own file, so
    revoking mail access leaves the calendar alone, and signing out of one does
    not silently break the other.
  * answer from an empty mailbox when nothing could be read. A missing token or
    a missing dependency returns the sentence that fixes it — an agent that says
    "no messages" because it never got in is worse than one that says nothing.

Everything here is best-effort: a refused consent, an expired token, a quota
error all come back as text the model can report. A mailbox hiccup must not
take down a chat turn.
"""

from __future__ import annotations

import base64
from datetime import UTC, datetime
from pathlib import Path

from waku.tools.registry import Tool

GMAIL_READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
GMAIL_SEND_SCOPE = "https://www.googleapis.com/auth/gmail.send"
# Reading asks for the narrow scope; the one-time consent covers sending too, so
# flipping WAKU_GMAIL_SEND later never needs a second approval window.
DEFAULT_SCOPES = [GMAIL_READONLY_SCOPE]
CONSENT_SCOPES = [GMAIL_READONLY_SCOPE, GMAIL_SEND_SCOPE]
# Both numbers exist because the model can pass any `limit` it likes: one caps
# what we ask Gmail for, the other what a single reply may dump into a prompt.
DEFAULT_LIMIT = 10
MAX_LIMIT = 20

_INSTALL_HINT = (
    "Gmail support is not installed — run: pip install -e '.[gcal]', then "
    "`waku connect google` to sign in."
)
_SETUP_HINT = (
    "Gmail is not connected yet. Type `/connect google` in the dashboard chat, or "
    "run `waku connect google` in a terminal — either opens your browser to sign in."
)


def _token_path(home: Path) -> Path:
    return home / "gmail-token.json"


def connect(home: Path) -> str:
    """Open the browser, get consent for mail, cache the token — the ONE place
    a Gmail window may appear, called from the CLI or the dashboard, never
    mid-turn. Same loopback door and same OAuth client as the calendar, but its
    own file: revoking mail leaves the calendar working, and vice versa."""
    try:
        from google_auth_oauthlib.flow import InstalledAppFlow
    except ImportError:
        return _INSTALL_HINT

    from waku.tools.google_calendar import BUNDLED_CLIENT_CONFIG

    own = home / "credentials.json"
    try:
        if own.exists():
            flow = InstalledAppFlow.from_client_secrets_file(
                str(own), scopes=CONSENT_SCOPES
            )
            source = "credentials.json override"
        else:
            bundled = BUNDLED_CLIENT_CONFIG.get("installed", {})
            if not bundled.get("client_id") or not bundled.get("client_secret"):
                return (
                    "Gmail's bundled OAuth client is not configured yet. Add "
                    f"{home / 'credentials.json'} to use your own Desktop OAuth client."
                )
            flow = InstalledAppFlow.from_client_config(
                BUNDLED_CLIENT_CONFIG, scopes=CONSENT_SCOPES
            )
            source = "bundled OAuth client"
        # port=0 = any free local port; the redirect lands back on this machine.
        creds = flow.run_local_server(port=0)
    except Exception as exc:
        return f"Gmail sign-in failed or was cancelled ({type(exc).__name__}). Nothing was saved."

    path = _token_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(creds.to_json(), encoding="utf-8")
    return (
        f"Gmail connected via {source}: read access, plus send access that stays "
        f"unused until WAKU_GMAIL_SEND is on. Token cached at {path}."
    )


def _load_credentials(home: Path, scopes: list[str]):
    """Cached token → refresh if stale → None. Never launches a browser: that
    only happens in connect(), so a chat turn cannot block on a consent screen
    the user cannot see. The token is Gmail's own file, not the calendar's."""
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
    except ImportError:
        return None

    path = _token_path(home)
    if not path.exists():
        return None
    try:
        creds = Credentials.from_authorized_user_file(str(path), scopes=scopes)
    except Exception:
        return None
    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
            path.write_text(creds.to_json(), encoding="utf-8")
        except Exception:
            return None
    return creds if (creds and creds.valid) else None


def _service(home: Path):
    """(service, None) or (None, the sentence explaining what to do).

    Order matters: dependency first, then token, and only then an API client.
    A machine that was never asked for Gmail therefore makes no network call at
    all, which is also what lets the tests prove the gate runs first.
    """
    try:
        from googleapiclient.discovery import build
    except ImportError:
        return None, _INSTALL_HINT

    creds = _load_credentials(home, DEFAULT_SCOPES)
    if creds is None:
        return None, _SETUP_HINT
    return build("gmail", "v1", credentials=creds, cache_discovery=False), None


def _header(payload: dict, name: str) -> str:
    for field in payload.get("headers", []) or []:
        if str(field.get("name", "")).lower() == name.lower():
            return str(field.get("value", ""))
    return ""


def _body_text(payload: dict) -> str:
    """The first text/plain part, depth-first. Gmail nests parts
    (multipart/alternative inside multipart/mixed), so a top-level read finds
    nothing on a real message."""
    if payload.get("mimeType") == "text/plain":
        data = (payload.get("body") or {}).get("data")
        if data:
            padded = data + "=" * (-len(data) % 4)
            return base64.urlsafe_b64decode(padded).decode("utf-8", "replace")
    for part in payload.get("parts", []) or []:
        text = _body_text(part)
        if text:
            return text
    return ""


def _search(service, query: str, limit: int) -> str:
    cap = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    listing = service.users().messages().list(
        userId="me", q=query, maxResults=cap
    ).execute()
    hits = (listing.get("messages") or [])[:cap]
    if not hits:
        return f"No Gmail messages matched '{query}'." if query else "No Gmail messages found."

    lines = []
    for hit in hits:
        mid = hit.get("id", "")
        # Metadata only: the list call gives ids, and the model needs enough to
        # choose one without pulling every full body into the prompt.
        msg = service.users().messages().get(
            id=mid, format="metadata", metadataHeaders=["From", "Subject", "Date"]
        ).execute()
        payload = msg.get("payload") or {}
        lines.append(
            f"{mid} | {_header(payload, 'From')} | {_header(payload, 'Subject')} "
            f"| {_header(payload, 'Date')}"
        )
    return "\n".join(lines)


def _read(service, message_id: str) -> str:
    msg = service.users().messages().get(id=message_id, format="full").execute()
    payload = msg.get("payload") or {}
    body = _body_text(payload) or msg.get("snippet", "")
    return (
        f"From: {_header(payload, 'From')}\n"
        f"Date: {_header(payload, 'Date')}\n"
        f"Subject: {_header(payload, 'Subject')}\n\n{body}"
    )


def _draft(
    home: Path, to: str, subject: str, body: str, thread_id: str, in_reply_to: str
) -> str:
    """The send_message bargain: a file a person can read, edit and send
    themselves. Deliberately needs no token — nothing leaves the machine, so
    asking for credentials here would only hide the draft behind a sign-in."""
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
    safe_to = "".join(c if c.isalnum() else "-" for c in to)[:40]
    path = home / "outbox" / f"{stamp}-{safe_to}.txt"
    # A second draft to the same person must never overwrite the first: the
    # outbox holds the user's own words, not a cache we may drop.
    n = 1
    while path.exists():
        n += 1
        path = home / "outbox" / f"{stamp}-{safe_to}-{n}.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    headers = [f"To: {to}", f"Subject: {subject}"]
    if thread_id:
        headers.append(f"X-Waku-Thread: {thread_id}")
    if in_reply_to:
        headers.append(f"In-Reply-To: {in_reply_to}")
    path.write_text("\n".join(headers) + f"\n\n{body}\n", encoding="utf-8")
    return (
        f"Draft to {to} placed in outbox ({path.name}). Nothing was sent — review it there."
    )


def _raw_message(to: str, subject: str, body: str, in_reply_to: str) -> str:
    """RFC 822 as Gmail's API wants it: base64url, no line wrapping of our own.
    Only text/plain — an HTML body this tool never wrote would be a guess."""
    headers = [
        f"To: {to}",
        f"Subject: {subject}",
        "MIME-Version: 1.0",
        'Content-Type: text/plain; charset="utf-8"',
    ]
    if in_reply_to:
        headers.append(f"In-Reply-To: {in_reply_to}")
    message = "\n".join(headers) + "\n\n" + body
    return base64.urlsafe_b64encode(message.encode("utf-8")).decode()


def make_tools(home: Path, send: bool = False) -> list[Tool]:
    """gmail_search, gmail_read and gmail_send, registered only when WAKU_GMAIL
    is on. `send` is the second switch (WAKU_GMAIL_SEND): with it off, sending
    means drafting locally."""

    def gmail_search(query: str = "", limit: int = DEFAULT_LIMIT) -> str:
        service, problem = _service(home)
        if service is None:
            return problem
        try:
            return _search(service, query, limit)
        except Exception as exc:
            return f"Gmail search unavailable ({type(exc).__name__}: {str(exc)[:120]})"

    def gmail_read(message_id: str = "") -> str:
        if not message_id:
            return "gmail_read needs a message_id — call gmail_search first to get one."
        service, problem = _service(home)
        if service is None:
            return problem
        try:
            return _read(service, message_id)
        except Exception as exc:
            return f"Gmail could not open {message_id} ({type(exc).__name__}: {str(exc)[:120]})"

    def gmail_send(
        to: str = "",
        subject: str = "",
        body: str = "",
        thread_id: str = "",
        in_reply_to: str = "",
    ) -> str:
        if not to:
            return "gmail_send needs a recipient address — call it again with one."
        # Drafting first is not a fallback, it is the default: the switch has to
        # be turned on deliberately before this repo can send mail in your name.
        if not send:
            return _draft(home, to, subject, body, thread_id, in_reply_to)
        service, problem = _service(home)
        if service is None:
            return problem
        try:
            payload: dict = {"raw": _raw_message(to, subject, body, in_reply_to)}
            if thread_id:
                payload["threadId"] = thread_id
            sent = service.users().messages().send(userId="me", body=payload).execute()
        except Exception as exc:
            return f"Gmail could not send to {to} ({type(exc).__name__}: {str(exc)[:120]})"
        return f"Sent to {to} (message {sent.get('id', '?')})."

    return [
        Tool(
            name="gmail_search",
            description=(
                "Search the user's Gmail and list the matching messages as "
                "id | from | subject | date, newest first. Use Gmail's own query "
                "syntax (from:, subject:, newer_than:7d). Call gmail_read with an "
                "id to open one."
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Gmail search query, e.g. 'from:ana newer_than:7d'",
                    },
                    "limit": {
                        "type": "integer",
                        "description": f"How many hits to list (default {DEFAULT_LIMIT}, max {MAX_LIMIT})",
                    },
                },
                "required": ["query"],
            },
            fn=gmail_search,
        ),
        Tool(
            name="gmail_read",
            description=(
                "Open one Gmail message by id and return its sender, date, subject "
                "and body. Use after gmail_search when the user asks what a message says."
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "message_id": {
                        "type": "string",
                        "description": "The id from gmail_search",
                    },
                },
                "required": ["message_id"],
            },
            fn=gmail_read,
        ),
        Tool(
            name="gmail_send",
            description=(
                "Write an email in the user's name. By default it is placed in the "
                "local outbox as a draft and NOTHING IS SENT — say so plainly and let "
                "the user review and send it. Only when WAKU_GMAIL_SEND is on does it "
                "deliver, and then it returns the sent message id. Pass thread_id and "
                "in_reply_to to answer an existing thread instead of starting one."
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": "Recipient address"},
                    "subject": {"type": "string", "description": "Subject line"},
                    "body": {"type": "string", "description": "Plain-text body"},
                    "thread_id": {
                        "type": "string",
                        "description": "Optional: the thread to answer (from gmail_read)",
                    },
                    "in_reply_to": {
                        "type": "string",
                        "description": "Optional: the Message-ID being answered",
                    },
                },
                "required": ["to", "body"],
            },
            fn=gmail_send,
        ),
    ]
