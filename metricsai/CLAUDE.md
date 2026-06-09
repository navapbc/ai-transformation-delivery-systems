# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

This project uses [uv](https://docs.astral.sh/uv/). All commands run through it.

```bash
uv sync                  # create venv + install (runtime + dev groups)
uv sync --group docs     # also install mkdocs (not installed by default)

uv run pytest                                   # all tests
uv run pytest tests/test_security.py            # one file
uv run pytest -k skip_sechub                    # match by name
uv run pytest tests/test_cli.py::test_list_modules   # one test

uv run ruff check .          # lint
uv run ruff format .         # format (also: uv run black .)
uv run mkdocs build          # build docs (requires --group docs)

uv run metricsai --dry-run                # run all modules, print row, no POST
uv run metricsai --list-modules
uv run metricsai --module security --repo owner/repo --skip-sechub --dry-run
```

**Git note:** this package lives in the `metricsai/` subdirectory of the `skillz` git repo
(whose root also holds unrelated `security/` and `security-old/` dirs — stage only
`metricsai/`). Git commands that write to `.git` fail under the command sandbox; run them
with the sandbox disabled.

## Architecture

A CLI that gathers AI-in-SDLC metrics from pluggable modules and POSTs one weekly row
(`week_ending_date` + one field per metric) to a Google Apps Script webhook.

**Pipeline (`cli.py::main`):** load `Settings` (env, `METRICSAI_` prefix) → apply CLI
overrides via `settings.model_copy(update=...)` → compute `week_ending_date` (default: most
recent Thursday) → build a `RunContext` (settings, a *lazy/cached* `get_github_token`, and the
week-ending date) → run the selected modules → merge their dicts into
`MetricRow(week_ending_date, metrics)` → `MetricsClient.post()` (or print on `--dry-run`).

**Module registry (`modules/__init__.py`):** modules subclass `MetricsModule`
(`base.py`) — a `name`, a `requires_github_token` flag, and `gather(ctx) -> dict[str,
MetricValue]` whose **keys are the exact spreadsheet column names**. Each built-in module
calls `register(...)` at import time and is imported in `modules/__init__.py` for that
side effect. `selected_modules(None)` returns all (sorted); `--module` narrows. To add a
module: subclass, `register()`, add the import. `build_pr` and `testing` are stubs (zeros);
`security` is live.

**`security` module is the real one.** It emits *both* the `security_*` and
`security_compliance_*` column families from a single GitHub comment scan, split by
Conventional-Comment label (`security` vs `compliance`), plus one AWS Security Hub count:
- `sources/github.py` (PyGithub): scans issue comments, inline review comments, and review
  submissions across `github_repos`, kept by author / week-window / `^(security|compliance)`
  body prefix; reactions and `Severity:` tags drive the counts. Repo-level `since=` listings
  are used; the per-PR review pass stops once PRs predate the window.
- `sources/aws.py` (boto3): paginated `securityhub get_findings` → `security_total_sechub_critical_high`.
- `skip_sechub` (`--skip-sechub` / `METRICSAI_SKIP_SECHUB`) omits the AWS call and that one
  column, so GitHub metrics still gather/post with no AWS creds.

**Secrets (`keychain.py`):** a generic `resolve_secret` (env → macOS keychain → TTY prompt)
backs `resolve_token` (GitHub, service `metricsai-github`) and `resolve_webhook_key` (webhook
key, service `metricsai-webhook`). Non-interactive contexts never prompt — they fail fast
with guidance. The webhook key is not needed for `--dry-run`.

**Webhook + Apps Script (`client.py`, `apps_script/Code.gs`):** the client POSTs flat JSON
`{week_ending_date, **metrics}` plus reserved body fields `_key` (API key) and `_tab` (tab),
and follows redirects (Apps Script 302s a POST to a googleusercontent URL). The Apps Script
aligns values to columns **by header name** (not order), appends missing columns
automatically, and **always returns HTTP 200** with an `{ok: ...}` body — so a bad key isn't
an HTTP error. Apps Script cannot read request headers, which is why the key is a body field.

**Errors:** operational failures (GitHub/AWS/network) raised during gathering are wrapped in
`GatherError` and reported as a clean one-line message with exit code 2 (`--debug` shows the
traceback). Config/usage errors (missing token/repos, unknown module) have their own exit-2
paths.

## Conventions & gotchas

- Pydantic v2 models/settings; extensive type hints; reStructuredText (`:param:`) docstrings;
  ruff + black at line length 100. Python `>=3.12`.
- `github_repos` / `github_authors` settings are stored as comma-separated **strings** (to
  avoid pydantic JSON-list env parsing); read them via `Settings.repos` / `.authors` or
  `config.csv_list`.
- `tmp/` is gitignored scratch holding the original shell scripts the `security` module was
  ported from — do not commit it. `site/` (mkdocs) and `.venv/` are also ignored; `uv.lock`
  is committed.
- Running under `srt` (optional sandbox): invoke `.venv/bin/metricsai` directly (`uv run`
  writes `~/.cache/uv`, which is blocked); keychain *writes* and AWS SSO token-cache writes
  are blocked, so bootstrap secrets / `aws sso login` unsandboxed first; allowlist
  `api.github.com`, `securityhub.<region>.amazonaws.com`, STS/SSO, and the Apps Script host.
- Week-ending weekday is configurable (`week_ending_day` setting / `--week-ending-day` /
  `METRICSAI_WEEK_ENDING_DAY`), default **Thursday**, giving a 7-day inclusive UTC window
  Fri 00:00:00Z–Thu 23:59:59Z (`models.default_week_ending` / `weekday_number` /
  `week_window`). Security Hub is single-region via boto3's default credential chain, which
  already honors env `AWS_SESSION_TOKEN` for temporary creds.
