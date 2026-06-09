# PR Review Setup Guide

This document covers everything needed to enable PR-level AI review on top
of the pre-commit hooks. There are **three independent paths**, and you can
use any combination of them:

| Path | What it does | Who runs it | Setup effort |
|---|---|---|---|
| **A. Local `pr-review` skill** | Developer runs `pr-review-dispatcher.sh` on their machine; results post as inline PR comments via `gh` CLI | Every developer who wants to | Low (per developer) |
| **B. GitHub Actions workflow** | Workflow runs on every PR, posts inline comments via `GITHUB_TOKEN` | Repo admin enables once | Medium (one-time) |
| **C. GitHub Copilot auto-review** | Copilot reviews every PR automatically, posts findings inline | Repo admin + GitHub Advanced Security or Copilot Enterprise license | Medium (one-time, requires license) |

Most teams use **A + B**: developers can self-review locally before
requesting review, and the workflow provides a backstop for PRs that bypass
that step. **C** is additional defense-in-depth if available to your org.

---

## Contents

1. [Path A — Local `pr-review` skill](#path-a--local-pr-review-skill)
2. [Path B — GitHub Actions workflow](#path-b--github-actions-workflow)
3. [Path C — GitHub Copilot PR review](#path-c--github-copilot-pr-review)
4. [Fine-grained personal access token setup](#fine-grained-personal-access-token-setup)
5. [Repository rule sets — requiring AI review before merge](#repository-rule-sets--requiring-ai-review-before-merge)
6. [Troubleshooting](#troubleshooting)

---

## Path A — Local `pr-review` skill

This is the developer-initiated path: a developer working on a branch runs
the local dispatcher to get an AI review and post inline comments to the
PR they're working on.

### Prerequisites

- The pre-commit hook system is already installed (see the main README).
- `AI_REVIEW_TOOL` is set in the developer's shell.
- The matching AI CLI is installed (`claude`, `codex`, or `copilot`).
- The GitHub CLI (`gh`) is installed and authenticated.

### Installing `gh`

```bash
# macOS
brew install gh

# Linux
# See https://github.com/cli/cli/blob/trunk/docs/install_linux.md

# Authenticate (one-time, interactive)
gh auth login
```

Choose **GitHub.com**, **HTTPS** for protocol, and **Login with a web browser**
unless your security policy requires a PAT (see the
[fine-grained PAT section](#fine-grained-personal-access-token-setup) below).

### Daily usage

```bash
# From the PR branch, with the PR already opened:
.skills/pr-review/scripts/pr-review-dispatcher.sh --post-comments

# Or explicitly specify the PR number (works from any branch):
.skills/pr-review/scripts/pr-review-dispatcher.sh --pr 1234 --post-comments

# Or review the diff locally without posting (for self-review before push):
.skills/pr-review/scripts/pr-review-dispatcher.sh --against origin/main
```

By default the dispatcher prints findings to the terminal only. Add
`--post-comments` to also post them as inline review comments on the PR.

### What gets posted

The dispatcher posts **one** PR review with:

- A short summary as the review body
- One inline comment per finding, attached to the file and line where the
  issue was identified
- A `` ```suggestion `` block in each comment that the PR author can
  one-click apply, when the fix is in-place

The review action is always `COMMENT` (advisory) unless there are zero
findings, in which case it is `APPROVE`. Use `--gate` to make the
dispatcher exit non-zero on any non-`APPROVE` result (useful in CI).

### Re-running a review is idempotent

You can safely run the review on the same PR as many times as you like — it
won't spam the PR with duplicate comments. Before posting, the dispatcher
fetches its own existing inline comments and drops any finding that already has
a *live* comment on the same `(path, line, perspective)`. A line counts as
"already commented" only while GitHub still anchors the prior comment to the
current diff; the moment that line (or its surrounding hunk) changes, GitHub
marks the old comment **outdated** and the finding is posted again on the new
code. If every finding is already present on an unchanged line, the dispatcher
posts nothing and logs `No new findings to post`.

### Flags reference (PR-review specific)

| Flag | Effect |
|---|---|
| `--pr <number>`     | Explicit PR number. Overrides auto-discovery via `gh pr view`. |
| `--post-comments`   | Post the review (with inline comments) to GitHub via `gh api`. |
| `--gate`            | Exit non-zero on any non-`APPROVE` result. For CI use. |
| `--json-only`       | Print only the JSON block (for piping into other tooling). |

Plus all flags from the shared dispatcher library:

| Flag | Effect |
|---|---|
| `-n`, `--dry-run`   | Print the plan; do not invoke AI. |
| `--no-block`        | Always exit 0 regardless of result. |
| `--against <ref>`   | Override the diff base ref (bypasses PR discovery). |
| `-h`, `--help`      | Show help. |

---

## Path B — GitHub Actions workflow

A workflow file lives at `.github/workflows/ai-pr-review.yml`. It is
**disabled by default**. To enable it, complete the following steps.

> ⚠️ **Merge, don't overwrite.** If your repository already has files at
> `.github/workflows/ai-pr-review.yml`, `.github/copilot-instructions.md`,
> or `.github/instructions/*.instructions.md`, **do not blindly replace
> them** — open the existing file and merge the relevant sections from the
> bundle. The `copilot-instructions.md` file uses `<!-- BEGIN ... -->` /
> `<!-- END ... -->` markers around its content to make manual merging
> safer.

### Step 1 — Set the AI tool as a repository variable

Repository variables are non-sensitive configuration that workflows can
read. The AI tool name is not a secret.

1. Go to **Settings** → **Secrets and variables** → **Actions**.
2. Click the **Variables** tab.
3. Click **New repository variable**.
4. Name: `AI_REVIEW_TOOL`
5. Value: `claude`, `codex`, or `copilot` (lowercase, exactly).

### Step 2 — Set the API key as a repository secret

The AI CLI needs an API key. Set the secret matching your chosen tool:

1. Go to **Settings** → **Secrets and variables** → **Actions**.
2. Click the **Secrets** tab.
3. Click **New repository secret**.

| Tool | Secret name | Where to get the value |
|---|---|---|
| `claude`  | `ANTHROPIC_API_KEY` | <https://console.anthropic.com/settings/keys> |
| `codex`   | `OPENAI_API_KEY`    | <https://platform.openai.com/api-keys> |
| `copilot` | (none — uses GITHUB_TOKEN) | n/a |

Only set the secret matching your chosen tool. The other secret names can
remain blank.

### Step 3 — Confirm workflow permissions

The workflow declares the permissions it needs:

```yaml
permissions:
  contents: read
  pull-requests: write
```

For most repos this is sufficient — the default `GITHUB_TOKEN` has the
ability to grant these. But if your org enforces restrictive default-token
permissions:

1. Go to **Settings** → **Actions** → **General**.
2. Under **Workflow permissions**, ensure either:
   - "Read and write permissions" is selected (broadest), or
   - "Read repository contents and packages permissions" is selected AND
     the workflow's `permissions:` block is honored (most orgs).

### Step 4 — Enable the trigger

Edit `.github/workflows/ai-pr-review.yml` and change:

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

Commit and push. The next PR opened will trigger an AI review automatically.

### Step 5 — Optional: enable gating

If you want the workflow to **fail the build** on any non-`APPROVE` result
(rather than just posting advisory comments), uncomment the `--gate` line
in the workflow's `Run AI PR review` step:

```yaml
.skills/pr-review/scripts/pr-review-dispatcher.sh \
  --pr "${PR_NUMBER}" \
  --post-comments \
  --gate
```

Combined with a branch protection rule that requires this workflow to pass
(see [Repository rule sets](#repository-rule-sets--requiring-ai-review-before-merge)
below), this makes AI review a true merge gate. Use with care — false
positives become blocking.

---

## Path C — GitHub Copilot PR review

> Requires GitHub Copilot Enterprise (or Copilot Business + Code Review
> early access). Check your org's license before attempting setup.

GitHub Copilot can be added as a reviewer to PRs and will automatically
leave inline comments based on your repo's instructions files. The bundle
ships three instruction files that configure Copilot to apply the same
security + compliance checks as the local skill.

### Files Copilot reads automatically

| File | When Copilot reads it |
|---|---|
| `.github/copilot-instructions.md` | Every PR review — global instructions for this repo |
| `.github/instructions/iac.instructions.md` | Reviews touching IaC files (matched by the file's `applyTo` glob) |
| `.github/instructions/auth.instructions.md` | Reviews touching auth/middleware code |
| `.github/instructions/scripts.instructions.md` | Reviews touching shell scripts |

These files are committed to your repo and pushed like any other change.
Copilot picks them up immediately on the next PR.

### Step 1 — Verify the files are present

```bash
ls .github/copilot-instructions.md
ls .github/instructions/
```

If they aren't, copy them from the delivery bundle (see INSTALL.txt).

> ⚠️ **Merge, don't overwrite.** Repos commonly already have a
> `.github/copilot-instructions.md`. Use the `<!-- BEGIN ai-review-hooks
> PR review instructions -->` / `<!-- END ai-review-hooks PR review
> instructions -->` markers in the bundled file to merge content into your
> existing file rather than replace it.

### Step 2 — Enable Copilot as a reviewer

In each repo where you want auto-review:

1. Open any PR (or create a draft PR for testing).
2. In the right sidebar, click **Reviewers**.
3. If Copilot is available in your org, **Copilot** appears in the list.
   Add it as a reviewer.

If Copilot is not in the list, your org may not have it enabled, or the
license may not cover code review. Contact your GitHub admin.

### Step 3 — Configure repository default reviewers (optional)

To make Copilot the default reviewer on every new PR without manually
adding it each time:

1. Go to **Settings** → **Code review and limits** (or **Branches** →
   **Branch protection rules** → **Edit** the rule for your default
   branch, depending on your GitHub plan).
2. Under **Require a pull request before merging** → **Require review from
   Code Owners**: set up a `CODEOWNERS` file with Copilot listed as an
   owner of relevant paths.

Example `.github/CODEOWNERS`:

```
# Copilot reviews everything by default
*  @github/copilot

# IaC reviews additionally pinged to the SRE team
*.tf  @github/copilot  @your-org/sre
```

> Setup steps for Copilot-as-CODEOWNER vary by GitHub plan and may change.
> Consult <https://docs.github.com/en/copilot/using-github-copilot/code-review/configuring-coding-guidelines>
> for the current procedure.

### Step 4 — Verify Copilot is using your instructions

Open a PR with a deliberate violation — e.g., add `password = "test123"` to
a Terraform `aws_db_instance` resource — and confirm Copilot leaves a
comment in the format:

```
compliance(critical): Hardcoded database password

Description: ... NIST IA-5, CMS ARS IA-5(HIGH) ...

Severity: CRITICAL

Suggestion: ...

```suggestion
manage_master_user_password = true
```
```

If Copilot's comments don't match this format, double-check that
`copilot-instructions.md` is on your default branch and that you've not
overridden it elsewhere.

---

## Fine-grained personal access token setup

A fine-grained PAT is only needed for **local use** — specifically, when a
developer needs to post PR comments via the `pr-review` dispatcher but
prefers a token over `gh auth login` (e.g., in a hardened environment
where browser-based auth is not available). For GitHub Actions, the
default `GITHUB_TOKEN` is sufficient and strictly preferred.

### Why fine-grained, not classic

Classic PATs are scoped at the user level — a single token can do anything
the user can do across every repo they have access to. Fine-grained PATs
are scoped to specific repos and specific permissions, which is the
least-privilege posture.

### Steps to create a token for the `pr-review` dispatcher

1. Go to <https://github.com/settings/personal-access-tokens/new>.
2. Token name: e.g., `pr-review-dispatcher-<repo>`.
3. Expiration: 90 days (recommended). Tokens that never expire are an
   accumulating risk surface.
4. **Resource owner**: your username, or the org that owns the target repo
   if you have access.
5. **Repository access**: **Only select repositories** → pick the specific
   repo(s) where you'll post PR comments. Do not grant `All repositories`.
6. **Permissions** → **Repository permissions** — grant exactly these,
   nothing more:

   | Permission | Access | Why |
   |---|---|---|
   | **Contents** | **Read-only** | `git diff` against the repo; `gh pr view` needs to read PR metadata |
   | **Metadata** | **Read-only** | Mandatory baseline; granted automatically |
   | **Pull requests** | **Read and write** | Post review with inline comments |

   Leave everything else (`Actions`, `Workflows`, `Secrets`, `Issues`,
   `Administration`, etc.) on **No access**.

7. Click **Generate token**. Copy the value once — GitHub will not show it
   again.

### Using the token

Set it as an environment variable that `gh` and the dispatcher pick up
automatically:

```bash
# Persistent, macOS / zsh
echo 'export GH_TOKEN=ghp_yourTokenValueHere' >> ~/.zshrc
source ~/.zshrc

# Or per-shell, if you don't want to persist
export GH_TOKEN=ghp_yourTokenValueHere
```

Verify:

```bash
gh auth status
# Should show:  "Logged in as <you> via token (GH_TOKEN env var)"
#               with the listed permissions
```

> Treat the token like any other secret. Never commit it. Never paste it
> in chat or PR comments. If it leaks, revoke it at
> <https://github.com/settings/personal-access-tokens> and create a new one.

### Token rotation

When the token expires (or sooner if you suspect compromise):

1. Generate a new token at the same URL with the same permissions.
2. Replace the value in `~/.zshrc` (or wherever you stored it).
3. Revoke the old token.
4. Run `gh auth status` to confirm the new token works.

---

## Repository rule sets — requiring AI review before merge

Once you have one or more review paths working, you can make AI review a
**required check** before merge via repository rule sets (the modern
replacement for branch protection rules).

### Why rule sets, not branch protection rules

Rule sets (introduced in 2023) supersede branch protection rules. They
support:

- Multiple rules per branch with priorities
- Inheritance from org level
- Bypass lists for specific users or apps
- More expressive matching (e.g., target only branches matching a pattern)

If your repo still uses classic branch protection rules, the same concepts
apply — just under a different UI.

### Step 1 — Pick the check to require

| Check | Source | Source type | Status check name |
|---|---|---|---|
| AI PR review (Path B) | `.github/workflows/ai-pr-review.yml` | GitHub Actions | `pr-review` (the job id) |
| Copilot review (Path C) | Copilot Enterprise | Application | `github-advanced-security/copilot-pull-request-review` (varies) |

The GitHub Actions job becomes a status check after it has run at least
once on a PR targeting your protected branch. You may need to push a
throwaway PR to make the check appear in the rule set's selector.

### Step 2 — Create the rule set

1. Go to **Settings** → **Rules** → **Rulesets** → **New ruleset** →
   **New branch ruleset**.
2. Name: e.g., `Require AI review for protected branches`.
3. **Enforcement status**: start with **Evaluate** (dry-run) to see what
   would be blocked, then switch to **Active** once you're confident.
4. **Target branches**: select the branches you want to protect
   (typically `main`, `master`, `develop`, or whatever your default is).
5. **Rules** → toggle on **Require status checks to pass**:
   - Click **Add checks** and search for the status check name from
     Step 1 (e.g., `pr-review`).
   - Optionally toggle **Require branches to be up to date before merging**.
6. (Recommended) Also toggle on **Require a pull request before merging**
   with **Required approvals: 1** so a human still has to approve.

### Step 3 — Set up bypass list carefully

Under **Bypass list**, decide who can override the rule. Typical setups:

- **No bypass** — strictest. Even repo admins can't merge without the check
  passing. Use for highly regulated systems.
- **Repository admins** — admins can force-merge in emergencies. Default
  for most teams.
- **Specific role** — e.g., a `security-admins` team. Useful when you want
  a documented escalation path.

For systems under FedRAMP / FISMA / HIPAA scrutiny, document the bypass
list in your system's POA&M and review it quarterly.

### Step 4 — Test the rule

1. Open a PR with a deliberate violation (e.g., a hardcoded password).
2. Wait for the AI review check to run.
3. Confirm the merge button is greyed out until the check passes (or
   shows as `failure` if you're using the `--gate` flag in the workflow).
4. Fix the issue, re-push, confirm the check goes green and merge becomes
   available.

---

## Troubleshooting

### `gh pr view` returns nothing on the current branch

Your branch isn't associated with an open PR yet. Either:

- Push the branch and open a PR via the GitHub UI or `gh pr create`, then
  re-run the dispatcher.
- Pass `--pr <number>` explicitly.

### `gh: command not found`

Install the GitHub CLI:

```bash
brew install gh        # macOS
# or follow https://github.com/cli/cli for other platforms
gh auth login
```

### `gh api` call fails with `403 Resource not accessible by integration`

Your token (or the workflow's `GITHUB_TOKEN`) doesn't have
`pull-requests: write` permission. For local use, regenerate the
fine-grained PAT with the correct permissions. For CI, verify the
workflow's `permissions:` block includes `pull-requests: write`.

### `gh api` call fails with `422 Validation failed`

The most common cause is a line number in the JSON payload that doesn't
exist in the PR diff. This indicates the AI returned a line number outside
the modified-line set. Re-run with `--json-only` to inspect the payload
and identify the bad line.

### Copilot review doesn't follow the template

Verify the instructions files are on the **default branch** (not just your
PR branch). Copilot reads instructions from the default branch's state, so
new instructions don't take effect until they're merged.

Also verify the `applyTo` glob in each path-specific file actually matches
the files you expect:

```bash
# Local sanity check (matches with bash globstar)
shopt -s globstar
ls **/*.tf  # should match the same files the iac.instructions.md applies to
```

### CI workflow runs but doesn't post comments

Check the workflow logs for the dispatcher's output. The most common
issues:

- `AI_REVIEW_TOOL` variable not set → workflow fails in Step 1
- API key secret not set → AI CLI errors
- `pull-requests: write` permission missing → `gh api` fails with 403
- AI returned no `<!-- AI_REVIEW_JSON_BEGIN -->` block → dispatcher errors
  and exits 1. This can happen on transient model issues; retry the workflow.

### My team uses different AI tools

The dispatcher selects based on `AI_REVIEW_TOOL`, so each developer can use
whichever they prefer locally. For CI, you must pick one (the `vars.AI_REVIEW_TOOL`
repository variable). Common choice: use the team's "official" tool in CI,
let developers use anything locally.
