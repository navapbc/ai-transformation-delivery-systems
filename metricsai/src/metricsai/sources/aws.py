"""AWS Security Hub source, backed by boto3.

Python port of ``retrieve_sechub_misconfigurations.sh``: count the FAILED Security Hub
findings of CRITICAL or HIGH severity created within the reporting window.

Credentials and region come from boto3's default resolution chain (environment,
``~/.aws/credentials`` / ``~/.aws/config`` profiles, SSO cache, or an assumed role). Pass
``region`` to pin one explicitly.
"""

from __future__ import annotations

import logging
from datetime import datetime

import boto3

logger = logging.getLogger(__name__)


def count_failed_critical_high(*, start: datetime, end: datetime, region: str | None = None) -> int:
    """Count FAILED CRITICAL/HIGH Security Hub findings created in ``[start, end]``.

    :param start: Inclusive window start (timezone-aware UTC).
    :param end: Inclusive window end (timezone-aware UTC).
    :param region: Optional AWS region; when ``None``, boto3's default region applies.
    :returns: The number of matching findings (paginated across all result pages).
    """
    client = boto3.client("securityhub", region_name=region)
    filters = {
        "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}],
        "CreatedAt": [{"Start": _iso(start), "End": _iso(end)}],
        "SeverityLabel": [
            {"Value": "CRITICAL", "Comparison": "EQUALS"},
            {"Value": "HIGH", "Comparison": "EQUALS"},
        ],
    }
    total = 0
    paginator = client.get_paginator("get_findings")
    for page in paginator.paginate(Filters=filters):
        total += len(page.get("Findings", []))
    logger.debug("Security Hub FAILED CRITICAL/HIGH findings: %d", total)
    return total


def _iso(value: datetime) -> str:
    """Format a datetime as the ``YYYY-MM-DDTHH:MM:SSZ`` string the API expects."""
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")
