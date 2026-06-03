# Test Classifier Setup Guide

This document covers everything needed to run the AI test classifier — the
tool that tags each CI test failure as **`APPLICATION_BUG`**, **`TEST_BUG`**,
**`FLAKY_FAILURE`**, or **`ENVIRONMENT_ISSUE`** (see
[`PLAYBOOK.md`](./PLAYBOOK.md) for the full framing). There are **three
independent paths**, and you can use any or all:

| Path | What it does | Who runs it | Setup effort |
|---|---|---|---|
| **A. Reusable workflow (recommended)** | Consumer repo adds a tiny caller workflow that references the bundle's reusable workflow with a pinned SHA — no files copied in. Runs on every PR; posts a triage comment with the verdicts + 👍/👎 | Repo admin enables once | Low (one-time) |
| **B. Local dispatcher run** | Developer runs `test-classifier-dispatcher.sh` on their machine against a PR; classifications print to the terminal and (with `--post-comment`) post as a PR comment via `gh` CLI | Any developer | Low (per developer) |
| **C. Vendored workflow** | Copy the bundle's workflow file into your repo's live workflows dir. Fallback for repos that can't use reusable workflows | Repo admin enables once | Medium (one-time) |

Most pilots use **A + B**: the reusable workflow provides the consistent,
recorded backstop that feeds the metrics loop, and developers can classify
locally while iterating. Use **C** only when policy forbids referencing an
external reusable workflow.

This guide mirrors `security/review/docs/PR_REVIEW_SETUP.md` step for step;
the difference is the classifier's metrics sink, which the security bundle does
not have.

---

## Contents

1. [Path A — Reusable workflow (recommended)](#path-a--reusable-workflow-recommended)
2. [Path B — Local dispatcher run](#path-b--local-dispatcher-run)
3. [Path C — Vendored workflow](#path-c--vendored-workflow)
4. [Fine-grained personal access token setup](#fine-grained-personal-access-token-setup)
5. [Metrics sink configuration](#metrics-sink-configuration)
6. [Troubleshooting](#troubleshooting)

---

## Path A — Reusable workflow (recommended)

This is the recommended way to use the classifier in CI. The bundle ships a
**reusable workflow** at the repo root —
`.github/workflows/test-classifier.yml` (with `on: workflow_call`) — that your
repo calls with a single pinned `uses:` line. **No files are copied into your
repo.** Upgrading is a one-line SHA bump; there is no vendored copy to drift,
and provenance is unambiguous.

### Step 0 — One-time org prerequisite (private source repo)

`navapbc/ai-transformation-delivery-systems` is **private**, so before any other
repo can call its reusable workflow, an org/repo admin must allow it once:

1. In **this source repo**: **Settings** → **Actions** → **General** →
   **Access** → set **"Accessible from repositories in the 'navapbc'
   organization"** (or list the specific consumer repos).

This single setting unlocks two things at runtime, both with the consumer's
default `GITHUB_TOKEN` — **no PAT is required**:

- the `uses:` reference to the reusable workflow resolves, and
- the workflow's own step that fetches this bundle's scripts (a pinned source
  tarball via the GitHub API) is authorized.

If you see `error: workflow was not found` or a `404` fetching the bundle in the
consumer's Actions log, this setting is the cause.

### Step 1 — Add the caller workflow

Create `.github/workflows/ai-test-classifier.yml` in your **consumer** repo:

```yaml
# .github/workflows/ai-test-classifier.yml in the CONSUMER repo
name: AI test classifier
on:
  # Run AFTER your test workflow finishes, so the classifier reads your REAL
  # test results. Set workflows: to YOUR test workflow's name (its `name:`
  # field, not its filename). The defaults cover the common conventions.
  workflow_run:
    workflows: ["Test", "CI", "Tests"]   # ← your test workflow's name(s)
    types: [completed]
jobs:
  classify:
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@<commit-sha>
    with:
      tool: claude        # claude | codex | copilot
      # Artifact name your test workflow uploads with its results (JUnit XML
      # and/or a captured run log). Defaults to 'ai-test-results'.
      test-results-artifact: ai-test-results
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

**Pin to a commit SHA, not a branch.** A branch ref moves under you; a SHA is
reproducible and is the only ref that gives you a clear, auditable provenance.
To upgrade, bump the SHA. That is the entire upgrade procedure — no file copy,
no merge.

In this path, `tool` is a **workflow input** in the caller's `with:` block —
**not** a repository variable. (Repository variables only apply to the local
and vendored paths below.)

#### Two things you must get right for the `workflow_run` trigger

1. **Name your test workflow in `workflows:`.** It matches by the upstream
   workflow's `name:` field, **not** filename — if it doesn't match, the
   classifier silently never fires. (An installing agent can set this for you —
   see `AGENT_INSTALL.md`.)
2. **It activates only from the default branch.** `workflow_run` triggers are
   read from the default branch, so the caller won't fire from a feature branch
   until merged. (Same reason forked-PR runs don't carry secrets.)

#### OBSERVED vs INFERRED — what the classifier actually sees

The classifier's verdicts are only as good as the failing-test signal it sees:

- **OBSERVED** (preferred): when your test workflow uploads its results as an
  artifact named by `test-results-artifact` (default `ai-test-results`), the
  classifier downloads that run's artifact and triages the **real** failures. The
  PR comment is marked *Observed*. This is the only mode in which
  `FLAKY_FAILURE` and `ENVIRONMENT_ISSUE` are reliably reachable — you cannot
  see a timeout, an OOM, or non-determinism from a diff.
- **INFERRED** (fallback): if no results artifact is available, the classifier
  reasons over the git diff and **predicts** which tests would fail. The PR
  comment is marked *Inferred, not observed* so a reviewer never mistakes a
  prediction for a real outcome. This is what you get with no test suite, no
  uploaded artifact, or a `pull_request`-triggered caller.

To unlock OBSERVED mode, have your test job upload its JUnit XML / run log:

```yaml
# in your TEST workflow's job, after the test step (even on failure):
- name: Upload test results for the AI classifier
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: ai-test-results      # must match test-results-artifact above
    path: |
      junit.xml                # your JUnit/xUnit report(s)
      test-output.log          # and/or a captured run log
    if-no-files-found: ignore
```

### Step 2 — Set the API-key secret

Even though no files are vendored, the consumer repo **must still set the
API-key secret** for the chosen tool, and pass it through the caller's
`secrets:` block as shown above.

1. **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab.
2. **New repository secret**, matching your chosen tool:

| Tool | Secret name | Pass through as | Where to get the value |
|---|---|---|---|
| `claude`  | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}` | <https://console.anthropic.com/settings/keys> |
| `codex`   | `OPENAI_API_KEY`    | `OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}` | <https://platform.openai.com/api-keys> |
| `copilot` | (none — uses `GITHUB_TOKEN`) | n/a | n/a |

Only set the secret matching your chosen `tool` input.

That is the whole setup for Path A. On the next PR the workflow runs, triages
any failing tests, and posts one comment with the verdicts + a mandatory 👍/👎.
The full report is also uploaded as a CI artifact, and the run is non-blocking.

---

## Path B — Local dispatcher run

This is the developer-initiated path: a developer working on a branch runs the
local dispatcher to classify the failing tests on the PR they're working on.

### Prerequisites

- The classifier bundle is installed under `testing/classifier/` (see
  `INSTALL.txt`).
- `AI_REVIEW_TOOL` is set in the developer's shell (`claude` | `codex` |
  `copilot`).
- The matching AI CLI is installed (`claude`, `codex`, or `copilot`).
- The GitHub CLI (`gh`) is installed and authenticated (needed for PR
  discovery and, with `--post-comment`, for posting the comment).

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
# Classify the current branch's PR; print the report to the terminal only:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh

# Classify and post the comment with the mandatory 👍/👎 ask:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --post-comment

# Explicit PR number (works from any branch):
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr 1234 --post-comment

# Dry run — show the plan (tool, PR, diff range), make no AI call:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --dry-run
```

By default the dispatcher prints the classification report to the terminal
only. Add `--post-comment` to also post the PR comment.

### What gets posted

With `--post-comment`, the dispatcher posts **one** PR comment per classified
failure (or one rolled-up comment) stating:

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
`APPLICATION_BUG` a blocker (out of pilot scope; see the PLAYBOOK §4).

### Flags reference (classifier-specific)

| Flag | Effect |
|---|---|
| `--pr <number>`   | Explicit PR number. Overrides auto-discovery via `gh pr view`. |
| `--post-comment`  | Post the classifier comment (verdicts + 👍/👎 ask) via `gh api`. Without it, the report only prints / uploads as an artifact. |
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

## Path C — Vendored workflow

> **Fallback path.** Use this only for repos that can't use reusable workflows
> (e.g. policy forbids referencing an external `uses:`). It requires copying the
> bundle's workflow file into your repo. If you can, prefer
> [Path A — Reusable workflow](#path-a--reusable-workflow-recommended) instead.

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

### Step 4 — Confirm workflow permissions (least privilege)

The workflow declares exactly the permissions it needs:

```yaml
permissions:
  contents: read         # check out the repo, read the diff and test output
  pull-requests: write   # post the classifier comment
```

If your org enforces restrictive default-token permissions, confirm the
workflow's `permissions:` block is honored under **Settings** → **Actions** →
**General** → **Workflow permissions**.

### Step 5 — Enable the trigger

Edit `.github/workflows/ai-test-classifier.yml` and change:

```yaml
on:
  workflow_dispatch:
  # pull_request:
  #   types: [opened, synchronize, reopened]
```

to:

```yaml
on:
  workflow_dispatch:
  pull_request:
    types: [opened, synchronize, reopened]
```

Commit and push. The next PR triggers a classification, which posts one triage
comment with the verdicts + 👍/👎.

### Step 6 — Optional: enable gating (out of pilot scope)

The pilot default is **advisory / non-blocking**, exactly like security review.
If, much later, a team wants an unconfirmed triaged failure (e.g. an
`APPLICATION_BUG`) to fail the build, uncomment the `--gate` line in the
workflow's run step:

```yaml
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr "${PR_NUMBER}" \
  --post-comment
  # --gate
```

Combined with a repository rule set that requires the workflow to pass, this
makes the classifier a true merge gate. Use with care — a false
`APPLICATION_BUG` becomes blocking.

---

## Fine-grained personal access token setup

A fine-grained PAT is only needed for **local posting** — when a developer wants
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
   | **Pull requests** | **Read and write** | Post the classifier comment |

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
export SHEET_ID=<the target Google Sheet ID>
export GOOGLE_SHEETS_TOKEN=<a Google service-account access token>

testing/metrics/test_classifier_comments.sh
```

- The token is a **bearer token minted for a service account** that has edit
  access to the target Sheet. Mint it out-of-band (e.g., `gcloud auth
  print-access-token` for the service account, or your secrets manager) and
  pass it via the environment — **never** as a command-line argument and
  **never** committed.
- Treat `GOOGLE_SHEETS_TOKEN` exactly like an API key: GitHub Actions secret
  in CI, environment variable locally, kept out of logs.

### Fallback sink — TSV to stdout (the realistic default)

```bash
# TSV to stdout (default for early pilots, before the Sheet is wired)
testing/metrics/test_classifier_comments.sh

# capture to a file (it's tab-separated; import as TSV)
testing/metrics/test_classifier_comments.sh > classifier-metrics.tsv
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

Confirm `gh` is authenticated and the token has `pull-requests: write`. Without
`--post-comment` the dispatcher only prints the report to the terminal — pass
the flag to actually post.

### `gh api` call fails with `403 Resource not accessible by integration`

Your token (or the workflow's `GITHUB_TOKEN`) lacks `pull-requests: write`. For
local use, regenerate the fine-grained PAT with the correct permission. For CI,
verify the workflow's `permissions:` block includes `pull-requests: write`.

### Workflow runs but posts no comment

Check the workflow logs:

- `AI_REVIEW_TOOL` variable not set → the validation step fails fast.
- API key secret not set → the AI CLI errors.
- No failing tests to triage → the classifier returns `NO_ACTION` and posts
  nothing. That is expected, not an error.
- AI returned no result marker (`<<<AI_REVIEW_RESULT:...>>>`) → the dispatcher
  errors and exits non-zero. This can happen on transient model issues; retry.

### The classifier never runs at all (Path A, `workflow_run`)

The most common cause is one of the two `workflow_run` rules:

- **The caller isn't on the default branch yet.** GitHub reads `workflow_run`
  triggers from the file on the repo's **default** branch. Until the caller is
  merged there, it will not fire — even though it sits in your PR. Merge it to
  the default branch to activate.
- **The `workflows:` name doesn't match.** `workflow_run.workflows` matches the
  upstream workflow's `name:` field, not its filename. Open your test workflow,
  read its `name:`, and confirm that exact string is in the caller's
  `workflows:` list.
- **The triggering run wasn't for a PR.** A push-triggered test run has no PR to
  comment on; the classifier resolves no PR context and cleanly skips. Open a PR
  to exercise it.

### The comment says "Inferred, not observed" but I have a test suite

The classifier ran in INFERRED mode because it received no real test results.
Check that your **test** workflow uploads an artifact whose name matches the
caller's `test-results-artifact` (default `ai-test-results`), with
`if: always()` so it uploads even when tests fail. Without that artifact, the
classifier falls back to diff-only prediction (which is still useful, just
labeled as such).

### Metrics script writes nothing to the Sheet

- `GOOGLE_SHEETS_TOKEN` is unset, expired, or the service account lacks edit
  access to `SHEET_ID`. Re-mint the token and confirm Sheet sharing.
- As a fast diagnostic, run it to confirm the harvester is
  finding comments at all; if TSV is populated but the Sheet isn't, the problem
  is in the token/Sheet auth, not the harvest.

### My team uses different AI tools

The dispatcher selects on `AI_REVIEW_TOOL`, so each developer can use whichever
they prefer locally. For CI you must pick one (the `vars.AI_REVIEW_TOOL`
repository variable) — same model as security/review.
