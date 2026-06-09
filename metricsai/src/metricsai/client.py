"""HTTP client that posts a metrics row to the Google Apps Script webhook."""

from __future__ import annotations

import json
import logging

import httpx

from metricsai.models import MetricRow

logger = logging.getLogger(__name__)

#: Body field carrying the static API key (stripped by the Apps Script before storing).
KEY_FIELD = "_key"

#: Body field selecting the destination tab (stripped by the Apps Script before storing).
TAB_FIELD = "_tab"


class MetricsClient:
    """Posts a :class:`~metricsai.models.MetricRow` to the configured webhook.

    The API key and (optional) destination tab travel in the POST body, alongside the
    metrics, under reserved keys the Apps Script removes before writing the row.

    :ivar webhook_url: Target Apps Script endpoint.
    :ivar webhook_key: Static API key sent in the body; ``None`` only for dry runs.
    :ivar tab: Optional destination tab name.
    :ivar timeout: Per-request timeout, in seconds.
    """

    def __init__(
        self,
        webhook_url: str,
        *,
        webhook_key: str | None = None,
        tab: str | None = None,
        timeout: float = 10.0,
    ) -> None:
        self.webhook_url = webhook_url
        self.webhook_key = webhook_key
        self.tab = tab
        self.timeout = timeout

    def post(self, row: MetricRow, *, dry_run: bool = False) -> None:
        """Send ``row`` to the webhook, or log it when ``dry_run`` is set.

        :param row: The metrics row to deliver.
        :param dry_run: When ``True``, print the payload and skip the network call. Useful
            while the Apps Script endpoint does not yet exist.
        :raises httpx.HTTPStatusError: If the webhook returns a non-success status.
        """
        payload = row.to_payload()
        if dry_run:
            label = f" (tab={self.tab})" if self.tab else ""
            logger.warning(
                "[dry-run] would POST to %s%s:\n%s", self.webhook_url, label, _pretty(payload)
            )
            return

        logger.info("Posting %d metric(s) to webhook.", len(row.metrics))
        logger.debug("Payload: %s", _pretty(payload))  # row only -- never logs the API key

        body = dict(payload)
        if self.tab:
            body[TAB_FIELD] = self.tab
        body[KEY_FIELD] = self.webhook_key or ""

        # Apps Script web apps answer a POST to /exec with a 302 to a
        # script.googleusercontent.com URL that serves the result, so redirects
        # must be followed to observe the final response.
        response = httpx.post(
            self.webhook_url, json=body, timeout=self.timeout, follow_redirects=True
        )
        response.raise_for_status()
        logger.info("Webhook responded %s.", response.status_code)


def _pretty(payload: dict[str, object]) -> str:
    """Return an indented JSON rendering of ``payload`` for logging."""
    return json.dumps(payload, indent=2, sort_keys=True, default=str)
