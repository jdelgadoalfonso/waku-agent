"""Deterministic coverage for Gmail: the Connections row and its two switches.

Offline: no network, no key, no mailbox. The rules pinned here are the ones a
mistake would make expensive — that reaching a person's inbox is opt-in, and
that real delivery is a second switch rather than the same one (an email cannot
be unsent).
"""

from __future__ import annotations

import base64
import sys
from datetime import UTC, datetime
from types import ModuleType

import pytest

from waku import integrations
from waku.config import Settings, load_settings
from waku.db import connect
from waku.tools import build_registry, gmail


def _isolate(monkeypatch, tmp_path):
    monkeypatch.setenv("WAKU_HOME", str(tmp_path))
    monkeypatch.chdir(tmp_path)
    integrations._HEALTH = None
    integrations._reset_import_cache()


def _row():
    return next(i for i in integrations.INTEGRATIONS if i.key == "gmail")


def test_gmail_sits_in_calendar_and_productivity_next_to_google_calendar():
    """The group string is shared with the calendar rows; 'productivity' on its
    own is not a group this registry has."""
    keys = [i.key for i in integrations.INTEGRATIONS]
    assert _row().group == "Calendar & Productivity"
    assert keys.index("gmail") == keys.index("google_calendar") + 1


def test_enabling_gmail_is_opt_in(monkeypatch, tmp_path):
    """Both directions in one test, so an inverted flag cannot pass: an
    unconfigured machine must not reach a mailbox, and WAKU_GMAIL=1 must."""
    _isolate(monkeypatch, tmp_path)
    monkeypatch.delenv("WAKU_GMAIL", raising=False)
    assert _row().enabled({"WAKU_GMAIL": ""}) is False
    assert load_settings().gmail is False

    monkeypatch.setenv("WAKU_GMAIL", "1")
    assert _row().enabled({"WAKU_GMAIL": "1"}) is True
    assert load_settings().gmail is True


def test_real_delivery_is_a_second_switch(monkeypatch, tmp_path):
    """Opening the mailbox must not also open outbound mail: with WAKU_GMAIL on
    and WAKU_GMAIL_SEND unset, gmail_send drafts instead of sending."""
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setenv("WAKU_GMAIL", "1")
    monkeypatch.delenv("WAKU_GMAIL_SEND", raising=False)
    settings = load_settings()
    assert settings.gmail is True
    assert settings.gmail_send is False

    monkeypatch.setenv("WAKU_GMAIL_SEND", "true")
    assert load_settings().gmail_send is True


def test_gmail_reuses_the_gcal_extra_and_names_a_real_setup_page():
    """No new dependency (AGENTS.md rule 3), and the setup URL is a page a
    person can actually open."""
    row = _row()
    assert row.extra == "gcal"
    assert row.import_name == "googleapiclient"
    assert row.setup_url.startswith("https://")
    assert row.reload == integrations.ReloadMode.AGENT


@pytest.mark.parametrize("name", ["WAKU_GMAIL", "WAKU_GMAIL_SEND"])
def test_both_switches_have_a_field_and_no_secret(name):
    """The row's dialog is generated from `env`; a flag with no field is
    unreachable from the dashboard, and nothing here is a key."""
    field = next(f for f in _row().env if f.name == name)
    assert field.kind == integrations.FieldKind.BOOL
    assert field.secret is False


# --- the two read-only tools -----------------------------------------------
#
# Everything below runs offline: the google.* surface gmail.py imports is
# faked through sys.modules, the way test_google_calendar.py fakes providers.
# No network, no key, no mailbox. The googleapiclient extra is not installed in
# CI, so the fakes are also what lets a search/read path run at all.


class _FakeRequest:
    def __init__(self, payload, error=None):
        self._payload = payload
        self._error = error

    def execute(self, **kwargs):
        if self._error is not None:
            raise self._error
        return self._payload


class _FakeMessages:
    """A mailbox keyed by id. `list` names every id (the tool caps), `get`
    returns the stored payload, so a hit without a matching get is visible."""

    def __init__(self, store, captured, error=None):
        self._store = store
        self._captured = captured
        self._error = error

    def list(self, **kwargs):
        self._captured.setdefault("lists", []).append(kwargs)
        return _FakeRequest({"messages": [{"id": mid} for mid in self._store]}, self._error)

    def get(self, **kwargs):
        self._captured.setdefault("gets", []).append(kwargs)
        return _FakeRequest(self._store[kwargs["id"]], self._error)

    def send(self, **kwargs):
        self._captured.setdefault("sends", []).append(kwargs)
        return _FakeRequest({"id": "sent-1"}, self._error)


class _FakeService:
    def __init__(self, store, captured, error=None):
        self._entries = _FakeMessages(store, captured, error)

    def users(self):
        return self

    def messages(self):
        return self._entries


def _install_fake_gmail(monkeypatch, service, *, build_raises=False):
    """Install just enough google.* for gmail.py to reach a fake service.

    `build_raises` makes the service builder itself explode, which proves a
    test that passes with it never reached the Gmail API — the same stronger
    claim test_gh_tool.py makes with its exploding subprocess.
    """
    captured = {"build_calls": []}

    google = ModuleType("google")
    google_auth = ModuleType("google.auth")
    google_auth_requests = ModuleType("google.auth.transport.requests")
    google_auth_requests.Request = object
    google_auth.transport = ModuleType("google.auth.transport")
    google_auth.transport.requests = google_auth_requests
    google.auth = google_auth

    google_oauth2 = ModuleType("google.oauth2")
    google_oauth2_credentials = ModuleType("google.oauth2.credentials")

    class FakeCredentials:
        def __init__(self, valid=True, expired=False, refresh_token=""):
            self.valid = valid
            self.expired = expired
            self.refresh_token = refresh_token

        @classmethod
        def from_authorized_user_file(cls, path, scopes=None):
            captured["loaded_token_path"] = path
            captured["loaded_scopes"] = scopes
            return FakeCredentials()

        def to_json(self):
            return '{"token": "fake"}'

    google_oauth2_credentials.Credentials = FakeCredentials
    google_oauth2.credentials = google_oauth2_credentials
    google.oauth2 = google_oauth2

    discovery = ModuleType("googleapiclient.discovery")

    def build(name, version, **kwargs):
        captured["build_calls"].append((name, version, kwargs))
        if build_raises:
            raise AssertionError("the token gate must fail before any API call")
        return service

    discovery.build = build
    googleapiclient = ModuleType("googleapiclient")
    googleapiclient.discovery = discovery

    for name, module in {
        "google": google,
        "google.auth": google_auth,
        "google.auth.transport": google_auth.transport,
        "google.auth.transport.requests": google_auth_requests,
        "google.oauth2": google_oauth2,
        "google.oauth2.credentials": google_oauth2_credentials,
        "googleapiclient": googleapiclient,
        "googleapiclient.discovery": discovery,
    }.items():
        monkeypatch.setitem(sys.modules, name, module)
    return captured


def _message(mid, *, sender="Ana <ana@example.com>", subject="Lunch tomorrow",
             body="See you at 10.", snippet="See you at 10", text=True):
    headers = [
        {"name": "From", "value": sender},
        {"name": "Subject", "value": subject},
        {"name": "Date", "value": "Tue, 5 Aug 2026 09:00:00 +0000"},
    ]
    payload = {"mimeType": "text/plain", "headers": headers}
    if text:
        payload["body"] = {"data": base64.urlsafe_b64encode(body.encode()).decode()}
    return {"id": mid, "snippet": snippet, "payload": payload}


def _registry_with(tmp_path, monkeypatch, service, *, build_raises=False, token=True):
    """A registry whose gmail tools talk to `service`. The token file, when
    present, is empty on purpose: the fake Credentials ignores its contents, so
    the test never depends on a real token format."""
    _install_fake_gmail(monkeypatch, service, build_raises=build_raises)
    if token:
        (tmp_path / "gmail-token.json").write_text('{"token": "x"}', encoding="utf-8")
    settings = Settings(home=tmp_path, gmail=True)
    settings.ensure_home()
    conn = connect(settings.home)
    return build_registry(conn, settings, None), conn
def test_the_tools_are_registered_only_when_the_flag_is_on(tmp_path):
    """Both directions in one test, so an inverted flag cannot pass: a machine
    that never asked for Gmail must carry no Gmail tool in its prompt, and
    WAKU_GMAIL=1 must. Same opt-in shape as apple_tools/gh_tool."""
    off = Settings(home=tmp_path / "off", gmail=False)
    on = Settings(home=tmp_path / "on", gmail=True)
    off.ensure_home()
    on.ensure_home()
    conn_off, conn_on = connect(off.home), connect(on.home)
    try:
        registry_off = build_registry(conn_off, off, None)
        registry_on = build_registry(conn_on, on, None)
    finally:
        conn_off.close()
        conn_on.close()

    assert registry_off.get("gmail_search") is None
    assert registry_off.get("gmail_read") is None
    assert registry_off.get("gmail_send") is None
    assert registry_on.get("gmail_search") is not None
    assert registry_on.get("gmail_read") is not None
    # Present even with WAKU_GMAIL_SEND off: drafting is what it does then, and
    # a tool the model cannot see would make "draft an email" impossible.
    assert registry_on.get("gmail_send") is not None


def test_a_missing_token_is_an_honest_sign_in_hint(tmp_path, monkeypatch):
    """The tool registers even with no token, so the model can tell the user
    the one command that fixes it — and never answers from an empty mailbox as
    if it were empty. build_raises proves no Gmail call happens first."""
    registry, conn = _registry_with(tmp_path, monkeypatch, service=None,
                                    build_raises=True, token=False)
    try:
        out = registry.execute("gmail_search", {"query": "from:ana"})
    finally:
        conn.close()

    assert "connect google" in out


def test_search_uses_the_readonly_scope_and_its_own_token(tmp_path, monkeypatch):
    """S6: the token is ~/.waku/gmail-token.json, never google-token.json, and
    the scope asked for is gmail.readonly. Revoking mail must not touch the
    calendar."""
    captured = {}
    mods = _install_fake_gmail(monkeypatch, _FakeService({"m1": _message("m1")}, captured))
    (tmp_path / "gmail-token.json").write_text('{"token": "x"}', encoding="utf-8")
    (tmp_path / "google-token.json").write_text('{"token": "calendar"}', encoding="utf-8")

    gmail.make_tools(tmp_path)[0].fn(query="from:ana")

    assert mods["loaded_token_path"].endswith("gmail-token.json")
    assert mods["loaded_scopes"] == [gmail.GMAIL_READONLY_SCOPE]
    assert mods["build_calls"][0][0:2] == ("gmail", "v1")


def test_search_returns_one_line_per_hit_with_id_from_subject(tmp_path, monkeypatch):
    """What the model reads: a hit carries enough to decide which one to open,
    not a bare id."""
    captured = {}
    service = _FakeService({"m1": _message("m1")}, captured)
    registry, conn = _registry_with(tmp_path, monkeypatch, service)
    try:
        out = registry.execute("gmail_search", {"query": "from:ana", "limit": 5})
    finally:
        conn.close()

    assert captured["lists"][0]["userId"] == "me"
    assert captured["lists"][0]["q"] == "from:ana"
    assert captured["lists"][0]["maxResults"] == 5
    assert "m1" in out
    assert "ana@example.com" in out
    assert "Lunch tomorrow" in out


def test_search_never_returns_more_than_the_limit_or_the_cap(tmp_path, monkeypatch):
    """A mailbox with 30 hits must not dump 30 lines into the prompt. The cap
    is enforced in the tool, not trusted to the API response."""
    store = {f"m{n}": _message(f"m{n}") for n in range(30)}
    captured = {}
    service = _FakeService(store, captured)
    registry, conn = _registry_with(tmp_path, monkeypatch, service)
    try:
        capped = registry.execute("gmail_search", {"query": "x", "limit": 9999})
        small = registry.execute("gmail_search", {"query": "x", "limit": 2})
    finally:
        conn.close()

    assert [call["maxResults"] for call in captured["lists"]] == [gmail.MAX_LIMIT, 2]
    assert len(capped.splitlines()) == gmail.MAX_LIMIT
    assert len(small.splitlines()) == 2


def test_read_returns_the_message_body(tmp_path, monkeypatch):
    """The body is the point of opening a message; headers ride along so the
    model knows who and what it is reading."""
    captured = {}
    service = _FakeService({"m9": _message("m9", body="Hello from Ana.\nSecond line.")}, captured)
    registry, conn = _registry_with(tmp_path, monkeypatch, service)
    try:
        out = registry.execute("gmail_read", {"message_id": "m9"})
    finally:
        conn.close()

    assert captured["gets"][0]["id"] == "m9"
    assert captured["gets"][0]["format"] == "full"
    assert "Hello from Ana." in out
    assert "Second line." in out
    assert "ana@example.com" in out


def test_a_mailbox_error_degrades_to_a_sentence(tmp_path, monkeypatch):
    """A quota or a timeout must not take down a chat turn: the tool returns
    text the model can report, the loop never sees an exception."""
    captured = {}
    service = _FakeService({}, captured, error=RuntimeError("quota exceeded"))
    registry, conn = _registry_with(tmp_path, monkeypatch, service)
    try:
        out = registry.execute("gmail_search", {"query": "x"})
    finally:
        conn.close()

    assert "quota exceeded" in out
    assert not out.startswith("Error running")


def test_missing_gcal_extra_names_the_install_and_the_sign_in(tmp_path, monkeypatch):
    """No extra is not a crash and not an empty result: it is the one command
    to install, plus the one to authorise."""
    monkeypatch.setitem(sys.modules, "googleapiclient.discovery", None)
    (tmp_path / "gmail-token.json").write_text('{"token": "x"}', encoding="utf-8")

    out = gmail.make_tools(tmp_path)[0].fn(query="x")

    assert "gcal" in out
    assert "connect google" in out


# --- sending: the irreversible half ----------------------------------------
#
# An email cannot be unsent, so these tests are about WHICH of two things
# happened, not merely that a string came back: a draft on disk and no API
# call, or a real send and no draft. `build_raises` is what makes the first
# claim strong — with the switch off, gmail_send must not even construct a
# Gmail client.


def _sending_registry(tmp_path, monkeypatch, service, *, send_for_real, build_raises=False, token=True):
    _install_fake_gmail(monkeypatch, service, build_raises=build_raises)
    if token:
        (tmp_path / "gmail-token.json").write_text('{"token": "x"}', encoding="utf-8")
    settings = Settings(home=tmp_path, gmail=True, gmail_send=send_for_real)
    settings.ensure_home()
    conn = connect(settings.home)
    return build_registry(conn, settings, None), conn


class _FrozenNow:
    """datetime.now() pinned to one instant, so two drafts land in the same one."""

    def __init__(self, fixed):
        self._fixed = fixed

    def now(self, tz=None):
        return self._fixed


def _drafts(home):
    outbox = home / "outbox"
    return sorted(outbox.glob("*.txt")) if outbox.exists() else []


def test_send_drafts_and_says_so_when_the_second_switch_is_off(tmp_path, monkeypatch):
    """S5: with WAKU_GMAIL_SEND unset, "send an email to Ana" drafts. The
    exploding builder proves no mail left the machine."""
    registry, conn = _sending_registry(tmp_path, monkeypatch, None, send_for_real=False, build_raises=True)
    try:
        out = registry.execute(
            "gmail_send", {"to": "ana@example.com", "subject": "Lunch", "body": "10am?"}
        )
    finally:
        conn.close()

    drafts = _drafts(tmp_path)
    assert len(drafts) == 1
    text = drafts[0].read_text(encoding="utf-8")
    assert "To: ana@example.com" in text
    assert "Subject: Lunch" in text
    assert "10am?" in text
    assert "Nothing was sent" in out
    assert drafts[0].name in out


def test_send_for_real_reaches_the_api_and_writes_no_draft(tmp_path, monkeypatch):
    """The other direction of the same switch: WAKU_GMAIL_SEND=1 delivers, and
    the local outbox stays empty so the two paths cannot both look taken."""
    captured = {}
    registry, conn = _sending_registry(
        tmp_path, monkeypatch, _FakeService({}, captured), send_for_real=True
    )
    try:
        out = registry.execute(
            "gmail_send", {"to": "ana@example.com", "subject": "Lunch", "body": "10am?"}
        )
    finally:
        conn.close()

    assert _drafts(tmp_path) == []
    payload = captured["sends"][0]
    assert payload["userId"] == "me"
    raw = payload["body"]["raw"]
    message = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode()
    assert "To: ana@example.com" in message
    assert "Subject: Lunch" in message
    assert "10am?" in message
    assert "sent-1" in out


def test_a_reply_keeps_the_thread_and_the_reply_headers(tmp_path, monkeypatch):
    """Answering a thread must land in that thread, not start a new one; the
    headers are what mail clients use to fold it there."""
    captured = {}
    registry, conn = _sending_registry(
        tmp_path, monkeypatch, _FakeService({}, captured), send_for_real=True
    )
    try:
        registry.execute(
            "gmail_send",
            {
                "to": "ana@example.com",
                "subject": "Re: Lunch",
                "body": "Sounds good",
                "thread_id": "t-42",
                "in_reply_to": "<abc@mail.example.com>",
            },
        )
    finally:
        conn.close()

    payload = captured["sends"][0]
    assert payload["body"]["threadId"] == "t-42"
    raw = payload["body"]["raw"]
    message = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode()
    assert "In-Reply-To: <abc@mail.example.com>" in message


def test_send_without_a_token_never_reports_success(tmp_path, monkeypatch):
    """Asked to send and unable to sign in: the answer names the fix. It must
    never read like something was delivered, and nothing is drafted either --
    a fake draft would hide that the mailbox was never reached."""
    registry, conn = _sending_registry(
        tmp_path, monkeypatch, None, send_for_real=True, build_raises=True, token=False
    )
    try:
        out = registry.execute(
            "gmail_send", {"to": "ana@example.com", "subject": "Lunch", "body": "10am?"}
        )
    finally:
        conn.close()

    assert "connect google" in out
    assert "Sent" not in out
    assert _drafts(tmp_path) == []


def test_a_refused_send_degrades_to_a_sentence(tmp_path, monkeypatch):
    """A revoked scope or a quota error is text the model can report, not an
    exception that ends the turn."""
    captured = {}
    service = _FakeService({}, captured, error=RuntimeError("insufficient scope"))
    registry, conn = _sending_registry(tmp_path, monkeypatch, service, send_for_real=True)
    try:
        out = registry.execute(
            "gmail_send", {"to": "ana@example.com", "subject": "Lunch", "body": "10am?"}
        )
    finally:
        conn.close()

    assert "insufficient scope" in out
    assert not out.startswith("Error running")


def test_two_drafts_in_the_same_second_both_survive(tmp_path, monkeypatch):
    """The outbox is the user's text, not a cache: a second draft to the same
    person must never overwrite the first. Time is frozen here so the collision
    is the tested situation rather than a lucky gap between microseconds."""
    registry, conn = _sending_registry(tmp_path, monkeypatch, None, send_for_real=False, build_raises=True)
    frozen = datetime(2026, 8, 5, 9, 0, 0, tzinfo=UTC)
    monkeypatch.setattr(gmail, "datetime", _FrozenNow(frozen))
    try:
        first = registry.execute(
            "gmail_send", {"to": "ana@example.com", "subject": "One", "body": "first"}
        )
        second = registry.execute(
            "gmail_send", {"to": "ana@example.com", "subject": "Two", "body": "second"}
        )
    finally:
        conn.close()

    drafts = _drafts(tmp_path)
    assert len(drafts) == 2
    texts = "\n".join(p.read_text(encoding="utf-8") for p in drafts)
    assert "first" in texts and "second" in texts
    assert first != second
