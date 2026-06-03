# AI Test Classifier — Agent Install (Path A, reusable workflow)

> For AI coding agents. This is the whole task. Do not read SETUP.md (full guide)
> unless something below fails. Do not vendor or copy any files.

## What you are doing

Add ONE workflow file to the **current (consumer) repo** that calls the
classifier's reusable workflow by pinned SHA. No scripts are copied in.

The classifier runs **after** the repo's test workflow finishes (a
`workflow_run` trigger) so it can read the repo's REAL test results — that is the
mode in which its verdicts are grounded in an actual run rather than guessed from
the diff. Your job includes wiring it to the **right** test workflow.

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

The caller fires on completion of the repo's test workflow, identified by that
workflow's **`name:`** field. The fetched file lists conventional defaults
(`"Test"`, `"CI"`, `"Tests"`). You must confirm one of those is correct, or fix
it — otherwise the classifier silently never runs.

1. **Find the repo's test workflow and read its `name:`.** Inspect the existing
   workflows and identify the one that runs the test suite (it invokes the
   project's test command — e.g. `pytest`, `go test`, `vitest`/`jest`,
   `npm/pnpm test`, `cargo test`, `rspec`, `mvn test`, etc.):

   ```
   for f in .github/workflows/*.yml .github/workflows/*.yaml; do
     [ -e "$f" ] || continue
     echo "== $f =="; grep -nE '^name:|run:.*(pytest|go test|vitest|jest|npm (run )?test|pnpm (run )?test|yarn test|cargo test|rspec|mvn test|gradle test|tox|phpunit)' "$f"
   done
   ```

   The `name:` value of the matching file (NOT its filename) is the test
   workflow name. Example: a file `.github/workflows/ci.yml` whose first line is
   `name: Build and Test` has the workflow name `Build and Test`.

2. **Make the caller's `workflows:` list contain that exact name.** Edit
   `.github/workflows/ai-test-classifier.yml` so the `workflow_run.workflows`
   array is your repo's test workflow name. If the repo's name already matches
   one of the defaults (`Test`/`CI`/`Tests`), leave it; otherwise replace the
   list, e.g.:

   ```yaml
   on:
     workflow_run:
       workflows: ["Build and Test"]   # ← this repo's actual test workflow name
       types: [completed]
   ```

   State plainly in your summary which workflow name you set and why.

3. **(Optional but recommended) results artifact for OBSERVED verdicts.** The
   classifier reads real test output when the test workflow uploads it as an
   artifact named `ai-test-results` (the `test-results-artifact` input). If the
   repo's test job does not already upload one, you may add an
   `actions/upload-artifact@v4` step to it that uploads its JUnit XML / log under
   that name. If you do not, the classifier still runs but in INFERRED
   (diff-only) mode and labels its comment accordingly.

If this repo has **no** test workflow at all, say so: the `workflow_run` trigger
has nothing to attach to. Either help the user add a test workflow first, or fall
back to a `pull_request:` trigger (INFERRED-only) and tell them the classifier
will guess from the diff until a real test workflow exists.

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

- **It must be merged to the default branch to activate.** GitHub reads
  `workflow_run` triggers from the workflow file on the repo's DEFAULT branch.
  The classifier will NOT fire from a feature branch — the caller has to land on
  the default branch first. Tell the user this; it is the #1 "why didn't it run"
  cause.
- On a PR, after the test workflow finishes, the classifier triages each failing
  test and posts **one PR comment** with the verdicts + a mandatory 👍/👎 ask. It
  is non-blocking, and the full report is also uploaded as an
  `ai-test-classification` CI artifact.
- **OBSERVED vs INFERRED.** If the test workflow uploaded an `ai-test-results`
  artifact, verdicts are grounded in the real run (comment marked "Observed"). If
  not, the classifier predicts from the diff (comment marked "Inferred, not
  observed"). Both are valid; OBSERVED is stronger and is the only mode where
  flaky/environment verdicts are reliable.
- If a test run was for a push (not a PR), the classifier cleanly skips — there
  is no PR to comment on. That is expected, not a failure.
- Do NOT enable gating. Gating (`--gate`) is a separate opt-in, out of scope for
  this install.
- Nothing triggers until (a) the caller is on the default branch and (b) a PR's
  test workflow completes. Offer to commit the file on a branch and open a PR
  toward the default branch.

## If you need to read more

Full guide (humans, or when the above fails): `testing/classifier/docs/SETUP.md`
at the `@pilot` tag. Fetch repo files with (quote the URL — the `?` is a shell glob):
`curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/<path>`
