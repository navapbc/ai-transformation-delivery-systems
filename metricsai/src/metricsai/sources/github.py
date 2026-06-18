"""GitHub review-comment source, backed by PyGithub.

This is the Python port of ``pr_review_comments.sh``: it collects the AI reviewer's
*Conventional Comments* across a set of repositories and a time window, drawn from three
sources -- PR conversation (issue) comments, inline review comments, and review submission
bodies -- and normalises each into a :class:`Comment`.

Only comments are kept whose author is one of ``authors`` (unless ``match_all_authors`` is
set, which accepts any author), whose creation time falls within ``[start, end]``, and whose
body begins with ``security`` or ``compliance`` (the Conventional-Comment label).
Thumbs-up/down reaction totals are read from the inline reaction summary that GitHub returns
with each comment.

Review submissions get a second pass (:func:`_scan_review_offdiff`): the PR-review
dispatcher cannot inline-anchor a finding whose line is outside the diff, so it lists those
in the review *body* -- which does not start with the label -- and they are parsed out here
into individual comments. A review's own summary-level 👍/👎 (which REST does not expose for
reviews) is fetched via GraphQL and folded into the ``security`` totals.

Diagnostics: each repository logs a per-source ``fetched/matched`` summary at INFO
(``-v``), and every skipped comment logs its reason (author / window / label) at DEBUG
(``--debug``) -- so it is easy to see *why* a comment was or was not counted.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime

from github import Auth, Github

logger = logging.getLogger(__name__)

#: A body beginning (ignoring leading whitespace) with the Conventional-Comment label.
_LABEL_RE = re.compile(r"^\s*(security|compliance)", re.IGNORECASE)

#: Header the PR-review dispatcher writes above the off-diff findings it could not
#: inline-anchor (GitHub rejects the whole review if a comment lands off the diff), so it
#: lists them in the review *body* instead. See ``security/review`` dispatcher.
_OFFDIFF_HEADER = "Findings outside the diff (not inline-anchored)"

#: One off-diff finding bullet, e.g. ``- **security(high)** `app.py:42` - Hardcoded key``.
#: The body these come from never starts with the label, so :func:`_classify` misses them.
_OFFDIFF_BULLET_RE = re.compile(
    r"^\s*-\s*\*\*(?P<label>security|compliance)\((?P<sev>critical|high|medium|low)\)\*\*"
    r"\s+`(?P<loc>[^`]*)`\s*-\s*(?P<title>.+?)\s*$",
    re.IGNORECASE | re.MULTILINE,
)

#: A body beginning (ignoring leading whitespace) with the ``test-classifier:`` label.
_CLASSIFIER_LABEL_RE = re.compile(r"^\s*test-classifier:", re.IGNORECASE)

#: The machine-readable verdict block the classifier embeds in its PR comment, delimited by
#: ``<!-- AI_CLASSIFIER_JSON_BEGIN -->`` / ``<!-- AI_CLASSIFIER_JSON_END -->`` markers (see
#: ``testing/classifier/.skills/test-classifier/SKILL.md`` section 6B).
_CLASSIFIER_JSON_RE = re.compile(
    r"<!-- AI_CLASSIFIER_JSON_BEGIN -->(?P<json>.*?)<!-- AI_CLASSIFIER_JSON_END -->",
    re.DOTALL,
)


@dataclass(frozen=True)
class Comment:
    """A normalised AI review comment.

    :ivar label: ``"security"`` or ``"compliance"`` (the Conventional-Comment label).
    :ivar body: The full comment body.
    :ivar thumbs_up: Count of ``+1`` reactions.
    :ivar thumbs_down: Count of ``-1`` reactions.
    :ivar is_summary: When ``True`` this is not a finding but a carrier for a review's
        summary-level reactions (see :func:`_scan_review_offdiff`); aggregation counts its
        reactions but does not count it as a comment or read a severity from it.
    """

    label: str
    body: str
    thumbs_up: int
    thumbs_down: int
    is_summary: bool = False


def fetch_review_comments(
    *,
    token: str,
    base_url: str,
    repos: Iterable[str],
    authors: Iterable[str],
    start: datetime,
    end: datetime,
    match_all_authors: bool = False,
) -> list[Comment]:
    """Fetch and normalise the AI reviewer's comments across ``repos`` within the window.

    :param token: GitHub token used for authentication.
    :param base_url: GitHub REST API base URL (github.com or an Enterprise host).
    :param repos: ``owner/repo`` identifiers to scan.
    :param authors: Comment author logins to keep (case-insensitive).
    :param start: Inclusive window start (timezone-aware UTC).
    :param end: Inclusive window end (timezone-aware UTC).
    :param match_all_authors: When ``True``, accept any author and ignore ``authors``.
    :returns: The matching normalised comments.
    """
    gh = Github(base_url=base_url, auth=Auth.Token(token))
    authors_lower = {a.lower() for a in authors}
    out: list[Comment] = []
    for full_name in repos:
        logger.debug("Scanning %s", full_name)
        out.extend(
            _scan_repo(
                gh.get_repo(full_name),
                full_name,
                authors_lower,
                start=start,
                end=end,
                match_all_authors=match_all_authors,
                requester=gh.requester,
            )
        )
    return out


@dataclass(frozen=True)
class Classification:
    """A single test classification harvested from a classifier PR comment.

    One classifier comment carries a ``classifications`` array (one entry per failing test),
    so a single comment expands into several of these. The comment's 👍/👎 reaction totals
    are attached to *every* classification it produced -- the reaction is a signal on the
    comment as a whole, and weekly aggregation sums them per verdict bucket.

    :ivar verdict: One of ``APPLICATION_BUG`` / ``TEST_BUG`` / ``FLAKY_FAILURE`` /
        ``ENVIRONMENT_ISSUE`` (uppercase, as the classifier emits them), or ``""`` if the
        embedded JSON was absent or unparseable.
    :ivar thumbs_up: Count of ``+1`` reactions on the parent comment.
    :ivar thumbs_down: Count of ``-1`` reactions on the parent comment.
    """

    verdict: str
    thumbs_up: int
    thumbs_down: int


def fetch_classifier_comments(
    *,
    token: str,
    base_url: str,
    repos: Iterable[str],
    authors: Iterable[str],
    start: datetime,
    end: datetime,
) -> list[Classification]:
    """Fetch the AI test-classifier's comments and expand them to per-verdict records.

    A classifier comment leads with the ``test-classifier:`` label and embeds a JSON verdict
    block. Each comment is expanded into one :class:`Classification` per entry in its
    ``classifications`` array, carrying the comment's reaction totals. A labelled comment
    with no parseable JSON yields a single record with an empty verdict, so it still counts
    toward the comment total.

    :param token: GitHub token used for authentication.
    :param base_url: GitHub REST API base URL (github.com or an Enterprise host).
    :param repos: ``owner/repo`` identifiers to scan.
    :param authors: Comment author logins to keep (case-insensitive).
    :param start: Inclusive window start (timezone-aware UTC).
    :param end: Inclusive window end (timezone-aware UTC).
    :returns: One record per classification across all matching comments.
    """
    gh = Github(base_url=base_url, auth=Auth.Token(token))
    authors_lower = {a.lower() for a in authors}
    out: list[Classification] = []
    for full_name in repos:
        logger.debug("Scanning %s for classifier comments", full_name)
        out.extend(
            _scan_repo_classifier(
                gh.get_repo(full_name), full_name, authors_lower, start=start, end=end
            )
        )
    return out


def _scan_repo_classifier(
    repo: object, full_name: str, authors_lower: set[str], *, start: datetime, end: datetime
) -> list[Classification]:
    """Scan one repository's PR issue + review comments for classifier verdicts.

    The classifier posts on two surfaces over its lifetime -- legacy top-level issue
    comments and (newer) file-level review comments -- so both are harvested; the two ID
    spaces are disjoint, so there is no double counting. Review-thread *replies* (the 👎
    reason) never carry the ``test-classifier:`` label, so the label filter excludes them.

    :param repo: A PyGithub ``Repository``.
    :param full_name: ``owner/repo`` (for log messages).
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :returns: The classifications harvested from this repository's classifier comments.
    """
    matched: list[Classification] = []
    counts = {"issue": [0, 0], "review": [0, 0]}

    def record(source: str, obj: object) -> None:
        counts[source][0] += 1
        records = _classify_classifier(obj, authors_lower=authors_lower, start=start, end=end)
        if records:
            matched.extend(records)
            counts[source][1] += 1

    # Issue comments (PR conversation); keep only those belonging to a pull request.
    for comment in repo.get_issues_comments(since=start):
        if _is_pull_comment(comment):
            record("issue", comment)
    # Inline review comments (and their replies, which the label filter drops).
    for comment in repo.get_pulls_comments(since=start):
        record("review", comment)

    summary = ", ".join(f"{source} {f}/{m}" for source, (f, m) in counts.items())
    logger.info("github %s classifier: %s (fetched/matched)", full_name, summary)
    return matched


def _classify_classifier(
    obj: object, *, authors_lower: set[str], start: datetime, end: datetime
) -> list[Classification]:
    """Expand one raw comment into its classifications, or ``[]`` if it does not count.

    Applies the same author / window / label gate as :func:`_classify`, then parses the
    embedded JSON block. Each entry in ``classifications`` becomes one record carrying the
    comment's reaction totals; a labelled comment whose JSON is missing or unparseable still
    yields a single empty-verdict record so it counts toward the comment total.

    :param obj: A PyGithub comment object.
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :returns: One :class:`Classification` per verdict, or ``[]`` when the comment is skipped.
    """
    body = getattr(obj, "body", None)
    login = _login(obj)
    when = getattr(obj, "created_at", None)
    if not body or login is None or when is None:
        return []
    if login.lower() not in authors_lower:
        return []
    timestamp = _as_utc(when)
    if not (start <= timestamp <= end):
        return []
    if _CLASSIFIER_LABEL_RE.match(body) is None:
        return []

    up, down = _reactions(obj)
    verdicts = _parse_verdicts(body)
    if not verdicts:
        # Labelled but no parseable verdict: count the comment with an empty verdict.
        return [Classification(verdict="", thumbs_up=up, thumbs_down=down)]
    return [Classification(verdict=v, thumbs_up=up, thumbs_down=down) for v in verdicts]


def _parse_verdicts(body: str) -> list[str]:
    """Extract the ``verdict`` of each entry in the comment's embedded JSON block.

    :param body: The full comment body.
    :returns: The uppercased verdict strings, one per ``classifications`` entry; ``[]`` if
        the marker block is absent, the JSON does not parse, or it holds no classifications.
    """
    match = _CLASSIFIER_JSON_RE.search(body)
    if match is None:
        return []
    try:
        payload = json.loads(match.group("json"))
    except (ValueError, TypeError):
        return []
    classifications = payload.get("classifications") if isinstance(payload, dict) else None
    if not isinstance(classifications, list):
        return []
    verdicts: list[str] = []
    for entry in classifications:
        if isinstance(entry, dict):
            verdict = entry.get("verdict")
            verdicts.append(str(verdict).upper() if verdict else "")
    return verdicts


def _scan_repo(
    repo: object,
    full_name: str,
    authors_lower: set[str],
    *,
    start: datetime,
    end: datetime,
    match_all_authors: bool = False,
    requester: object = None,
) -> list[Comment]:
    """Scan one repository's comment sources, with fetched/matched diagnostics.

    Beyond the three standard sources (issue / review / submission), review submission
    bodies are also mined for *off-diff* findings -- the ones the PR-review dispatcher
    could not inline-anchor and instead listed in the review body (see
    :func:`_scan_review_offdiff`); that pass is reported under the ``offdiff`` source.

    :param repo: A PyGithub ``Repository``.
    :param full_name: ``owner/repo`` (for log messages).
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :param match_all_authors: When ``True``, accept any author and ignore ``authors_lower``.
    :param requester: The PyGithub ``Requester`` (``Github.requester``) used for the GraphQL
        lookup of review summary reactions, which REST does not expose for reviews.
    :returns: The matching comments from this repository.
    """
    matched: list[Comment] = []
    counts: dict[str, list[int]] = {
        "issue": [0, 0],
        "review": [0, 0],
        "submission": [0, 0],
        "offdiff": [0, 0],
    }

    def record(source: str, obj: object, when: datetime | None, *, with_reactions: bool) -> None:
        counts[source][0] += 1
        comment, reason = _classify(
            obj,
            when,
            authors_lower=authors_lower,
            start=start,
            end=end,
            with_reactions=with_reactions,
            match_all_authors=match_all_authors,
        )
        if comment is None:
            logger.debug("%s [%s] skipped: %s", full_name, source, reason)
            return
        matched.append(comment)
        counts[source][1] += 1

    # Issue comments (PR conversation); the endpoint also returns plain-issue comments, so
    # keep only those belonging to a pull request.
    for comment in repo.get_issues_comments(since=start):
        if _is_pull_comment(comment):
            record("issue", comment, comment.created_at, with_reactions=True)
    # Inline review comments.
    for comment in repo.get_pulls_comments(since=start):
        record("review", comment, comment.created_at, with_reactions=True)
    # Review submission bodies, per-PR; stop once PRs (most-recently-updated first) predate
    # the window, since a review in-window implies the PR was updated at/after the start.
    for pull in repo.get_pulls(state="all", sort="updated", direction="desc"):
        if pull.updated_at is not None and _as_utc(pull.updated_at) < start:
            break
        for review in pull.get_reviews():
            record("submission", review, review.submitted_at, with_reactions=False)
            # Mine the same review body for off-diff findings the dispatcher could not
            # inline-anchor, plus its summary-level reactions.
            counts["offdiff"][0] += 1
            for comment in _scan_review_offdiff(
                review,
                requester,
                authors_lower=authors_lower,
                start=start,
                end=end,
                match_all_authors=match_all_authors,
            ):
                matched.append(comment)
                counts["offdiff"][1] += 1

    summary = ", ".join(f"{source} {f}/{m}" for source, (f, m) in counts.items())
    logger.info("github %s: %s (fetched/matched)", full_name, summary)
    return matched


def _classify(
    obj: object,
    when: datetime | None,
    *,
    authors_lower: set[str],
    start: datetime,
    end: datetime,
    with_reactions: bool,
    match_all_authors: bool = False,
) -> tuple[Comment | None, str]:
    """Decide whether a raw comment counts, returning the reason when it does not.

    :param obj: A PyGithub comment/review object.
    :param when: Its creation/submission time.
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :param with_reactions: Whether to read reaction totals (reviews carry none).
    :param match_all_authors: When ``True``, accept any author and ignore ``authors_lower``.
    :returns: ``(comment, "")`` on a match, or ``(None, reason)`` when skipped.
    """
    body = getattr(obj, "body", None)
    login = _login(obj)
    if not body or login is None or when is None:
        return None, "missing body, author, or timestamp"
    if not match_all_authors and login.lower() not in authors_lower:
        return None, f"author {login!r} not in configured authors"
    timestamp = _as_utc(when)
    if not (start <= timestamp <= end):
        return None, f"timestamp {timestamp.isoformat()} outside window"
    match = _LABEL_RE.match(body)
    if match is None:
        return None, f"body does not start with security/compliance: {body[:60]!r}"
    up, down = _reactions(obj) if with_reactions else (0, 0)
    return Comment(label=match.group(1).lower(), body=body, thumbs_up=up, thumbs_down=down), ""


def _scan_review_offdiff(
    review: object,
    requester: object,
    *,
    authors_lower: set[str],
    start: datetime,
    end: datetime,
    match_all_authors: bool = False,
) -> list[Comment]:
    """Parse a review body's off-diff findings and attach its summary-level reactions.

    The PR-review dispatcher cannot inline-anchor a finding whose line is outside the PR
    diff (GitHub rejects the entire review with HTTP 422), so it lists those findings in
    the review *body* under :data:`_OFFDIFF_HEADER`, one bullet each. Those bodies start
    with the dispatcher's prose summary, not the Conventional-Comment label, so
    :func:`_classify` skips them and the findings would otherwise go uncounted.

    Each bullet becomes one :class:`Comment` carrying a synthesised body (``label: title``
    plus a ``Severity:`` line) so the security module's existing label and severity
    aggregation works unchanged; per-finding reactions are not available, so they are zero.
    The review's own 👍/👎 -- the "was this review helpful" signal on the summary -- is
    fetched via GraphQL (REST does not expose reactions for reviews) and returned once as a
    single ``is_summary`` carrier comment labelled ``security``.

    :param review: A PyGithub ``PullRequestReview``.
    :param requester: The PyGithub ``Requester`` for the GraphQL reaction lookup.
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :param match_all_authors: When ``True``, accept any author and ignore ``authors_lower``.
    :returns: One comment per off-diff finding, plus a summary-reaction carrier if present.
    """
    body = getattr(review, "body", None)
    login = _login(review)
    when = getattr(review, "submitted_at", None)
    if not body or not _in_scope(
        login,
        when,
        authors_lower=authors_lower,
        start=start,
        end=end,
        match_all_authors=match_all_authors,
    ):
        return []

    out: list[Comment] = []
    header = body.find(_OFFDIFF_HEADER)
    if header != -1:
        for m in _OFFDIFF_BULLET_RE.finditer(body, header):
            label = m.group("label").lower()
            out.append(
                Comment(
                    label=label,
                    body=f"{label}: {m.group('title').strip()}\nSeverity: {m.group('sev').upper()}",
                    thumbs_up=0,
                    thumbs_down=0,
                )
            )

    up, down = _review_reactions(requester, getattr(review, "raw_data", None) or {})
    if up or down:
        out.append(
            Comment(label="security", body="", thumbs_up=up, thumbs_down=down, is_summary=True)
        )
    return out


def _review_reactions(requester: object, raw: dict) -> tuple[int, int]:
    """Return a review's ``(thumbs_up, thumbs_down)`` via GraphQL, or ``(0, 0)`` on failure.

    REST omits reactions for pull-request reviews (there is no reactions endpoint for
    them), so the summary-level 👍/👎 is only reachable through GraphQL -- ``PullRequestReview``
    implements the ``Reactable`` interface. A missing node id, a GraphQL/permission error,
    or a network failure degrades quietly to ``(0, 0)`` rather than aborting the scan.

    :param requester: The PyGithub ``Requester`` (``Github.requester``).
    :param raw: The review's ``raw_data`` (its ``node_id`` keys the GraphQL node lookup).
    :returns: ``(thumbs_up, thumbs_down)`` reaction totals on the review.
    """
    node_id = raw.get("node_id")
    if requester is None or not node_id:
        return 0, 0
    try:
        _, resp = requester.graphql_node(
            node_id, "reactionGroups { content users { totalCount } }", "PullRequestReview"
        )
    except Exception as exc:  # GraphQL / permission / network errors must not abort the scan.
        logger.debug("review reactions lookup failed for %s: %s", node_id, exc)
        return 0, 0
    node = ((resp or {}).get("data") or {}).get("node") or {}
    up = down = 0
    for group in node.get("reactionGroups") or []:
        total = int((group.get("users") or {}).get("totalCount") or 0)
        if group.get("content") == "THUMBS_UP":
            up = total
        elif group.get("content") == "THUMBS_DOWN":
            down = total
    return up, down


def _in_scope(
    login: str | None,
    when: datetime | None,
    *,
    authors_lower: set[str],
    start: datetime,
    end: datetime,
    match_all_authors: bool,
) -> bool:
    """Whether a comment/review passes the author and window gates (no label check).

    :param login: The author login, or ``None`` if absent.
    :param when: The creation/submission time, or ``None`` if absent.
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :param match_all_authors: When ``True``, accept any author and ignore ``authors_lower``.
    :returns: ``True`` when author (unless lifted) and window both pass.
    """
    if login is None or when is None:
        return False
    if not match_all_authors and login.lower() not in authors_lower:
        return False
    return start <= _as_utc(when) <= end


def _is_pull_comment(obj: object) -> bool:
    """Whether an issue comment belongs to a pull request (vs a plain issue).

    PR comments have an ``html_url`` containing ``/pull/``; plain-issue comments use
    ``/issues/``.
    """
    raw = getattr(obj, "raw_data", None) or {}
    return "/pull/" in (raw.get("html_url") or "")


def _login(obj: object) -> str | None:
    """Return ``obj.user.login`` if present."""
    user = getattr(obj, "user", None)
    return getattr(user, "login", None) if user is not None else None


def _reactions(obj: object) -> tuple[int, int]:
    """Return ``(thumbs_up, thumbs_down)`` from a comment's inline reaction summary."""
    raw = getattr(obj, "raw_data", None) or {}
    reactions = raw.get("reactions") or {}
    return int(reactions.get("+1", 0)), int(reactions.get("-1", 0))


def _as_utc(value: datetime) -> datetime:
    """Coerce a possibly-naive datetime to timezone-aware UTC for comparison."""
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
