"""Command-line interface and run orchestration.

Typical use::

    metricsai --dry-run                 # run every module, print the row
    metricsai --module security         # run only the security module
    metricsai --url https://.../exec    # override the webhook URL
    metricsai --set-token               # store a GitHub token in the keychain
"""

from __future__ import annotations

import argparse
import logging
from datetime import date
from functools import lru_cache

from metricsai import __version__
from metricsai.client import MetricsClient
from metricsai.config import Settings
from metricsai.context import RunContext
from metricsai.keychain import TokenError, resolve_token, resolve_webhook_key, store_token
from metricsai.logging import setup_logging
from metricsai.models import MetricRow, MetricValue, default_week_ending, weekday_number
from metricsai.modules import REGISTRY, selected_modules

logger = logging.getLogger(__name__)


class GatherError(RuntimeError):
    """Wraps an operational failure (API/auth/network) raised while a module gathers.

    :ivar module_name: The module that failed.
    :ivar original: The underlying exception, preserved for ``--debug`` tracebacks.
    """

    def __init__(self, module_name: str, original: Exception) -> None:
        self.module_name = module_name
        self.original = original
        super().__init__(f"Failed gathering {module_name!r} metrics: {original}")


def _apply_overrides(settings: Settings, args: argparse.Namespace) -> Settings:
    """Return ``settings`` with any CLI overrides applied.

    :param settings: The environment-loaded settings.
    :param args: Parsed CLI arguments.
    :returns: A copy with ``--github-url`` / ``--repo`` / ``--author`` folded in, or the
        original when no overrides were given.
    """
    overrides: dict[str, object] = {}
    if args.github_url:
        overrides["github_base_url"] = args.github_url
    if args.repo:
        overrides["github_repos"] = ",".join(args.repo)
    if args.author:
        overrides["github_authors"] = ",".join(args.author)
    if args.week_ending_day:
        overrides["week_ending_day"] = args.week_ending_day
    if args.skip_sechub:
        overrides["skip_sechub"] = True
    return settings.model_copy(update=overrides) if overrides else settings


def build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser."""
    parser = argparse.ArgumentParser(
        prog="metricsai",
        description="Gather AI-in-SDLC metrics and report them to a Google Apps Script webhook.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument(
        "--url",
        help="Webhook URL (overrides METRICSAI_WEBHOOK_URL).",
    )
    parser.add_argument(
        "--tab",
        metavar="NAME",
        help="Destination spreadsheet tab (overrides METRICSAI_WEBHOOK_TAB).",
    )
    parser.add_argument(
        "--module",
        action="append",
        metavar="NAME",
        help="Run only this module (repeatable). Defaults to all registered modules.",
    )
    parser.add_argument(
        "--week-ending",
        type=date.fromisoformat,
        metavar="YYYY-MM-DD",
        help="Week-ending date for this run (defaults to the most recent week-ending day).",
    )
    parser.add_argument(
        "--week-ending-day",
        metavar="DAY",
        help="Weekday the reporting week closes on, e.g. 'friday' (overrides "
        "METRICSAI_WEEK_ENDING_DAY; default friday).",
    )
    parser.add_argument(
        "--github-url",
        metavar="URL",
        help="GitHub REST API base URL (overrides METRICSAI_GITHUB_BASE_URL).",
    )
    parser.add_argument(
        "--repo",
        action="append",
        metavar="OWNER/REPO",
        help="Repository to scan (repeatable; overrides METRICSAI_GITHUB_REPOS).",
    )
    parser.add_argument(
        "--author",
        action="append",
        metavar="LOGIN",
        help="Comment author to count as AI-generated (repeatable; overrides "
        "METRICSAI_GITHUB_AUTHORS).",
    )
    parser.add_argument(
        "--skip-sechub",
        action="store_true",
        help="Skip the AWS Security Hub query; still gather/post GitHub security metrics.",
    )
    parser.add_argument(
        "--list-modules",
        action="store_true",
        help="List registered modules and exit.",
    )
    parser.add_argument(
        "--set-token",
        action="store_true",
        help="Prompt for a GitHub token, store it in the keychain, and exit.",
    )
    parser.add_argument(
        "--set-webhook-key",
        action="store_true",
        help="Prompt for the webhook API key, store it in the keychain, and exit.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the payload instead of posting it.",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable INFO logging.")
    parser.add_argument("--debug", action="store_true", help="Enable DEBUG logging.")
    return parser


def _run_modules(names: list[str] | None, ctx: RunContext) -> dict[str, MetricValue]:
    """Run the selected modules and merge their metrics into one mapping.

    :param names: Module names from ``--module`` (``None`` selects all).
    :param ctx: The shared per-run context.
    :returns: The merged metric key/value pairs.
    """
    merged: dict[str, MetricValue] = {}
    for module in selected_modules(names):
        logger.info("Gathering metrics from %r.", module.name)
        try:
            gathered = module.gather(ctx)
        except (TokenError, ValueError):
            raise  # clear config/usage errors, reported distinctly by the caller
        except Exception as exc:  # operational: API / auth / network failures
            raise GatherError(module.name, exc) from exc
        for key, value in gathered.items():
            if key in merged:
                logger.warning(
                    "Metric key %r from %r overwrites an earlier value.", key, module.name
                )
            merged[key] = value
    return merged


def main(argv: list[str] | None = None) -> int:
    """CLI entry point.

    :param argv: Optional argument list (defaults to ``sys.argv``); aids testing.
    :returns: Process exit code (``0`` on success).
    """
    args = build_parser().parse_args(argv)
    setup_logging(verbose=args.verbose, debug=args.debug)

    settings = Settings()

    if args.list_modules:
        print("\n".join(sorted(REGISTRY)) or "(no modules registered)")
        return 0

    if args.set_token:
        return _store_secret(settings.github_keychain_service, "Enter GitHub token: ")

    if args.set_webhook_key:
        return _store_secret(settings.webhook_keychain_service, "Enter webhook API key: ")

    settings = _apply_overrides(settings, args)
    webhook_url = args.url or (str(settings.webhook_url) if settings.webhook_url else None)
    try:
        week_ending_date = args.week_ending or default_week_ending(
            weekday=weekday_number(settings.week_ending_day)
        )
    except ValueError as exc:
        logger.error("%s", exc)
        return 2

    # Resolve the GitHub token lazily and at most once, so modules that don't need it never
    # touch the keychain. Prompting is allowed here (the gather path is interactive use).
    @lru_cache(maxsize=1)
    def get_github_token() -> str:
        return resolve_token(settings, interactive=True)

    ctx = RunContext(
        settings=settings,
        get_github_token=get_github_token,
        week_ending_date=week_ending_date,
    )

    try:
        metrics = _run_modules(args.module, ctx)
    except KeyError as exc:
        logger.error("%s", exc.args[0] if exc.args else exc)
        return 2
    except (TokenError, ValueError) as exc:
        logger.error("%s", exc)
        return 2
    except GatherError as exc:
        logger.error("%s", exc)
        if args.debug:
            logger.debug("Traceback:", exc_info=exc.original)
        return 2

    row = MetricRow(week_ending_date=week_ending_date, metrics=metrics)
    tab = args.tab or settings.webhook_tab

    if args.dry_run:
        MetricsClient(webhook_url or "", tab=tab, timeout=settings.request_timeout).post(
            row, dry_run=True
        )
        return 0

    if webhook_url is None:
        logger.error("No webhook URL. Pass --url or set METRICSAI_WEBHOOK_URL (or use --dry-run).")
        return 2
    try:
        webhook_key = resolve_webhook_key(settings, interactive=True)
    except TokenError as exc:
        logger.error("%s", exc)
        return 2

    client = MetricsClient(
        webhook_url, webhook_key=webhook_key, tab=tab, timeout=settings.request_timeout
    )
    client.post(row)
    return 0


def _store_secret(service: str, prompt: str) -> int:
    """Prompt for a secret and store it in the keychain under ``service``.

    :param service: Keychain service name.
    :param prompt: Prompt text shown to the user.
    :returns: Process exit code.
    """
    import getpass
    import sys

    if not sys.stdin.isatty():
        logger.error("Storing a secret requires an interactive terminal.")
        return 2
    secret = getpass.getpass(prompt)
    if not secret:
        logger.error("No value entered.")
        return 2
    store_token(service, secret)
    print(f"Stored secret in keychain service {service!r}.")
    return 0
