"""Tests for token resolution."""

from __future__ import annotations

import pytest

from metricsai import keychain
from metricsai.config import Settings


def test_env_token_wins(settings: Settings) -> None:
    assert keychain.resolve_token(settings, interactive=False) == "env-token"


def test_webhook_key_env_wins() -> None:
    settings = Settings(webhook_key="env-key")
    assert keychain.resolve_webhook_key(settings, interactive=False) == "env-key"


def test_webhook_key_missing_non_interactive_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(keychain.keyring, "get_password", lambda *_: None)
    with pytest.raises(keychain.TokenError):
        keychain.resolve_webhook_key(Settings(), interactive=False)


def test_keychain_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(keychain.keyring, "get_password", lambda *_: "kc-token")
    settings = Settings()  # no env token
    assert keychain.resolve_token(settings, interactive=False) == "kc-token"


def test_missing_non_interactive_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(keychain.keyring, "get_password", lambda *_: None)
    settings = Settings()
    with pytest.raises(keychain.TokenError):
        keychain.resolve_token(settings, interactive=False)


def test_prompt_stores_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(keychain.keyring, "get_password", lambda *_: None)
    monkeypatch.setattr(keychain.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr(keychain.getpass, "getpass", lambda _: "typed-token")
    stored: dict[str, str] = {}
    monkeypatch.setattr(
        keychain.keyring,
        "set_password",
        lambda service, account, token: stored.update({service: token}),
    )
    settings = Settings()
    assert keychain.resolve_token(settings, interactive=True) == "typed-token"
    assert stored["metricsai-github"] == "typed-token"
