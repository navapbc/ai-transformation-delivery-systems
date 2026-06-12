# Modules

A **module** is a pluggable metrics source. Each module returns plain key/value pairs, where
every key maps to a field (column) in the destination spreadsheet. The CLI merges the output
of every selected module into one row.

## The contract

::: metricsai.modules.base.MetricsModule

## Registry

Modules register themselves at import time and are discovered through the registry.

::: metricsai.modules.register

::: metricsai.modules.selected_modules

## Adding a module

1. Subclass `MetricsModule`, set `name`, and implement `gather`.
2. Call `register(YourModule())` at import time.
3. Import the new module from `src/metricsai/modules/__init__.py` so it self-registers.

```python
from metricsai.context import RunContext
from metricsai.models import MetricValue
from metricsai.modules import register
from metricsai.modules.base import MetricsModule


class DeployModule(MetricsModule):
    name = "deploy"
    requires_github_token = True

    def gather(self, ctx: RunContext) -> dict[str, MetricValue]:
        token = ctx.get_github_token()
        ...
        return {"deploy_frequency_per_week": 0}


register(DeployModule())
```

## Built-in modules

All registered modules run by default; each owns the spreadsheet columns under its name
prefix. `security` and `testing` are implemented; `build_pr` is a stub.

### build_pr

::: metricsai.modules.build_pr.BuildPrModule

### testing

::: metricsai.modules.testing.TestingModule

### security

Implemented. Emits both the `security_*` and `security_compliance_*` columns from a single
scan of the AI reviewer's Conventional Comments (split by `security` / `compliance` label),
plus an AWS Security Hub findings count. Backed by the data sources below.

::: metricsai.modules.security.SecurityModule

## Data sources

::: metricsai.sources.github.fetch_review_comments

::: metricsai.sources.aws.count_failed_critical_high
