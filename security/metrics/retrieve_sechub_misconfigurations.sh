#!/usr/bin/env bash

# DEPRECATED: This script is superseded by `metricsai` (../../metricsai/README.md).
# Its `security` module gathers the same AWS Security Hub findings count and reports it as
# part of a single weekly row. Use metricsai instead; this script is retained for reference
# only and is no longer maintained.

aws securityhub get-findings \
    --filters '{
        "ComplianceStatus": [{"Value": "FAILED", "Comparison": "EQUALS"}],
        "CreatedAt": [{
            "Start": "2026-05-15T00:00:00Z",
            "End": "2026-05-21T11:59:59Z"
        }],
        "SeverityLabel": [
            {"Value": "CRITICAL", "Comparison": "EQUALS"},
            {"Value": "HIGH", "Comparison": "EQUALS"}
        ]
    }' \
    --output yaml |grep -c CreatedAt
