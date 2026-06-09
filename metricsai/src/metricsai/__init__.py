"""metricsai -- pluggable collector for AI-in-SDLC metrics.

The package gathers metrics from one or more pluggable *modules* (``security`` is
implemented; ``build_pr`` and ``testing`` are stubs) and reports a single weekly row, keyed
by ``week_ending_date``, to a Google Apps Script webhook that fronts a Google Sheet.

:var __version__: Installed package version.
"""

from __future__ import annotations

__all__ = ["__version__"]

__version__ = "0.1.0"
