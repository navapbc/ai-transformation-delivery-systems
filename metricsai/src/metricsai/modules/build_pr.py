"""Build / pull-request metrics module (stub).

Emits the ``build_pr_*`` spreadsheet columns. Values are placeholders for now.

.. todo::
   Source these from the GitHub API, e.g. average PR cycle time, the share of PRs that are
   AI-generated, and PR comment counts. Set :pyattr:`requires_github_token` to ``True``
   when implemented.
"""

from __future__ import annotations

from metricsai.context import RunContext
from metricsai.models import MetricValue
from metricsai.modules import register
from metricsai.modules.base import MetricsModule


class BuildPrModule(MetricsModule):
    """Gathers build / pull-request metrics (currently stubbed)."""

    name = "build_pr"
    requires_github_token = False

    def gather(self, ctx: RunContext) -> dict[str, MetricValue]:
        """Return placeholder build/PR metrics.

        :param ctx: The shared per-run context (unused while stubbed).
        :returns: Stub metric key/value pairs keyed by spreadsheet column.
        """
        return {
            "build_pr_avg_cycle_time_days": 0.0,
            "build_pr_ai_gen_pr_rate_pct": 0.0,
            "build_pr_num_comments": 0,
        }


register(BuildPrModule())
