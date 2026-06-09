"""GitHub review-comment source, backed by PyGithub.

This is the Python port of ``pr_review_comments.sh``: it collects the AI reviewer's
*Conventional Comments* across a set of repositories and a time window, drawn from three
sources -- PR conversation (issue) comments, inline review comments, and review submission
bodies -- and normalises each into a :class:`Comment`.

Only comments are kept whose author is one of ``authors``, whose creation time falls within
``[start, end]``, and whose body begins with ``security`` or ``compliance`` (the
Conventional-Comment label). Thumbs-up/down reaction totals are read from the inline
reaction summary that GitHub returns with each comment; review submissions carry no
reactions.

Diagnostics: each repository logs a per-source ``fetched/matched`` summary at INFO
(``-v``), and every skipped comment logs its reason (author / window / label) at DEBUG
(``--debug``) -- so it is easy to see *why* a comment was or was not counted.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime

from github import Auth, Github

logger = logging.getLogger(__name__)

#: A body beginning (ignoring leading whitespace) with the Conventional-Comment label.
_LABEL_RE = re.compile(r"^\s*(security|compliance)", re.IGNORECASE)


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
) -> list[Comment]:
    """Fetch and normalise the AI reviewer's comments across ``repos`` within the window.

    :param token: GitHub token used for authentication.
    :param base_url: GitHub REST API base URL (github.com or an Enterprise host).
    :param repos: ``owner/repo`` identifiers to scan.
    :param authors: Comment author logins to keep (case-insensitive).
    :param start: Inclusive window start (timezone-aware UTC).
    :param end: Inclusive window end (timezone-aware UTC).
    :returns: The matching normalised comments.
    """
    gh = Github(base_url=base_url, auth=Auth.Token(token))
    authors_lower = {a.lower() for a in authors}
    out: list[Comment] = []
    for full_name in repos:
        logger.debug("Scanning %s", full_name)
        out.extend(
            _scan_repo(gh.get_repo(full_name), full_name, authors_lower, start=start, end=end)
        )
    return out


def _scan_repo(
    repo: object, full_name: str, authors_lower: set[str], *, start: datetime, end: datetime
) -> list[Comment]:
    """Scan one repository's three comment sources, with fetched/matched diagnostics.

    :param repo: A PyGithub ``Repository``.
    :param full_name: ``owner/repo`` (for log messages).
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
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
) -> tuple[Comment | None, str]:
    """Decide whether a raw comment counts, returning the reason when it does not.

    :param obj: A PyGithub comment/review object.
    :param when: Its creation/submission time.
    :param authors_lower: Lower-cased author logins to keep.
    :param start: Inclusive window start (UTC).
    :param end: Inclusive window end (UTC).
    :param with_reactions: Whether to read reaction totals (reviews carry none).
    :returns: ``(comment, "")`` on a match, or ``(None, reason)`` when skipped.
    """
    body = getattr(obj, "body", None)
    login = _login(obj)
    if not body or login is None or when is None:
        return None, "missing body, author, or timestamp"
    if login.lower() not in authors_lower:
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
