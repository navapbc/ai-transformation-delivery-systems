"""Tests for environment-backed configuration."""

from __future__ import annotations

import pytest

from metricsai.config import Settings


def test_defaults() -> None:
    settings = Settings()
    assert settings.webhook_url is None
    assert settings.github_token is None
    assert settings.github_keychain_service == "metricsai-github"
    assert settings.request_timeout == 10.0


def test_reads_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("METRICSAI_WEBHOOK_URL", "https://example.com/exec")
    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "secret")
    settings = Settings()
    assert str(settings.webhook_url) == "https://example.com/exec"
    assert settings.github_token is not None
    assert settings.github_token.get_secret_value() == "secret"
