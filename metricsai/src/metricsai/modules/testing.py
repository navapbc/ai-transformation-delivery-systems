"""Testing / quality metrics module.

Emits the ``testing_classifier_*`` spreadsheet columns from a single scan of the AI
test-classifier's PR comments. The classifier posts one comment per CI run with findings,
each leading with the ``test-classifier:`` Conventional-Comment label and embedding a JSON
verdict block (one entry per failing test). We expand those into per-verdict records,
attach each comment's 👍/👎 reaction totals, and aggregate the week into:

* per-verdict counts (``app_bug`` / ``test_bug`` / ``flaky_failure`` / ``environment_issue``),
* total comment-level reactions, and
* the 👍-rate -- the classifier's tuning signal.

Source: :func:`metricsai.sources.github.fetch_classifier_comments`.
"""

from __future__ import annotations

from metricsai.context import RunContext
from metricsai.models import MetricValue, week_window
from metricsai.modules import register
from metricsai.modules.base import MetricsModule
from metricsai.sources.github import Classification, fetch_classifier_comments

#: Verdicts the classifier emits, mapped to their spreadsheet column suffix. Records whose
#: verdict is absent/unparseable (``""``) count toward the comment total but no bucket.
_VERDICT_COLUMNS = {
    "APPLICATION_BUG": "testing_classifier_app_bug",
    "TEST_BUG": "testing_classifier_test_bug",
    "FLAKY_FAILURE": "testing_classifier_flaky_failure",
    "ENVIRONMENT_ISSUE": "testing_classifier_environment_issue",
}


class TestingModule(MetricsModule):
    """Gathers AI test-classifier precision metrics."""

    name = "testing"
    requires_github_token = True

    def gather(self, ctx: RunContext) -> dict[str, MetricValue]:
        """Collect the classifier metrics for the reporting week.

        :param ctx: The shared per-run context.
        :returns: The ``testing_classifier_*`` key/value pairs.
        :raises ValueError: If no target repositories are configured.
        """
        settings = ctx.settings
        repos = settings.testing_repos
        if not repos:
            raise ValueError(
                "No repositories configured. Set METRICSAI_TESTING_GITHUB_REPOS "
                "(or METRICSAI_GITHUB_REPOS), or pass --repo."
            )

        start, end = week_window(ctx.week_ending_date)
        classifications = fetch_classifier_comments(
            token=ctx.get_github_token(),
            base_url=settings.github_base_url,
            repos=repos,
            authors=settings.testing_authors,
            start=start,
            end=end,
        )
        return _aggregate_classifications(classifications)


def _aggregate_classifications(records: list[Classification]) -> dict[str, MetricValue]:
    """Aggregate per-verdict records into the ``testing_classifier_*`` columns.

    The 👍-rate is rounded to one decimal and is ``0.0`` when there are no reactions, so the
    column is always numeric. Per-comment reactions are repeated across that comment's
    records, so reaction totals are summed over verdict entries exactly as the comments
    carry them.

    :param records: One entry per classification (see
        :class:`~metricsai.sources.github.Classification`).
    :returns: The ``testing_classifier_*`` metrics.
    """
    counts = dict.fromkeys(_VERDICT_COLUMNS.values(), 0)
    thumbs_up = 0
    thumbs_down = 0
    for record in records:
        thumbs_up += record.thumbs_up
        thumbs_down += record.thumbs_down
        column = _VERDICT_COLUMNS.get(record.verdict)
        if column is not None:
            counts[column] += 1

    total_reactions = thumbs_up + thumbs_down
    up_rate = round(100.0 * thumbs_up / total_reactions, 1) if total_reactions else 0.0

    return {
        "testing_classifier_total_classifications": len(records),
        "testing_classifier_thumbs_ups": thumbs_up,
        "testing_classifier_thumbs_downs": thumbs_down,
        "testing_classifier_thumbs_up_rate_pct": up_rate,
        **counts,
    }


register(TestingModule())
