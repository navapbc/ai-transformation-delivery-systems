"""Tests for the CLI orchestration."""

from __future__ import annotations

from datetime import date

import pytest

from metricsai import cli


def test_list_modules(capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["--list-modules"]) == 0
    out = capsys.readouterr().out
    for name in ("build_pr", "security", "testing"):
        assert name in out


def test_dry_run_stub_module(capsys: pytest.CaptureFixture[str]) -> None:
    # setup_logging() uses basicConfig(force=True), so the dry-run notice lands on stderr.
    assert cli.main(["--dry-run", "--module", "build_pr"]) == 0
    err = capsys.readouterr().err
    assert "would POST" in err
    assert "build_pr_num_comments" in err
    assert "week_ending_date" in err


def test_week_ending_override(capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["--dry-run", "--module", "build_pr", "--week-ending", "2026-06-07"]) == 0
    assert '"week_ending_date": "2026-06-07"' in capsys.readouterr().err


def test_unknown_module_errors() -> None:
    assert cli.main(["--dry-run", "--module", "nope"]) == 2


def test_week_ending_day_override(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, int] = {}

    def _fake(today=None, *, weekday):
        captured["weekday"] = weekday
        return date(2026, 6, 7)

    monkeypatch.setattr(cli, "default_week_ending", _fake)
    assert cli.main(["--dry-run", "--module", "build_pr", "--week-ending-day", "sunday"]) == 0
    assert captured["weekday"] == 6  # Sunday


def test_invalid_week_ending_day_errors() -> None:
    assert cli.main(["--dry-run", "--module", "build_pr", "--week-ending-day", "funday"]) == 2


def test_security_without_repos_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "token")
    assert cli.main(["--dry-run", "--module", "security"]) == 2


def test_post_without_url_errors() -> None:
    # No --dry-run and no URL configured -> usage error.
    assert cli.main(["--module", "build_pr"]) == 2


def test_post_calls_client(monkeypatch: pytest.MonkeyPatch) -> None:
    posted: dict[str, object] = {}

    def _post(self, row, *, dry_run=False):
        posted.update(
            url=self.webhook_url, dry_run=dry_run, n=len(row.metrics), key=self.webhook_key
        )

    monkeypatch.setenv("METRICSAI_WEBHOOK_KEY", "wk")
    monkeypatch.setattr(cli.MetricsClient, "post", _post)
    assert cli.main(["--module", "build_pr", "--url", "https://example.com/exec"]) == 0
    assert posted["url"] == "https://example.com/exec"
    assert posted["dry_run"] is False
    assert posted["key"] == "wk"
    assert posted["n"] >= 1


def test_skip_sechub_flag(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    import metricsai.modules.security as sec

    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "token")
    monkeypatch.setattr(sec, "fetch_review_comments", lambda **_: [])

    def _must_not_call(**_):  # pragma: no cover - must not run
        raise AssertionError("Security Hub must not be queried with --skip-sechub")

    monkeypatch.setattr(sec, "count_failed_critical_high", _must_not_call)

    code = cli.main(["--dry-run", "--module", "security", "--repo", "o/r", "--skip-sechub"])
    assert code == 0
    err = capsys.readouterr().err
    assert "security_total_security_comments" in err
    assert "security_total_sechub_critical_high" not in err


def test_all_authors_flag_flows_to_fetch(monkeypatch: pytest.MonkeyPatch) -> None:
    import metricsai.modules.security as sec

    captured: dict[str, object] = {}

    def _fake_fetch(**kwargs):
        captured.update(kwargs)
        return []

    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "token")
    monkeypatch.setattr(sec, "fetch_review_comments", _fake_fetch)

    argv = ["--dry-run", "--module", "security", "--repo", "o/r", "--skip-sechub", "--all-authors"]
    assert cli.main(argv) == 0
    assert captured["match_all_authors"] is True


def test_all_authors_defaults_off(monkeypatch: pytest.MonkeyPatch) -> None:
    import metricsai.modules.security as sec

    captured: dict[str, object] = {}
    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "token")
    monkeypatch.setattr(sec, "fetch_review_comments", lambda **kw: captured.update(kw) or [])

    assert cli.main(["--dry-run", "--module", "security", "--repo", "o/r", "--skip-sechub"]) == 0
    assert captured["match_all_authors"] is False


def test_gather_error_is_reported_cleanly(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    import metricsai.modules.security as sec

    def _boom(**_):
        raise RuntimeError("401 Bad credentials")

    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "token")
    monkeypatch.setattr(sec, "fetch_review_comments", _boom)

    code = cli.main(["--dry-run", "--module", "security", "--repo", "o/r", "--skip-sechub"])
    assert code == 2
    err = capsys.readouterr().err
    assert "Failed gathering 'security' metrics: 401 Bad credentials" in err
    assert "Traceback" not in err  # no raw stack trace without --debug


def test_post_without_webhook_key_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    # URL present but no key resolvable in a non-interactive context -> usage error.
    monkeypatch.setattr("metricsai.keychain.keyring.get_password", lambda *_: None)
    assert cli.main(["--module", "build_pr", "--url", "https://example.com/exec"]) == 2


def test_all_modules_run_by_default(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    import metricsai.modules.security as sec
    import metricsai.modules.testing as testing

    monkeypatch.setenv("METRICSAI_GITHUB_TOKEN", "token")
    monkeypatch.setenv("METRICSAI_GITHUB_REPOS", "owner/repo")
    monkeypatch.setattr(sec, "fetch_review_comments", lambda **_: [])
    monkeypatch.setattr(sec, "count_failed_critical_high", lambda **_: 0)
    monkeypatch.setattr(testing, "fetch_classifier_comments", lambda **_: [])

    assert cli.main(["--dry-run"]) == 0
    err = capsys.readouterr().err
    assert "build_pr_num_comments" in err
    assert "testing_classifier_thumbs_up_rate_pct" in err
    assert "security_total_sechub_critical_high" in err
