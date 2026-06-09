"""Shared pytest fixtures."""

from __future__ import annotations

import pytest

from metricsai.config import Settings


@pytest.fixture
def settings() -> Settings:
    """A Settings instance with a token supplied via the environment field."""
    return Settings(github_token="env-token", webhook_url="https://example.com/exec")


@pytest.fixture(autouse=True)
def _clear_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Ensure ambient METRICSAI_* env vars don't leak into tests."""
    for name in (
        "METRICSAI_WEBHOOK_URL",
        "METRICSAI_WEBHOOK_KEY",
        "METRICSAI_WEBHOOK_TAB",
        "METRICSAI_GITHUB_TOKEN",
        "METRICSAI_GITHUB_REPOS",
        "METRICSAI_GITHUB_AUTHORS",
        "METRICSAI_GITHUB_BASE_URL",
        "METRICSAI_WEEK_ENDING_DAY",
        "METRICSAI_AWS_REGION",
        "METRICSAI_SKIP_SECHUB",
    ):
        monkeypatch.delenv(name, raising=False)
