"""Enable ``python -m metricsai`` as an alias for the console script."""

from __future__ import annotations

from metricsai.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
