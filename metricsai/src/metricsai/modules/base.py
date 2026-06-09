"""The metrics-module contract."""

from __future__ import annotations

from abc import ABC, abstractmethod

from metricsai.context import RunContext
from metricsai.models import MetricValue


class MetricsModule(ABC):
    """Base class for a pluggable metrics source.

    A module gathers a set of metrics and returns them as key/value pairs, where each key
    maps to a field (column) in the destination spreadsheet.

    :cvar name: Stable identifier used to select the module via ``--module``.
    :cvar requires_github_token: Whether :meth:`gather` needs the GitHub token resolved.
    """

    name: str
    requires_github_token: bool = False

    @abstractmethod
    def gather(self, ctx: RunContext) -> dict[str, MetricValue]:
        """Collect this module's metrics.

        :param ctx: The shared per-run context.
        :returns: Mapping of spreadsheet field name to value.
        """
        raise NotImplementedError
