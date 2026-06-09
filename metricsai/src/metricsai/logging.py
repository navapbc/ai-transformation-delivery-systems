"""Logging configuration for the CLI.

Two opt-in verbosity levels are supported:

* ``--verbose`` raises the root level to ``INFO``.
* ``--debug`` raises it to ``DEBUG`` and switches to a richer, source-annotated format.
"""

from __future__ import annotations

import logging

_PLAIN_FORMAT = "%(message)s"
_DEBUG_FORMAT = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"


def setup_logging(*, verbose: bool = False, debug: bool = False) -> None:
    """Configure root logging based on the chosen verbosity.

    :param verbose: Emit ``INFO`` level records.
    :param debug: Emit ``DEBUG`` level records with a detailed format. Implies ``verbose``.
    """
    if debug:
        level, fmt = logging.DEBUG, _DEBUG_FORMAT
    elif verbose:
        level, fmt = logging.INFO, _PLAIN_FORMAT
    else:
        level, fmt = logging.WARNING, _PLAIN_FORMAT

    logging.basicConfig(level=level, format=fmt, force=True)
