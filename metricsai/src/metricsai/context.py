"""The per-run context handed to each metrics module."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import date

from metricsai.config import Settings


@dataclass(frozen=True)
class RunContext:
    """Shared state passed to :meth:`~metricsai.modules.base.MetricsModule.gather`.

    :ivar settings: Loaded configuration.
    :ivar get_github_token: Lazily resolves the GitHub token on first use, so modules that
        do not need it never trigger a keychain lookup or prompt. The resolved value is
        cached for the duration of the run.
    :ivar week_ending_date: The Thursday that closes the reporting week. Modules derive their
        query window from it via :func:`~metricsai.models.week_window`.
    """

    settings: Settings
    get_github_token: Callable[[], str]
    week_ending_date: date
