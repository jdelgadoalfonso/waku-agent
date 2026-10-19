"""Deterministic coverage for Gmail: the Connections row and its two switches.

Offline: no network, no key, no mailbox. The rules pinned here are the ones a
mistake would make expensive — that reaching a person's inbox is opt-in, and
that real delivery is a second switch rather than the same one (an email cannot
be unsent).
"""

from __future__ import annotations

import pytest

from waku import integrations
from waku.config import load_settings


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
