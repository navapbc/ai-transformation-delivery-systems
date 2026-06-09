# metricsai

A small, pluggable collector for **AI-in-SDLC metrics**. Each run gathers metrics from one
or more pluggable modules and reports a single weekly row — `week_ending_date` plus one
field per metric — to a Google Apps Script webhook that fronts a Google Sheet.

The design goal is simplicity: one row per week, one field per metric, modules that each
return plain key/value pairs whose keys are exactly the spreadsheet columns.

> **Status:** the `security` module is implemented (GitHub PR comments + AWS Security Hub);
> `build_pr` and `testing` still return placeholder (zero) values; and the Google Apps
> Script / Sheet are not built yet. Use `--dry-run` to print the row without sending it.

## Modules and spreadsheet columns

All registered modules run by default; each owns the columns under its prefix. `--module
NAME` (repeatable) narrows the scope.

| Module      | Status | Spreadsheet columns                                                                                                                                                  |
| ----------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _(row key)_ | —      | `week_ending_date`                                                                                                                                                   |
| `build_pr`  | stub   | `build_pr_avg_cycle_time_days`, `build_pr_ai_gen_pr_rate_pct`, `build_pr_num_comments`                                                                               |
| `testing`   | stub   | `testing_quality_comment_thumbs_up_rate_pct`, `testing_quality_suggestion_merge_rate_pct`, `testing_quality_time_to_workflow_run_completion`                         |
| `security`  | live   | `security_total_security_comments`, `security_thumbs_ups`, `security_thumbs_downs`, `security_critical`, `security_high`, `security_medium`, `security_low`, `security_total_sechub_critical_high`, and the `security_compliance_*` columns below |

The `security` module emits **both** the `security_*` and `security_compliance_*` families:
they come from one scan of the AI reviewer's [Conventional
Comments](https://conventionalcomments.org/), split by label (`security` vs `compliance`),
plus one AWS Security Hub findings count. The `security_compliance_*` columns are:
`security_compliance_total_comments`, `security_compliance_thumbs_ups`,
`security_compliance_thumbs_down`, `security_compliance_critical`,
`security_compliance_high`, `security_compliance_medium`, `security_compliance_low`.

## Prerequisites

- **macOS** (the GitHub token is stored in the macOS Keychain).
- **Python ≥ 3.12**.
- **[uv](https://docs.astral.sh/uv/)** — `brew install uv`.
- A **GitHub fine-grained personal access token** for the repos you want to scan (see
  [GitHub access token](#github-access-token)).
- **AWS credentials** with Security Hub read access, resolvable by boto3's default chain
  (env vars, an `~/.aws` profile, SSO, or a role). Needed for the `security` module unless
  you pass `--skip-sechub` (or set `METRICSAI_SKIP_SECHUB`), which gathers only the GitHub
  metrics and leaves `security_total_sechub_critical_high` blank.

## Install

```bash
git clone https://github.com/navapbc/metricsai.git
cd metricsai
uv sync
```

`uv sync` creates a virtual environment and installs the package with its dependencies.

## Usage

Run every registered module and print the row without sending it:

```bash
uv run metricsai --dry-run
```

Other common invocations:

```bash
uv run metricsai --list-modules                 # show registered modules
uv run metricsai --module security --dry-run    # run a single module
uv run metricsai --repo navapbc/strata --repo navapbc/oscer --dry-run   # scan these repos
uv run metricsai --author "github-copilot[bot]" # count this author's comments (repeatable)
uv run metricsai --github-url https://ghe.example.com/api/v3            # GitHub Enterprise
uv run metricsai --module security --skip-sechub --dry-run   # GitHub-only (no AWS call)
uv run metricsai --week-ending 2026-06-07       # set the row's week-ending date
uv run metricsai --url https://script.google.com/.../exec --tab Metrics   # post to a tab
uv run metricsai --set-token                    # store the GitHub token in the keychain
uv run metricsai --set-webhook-key              # store the webhook key in the keychain
uv run metricsai --dry-run -v                   # INFO logging
uv run metricsai --dry-run --debug              # DEBUG logging (full payload + sources)
```

The row is keyed by `week_ending_date`, which defaults to the most recent Thursday (the
reporting week runs Friday 00:00:00Z through Thursday 23:59:59Z) and can be overridden with
`--week-ending YYYY-MM-DD`. Change the week-ending weekday with `--week-ending-day`
(e.g. `sunday`) or `METRICSAI_WEEK_ENDING_DAY`.

By default **all registered modules run**; `--module NAME` (repeatable) narrows the scope.

### First-run secrets

Two secrets — the **GitHub token** (for the `security` module) and the **webhook key** (to
POST) — are each resolved the same way:

1. The environment variable (`METRICSAI_GITHUB_TOKEN` / `METRICSAI_WEBHOOK_KEY`).
2. The macOS Keychain (services `metricsai-github` / `metricsai-webhook`).
3. An interactive prompt (TTY only) that stores what you type in the Keychain.

In a non-interactive context (CI, cron, a sandbox) steps 1–2 are tried and, if both miss,
the run fails with a clear message instead of blocking. Bootstrap the keychain once with
`uv run metricsai --set-token` and `uv run metricsai --set-webhook-key`. (The webhook key is
not needed for `--dry-run`.)

## Destination webhook

The bundled Google Apps Script in [`apps_script/`](./apps_script/) is a ready-to-deploy
endpoint that appends each posted row to a tab in a Google Sheet, authenticated by a static
API key (sent in the request body) and with per-request tab selection. It ships with the
least-privilege `spreadsheets.currentonly` OAuth scope, so it can access **only the sheet
it's bound to** — not all your spreadsheets. See [`apps_script/README.md`](./apps_script/README.md)
for setup (including keeping that scope), a `curl` example, and how to feed different tabs of
one sheet. Once deployed, set `METRICSAI_WEBHOOK_URL` to its `/exec` URL and store the key
with `uv run metricsai --set-webhook-key` (or `METRICSAI_WEBHOOK_KEY`).

## Configuration

All settings use the `METRICSAI_` prefix.

| Variable                            | Default              | Description                                                                 |
| ----------------------------------- | -------------------- | --------------------------------------------------------------------------- |
| `METRICSAI_WEBHOOK_URL`             | _(none)_             | Apps Script endpoint. Overridable with `--url`.                             |
| `METRICSAI_WEBHOOK_KEY`             | _(none)_             | Webhook API key (sent in the body); takes precedence over the keychain.     |
| `METRICSAI_WEBHOOK_KEYCHAIN_SERVICE`| `metricsai-webhook`  | Keychain service name for the webhook key.                                  |
| `METRICSAI_WEBHOOK_TAB`             | _(none)_             | Destination spreadsheet tab. Overridable with `--tab`.                      |
| `METRICSAI_GITHUB_TOKEN`            | _(none)_             | GitHub token; takes precedence over the keychain.                           |
| `METRICSAI_GITHUB_KEYCHAIN_SERVICE` | `metricsai-github`   | Keychain service name for the GitHub token.                                 |
| `METRICSAI_GITHUB_BASE_URL`         | `https://api.github.com` | GitHub REST base URL. For Enterprise use `https://<host>/api/v3`. (`--github-url`) |
| `METRICSAI_GITHUB_REPOS`            | _(none)_             | Comma-separated `owner/repo` list to scan. Required by `security`. (`--repo`) |
| `METRICSAI_GITHUB_AUTHORS`          | `github-copilot[bot]` | Comma-separated comment authors counted as AI-generated. (`--author`)      |
| `METRICSAI_WEEK_ENDING_DAY`         | `thursday`           | Weekday the reporting week closes on (name or abbrev). `--week-ending-day`   |
| `METRICSAI_AWS_REGION`              | _(boto3 default)_    | AWS region for Security Hub. Falls back to `AWS_REGION` / active profile.   |
| `METRICSAI_SKIP_SECHUB`             | `false`              | Skip the AWS Security Hub query (GitHub metrics still gather/post). `--skip-sechub` |
| `METRICSAI_REQUEST_TIMEOUT`         | `10.0`               | HTTP request timeout (seconds).                                             |

AWS credentials themselves come from boto3's standard resolution (env `AWS_*`, `~/.aws`
profiles, SSO, or a role) — set `AWS_PROFILE` / `AWS_REGION` as usual. Temporary/STS
credentials work automatically: if `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_SESSION_TOKEN` are already set in the environment, boto3 uses them.

### GitHub access token

The `security` module needs to read PR comments and reactions on the target repos. Create a
**fine-grained** PAT scoped for least privilege:

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens →
   Generate new token**.
2. **Resource owner:** the org/owner of the repos. **Repository access:** *Only select
   repositories* — pick exactly the repos you scan.
3. **Repository permissions** (all *Read-only*):
   - **Metadata** — Read (mandatory).
   - **Pull requests** — Read (inline review comments, reviews).
   - **Issues** — Read (PR conversation comments are issue comments).
   - No other permissions; no account/organization permissions.
4. Store it: `uv run metricsai --set-token` (keychain) or export `METRICSAI_GITHUB_TOKEN`.

The same token is used for github.com and GitHub Enterprise (set `--github-url` /
`METRICSAI_GITHUB_BASE_URL` for the latter).

### Troubleshooting: zero security comment counts

A comment is counted only if **all three** hold — so a manual test often shows zeros:

1. **Author** is in `--author` / `METRICSAI_GITHUB_AUTHORS` (default `github-copilot[bot]`).
   Comments you wrote yourself won't count unless you add your own login.
2. **Created within the window** — the 7 days ending on `week_ending_date`. Comments from
   *today* are excluded unless `week_ending_date` covers today (`--week-ending`).
3. **Body starts with** `security` or `compliance` (Conventional-Comments style).

Run with `-v` for a per-repo `fetched/matched` summary, or `--debug` to log the skip reason
(author / window / label) for every comment:

```
github owner/repo: issue 0/0, review 3/1, submission 1/0 (fetched/matched)
owner/repo [review] skipped: author 'you' not in configured authors
```

## Extending: add a module

1. Subclass `MetricsModule` in `src/metricsai/modules/`, set `name`, implement `gather`.
2. `register(YourModule())` at import time.
3. Import it from `src/metricsai/modules/__init__.py` so it self-registers.

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

## Optional: run isolated with `srt`

`metricsai` has **no dependency** on any sandbox — plain `uv run metricsai …` is the norm.
If you want OS-level isolation on macOS you can wrap it in
[`@anthropic-ai/sandbox-runtime`](https://www.npmjs.com/package/@anthropic-ai/sandbox-runtime)
(`srt`):

- Keychain **reads** work inside `srt`. Keychain **writes** do not — run `--set-token` and
  `--set-webhook-key` (or set `METRICSAI_GITHUB_TOKEN` / `METRICSAI_WEBHOOK_KEY`) outside the
  sandbox first.
- **AWS credentials:** boto3 *reads* `~/.aws/credentials` / `~/.aws/config` fine in-sandbox,
  so static keys and profiles work. But **AWS SSO token refresh writes** to
  `~/.aws/sso/cache`, which the sandbox blocks — run `aws sso login` outside `srt` first
  (cached tokens are readable in-sandbox until they expire).
- **Network egress** is restricted — allowlist your hosts in `~/.srt-settings.json`:
  `api.github.com` (or your Enterprise host), `securityhub.<region>.amazonaws.com`, the
  STS/SSO endpoints if you assume roles or use SSO, and your Apps Script host.

```bash
uv run metricsai --set-token                      # bootstrap GitHub token, unsandboxed
uv run metricsai --set-webhook-key                # bootstrap webhook key, unsandboxed
aws sso login                                      # if using SSO, also unsandboxed
uv sync                                            # ensure the venv is built
srt -c ".venv/bin/metricsai --dry-run"            # then run isolated
```

> Inside `srt`, call the installed `.venv/bin/metricsai` script directly rather than
> `uv run …` — `uv run` writes to `~/.cache/uv`, which the sandbox blocks (allowlist that
> path in `~/.srt-settings.json` if you prefer `uv run`).

For Linux/CI, a container (optionally with gVisor's `runsc`) is a better fit; inject the
GitHub token via `METRICSAI_GITHUB_TOKEN` and AWS creds via the environment or a role.

## Development

```bash
uv run pytest                 # unit tests
uv run ruff check .           # lint
uv run ruff format .          # format (and `uv run black .`)
uv run mkdocs serve           # docs at http://127.0.0.1:8000
```
