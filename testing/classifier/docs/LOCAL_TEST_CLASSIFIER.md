# Local Test Classifier — Manual Function

The test classifier's recommended CI path (Path B, the reusable workflow) runs
on every PR. But you don't need an open PR to use it: a developer can classify
the failing tests on **whatever they haven't pushed yet** — committed + staged —
straight from their machine, before the code ever leaves it.

This guide sets up one shell **function** — `test-classifier` — that makes that
a one-word command from anywhere inside the repository. By default it classifies
**everything you haven't pushed yet** (all locally-committed *and* staged
changes), so it mirrors what the PR run would later see. It is the testing
counterpart to the security bundle's
[`LOCAL_SECURITY_REVIEW.md`](../../../security/review/docs/LOCAL_SECURITY_REVIEW.md)
and uses the same `--unpushed` scope rule. This is the ergonomics layer over
[`SETUP.md`](./SETUP.md) **Path A** (the local dispatcher run).

---

## Why a local run?

- **No PR required.** The `--unpushed` mode resolves the diff base itself (your
  branch's upstream, falling back to the merge-base with the remote default
  branch), so you get a classification on a branch that has no open PR yet —
  while you're still iterating.
- **It's a local preview, not the gate.** The PR run (Path B) is the recorded
  backstop that feeds the metrics loop. The local run is for the developer's own
  fast feedback before pushing; it never blocks anything. By default it's
  **report-only** (prints to your terminal, posts nothing) — but you can opt in
  to posting against a real PR with `--pr N --post-comment` (see Usage).
- **OBSERVED on demand.** By default a local run is INFERRED (it predicts from
  the diff — read-only, never touches your machine's toolchain). Opt into
  OBSERVED with `AI_RUN_SUITE=1` to have the agent actually locate, install, and
  run your suite and triage the real failures — the same behavior CI uses.

> [!WARNING]
> **OBSERVED (`AI_RUN_SUITE=1`) runs the change's code on your machine — there
> is no sandbox.** The agent installs dependencies (running each package's
> install/postinstall scripts) and executes the test suite **directly in your
> checkout**, with your shell, your environment, and your credentials. It also
> leaves build artifacts behind (`node_modules/`, downloaded browsers, etc.).
>
> Only use `AI_RUN_SUITE=1` on a branch **you trust** — typically your own
> work-in-progress. Do **not** point it at an untrusted or unreviewed PR
> (e.g. `--pr N` for someone else's contribution): installing and running that
> branch's code is arbitrary code execution on your laptop. For untrusted
> changes, use the default **INFERRED** mode (omit `AI_RUN_SUITE`), which only
> reasons over the diff and never executes anything, or let CI run OBSERVED in
> its disposable runner.

---

## Prerequisites

1. **The classifier bundle's scripts are present** under `testing/classifier/`
   in your repo. The source repo is public, so one command vendors just that
   subtree (no auth) — run it from your repo root:
   ```bash
   curl -fsSL https://codeload.github.com/navapbc/ai-transformation-delivery-systems/tar.gz/refs/tags/pilot \
     | tar -xz --strip-components=1 '*/testing/classifier'
   ```
   See [`SETUP.md`](./SETUP.md) Path A → "Step 0 — Install the bundle" for the
   pinned-SHA and sparse-checkout variants.
2. **`AI_REVIEW_TOOL` set** to `claude`, `codex`, or `copilot` — see the
   `README.md`, section "AI tool selection". The dispatcher exits with a helpful
   message if it's unset.
3. **The matching AI CLI installed** (`claude`, `codex`, or `copilot`).
4. **`zsh`** (this snippet is zsh; adapt for bash if needed).

`gh` is **not** required for `--unpushed` (there's no PR to discover or post to);
it's only needed for the PR-based modes (`--pr` / auto-discovery / `--post-comment`).

---

## Add the function to `~/.zshrc`

Paste this block into `~/.zshrc`, then `source ~/.zshrc` (or open a new shell):

```zsh
# AI test classifier. Run `test-classifier --help` for usage.
test-classifier() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "✗ not inside a git repository"; return 1; }
  "$root/testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh" "$@"
}
```

The function is a thin passthrough: it finds the repo root and forwards every
argument to the dispatcher. **All argument handling lives in the dispatcher**
(versioned with the bundle), so the function never goes stale when you re-vendor.
It forwards args verbatim, and the dispatcher applies these defaults:

- **no argument** → `--unpushed`: everything not yet pushed (committed +
  staged). The base is your branch's upstream, falling back to the merge-base
  with the remote default branch. If neither can be determined (e.g. a
  brand-new branch with no remote), it errors and asks for an explicit ref
  rather than silently classifying less than you expect.
- **a bare ref** (e.g. `test-classifier origin/main`) → `--against <ref>`: the
  committed range `<ref>..HEAD`.
- **any flags** → used directly. This is how you post to a PR —
  `test-classifier --pr 42 --post-comment` (or just `--post-comment` to
  auto-discover the current branch's PR), plus any other dispatcher flag
  (`--dry-run`, `--json-only`, …). You can combine a ref with flags too:
  `test-classifier origin/main --post-comment`.

Prefix `AI_RUN_SUITE=1` to run the suite locally (OBSERVED) instead of inferring
from the diff: `AI_RUN_SUITE=1 test-classifier`.

---

## Usage

```bash
test-classifier                       # everything unpushed: committed + staged (INFERRED)
test-classifier origin/main           # the committed range origin/main..HEAD
test-classifier HEAD~1                # just the last commit

AI_RUN_SUITE=1 test-classifier        # run the suite locally and triage REAL failures (OBSERVED)

# Post the result as a PR comment (needs an open PR + gh authed):
test-classifier --post-comment              # auto-discovers the current branch's PR
test-classifier --pr 42 --post-comment      # explicit PR number
AI_RUN_SUITE=1 test-classifier --pr 42 --post-comment   # OBSERVED + post

# Streamlined: post AND record the metric in one shot (see --submit below):
test-classifier --pr 42 --submit
```

> **Posting authorship.** A locally-posted comment is authored by **you**, not
> `github-actions[bot]`. For the comment to be picked up by the weekly metrics
> harvest, `metricsai` must be told to count your author (`--all-authors` or
> `METRICSAI_TESTING_GITHUB_AUTHORS`); by default it only counts the CI bot. For
> just *posting to the PR*, this doesn't matter.

---

## `--submit` — classify, post, and record the metric in one shot

The slow path to metrics is: post a comment → react 👍/👎 on GitHub later → wait
for the weekly harvest. `--submit` collapses that into the run you're already
doing. After classifying and posting, it prompts right in the terminal:

```
  Was the classification helpful? [y/n] (enter to skip):
```

Your answer is appended **immediately** as one row to the Sheet's **Testing
Events** tab — verdict, file context, confidence, and your 👍/👎 (with an optional
one-line reason on a 👎). No GitHub round-trip, no separate harvest.

```bash
test-classifier --pr 42 --submit                 # classify (INFERRED) → post → ask → record
AI_RUN_SUITE=1 test-classifier --pr 42 --submit  # OBSERVED → post → ask → record
test-classifier --submit                         # auto-discovers the current branch's PR
```

**Requirements:** everything `--post-comment` needs (open PR + `gh` authed),
**plus** the metricsai webhook creds — two static values, set once in `~/.zshrc`:

```bash
export METRICSAI_WEBHOOK_URL="https://script.google.com/macros/s/<id>/exec"
export METRICSAI_WEBHOOK_KEY="<the AI Metrics API key>"
```

That's the whole setup. `--submit` POSTs the row to the same Google Apps Script
webhook `metricsai` uses (flat JSON body; the script aligns fields to the sheet
by header name, so column order never matters). **No gcloud, no service account,
no token to refresh** — both values are permanent.

The row lands in the **Testing Events** tab by default; override with
`METRICSAI_WEBHOOK_TAB`.

**Behavior notes:**
- **Interactive only.** In CI or any non-TTY run, `--submit` posts the comment
  and **skips** the prompt + row (no human to ask, no hang). CI metrics still
  come from the central weekly harvest.
- **No creds → no crash.** If `METRICSAI_WEBHOOK_URL` / `METRICSAI_WEBHOOK_KEY`
  aren't set, it records your answer to the terminal, warns, and **still posts**
  the comment.
- **Writes to Testing Events, not the weekly tabs.** These are per-event rows
  (one per run), distinct from the `metricsai` weekly aggregate rows in the
  CXT / DMOD / EMMY / OSRE tabs. The central sweep writes to the same tab — two
  writers, one tab, deduped by `comment_id`.
- **Pressing enter skips** the row entirely — no verdict is guessed.

**Scope details.**

- `--unpushed` (the default) classifies **committed + staged** changes — it
  **excludes unstaged working-tree edits**. Commit or `git add` work-in-progress
  to include it.
- A local run is **report-only**: it prints the classification to the terminal
  and never posts a PR comment. Posting (with the mandatory 👍/👎 ask that feeds
  the metrics loop) happens on the PR run — Path B, or `--post-comment` against a
  real PR. See [`SETUP.md`](./SETUP.md).
- **The actionable summary.** After the full report, the dispatcher prints a
  compact, colored summary — one line per failing test with its verdict,
  `file:line`, confidence, and the one-line *what to do* (`→ Fix the TEST`,
  `→ Fix the CODE`, `→ Re-run / deflake`, `→ Fix the ENV`). That's the punchline:
  the classifier is **diagnostic** — it tells you which side to fix, never writes
  the patch. Read the summary, then make the change yourself.
- **INFERRED vs OBSERVED.** Without `AI_RUN_SUITE=1` the agent predicts failures
  from the diff (INFERRED) and never touches your toolchain. With it, the agent
  runs your suite (OBSERVED) — the only mode in which `FLAKY_FAILURE` /
  `ENVIRONMENT_ISSUE` are reliably reachable, since you can't see a timeout or
  non-determinism from a diff.
- **Live progress.** On a local interactive run the dispatcher streams the
  agent's steps (each `⏺` reasoning line and `⏎` tool call) to your terminal as
  they happen, so it isn't a blinking cursor while it works. The final report is
  unchanged. To silence the step stream (just wait for the report), set
  `AI_REVIEW_STREAM=0`. In CI the run is always silent until it finishes.

---

## When to run

Run it before pushing when you want a fast read on a failing or risky test
change — to catch an `APPLICATION_BUG` vs a `TEST_BUG` while you can still fix it
locally, or to sanity-check that a flaky-looking failure really is flaky. The PR
run (Path B) is still the recorded, metrics-feeding pass; this is your preview.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `✗ not inside a git repository` | You're not in a git work tree. `cd` into the repo. |
| `no such file or directory` / `permission denied` on the dispatcher path | The bundle isn't installed under `testing/classifier/`, or the script lost its `+x` bit. Re-install / `chmod +x`. |
| `--unpushed: couldn't determine what's been pushed` | No upstream and no remote default branch (e.g. brand-new branch, no remote). Pass an explicit base: `test-classifier origin/main`. |
| `AI_REVIEW_TOOL … not set` | Export `AI_REVIEW_TOOL=claude` (or `codex`/`copilot`); see `README.md`. |
| Classification seems to miss recent edits | `--unpushed` excludes *unstaged* changes. `git add` or commit them first. |
| Everything lands in INFERRED | That's the default. Add `AI_RUN_SUITE=1` to run the suite (OBSERVED). Suites needing services may still fall back to INFERRED, by design. |
| Posted to / recorded the wrong repo (e.g. the upstream of your fork) | The repo is resolved from your `origin` remote. On a fork whose `origin` isn't the repo the PR lives in, export `AI_REVIEW_REPO=owner/name` to set it explicitly. |

---

## Related

- [`SETUP.md`](./SETUP.md) — all paths (A reusable workflow, B local dispatcher,
  C vendored, D Jenkins), the full flag reference, and metrics-sink config.
- [`PLAYBOOK.md`](./PLAYBOOK.md) — the four-verdict framing.
- [`../../../security/review/docs/LOCAL_SECURITY_REVIEW.md`](../../../security/review/docs/LOCAL_SECURITY_REVIEW.md)
  — the security bundle's parallel local-run guide.
