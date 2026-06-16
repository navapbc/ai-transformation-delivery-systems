"""GitHub review-comment source, backed by PyGithub.

This is the Python port of ``pr_review_comments.sh``: it collects the AI reviewer's
*Conventional Comments* across a set of repositories and a time window, drawn from three
sources -- PR conversation (issue) comments, inline review comments, and review submission
bodies -- and normalises each into a :class:`Comment`.

Only comments are kept whose author is one of ``authors`` (unless ``match_all_authors`` is
set, which accepts any author), whose creation time falls within ``[start, end]``, and whose
body begins with ``security`` or ``compliance`` (the Conventional-Comment label).
Thumbs-up/down reaction totals are read from the inline reaction summary that GitHub returns
with each comment; review submissions carry no reactions.

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
    """

    label: str
    body: str
    thumbs_up: int
    thumbs_down: int


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
) -> list[Comment]:
    """Scan one repository's three comment sources, with fetched/matched diagnostics.

    :param repo: A PyGithub ``Repository``.
    :param full_name: ``owner/repo`` (for log messages).
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :param match_all_authors: When ``True``, accept any author and ignore ``authors_lower``.
    :returns: The matching comments from this repository.
    """
    matched: list[Comment] = []
    counts: dict[str, list[int]] = {"issue": [0, 0], "review": [0, 0], "submission": [0, 0]}

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
