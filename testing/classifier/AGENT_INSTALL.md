# AI Test Classifier — Agent Install (Path A, reusable workflow)

> For AI coding agents. This is the whole task. Do not read SETUP.md (full guide)
> unless something below fails. Do not vendor or copy any files.

## What you are doing

Add ONE workflow file to the **current (consumer) repo** that calls the
classifier's reusable workflow by pinned SHA. No scripts are copied in.

The classifier runs **after** the repo's test workflow finishes (`workflow_run`)
so it can read the REAL test results. Your job includes wiring it to the **right**
test workflow.

## Step 1 — fetch the ready-made caller file and write its bytes

**Do not hand-type the YAML** (transcription corrupts the `on:`/`uses:` lines).
Fetch the bundle's ready-made caller file — already pinned to the `@pilot` tag —
and write its exact bytes to the consumer repo. One command:

```
mkdir -p .github/workflows && \
curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/testing/classifier/caller-workflow.yml \
  -o .github/workflows/ai-test-classifier.yml
```

## Step 2 — point it at THIS repo's test workflow (REQUIRED — do not skip)

`workflow_run` matches the test workflow by its **`name:`** field, not filename.
The fetched file defaults to `"Test"`/`"CI"`/`"Tests"`; confirm one matches or
fix it, else the classifier silently never runs.

1. **Find the repo's test workflow and read its `name:`:**

   ```
   for f in .github/workflows/*.yml .github/workflows/*.yaml; do
     [ -e "$f" ] || continue
     echo "== $f =="; grep -nE '^name:|run:.*(pytest|go test|vitest|jest|npm (run )?test|pnpm (run )?test|yarn test|cargo test|rspec|mvn test|gradle test|tox|phpunit)' "$f"
   done
   ```

2. **Put that exact name in the caller's `workflows:` list** (leave it if a
   default already matches), and say which you set in your summary:

   ```yaml
   on:
     workflow_run:
       workflows: ["Build and Test"]   # ← this repo's test workflow name
       types: [completed]
   ```

3. **(Optional) results artifact for OBSERVED verdicts.** For real (not diff-only)
   verdicts, have the test job upload its JUnit XML / log via
   `actions/upload-artifact@v4` named `ai-test-results`. Without it the classifier
   runs in INFERRED mode and labels its comment.

**No test workflow at all?** `workflow_run` has nothing to attach to — add a test
workflow first, or fall back to a `pull_request:` trigger (INFERRED-only).

## Step 3 — tell the human the one manual step (you cannot do it)

Print this to the user verbatim — it is out-of-band and blocks the run:

1. **Add the API key secret** (consumer repo): run, then paste the key from
   <https://console.anthropic.com/settings/keys> when prompted:
   ```
   gh secret set ANTHROPIC_API_KEY -R <owner>/<consumer-repo>
   ```
   (Replace `<owner>/<consumer-repo>` with this repo's slug from `gh repo view`.)

Also warn them about the activation rule below.

(The source repo is public, so no org-access setting is needed.)

## Step 4 — set expectations, then stop

- **Must be on the default branch to activate.** GitHub reads `workflow_run`
  triggers from the default branch only — it won't fire from a feature branch.
  This is the #1 "why didn't it run" cause; tell the user.
- After the test workflow finishes on a PR, the classifier posts **one
  non-blocking PR comment** with the verdicts + a 👍/👎 ask (also uploaded as the
  `ai-test-classification` artifact).
- **OBSERVED vs INFERRED.** With an `ai-test-results` artifact, verdicts are
  grounded in the real run ("Observed"); without one, predicted from the diff
  ("Inferred, not observed") — the only mode where flaky/environment verdicts are
  reliable is OBSERVED.
- A push-triggered test run (no PR) skips cleanly. Don't enable gating
  (`--gate`) — out of scope. Offer to commit on a branch and open a PR.

## If you need to read more

Full guide (humans, or when the above fails): `testing/classifier/docs/SETUP.md`
at the `@pilot` tag. Fetch repo files with (quote the URL — the `?` is a shell glob):
`curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/<path>`
