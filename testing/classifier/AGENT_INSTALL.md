# AI Test Classifier — Agent Install (Path A, reusable workflow)

> For AI coding agents. This is the whole task. Do not read SETUP.md (498 lines)
> unless something below fails. Do not vendor or copy any files.

## What you are doing

Add ONE workflow file to the **current (consumer) repo** that calls the
classifier's reusable workflow by pinned SHA. No scripts are copied in.

## Step 1 — write this file VERBATIM

Create `.github/workflows/ai-test-classifier.yml` in the consumer repo with
**exactly** this content. Do not rewrite, reformat, or substitute the SHA — copy
it character-for-character (the `uses:` line is one unbroken string):

```yaml
name: AI test classifier
on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs:
  classify:
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@__PIN_SHA__
    with:
      tool: claude
      mode: p0
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

After writing it, verify it parses: `yamllint` or
`python3 -c "import yaml,sys;yaml.safe_load(open('.github/workflows/ai-test-classifier.yml'))"`.
The `uses:` value must be a single line with exactly one `@` and no stray spaces
or colons. If it looks scrambled, rewrite it.

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
`gh api "repos/navapbc/ai-transformation-delivery-systems/contents/<path>?ref=__PIN_SHA__" --jq .content | base64 -d`
