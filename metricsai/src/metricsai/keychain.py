"""macOS keychain helpers for the secrets metricsai needs.

Two secrets are resolved the same way: the GitHub token and the webhook API key. Resolution
order for each:

#. The value from the environment (the sandbox/CI fallback).
#. The macOS keychain entry for the configured service.
#. An interactive prompt that stores the entered value in the keychain -- but only when
   running interactively on a TTY. In any non-interactive context (cron, CI, a sandbox) a
   clear error is raised instead of blocking on input.

Reading the keychain works inside ``srt`` (its sandbox profile allows the
``com.apple.SecurityServer`` Mach lookup); writing to the keychain does not, so storing a
value via :func:`store_token` should be run unsandboxed.
"""

from __future__ import annotations

import getpass
import logging
import sys

import keyring

from metricsai.config import Settings

logger = logging.getLogger(__name__)

_ACCOUNT = "token"


class TokenError(RuntimeError):
    """Raised when a required secret cannot be resolved without blocking on input."""


def store_token(service: str, token: str) -> None:
    """Persist ``token`` in the macOS keychain under ``service``.

    :param service: Keychain service name.
    :param token: The secret to store.
    """
    keyring.set_password(service, _ACCOUNT, token)
    logger.info("Stored secret in keychain service %r.", service)


def resolve_secret(
    *,
    env_value: str | None,
    service: str,
    prompt_label: str,
    missing_help: str,
    interactive: bool,
) -> str:
    """Resolve a secret from the environment, the keychain, or an interactive prompt.

    :param env_value: Value supplied via the environment (highest priority), or ``None``.
    :param service: Keychain service name to read/write.
    :param prompt_label: Prompt shown when reading a missing value interactively.
    :param missing_help: Error message used when no value is found non-interactively.
    :param interactive: When ``True`` and stdin is a TTY, prompt for and store a missing
        value. When ``False``, raise :class:`TokenError` rather than block on input.
    :returns: The resolved secret.
    :raises TokenError: If no value is found and prompting is not possible.
    """
    if env_value is not None:
        logger.debug("Using secret from environment for service %r.", service)
        return env_value

    stored = keyring.get_password(service, _ACCOUNT)
    if stored is not None:
        logger.debug("Using secret from keychain service %r.", service)
        return stored

    if interactive and sys.stdin.isatty():
        entered = getpass.getpass(prompt_label)
        if not entered:
            raise TokenError("No value entered.")
        store_token(service, entered)
        return entered

    raise TokenError(missing_help)


def resolve_token(settings: Settings, *, interactive: bool) -> str:
    """Resolve the GitHub token.

    :param settings: Loaded configuration providing the env token and keychain service.
    :param interactive: Whether interactive prompting is permitted.
    :returns: The resolved GitHub token.
    :raises TokenError: If no token is found and prompting is not possible.
    """
    env_value = settings.github_token.get_secret_value() if settings.github_token else None
    service = settings.github_keychain_service
    return resolve_secret(
        env_value=env_value,
        service=service,
        prompt_label=f"Enter GitHub token (stored in keychain {service!r}): ",
        missing_help=(
            "No GitHub token available. Run `metricsai --set-token` in an interactive "
            "terminal (outside any sandbox), or set the METRICSAI_GITHUB_TOKEN environment "
            "variable."
        ),
        interactive=interactive,
    )


def resolve_webhook_key(settings: Settings, *, interactive: bool) -> str:
    """Resolve the webhook API key.

    :param settings: Loaded configuration providing the env key and keychain service.
    :param interactive: Whether interactive prompting is permitted.
    :returns: The resolved webhook key.
    :raises TokenError: If no key is found and prompting is not possible.
    """
    env_value = settings.webhook_key.get_secret_value() if settings.webhook_key else None
    service = settings.webhook_keychain_service
    return resolve_secret(
        env_value=env_value,
        service=service,
        prompt_label=f"Enter webhook API key (stored in keychain {service!r}): ",
        missing_help=(
            "No webhook key available. Run `metricsai --set-webhook-key` in an interactive "
            "terminal (outside any sandbox), or set the METRICSAI_WEBHOOK_KEY environment "
            "variable (or use --dry-run)."
        ),
        interactive=interactive,
    )
