# AI Test Classifier — Agent Install (Path A, reusable workflow)

> For AI coding agents. This is the whole task. Do not read SETUP.md (498 lines)
> unless something below fails. Do not vendor or copy any files.

## What you are doing

Add ONE workflow file to the **current (consumer) repo** that calls the
classifier's reusable workflow by pinned SHA. No scripts are copied in.

## Step 1 — fetch the ready-made caller file and write its bytes

**Do not hand-type the YAML** (transcription corrupts the `name:`/`on:`/`uses:`
lines). Instead, fetch the bundle's ready-made caller file — already pinned to
the `@pilot` tag — and write its exact bytes to the consumer repo. One command:

```
mkdir -p .github/workflows && \
curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/testing/classifier/caller-workflow.yml \
  -o .github/workflows/ai-test-classifier.yml
```

That writes `.github/workflows/ai-test-classifier.yml` verbatim — no retyping,
nothing to scramble. For reference, the file you just wrote should be exactly:

```yaml
name: AI test classifier
on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs:
  classify:
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@pilot
    with:
      tool: claude
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Do not run a YAML linter. If you want a sanity check, `cat` the file and confirm
the first line is `name: AI test classifier` and the `uses:` line is a single
unbroken line with one `@`. Then move on.

## Step 2 — tell the human this manual step (you cannot do it)

Print this to the user verbatim — it is out-of-band and blocks the run:

1. **Add the API key secret** (consumer repo): run, then paste the key from
   <https://console.anthropic.com/settings/keys> when prompted:
   ```
   gh secret set ANTHROPIC_API_KEY -R <owner>/<consumer-repo>
   ```
   (Replace `<owner>/<consumer-repo>` with this repo's slug from `gh repo view`.)

That is the only manual step. **Do nothing for metrics** — the pilot's central
sweep reads this repo's classifier comments from the maintainer's side; no token
or secret is set up here. (The source repo is public, so no org-access setting is
needed for the classifier workflow itself.)

## Step 3 — set expectations, then stop

- On each PR, the classifier triages the failing tests and posts **one PR
  comment** with the verdicts + a mandatory 👍/👎 ask. It is non-blocking, and the
  full report is also uploaded as an `ai-test-classification` CI artifact. The
  success signal is a green Actions run that posts that one triage comment.
- **The classifier runs your test suite itself.** Inside the CI run the agent
  locates this repo's test command (package.json / Makefile / pytest / go /
  cargo / your CI's test step), installs deps best-effort, and runs the suite,
  then triages the real failures it observed — the comment is marked
  **Observed**. No extra setup and no separate test job is required.
- **If it can't run the suite** (no test command, a toolchain it can't install on
  the stock runner, the suite needs services like a database, or it times out),
  it falls back to predicting from the diff and marks the comment **Inferred,
  not observed**, stating why in the summary. That is expected, not a failure.
- If nothing failed (or the diff implicates no test), it posts nothing
  (`NO_ACTION`).
- Do NOT enable gating. Gating (`--gate`) is a separate opt-in, out of scope
  for this install.
- Nothing triggers until a PR exists. Offer to commit the file on a branch and
  open a PR.

## If you need to read more

Full guide (humans, or when the above fails): `testing/classifier/docs/SETUP.md`
at the `@pilot` tag. Fetch repo files with (quote the URL — the `?` is a shell glob):
`curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/<path>`
