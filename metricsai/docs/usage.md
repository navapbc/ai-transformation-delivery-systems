# Usage

## Running

```bash
uv run metricsai --dry-run                 # run all modules, print the row offline
uv run metricsai --list-modules            # list registered modules
uv run metricsai --module security --dry-run
uv run metricsai --repo owner/repo --repo owner/other   # repos to scan (repeatable)
uv run metricsai --author "github-copilot[bot]"         # AI comment author (repeatable)
uv run metricsai --github-url https://ghe.example.com/api/v3   # GitHub Enterprise
uv run metricsai --week-ending 2026-06-07  # set the row's week-ending date
uv run metricsai --url https://script.google.com/.../exec --tab Metrics
uv run metricsai --set-webhook-key         # store the webhook key in the keychain
uv run metricsai --dry-run -v              # INFO logging
uv run metricsai --dry-run --debug         # DEBUG logging
```

All registered modules run by default; pass `--module NAME` (repeatable) to narrow scope.
The row is keyed by `week_ending_date` (default: most recent Thursday; the query window is
the 7 days ending on it, Fri 00:00:00Z through Thu 23:59:59Z).

## Configuration

All settings use the `METRICSAI_` prefix and may be set in the environment.

| Variable                            | Default                  | Description                                                          |
| ----------------------------------- | ------------------------ | ------------------------------------------------------------------- |
| `METRICSAI_WEBHOOK_URL`             | _(none)_                 | Apps Script endpoint. Overridable with `--url`.                     |
| `METRICSAI_WEBHOOK_KEY`             | _(none)_                 | Webhook API key (sent in the body); precedence over the keychain.   |
| `METRICSAI_WEBHOOK_KEYCHAIN_SERVICE`| `metricsai-webhook`      | Keychain service name for the webhook key.                          |
| `METRICSAI_WEBHOOK_TAB`             | _(none)_                 | Destination spreadsheet tab. Overridable with `--tab`.              |
| `METRICSAI_GITHUB_TOKEN`            | _(none)_                 | GitHub token; takes precedence over the keychain.                   |
| `METRICSAI_GITHUB_KEYCHAIN_SERVICE` | `metricsai-github`       | Keychain service name for the GitHub token.                         |
| `METRICSAI_GITHUB_BASE_URL`         | `https://api.github.com` | GitHub REST base URL (Enterprise: `https://<host>/api/v3`). `--github-url` |
| `METRICSAI_GITHUB_REPOS`            | _(none)_                 | Comma-separated `owner/repo` list. Required by `security`. `--repo` |
| `METRICSAI_GITHUB_AUTHORS`          | `github-copilot[bot]`    | Comma-separated AI comment authors. `--author`                      |
| `METRICSAI_WEEK_ENDING_DAY`         | `thursday`               | Weekday the reporting week closes on. `--week-ending-day`           |
| `METRICSAI_AWS_REGION`              | _(boto3 default)_        | AWS region for Security Hub.                                        |
| `METRICSAI_SKIP_SECHUB`             | `false`                  | Skip the AWS Security Hub query (GitHub metrics still run). `--skip-sechub` |
| `METRICSAI_REQUEST_TIMEOUT`         | `10.0`                   | HTTP request timeout (seconds).                                     |

AWS credentials come from boto3's default chain (env `AWS_*`, `~/.aws` profiles, SSO, or a
role) — including temporary creds via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
`AWS_SESSION_TOKEN` if already set. A least-privilege fine-grained GitHub PAT needs **Metadata: Read**, **Pull requests:
Read**, and **Issues: Read** on only the target repos — see the README for step-by-step
setup.

## Secrets (GitHub token & webhook key)

The GitHub token (for the `security` module) and the webhook key (to POST) are each resolved
in the same order: **environment → macOS Keychain → interactive prompt (TTY only)**. In a
non-interactive context the prompt is skipped and the run fails with guidance rather than
hanging. The webhook key is not needed for `--dry-run`. Store them once with:

```bash
uv run metricsai --set-token        # GitHub token  -> keychain service metricsai-github
uv run metricsai --set-webhook-key  # webhook key    -> keychain service metricsai-webhook
```

## Optional sandbox (`srt`)

`metricsai` has no dependency on any sandbox. To isolate it on macOS with `srt`: store the
GitHub token unsandboxed first (keychain writes are blocked in-sandbox), run `aws sso login`
unsandboxed if you use SSO (its token-cache write is also blocked), allowlist your hosts
(`api.github.com` or Enterprise host, `securityhub.<region>.amazonaws.com`, STS/SSO
endpoints, your Apps Script host) in `~/.srt-settings.json`, then:

```bash
srt -c ".venv/bin/metricsai --dry-run"
```

Inside `srt`, call the installed `.venv/bin/metricsai` directly — `uv run` writes to
`~/.cache/uv`, which the sandbox blocks unless you allowlist that path. boto3 *reads* of
`~/.aws/*` work in-sandbox, so static keys and profiles are fine.
