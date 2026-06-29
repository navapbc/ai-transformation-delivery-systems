---
name: test-classifier
description: >
  Classify each failing CI test into one of four verdicts — APPLICATION_BUG,
  TEST_BUG, FLAKY_FAILURE, or ENVIRONMENT_ISSUE — so teams never auto-generate
  no-op tests for genuinely broken code, never "fix" the application when the
  test itself is stale, and never burn a code/test patch on an intermittent or
  infrastructure failure. Built on Joe's framing (is the test wrong or the code
  wrong?) and aligned to the industry-standard four-way failure taxonomy used by
  tools like ContextQA and FixSense. For each failing test the skill emits a
  verdict plus a short rationale and a failure category (visual drift, behavioral
  drift, E2E form-flow drift). Produces a human-readable terminal report and a
  machine-readable JSON block that the dispatcher uses to post a single PR
  comment requesting a mandatory 👍/👎 reaction. Use this skill
  whenever a CI test run fails and you want to know whether the test, the code,
  the test's stability, or the environment is at fault.
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

## The Four-Verdict Taxonomy (what we are classifying)

Every failing test maps to exactly one of four verdicts. This is the whole
model; everything else in this skill is in service of getting the verdict right.
The taxonomy follows the industry-standard four-way split (ContextQA, FixSense,
TestDino), grounded in Joe's original framing: *is the test wrong or the code
wrong?* — extended so that an intermittent or infrastructure failure is never
mistaken for either.

| Verdict | Test result | Root cause | What a human should do |
|---|---|---|---|
| `APPLICATION_BUG` | **Fails** | The app **regressed**; the test correctly caught a real defect. | Fix the CODE. The test is doing its job — do **not** relax it. |
| `TEST_BUG` | **Fails** | The app is **correct**; the test is stale or a change-detector asserting on an intended change. | Fix the TEST. Update it to match the new, correct behavior. |
| `FLAKY_FAILURE` | **Fails intermittently** | Non-deterministic test/timing/ordering; passes on re-run with no code change. | Re-run to confirm; then deflake the test. **Not** a code or test-logic patch. |
| `ENVIRONMENT_ISSUE` | **Fails** | Infrastructure: timeout, network blip, port contention, runner resource exhaustion, missing service. | Fix the environment / re-run. Neither the app nor the test is at fault. |

A test that **passes** is not a failure and is not classified — it simply does
not appear in the output, and (if nothing failed at all) the run emits the
`NO_ACTION` marker. There is no per-test "no-action" verdict.

> **Why this distinction is load-bearing.** The expensive failure mode is not a
> red build — it is "fixing" the wrong thing. If the app is correct and we
> blindly regenerate or relax the test, we erode the test's value
> (`TEST_BUG` mishandled). If the app regressed and we instead "update the
> snapshot" to make the test pass, we ship a bug with a green checkmark
> (`APPLICATION_BUG` mishandled). And if we invent a code regression to explain
> a timeout, we waste a developer's afternoon chasing a ghost
> (`FLAKY_FAILURE` / `ENVIRONMENT_ISSUE` mishandled). The classifier exists to
> keep these four cases apart **before** anyone writes a patch — and
> specifically so teams never generate no-op tests for genuinely broken code,
> and never patch code to chase a flaky test.

---

## Scope

The classifier classifies each failing test and posts ONE PR comment with the
verdicts plus a **mandatory** 👍/👎 reaction (the tuning signal). The comment is
advisory and non-blocking.

**Two further directions are explicitly OUT of scope for this skill.** They are
documented as future work in the playbook only and must not be implemented here:

- **Future direction (not built)** — proposed commit suggestions for
  `APPLICATION_BUG` / `TEST_BUG` verdicts, and a merge-rate metric on those
  suggestions. Do **not** emit applyable code suggestions from this skill.
- **Future direction (not built)** — zero-shot generation of brand-new tests. Do
  **not** generate tests. This skill only classifies failures that already exist.

If you find yourself wanting to write a patch or author a test, stop: that is
out of current scope.

---

## Execution Overview

1. **Collect the failing-test signal** — which tests failed, with their output
2. **Collect the diff** — `git diff` against `AI_REVIEW_AGAINST` (the change under test)
3. **For each failing test, decide the verdict** — APPLICATION_BUG / TEST_BUG / FLAKY_FAILURE / ENVIRONMENT_ISSUE
4. **Tag a failure category** — visual drift / behavioral drift / E2E form-flow drift / other
5. **Assign a confidence** — high / medium / low, honestly
6. **Emit two artifacts:**
   - A **human-readable terminal report** for developers running the dispatcher locally
   - A **machine-readable JSON block** the dispatcher posts as one PR comment
7. **Emit result marker** — exactly one of `<<<AI_REVIEW_RESULT:CLASSIFIED|NO_ACTION>>>`

---

## Step 1 — Collect the Failing-Test Signal

The classifier needs to know *what failed and why it says it failed*. There are
two ways to get that signal, and which one you use determines the result `mode`:

### OBSERVED — run the suite yourself (when `AI_RUN_SUITE=1`)

When the environment variable `AI_RUN_SUITE=1` is set (the CI workflows set it,
and you have been granted shell execution), **locate and run the repo's test
suite yourself**, then classify the failures you actually observe:

1. **Locate the test command.** Inspect the checked-out repo: `package.json`
   `scripts.test`, a `Makefile` `test:` target, `pytest.ini`/`tox.ini`/
   `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, or the repo's own CI
   workflow's test step (`.github/workflows/*`). Use what the repo actually uses.
2. **Install dependencies** using the repo's own lockfile, best-effort —
   `npm ci`/`pnpm i`/`yarn`, `pip install -r …`/`poetry install`, `go mod
   download`, `cargo fetch`, etc. Only what the stock runner image supports.
3. **Run the suite** (prefer the non-watch / single-run invocation; e.g. add
   `--run` for vitest) and capture pass/fail plus the failure output. This is
   your OBSERVED signal.
4. Set the result `mode` to `"OBSERVED"` in the JSON.

> **Infrastructure-as-code tests need a teardown guarantee — never strand real
> resources.** Some repos (Terraform/OpenTofu modules, Pulumi, CloudFormation)
> have a "test suite" that **applies real cloud resources**. That is fine to run
> *only* when teardown is guaranteed; the failure mode to avoid is an interrupted
> run (timeout, turn cap) that leaves **orphaned resources** in the consumer's
> cloud account (real cost + security exposure). Detect IaC first (`*.tf`,
> `*.tftest.hcl`/`.tftest.json`, a `terraform`/`tofu`/Terratest step, `Pulumi.yaml`),
> then work down this ladder and stop at the first rung you can do safely:
>
> 1. **No-provision checks (always safe, prefer these).** `terraform validate`,
>    `terraform fmt -check`, and `terraform test` **when it cannot apply** — every
>    `run` block is `command = plan`, or the tests use `mock_provider`/`override_*`
>    (TF ≥1.7) so there are no real provider calls. A genuine OBSERVED signal with
>    zero infrastructure. Terratest always applies, so it does **not** qualify here.
> 2. **Apply *with* a guaranteed teardown.** Run a real apply-mode suite only if a
>    teardown is **guaranteed regardless of how this run ends**, i.e. one of:
>    - the repo has a **separate, PR-scoped cleanup** that destroys by environment
>      key on PR close (e.g. a `cleanup-preview` workflow that runs
>      `terraform destroy` for `preview-pr-<N>`) — teardown is decoupled from your
>      run, so an interruption can't strand anything; **or**
>    - you run the destroy yourself **in the same execution** immediately after the
>      assertions, with the destroy guarded so it runs even on test failure (the
>      native `terraform test` lifecycle does this; a raw `apply` does not unless
>      you pair it with `terraform destroy`).
>    Use an **isolated state prefix / ephemeral environment name** so a destroy
>    can't touch anything real, and only proceed if the apply can finish well
>    inside your time budget (leave room for the destroy). If you can't guarantee
>    both, do not apply.
> 3. **Otherwise fall back to INFERRED.** If the only way to exercise the tests is
>    an unguarded real apply, do **not** run it — predict from the diff and say so
>    in the summary (e.g. "Terraform tests provision real infra and no guaranteed
>    teardown was available; ran validate + plan-mode, predicted the rest from the
>    diff"). A safe prediction beats an orphaned VPC. Same rule for any test that
>    stands up real external state (Pulumi, CloudFormation, live DB migrations).

### INFERRED — predict from the diff (fallback)

If `AI_RUN_SUITE` is not set, **or** you cannot locate / install / run the suite
(no test command found, missing toolchain, the suite needs services like a
database, it times out, **or it would apply real infrastructure with no
guaranteed teardown** — see the IaC ladder above), do **not** fabricate a run.
Instead reason
statically over the diff (Step 2) and PREDICT which tests the change would cause
to fail and why. Then:

- Set the result `mode` to `"INFERRED"`.
- State the reason you fell back in the `summary` (e.g. "no test script found",
  "deps failed to install", "suite timed out", "AI_RUN_SUITE not set") so the
  reviewer sees why this is a prediction, not an observation.
- Prefer lower confidence, and remember `FLAKY_FAILURE`/`ENVIRONMENT_ISSUE` are
  generally NOT determinable from a diff alone — only assert them with explicit
  evidence.

### Either way

Gather, in order of preference: the test runner's failure output (assertion
messages, expected-vs-actual diffs, stack traces, snapshot diffs); the names and
file paths of the failing tests; for visual/snapshot tests, the recorded
baseline-vs-actual diff if available.

If no test failed (the run is green, or the diff implicates no test), there is
nothing to classify: emit an empty `classifications` array and the `NO_ACTION`
marker, and stop. Passing tests are never listed.

---

## Step 2 — Collect the Diff

The dispatcher passes a **candidate** range via `AI_REVIEW_DIFF_RANGE` (and the
base ref via `AI_REVIEW_AGAINST`). Start there:

```bash
git diff $AI_REVIEW_DIFF_RANGE --name-only          # list of changed paths
git diff $AI_REVIEW_DIFF_RANGE --unified=5          # full content of the change
```

**Verify it reflects the real change under test — it is a starting point, not
gospel.** The precomputed base (often `origin/<base>`) can be wrong or empty when
the PR lives on a different repo than the local `origin`, on a fork or enterprise
host, or when `origin/<base>` is stale/absent. If the name-only diff is empty or
clearly not this PR's change, re-resolve the base yourself before concluding
there is nothing to classify: for a PR run use `AI_REVIEW_PR_NUMBER` /
`AI_REVIEW_REPO_SLUG` / `AI_REVIEW_PR_BASE` to fetch the base from the PR's own
repo and diff `FETCH_HEAD HEAD`; for a local `--unpushed` run fall back to the
merge-base with the remote default branch. Note in the summary if you re-resolved.

The diff is your evidence for the central question: did this change *intend* to
alter the behavior the failing test asserts on? An intended behavior change that
the test wasn't updated for points toward `TEST_BUG`. A change that should NOT
have altered that behavior, yet did, points toward `APPLICATION_BUG`.

---

## Step 3 — Decide the Verdict (the decision procedure)

For each failing test, work through this procedure **in order** and stop at the
first verdict that fits. Be explicit in the rationale about which branch you took
and what evidence drove it. The order matters: rule out non-deterministic and
environmental causes *before* attributing the failure to the app or the test,
so you never invent a code regression to explain a timeout.

1. **Is this an environment/infrastructure failure?** Signals: connection
   refused, DNS/network error, port already in use, out-of-memory or disk on the
   runner, a missing service/dependency, a credential/secret not present in CI,
   an HTTP 5xx from a backing service the test depends on. If the failure is
   about the *substrate the test runs on* rather than the code it exercises,
   verdict = `ENVIRONMENT_ISSUE`. Recommend fixing the environment or re-running;
   do not patch app or test logic.
2. **Is this a flaky/non-deterministic failure?** Signals: the failure is
   timing- or ordering-dependent, the test uses real clocks/sleeps/animations,
   it depends on test-execution order or shared mutable state, or the same commit
   is known to pass on re-run. If the test would likely pass on an unchanged
   re-run, verdict = `FLAKY_FAILURE`. Recommend a re-run to confirm, then a
   deflaking task — **not** a code or test-logic patch.
3. **Otherwise it is a deterministic, code-or-test failure. Determine the app's
   intended behavior** for the assertion that failed. Use: the diff (what did the
   author set out to change?), the test's own intent (what contract is it
   guarding?), surrounding code, and any spec/PR-description signal.
4. **Is the app's *current* behavior correct** with respect to that intended
   behavior?
   - **Yes — the app is doing the right thing, the test is asserting the old
     thing.** Verdict = `TEST_BUG`. The test is stale, or it is a
     change-detector that is firing on an intended change. The TEST should be
     updated to match the new, correct behavior.
   - **No — the app is doing the wrong thing; the change introduced a
     regression the test correctly caught.** Verdict = `APPLICATION_BUG`. The
     CODE should be fixed; the test is doing its job.
5. **If you cannot tell** which verdict is correct from the available evidence,
   do not guess confidently. Pick the more likely verdict, set
   `confidence: low`, and say plainly in the rationale what additional signal a
   human would need (e.g., "needs product decision on whether the new copy is
   intended", or "re-run needed to rule out flakiness before calling it an
   APPLICATION_BUG").

### Tie-breakers and edge cases

- **Flaky vs. APPLICATION_BUG is the dangerous confusion.** A real regression can
  *look* intermittent (e.g., a race the change introduced). When a failure is
  plausibly flaky but you cannot be sure it isn't a real defect, prefer
  `FLAKY_FAILURE` with `confidence: low` and explicitly recommend the re-run as
  the disambiguator — never assert `APPLICATION_BUG` on a single flaky-looking
  run.
- **Deterministic-tooling failures** — a type error, lint failure, schema
  violation, or compile error masquerading as a "test failure" — are best fixed
  by the tool that owns them. Classify as `TEST_BUG` only if the test itself is
  malformed; otherwise treat a broken build step as `ENVIRONMENT_ISSUE`
  (the test never got to run) and say so in the rationale.
- **Manual/exploratory judgment calls** — "is this the *right* UX?" is a product
  decision, not a static one. If correctness genuinely needs a human to look,
  give your best verdict at `confidence: low` and name the decision the human
  must make.
- **Failures unrelated to the change under test are normal — triage them, don't
  escalate them.** When you run the whole suite (OBSERVED), you will routinely
  see failures in tests the diff never touched — pre-existing breakage, an
  earlier commit's drift, flakiness elsewhere. This is expected and is *not* a
  reason to alarm or to blame the change under test. Handle it calmly:
    - **Classify every observed failure** (discovery of pre-existing breakage is
      useful signal), but **decide the verdict against the change under test**.
      A failure in a file the diff did not touch is almost never an
      `APPLICATION_BUG` *of this change* — say so in the rationale ("pre-existing;
      the change under test does not touch this code path").
    - **Mark scope.** Set `"in_scope": true` when the failing test or the code it
      exercises is part of the diff, `false` when it is pre-existing/unrelated.
      The headline verdict is about the in-scope failures; out-of-scope ones are
      reported as discovery, clearly labeled, never conflated with the change.
    - Never invent a regression to "explain" an unrelated failure, and never let
      unrelated failures flip your read of an otherwise-clean change.

When in doubt, prefer `confidence: low` and an honest rationale over a confident
wrong call. A low-confidence-but-correct triage is useful; a high-confidence
wrong one trains the team to distrust the classifier.

---

## Step 4 — Tag a Failure Category

Aligned to the test + QA doc, tag each failing test with one of the following
categories. These describe the *kind* of failure, independent of the verdict —
a `behavioral-drift` failure can be any of the four verdicts.

| Category | What it means | Typical signal |
|---|---|---|
| `visual-drift` | A rendered-UI / snapshot / screenshot test failed because pixels or DOM structure changed. | Image-diff or snapshot mismatch; "X% of pixels differ"; updated component markup. |
| `behavioral-drift` | A unit/integration test failed because a function's logic, return value, or side effect changed. | Assertion on a value/branch/exception that no longer holds. |
| `e2e-form-flow-drift` | An end-to-end test driving a multi-step user flow (especially form submission flows) failed at some step. | Selector not found, step timed out, validation/redirect path changed, submit produced a different result. |
| `other` | Does not fit the above — e.g. a build/tooling failure, or an infrastructure failure with no test-kind signal. | Lint/type/compile errors, runner OOM, connection refused. |

The category is advisory metadata that helps the metrics layer slice precision
by failure type; it does not change the verdict logic. Note that `verdict` and
`category` are orthogonal: a `FLAKY_FAILURE` on a Playwright form test is
`category: e2e-form-flow-drift`; an `ENVIRONMENT_ISSUE` from a runner OOM with no
particular test-kind signal is `category: other`.

---

## Step 5 — Assign Confidence

Every classification carries a `confidence` of `high`, `medium`, or `low`:

- **high** — the diff and the failure output unambiguously point to one verdict.
  (e.g., the author intentionally changed a label string and only the
  string-assertion test broke → `TEST_BUG`, high.)
- **medium** — the evidence leans one way but a reasonable reviewer could
  disagree, or some context is missing.
- **low** — genuinely uncertain: the failure could be flaky vs. a real
  regression, or correctness needs a human/product judgment. Always pair `low`
  with an actionable rationale naming the disambiguator (usually a re-run or a
  product decision).

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
**Scope:** Change under test = diff against <base-ref> (N files changed)
**Failing tests classified:** K

---

### Classifications by file

#### `src/components/Banner.test.tsx`

- **TEST_BUG** | visual-drift | confidence: high
  `Banner › renders the announcement copy`
  The diff intentionally updates the banner copy from "Welcome" to "Welcome back".
  The app is rendering the new, correct copy; the snapshot is stale. Update the test.

#### `src/api/checkout.test.ts`

- **APPLICATION_BUG** | behavioral-drift | confidence: high
  `checkout › applies the loyalty discount`
  The diff refactored `applyDiscount()` and now returns the pre-discount total.
  Nothing in the change intended to remove the discount — the code regressed. Fix the code.

#### `e2e/signup.spec.ts`

- **FLAKY_FAILURE** | e2e-form-flow-drift | confidence: low
  `signup › submits the registration form`
  The submit step times out at the "Create account" button on this run only;
  nothing in the diff touches the submit handler. Likely a flaky selector/wait.
  Re-run to confirm before treating it as a regression.

#### `tests/integration/orders.test.ts`

- **ENVIRONMENT_ISSUE** | other | confidence: high
  `orders › fetches the order history`
  The test failed with "connection refused" to the orders DB on the runner. The
  backing service was unavailable; neither the app nor the test is at fault.
  Re-run once CI has the service, or fix the CI service definition.

---

### Summary
| Verdict           | Count |
|---|---|
| APPLICATION_BUG   | 1 |
| TEST_BUG          | 1 |
| FLAKY_FAILURE     | 1 |
| ENVIRONMENT_ISSUE | 1 |

**Recommendation:** CLASSIFIED — 4 failing tests triaged
(1 APPLICATION_BUG, 1 TEST_BUG, 1 FLAKY_FAILURE, 1 ENVIRONMENT_ISSUE).
The PR comment below will be posted requesting a mandatory 👍/👎 reaction.
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
  "mode": "OBSERVED",
  "summary": "Ran the suite: 4 failed / 40 passed. 1 APPLICATION_BUG, 1 TEST_BUG, 1 FLAKY_FAILURE, 1 ENVIRONMENT_ISSUE — see per-test detail.",
  "classifications": [
    {
      "test": "checkout › applies the loyalty discount",
      "path": "src/api/checkout.test.ts",
      "line": 58,
      "verdict": "APPLICATION_BUG",
      "category": "behavioral-drift",
      "confidence": "high",
      "in_scope": true,
      "rationale": "The refactor of applyDiscount() now returns the pre-discount total. Nothing in the change intended to remove the discount; the code regressed and the test correctly caught it. Fix the code; do NOT relax the test."
    },
    {
      "test": "Banner › renders the announcement copy",
      "path": "src/components/Banner.test.tsx",
      "line": 22,
      "verdict": "TEST_BUG",
      "category": "visual-drift",
      "confidence": "high",
      "in_scope": true,
      "rationale": "The diff intentionally changes the banner copy to 'Welcome back'. The app renders the new, correct copy; the snapshot assertion is stale. Update the test, not the code."
    },
    {
      "test": "signup › submits the registration form",
      "path": "e2e/signup.spec.ts",
      "line": 41,
      "verdict": "FLAKY_FAILURE",
      "category": "e2e-form-flow-drift",
      "confidence": "low",
      "in_scope": false,
      "rationale": "Submit step times out at 'Create account' on this run only; the diff does not touch the submit handler. Pre-existing/unrelated to the change. Likely a flaky selector/wait. Re-run to confirm before treating it as a regression."
    },
    {
      "test": "orders › fetches the order history",
      "path": "tests/integration/orders.test.ts",
      "line": 13,
      "verdict": "ENVIRONMENT_ISSUE",
      "category": "other",
      "confidence": "high",
      "in_scope": false,
      "rationale": "Failed with 'connection refused' to the orders DB on the runner. The backing service was unavailable; neither the app nor the test is at fault. Re-run once CI provides the service, or fix the CI service definition."
    }
  ]
}
<!-- AI_CLASSIFIER_JSON_END -->
```

**JSON schema requirements:**

- `mode` — `"OBSERVED"` if you ran the suite and triaged real failures, or
  `"INFERRED"` if you predicted from the diff (see Step 1). The dispatcher labels
  the PR comment from this field so a prediction is never mistaken for a real
  run. Omitted ⇒ treated as `"INFERRED"`.
- `summary` — ONE sentence (≤ ~200 chars). It seeds the top of the PR comment, so
  keep it a high-level headline (e.g. counts + the dominant verdict) — do NOT
  restate each per-test rationale here; the table and the per-test entries already
  carry that. In `INFERRED` mode, state *why* you couldn't run the suite.
- `classifications` — array, one entry per failing test considered. Each entry:
  - `test` — the failing test's name/id as the runner reports it.
  - `path` — repo-relative path to the test file (matches `git diff --name-only`
    conventions).
  - `line` — 1-indexed line number of the failing assertion/test in that file
    (best effort; use the test's declaration line if the assertion line is
    unknown).
  - `verdict` — one of `"APPLICATION_BUG"`, `"TEST_BUG"`, `"FLAKY_FAILURE"`,
    `"ENVIRONMENT_ISSUE"` (UPPERCASE, exactly as written — the metrics layer keys
    off these literals). There is no per-test "no-action" verdict; passing tests
    are simply omitted.
  - `category` — one of `"visual-drift"`, `"behavioral-drift"`,
    `"e2e-form-flow-drift"`, `"other"`.
  - `confidence` — one of `"high"`, `"medium"`, `"low"`.
  - `in_scope` — boolean. `true` when the failing test, or the code path it
    exercises, is part of the change under test (the diff); `false` when it is a
    pre-existing/unrelated failure surfaced by running the full suite. Out-of-scope
    failures are still classified (useful discovery) but are clearly *not* the
    change's fault — see "Failures unrelated to the change under test" in Step 3.
    Omitted ⇒ treated as `true` (assume in-scope unless stated otherwise).
  - `rationale` — ONE or at most TWO short sentences (≤ ~280 chars): the evidence
    for the verdict and the fix. Be terse — name the mismatch and what to change,
    not a narrative. For `APPLICATION_BUG`, say plainly the fix belongs in the app
    code, not the test (the guardrail against no-op test generation). For
    `FLAKY_FAILURE`, name the re-run as the disambiguator.

If nothing failed, `classifications` is empty and the run emits the `NO_ACTION`
marker. Any non-empty `classifications` array means at least one real failure
was triaged, so the run emits `CLASSIFIED`.

### 6C — PR comment body (what the dispatcher posts)

The dispatcher renders ONE comment on the PR from the JSON above. The `Scope`
column comes from each entry's `in_scope` flag — `change` for failures that are
part of the change under test, `pre-existing` for unrelated ones surfaced by the
full suite. The rendered body looks like this:

```
test-classifier: AI triage of failing tests

## AI Test Classifier — triage of failing tests

> **Observed** — these verdicts are grounded in the actual test run output.

<one-line summary>

| Verdict | Test | Confidence | Scope |
|---|---|---|---|
| APPLICATION_BUG | `checkout › applies the loyalty discount` | high | change |
| TEST_BUG | `Banner › renders the announcement copy` | high | change |
| FLAKY_FAILURE | `signup › submits the registration form` | low | pre-existing |
| ENVIRONMENT_ISSUE | `orders › fetches the order history` | high | pre-existing |

<details><summary>Per-test rationale</summary>

<per-test rationales (verdict · category — test (path:line) + one-line reason)>

</details>

**React 👍 if right / 👎 if wrong** … (on a CI / --post-comment run)
```

The **footer depends on how the comment is posted** — two tuning-signal surfaces,
both supported:

- **CI / plain `--post-comment`:** the comment ends with the **👍/👎 reaction
  ask** (and, on a 👎, a request to reply with a one-line reason). This is where
  devs interact on the PR, and the `metricsai` weekly harvest reads those
  reactions (and reply reasons) off GitHub. Posted as a review comment so it has
  a Reply thread.
- **Local `--submit`:** the ask is omitted and replaced with a plain advisory
  footer (`_Advisory, non-blocking — diagnostic only …_`), because `--submit`
  already captured the helpfulness signal via its terminal prompt and wrote it
  straight to the Testing Events sheet.

The dispatcher chooses based on whether `--submit` was passed; the skill emits
the same JSON either way.

---

## Step 7 — Result Marker

End the response with exactly one of:

```
<<<AI_REVIEW_RESULT:CLASSIFIED>>>
<<<AI_REVIEW_RESULT:NO_ACTION>>>
```

Marker contract:

- `CLASSIFIED` — at least one failing test was triaged (i.e., `classifications`
  is non-empty). All four verdicts — `APPLICATION_BUG`, `TEST_BUG`,
  `FLAKY_FAILURE`, `ENVIRONMENT_ISSUE` — are real failures and all map to
  `CLASSIFIED`.
- `NO_ACTION` — nothing failed; `classifications` is empty.

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
  of current scope. If an `APPLICATION_BUG` verdict is correct, the *value* of
  the classifier is precisely that it told a human to fix the code rather than
  silently regenerating the test to pass.
- **Be honest about uncertainty.** A `low`-confidence verdict with a clear "here
  is what I couldn't tell" is more useful than a confident guess. The 👍/👎 loop
  punishes confident wrongness.
- **Rule out flaky and environment causes first.** Do not invent an
  `APPLICATION_BUG` to explain a timeout or a connection error. Work the decision
  procedure in order: `ENVIRONMENT_ISSUE` and `FLAKY_FAILURE` are checked before
  the app-vs-test question precisely so a substrate failure never gets pinned on
  the code.
- **One classification per failing test, not per assertion.** If a single test
  has three failing assertions for one root cause, emit one classification.

---

## Data sent to the AI (privacy / data-minimization)

This skill runs in repositories that may handle PHI/PII and may be subject to
FedRAMP/FISMA constraints. Treat what you send to the AI as the smallest set
needed to reach a correct verdict — the same data-minimization posture used by
dedicated tools in this space (e.g. FixSense sends only the test name, error
message, and stack trace to its API, not the source tree).

What the classifier legitimately needs, and nothing more:

- **The failing-test signal** — test names, paths, assertion messages,
  expected-vs-actual diffs, stack traces, snapshot diffs.
- **The change-under-test diff** — `git diff "$AI_REVIEW_AGAINST" HEAD`. This is
  required: the `APPLICATION_BUG` vs `TEST_BUG` decision hinges on whether the
  change *intended* to alter the asserted behavior, and you cannot judge that
  without seeing the change. (This is the one place we send more than a
  stack-trace-only tool would — and it is deliberate, because the verdict
  quality depends on it.)

Rules:

- **Never echo secrets.** If a failure output or fixture contains a token, key,
  password, or connection string, redact it in your rationale
  (`Authorization: Bearer ***`), and treat its mere presence in a committed
  fixture as worth flagging.
- **Never reproduce PHI/PII verbatim.** If a test fixture appears to contain real
  personal/health data (names, SSNs, DOBs, member IDs, addresses), do not quote
  it in the report or the PR comment. Describe the failure abstractly and note
  that the fixture should be reviewed for synthetic-data compliance.
- **Do not pull in unrelated files.** Read only the test, the code paths the
  failure implicates, and the diff. Do not load the broader source tree, env
  files, or credential stores "for context."
- **The PR comment is public to the repo.** Everything in the rendered
  comment is visible to anyone with repo access — keep it to verdicts,
  rationales, and the 👍/👎 ask, with no sensitive values.
