"""Tests for the testing (classifier) module and its aggregation."""

from __future__ import annotations

from datetime import date

import pytest

from metricsai.config import Settings
from metricsai.context import RunContext
from metricsai.modules.testing import TestingModule, _aggregate_classifications
from metricsai.sources.github import Classification

EXPECTED_KEYS = {
    "testing_classifier_total_classifications",
    "testing_classifier_thumbs_ups",
    "testing_classifier_thumbs_downs",
    "testing_classifier_thumbs_up_rate_pct",
    "testing_classifier_app_bug",
    "testing_classifier_test_bug",
    "testing_classifier_flaky_failure",
    "testing_classifier_environment_issue",
}


def _ctx(**settings_kwargs: object) -> RunContext:
    settings = Settings(**settings_kwargs)  # type: ignore[arg-type]
    return RunContext(
        settings=settings,
        get_github_token=lambda: "token",
        week_ending_date=date(2026, 6, 7),
    )


def test_aggregate_counts_verdicts_and_rate() -> None:
    records = [
        Classification("APPLICATION_BUG", thumbs_up=2, thumbs_down=0),
        Classification("TEST_BUG", thumbs_up=2, thumbs_down=0),  # same comment's 👍 repeated
        Classification("FLAKY_FAILURE", thumbs_up=0, thumbs_down=1),
        Classification("ENVIRONMENT_ISSUE", thumbs_up=1, thumbs_down=0),
    ]
    metrics = _aggregate_classifications(records)
    assert set(metrics) == EXPECTED_KEYS
    assert metrics["testing_classifier_total_classifications"] == 4
    assert metrics["testing_classifier_app_bug"] == 1
    assert metrics["testing_classifier_test_bug"] == 1
    assert metrics["testing_classifier_flaky_failure"] == 1
    assert metrics["testing_classifier_environment_issue"] == 1
    assert metrics["testing_classifier_thumbs_ups"] == 5
    assert metrics["testing_classifier_thumbs_downs"] == 1
    # 5 / (5 + 1) = 83.333... -> 83.3
    assert metrics["testing_classifier_thumbs_up_rate_pct"] == 83.3


def test_aggregate_empty_is_all_zero_no_div_by_zero() -> None:
    metrics = _aggregate_classifications([])
    assert metrics["testing_classifier_total_classifications"] == 0
    assert metrics["testing_classifier_thumbs_up_rate_pct"] == 0.0


def test_aggregate_unknown_verdict_counts_total_only() -> None:
    # A labelled comment with no parseable verdict surfaces as an empty-verdict record:
    # it counts toward the total but lands in no bucket.
    metrics = _aggregate_classifications([Classification("", thumbs_up=1, thumbs_down=0)])
    assert metrics["testing_classifier_total_classifications"] == 1
    assert metrics["testing_classifier_app_bug"] == 0
    assert metrics["testing_classifier_thumbs_ups"] == 1


def test_gather_requires_repos() -> None:
    with pytest.raises(ValueError, match="No repositories"):
        TestingModule().gather(_ctx())


def test_gather_returns_expected_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    import metricsai.modules.testing as testing

    monkeypatch.setattr(
        testing,
        "fetch_classifier_comments",
        lambda **_: [Classification("APPLICATION_BUG", thumbs_up=1, thumbs_down=0)],
    )
    metrics = TestingModule().gather(_ctx(testing_github_repos="owner/repo"))
    assert set(metrics) == EXPECTED_KEYS
    assert metrics["testing_classifier_app_bug"] == 1


def test_gather_falls_back_to_shared_repos(monkeypatch: pytest.MonkeyPatch) -> None:
    import metricsai.modules.testing as testing

    captured: dict[str, object] = {}

    def _fake_fetch(**kwargs):
        captured.update(kwargs)
        return []

    monkeypatch.setattr(testing, "fetch_classifier_comments", _fake_fetch)
    # No testing-specific repos: should fall back to github_repos, and to the classifier
    # author default since testing_github_authors is unset.
    TestingModule().gather(_ctx(github_repos="shared/repo"))
    assert captured["repos"] == ["shared/repo"]
    assert captured["authors"] == ["github-actions[bot]"]
