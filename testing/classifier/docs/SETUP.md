# Test Classifier Setup Guide

This document covers everything needed to run the AI test classifier — the
tool that tags each CI test failure as **`APPLICATION_BUG`**, **`TEST_BUG`**,
**`FLAKY_FAILURE`**, or **`ENVIRONMENT_ISSUE`** (see
[`PLAYBOOK.md`](./PLAYBOOK.md) for the full framing). There are **three
independent paths**, and you can use any or all:

| Path | What it does | Who runs it | Setup effort |
|---|---|---|---|
| **A. Local dispatcher run** | Developer runs `test-classifier-dispatcher.sh` on their own machine; classifications print to the terminal. With no PR it classifies the local committed + staged diff (`--unpushed`); against a PR, `--post-comment` posts the comment via `gh` CLI | Any developer | Low (per developer) |
| **B. Reusable workflow (recommended backstop)** | Consumer repo adds a tiny caller workflow that references the bundle's reusable workflow with a pinned SHA — no files copied in. Runs on every PR; posts a triage comment with the verdicts + 👍/👎 | Repo admin enables once | Low (one-time) |
| **C. Vendored workflow** | Copy the bundle's workflow file into your repo's live workflows dir. Fallback for repos that can't use reusable workflows | Repo admin enables once | Medium (one-time) |
| **D. Jenkins** | For teams whose CI is Jenkins, not GitHub Actions (GitHub.com or GitHub Enterprise). A reference `Jenkinsfile` + a thin adapter map Jenkins' PR env onto the same dispatcher contract. Full guide: [`../jenkins/README.md`](../jenkins/README.md) | Repo / Jenkins admin enables once | Medium (one-time) |

Most pilots use **A + B**: developers classify locally while iterating (A), and
the reusable workflow (B) provides the consistent, recorded backstop that feeds
the metrics loop. Use **C** only when policy forbids referencing an external
reusable workflow. Use **D** when the team's CI is Jenkins rather than GitHub
Actions — the classifier core is CI-agnostic, so paths B and D run the same
dispatcher and produce the same comment + metrics.

This guide mirrors `security/review/docs/PR_REVIEW_SETUP.md` step for step —
including the path lettering: **Path A is the local developer run, Path B is the
CI workflow**, exactly as in the security bundle. The difference is the
classifier's metrics sink, which the security bundle does not have.

---

## Contents

1. [Path A — Local dispatcher run](#path-a--local-dispatcher-run)
2. [Path B — Reusable workflow (recommended backstop)](#path-b--reusable-workflow-recommended-backstop)
3. [Path C — Vendored workflow](#path-c--vendored-workflow)
4. [Path D — Jenkins](../jenkins/README.md)
5. [Fine-grained personal access token setup](#fine-grained-personal-access-token-setup)
6. [Metrics sink configuration](#metrics-sink-configuration)
7. [Troubleshooting](#troubleshooting)

---

## Path A — Local dispatcher run

This is the developer-initiated path: a developer working on a branch runs the
local dispatcher to classify failing tests. With **no PR** it classifies the
local committed + staged diff (`--unpushed`); on a PR branch it discovers the PR
and can post the comment. This is the testing sibling of the security bundle's
Path A (its local `pr-review` run).

> **Want a one-word command instead of the full dispatcher path?** Add the
> `test-classifier` shell function from
> [`LOCAL_TEST_CLASSIFIER.md`](./LOCAL_TEST_CLASSIFIER.md) to your `~/.zshrc`. It
> defaults to `--unpushed` (everything committed + staged, no PR needed) and
> mirrors the security bundle's local-review function.

### Prerequisites

- The classifier bundle's scripts are present under `testing/classifier/` in
  your repo — see [Step 0](#step-0--install-the-bundle) just below.
- `AI_REVIEW_TOOL` is set in the developer's shell (`claude` | `codex` |
  `copilot`).
- The matching AI CLI is installed (`claude`, `codex`, or `copilot`).
- The GitHub CLI (`gh`) is installed and authenticated — needed only for the
  PR-based modes (auto-discovery, `--pr`, `--post-comment`). A `--unpushed`
  local run needs no PR and no `gh`.

### Step 0 — Install the bundle

Unlike the CI path (Path B), which copies nothing in, a local run needs the
classifier scripts present in your repo. The source repo is **public**, so one
command vendors just the `testing/classifier/` subtree from the pinned `pilot`
tag — no auth, no `gh`:

```bash
# Run from your repo root. Pin to a tag (pilot) or a commit SHA.
curl -fsSL https://codeload.github.com/navapbc/ai-transformation-delivery-systems/tar.gz/refs/tags/pilot \
  | tar -xz --strip-components=1 '*/testing/classifier'
```

This drops the bundle at `testing/classifier/` with the dispatcher's `+x` bit
intact. Commit the tree (or add it to your repo however you vendor third-party
code). To upgrade later, re-run the command with a newer tag/SHA. If you'd
rather track it as a live subtree, a `git clone --filter=blob:none --sparse`
of the source repo with `git sparse-checkout set testing/classifier` works too.

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

# NO open PR yet? Classify everything you haven't pushed (committed + staged),
# just like the security runner's `--unpushed`. Report-only — nothing is posted:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --unpushed

# Classify and post the comment with the mandatory 👍/👎 ask:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --post-comment

# Explicit PR number (works from any branch):
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr 1234 --post-comment

# Dry run — show the plan (tool, PR, diff range), make no AI call:
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --dry-run

# Opt in to running the suite locally (OBSERVED). OFF by default for the local
# path so a run never auto-installs deps or executes tests on your machine:
AI_RUN_SUITE=1 \
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --post-comment
```

By default a **local** run is read-only and INFERRED (predicts from the diff) —
it will not install deps or run your suite. Set `AI_RUN_SUITE=1` to let the agent
run the suite locally (the same OBSERVED behavior CI uses). CI sets this for you.

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
| `--unpushed`      | Classify everything not yet pushed (committed + staged) with **no PR** — resolves the base from upstream / remote-default merge-base, like the security runner. Report-only (incompatible with `--post-comment`, which needs a PR). |
| `-h`, `--help`    | Show help. |

---

## Path B — Reusable workflow (recommended backstop)

This is the recommended way to run the classifier in CI as the recorded,
metrics-feeding backstop. The bundle ships a
**reusable workflow** at the repo root —
`.github/workflows/test-classifier.yml` (with `on: workflow_call`) — that your
repo calls with a single pinned `uses:` line. **No files are copied into your
repo.** Upgrading is a one-line SHA bump; there is no vendored copy to drift,
and provenance is unambiguous.

`navapbc/ai-transformation-delivery-systems` is **public**, so no org-access
prerequisite is needed: any repo can call its reusable workflow, and both the
`uses:` reference and the workflow's own step that fetches the bundle scripts
(a pinned source tarball) resolve with the consumer's default `GITHUB_TOKEN` —
**no PAT required**.

### Step 1 — Add the caller workflow

Create `.github/workflows/ai-test-classifier.yml` in your **consumer** repo:

```yaml
# .github/workflows/ai-test-classifier.yml in the CONSUMER repo
name: AI test classifier
on:
  pull_request:
    types: [opened, synchronize, reopened]
# Required in the CALLER — a reusable workflow can't grant more than the caller
# holds. Without pull-requests: write the run 403s when it posts the comment.
permissions:
  contents: read
  pull-requests: write
  id-token: write          # only used by provider: bedrock + aws-auth: oidc; harmless otherwise
jobs:
  classify:
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@<commit-sha>
    with:
      tool: claude        # claude | codex | copilot
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

**Pin to a commit SHA, not a branch.** A branch ref moves under you; a SHA is
reproducible and is the only ref that gives you a clear, auditable provenance.
To upgrade, bump the SHA. That is the entire upgrade procedure — no file copy,
no merge.

In this path, `tool` is a **workflow input** in the caller's `with:` block —
**not** a repository variable. (Repository variables only apply to the local
path above and the vendored path below.)

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

> **Running on Amazon Bedrock instead?** For CMS-internal repos that can't send
> code to a direct API, the classifier can run in your own AWS account via
> Bedrock (GitHub OIDC, no stored keys) — Claude with `tool: claude`, or OpenAI
> GPT-5.x with `tool: codex`. See [`BEDROCK.md`](./BEDROCK.md) — it adds a
> `provider: bedrock` input and replaces the API-key secret with an assumed IAM
> role.

That is the whole setup for Path B. On the next PR the workflow runs, triages
any failing tests, and posts one comment with the verdicts + a mandatory 👍/👎.
The full report is also uploaded as a CI artifact, and the run is non-blocking.

#### OBSERVED vs INFERRED — what the classifier actually sees

In CI the workflow sets `AI_RUN_SUITE=1`, which grants the agent shell execution
so it **runs your suite itself**: it locates your test command (package.json,
Makefile, pytest/tox, go.mod, Cargo.toml, or your CI's test step), installs deps
from your lockfile best-effort, runs the tests, and triages the **real**
failures. That comment is marked **Observed**.

If it can't run the suite — no test command found, a toolchain it can't install
on the stock `ubuntu-latest` image, the suite needs services (a database, etc.),
or it times out — it falls back to predicting from the diff and marks the comment
**Inferred, not observed**, stating the reason in the summary. OBSERVED is the
only mode in which `FLAKY_FAILURE`/`ENVIRONMENT_ISSUE` are reliably reachable
(you can't see a timeout or non-determinism from a diff). No per-repo config is
needed either way; suites needing services legitimately land in INFERRED.

The run is bounded: `timeout-minutes` on the job and `AI_SUITE_TIMEOUT_SECS` /
`AI_SUITE_MAX_TURNS` (env, defaults 1500s / 40 turns) inside the dispatcher.

#### Observability (OpenTelemetry)

The CI run enables Claude Code's native OpenTelemetry, but the span/metric
**exporter defaults to `none`** — Claude's `console` exporter writes to stdout
and would corrupt the parsed result. Instead, each run captures the agent in the
`ai-test-classification` artifact as:

- `agent-bodies/` — the untruncated request/response bodies
  (`OTEL_LOG_RAW_API_BODIES=file:…`): the full conversation the agent saw and
  produced, every tool call and model response. Written straight to disk (no
  stream, no stdout collision). **This includes your repo's code and the agent's
  full reasoning** — it lives only in the run's artifact on the ephemeral runner,
  but treat it as sensitive.
- `classification.txt` — the clean classification report + the parsed JSON.

To ship real spans/metrics to a backend, set repo/org variables
`OTEL_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_ENDPOINT` (+
`OTEL_EXPORTER_OTLP_PROTOCOL`) and the secret `OTEL_EXPORTER_OTLP_HEADERS`. OTLP
is a network exporter, so it never touches stdout — safe to enable with no
workflow code change (the vars are already wired through).

---

## Path C — Vendored workflow

> **Fallback path.** Use this only for repos that can't use reusable workflows
> (e.g. policy forbids referencing an external `uses:`). It requires copying the
> bundle's workflow file into your repo. If you can, prefer
> [Path B — Reusable workflow](#path-b--reusable-workflow-recommended-backstop) instead.

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

### The comment says "Inferred, not observed" but I have a test suite

The agent couldn't run your suite, so it fell back to predicting from the diff.
The `summary` states the reason — typically: no test command it recognized, a
toolchain it couldn't install on the stock runner, the suite needs a service
(database/Redis) the runner doesn't provide, or it hit the timeout
(`AI_SUITE_TIMEOUT_SECS`, default 1500s, and the job's `timeout-minutes`). Make
the test command discoverable (a `test` script / standard config) and runnable
with only the repo's lockfile to get **Observed** verdicts. Suites that genuinely
need services will remain INFERRED — that's expected.

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
