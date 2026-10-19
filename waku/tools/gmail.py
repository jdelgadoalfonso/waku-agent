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
from pathlib import Path

from waku.tools.registry import Tool

GMAIL_READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
DEFAULT_SCOPES = [GMAIL_READONLY_SCOPE]
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


def make_tools(home: Path) -> list[Tool]:
    """gmail_search and gmail_read, registered only when WAKU_GMAIL is on."""

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
    ]
