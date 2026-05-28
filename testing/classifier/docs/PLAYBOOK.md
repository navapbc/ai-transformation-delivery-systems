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
3. [Phasing: P0 → P1 → (future) P2 → P3](#3-phasing-p0--p1--future-p2--p3)
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
- A **canonical `SKILL.md`** under `.skills/`, synced into the tool-specific
  directories by `scripts/sync-skills.sh`.
- A GitHub Actions workflow that ships **disabled** (`on: workflow_dispatch`
  only), is **non-blocking/advisory by default**, and flips to build-failing
  only behind an explicit `--gate` flag.

What is *different* is the domain: this skill classifies test-vs-code rather
than reviewing for security/compliance findings, and it asks the developer for
a tuning signal (see P1 below).

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
│      test-classifier-dispatcher.sh --pr <n> --mode <p0|p1>            │
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
│         ┌───────────┴───────────┐                                     │
│         ▼ (P0)                   ▼ (P1)                                │
│   record only,             post PR comment with the call +            │
│   no PR comment            rationale + a MANDATORY 👍/👎 ask           │
│         │                          │                                  │
│         └───────────┬──────────────┘                                  │
│                     ▼                                                 │
│   metrics harvest (testing/metrics/) → Google Sheet / TSV             │
└──────────────────────────────────────────────────────────────────────┘
```

The dispatcher interface a team integrates against is:

```bash
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr <number> \
  --mode <p0|p1> \
  [--post-comment]
```

- `--pr <number>` — the pull request to classify against (auto-discovered via
  `gh pr view` if omitted, exactly like the security dispatcher).
- `--mode <p0|p1>` — the phase. `p0` records only; `p1` posts the PR comment
  and requests the 👍/👎 reaction.
- `--post-comment` — actually post to GitHub via `gh api`. In `p0` this flag
  is a no-op by design (P0 is observe-only); in `p1` it is required to post.

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
silently — it surfaces the call and the reasoning, and (in P1) makes a human
confirm it.

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

## 3. Phasing: P0 → P1 → (future) P2 → P3

The pilot is scoped to **P0 and P1 only**. P2 and P3 are documented here as
direction, not as shipped capability. Do not build them as part of the pilot.

### P0 — Observe-only  ✅ in scope

- The classifier runs in CI and **classifies every failure**.
- It **records** each call + rationale to the metrics sink (Google Sheet / TSV).
- It posts **no PR-facing comments**. Developers are not interrupted.
- Purpose: measure baseline classifier precision against real failures before
  anyone trusts a single comment it makes. You are collecting ground truth.

Run it with `--mode p0`. The `--post-comment` flag is ignored in this mode.

### P1 — MVP: comment + mandatory 👍/👎  ✅ in scope

- The classifier runs in CI and posts **one PR comment** per classified
  failure (or one rolled-up comment, team's choice), stating the verdict
  (`APPLICATION_BUG` / `TEST_BUG` / `FLAKY_FAILURE` / `ENVIRONMENT_ISSUE`) and
  the short rationale.
- The comment **requests a mandatory 👍 / 👎 reaction** from the developer:
  - 👍 = "the classifier got the call right"
  - 👎 = "the classifier got the call wrong"
- That reaction is **the tuning signal**. It is the only thing P1 asks of the
  developer, and it is mandatory because precision is unmeasurable without it.
- P1 is **non-blocking**: the comment never fails the build. (A team that
  wants a gate later can opt in via `--gate`, exactly as in security/review,
  but the pilot default is advisory.)

Run it with `--mode p1 --post-comment`.

### P2 — Proposed commit suggestions / merge-rate  🚧 FUTURE — NOT BUILT

> Documented as direction only. **Do not build during the pilot.**

The intended next step is for the classifier to attach a *proposed diff* — a
suggested edit to the test (for `TEST_BUG`) or a pointer at the regressed code
(for `APPLICATION_BUG`) — using GitHub's one-click `` ```suggestion `` blocks, and to
track the **merge-rate** of those suggestions as a stronger quality signal
than 👍/👎 alone. This stays behind the **propose-diff-then-approve** rule (see
§6): the classifier proposes; a human approves and commits. No autocommit.

### P3 — Zero-shot test generation  🚧 FUTURE — NOT BUILT

> Documented as direction only. **Do not build during the pilot.**

The long-horizon goal: generate net-new tests for uncovered behavior from a
spec or a diff. This is explicitly **gated behind a mature P0/P1 precision
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

### Step 1 — Copy the workflow into place

The bundle ships a workflow at
`testing/classifier/.github/workflows/ai-test-classifier.yml`. Copy it to your
repo's live workflows directory:

```bash
cp testing/classifier/.github/workflows/ai-test-classifier.yml \
   .github/workflows/ai-test-classifier.yml
```

> ⚠️ **Merge, don't overwrite.** If you already have a workflow with that
> name, open both files and merge — don't clobber an existing one.

The workflow ships **disabled**: its only trigger is `workflow_dispatch`, with
a commented-out `pull_request:` block and a banner explaining how to enable it.
This is identical to the security workstream's posture.

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

### Step 4 — Set the phase via the `MODE` input

The classifier's phase is controlled by a **`MODE`** value of `p0` or `p1`,
which the workflow passes to the dispatcher as `--mode`. The workflow exposes
this two ways:

- As a `workflow_dispatch` **input** named `mode` (default `p0`) so you can run
  a manual classification at either phase without editing the file.
- As a repository **variable** `CLASSIFIER_MODE` that the `pull_request`
  trigger reads, so the automatic path has a phase too.

**Start every pilot in `p0`.** Only switch to `p1` once P0 precision looks
trustworthy (see §5). To switch:

1. **Settings** → **Secrets and variables** → **Actions** → **Variables**.
2. Add/edit `CLASSIFIER_MODE` = `p0` (observe-only) or `p1` (comment + 👍/👎).

### Step 5 — Confirm workflow permissions (least privilege)

The workflow declares exactly what it needs and nothing more:

```yaml
permissions:
  contents: read         # check out the repo, read the diff and test output
  pull-requests: write   # post the classifier comment (P1 only)
```

In `p0` the workflow does not post and only needs `contents: read`; the
`pull-requests: write` grant is harmless because P0 never calls the posting
path. If your org enforces restrictive default-token permissions, confirm the
workflow's `permissions:` block is honored under **Settings** → **Actions** →
**General** → **Workflow permissions**.

### Step 6 — Enable the trigger

Edit `.github/workflows/ai-test-classifier.yml` and change:

```yaml
on:
  workflow_dispatch:
    inputs:
      mode:
        description: "Classifier phase"
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
        description: "Classifier phase"
        default: "p0"
  pull_request:
    types: [opened, synchronize, reopened]
```

Commit and push. The next PR triggers a classification at whatever phase
`CLASSIFIER_MODE` is set to.

### Step 7 — (Optional, later) enable gating

The pilot default is **advisory / non-blocking** — exactly like security
review. If, much later, a team wants a failing classification (e.g. an
unconfirmed `APPLICATION_BUG`) to fail the build, uncomment the `--gate` line in the
workflow's run step:

```yaml
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr "${PR_NUMBER}" \
  --mode "${CLASSIFIER_MODE}" \
  --post-comment
  # --gate
```

Use with care: a false `APPLICATION_BUG` becomes a merge blocker.

---

## 5. The metrics loop

The classifier is only as good as our ability to measure it, and the pilot's
whole purpose is to gather that measurement. Two things are harvested:

1. **The 👍/👎 reaction counts** on each P1 classifier comment — the developer's
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
| **Google Sheet (primary)** | The shared pilot dashboard everyone reads. | The script POSTs rows to a Sheet via a **service-account bearer token**. Set `CLASSIFIER_SHEET_ID` and `CLASSIFIER_SHEET_TOKEN` (the service-account access token) in the environment. |
| **CSV/TSV to stdout (P0 fallback)** | The realistic default for early pilots before the Sheet plumbing is wired. Pipe it anywhere. | Run with `--format tsv` (or `--format csv`); the script writes rows to stdout. This shares plumbing intent with the security metrics script. |

### What we read from it

Per class, per time window:

- **Count** of classifications emitted (`APPLICATION_BUG`, `TEST_BUG`,
  `FLAKY_FAILURE`, `ENVIRONMENT_ISSUE`). Passing tests are omitted, not counted.
- **👍 / 👎 totals** per class.
- **Precision** ≈ 👍 / (👍 + 👎) for each verdict — with **`APPLICATION_BUG`
  precision the headline number**, since a missed real bug is the worst
  outcome. This is what decides whether a pilot graduates from P0 to P1, and
  (eventually) whether P2 is worth building.
- **Response rate** — what fraction of P1 comments actually received the
  mandatory reaction. A low response rate means the signal is unreliable and
  the team needs a nudge, not a phase change.

> The 👍/👎 ask is **mandatory** in P1 precisely because precision is
> uncomputable without it. A classifier comment with no reaction is a
> measurement you didn't take.

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

- **Propose-diff-then-approve.** P1 posts a comment and asks for a 👍/👎. It does
  **not** push commits. P2 (future) will propose `` ```suggestion `` diffs that
  a human one-click-applies — still human-approved, never autocommitted.
- There is no mode in the pilot where the classifier writes to your branch.
  If a future capability proposes a test edit, a person must approve and commit
  it. This is the single most important guardrail against the "AI rewrites the
  test to hide the regression" failure mode.

### Keep secrets out of CI logs

- The dispatcher uses `set -euo pipefail` and **never echoes** API keys or
  tokens. Pass `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `CLASSIFIER_SHEET_TOKEN`
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
Because precision is the metric that decides whether the classifier earns more
trust (P1 → P2). Without the reaction, every comment is an unscored guess.

**Can different developers use different AI tools?**
Yes, locally — `AI_REVIEW_TOOL` is per-environment, exactly as in
security/review. CI picks one via the `vars.AI_REVIEW_TOOL` repository variable.

**Is the classifier ever blocking?**
Not by default. P0 and P1 are advisory. A team can opt into `--gate` later, but
that is out of pilot scope.

**Where do P2/P3 live?**
Nowhere yet — they are documented direction in §3. Do not build them during the
pilot.
