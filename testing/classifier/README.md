# AI Test Classifier — Overview

This bundle ships an AI **test classifier** that runs after your test suite
(in CI or against a local commit) and answers the one question teams keep
getting wrong when they wire AI into testing:

> **When a test fails, is the *test* wrong, or is the *code* wrong?**

For every failure it emits one of four calls, with a short rationale:

| Call | Meaning | Action |
|---|---|---|
| **`APPLICATION_BUG`**   | Test failed because the app actually regressed. | Fix the CODE. |
| **`TEST_BUG`**          | Test failed, app is fine (stale/brittle test). | Fix the TEST. |
| **`FLAKY_FAILURE`**     | Intermittent failure, not a real regression. | Re-run, then deflake. |
| **`ENVIRONMENT_ISSUE`** | Infra fault (timeout/connection/OOM/missing service). | Fix the env or re-run. |

Passing tests are omitted — "nothing failed" surfaces as the `NO_ACTION` result
marker, not a per-test verdict.

The point is to **never generate no-op tests for genuinely broken code** — the
worst failure mode of "AI fixes the failing tests" tooling. The classifier
makes the test-vs-code call explicitly, before anyone edits anything.

It is the testing-workstream counterpart to the `security/review/` bundle and
reuses its conventions exactly:

- Tool selection via the `AI_REVIEW_TOOL` env var (`claude` | `codex` |
  `copilot`).
- The result-marker contract: the AI ends with one `<<<AI_REVIEW_RESULT:...>>>`
  marker the dispatcher parses.
- A canonical `SKILL.md` under `.skills/`, synced into tool-specific dirs by
  `scripts/sync-skills.sh`.
- A GitHub Actions workflow that ships **disabled**, **advisory/non-blocking**
  by default, with a `--gate` flag to opt into build-failing later.
- Same bash style: `set -euo pipefail`, `ai_review::`-namespaced helpers,
  color suppressed in CI; least-privilege `GITHUB_TOKEN` permissions.

## Scope: P0 and P1 only

- **P0 — observe-only.** Classify in CI, record to the metrics sink, post **no**
  PR comments.
- **P1 — MVP.** Post a PR comment with the call + rationale and request a
  **mandatory 👍/👎** reaction from the developer. That reaction is the tuning
  signal. Non-blocking.

**P2** (proposed commit suggestions / merge-rate) and **P3** (zero-shot test
generation) are documented as **future direction** in the playbook only — they
are **not built** in this pilot.

## Layout

```
testing/classifier/
├── README.md                                   ← you are here
├── INSTALL.txt                                 ← quick install steps
├── docs/
│   ├── PLAYBOOK.md                             ← the prescriptive pilot playbook
│   └── SETUP.md                                ← Path A (local) + Path B (Actions) setup
├── .github/
│   ├── copilot-instructions.md                 ← Copilot test-classification instructions
│   └── workflows/
│       └── ai-test-classifier.yml              ← GitHub Actions workflow (disabled by default)
└── .skills/
    └── test-classifier/
        ├── SKILL.md                            ← canonical classification skill
        └── scripts/
            └── test-classifier-dispatcher.sh   ← --pr --mode --post-comment

testing/metrics/
└── test_classifier_comments.sh                 ← harvests 👍/👎 reactions → Google Sheet / TSV
```

## Start here

1. Read **`docs/PLAYBOOK.md`** — the four-verdict taxonomy, the P0→P1 phasing, the
   metrics loop, and the embedded security-considerations section.
2. Follow **`docs/SETUP.md`** — Path A to run locally, Path B to enable the
   GitHub Actions workflow, with the `MODE` (`p0`/`p1`) configuration.
3. Use **`INSTALL.txt`** for the fast-path file-copy steps.

## Dispatcher interface

```bash
testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh \
  --pr <number> \
  --mode <p0|p1> \
  [--post-comment]
```

## A note on security

Test tooling is not exempt from the security mindset. No real PHI/PII in
fixtures or prompts; the classifier never commits to a branch a human hasn't
approved (propose-diff-then-approve); keep secrets out of CI logs; and don't
route DOM/screenshots/credentials to a non-FedRAMP testing SaaS. The full
treatment is in `docs/PLAYBOOK.md` §6, which cross-references the
`security/review/` pre-commit hooks.
