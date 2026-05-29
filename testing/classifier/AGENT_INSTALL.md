# AI Test Classifier — Agent Install (Path A, reusable workflow)

> For AI coding agents. This is the whole task. Do not read SETUP.md (498 lines)
> unless something below fails. Do not vendor or copy any files.

## What you are doing

Add ONE workflow file to the **current (consumer) repo** that calls the
classifier's reusable workflow by pinned SHA. No scripts are copied in.

## Step 1 — fetch the ready-made caller file and write its bytes

**Do not hand-type the YAML** (transcription corrupts the `name:`/`on:`/`uses:`
lines). Instead, fetch the bundle's ready-made caller file — already pinned to
the correct SHA — and write its exact bytes to the consumer repo. One command:

```
mkdir -p .github/workflows && \
curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/test-classifier-v0/testing/classifier/caller-workflow.yml \
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
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@test-classifier-v0
    with:
      tool: claude
      mode: p0
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Do not run a YAML linter. If you want a sanity check, `cat` the file and confirm
the first line is `name: AI test classifier` and the `uses:` line is a single
unbroken line with one `@`. Then move on.

## Step 2 — tell the human these two manual steps (you cannot do them)

Print this to the user verbatim — these are out-of-band and block the run:

1. **Add the API key secret** (consumer repo): run, then paste the key from
   <https://console.anthropic.com/settings/keys> when prompted:
   ```
   gh secret set ANTHROPIC_API_KEY -R <owner>/<consumer-repo>
   ```
   (Replace `<owner>/<consumer-repo>` with this repo's slug from `gh repo view`.)
2. **One-time org access** (an admin does once, on the SOURCE repo
   `navapbc/ai-transformation-delivery-systems`): Settings → Actions → General →
   Access → "Accessible from repositories in the 'navapbc' organization."
   Without this, the `uses:` line 404s at runtime.

## Step 3 — set expectations, then stop

- `mode: p0` is observe-only: it records a `ai-test-classification` artifact on
  the PR's Actions run and **posts no comment**. That is correct. The success
  signal is a green Actions run + a downloadable artifact, not a PR comment.
- Do NOT enable `mode: p1` or gating. The human flips `mode: p0` → `mode: p1`
  later, after P0 looks trustworthy.
- Nothing triggers until a PR exists. Offer to commit the file on a branch and
  open a PR.

## If you need to read more

Full guide (humans, or when the above fails): `testing/classifier/docs/SETUP.md`
at the same SHA. Fetch repo files with (quote the URL — the `?` is a shell glob):
`curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/test-classifier-v0/<path>`
