"""Runtime configuration sourced from environment variables.

All settings use the ``METRICSAI_`` prefix, e.g. ``METRICSAI_WEBHOOK_URL``. The CLI may
override individual values (notably ``--url``, ``--repo``, ``--author``) at call time.
"""

from __future__ import annotations

from pydantic import HttpUrl, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

#: Default author whose review comments are counted as AI-generated.
DEFAULT_AUTHOR = "github-copilot[bot]"


def csv_list(value: str | None) -> list[str]:
    """Split a comma-separated configuration string into a clean list.

    :param value: Raw comma-separated string (may be ``None`` or empty).
    :returns: List of trimmed, non-empty items.
    """
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


class Settings(BaseSettings):
    """Environment-backed configuration.

    Comma-separated fields (``github_repos``, ``github_authors``) are kept as raw strings
    here and split with :func:`csv_list` at the point of use; this keeps environment
    parsing simple and avoids JSON-list quoting.

    :ivar webhook_url: Google Apps Script endpoint that receives the metrics row. May be
        ``None`` here and supplied later via the CLI ``--url`` flag.
    :ivar webhook_key: Optional static API key for the webhook, sent in the POST body. When
        set it takes precedence over the keychain (sandbox/CI fallback).
    :ivar webhook_keychain_service: Service name under which the webhook key is stored in
        the macOS keychain.
    :ivar webhook_tab: Optional destination tab (sheet) name; sent in the POST body so one
        deployment can feed multiple tabs.
    :ivar github_token: Optional GitHub token taken straight from the environment. When set
        it takes precedence over the keychain, which makes sandboxed/CI runs work without
        any keychain access.
    :ivar github_keychain_service: Service name under which the GitHub token is stored in
        the macOS keychain.
    :ivar github_base_url: GitHub REST API base URL. Defaults to github.com; set to
        ``https://<host>/api/v3`` for GitHub Enterprise.
    :ivar github_repos: Comma-separated ``owner/repo`` list to scan. Required for the
        security module (overridable with ``--repo``).
    :ivar github_authors: Comma-separated comment author logins to count as AI-generated.
    :ivar week_ending_day: Weekday that closes the reporting week (e.g. ``thursday`` /
        ``thu``). The query window is the 7 days ending on it.
    :ivar aws_region: Optional AWS region for Security Hub. When unset, boto3's default
        resolution (``AWS_REGION`` / active profile) is used.
    :ivar skip_sechub: When ``True``, the security module skips the AWS Security Hub query
        (and omits ``security_total_sechub_critical_high``) but still gathers and posts the
        GitHub-derived metrics.
    :ivar request_timeout: HTTP request timeout, in seconds.
    """

    model_config = SettingsConfigDict(env_prefix="METRICSAI_", extra="ignore")

    webhook_url: HttpUrl | None = None
    webhook_key: SecretStr | None = None
    webhook_keychain_service: str = "metricsai-webhook"
    webhook_tab: str | None = None
    github_token: SecretStr | None = None
    github_keychain_service: str = "metricsai-github"
    github_base_url: str = "https://api.github.com"
    github_repos: str = ""
    github_authors: str = DEFAULT_AUTHOR
    week_ending_day: str = "thursday"
    aws_region: str | None = None
    skip_sechub: bool = False
    request_timeout: float = 10.0

    @property
    def repos(self) -> list[str]:
        """Target repositories as a list."""
        return csv_list(self.github_repos)

    @property
    def authors(self) -> list[str]:
        """Comment authors to count, falling back to the default bot."""
        return csv_list(self.github_authors) or [DEFAULT_AUTHOR]
