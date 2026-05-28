# Test Classifier Setup Guide

This document covers everything needed to run the AI test classifier — the
tool that tags each CI test failure as **`APPLICATION_BUG`**, **`TEST_BUG`**,
**`FLAKY_FAILURE`**, or **`ENVIRONMENT_ISSUE`** (see
[`PLAYBOOK.md`](./PLAYBOOK.md) for the full framing and
phasing). There are **two independent paths**, and you can use either or both:

| Path | What it does | Who runs it | Setup effort |
|---|---|---|---|
| **A. Local dispatcher run** | Developer runs `test-classifier-dispatcher.sh` on their machine against a PR; classifications print to the terminal and (in P1) post as a PR comment via `gh` CLI | Any developer | Low (per developer) |
| **B. GitHub Actions workflow** | Workflow runs on every PR, classifies failures, and (in P1) posts a comment requesting a 👍/👎, via `GITHUB_TOKEN` | Repo admin enables once | Medium (one-time) |

Most pilots use **A + B**: developers can classify locally while iterating,
and the workflow provides the consistent, recorded backstop that feeds the
metrics loop.

This guide mirrors `security/review/docs/PR_REVIEW_SETUP.md` step for step;
the difference is the classifier's `--mode` (`p0` / `p1`) input and the
metrics sink, which the security bundle does not have.

---

## Contents

1. [Path A — Local dispatcher run](#path-a--local-dispatcher-run)
2. [Path B — GitHub Actions workflow](#path-b--github-actions-workflow)
3. [Choosing a phase: `p0` vs `p1`](#choosing-a-phase-p0-vs-p1)
4. [Fine-grained personal access token setup](#fine-grained-personal-access-token-setup)
5. [Metrics sink configuration](#metrics-sink-configuration)
6. [Troubleshooting](#troubleshooting)

---

## Path A — Local dispatcher run

This is the developer-initiated path: a developer working on a branch runs the
local dispatcher to classify the failing tests on the PR they're working on.

### Prerequisites

- The classifier bundle is installed under `testing/classifier/` (see
  `INSTALL.txt`).
- `AI_REVIEW_TOOL` is set in the developer's shell (`claude` | `codex` |
  `copilot`).
- The matching AI CLI is installed (`claude`, `codex`, or `copilot`).
- The GitHub CLI (`gh`) is installed and authenticated (needed for PR
  discovery and, in P1, for posting the comment).

### Installing `gh`

```bash
# macOS
brew install gh

# Linux
# See https://github.com/cli/cli/blob/trunk/docs/install_linux.md

# Authenticate (one-time, interactive)
gh auth login
```

Choose **GitHub.com**, **HTTPS**, and **Login with a web browser** unless your
security policy requires a PAT (see the
[fine-grained PAT section](#fine-grained-personal-access-token-setup) below).

### Daily usage

```bash
# P0 — observe-only. Classify the current branch's PR, record, post nothing:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --mode p0

# P1 — classify and post the comment with the mandatory 👍/👎 ask:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --mode p1 --post-comment

# Explicit PR number (works from any branch):
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr 1234 --mode p1 --post-comment

# Dry run — show the plan (tool, mode, PR, diff range), make no AI call:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --mode p0 --dry-run
```

By default the dispatcher prints the classification report to the terminal
only. In `--mode p1`, add `--post-comment` to also post the PR comment. In
`--mode p0`, `--post-comment` is ignored by design — P0 never posts.

### What gets posted (P1 only)

In `--mode p1 --post-comment`, the dispatcher posts **one** PR comment per
classified failure (or one rolled-up comment) stating:

- The call: one of **`APPLICATION_BUG`** (test fails because the app
  regressed — fix the code), **`TEST_BUG`** (test fails but the app is correct
  — fix the test), **`FLAKY_FAILURE`** (intermittent — re-run, then deflake),
  or **`ENVIRONMENT_ISSUE`** (infra: timeout/connection/OOM/missing service —
  fix the env or re-run). A passing test is simply not classified.
- A short rationale for the call.
- A **mandatory 👍 / 👎 ask** — the developer reacts 👍 if the call is right, 👎 if
  wrong. That reaction is the tuning signal the metrics loop reads.

The classifier is **advisory** — posting a comment never fails anything. Use
`--gate` only if you have explicitly decided to make an unconfirmed
`APPLICATION_BUG` a blocker (out of pilot scope; see the PLAYBOOK §3 and §4).

### Flags reference (classifier-specific)

| Flag | Effect |
|---|---|
| `--pr <number>`   | Explicit PR number. Overrides auto-discovery via `gh pr view`. |
| `--mode <p0\|p1>` | Phase. `p0` = observe-only (record, no comment). `p1` = comment + mandatory 👍/👎. |
| `--post-comment`  | Post the classifier comment via `gh api`. Required in `p1`; ignored in `p0`. |
| `--gate`          | Exit non-zero on any unconfirmed triaged failure (e.g. an `APPLICATION_BUG`). For CI gating (out of pilot scope). |
| `--json-only`     | Print only the JSON block (for piping into the metrics harvest). |

Plus the shared dispatcher-library flags (identical to security/review):

| Flag | Effect |
|---|---|
| `-n`, `--dry-run` | Print the plan; do not invoke AI. |
| `--no-block`      | Always exit 0 regardless of result. |
| `--against <ref>` | Override the diff base ref (bypasses PR discovery). |
| `-h`, `--help`    | Show help. |

---

## Path B — GitHub Actions workflow

A workflow file lives at
`testing/classifier/.github/workflows/ai-test-classifier.yml`. It is
**disabled by default**. To enable it, complete the steps below.

> **Merge, don't overwrite.** If your repository already has a file at
> `.github/workflows/ai-test-classifier.yml` or
> `.github/copilot-instructions.md`, **do not blindly replace them** — open the
> existing file and merge in the relevant sections. The
> `copilot-instructions.md` file uses `<!-- BEGIN ... -->` / `<!-- END ... -->`
> markers around its content to make manual merging safe.

### Step 1 — Copy the workflow into your live workflows directory

```bash
cp testing/classifier/.github/workflows/ai-test-classifier.yml \
   .github/workflows/ai-test-classifier.yml
```

### Step 2 — Set the AI tool as a repository variable

Repository variables are non-sensitive configuration. The AI tool name is not
a secret.

1. **Settings** → **Secrets and variables** → **Actions** → **Variables** tab.
2. **New repository variable**.
3. Name: `AI_REVIEW_TOOL`
4. Value: `claude`, `codex`, or `copilot` (lowercase, exactly).

### Step 3 — Set the API key as a repository secret

1. **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab.
2. **New repository secret**, matching your chosen tool:

| Tool | Secret name | Where to get the value |
|---|---|---|
| `claude`  | `ANTHROPIC_API_KEY` | <https://console.anthropic.com/settings/keys> |
| `codex`   | `OPENAI_API_KEY`    | <https://platform.openai.com/api-keys> |
| `copilot` | (none — uses `GITHUB_TOKEN`) | n/a |

Only set the secret matching your chosen tool. The others can remain blank.

### Step 4 — Set the phase via `CLASSIFIER_MODE`

The classifier's phase is a repository **variable** read by the `pull_request`
trigger, and is also exposed as a `workflow_dispatch` input for manual runs.

1. **Settings** → **Secrets and variables** → **Actions** → **Variables**.
2. **New repository variable**.
3. Name: `CLASSIFIER_MODE`
4. Value: `p0` (observe-only) or `p1` (comment + mandatory 👍/👎).

**Start in `p0`.** Switch to `p1` only after P0 precision looks trustworthy
(see [Choosing a phase](#choosing-a-phase-p0-vs-p1) and the metrics loop in
PLAYBOOK §5).

### Step 5 — Confirm workflow permissions (least privilege)

The workflow declares exactly the permissions it needs:

```yaml
permissions:
  contents: read         # check out the repo, read the diff and test output
  pull-requests: write   # post the classifier comment (used in p1 only)
```

In `p0` the workflow does not post and only exercises `contents: read`. If your
org enforces restrictive default-token permissions, confirm the workflow's
`permissions:` block is honored under **Settings** → **Actions** → **General**
→ **Workflow permissions**.

### Step 6 — Enable the trigger

Edit `.github/workflows/ai-test-classifier.yml` and change:

```yaml
on:
  workflow_dispatch:
    inputs:
      mode:
        description: "Classifier phase (p0 = observe-only, p1 = comment + 👍/👎)"
        default: "p0"
  # pull_request:
  #   types: [opened, synchronize, reopened]
```

to:

```yaml
on:
  workflow_dispatch:
    inputs:
      mode:
        description: "Classifier phase (p0 = observe-only, p1 = comment + 👍/👎)"
        default: "p0"
  pull_request:
    types: [opened, synchronize, reopened]
```

Commit and push. The next PR triggers a classification at whatever phase
`CLASSIFIER_MODE` is set to.

### Step 7 — Optional: enable gating (out of pilot scope)

The pilot default is **advisory / non-blocking**, exactly like security review.
If, much later, a team wants an unconfirmed triaged failure (e.g. an
`APPLICATION_BUG`) to fail the build, uncomment the `--gate` line in the
workflow's run step:

```yaml
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr "${PR_NUMBER}" \
  --mode "${CLASSIFIER_MODE}" \
  --post-comment
  # --gate
```

Combined with a repository rule set that requires the workflow to pass, this
makes the classifier a true merge gate. Use with care — a false
`APPLICATION_BUG` becomes blocking.

---

## Choosing a phase: `p0` vs `p1`

| | `p0` — observe-only | `p1` — MVP |
|---|---|---|
| Classifies failures | Yes | Yes |
| Records to metrics sink | Yes | Yes |
| Posts PR comment | No | Yes |
| Asks for mandatory 👍/👎 | No | Yes |
| Developer-visible | No | Yes |
| Use when | Establishing baseline precision; no one trusts a comment yet | Baseline precision is good enough to be worth a developer's glance and reaction |

**Graduation rule of thumb:** run `p0` until you have enough recorded
classifications to read a stable per-class precision (see PLAYBOOK §5), then
flip `CLASSIFIER_MODE` to `p1`. Do not skip P0 — a P1 comment a team doesn't
trust trains them to ignore the bot, which poisons the 👍/👎 signal.

---

## Fine-grained personal access token setup

A fine-grained PAT is only needed for **local P1 use** — when a developer wants
to post the classifier comment via the dispatcher but prefers a token over
`gh auth login` (e.g., in a hardened environment without browser auth). For
GitHub Actions, the default `GITHUB_TOKEN` is sufficient and strictly
preferred.

### Steps

1. Go to <https://github.com/settings/personal-access-tokens/new>.
2. Token name: e.g., `test-classifier-<repo>`.
3. Expiration: 90 days (recommended). Never-expiring tokens are accumulating
   risk.
4. **Resource owner**: your username, or the org that owns the target repo.
5. **Repository access**: **Only select repositories** → pick the specific
   repo(s). Do not grant `All repositories`.
6. **Permissions** → **Repository permissions** — grant exactly these, nothing
   more:

   | Permission | Access | Why |
   |---|---|---|
   | **Contents** | **Read-only** | `git diff` against the repo; `gh pr view` reads PR metadata |
   | **Metadata** | **Read-only** | Mandatory baseline; granted automatically |
   | **Pull requests** | **Read and write** | Post the classifier comment (P1) |

   Leave everything else (`Actions`, `Workflows`, `Secrets`, `Administration`,
   etc.) on **No access**.

7. **Generate token**, copy the value once.

### Using the token

```bash
# Persistent, macOS / zsh
echo 'export GH_TOKEN=ghp_yourTokenValueHere' >> ~/.zshrc
source ~/.zshrc

# Verify
gh auth status
```

> Treat the token like any other secret. Never commit it, never paste it in a
> comment. If it leaks, revoke it at
> <https://github.com/settings/personal-access-tokens> and create a new one.
> This is the same least-privilege posture documented in
> `security/review/docs/PR_REVIEW_SETUP.md`.

---

## Metrics sink configuration

The metrics harvester lives at
`testing/metrics/test_classifier_comments.sh`. It reads the 👍/👎 reactions off
classifier comments and emits per-class precision inputs (see PLAYBOOK §5).

### Primary sink — Google Sheet (service-account bearer token)

```bash
export CLASSIFIER_SHEET_ID=<the target Google Sheet ID>
export CLASSIFIER_SHEET_TOKEN=<a Google service-account access token>

testing/metrics/test_classifier_comments.sh
```

- The token is a **bearer token minted for a service account** that has edit
  access to the target Sheet. Mint it out-of-band (e.g., `gcloud auth
  print-access-token` for the service account, or your secrets manager) and
  pass it via the environment — **never** as a command-line argument and
  **never** committed.
- Treat `CLASSIFIER_SHEET_TOKEN` exactly like an API key: GitHub Actions secret
  in CI, environment variable locally, kept out of logs.

### Fallback sink — TSV/CSV to stdout (the realistic P0 default)

```bash
# TSV to stdout (default for early pilots, before the Sheet is wired)
testing/metrics/test_classifier_comments.sh --format tsv

# CSV instead
testing/metrics/test_classifier_comments.sh --format csv > classifier-metrics.csv
```

This shares plumbing intent with `security/metrics/pr_review_comments.sh`
(paginated `gh api`, `jq` reaction extraction). Pipe it into a spreadsheet, a
notebook, or `column -t -s$'\t'` for a quick eyeball.

---

## Troubleshooting

### `gh pr view` returns nothing on the current branch

Your branch isn't associated with an open PR yet. Either push and open a PR
(`gh pr create`), then re-run, or pass `--pr <number>` explicitly.

### `gh: command not found`

```bash
brew install gh        # macOS — or see https://github.com/cli/cli
gh auth login
```

### `--post-comment` did nothing

Confirm you are in `--mode p1`. In `--mode p0` the classifier is observe-only
and `--post-comment` is intentionally a no-op.

### `gh api` call fails with `403 Resource not accessible by integration`

Your token (or the workflow's `GITHUB_TOKEN`) lacks `pull-requests: write`. For
local use, regenerate the fine-grained PAT with the correct permission. For CI,
verify the workflow's `permissions:` block includes `pull-requests: write`.

### Workflow runs but posts no comment

Check the workflow logs:

- `AI_REVIEW_TOOL` variable not set → the validation step fails fast.
- API key secret not set → the AI CLI errors.
- `CLASSIFIER_MODE` is `p0` → posting is intentionally skipped (observe-only).
- AI returned no result marker (`<<<AI_REVIEW_RESULT:...>>>`) → the dispatcher
  errors and exits non-zero. This can happen on transient model issues; retry.

### Metrics script writes nothing to the Sheet

- `CLASSIFIER_SHEET_TOKEN` is unset, expired, or the service account lacks edit
  access to `CLASSIFIER_SHEET_ID`. Re-mint the token and confirm Sheet sharing.
- As a fast diagnostic, run with `--format tsv` to confirm the harvester is
  finding comments at all; if TSV is populated but the Sheet isn't, the problem
  is in the token/Sheet auth, not the harvest.

### My team uses different AI tools

The dispatcher selects on `AI_REVIEW_TOOL`, so each developer can use whichever
they prefer locally. For CI you must pick one (the `vars.AI_REVIEW_TOOL`
repository variable) — same model as security/review.
