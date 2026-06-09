# metricsai

A small, pluggable collector for **AI-in-SDLC metrics**. Each run gathers metrics from one
or more pluggable modules and reports a single **weekly row** to a Google Apps Script
webhook that fronts a Google Sheet.

## How it works

```
modules (build_pr, testing, security)  ─gather()─▶  merged key/value pairs
                                     │
                            MetricRow(week_ending_date, metrics)
                                     │
                            MetricsClient.post()  ─▶  Apps Script webhook ─▶ Google Sheet
```

- **Modules** each return plain key/value pairs, where keys map to spreadsheet columns.
- All registered modules run by default; `--module NAME` narrows the scope.
- The webhook receives one flat JSON object per run:
  `{"week_ending_date": "YYYY-MM-DD", <metric>: <value>, …}`.

See [Usage](usage.md) to run it and [Modules](modules.md) to add your own.

!!! note "Status"
    The `security` module is implemented (GitHub PR comments + AWS Security Hub); `build_pr`
    and `testing` are stubbed (zero values); and the Apps Script / Sheet are not built yet —
    use `--dry-run` to print the row without sending it.
