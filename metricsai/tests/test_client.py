"""Tests for the webhook client."""

from __future__ import annotations

import pytest

from metricsai import client as client_mod
from metricsai.client import MetricsClient
from metricsai.models import MetricRow


def test_dry_run_skips_network(monkeypatch: pytest.MonkeyPatch) -> None:
    called = False

    def _fail(*_args, **_kwargs):  # pragma: no cover - must not run
        nonlocal called
        called = True

    monkeypatch.setattr(client_mod.httpx, "post", _fail)
    MetricsClient("https://example.com/exec").post(MetricRow(metrics={"a": 1}), dry_run=True)
    assert called is False


def test_post_sends_flat_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    class _Resp:
        status_code = 200

        def raise_for_status(self) -> None:
            return None

    def _post(url, *, json, timeout, follow_redirects):
        captured.update(url=url, json=json, timeout=timeout, follow_redirects=follow_redirects)
        return _Resp()

    monkeypatch.setattr(client_mod.httpx, "post", _post)
    row = MetricRow(metrics={"security_critical": 0})
    MetricsClient(
        "https://example.com/exec", webhook_key="secret", tab="security", timeout=5.0
    ).post(row)

    body = captured["json"]
    assert captured["url"] == "https://example.com/exec"
    assert captured["timeout"] == 5.0
    assert captured["follow_redirects"] is True
    assert "week_ending_date" in body
    assert body["security_critical"] == 0
    # Key and tab travel in the body under reserved keys.
    assert body["_key"] == "secret"
    assert body["_tab"] == "security"


def test_dry_run_omits_key(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    def _fail(*_args, **_kwargs):  # pragma: no cover - must not run
        raise AssertionError("dry-run must not POST")

    monkeypatch.setattr(client_mod.httpx, "post", _fail)
    with caplog.at_level("WARNING", logger="metricsai.client"):
        MetricsClient("https://example.com/exec", webhook_key="secret").post(
            MetricRow(metrics={"a": 1}), dry_run=True
        )
    # The secret (and its reserved field) must never appear in dry-run output.
    message = caplog.records[-1].getMessage()
    assert "secret" not in message
    assert "_key" not in message
