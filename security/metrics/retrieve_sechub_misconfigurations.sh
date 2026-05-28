#!/bin/bash

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
