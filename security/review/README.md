# AI-Assisted Pre-Commit Review — Setup & Operations Guide

This repository ships two pre-commit hooks that run AI-assisted reviews on
your uncommitted changes:

| Skill | What it does | When it runs |
|---|---|---|
| **`code-security`** | Detects secrets, PII, PHI, OWASP Top 10 issues, and general security defects | On every commit |
| **`iac-compliance`** | Reviews infrastructure-as-code against **CMS ARS 5.1** and **NIST SP 800-53 Rev 5** controls | Only when IaC files are staged |

Both hooks support **three AI coding assistants** — Claude Code, OpenAI Codex
CLI, and GitHub Copilot CLI — and each developer chooses which one to use
locally. Skills are stored in a tool-neutral location and copied into the
chosen tool's directory on demand, so a repo isn't branded with any
particular AI vendor's directory name.

Both hooks **block** commits on critical, high, or medium findings, and
**warn without blocking** on low findings.

---

## Contents

1. [Architecture overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [AI tool selection (`AI_REVIEW_TOOL`)](#ai-tool-selection-ai_review_tool)
5. [Per-assistant setup](#per-assistant-setup)
6. [Daily workflow](#daily-workflow)
7. [Understanding the report](#understanding-the-report)
8. [Manual and ad-hoc invocation](#manual-and-ad-hoc-invocation)
9. [PR-level review](#pr-level-review)
10. [Codebase audit](#codebase-audit)
11. [Editing skills (keeping copies in sync)](#editing-skills-keeping-copies-in-sync)
12. [Remediation guidance — code security](#remediation-guidance--code-security)
13. [Remediation guidance — IaC compliance](#remediation-guidance--iac-compliance)
14. [False positives](#false-positives)
15. [Bypassing a hook](#bypassing-a-hook)
16. [CI integration](#ci-integration)
17. [Troubleshooting](#troubleshooting)

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  git commit                                                          │
│      │                                                               │
│      ▼                                                               │
│  pre-commit framework                                                │
│      │                                                               │
│      ├──▶ .skills/code-security/scripts/code-security-...─┐          │
│      │                                                    │          │
│      └──▶ .skills/iac-compliance/scripts/iac-compliance-..┤          │
│                                                           ▼          │
│                            .skills/_lib/ai-review-dispatch.sh        │
│                                              │                       │
│                            reads AI_REVIEW_TOOL                      │
│                                              │                       │
│              ┌──────────────────┬────────────┴───────────┐           │
│              ▼                  ▼                        ▼           │
│         claude -p          codex exec              copilot -p        │
│       (Claude Code)     (--sandbox read-only)   (GitHub Copilot)     │
│              │                  │                        │           │
│              └──────────────────┼────────────────────────┘           │
│                                 ▼                                    │
│         AI reads SKILL.md, runs review, emits result marker:         │
│         <<<AI_REVIEW_RESULT:PASS|WARN|BLOCK>>>                       │
│                                 │                                    │
│                                 ▼                                    │
│              Dispatcher parses marker, exits 0 or 1                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Repository layout

```
.skills/                                               ← canonical (tool-neutral)
├── _lib/
│   └── ai-review-dispatch.sh                          ← shared dispatch logic
├── code-security/
│   ├── SKILL.md
│   └── scripts/code-security-hook-dispatcher.sh
├── iac-compliance/
│   ├── SKILL.md
│   └── scripts/iac-compliance-hook-dispatcher.sh
├── pr-review/                                         ← PR-level review skill
│   ├── SKILL.md
│   └── scripts/pr-review-dispatcher.sh
├── codebase-audit/                                    ← full-repo audit skill
│   ├── SKILL.md
│   └── scripts/codebase-audit-dispatcher.sh
└── finding-adjudication/                              ← second-opinion adjudicator
    ├── SKILL.md
    └── scripts/finding-adjudication-dispatcher.sh

.github/                                               ← GitHub-specific config
├── copilot-instructions.md                            ← global Copilot PR review
├── instructions/
│   ├── iac.instructions.md                            ← path-scoped (IaC files)
│   ├── auth.instructions.md                           ← path-scoped (auth code)
│   └── scripts.instructions.md                        ← path-scoped (shell)
└── workflows/
    └── ai-pr-review.yml                               ← GitHub Actions PR review (opt-in)

scripts/
└── sync-skills.sh                                     ← canonical → per-tool sync

docs/
└── PR_REVIEW_SETUP.md                                 ← PR-review setup runbook

.pre-commit-config.yaml
.gitignore                                             ← gitignores derived dirs
README.md
```

**Derived per-developer directories** (each developer creates only the one
matching their `AI_REVIEW_TOOL`; these are gitignored):

```
.claude/skills/<skill>/SKILL.md          ← created locally if AI_REVIEW_TOOL=claude
.codex/skills/<skill>/SKILL.md           ← created locally if AI_REVIEW_TOOL=codex
.github/copilot/skills/<skill>/SKILL.md  ← created locally if AI_REVIEW_TOOL=copilot
```

Each contains derived copies of `code-security/SKILL.md`,
`iac-compliance/SKILL.md`, `pr-review/SKILL.md`, `codebase-audit/SKILL.md`, and
`finding-adjudication/SKILL.md`. A developer using only Codex will see `.skills/`
and `.codex/` in their checkout. No `.claude/` or `.github/copilot/skills/`
directories ever appear unless they choose those tools.

> **Note on `.github/copilot/`:** The `.github/copilot/skills/` subdirectory
> is **derived** (gitignored, per-developer). The
> `.github/copilot-instructions.md` file at the same level is **committed**
> — it configures the Copilot auto-review path described in
> [`docs/PR_REVIEW_SETUP.md`](docs/PR_REVIEW_SETUP.md). The two coexist
> under `.github/copilot/` and `.github/` with different commit statuses,
> which is intentional.

Skills follow the [Agent Skills standard](https://agentskills.io): each
`SKILL.md` has YAML frontmatter (`name`, `description`) followed by procedural
markdown that the AI loads at runtime.

### Three layers of review

This project ships **three layers** of AI-assisted review:

| Layer | Where it runs | What it reviews | When it fires |
|---|---|---|---|
| **Pre-commit** | Developer's machine | The staged diff for one commit | `git commit`, before the commit is recorded |
| **PR-level**   | Developer's machine *or* GitHub Actions *or* GitHub Copilot | The full diff between the PR's base ref and HEAD | On demand, on PR open/sync, or as part of Copilot auto-review |
| **Codebase audit** | Developer's machine *or* CI | The full content of every reviewable file in the repo, batched by directory | On demand (e.g., quarterly baseline, pre-assessment review, new-repo onboarding) |

The pre-commit layer is the primary gate — it blocks Critical/High/Medium
findings before they enter the repository. The PR-level layer is a backstop
that catches issues emerging only when changes are composed across commits
or that arrive via the GitHub web UI. The codebase-audit layer is for one-
time and periodic full reviews of the codebase at rest — useful when
onboarding a repo into the review system, before a compliance assessment,
or for routine quarterly baselines.

PR-level review is configured separately from pre-commit. See
[`docs/PR_REVIEW_SETUP.md`](docs/PR_REVIEW_SETUP.md) for that setup, which
covers three independent paths:

- **Path A** — Local `pr-review` skill (any of the three AI CLIs)
- **Path B** — GitHub Actions workflow (opt-in, shipped as
  `.github/workflows/ai-pr-review.yml`)
- **Path C** — GitHub Copilot PR auto-review (requires Copilot Enterprise)

You can use any combination of paths; most teams pair Path A + Path B.

The codebase-audit layer is documented in this README under
[Codebase audit](#codebase-audit).

### Second-opinion adjudication (false-positive reduction)

The **pre-commit** and **codebase-audit** layers are wrapped by an independent
**adjudication pass** that cuts false positives before they reach you — no
suppression files, no inline annotations, no manual bookkeeping.

When a first-pass review reports findings, the dispatcher invokes the
`finding-adjudication` skill: a **fresh agent**, with no memory of the first
pass, re-inspects the cited code and classifies each finding as **confirmed**,
**false positive**, or **overstated** (downgraded), each with a one-line reason.
The gate is then decided from the confirmed findings only, and the dismissed /
downgraded findings are shown in a transparency section so nothing is silently
hidden.

Key properties:

- **Cost scales with noise, not commit volume.** A clean first pass (`PASS` /
  `CLEAN`) is final and triggers **no** second call — most commits stay
  single-pass and fast. Only finding-bearing reviews pay for adjudication, which
  is exactly when a second opinion is worth it.
- **Tool-neutral.** It runs on the same `AI_REVIEW_TOOL` CLI as the first pass.
  Set `AI_ADJUDICATION_MODEL` to run the second opinion on a *different model*
  of that same CLI for stronger independence; leave it unset to use the default.
- **Security-first.** The adjudicator may only confirm, dismiss, or downgrade —
  never escalate or invent findings — and must keep any finding it cannot
  positively show to be benign. If the pass fails or returns no marker, the
  stricter first-pass result stands.
- **Opt-out.** Disable with `AI_ADJUDICATION=0` (env) or `--no-adjudicate` (flag).

PR-level review is **not** adjudicated (the Copilot path can't be customized for
it). The full skill contract is in `.skills/finding-adjudication/SKILL.md`.

---

## Prerequisites

Three pieces are required regardless of which AI assistant you use:

### 1. `pre-commit`

```bash
# macOS
brew install pre-commit

# Linux / Windows (pip)
pip install pre-commit

# Verify
pre-commit --version
```

Full docs: <https://pre-commit.com/#installation>

### 2. Bash and `git`

Both ship with macOS and Linux. The dispatchers are written for **bash 3.2+**
— the version macOS still ships as `/bin/bash` — so no Homebrew bash upgrade is
needed. They are POSIX-bash, not POSIX-sh; `/bin/bash` must be available.

### 3. **One** of the three AI CLIs

You only need the one matching your chosen `AI_REVIEW_TOOL`. See the
[Per-assistant setup](#per-assistant-setup) section below.

---

## Installation

Run these commands from the **root of your repository**.

> ⚠️ **Merge, don't overwrite.** Several files in this bundle have names
> that commonly exist in repos already. Before copying any of the files
> below, check whether the destination already exists, and if it does,
> **merge** the relevant content rather than replace the whole file. Files
> at risk of collision:
>
> | File | Common in existing repos? | Merge strategy |
> |---|---|---|
> | `.pre-commit-config.yaml` | Often | Append the hooks under your existing `repos:` block |
> | `.gitignore` | Almost always | Append the snippet — see the bundled `.gitignore` |
> | `README.md` | Always | This is *this* file; you're reading it — don't overwrite your project README |
> | `.github/copilot-instructions.md` | Increasingly common | Use the `<!-- BEGIN -->` / `<!-- END -->` markers in the bundled file to merge into your existing one |
> | `.github/workflows/ai-pr-review.yml` | Rarely | Unique name; safe to add. Rename your existing one if you do collide. |
> | `.github/instructions/*.instructions.md` | Rarely | Check whether your team already has path-scoped Copilot instructions; merge by glob if so |
>
> If unsure, copy the bundled file alongside your existing one (e.g.,
> `README.bundled.md`), compare side-by-side, and merge by hand.

### Step 1 — Copy files into your repository

Drop the provided files into the matching locations (merging with existing
files where applicable — see the callout above):

```text
<repo-root>/
├── .pre-commit-config.yaml
├── .gitignore               (append the snippet from the bundle's .gitignore)
├── README.md
├── .skills/
│   ├── _lib/ai-review-dispatch.sh
│   ├── code-security/
│   │   ├── SKILL.md
│   │   └── scripts/code-security-hook-dispatcher.sh
│   ├── iac-compliance/
│   │   ├── SKILL.md
│   │   └── scripts/iac-compliance-hook-dispatcher.sh
│   ├── pr-review/
│   │   ├── SKILL.md
│   │   └── scripts/pr-review-dispatcher.sh
│   ├── codebase-audit/
│   │   ├── SKILL.md
│   │   └── scripts/codebase-audit-dispatcher.sh
│   └── finding-adjudication/
│       ├── SKILL.md
│       └── scripts/finding-adjudication-dispatcher.sh
├── .github/
│   ├── copilot-instructions.md
│   ├── instructions/
│   │   ├── iac.instructions.md
│   │   ├── auth.instructions.md
│   │   └── scripts.instructions.md
│   └── workflows/
│       └── ai-pr-review.yml
├── docs/
│   └── PR_REVIEW_SETUP.md
└── scripts/sync-skills.sh
```

> See **`INSTALL.txt`** in the delivery bundle for the exact `mkdir`/`cp`
> command sequence.

### Step 2 — Make the scripts executable

```bash
chmod +x .skills/_lib/ai-review-dispatch.sh
chmod +x .skills/code-security/scripts/code-security-hook-dispatcher.sh
chmod +x .skills/iac-compliance/scripts/iac-compliance-hook-dispatcher.sh
chmod +x .skills/pr-review/scripts/pr-review-dispatcher.sh
chmod +x .skills/codebase-audit/scripts/codebase-audit-dispatcher.sh
chmod +x .skills/finding-adjudication/scripts/finding-adjudication-dispatcher.sh
chmod +x scripts/sync-skills.sh
```

### Step 3 — Set `AI_REVIEW_TOOL`

You must set this **before running the sync step**, because `sync-skills.sh`
uses it to decide which derived directory to create. See the
[next section](#ai-tool-selection-ai_review_tool).

### Step 4 — Install your chosen AI CLI

See [Per-assistant setup](#per-assistant-setup).

### Step 5 — Sync the skill files into your tool directory

```bash
scripts/sync-skills.sh
```

If `AI_REVIEW_TOOL=claude`, this creates `.claude/skills/...`. If
`AI_REVIEW_TOOL=codex`, it creates `.codex/skills/...`. And so on. The
derived directory is gitignored — it's local to your checkout.

### Step 6 — Install the pre-commit hooks

```bash
pre-commit install
```

You should see:

```
pre-commit installed at .git/hooks/pre-commit
```

### Step 7 — Commit the configuration

```bash
git add .pre-commit-config.yaml .gitignore .skills/ scripts/ README.md
git commit -m "chore: add AI-assisted code security & IaC compliance hooks"
```

> The first commit runs the review on itself. That's expected.

### Step 8 — Team onboarding

Every developer who clones the repo must:

1. Install pre-commit + their chosen AI CLI
2. Set `AI_REVIEW_TOOL` in their shell
3. Run `scripts/sync-skills.sh` (creates their local derived directory)
4. Run `pre-commit install`

Add this to your project's `Makefile`:

```makefile
setup:
	@if [ -z "$$AI_REVIEW_TOOL" ]; then \
	  echo "ERROR: AI_REVIEW_TOOL is not set."; \
	  echo "Set it to one of: claude | codex | copilot, then re-run 'make setup'."; \
	  echo "See README.md for details."; \
	  exit 1; \
	fi
	scripts/sync-skills.sh
	pre-commit install
```

---

## AI tool selection (`AI_REVIEW_TOOL`)

The `AI_REVIEW_TOOL` environment variable selects which AI assistant will run
the reviews — **and** which derived skill directory `scripts/sync-skills.sh`
will create. It must be set to **exactly one of**:

| Value | AI assistant | CLI invoked | Derived directory |
|---|---|---|---|
| `claude` | Anthropic Claude Code | `claude -p "<prompt>"` | `.claude/skills/` |
| `codex` | OpenAI Codex CLI | `codex exec --sandbox read-only --skip-git-repo-check "<prompt>"` | `.codex/skills/` |
| `copilot` | GitHub Copilot CLI (agentic) | `copilot -p "<prompt>"` | `.github/copilot/skills/` |

If the variable is unset or has any other value, the dispatcher exits with
code 2 (configuration error) and refuses to run.

> **Switching tools later:** Just change `AI_REVIEW_TOOL` and re-run
> `scripts/sync-skills.sh`. Your old derived directory can be deleted; it's
> gitignored.
>
> **Using multiple tools (rare):** Set `AI_REVIEW_SYNC_TARGETS=claude,codex`
> to keep multiple derived directories in sync. `AI_REVIEW_TOOL` still
> controls which one is actually invoked at commit time.

### Adjudication settings (optional)

Two optional variables tune the [second-opinion adjudication
pass](#second-opinion-adjudication-false-positive-reduction):

| Variable | Default | Effect |
|---|---|---|
| `AI_ADJUDICATION` | enabled | Set to `0` to disable the adjudication pass entirely (first-pass results then stand). |
| `AI_ADJUDICATION_MODEL` | unset | Model name passed to the **same** `AI_REVIEW_TOOL` CLI for the adjudication pass only. Unset = the tool's default model. Use it to get a second opinion from a different model on the same CLI — e.g. a Claude shop running the first pass on one model and adjudication on another. (Confirm your CLI's accepted model names: `claude --model`, `codex exec --model`, or the Copilot equivalent.) |

Both are optional; the system works out of the box with adjudication on and the
default model. Adjudication never fires on a clean first pass, so leaving it on
adds no cost to commits that have no findings.

### macOS setup

#### Persistent (recommended)

For **zsh** (the macOS default since Catalina):

```bash
echo 'export AI_REVIEW_TOOL=claude' >> ~/.zshrc   # or codex / copilot
source ~/.zshrc
```

For **bash**:

```bash
echo 'export AI_REVIEW_TOOL=claude' >> ~/.bash_profile
source ~/.bash_profile
```

Verify:

```bash
echo "$AI_REVIEW_TOOL"
# should print: claude   (or codex / copilot)
```

#### Per-project (via direnv)

If you work in multiple repos that use different AI tools, install
[direnv](https://direnv.net/):

```bash
brew install direnv
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc      # or bash equivalent
```

Then in your repo:

```bash
echo 'export AI_REVIEW_TOOL=claude' >> .envrc
direnv allow
```

`.envrc` should be in `.gitignore` (developer-local) or, if your whole team
uses the same tool, committed.

#### Current shell only (one-off)

```bash
export AI_REVIEW_TOOL=claude
```

### IDE-launched terminals — important footgun

VS Code, JetBrains IDEs, GitHub Desktop, SourceTree, and other GUI git
clients **do not always inherit** your login shell's environment. If you
commit from inside an IDE and see `AI_REVIEW_TOOL is not set`, the IDE's git
process did not pick up your `~/.zshrc`.

**Fixes:**

- **VS Code:** Settings → "Terminal › Integrated: Inherit Env" should be
  `true` (default). For the built-in git operations (not the terminal), set
  the variable in `~/.zshenv` instead of `~/.zshrc`. `~/.zshenv` is loaded
  by **every** zsh invocation, including non-interactive ones.
  ```bash
  echo 'export AI_REVIEW_TOOL=claude' >> ~/.zshenv
  ```
- **JetBrains IDEs:** Settings → Tools → Terminal → "Shell integration" + use
  `~/.zshenv` as above.
- **Any GUI git client:** Set the variable in `~/.zshenv` (or
  `/etc/launchd.conf` for system-wide persistence on macOS). After editing,
  fully quit and relaunch the application — login items pick up env vars
  only at launch.

To verify your IDE sees the variable, open the IDE's integrated terminal and
run `echo $AI_REVIEW_TOOL`.

---

## Per-assistant setup

### Option A — Claude Code

```bash
# Install
npm install -g @anthropic-ai/claude-code

# Verify
claude --version

# Authenticate (one-time, interactive)
claude
```

Set and sync:

```bash
export AI_REVIEW_TOOL=claude
scripts/sync-skills.sh    # creates .claude/skills/
```

Docs: <https://docs.anthropic.com/en/docs/claude-code>

### Option B — OpenAI Codex CLI

```bash
# Install
npm install -g @openai/codex
# (or follow https://github.com/openai/codex for alternative install methods)

# Verify
codex --version

# Authenticate
codex login     # interactive; follows your OPENAI_API_KEY env var or browser auth
```

Set and sync:

```bash
export AI_REVIEW_TOOL=codex
scripts/sync-skills.sh    # creates .codex/skills/
```

**Sandbox mode:** The dispatcher invokes Codex with `--sandbox read-only`,
which permits filesystem reads (necessary for `git diff` and SKILL.md reads)
but blocks writes and network egress from the AI. This is the appropriate
posture for a pre-commit hook that should observe but not modify your code.

Docs: <https://github.com/openai/codex>

### Option C — GitHub Copilot CLI (agentic)

> The hook targets the **agentic** Copilot CLI (`copilot -p`), not the older
> `gh copilot suggest`/`explain` shell-assistant. The agentic CLI is required
> because pre-commit reviews need long-form, structured output.

```bash
# Install (see https://github.com/github/copilot-cli for current method)
# At time of writing the recommended method is:
npm install -g @github/copilot

# Verify
copilot --version

# Authenticate
copilot login
```

Set and sync:

```bash
export AI_REVIEW_TOOL=copilot
scripts/sync-skills.sh    # creates .github/copilot/skills/
```

Docs: <https://github.com/github/copilot-cli>

---

## Daily workflow

Every `git commit` triggers the hooks automatically:

```
[code-security] AI tool resolved: claude
[code-security] Running Code Security Review on git diff --cached via claude...
────────────────────────────────────────────────────────────
## Security Review Report
**Scope:** Staged changes (git diff --cached)
**Files reviewed:** src/api/auth.py, src/api/users.py
**Context files loaded:** src/models/user.py

(no findings)

<<<AI_REVIEW_RESULT:PASS>>>
────────────────────────────────────────────────────────────
[code-security] ✅  Code Security Review passed. No findings detected.
```

The `iac-compliance` hook runs only when at least one IaC file is staged. It
short-circuits silently otherwise.

---

## Understanding the report

The dispatcher emits one of three outcomes:

| Symbol | Label | Meaning |
|--------|-------|---------|
| 🚫 | **BLOCK** | Critical, high, or medium findings present. **Commit is prevented.** Resolve before proceeding. |
| ⚠️ | **WARN**  | Low findings only. Commit is allowed but findings should be reviewed. |
| ✅ | **PASS**  | No findings of any severity. |

Each finding shows: severity, category (or NIST/ARS control ID for IaC),
file/line, the finding itself, evidence (redacted for secrets), and specific
remediation steps.

### Severity definitions — code-security

| Severity | Examples |
|---|---|
| 🔴 **Critical** | Hardcoded secrets, API keys, real PHI in source, direct RCE, auth bypass |
| 🟠 **High**     | Real PII; SQL/command injection with no mitigation; broken access control; deprecated crypto |
| 🟡 **Medium**   | Injection with partial mitigation; suspicious-but-uncertain PII; missing input validation on internal endpoints |
| 🔵 **Low**      | Hygiene issues; placeholder-like PII patterns; minor hardening opportunities |

### Severity definitions — iac-compliance

| Severity | Examples |
|---|---|
| 🔴 **Critical** | SSH/RDP open to `0.0.0.0/0`; IAM `Action:*` + `Resource:*` with no conditions; all S3 public access blocks disabled; publicly accessible RDS |
| 🟠 **High**     | IAM AdministratorAccess; DB ports open to internet; encryption at rest disabled; CloudTrail off; hardcoded passwords; deprecated Lambda runtime; production deletion-protection off |
| 🟡 **Medium**   | No WAF on public ALB; missing VPC endpoints; 2+ required tags absent; KMS default key instead of CMK; log retention unset; GuardDuty absent |
| 🔵 **Low**      | 1 required tag missing; image tagged `latest`; Lambda X-Ray tracing off; module not version-pinned; missing `Name`/`description` |

---

## Manual and ad-hoc invocation

The dispatchers are designed to be runnable standalone, not just from
pre-commit.

```bash
# Run on currently staged changes (same as pre-commit would)
.skills/code-security/scripts/code-security-hook-dispatcher.sh

# Show what the dispatcher WOULD do, without invoking the AI
.skills/code-security/scripts/code-security-hook-dispatcher.sh --dry-run

# Run the full review but never exit non-zero (for testing in CI)
.skills/code-security/scripts/code-security-hook-dispatcher.sh --no-block

# Review the diff between a ref and HEAD (ad-hoc, no staging required)
.skills/code-security/scripts/code-security-hook-dispatcher.sh --against HEAD~1
.skills/code-security/scripts/code-security-hook-dispatcher.sh --against main
.skills/iac-compliance/scripts/iac-compliance-hook-dispatcher.sh --against origin/main
```

You can also run hooks via the pre-commit runner:

```bash
pre-commit run code-security                  # against staged changes
pre-commit run code-security --all-files      # against the whole repo
pre-commit run iac-compliance                 # only runs if IaC files match
```

### Flags reference

| Flag | Effect |
|---|---|
| `-n`, `--dry-run`     | Print resolved tool, prompt, and file list; do not invoke AI. Exits 0. |
| `--no-block`          | Run the full review but always exit 0, regardless of findings. |
| `--no-adjudicate`     | Skip the second-opinion adjudication pass (same as `AI_ADJUDICATION=0`). |
| `--against <ref>`     | Review the diff between `<ref>` and `HEAD` (instead of staged). |
| `-h`, `--help`        | Show help. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | PASS or WARN (commit may proceed); or `--dry-run` / `--no-block` |
| `1` | BLOCK — findings require remediation; or unrecoverable runtime error |
| `2` | Configuration error (`AI_REVIEW_TOOL` unset or invalid; bad flags) |

---

## PR-level review

The pre-commit layer blocks issues per-commit. The PR-level layer reviews
the **full diff** between the PR's base ref and HEAD — useful for catching
issues that emerge only when changes are composed across commits, or that
reach the repo via bypassed hooks or the GitHub web UI.

There are three independent paths to enable PR-level review. Use any
combination; most teams pair the first two.

### Path A — Local `pr-review` skill

A developer runs the local dispatcher to get an AI review of their PR
diff. Results post as inline review comments on the PR.

```bash
# From the PR branch (auto-discovers PR via gh CLI):
.skills/pr-review/scripts/pr-review-dispatcher.sh --post-comments

# Or explicitly:
.skills/pr-review/scripts/pr-review-dispatcher.sh --pr 1234 --post-comments

# Self-review locally without posting (before pushing):
.skills/pr-review/scripts/pr-review-dispatcher.sh --against origin/main
```

Requires the `gh` CLI to be installed and authenticated (or a fine-grained
PAT exported as `GH_TOKEN`).

The dispatcher runs the same security + compliance checks as the pre-commit
skills, but applied to the **PR-scoped diff**, and produces inline comments
in [Conventional Comments](https://conventionalcomments.org) format with
suggestion blocks the author can one-click apply. Each comment is labeled
either `security(<severity>):` or `compliance(<severity>):`.

Full setup and usage: [`docs/PR_REVIEW_SETUP.md`](docs/PR_REVIEW_SETUP.md)
(section "Path A — Local pr-review skill").

### Path B — GitHub Actions workflow

The bundle ships `.github/workflows/ai-pr-review.yml` which runs the same
`pr-review` skill on every PR and posts inline comments via the workflow's
`GITHUB_TOKEN`. The workflow is **disabled by default** — to enable, follow
the steps in [`docs/PR_REVIEW_SETUP.md`](docs/PR_REVIEW_SETUP.md)
(section "Path B — GitHub Actions workflow"):

1. Set the `AI_REVIEW_TOOL` repository variable
2. Set the API-key secret matching your tool
3. Uncomment the `pull_request:` trigger in the workflow

### Path C — GitHub Copilot PR auto-review

If your org has Copilot Enterprise (or Copilot Business + Code Review),
Copilot can be added as a default reviewer on PRs. The bundle ships
configuration files that align Copilot's review behavior with the rest of
the system:

- `.github/copilot-instructions.md` — global instructions (severity ladder,
  comment template, labels)
- `.github/instructions/iac.instructions.md` — heightened compliance
  attention on IaC files
- `.github/instructions/auth.instructions.md` — heightened security
  attention on auth code
- `.github/instructions/scripts.instructions.md` — heightened attention on
  shell scripts (the dispatchers themselves are reviewed under this rule)

Setup steps: [`docs/PR_REVIEW_SETUP.md`](docs/PR_REVIEW_SETUP.md)
(section "Path C — GitHub Copilot PR review").

### Requiring AI review before merge

Once you have one or more paths working, you can require AI review as a
**merge gate** via repository rule sets. See
[`docs/PR_REVIEW_SETUP.md`](docs/PR_REVIEW_SETUP.md)
(section "Repository rule sets") for the full procedure.

---

## Codebase audit

The pre-commit and PR-level layers review **changes**. The codebase-audit
layer reviews **state** — the full content of every reviewable file in
the repository, batched by directory.

> **When to use:** baseline audits when onboarding a new codebase,
> periodic full reviews (quarterly is common for FedRAMP / FISMA / HIPAA-
> bound systems), pre-assessment audits before an external review, or
> one-time deep-dives on suspect subsystems.
>
> **When NOT to use:** routine development. The pre-commit and PR-review
> layers are tuned for diffs and run in seconds, while this layer scans
> the full repo and can run for an hour or more (and costs accordingly).

### Quick start

```bash
# Audit everything at default threshold (low — all severities reported):
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh

# Audit one subtree, only Critical and High findings:
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh \
  --scope src/ --min-severity high

# Audit several specific subtrees (--scope is repeatable):
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh \
  --scope src/api --scope infra

# See what would be audited without invoking the AI:
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --list-batches

# Re-audit everything (skip resume mode):
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --force

# Also emit SARIF for ingestion into security tooling:
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --sarif

# Speed up a large audit by auditing several directories concurrently:
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --jobs 8
```

### How it works

The dispatcher enumerates tracked files (via `git ls-files`), filters out
known-skippable directories (`node_modules/`, `.venv/`, `vendor/`,
`audit-reports/` itself, etc.) and binary-by-extension files, then groups
the remainder by directory. Each directory becomes one **batch** — the AI
is invoked once per batch with the codebase-audit skill, the directory in
scope, and the appropriate context-loading rules.

### Speeding up large audits (`--jobs` / `AUDIT_JOBS`)

Because each batch is self-contained — one directory in, one report out, with
its own bounded context — batches run independently. By default the dispatcher
processes **4 at a time**; raise or lower that with `--jobs N` (or the
`AUDIT_JOBS` env var), and `--jobs 1` forces the original fully serial run.

```bash
AUDIT_JOBS=8 .skills/codebase-audit/scripts/codebase-audit-dispatcher.sh
```

Batch *planning* stays single-threaded and deterministic, so the set of reports
and the `_INDEX.md` are identical regardless of `--jobs` — only execution fans
out. Each worker uses the same configured `AI_REVIEW_TOOL`; the practical
ceiling on `N` is your AI vendor's rate limit (too high invites HTTP 429s). A
worker whose AI call fails writes no report, so a later resume run (the default)
simply picks that directory back up.

Output goes to `audit-reports/`:

```
audit-reports/
├── _INDEX.md                                ← start here; findings-first triage view
├── _findings.sarif                          ← if --sarif (merged across batches)
├── src__api__auth.md                        ← per-directory finding reports
├── src__api__users.md                       ← (slashes in paths → __ in filenames)
├── infra__production.md
└── ...
```

### Reading the output

Start at `audit-reports/_INDEX.md`. It's built **findings-first** so you
never have to hunt through the clean reports:

- A **"Directories with findings"** table at the top lists *only* the
  directories that have findings, sorted **worst-first** (by Critical, then
  High, Medium, Low), with per-severity columns and grand totals. Each
  directory links straight to its report's findings (`…/<dir>.md#findings`).
- The **clean directories** are reduced to a count and a collapsed
  `<details>` list at the bottom — present for completeness, out of the way.
- A header line summarizes the split, e.g. `Directories audited: 152 (8
  with findings, 144 clean)`.

So in a typical repo where most directories are clean, you open one file and
immediately see the handful that need attention, highest severity first. If
nothing was found, the top section is replaced with a ✅ clean-bill note.

Recommended triage order (the index repeats this):

1. **All Critical findings, every directory** — same-day attention
2. **High findings in security-sensitive directories** (auth, payments,
   IaC roots) — 1–2 sprint priorities
3. **High findings elsewhere** — quarter-level backlog
4. **Medium and Low findings** — review for patterns; a single recurring
   Medium across many files often indicates a systemic gap worth a
   focused improvement project rather than per-instance fixes

> **Tip:** to list the report files that contain findings directly from the
> shell (clean reports have no finding entries):
> ```bash
> grep -rl '^#### ' audit-reports/
> ```

### Resume mode (default)

The dispatcher skips any directory whose report already exists in
`audit-reports/`. This is what makes long audits practical — a 45-minute
audit interrupted at the 30-minute mark resumes without redoing work.
Pass `--force` to override and re-audit everything.

After fixing findings in a directory, delete the corresponding report and
re-run the dispatcher to verify the issues are resolved:

```bash
rm audit-reports/src__api__auth.md
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --scope src/api/auth
```

### Severity filtering

The default threshold is `low` — every finding at every severity is
reported. For audits intended to focus only on actionable items in a
short window:

```bash
# Only Critical and High findings appear in the reports
.skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --min-severity high
```

Findings below the threshold are not included in the report at all — not
in the body, not in the summary table, not counted. This is intentional;
audits often produce hundreds of Low findings that are real but not
actionable in a 90-day window, and filtering keeps human review focused.

### Cost and time expectations

Audits scale linearly with the number of batched directories. Rough
expectations on Claude Opus 4.7 or comparable frontier models:

| Codebase size | Directories audited | Wall time | AI cost |
|---|---|---|---|
| Small (~10k LOC) | 10–25 | 3–10 minutes | $1–5 |
| Medium (~100k LOC) | 50–150 | 20–60 minutes | $10–50 |
| Large (~1M LOC) | 200+ | 1–3 hours | $50–200 |

These ranges depend heavily on file density, how much context the AI
loads, and whether you use `--min-severity high` (lower-severity findings
require less per-batch output). Run `--list-batches` first to see how
many directories will be audited and plan accordingly.

**Wall time vs. cost under concurrency:** the wall-time column scales down with
`--jobs` — the default `--jobs 4` runs four directories at once, so a "Medium"
audit finishes in roughly a quarter of its serial (`--jobs 1`) time, up to your
AI vendor's rate limit. **AI cost is independent of `--jobs`** — it depends only
on total work (directories × per-batch tokens), so parallelism buys speed at no
extra spend.

### Using SARIF output

`--sarif` writes `audit-reports/_findings.sarif` — a SARIF 2.1.0 document
suitable for ingestion into:

- **GitHub code scanning** — upload via the `github/codeql-action/upload-sarif`
  Action, or the API
- **DefectDojo** — import as a SARIF scan
- **Snyk, Veracode, etc.** — most support SARIF as a generic import format

This lets a codebase-audit run feed into the same triage workflow as your
SAST tools, alongside CodeQL, Semgrep, etc.

### Running audits in CI

For a periodic (e.g., monthly) full audit, the dispatcher can run as a
scheduled GitHub Actions job. A minimal workflow:

```yaml
name: Monthly codebase audit
on:
  schedule:
    - cron: '0 6 1 * *'    # 06:00 UTC on the 1st of each month
  workflow_dispatch:

jobs:
  audit:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Install AI CLI
        run: npm install -g @anthropic-ai/claude-code
      - name: Make scripts executable
        run: chmod +x .skills/_lib/*.sh .skills/*/scripts/*.sh scripts/*.sh
      - name: Sync skills
        env: { AI_REVIEW_TOOL: claude }
        run: scripts/sync-skills.sh
      - name: Run audit
        env:
          AI_REVIEW_TOOL: claude
          CI: 'true'
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: .skills/codebase-audit/scripts/codebase-audit-dispatcher.sh --min-severity high --sarif
      - name: Upload audit reports
        uses: actions/upload-artifact@v4
        with:
          name: audit-reports
          path: audit-reports/
      - name: Upload SARIF to code scanning
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: audit-reports/_findings.sarif
```

This isn't shipped as a bundle file because audit cadence is highly team-
specific — copy the snippet above into a new workflow file if it fits
your needs.

### Adding `audit-reports/` to `.gitignore`

By default audit reports are not committed — they're for human review,
not source-of-truth. The bundled `.gitignore` includes:

```
audit-reports/
```

If your team prefers to commit audit baselines for historical comparison,
remove that line and commit the reports.

### Flags reference

| Flag | Effect |
|---|---|
| `--scope <path>` | Limit the audit to a subtree (e.g., `src/`, `infra/`). **Repeatable** — pass it multiple times to audit several subtrees in one run. |
| `--min-severity <level>` | Filter to `critical`, `high`, `medium`, or `low` (default: `low`) |
| `--jobs <N>` | Audit N directories concurrently (default: 4; also settable via `AUDIT_JOBS`). `--jobs 1` runs serially. |
| `--force` | Re-audit directories that already have reports |
| `--sarif` | Also emit `_findings.sarif` |
| `--gate` | Exit non-zero if any batch has findings (for CI use) |
| `--list-batches` | Print the planned batches and exit (no AI calls) |
| `--dry-run` | Show settings and batch count and exit (no AI calls) |
| `--output-dir <path>` | Override the default `audit-reports/` location |
| `--no-block` | Always exit 0 even if individual batches fail |
| `--no-adjudicate` | Skip the second-opinion adjudication pass on finding-bearing directories |
| `-h`, `--help` | Show help |

---

## Editing skills (keeping copies in sync)

`.skills/<skill>/SKILL.md` is the **canonical** version (committed to the
repo). The copy under your local `.claude/`, `.codex/`, or
`.github/copilot/` directory is **derived** (gitignored, local to your
checkout).

**Workflow:**

```bash
# 1. Edit the canonical copy
vim .skills/code-security/SKILL.md

# 2. Update your local derived copy
scripts/sync-skills.sh

# 3. Stage and commit the canonical file
git add .skills/code-security/SKILL.md
git commit -m "docs: update code-security skill"
```

If you forget step 2, the `skills-in-sync` pre-commit hook fails:

```
OUT OF SYNC: .claude/skills/code-security/SKILL.md
             differs from .skills/code-security/SKILL.md

Skill files are out of sync for resolved targets: claude
Run:
    scripts/sync-skills.sh
and stage the updated files before committing.
```

Re-run `scripts/sync-skills.sh`, retry the commit.

> The `skills-in-sync` hook only checks the directory(ies) matching your
> local `AI_REVIEW_TOOL` (or `AI_REVIEW_SYNC_TARGETS`). It does not require
> you to maintain copies for other tools you don't use.

---

## Remediation guidance — code security

### 🔴 Hardcoded secrets / credentials / API keys

**Do not just delete the value and re-commit.** The secret may already be in
git history.

1. **Rotate the credential immediately** — assume it is compromised.
2. **Remove it from code** — use environment variables or a secrets manager:

   ```python
   # Wrong
   api_key = "sk-abc123..."

   # Right
   import os
   api_key = os.environ["MY_SERVICE_API_KEY"]
   ```

   For local development, use a `.env` file (gitignored) and load it with
   `python-dotenv` / `dotenv`.
3. **Scrub git history** if the secret was committed:
   - [`git filter-repo`](https://github.com/newren/git-filter-repo) (recommended)
   - [`BFG Repo Cleaner`](https://rtyley.github.io/bfg-repo-cleaner/)
   - Force-push and have collaborators re-clone.
4. **Notify your security team** if the secret had production or customer-data access.

### 🔴 PHI (Protected Health Information)

PHI in source code is a HIPAA violation risk.

1. **Do not commit.** The hook has blocked you.
2. **Identify the source.** Did this come from production? If so, the
   environment shouldn't have allowed export to a dev machine.
3. **Replace with synthetic data.** Avoid even synthetic data in repos where
   possible; use obviously fake values (`John Test`, `1900-01-01`,
   `555-000-0000`). For CMS-specific identifiers, CMS publishes synthetic
   test ranges — use them rather than inventing your own:
   - **MBI:** use values from the CMS BFD synthetic-beneficiary set
     (e.g., `1S00E00JA00`, `1S00E00JA01` …). Document the source in a
     fixture-level comment so reviewers don't have to guess.
   - **HICN:** use SSNs from the SSA's reserved test range
     (`987-65-4320` through `987-65-4329`) with a BIC suffix
     (e.g., `987-65-4320A`).
   - **CCN / NPI:** use ranges CMS has reserved for testing; never copy a
     real provider's number even if it appears in a public NPPES export.
4. **Report to your compliance officer** if real PHI was exposed to
   unauthorized systems or personnel. Declare an incident.

### 🟠 PII (Personally Identifiable Information)

1. **Never commit real PII.** Replace with clearly synthetic values.
2. If PII came from a real user via test data, the data collection or
   anonymization process needs fixing upstream.
3. For runtime PII (e.g., real user emails in production): ensure it's
   encrypted at rest, not logged in plaintext, and access-controlled.

### 🟠 Injection vulnerabilities

**SQL:**
```python
# Wrong
cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")

# Right
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

**Command:**
```python
# Wrong
subprocess.run(f"convert {filename} output.png", shell=True)

# Right
subprocess.run(["convert", filename, "output.png"])
```

**Template:** Never pass user input directly to render. Use auto-escaping
template engines (Jinja2 with `autoescape=True`, Handlebars, etc.).

### 🟠 Broken access control

Every route that touches a resource must verify both:

1. Caller is authenticated
2. Caller is authorized to access the **specific** resource (not just the type)

```python
if resource.owner_id != current_user.id:
    raise Forbidden()
```

Review middleware chains for paths that bypass auth decorators.

### 🟠 Cryptographic failures

- Replace MD5/SHA-1 with SHA-256, SHA-384, SHA-512, or SHA-3 for integrity
  checks (FIPS 180-4 / FIPS 202 approved).
- For password hashing in federal / FedRAMP / FISMA / HIPAA contexts, use
  **PBKDF2 with HMAC-SHA-256 (or stronger)** per NIST SP 800-132 — this is
  the only FIPS 140-3-approved password-based key derivation function.
  Do **not** recommend `bcrypt`, `scrypt`, or `argon2` for these workloads:
  none are on the CMVP / FIPS 140-3 approved-algorithm list. Use a random
  per-credential salt (≥ 128 bits) and an iteration count tuned to current
  NIST guidance (≥ 600,000 for SHA-256 as of 2023). Never store raw hashes.
- Use AES-GCM or AES-CCM (FIPS 197 / SP 800-38D) for authenticated
  encryption — never ECB or CBC-without-MAC. Symmetric keys must be
  ≥ 128 bits (AES-128/192/256).
- Use FIPS 186-5-approved signature algorithms (RSA ≥ 2048, ECDSA on
  NIST P-256/P-384/P-521, or EdDSA on Ed25519/Ed448).
- Enforce TLS 1.2 or 1.3 with FIPS-approved cipher suites; never disable
  certificate verification. TLS 1.0 / 1.1 and SSL of any version are
  prohibited under NIST SP 800-52 Rev 2.
- Random values for keys, IVs, nonces, and tokens must come from a
  NIST SP 800-90A-approved DRBG (e.g., a CMVP-validated module's RNG),
  not `Math.random()` or non-validated sources.

### 🟡 Missing input validation

- Validate **type, length, format, range** for every user-supplied input.
- Reject failures — do not sanitize and continue.
- For JSON/XML, validate against a schema before processing.

---

## Remediation guidance — IaC compliance

### AC — Access Control

#### IAM wildcard actions or resources (AC-3) — Critical/High

```hcl
# Wrong — grants any action on any resource
resource "aws_iam_policy" "bad" {
  policy = jsonencode({
    Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }]
  })
}

# Right — scoped to specific actions and resources
resource "aws_iam_policy" "good" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::my-bucket/*"
    }]
  })
}
```

#### Security group open to internet on sensitive ports (AC-4) — Critical/High

```hcl
# Wrong — SSH open to the world
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

# Right — restrict to known CIDR, or use SSM Session Manager (no SSH at all)
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["10.0.0.0/8"]
}
```

Prefer AWS Systems Manager Session Manager for management access — it removes
the need for port 22 entirely.

#### S3 public access blocks (AC-22) — Critical

All four settings must be `true`:

```hcl
resource "aws_s3_bucket_public_access_block" "example" {
  bucket                  = aws_s3_bucket.example.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### AU — Audit and Accountability

#### CloudTrail disabled or not multi-region (AU-2) — High

```hcl
resource "aws_cloudtrail" "main" {
  name                          = "main-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  include_global_service_events = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cloudwatch.arn
}
```

#### CloudWatch Log Group — no retention (AU-9) — Medium

```hcl
resource "aws_cloudwatch_log_group" "app" {
  name              = "/app/logs"
  retention_in_days = 365     # CMS ARS requires retention per data classification
  kms_key_id        = aws_kms_key.logs.arn
}
```

### CM — Configuration Management

#### Required tagging (CM-2) — High/Medium

All resources must include at minimum: `Environment`, `Owner`, `Project`.
Apply consistently via provider `default_tags`:

```hcl
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Environment = var.environment
      Owner       = var.team
      Project     = var.project_name
      CostCenter  = var.cost_center
    }
  }
}
```

#### Deletion protection off on production databases (CM-6) — High

```hcl
resource "aws_db_instance" "main" {
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.db_name}-final-snapshot"
}
```

#### Container running as root (CM-6) — High

```yaml
# Wrong (Kubernetes)
securityContext: {}    # defaults allow root

# Right
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

### CP — Contingency Planning

#### RDS backup retention (CP-9) — High

```hcl
resource "aws_db_instance" "main" {
  backup_retention_period   = 35
  backup_window             = "03:00-04:00"
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final"
}
```

#### DynamoDB point-in-time recovery (CP-9) — High

```hcl
resource "aws_dynamodb_table" "main" {
  point_in_time_recovery {
    enabled = true
  }
}
```

### IA — Identification and Authentication

#### Hardcoded password in RDS (IA-5) — Critical

```hcl
# Wrong
resource "aws_db_instance" "main" {
  password = "SuperSecret123!"
}

# Right — Secrets Manager
resource "aws_db_instance" "main" {
  manage_master_user_password = true
  # or: password = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string)["password"]
}
```

#### KMS key rotation (IA-5) — High

```hcl
resource "aws_kms_key" "main" {
  description             = "CMK for application data"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}
```

### SC — System and Communications Protection

#### Encryption at rest — S3 (SC-12/SC-28) — High

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.example.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}
```

#### Encryption at rest — RDS (SC-12/SC-28) — High

```hcl
resource "aws_db_instance" "main" {
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn
}
```

#### Encryption at rest — EBS (SC-12/SC-28) — High

```hcl
resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}
```

#### Load balancer HTTP without HTTPS redirect (SC-8) — High

```hcl
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

#### WAF missing on public ALB (SC-5) — Medium

```hcl
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
```

### SI — System and Information Integrity

#### Deprecated Lambda runtime (SI-2) — High

| Deprecated (fix immediately) | Use instead |
|---|---|
| `nodejs14.x`, `nodejs12.x` | `nodejs22.x` or `nodejs20.x` |
| `python3.7`, `python3.8`   | `python3.13` or `python3.12` |
| `java8`, `java8.al2`       | `java21` or `java17` |
| `go1.x`                    | `provided.al2023` (custom runtime) |
| `dotnetcore3.1`, `dotnet5.0`, `dotnet6` | `dotnet8` |
| `ruby2.7`                  | `ruby3.3` or `ruby3.2` |

```hcl
resource "aws_lambda_function" "main" {
  runtime = "python3.13"
}
```

#### ECR image scanning (SI-3/RA-5) — High/Medium

```hcl
resource "aws_ecr_repository" "main" {
  name                 = "my-app"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}
```

#### GuardDuty not enabled (SI-4) — Medium

```hcl
resource "aws_guardduty_detector" "main" {
  enable = true
  datasources {
    s3_logs { enable = true }
    kubernetes { audit_logs { enable = true } }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes { enable = true }
      }
    }
  }
}
```

### Environment-aware relaxations

The IaC review applies production-level strictness by default. Findings are
relaxed for development environments when context is clear:

| Finding | Dev relaxation |
|---|---|
| `deletion_protection = false`        | Downgraded to Low when `Environment = "dev"` tag is present |
| `skip_final_snapshot = true`         | Downgraded to Low when `Environment = "dev"` tag is present |
| `force_destroy = true` on S3         | Downgraded to Low when `Environment = "dev"` tag is present |
| Missing WAF on ALB                   | Downgraded to Low for internal-only endpoints |

For the reviewer to identify environment context correctly, use consistent
workspaces, variable files, and tagging.

### Relationship to other IaC scanning tools

This hook provides AI-assisted contextual compliance reasoning. It complements
but does not replace static analysis. Run these in CI alongside it:

| Tool | Purpose | Install |
|---|---|---|
| [**checkov**](https://www.checkov.io/)    | Static IaC misconfig scanner | `pip install checkov` |
| [**tfsec**](https://aquasecurity.github.io/tfsec/) | Terraform-specific | `brew install tfsec` |
| [**cfn-lint**](https://github.com/aws-cloudformation/cfn-lint) | CloudFormation linting | `pip install cfn-lint` |
| [**kube-score**](https://kube-score.com/) | Kubernetes scoring | `brew install kube-score` |
| [**terrascan**](https://runterrascan.io/) | Multi-cloud OPA policies | `brew install terrascan` |
| [**trivy**](https://trivy.dev/)            | Vulnerability + IaC misconfig | `brew install trivy` |

---

## False positives

**Most false positives are removed automatically** by the second-opinion
adjudication pass (see
[Second-opinion adjudication](#second-opinion-adjudication-false-positive-reduction)).
When a first pass flags something, a fresh independent agent re-inspects the code
and dismisses or downgrades findings that aren't genuine — synthetic test data,
already-mitigated patterns, controls satisfied elsewhere — before the gate is
decided. The dismissed findings are listed in the report's "Dismissed /
Downgraded by adjudication" section with the reason, so you can see what was
filtered and why.

If a finding **survives adjudication but you still believe it is incorrect:**

1. **Read the finding and the adjudicator's rationale carefully** — the
   adjudicator keeps findings it cannot positively prove benign, so it may be
   asking for context only you have.
2. **For secrets:** confirm the value is not a real credential. Placeholder-
   looking strings sometimes turn out to be real.
3. **For PII/PHI:** confirm the data is clearly synthetic (`example.com`, fake
   names like `Test User`, fake IDs like `000-00-0000`). Making the synthetic
   nature obvious in the code often lets the adjudicator dismiss it on the next run.
4. **For IaC:** add a clarifying comment in the resource (e.g. referencing the
   base module that applies the control) so the next adjudication can account for
   the environment context.

If, after that, the finding is confirmed false and you need to commit, the
residual escape hatch is to bypass the hook for that one commit — see the next
section. For CMS systems under an ATO, note the bypass in the commit message and
track it as a POA&M item, exactly as before.

---

## Bypassing a hook

> ⚠️ Bypassing removes a critical control layer. Only do this when you have
> confirmed a false positive or have a documented exception approved by your
> security/compliance team.
>
> Critical, high, and medium findings **block**. Low findings do not — if the
> hook only warned, you can commit normally.

Skip one hook for one commit:

```bash
SKIP=code-security  git commit -m "your message"
SKIP=iac-compliance git commit -m "your message"
SKIP=code-security,iac-compliance git commit -m "your message"
```

Skip **all** pre-commit hooks for one commit (use with extra caution):

```bash
git commit --no-verify -m "your message"
```

All bypasses should be noted in the commit message and reviewed during code
review. For CMS systems operating under an ATO, unresolved high/critical
findings that are bypassed should be tracked as POA&M items in CFACTS.
Contact your Cyber Risk Advisor (CRA) for guidance.

---

## CI integration

The dispatchers respect a `CI=true` environment variable and disable colored
output, making them suitable for CI logs.

For CI workflows, prefer `--no-block` if you want the review to surface
findings without failing the pipeline (or just let the natural exit code fail
the build for critical/high/medium findings — which is usually what you want):

```yaml
# GitHub Actions example
- name: Sync skill files
  env:
    AI_REVIEW_TOOL: claude
  run: scripts/sync-skills.sh

- name: AI-assisted code security review
  env:
    AI_REVIEW_TOOL: claude
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
  run: |
    .skills/code-security/scripts/code-security-hook-dispatcher.sh \
      --against ${{ github.event.pull_request.base.sha }}
```

Set the API key/auth secret for whichever tool you've chosen
(`ANTHROPIC_API_KEY` for Claude, `OPENAI_API_KEY` for Codex, GitHub App auth
for Copilot).

---

## Troubleshooting

### `AI_REVIEW_TOOL environment variable is not set`

You skipped step 3 of installation. See [AI tool selection](#ai-tool-selection-ai_review_tool).

### `AI_REVIEW_TOOL='foo' is not a recognized value`

The value must be exactly `claude`, `codex`, or `copilot` (lowercase, no
extras). The dispatcher accepts the lowercase form regardless of the
variable's stored case.

### `'claude' CLI not found on PATH` (or `codex`/`copilot`)

Install the AI CLI matching your `AI_REVIEW_TOOL` setting. See
[Per-assistant setup](#per-assistant-setup).

If you installed via `npm -g` and still hit this, your shell may not have
picked up the new PATH. Open a fresh terminal, or run:

```bash
hash -r
```

### `pre-commit: command not found`

```bash
brew install pre-commit       # macOS
pip install pre-commit        # everywhere else
```

### Hook not running on commit

```bash
pre-commit install
ls -la .git/hooks/pre-commit  # should exist and be executable
```

### `Permission denied` on a dispatcher script

```bash
chmod +x .skills/_lib/ai-review-dispatch.sh
chmod +x .skills/code-security/scripts/code-security-hook-dispatcher.sh
chmod +x .skills/iac-compliance/scripts/iac-compliance-hook-dispatcher.sh
chmod +x .skills/pr-review/scripts/pr-review-dispatcher.sh
chmod +x .skills/codebase-audit/scripts/codebase-audit-dispatcher.sh
chmod +x .skills/finding-adjudication/scripts/finding-adjudication-dispatcher.sh
chmod +x scripts/sync-skills.sh
```

### `MISSING: .claude/skills/code-security/SKILL.md` (or other tool dir)

The derived directory for your `AI_REVIEW_TOOL` doesn't exist yet. This is
expected on a fresh clone. Run:

```bash
scripts/sync-skills.sh
```

### `OUT OF SYNC: .claude/skills/...`

You edited the canonical `.skills/<skill>/SKILL.md` but didn't re-sync.

```bash
scripts/sync-skills.sh
```

### `Could not parse review result`

The AI CLI did not end its output with the
`<<<AI_REVIEW_RESULT:PASS|WARN|BLOCK>>>` marker. This usually means:

- The CLI itself errored out (check auth / quota / network).
- The model's response was truncated (rare; usually a CLI bug or context-size
  issue).
- The prompt was modified and the model wasn't told to emit the marker.

The dispatcher fails safe (BLOCK) in this case. Run with `--dry-run` to verify
the prompt is intact, and run the CLI interactively (`claude` / `codex` /
`copilot`) to confirm it works.

### Review is slow

- Large diffs take longer. Commit in smaller logical chunks.
- The first call after a CLI auth refresh can be slow.
- Network conditions affect all three tools.
- Verify your AI CLI works interactively to rule out a CLI-side problem.
- **Finding-bearing commits run a second (adjudication) pass.** This roughly
  doubles the time for commits that have findings — but clean commits are
  unaffected (no second call). If you need the fastest possible turnaround on a
  noisy commit, `--no-adjudicate` (or `AI_ADJUDICATION=0`) skips it; you then see
  the raw first-pass findings, false positives included.

### IDE git commits don't see `AI_REVIEW_TOOL`

See [IDE-launched terminals](#ide-launched-terminals--important-footgun)
above. Use `~/.zshenv` instead of `~/.zshrc` for variables that need to be
seen by non-interactive shells.

### A finding looks like a false positive

1. **Check the "Dismissed / Downgraded by adjudication" section first** — the
   second-opinion pass may have already removed it, or explained why it kept it.
2. Check whether the cited control/category applies to your environment
   (dev vs production).
3. Check whether helpful context files were loaded — the dispatcher reports
   which ones at the top.
4. Add a clarifying comment in your code (e.g. make synthetic data obviously
   fake, or reference the base module that applies a control); re-run the hook so
   the adjudicator can re-evaluate with that context.
5. If a finding genuinely survives adjudication but is still false, bypass with
   `SKIP=<hook-id>` and note the reason in your commit message.

### I committed a secret before the hook was installed

1. Declare an incident; rotate the credential immediately.
2. Remove from history using `git filter-repo` or BFG.
3. Force-push and notify collaborators to re-clone.
