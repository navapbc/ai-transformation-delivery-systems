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


def test_classify_match_all_authors_accepts_any_author() -> None:
    comment, reason = github._classify(
        _obj(login="someone-else"),
        _IN_WINDOW,
        authors_lower=_AUTHORS,
        start=_START,
        end=_END,
        with_reactions=True,
        match_all_authors=True,
    )
    assert reason == ""
    assert comment is not None
    assert comment.label == "security"


def test_classify_match_all_authors_still_enforces_window_and_label() -> None:
    # The author gate is lifted, but the window and label gates still apply.
    gate = {"authors_lower": _AUTHORS, "start": _START, "end": _END, "with_reactions": True}
    outside, reason = github._classify(
        _obj(login="anyone"), datetime(2026, 6, 9, tzinfo=UTC), match_all_authors=True, **gate
    )
    assert outside is None and "outside window" in reason
    wrong_label, reason = github._classify(
        _obj(login="anyone", body="looks good"), _IN_WINDOW, match_all_authors=True, **gate
    )
    assert wrong_label is None and "security/compliance" in reason


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
        requester = None

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


# --- off-diff findings + summary-level reactions (_scan_review_offdiff) ---


class _FakeRequester:
    """Stub GitHub requester returning fixed reaction totals for ``graphql_node``."""

    def __init__(self, up: int = 0, down: int = 0):
        self._groups = [
            {"content": "THUMBS_UP", "users": {"totalCount": up}},
            {"content": "THUMBS_DOWN", "users": {"totalCount": down}},
        ]

    def graphql_node(self, node_id, output_schema, node_type):
        return {}, {"data": {"node": {"reactionGroups": self._groups}}}


def _review(login, body, when, node_id="R_kwDO"):
    return SimpleNamespace(
        body=body,
        user=SimpleNamespace(login=login),
        submitted_at=when,
        raw_data={"node_id": node_id},
    )


_OFFDIFF_BODY = (
    "Reviewed 3 files against origin/main. Found 2 findings.\n\n"
    "_Reviewed by AI, was this helpful? Please react with 👍 or 👎._\n\n"
    "---\n\n"
    "#### Findings outside the diff (not inline-anchored)\n\n"
    "- **security(high)** `app.py:42` - Hardcoded API key\n"
    "- **compliance(low)** `infra/x.tf:3` - Missing required tag\n"
)


def _offdiff(review, requester, *, match_all_authors=False):
    return github._scan_review_offdiff(
        review,
        requester,
        authors_lower=_AUTHORS,
        start=_START,
        end=_END,
        match_all_authors=match_all_authors,
    )


def test_scan_review_offdiff_parses_findings_and_summary_reaction() -> None:
    out = _offdiff(_review("github-copilot[bot]", _OFFDIFF_BODY, _IN_WINDOW), _FakeRequester(0, 1))

    findings = [c for c in out if not c.is_summary]
    assert sorted(c.label for c in findings) == ["compliance", "security"]
    sec = next(c for c in findings if c.label == "security")
    comp = next(c for c in findings if c.label == "compliance")
    assert "Severity: HIGH" in sec.body and (sec.thumbs_up, sec.thumbs_down) == (0, 0)
    assert "Severity: LOW" in comp.body

    # The review's single 👎 rides on one is_summary carrier, labelled security.
    summary = [c for c in out if c.is_summary]
    assert len(summary) == 1
    assert summary[0].label == "security"
    assert (summary[0].thumbs_up, summary[0].thumbs_down) == (0, 1)


def test_scan_review_offdiff_no_section_no_reactions_is_empty() -> None:
    review = _review("github-copilot[bot]", "Reviewed 1 file. No findings.", _IN_WINDOW)
    assert _offdiff(review, _FakeRequester(0, 0)) == []


def test_scan_review_offdiff_section_present_but_no_reaction_omits_carrier() -> None:
    out = _offdiff(_review("github-copilot[bot]", _OFFDIFF_BODY, _IN_WINDOW), _FakeRequester(0, 0))
    assert out and all(not c.is_summary for c in out)


def test_scan_review_offdiff_respects_author_and_window() -> None:
    wrong_author = _review("someone-else", _OFFDIFF_BODY, _IN_WINDOW)
    assert _offdiff(wrong_author, _FakeRequester(1, 1)) == []
    late = _review("github-copilot[bot]", _OFFDIFF_BODY, datetime(2026, 6, 30, tzinfo=UTC))
    assert _offdiff(late, _FakeRequester(1, 1)) == []
    # match_all_authors lifts the author gate.
    assert _offdiff(wrong_author, _FakeRequester(0, 0), match_all_authors=True)


def test_review_reactions_degrades_to_zero() -> None:
    assert github._review_reactions(_FakeRequester(1, 1), {}) == (0, 0)  # no node_id
    assert github._review_reactions(None, {"node_id": "R_1"}) == (0, 0)  # no requester

    class Boom:
        def graphql_node(self, *args):
            raise RuntimeError("graphql unavailable")

    assert github._review_reactions(Boom(), {"node_id": "R_1"}) == (0, 0)


# --- classifier source: verdict parsing + comment expansion ---

_CLASSIFIER = "github-actions[bot]"


def _classifier_body(*verdicts: str) -> str:
    entries = ", ".join(f'{{"verdict": "{v}"}}' for v in verdicts)
    return (
        "test-classifier: AI triage of failing tests\n\n"
        "<!-- AI_CLASSIFIER_JSON_BEGIN -->\n"
        f'{{"classifications": [{entries}]}}\n'
        "<!-- AI_CLASSIFIER_JSON_END -->\n"
    )


def test_parse_verdicts_reads_each_entry() -> None:
    body = _classifier_body("APPLICATION_BUG", "TEST_BUG")
    assert github._parse_verdicts(body) == ["APPLICATION_BUG", "TEST_BUG"]


def test_parse_verdicts_uppercases_and_handles_missing() -> None:
    body = (
        "<!-- AI_CLASSIFIER_JSON_BEGIN -->\n"
        '{"classifications": [{"verdict": "flaky_failure"}, {"category": "other"}]}\n'
        "<!-- AI_CLASSIFIER_JSON_END -->"
    )
    assert github._parse_verdicts(body) == ["FLAKY_FAILURE", ""]


def test_parse_verdicts_empty_when_no_block_or_unparseable() -> None:
    assert github._parse_verdicts("test-classifier: no json here") == []
    bad = "<!-- AI_CLASSIFIER_JSON_BEGIN -->\nnot json\n<!-- AI_CLASSIFIER_JSON_END -->"
    assert github._parse_verdicts(bad) == []


def _classifier_obj(login: str, body: str, when, html, reactions=None):
    return SimpleNamespace(
        body=body,
        user=SimpleNamespace(login=login),
        created_at=when,
        raw_data={"html_url": html, "reactions": reactions or {}},
    )


def test_classify_classifier_expands_verdicts_with_reactions() -> None:
    obj = _classifier_obj(
        _CLASSIFIER,
        _classifier_body("APPLICATION_BUG", "TEST_BUG"),
        _IN_WINDOW,
        "https://github.com/o/r/pull/1",
        {"+1": 3, "-1": 1},
    )
    out = github._classify_classifier(obj, authors_lower={_CLASSIFIER}, start=_START, end=_END)
    assert [c.verdict for c in out] == ["APPLICATION_BUG", "TEST_BUG"]
    assert all((c.thumbs_up, c.thumbs_down) == (3, 1) for c in out)


def test_classify_classifier_labelled_but_no_json_counts_once() -> None:
    obj = _classifier_obj(
        _CLASSIFIER, "test-classifier: triage", _IN_WINDOW, "https://github.com/o/r/pull/1"
    )
    out = github._classify_classifier(obj, authors_lower={_CLASSIFIER}, start=_START, end=_END)
    assert len(out) == 1
    assert out[0].verdict == ""


def test_classify_classifier_skips_wrong_label_author_window() -> None:
    body = _classifier_body("APPLICATION_BUG")
    gate = {"authors_lower": {_CLASSIFIER}, "start": _START, "end": _END}
    # Wrong label (a security comment, not a classifier one).
    sec = _classifier_obj(_CLASSIFIER, "security: leak", _IN_WINDOW, "x")
    assert github._classify_classifier(sec, **gate) == []
    # Wrong author.
    wrong = _classifier_obj("someone-else", body, _IN_WINDOW, "x")
    assert github._classify_classifier(wrong, **gate) == []
    # Outside window.
    late = _classifier_obj(_CLASSIFIER, body, datetime(2026, 6, 30, tzinfo=UTC), "x")
    assert github._classify_classifier(late, **gate) == []


def test_fetch_classifier_comments_scans_both_surfaces(monkeypatch) -> None:
    issue = _classifier_obj(
        _CLASSIFIER,
        _classifier_body("APPLICATION_BUG"),
        _IN_WINDOW,
        "https://github.com/o/r/pull/1",
        {"+1": 1},
    )
    review = _classifier_obj(
        _CLASSIFIER,
        _classifier_body("TEST_BUG", "FLAKY_FAILURE"),
        _IN_WINDOW,
        "https://github.com/o/r/pull/2",
        {"+1": 2},
    )

    class FakeRepo:
        def get_issues_comments(self, since):
            return [issue]

        def get_pulls_comments(self, since):
            return [review]

    class FakeGithub:
        def __init__(self, *args, **kwargs):
            pass

        def get_repo(self, name):
            return FakeRepo()

    monkeypatch.setattr(github, "Github", FakeGithub)
    out = github.fetch_classifier_comments(
        token="t",
        base_url="https://api.github.com",
        repos=["o/r"],
        authors=[_CLASSIFIER],
        start=_START,
        end=_END,
    )
    assert sorted(c.verdict for c in out) == ["APPLICATION_BUG", "FLAKY_FAILURE", "TEST_BUG"]
    assert sum(c.thumbs_up for c in out) == 1 + 2 + 2  # review's 👍 repeated per verdict
