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
  fast feedback before pushing; it is **report-only** — it never posts a PR
  comment (there's no PR to post to) and never blocks anything.
- **OBSERVED on demand.** By default a local run is INFERRED (it predicts from
  the diff — read-only, never touches your machine's toolchain). Opt into
  OBSERVED with `AI_RUN_SUITE=1` to have the agent actually locate, install, and
  run your suite and triage the real failures — the same behavior CI uses.

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
# AI test classifier — local, report-only.
#   <no arg>  → classify everything not yet pushed (committed + staged)
#   <ref>     → classify the committed range <ref>..HEAD
# Prefix with AI_RUN_SUITE=1 to run the suite locally (OBSERVED) instead of
# inferring from the diff:  AI_RUN_SUITE=1 test-classifier
test-classifier() {
  local root disp
  root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "✗ not inside a git repository"; return 1; }
  disp="$root/testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh"
  [ -x "$disp" ] \
    || { echo "✗ test-classifier dispatcher not found/executable: $disp"; return 1; }
  if [ -n "$1" ]; then
    echo "▶ test-classifier: ${1}..HEAD (committed range)"
    "$disp" --against "$1"
  else
    echo "▶ test-classifier: all not-yet-pushed changes (committed + staged)"
    "$disp" --unpushed
  fi
}
```

What the function does:

1. **Confirms you're in a git repo** — `git rev-parse --show-toplevel` doubles as
   the repo check (empty → not a repo) and gives the authoritative root, so the
   function works from any subdirectory.
2. **Locates the dispatcher** under `testing/classifier/` and confirms it's
   executable.
3. **Runs the classifier** by calling the dispatcher directly:
   - **no argument** → `--unpushed`: everything not yet pushed (committed +
     staged). The base is your branch's upstream, falling back to the merge-base
     with the remote default branch. If neither can be determined (e.g. a
     brand-new branch with no remote), it errors and asks for an explicit ref
     rather than silently classifying less than you expect.
   - **a ref** → `--against <ref>`: the committed range `<ref>..HEAD`.

---

## Usage

```bash
test-classifier                       # everything unpushed: committed + staged (INFERRED)
test-classifier origin/main           # the committed range origin/main..HEAD
test-classifier HEAD~1                # just the last commit

AI_RUN_SUITE=1 test-classifier        # run the suite locally and triage REAL failures (OBSERVED)
```

**Scope details.**

- `--unpushed` (the default) classifies **committed + staged** changes — it
  **excludes unstaged working-tree edits**. Commit or `git add` work-in-progress
  to include it.
- A local run is **report-only**: it prints the classification to the terminal
  and never posts a PR comment. Posting (with the mandatory 👍/👎 ask that feeds
  the metrics loop) happens on the PR run — Path B, or `--post-comment` against a
  real PR. See [`SETUP.md`](./SETUP.md).
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
| `✗ test-classifier dispatcher not found/executable` | The bundle isn't installed under `testing/classifier/`, or the script lost its `+x` bit. Re-install / `chmod +x`. |
| `--unpushed: couldn't determine what's been pushed` | No upstream and no remote default branch (e.g. brand-new branch, no remote). Pass an explicit base: `test-classifier origin/main`. |
| `AI_REVIEW_TOOL … not set` | Export `AI_REVIEW_TOOL=claude` (or `codex`/`copilot`); see `README.md`. |
| Classification seems to miss recent edits | `--unpushed` excludes *unstaged* changes. `git add` or commit them first. |
| Everything lands in INFERRED | That's the default. Add `AI_RUN_SUITE=1` to run the suite (OBSERVED). Suites needing services may still fall back to INFERRED, by design. |

---

## Related

- [`SETUP.md`](./SETUP.md) — all paths (A reusable workflow, B local dispatcher,
  C vendored, D Jenkins), the full flag reference, and metrics-sink config.
- [`PLAYBOOK.md`](./PLAYBOOK.md) — the four-verdict framing.
- [`../../../security/review/docs/LOCAL_SECURITY_REVIEW.md`](../../../security/review/docs/LOCAL_SECURITY_REVIEW.md)
  — the security bundle's parallel local-run guide.
