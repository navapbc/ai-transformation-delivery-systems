"""Tests for the security module and its aggregation."""

from __future__ import annotations

from datetime import date

import pytest

from metricsai.config import Settings
from metricsai.context import RunContext
from metricsai.modules import REGISTRY
from metricsai.modules.security import SecurityModule, _aggregate_comments
from metricsai.sources.github import Comment

EXPECTED_KEYS = {
    "security_total_security_comments",
    "security_thumbs_ups",
    "security_thumbs_downs",
    "security_critical",
    "security_high",
    "security_medium",
    "security_low",
    "security_compliance_total_comments",
    "security_compliance_thumbs_ups",
    "security_compliance_thumbs_downs",
    "security_compliance_critical",
    "security_compliance_high",
    "security_compliance_medium",
    "security_compliance_low",
    "security_total_sechub_critical_high",
}


def _ctx(**settings_kwargs: object) -> RunContext:
    settings = Settings(**settings_kwargs)  # type: ignore[arg-type]
    return RunContext(
        settings=settings,
        get_github_token=lambda: "token",
        week_ending_date=date(2026, 6, 7),
    )


def test_expected_modules_registered() -> None:
    assert set(REGISTRY) >= {"build_pr", "testing", "security"}
    assert "security_compliance" not in REGISTRY  # merged into `security`


def test_aggregate_classifies_counts_and_severities() -> None:
    comments = [
        Comment("security", "security: leak\nSeverity: HIGH", thumbs_up=2, thumbs_down=1),
        Comment("security", "security(x): Severity: critical", thumbs_up=0, thumbs_down=0),
        Comment("compliance", "compliance: drift\nSeverity: LOW", thumbs_up=1, thumbs_down=0),
    ]
    metrics = _aggregate_comments(comments)
    assert metrics["security_total_security_comments"] == 2
    assert metrics["security_thumbs_ups"] == 2
    assert metrics["security_thumbs_downs"] == 1
    assert metrics["security_high"] == 1
    assert metrics["security_critical"] == 1
    assert metrics["security_compliance_total_comments"] == 1
    assert metrics["security_compliance_low"] == 1
    assert metrics["security_compliance_thumbs_ups"] == 1


def test_gather_requires_repos() -> None:
    with pytest.raises(ValueError, match="No repositories"):
        SecurityModule().gather(_ctx(github_token="t"))


def test_gather_merges_github_and_aws(monkeypatch: pytest.MonkeyPatch) -> None:
    import metricsai.modules.security as sec

    monkeypatch.setattr(
        sec,
        "fetch_review_comments",
        lambda **_: [Comment("security", "security: x", thumbs_up=1, thumbs_down=0)],
    )
    monkeypatch.setattr(sec, "count_failed_critical_high", lambda **_: 5)

    metrics = SecurityModule().gather(_ctx(github_token="t", github_repos="owner/repo"))
    assert set(metrics) == EXPECTED_KEYS
    assert metrics["security_total_security_comments"] == 1
    assert metrics["security_total_sechub_critical_high"] == 5


def test_skip_sechub_omits_aws_but_keeps_github(monkeypatch: pytest.MonkeyPatch) -> None:
    import metricsai.modules.security as sec

    monkeypatch.setattr(
        sec,
        "fetch_review_comments",
        lambda **_: [Comment("security", "security: x", thumbs_up=1, thumbs_down=0)],
    )

    def _must_not_call(**_):  # pragma: no cover - must not run
        raise AssertionError("Security Hub must not be queried when skip_sechub is set")

    monkeypatch.setattr(sec, "count_failed_critical_high", _must_not_call)

    metrics = SecurityModule().gather(
        _ctx(github_token="t", github_repos="owner/repo", skip_sechub=True)
    )
    assert "security_total_sechub_critical_high" not in metrics
    assert set(metrics) == EXPECTED_KEYS - {"security_total_sechub_critical_high"}
    assert metrics["security_total_security_comments"] == 1
