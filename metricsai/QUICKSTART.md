# metricsai — Quick Reference

macOS · Python ≥3.12 · [uv](https://docs.astral.sh/uv/) (`brew install uv`)

## Install

```bash
git clone https://github.com/navapbc/ai-transformation-delivery-systems.git && cd ai-transformation-delivery-systems/metricsai
uv sync
```

## One-time secrets (keychain)

```bash
uv run metricsai --set-token         # GitHub token (security module)
uv run metricsai --set-webhook-key   # webhook API key (to post)
```

Or via env: `METRICSAI_GITHUB_TOKEN`, `METRICSAI_WEBHOOK_KEY`.

## Run

```bash
uv run metricsai --dry-run                              # gather all, print row, no POST
uv run metricsai --module security --repo OWNER/REPO    # one module, scan a repo
uv run metricsai --repo o/r --skip-sechub --dry-run     # GitHub only, no AWS
uv run metricsai --url "$URL" --tab Metrics             # gather all, POST to a tab
uv run metricsai --list-modules
```

All modules run by default; `--module` (repeatable) narrows. Row key = `week_ending_date`
(most recent Thursday, window Fri 00:00Z–Thu 23:59:59Z; override the date with
`--week-ending YYYY-MM-DD` or the weekday with `--week-ending-day sunday`).

## Common flags / env

| Flag | Env | Purpose |
|------|-----|---------|
| `--url` | `METRICSAI_WEBHOOK_URL` | Apps Script `/exec` endpoint |
| `--tab` | `METRICSAI_WEBHOOK_TAB` | destination sheet tab |
| `--repo` (repeat) | `METRICSAI_GITHUB_REPOS` (csv) | repos to scan (required by `security`) |
| `--author` (repeat) | `METRICSAI_GITHUB_AUTHORS` (csv) | AI comment authors (default `github-copilot[bot]`) |
| `--github-url` | `METRICSAI_GITHUB_BASE_URL` | Enterprise: `https://<host>/api/v3` |
| `--week-ending-day` | `METRICSAI_WEEK_ENDING_DAY` | week-closing weekday (default `thursday`) |
| `--skip-sechub` | `METRICSAI_SKIP_SECHUB` | skip AWS Security Hub |
| — | `METRICSAI_AWS_REGION` | Security Hub region (else boto3 default) |
| `-v` / `--debug` | — | INFO / DEBUG logging |

AWS creds: boto3 default chain (`AWS_PROFILE` / `AWS_REGION` / `~/.aws`, or env
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`).

## Dev

```bash
uv run pytest            # tests (uv run pytest -k NAME for one)
uv run ruff check .      # lint
uv run ruff format .     # format
uv run mkdocs serve      # docs (uv sync --group docs first)
```

Full docs: [`README.md`](./README.md) · webhook setup: [`apps_script/README.md`](./apps_script/README.md)
