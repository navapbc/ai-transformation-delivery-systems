# AI Test Classifier — Pilot Playbook

This is the prescriptive, step-by-step playbook for pilot teams adopting the
**AI test classifier**. It is the companion to the security workstream's
PR-review bundle: where that bundle answers *"is this change safe?"*, this one
answers a different, narrower question that teams keep getting wrong when they
wire AI into CI:

> **When a test fails, is the *test* wrong, or is the *code* wrong?**

If you get that question wrong, you generate no-op tests that paper over real
regressions — the single worst failure mode of "AI writes the tests" tooling.
The classifier exists to make that call explicitly, on every failure, with a
short rationale a human can agree or disagree with.

This playbook is deliberately opinionated. A pilot team should be able to read
it top to bottom and run with zero guessing.

---

## Contents

1. [What the classifier is](#1-what-the-classifier-is)
2. [The four-verdict taxonomy](#2-the-four-verdict-taxonomy)
3. [Future direction (not built in the pilot)](#3-future-direction-not-built-in-the-pilot)
4. [How to drop the GitHub Action into your repo](#4-how-to-drop-the-github-action-into-your-repo)
5. [The metrics loop (👍/👎 and precision inputs)](#5-the-metrics-loop)
6. [Security considerations for AI-enabled PR/test workflows](#6-security-considerations-for-ai-enabled-prtest-workflows)
7. [FAQ](#7-faq)

---

## 1. What the classifier is

The classifier is an AI reviewer that runs **after your test suite runs in
CI** (or against a local commit) and, for each test failure or each finding,
tags it as one of four verdicts:

| Verdict | Meaning | What the team should do |
|---|---|---|
| **`APPLICATION_BUG`** | The test failed because the application actually regressed. | Fix the **CODE**. |
| **`TEST_BUG`** | The test failed but the application is fine. The test is stale, brittle, or a change-detector that's asserting on an intentional change. | Fix the **TEST**. |
| **`FLAKY_FAILURE`** | The failure is intermittent / non-deterministic (timing, ordering) and would pass on an unchanged re-run. | Re-run to confirm, then deflake. Not a code or test-logic patch. |
| **`ENVIRONMENT_ISSUE`** | Infrastructure: timeout, connection refused, port in use, runner OOM, missing service/secret. | Fix the environment / re-run. Neither app nor test is at fault. |

> A passing test is not classified — it is simply omitted. "Nothing failed"
> is handled by the `NO_ACTION` result marker, not a per-test verdict.

It mirrors the security workstream exactly in its plumbing:

- Tool selection via the **`AI_REVIEW_TOOL`** environment variable
  (`claude` | `codex` | `copilot`) — identical contract to security/review.
- A shared dispatch library with `ai_review::` namespaced helpers,
  `set -euo pipefail`, and color helpers suppressed in CI.
- The **result-marker contract**: the AI ends its output with exactly one
  `<<<AI_REVIEW_RESULT:...>>>` marker that the dispatcher parses.
- The **skill text** vendored from `navapbc/agent-skills` by
  `scripts/fetch-skills.sh`, with the in-repo `.skills/` copy as a fallback.
- A GitHub Actions workflow that ships **disabled** (`on: workflow_dispatch`
  only), is **non-blocking/advisory by default**, and flips to build-failing
  only behind an explicit `--gate` flag.

What is *different* is the domain: this skill classifies test-vs-code rather
than reviewing for security/compliance findings, and it asks the developer for
a tuning signal — a mandatory 👍/👎 on the comment it posts.

### Where it sits in the toolchain

```
┌──────────────────────────────────────────────────────────────────────┐
│  CI: test suite runs                                                  │
│      │                                                                │
│      ▼                                                                │
│  one or more tests fail (or all pass)                                 │
│      │                                                                │
│      ▼                                                                │
│  testing/classifier/.skills/test-classifier/scripts/                  │
│      test-classifier-dispatcher.sh --pr <n> --post-comment            │
│      │                                                                │
│      reads AI_REVIEW_TOOL                                             │
│      │                                                                │
│      ┌──────────────┬──────────────┬──────────────┐                   │
│      ▼              ▼              ▼               ▼                   │
│   claude -p     codex exec     copilot -p                             │
│      │              │              │                                  │
│      └──────────────┴──────────────┘                                  │
│                     ▼                                                 │
│   AI reads SKILL.md, classifies each failure as                       │
│   APPLICATION_BUG | TEST_BUG | FLAKY_FAILURE | ENVIRONMENT_ISSUE,      │
│   emits rationale + JSON,                                             │
│   ends with: <<<AI_REVIEW_RESULT:CLASSIFIED>>>                        │
│                     │                                                 │
│                     ▼                                                 │
│   post ONE PR comment with the verdicts +                             │
│   rationale + a MANDATORY 👍/👎 ask (non-blocking);                   │
│   the full report is also uploaded as a CI artifact                   │
│                     │                                                 │
│                     ▼                                                 │
│   metrics harvest (testing/metrics/) → Google Sheet / TSV             │
└──────────────────────────────────────────────────────────────────────┘
```

The dispatcher interface a team integrates against is:

```bash
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr <number> \
  [--post-comment] \
  [--gate]
```

- `--pr <number>` — the pull request to classify against (auto-discovered via
  `gh pr view` if omitted, exactly like the security dispatcher).
- `--post-comment` — post the verdicts to GitHub via `gh api` as one PR comment
  with the mandatory 👍/👎 ask. Without it, the report prints to the terminal /
  uploads as a CI artifact only.
- `--gate` — exit non-zero on an unconfirmed triaged failure, to make the
  classifier a build gate (off by default; advisory is the pilot posture).

---

## 2. The four-verdict taxonomy

Joe's original "is the test wrong or the code wrong?" framing is the
foundation of the classifier. We've extended it to the industry-standard
four-way split (ContextQA / FixSense / TestDino), because "the test or the
code" only covers two of the four ways a test can fail. Every failing test
maps to exactly one of four verdicts:

| # | Verdict | When | Rationale focus |
|---|---|---|---|
| 1 | **`APPLICATION_BUG`** | The test fails and the app is genuinely broken. | The code regressed against a contract the test correctly encodes. The test is doing its job; the fix belongs in the application. |
| 2 | **`TEST_BUG`** | The test fails but the app is fine. | The test encodes a stale expectation — a renamed field, a reworded copy string, a deliberately changed return shape, an ordering assumption, a snapshot that should be re-baselined. The production code is behaving correctly. |
| 3 | **`FLAKY_FAILURE`** | The failure is intermittent / non-deterministic. | Timing, ordering, or other non-determinism that would pass on an unchanged re-run. Re-run to confirm, then deflake — it is neither a code nor a test-logic patch. |
| 4 | **`ENVIRONMENT_ISSUE`** | The failure is infrastructure, not behavior. | Timeout, connection refused, port already in use, runner OOM, a missing service or secret. Fix the environment / re-run; neither the app nor the test is at fault. |

> A passing test is **not** classified — it is omitted. "Nothing failed" is
> the `NO_ACTION` result marker, not a per-test verdict.

The classifier's **primary job** is to tag each finding with one of these four
verdicts, **with a short rationale**, so teams never generate no-op tests for
genuinely broken code. That last clause is the whole point: a naive "AI fixes
failing tests" loop will happily edit the test to match the broken code,
turning a real regression green. The classifier refuses to make that move
silently — it surfaces the call and the reasoning, and asks a human to confirm
it with a 👍/👎.

### How the AI is expected to reason

The decision procedure runs **in order**, and the order matters:

1. **Rule out `ENVIRONMENT_ISSUE` first.** Does the failure output show a
   timeout, connection refused, port already in use, runner OOM, or a missing
   service/secret? If so, the behavior was never exercised — never invent an
   `APPLICATION_BUG` to explain a timeout.
2. **Then rule out `FLAKY_FAILURE`.** Is the failure non-deterministic —
   timing, ordering, a race that would pass on an unchanged re-run? When a
   single run looks flaky but might be real, prefer `FLAKY_FAILURE` with **low
   confidence** and recommend a re-run as the disambiguator.
3. **Only then ask the app-vs-test question** (`APPLICATION_BUG` vs
   `TEST_BUG`). For that call the classifier weighs evidence such as:
   - Does the diff touch the code under test, or only unrelated files? (A
     failure with no nearby code change skews toward `TEST_BUG` / flake.)
   - Does the assertion encode a *contract* (an API shape, an invariant, a
     security control) or an *incidental detail* (exact log wording, ordering,
     a hard-coded timestamp)? Contract breakage skews `APPLICATION_BUG`;
     incidental breakage skews `TEST_BUG`.
   - Is the change to the code under test plausibly *intentional* (a feature
     change reflected in the PR description) vs an accidental regression?

When the app-vs-test evidence is genuinely ambiguous, the classifier must say
so in the rationale and default to the **more conservative** call —
`APPLICATION_BUG` over `TEST_BUG` — because shipping a bug behind a green check
is the worst outcome, and the cost of silently rewriting a test to hide a
regression is far higher than the cost of a human glancing at a test that was
actually just stale. (This default applies only after `ENVIRONMENT_ISSUE` and
`FLAKY_FAILURE` have been ruled out — never reach for `APPLICATION_BUG` to
explain an infra failure or a flake.)

---

## 3. What the pilot ships (and what's future direction)

When a PR's tests fail, the classifier triages each failure and posts **one PR
comment** with the verdicts and a mandatory 👍/👎 ask.

- The classifier runs in CI after the test suite and **classifies every
  failure** as `APPLICATION_BUG` / `TEST_BUG` / `FLAKY_FAILURE` /
  `ENVIRONMENT_ISSUE`, each with a short rationale.
- It posts **one PR comment** (rolled up, or one per failure — team's choice)
  stating the verdict and rationale, and **requests a mandatory 👍 / 👎
  reaction** from the developer:
  - 👍 = "the classifier got the call right"
  - 👎 = "the classifier got the call wrong"
- That reaction is **the tuning signal**, and it is mandatory because precision
  is unmeasurable without it.
- It is **non-blocking**: the comment never fails the build. The full
  classification report is also uploaded as a CI artifact. (A team that wants a
  gate later can opt in via `--gate`, exactly as in security/review, but the
  pilot default is advisory.)

The items below are **future direction, not built in the pilot.** They are
recorded here so the design intent is on the page — do not build them as part
of the pilot.

### Proposed commit suggestions / merge-rate  (P2 — future direction, not built)

> Documented as direction only. **Not built in the pilot.**

A natural next step is for the classifier to attach a *proposed diff* — a
suggested edit to the test (for `TEST_BUG`) or a pointer at the regressed code
(for `APPLICATION_BUG`) — using GitHub's one-click `` ```suggestion `` blocks, and to
track the **merge-rate** of those suggestions as a stronger quality signal
than 👍/👎 alone. This stays behind the **propose-diff-then-approve** rule (see
§6): the classifier proposes; a human approves and commits. No autocommit.

### Zero-shot test generation  (P3 — future direction, not built)

> Documented as direction only. **Not built in the pilot.**

The long-horizon goal: generate net-new tests for uncovered behavior from a
spec or a diff. This is explicitly **gated behind a mature classifier-precision
track record**, because generating tests is only safe once we trust the
classifier's test-vs-code judgment — otherwise we are back to generating no-op
tests against broken code, at scale.

---

## 4. How to drop the GitHub Action into your repo

This is the zero-guessing version. Follow it in order. For the local-run path
and a fuller troubleshooting matrix, see [`SETUP.md`](./SETUP.md).

### Step 0 — Prerequisites

- The classifier bundle is installed under `testing/classifier/` in your repo
  (see `INSTALL.txt`).
- Your test suite already runs in CI and you can identify failures
  programmatically (most teams already have this).
- You have picked an AI tool: `claude`, `codex`, or `copilot`.

### Step 1 — Wire up the workflow (recommended: reusable workflow)

The recommended approach copies **nothing** into your repo. The bundle ships a
**reusable workflow** at the repo root —
`.github/workflows/test-classifier.yml` (`on: workflow_call`) — that your repo
calls with a single pinned `uses:` line. Add this caller to your consumer repo:

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

Pin to a commit SHA, not a branch — a SHA is reproducible and gives clear
provenance. Upgrading is a one-line SHA bump: no vendored copy to drift, no
merge. In this path `tool` is a **workflow input** in the caller's `with:`
block, not a repository variable; you can skip Step 2 below (it applies only to
the vendored fallback). You still set the API-key secret (Step 3) and pass it
through `secrets:` as shown.

> **Fallback — vendoring.** If your repo can't reference an external reusable
> workflow (e.g. policy forbids it), copy the bundle's workflow file in instead:
>
> ```bash
> cp testing/classifier/.github/workflows/ai-test-classifier.yml \
>    .github/workflows/ai-test-classifier.yml
> ```
>
> **Merge, don't overwrite** if you already have a workflow with that name. The
> vendored workflow ships **disabled** (only `workflow_dispatch`, with a
> commented-out `pull_request:` block and a banner explaining how to enable it),
> identical to the security workstream's posture. The remaining steps below
> (the AI-tool variable, enabling the trigger) apply to this vendored fallback; see
> [`SETUP.md`](./SETUP.md) Path C for the full vendored walkthrough.

### Step 2 — Set the AI tool as a repository variable

`AI_REVIEW_TOOL` is non-sensitive configuration, so it is a **variable**, not a
secret.

1. **Settings** → **Secrets and variables** → **Actions** → **Variables** tab.
2. **New repository variable**.
3. Name: `AI_REVIEW_TOOL`
4. Value: `claude`, `codex`, or `copilot` (lowercase, exactly).

### Step 3 — Set the API key as a repository secret

1. **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab.
2. **New repository secret**, matching your chosen tool:

| Tool | Secret name | Where to get it |
|---|---|---|
| `claude`  | `ANTHROPIC_API_KEY` | <https://console.anthropic.com/settings/keys> |
| `codex`   | `OPENAI_API_KEY`    | <https://platform.openai.com/api-keys> |
| `copilot` | (none — uses `GITHUB_TOKEN`) | n/a |

Only set the secret matching your chosen tool.

### Step 4 — Confirm workflow permissions (least privilege)

The workflow declares exactly what it needs and nothing more:

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

### Step 6 — (Optional, later) enable gating

The pilot default is **advisory / non-blocking** — exactly like security
review. If, much later, a team wants a failing classification (e.g. an
unconfirmed `APPLICATION_BUG`) to fail the build, uncomment the `--gate` line in the
workflow's run step:

```yaml
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr "${PR_NUMBER}" \
  --post-comment
  # --gate
```

Use with care: a false `APPLICATION_BUG` becomes a merge blocker.

---

## 5. The metrics loop

The classifier is only as good as our ability to measure it, and the pilot's
whole purpose is to gather that measurement. Two things are harvested:

1. **The 👍/👎 reaction counts** on each classifier comment — the developer's
   verdict on whether the call was right.
2. **Classifier precision inputs** — the raw `(verdict, was-it-right?)` pairs
   that let us compute precision per class (`APPLICATION_BUG`, `TEST_BUG`,
   `FLAKY_FAILURE`, `ENVIRONMENT_ISSUE`) over time. **`APPLICATION_BUG`
   precision is the one to watch** — never ship a no-op test for a real bug.

### Where it goes

The harvest script lives at `testing/metrics/test_classifier_comments.sh`. It
mirrors the intent of Brian's `security/metrics/pr_review_comments.sh`: it walks
PRs with `gh api`, finds classifier comments, and reads the `+1` / `-1`
reaction counts off each one with `jq`.

| Sink | When to use | How |
|---|---|---|
| **Google Sheet (primary)** | The shared pilot dashboard everyone reads. | The script POSTs rows to a Sheet via a **service-account bearer token**. Set `SHEET_ID` and `GOOGLE_SHEETS_TOKEN` (the service-account access token) in the environment. |
| **TSV to stdout (fallback)** | The realistic default for early pilots before the Sheet plumbing is wired. Pipe it anywhere. | Run the script with no Sheet env vars set; it writes tab-separated rows to stdout. This shares plumbing intent with the security metrics script. |

### What we read from it

Per class, per time window:

- **Count** of classifications emitted (`APPLICATION_BUG`, `TEST_BUG`,
  `FLAKY_FAILURE`, `ENVIRONMENT_ISSUE`). Passing tests are omitted, not counted.
- **👍 / 👎 totals** per class.
- **Precision** ≈ 👍 / (👍 + 👎) for each verdict — with **`APPLICATION_BUG`
  precision the headline number**, since a missed real bug is the worst
  outcome. This is the signal that tells you whether to trust the classifier,
  and (eventually) whether the P2 future direction is worth building.
- **Response rate** — what fraction of comments actually received the
  mandatory reaction. A low response rate means the signal is unreliable and
  the team needs a nudge.

> The 👍/👎 ask is **mandatory** precisely because precision is uncomputable
> without it. A classifier comment with no reaction is a measurement you
> didn't take.

---

## 6. Security considerations for AI-enabled PR/test workflows

> This section is here on purpose. The testing playbook reinforces the same
> security mindset shift the security workstream is built around — AI in CI is
> a new data-egress and write-access surface, and test tooling is *not* exempt.
> Treat it with the same rigor.

### No PHI / PII in test fixtures or prompts

- The classifier reads test code, diffs, and failure output and sends them to
  an AI tool. **Anything in a fixture is in the prompt.** Do not put real PHI,
  real PII, real member data, or production secrets in test fixtures, golden
  files, or snapshots. Use synthetic data.
- This is the same rule the security pre-commit hooks enforce on commits —
  see the security workstream's `code-security` hook, which blocks real
  PII/PHI/secrets *before* they ever land. Keep those hooks installed; the
  classifier assumes fixtures have already cleared them.

### Data minimization — send the least that yields a correct verdict

- Dedicated tools in this space set a useful bar: **FixSense sends only the test
  name, error message, and stack trace** to its analysis API — never the source
  tree, env vars, or repo contents. Adopt the same posture: the classifier reads
  only the failing-test signal, the implicated code paths, and the
  change-under-test diff — **not** the broader source tree, env files, or
  credential stores "for context."
- **The one place we deliberately send more** than a stack-trace-only tool is
  the `git diff "$AI_REVIEW_AGAINST" HEAD`. This is required and intentional: the
  `APPLICATION_BUG`-vs-`TEST_BUG` decision hinges on whether the change *intended*
  to alter the asserted behavior, and that cannot be judged without seeing the
  change. We accept that wider scope because the verdict quality depends on it —
  and we keep everything *else* minimal to compensate.
- Redact secret-shaped and PHI/PII-shaped values before they reach a prompt or a
  posted comment; never quote a suspicious fixture verbatim (see the SKILL.md
  "Data sent to the AI" section, which is the canonical version of this rule).

### The classifier never commits to a branch a human hasn't approved

- **Propose-diff-then-approve.** The classifier posts a comment and asks for a
  👍/👎. It does **not** push commits. The P2 future direction would propose
  `` ```suggestion `` diffs that a human one-click-applies — still
  human-approved, never autocommitted.
- There is nothing in the pilot where the classifier writes to your branch.
  If a future capability proposes a test edit, a person must approve and commit
  it. This is the single most important guardrail against the "AI rewrites the
  test to hide the regression" failure mode.

### Keep secrets out of CI logs

- The dispatcher uses `set -euo pipefail` and **never echoes** API keys or
  tokens. Pass `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_SHEETS_TOKEN`
  only via GitHub Actions secrets and environment variables — never as command
  arguments (which can appear in `ps` output and logs).
- If a test failure message itself contains a secret (it shouldn't, but it
  happens), that secret is now in CI logs **and** in the AI prompt. Treat such
  a secret as compromised and rotate it. Redact secret-shaped values when
  citing failure output in any posted comment.

### FedRAMP / hosted-SaaS note

- Many "AI testing" SaaS products **exfiltrate DOM snapshots, screenshots,
  network captures, or credentials** to a vendor cloud to do their analysis.
  For systems under FedRAMP / FISMA / HIPAA scrutiny, do **not** route that
  data to a non-FedRAMP-authorized cloud.
- This classifier is intentionally built on the **same** `AI_REVIEW_TOOL` CLIs
  the security workstream already vetted (`claude` / `codex` / `copilot`), so
  the data path is one your org has already reasoned about — rather than a new
  third-party testing SaaS. If you must use a hosted testing tool, confirm its
  authorization boundary first and document it in your POA&M.

### Cross-reference

- Security pre-commit hooks and PR review: `security/review/` (the bundle this
  classifier mirrors). Keep them installed — they are the first line that keeps
  PHI/PII/secrets out of the fixtures and diffs the classifier reads.
- Treat the classifier's GitHub token with the same least-privilege posture
  documented in `security/review/docs/PR_REVIEW_SETUP.md` (fine-grained PAT:
  `contents: read`, `pull-requests: write`, nothing else).

---

## 7. FAQ

**Why not just let the AI fix the failing test?**
Because if the code is the thing that broke, "fixing the test" means deleting
the only signal that caught a regression. The classifier's entire reason to
exist is to make the test-vs-code call *before* anyone edits anything.

**Why is the 👍/👎 mandatory?**
Because precision is the metric that tells you whether the classifier can be
trusted. Without the reaction, every comment is an unscored guess.

**Can different developers use different AI tools?**
Yes, locally — `AI_REVIEW_TOOL` is per-environment, exactly as in
security/review. CI picks one via the `vars.AI_REVIEW_TOOL` repository variable.

**Is the classifier ever blocking?**
Not by default. It is advisory. A team can opt into `--gate` later, but that is
out of pilot scope.

**Where do P2/P3 live?**
Nowhere yet — they are documented as future direction in §3. Do not build them
during the pilot.
