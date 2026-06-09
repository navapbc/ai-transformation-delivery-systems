"""Security metrics module.

Emits every ``security_*`` and ``security_compliance_*`` spreadsheet column. The two
families come from a *single* scan of the AI reviewer's Conventional Comments, split by
label (``security`` vs ``compliance``), plus one AWS Security Hub findings count.

Sources:

* :func:`metricsai.sources.github.fetch_review_comments` -- the comment metrics.
* :func:`metricsai.sources.aws.count_failed_critical_high` -- the Security Hub count
  (``security_total_sechub_critical_high``).
"""

from __future__ import annotations

import logging
import re

from metricsai.config import csv_list
from metricsai.context import RunContext
from metricsai.models import MetricValue, week_window
from metricsai.modules import register
from metricsai.modules.base import MetricsModule
from metricsai.sources.aws import count_failed_critical_high
from metricsai.sources.github import Comment, fetch_review_comments

logger = logging.getLogger(__name__)

#: Severity tag inside a comment body, e.g. ``Severity: HIGH``.
_SEVERITY_RE = re.compile(r"Severity:\s*(CRITICAL|HIGH|MEDIUM|LOW)\b", re.IGNORECASE)

_SEVERITIES = ("critical", "high", "medium", "low")


class SecurityModule(MetricsModule):
    """Gathers code-security and IaC-compliance metrics."""

    name = "security"
    requires_github_token = True

    def gather(self, ctx: RunContext) -> dict[str, MetricValue]:
        """Collect the security and compliance metrics for the reporting week.

        :param ctx: The shared per-run context.
        :returns: The ``security_*`` and ``security_compliance_*`` key/value pairs.
        :raises ValueError: If no target repositories are configured.
        """
        settings = ctx.settings
        repos = csv_list(settings.github_repos)
        if not repos:
            raise ValueError(
                "No repositories configured. Set METRICSAI_GITHUB_REPOS or pass --repo."
            )

        start, end = week_window(ctx.week_ending_date)
        comments = fetch_review_comments(
            token=ctx.get_github_token(),
            base_url=settings.github_base_url,
            repos=repos,
            authors=settings.authors,
            start=start,
            end=end,
        )

        metrics = _aggregate_comments(comments)
        if settings.skip_sechub:
            logger.info("Skipping AWS Security Hub (skip_sechub set); omitting that column.")
        else:
            metrics["security_total_sechub_critical_high"] = count_failed_critical_high(
                start=start, end=end, region=settings.aws_region
            )
        return metrics


def _aggregate_comments(comments: list[Comment]) -> dict[str, MetricValue]:
    """Aggregate normalised comments into the comment-derived spreadsheet columns.

    :param comments: Normalised, already-filtered comments.
    :returns: The 14 comment-based ``security_*`` / ``security_compliance_*`` metrics.
    """
    buckets: dict[str, dict[str, int]] = {
        "security": _empty_bucket(),
        "compliance": _empty_bucket(),
    }
    for comment in comments:
        bucket = buckets[comment.label]
        bucket["total"] += 1
        bucket["up"] += comment.thumbs_up
        bucket["down"] += comment.thumbs_down
        match = _SEVERITY_RE.search(comment.body)
        if match is not None:
            bucket[match.group(1).lower()] += 1

    sec, comp = buckets["security"], buckets["compliance"]
    return {
        "security_total_security_comments": sec["total"],
        "security_thumbs_ups": sec["up"],
        "security_thumbs_downs": sec["down"],
        "security_critical": sec["critical"],
        "security_high": sec["high"],
        "security_medium": sec["medium"],
        "security_low": sec["low"],
        "security_compliance_total_comments": comp["total"],
        "security_compliance_thumbs_ups": comp["up"],
        "security_compliance_thumbs_down": comp["down"],
        "security_compliance_critical": comp["critical"],
        "security_compliance_high": comp["high"],
        "security_compliance_medium": comp["medium"],
        "security_compliance_low": comp["low"],
    }


def _empty_bucket() -> dict[str, int]:
    """Return a zeroed aggregation bucket."""
    return {"total": 0, "up": 0, "down": 0, **dict.fromkeys(_SEVERITIES, 0)}


register(SecurityModule())
