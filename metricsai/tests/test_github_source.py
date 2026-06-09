"""Tests for the GitHub source helpers."""

from __future__ import annotations

from datetime import UTC, datetime
from types import SimpleNamespace

from metricsai.sources import github


def test_is_pull_comment_distinguishes_prs_from_issues() -> None:
    pr = SimpleNamespace(raw_data={"html_url": "https://github.com/o/r/pull/5#issuecomment-1"})
    issue = SimpleNamespace(raw_data={"html_url": "https://github.com/o/r/issues/5#issuecomment-1"})
    assert github._is_pull_comment(pr) is True
    assert github._is_pull_comment(issue) is False
    assert github._is_pull_comment(SimpleNamespace(raw_data={})) is False


def test_reactions_reads_inline_summary() -> None:
    obj = SimpleNamespace(raw_data={"reactions": {"+1": 3, "-1": 1}})
    assert github._reactions(obj) == (3, 1)
    assert github._reactions(SimpleNamespace(raw_data={})) == (0, 0)


def test_as_utc_coerces_naive_only() -> None:
    aware = datetime(2026, 6, 1, 12, 0, 0, tzinfo=UTC)
    assert github._as_utc(aware) is aware
    assert github._as_utc(datetime(2026, 6, 1, 12, 0, 0)).tzinfo is UTC


# --- _classify (the filter that decides whether a comment counts) ---

_START = datetime(2026, 6, 1, 0, 0, 0, tzinfo=UTC)
_END = datetime(2026, 6, 7, 23, 59, 59, tzinfo=UTC)
_AUTHORS = {"github-copilot[bot]"}
_IN_WINDOW = datetime(2026, 6, 3, 12, 0, 0, tzinfo=UTC)


def _obj(login: str = "github-copilot[bot]", body: str = "security: leak", reactions=None):
    return SimpleNamespace(
        body=body,
        user=SimpleNamespace(login=login),
        raw_data={"reactions": reactions if reactions is not None else {"+1": 2, "-1": 1}},
    )


def _classify(obj, when, *, with_reactions=True):
    return github._classify(
        obj, when, authors_lower=_AUTHORS, start=_START, end=_END, with_reactions=with_reactions
    )


def test_classify_matches_and_reads_reactions() -> None:
    comment, reason = _classify(_obj(), _IN_WINDOW)
    assert reason == ""
    assert comment is not None
    assert comment.label == "security"
    assert (comment.thumbs_up, comment.thumbs_down) == (2, 1)


def test_classify_skips_wrong_author() -> None:
    comment, reason = _classify(_obj(login="someone-else"), _IN_WINDOW)
    assert comment is None
    assert "author" in reason


def test_classify_skips_outside_window() -> None:
    comment, reason = _classify(_obj(), datetime(2026, 6, 9, tzinfo=UTC))
    assert comment is None
    assert "outside window" in reason


def test_classify_skips_wrong_prefix() -> None:
    comment, reason = _classify(_obj(body="looks good to me"), _IN_WINDOW)
    assert comment is None
    assert "security/compliance" in reason


def test_classify_reviews_have_no_reactions() -> None:
    comment, _ = _classify(_obj(), _IN_WINDOW, with_reactions=False)
    assert comment is not None
    assert (comment.thumbs_up, comment.thumbs_down) == (0, 0)


# --- fetch_review_comments end-to-end against a fake PyGithub client ---


def _comment(login, body, when, html, reactions=None):
    return SimpleNamespace(
        body=body,
        user=SimpleNamespace(login=login),
        created_at=when,
        submitted_at=when,
        raw_data={"html_url": html, "reactions": reactions or {}},
    )


def test_fetch_review_comments_filters_and_normalizes(monkeypatch) -> None:
    bot = "github-copilot[bot]"
    issue_pr = _comment(
        bot, "security: leak", _IN_WINDOW, "https://github.com/o/r/pull/1", {"+1": 1}
    )
    issue_plain = _comment(bot, "security: x", _IN_WINDOW, "https://github.com/o/r/issues/9")
    review = _comment(bot, "compliance: drift", _IN_WINDOW, "https://github.com/o/r/pull/1")
    submission = _comment(bot, "security: summary", _IN_WINDOW, "https://github.com/o/r/pull/1")

    class FakePull:
        updated_at = _IN_WINDOW

        def get_reviews(self):
            return [submission]

    class FakeRepo:
        def get_issues_comments(self, since):
            return [issue_pr, issue_plain]  # issue_plain dropped: not a PR comment

        def get_pulls_comments(self, since):
            return [review]

        def get_pulls(self, state, sort, direction):
            return [FakePull()]

    class FakeGithub:
        def __init__(self, *args, **kwargs):
            pass

        def get_repo(self, name):
            return FakeRepo()

    monkeypatch.setattr(github, "Github", FakeGithub)
    out = github.fetch_review_comments(
        token="t",
        base_url="https://api.github.com",
        repos=["o/r"],
        authors=[bot],
        start=_START,
        end=_END,
    )
    assert sorted(c.label for c in out) == ["compliance", "security", "security"]
    assert any(c.thumbs_up == 1 for c in out)  # from the PR conversation comment
