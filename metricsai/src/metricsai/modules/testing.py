"""Testing / quality metrics module (stub).

Emits the ``testing_quality_*`` spreadsheet columns. Values are placeholders for now.

.. todo::
   Source these from the GitHub API / CI, e.g. the thumbs-up rate on AI test-suggestion
   comments, the merge rate of accepted suggestions, and time to workflow-run completion.
   Set :pyattr:`requires_github_token` to ``True`` when implemented.
"""

from __future__ import annotations

from metricsai.context import RunContext
from metricsai.models import MetricValue
from metricsai.modules import register
from metricsai.modules.base import MetricsModule


class TestingModule(MetricsModule):
    """Gathers testing / quality metrics (currently stubbed)."""

    name = "testing"
    requires_github_token = False

    def gather(self, ctx: RunContext) -> dict[str, MetricValue]:
        """Return placeholder testing/quality metrics.

        :param ctx: The shared per-run context (unused while stubbed).
        :returns: Stub metric key/value pairs keyed by spreadsheet column.
        """
        return {
            "testing_quality_comment_thumbs_up_rate_pct": 0.0,
            "testing_quality_suggestion_merge_rate_pct": 0.0,
            "testing_quality_time_to_workflow_run_completion": 0.0,
        }


register(TestingModule())
