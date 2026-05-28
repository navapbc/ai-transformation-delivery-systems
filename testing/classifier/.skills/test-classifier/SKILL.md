---
name: test-classifier
description: >
  Classify a CI test failure (or a commit's failing tests) into one of three
  scenarios — test-fix, code-fix, or no-action — so teams never auto-generate
  no-op tests for genuinely broken code, and never "fix" the application when
  the test itself is stale. Implements Joe's 3-scenario framing: (1) test fails
  but the app is fine → fix the TEST; (2) test fails because the app regressed →
  fix the CODE; (3) test passes → no action. For each failing test the skill
  emits a verdict plus a short rationale and a failure category (visual drift,
  behavioral drift, E2E form-flow drift). Produces a human-readable terminal
  report and a machine-readable JSON block that the dispatcher uses to record
  (P0) or post a single PR comment requesting a mandatory 👍/👎 reaction (P1).
  Use this skill whenever a CI test run fails and you want to know whether the
  test or the code is at fault, or when a developer requests an AI test triage.
---

# Test Classifier Skill

A triage layer that sits between "a test went red in CI" and "a human decides
what to do about it." Its **primary job** is to answer one question for every
failing test: *is the test wrong, or is the code wrong?* — and to say so out
loud, with a rationale, so that downstream automation (or a tired developer at
2pm on a Friday) never patches the wrong side of the failure.

This skill is invoked by a dispatcher
(`.skills/test-classifier/scripts/test-classifier-dispatcher.sh`) which selects
an AI assistant based on the `AI_REVIEW_TOOL` environment variable
(`claude` | `codex` | `copilot`). The skill instructions are identical across
all three assistants; only the invoking CLI differs.

This file (`.skills/test-classifier/SKILL.md`) is the **canonical** copy. Each
developer's chosen AI tool reads either this file or a byte-identical derived
copy under `.claude/`, `.codex/`, or `.github/copilot/`, depending on what
`scripts/sync-skills.sh` produced for their `AI_REVIEW_TOOL` setting.

---

## The 3-Scenario Framing (what we are classifying)

Every failing test maps to exactly one of three scenarios. This is the whole
model; everything else in this skill is in service of getting the verdict right.

| # | Test result | App behavior | Verdict | What a human should do |
|---|---|---|---|---|
| 1 | **Fails** | **Correct** (app is fine) | `test-fix` | Fix the TEST. It is stale or it is a change-detector asserting on an intended change. |
| 2 | **Fails** | **Regressed** (app is broken) | `code-fix` | Fix the CODE. The application genuinely regressed and the test caught it. |
| 3 | **Passes** | n/a | `no-action` | Nothing. The test passed; it is reported only for completeness. |

> **Why this distinction is load-bearing.** The expensive failure mode is not a
> red build — it is "fixing" the wrong thing. If the app is correct and we
> blindly regenerate or relax the test, we erode the test's value (scenario 1
> mishandled). If the app regressed and we instead "update the snapshot" to make
> the test pass, we ship a bug with a green checkmark (scenario 2 mishandled).
> The classifier exists to keep those two cases apart **before** anyone writes a
> patch — and specifically so teams never generate no-op tests for genuinely
> broken code.

---

## Scope: P0 and P1 only

This skill implements two maturity levels, selected by the dispatcher's
`--mode` flag and reflected in the JSON `mode` field:

| Mode | Name | What the classifier does | PR-facing? |
|---|---|---|---|
| **p0** | Observe-only | Classify each failing test in CI, emit the report + JSON, and let the dispatcher **record** the result. No PR comment is posted. | No |
| **p1** | MVP | Everything P0 does, **plus** the dispatcher posts ONE PR comment with the call + rationale and requests a **mandatory** 👍/👎 reaction from the developer. That reaction is the tuning signal. Non-blocking. | Yes (one comment) |

**P2 and P3 are explicitly OUT of scope for this skill.** They are documented as
future work in the playbook only and must not be implemented here:

- **P2 (future)** — proposed commit suggestions for `test-fix` / `code-fix`
  verdicts, and a merge-rate metric on those suggestions. Do **not** emit
  applyable code suggestions from this skill.
- **P3 (future)** — zero-shot generation of brand-new tests. Do **not** generate
  tests. This skill only classifies failures that already exist.

If you find yourself wanting to write a patch or author a test, stop: that is
P2/P3 territory and out of current scope.

---

## Execution Overview

1. **Collect the failing-test signal** — which tests failed, with their output
2. **Collect the diff** — `git diff` against `AI_REVIEW_AGAINST` (the change under test)
3. **For each failing test, decide the verdict** — test-fix / code-fix / no-action
4. **Tag a failure category** — visual drift / behavioral drift / E2E form-flow drift / other
5. **Assign a confidence** — high / medium / low, honestly
6. **Emit two artifacts:**
   - A **human-readable terminal report** for developers running the dispatcher locally
   - A **machine-readable JSON block** the dispatcher records (P0) or posts as one PR comment (P1)
7. **Emit result marker** — exactly one of `<<<AI_REVIEW_RESULT:CLASSIFIED|NO_ACTION>>>`

---

## Step 1 — Collect the Failing-Test Signal

The classifier needs to know *what failed and why it says it failed*. Gather, in
order of preference:

- The CI test runner's failure output (assertion messages, diffs of
  expected-vs-actual, stack traces, snapshot diffs).
- The names and file paths of the failing tests.
- For visual/snapshot tests, the recorded baseline-vs-actual diff if available.

If no test failed (the run is green), there is nothing to classify: emit a
`no-action` summary and the `NO_ACTION` marker, and stop.

---

## Step 2 — Collect the Diff

The dispatcher passes the change-under-test base ref via the
`AI_REVIEW_AGAINST` environment variable. If unset, the dispatcher will have
refused to run.

```bash
git diff "$AI_REVIEW_AGAINST" HEAD --unified=5      # full content of the change
git diff "$AI_REVIEW_AGAINST" HEAD --name-only      # list of changed paths
```

The diff is your evidence for the central question: did this change *intend* to
alter the behavior the failing test asserts on? An intended behavior change that
the test wasn't updated for points toward `test-fix`. A change that should NOT
have altered that behavior, yet did, points toward `code-fix`.

---

## Step 3 — Decide the Verdict (the decision procedure)

For each failing test, work through this procedure. Be explicit in the rationale
about which branch you took and what evidence drove it.

1. **Did the test actually fail?** If it passed, verdict = `no-action`. Done.
2. **Determine the app's intended behavior** for the assertion that failed. Use:
   the diff (what did the author set out to change?), the test's own intent (what
   contract is it guarding?), surrounding code, and any spec/PR-description signal.
3. **Is the app's *current* behavior correct** with respect to that intended
   behavior?
   - **Yes — the app is doing the right thing, the test is asserting the old
     thing.** Verdict = `test-fix`. The test is stale, or it is a
     change-detector that is firing on an intended change. The TEST should be
     updated to match the new, correct behavior.
   - **No — the app is doing the wrong thing; the change introduced a
     regression the test correctly caught.** Verdict = `code-fix`. The CODE
     should be fixed; the test is doing its job.
4. **If you cannot tell** which side is correct from the available evidence,
   do not guess a confident verdict. Pick the more likely verdict, set
   `confidence: low`, and say plainly in the rationale what additional signal a
   human would need (e.g., "needs product decision on whether the new copy is
   intended").

### What is OUT of classifier scope

The classifier must **not** render a confident test-fix/code-fix verdict for
failures it cannot reason about from static signal. Tag these honestly (use
`confidence: low` and/or `category: "other"`, and say so in the rationale), and
defer to a human:

- **Failures that need manual/exploratory testing** to determine correctness
  (e.g., "is this the right UX?" — that's a product call, not a static one).
- **Flaky or infrastructure failures** — timeouts, network blips, port
  contention, ordering-dependent tests, CI runner resource exhaustion. These are
  neither test-fix nor code-fix in the sense above; flag them as flaky/infra and
  recommend a re-run or a deflaking task, not a code or test patch.
- **Failures better handled deterministically** — a linter, a type checker, a
  schema validator, or a compile error masquerading as a "test failure" should
  be fixed by the deterministic tool that owns it, not triaged by an LLM.

When in doubt, prefer `confidence: low` and an honest rationale over a confident
wrong call. A low-confidence-but-correct triage is useful; a high-confidence
wrong one trains the team to distrust the classifier.

---

## Step 4 — Tag a Failure Category

Aligned to the test + QA doc, tag each failing test with one of the following
categories. These describe the *kind* of failure, independent of the verdict —
a `behavioral-drift` failure can be either a `test-fix` or a `code-fix`.

| Category | What it means | Typical signal |
|---|---|---|
| `visual-drift` | A rendered-UI / snapshot / screenshot test failed because pixels or DOM structure changed. | Image-diff or snapshot mismatch; "X% of pixels differ"; updated component markup. |
| `behavioral-drift` | A unit/integration test failed because a function's logic, return value, or side effect changed. | Assertion on a value/branch/exception that no longer holds. |
| `e2e-form-flow-drift` | An end-to-end test driving a multi-step user flow (especially form submission flows) failed at some step. | Selector not found, step timed out, validation/redirect path changed, submit produced a different result. |
| `other` | Does not fit the above — including flaky/infra failures and deterministic-tooling failures (see "OUT of scope"). | Timeouts, env errors, lint/type/compile errors. |

The category is advisory metadata that helps the metrics layer slice precision
by failure type; it does not change the verdict logic.

---

## Step 5 — Assign Confidence

Every classification carries a `confidence` of `high`, `medium`, or `low`:

- **high** — the diff and the failure output unambiguously point to one side.
  (e.g., the author intentionally changed a label string and only the
  string-assertion test broke → `test-fix`, high.)
- **medium** — the evidence leans one way but a reasonable reviewer could
  disagree, or some context is missing.
- **low** — genuinely uncertain, or the failure is out of scope (manual,
  flaky/infra, deterministic). Always pair `low` with an actionable rationale.

---

## Step 6 — Emit Output

The dispatcher needs **two artifacts** in a single AI response: a human-readable
report for terminal display, and a machine-readable JSON block. Both must be
emitted in the same response, with the JSON block clearly fenced so the
dispatcher can extract it without ambiguity.

### 6A — Human-Readable Terminal Report

This is what the developer running the dispatcher locally sees. Group by file,
lead each finding with its verdict, and keep rationales to one or two sentences.

```
## Test Classifier Report
**Mode:** P0 (observe-only) | P1 (MVP — posts one PR comment)
**Scope:** Change under test = diff against <base-ref> (N files changed)
**Failing tests classified:** K

---

### Classifications by file

#### `src/components/Banner.test.tsx`

- ✏️  **TEST-FIX** | visual-drift | confidence: high
  `Banner › renders the announcement copy`
  The diff intentionally updates the banner copy from "Welcome" to "Welcome back".
  The app is rendering the new, correct copy; the snapshot is stale. Update the test.

#### `src/api/checkout.test.ts`

- 🛠️  **CODE-FIX** | behavioral-drift | confidence: high
  `checkout › applies the loyalty discount`
  The diff refactored `applyDiscount()` and now returns the pre-discount total.
  Nothing in the change intended to remove the discount — the code regressed. Fix the code.

#### `e2e/signup.spec.ts`

- ❓ **CODE-FIX** | e2e-form-flow-drift | confidence: low
  `signup › submits the registration form`
  The submit step times out at the "Create account" button. Could be a real
  regression in the submit handler or a flaky selector — needs a re-run to rule
  out infra before a code change.

---

### Summary
| Verdict     | Count |
|---|---|
| test-fix    | 1 |
| code-fix    | 2 |
| no-action   | 0 |

**Recommendation:** CLASSIFIED — 3 failing tests triaged (1 test-fix, 2 code-fix).
In P1, the PR comment below will be posted requesting a mandatory 👍/👎 reaction.
```

### 6B — Machine-Readable JSON Block (for dispatcher → record / PR comment)

After the human-readable report, emit a single fenced JSON block, exactly once
per response. The fence opener must be exactly
`<!-- AI_CLASSIFIER_JSON_BEGIN -->` and the closer exactly
`<!-- AI_CLASSIFIER_JSON_END -->`, each on its own line. The JSON between the
markers must be a single object with the schema below.

```
<!-- AI_CLASSIFIER_JSON_BEGIN -->
{
  "mode": "p1",
  "summary": "Triaged 3 failing tests against the change: 1 test-fix (stale snapshot, app is correct), 2 code-fix (loyalty discount regressed; signup submit may have regressed — low confidence, recommend re-run). No no-op tests should be generated for the code-fix cases.",
  "classifications": [
    {
      "test": "Banner › renders the announcement copy",
      "path": "src/components/Banner.test.tsx",
      "line": 22,
      "verdict": "test-fix",
      "category": "visual-drift",
      "confidence": "high",
      "rationale": "The diff intentionally changes the banner copy to 'Welcome back'. The app renders the new, correct copy; the snapshot assertion is stale. Update the test, not the code."
    },
    {
      "test": "checkout › applies the loyalty discount",
      "path": "src/api/checkout.test.ts",
      "line": 58,
      "verdict": "code-fix",
      "category": "behavioral-drift",
      "confidence": "high",
      "rationale": "The refactor of applyDiscount() now returns the pre-discount total. Nothing in the change intended to remove the discount; the code regressed and the test correctly caught it. Fix the code; do NOT relax the test."
    },
    {
      "test": "signup › submits the registration form",
      "path": "e2e/signup.spec.ts",
      "line": 41,
      "verdict": "code-fix",
      "category": "e2e-form-flow-drift",
      "confidence": "low",
      "rationale": "Submit step times out at 'Create account'. May be a real regression in the submit handler, or a flaky selector/infra timeout. Recommend a re-run to rule out flakiness before patching code."
    }
  ]
}
<!-- AI_CLASSIFIER_JSON_END -->
```

**JSON schema requirements:**

- `mode` — `"p0"` or `"p1"`. Must match the dispatcher's `--mode`.
- `summary` — a short overall triage summary. In P1 this seeds the top of the
  posted PR comment.
- `classifications` — array, one entry per failing test considered. Each entry:
  - `test` — the failing test's name/id as the runner reports it.
  - `path` — repo-relative path to the test file (matches `git diff --name-only`
    conventions).
  - `line` — 1-indexed line number of the failing assertion/test in that file
    (best effort; use the test's declaration line if the assertion line is
    unknown).
  - `verdict` — one of `"test-fix"`, `"code-fix"`, `"no-action"`.
  - `category` — one of `"visual-drift"`, `"behavioral-drift"`,
    `"e2e-form-flow-drift"`, `"other"`.
  - `confidence` — one of `"high"`, `"medium"`, `"low"`.
  - `rationale` — one to three sentences explaining the verdict and the evidence.
    For `code-fix`, make explicit that the fix belongs in the application code,
    not the test (this is the guardrail against no-op test generation).

If every failing test resolves to `no-action` (or nothing failed),
`classifications` may be empty and the run emits the `NO_ACTION` marker.

### 6C — P1 PR comment body (what the dispatcher posts)

In **P1**, the dispatcher renders ONE issue comment on the PR from the JSON
above. The comment **MUST** request a mandatory 👍/👎 reaction and explain that
the reaction is the tuning signal. The rendered body looks like this:

```
test-classifier: AI triage of failing tests

## 🧪 AI Test Classifier — triage of failing tests

<summary>

| Verdict | Test | Category | Confidence |
|---|---|---|---|
| test-fix | `Banner › renders the announcement copy` | visual-drift | high |
| code-fix | `checkout › applies the loyalty discount` | behavioral-drift | high |
| code-fix | `signup › submits the registration form` | e2e-form-flow-drift | low |

<per-test rationales>

---

### 👍 / 👎 required — this is how we tune the classifier

**Please react to this comment with 👍 if these calls are right, or 👎 if any are wrong.**
Your reaction is the tuning signal we use to measure classifier precision and
decide when it is trustworthy enough to graduate to suggesting fixes. A 👎 with a
one-line reply telling us which verdict was wrong is worth its weight in gold.

This comment is advisory and non-blocking — it will never fail your build.
```

The reaction ask is not optional decoration; it is the core of the P1 feedback
loop. The dispatcher will state it explicitly, and the metrics layer
(`testing/metrics/`) harvests the 👍/👎 counts off this exact comment.

---

## Step 7 — Result Marker

End the response with exactly one of:

```
<<<AI_REVIEW_RESULT:CLASSIFIED>>>
<<<AI_REVIEW_RESULT:NO_ACTION>>>
```

Marker contract:

- `CLASSIFIED` — at least one failing test was triaged with a `test-fix` or
  `code-fix` verdict (i.e., `classifications` contains a non-`no-action` entry).
- `NO_ACTION` — nothing failed, or every classification is `no-action`.

The marker must be on its own line with no surrounding text. It must be
consistent with the JSON `classifications`. Failure to emit a marker, or a
mismatch between the marker and the JSON, causes the dispatcher to log an error
and exit non-zero. (We keep the shared `<<<AI_REVIEW_RESULT:...>>>` envelope for
consistency with the security workstream's dispatch library; only the
vocabulary — `CLASSIFIED` / `NO_ACTION` — is specific to the classifier.)

---

## Notes for the Classifier

- **Never patch, never generate.** Your output is a verdict and a rationale,
  full stop. Proposing commit suggestions (P2) and authoring tests (P3) are out
  of current scope. If a `code-fix` verdict is correct, the *value* of the
  classifier is precisely that it told a human to fix the code rather than
  silently regenerating the test to pass.
- **Be honest about uncertainty.** A `low`-confidence verdict with a clear "here
  is what I couldn't tell" is more useful than a confident guess. The 👍/👎 loop
  punishes confident wrongness.
- **Flaky and infra failures are not code-fix or test-fix.** Do not invent a
  code regression to explain a timeout. Tag it, say "recommend a re-run," and
  move on.
- **Deterministic failures belong to deterministic tools.** A type error or a
  lint failure is not an interesting triage; note it and defer to the tool that
  owns it.
- **One classification per failing test, not per assertion.** If a single test
  has three failing assertions for one root cause, emit one classification.
