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
      tool: claude          # claude | codex — see "Choose your AI tool" below
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
```

Do not run a YAML linter. If you want a sanity check, `cat` the file and confirm
the first line is `name: AI test classifier` and the `uses:` line is a single
unbroken line with one `@`. Then move on.

### Choose your AI tool (claude | codex)

The classifier can run on either AI CLI. Both produce the same PR comment and the
same uploaded trace artifact — pick by which API key the team already has.

| `tool:` | API key secret to set (Step 2) | Trace artifact captured |
|---------|--------------------------------|--------------------------|
| `claude` (default) | `ANTHROPIC_API_KEY` | full raw request/response bodies (`agent-bodies/`) |
| `codex`  | `OPENAI_API_KEY` | OTel traces + logs JSONL (`codex-otel/`) |

To use Codex instead of Claude, change the one line `tool: claude` to
`tool: codex` and set `OPENAI_API_KEY` instead of `ANTHROPIC_API_KEY` in Step 2.
You only need the secret matching your choice — leaving the other unset is fine
(it resolves to empty and is ignored). Everything else is identical.

### Choose your provider (anthropic | bedrock)

By default the classifier calls the **direct Anthropic / OpenAI API** with the
API key from Step 2 (`provider: anthropic`). If the team wants inference to run
in **their own AWS account via Amazon Bedrock** instead — e.g. a CMS-internal
repo where no code may leave the AWS boundary — use `provider: bedrock`.

The caller file you just wrote already contains the Bedrock block, **commented
out**. To switch to Bedrock you UNCOMMENT and fill those lines (do not retype the
file). Edit `.github/workflows/ai-test-classifier.yml` so the `with:` block reads:

```yaml
    with:
      tool: claude                 # claude (Claude models) | codex (OpenAI GPT-5.x). NOT copilot.
      provider: bedrock
      aws-region: us-east-1        # a region where your account has Anthropic model access
      aws-auth: oidc               # oidc (recommended, role ARN below) | static (bearer-token secret)
      aws-role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/ai-test-classifier   # oidc only
      # bedrock-model: us.anthropic.claude-sonnet-4-6   # optional; codex → openai.gpt-5.5
```

Key facts to get this right (do NOT skip):

- **`id-token: write` is already in the caller's `permissions:` block** — leave it.
  OIDC fails without it, and the reusable workflow cannot grant it for you.
- **On Bedrock, leave the API-key secret UNSET.** A non-empty `ANTHROPIC_API_KEY`
  makes the CLI call the direct API and silently ignore Bedrock. (The reusable
  workflow blanks it on the bedrock path, but don't rely on that — just don't set it.)
- **`aws-auth: oidc`** (recommended) needs `aws-role-to-assume` and no stored AWS
  secret. **`aws-auth: static`** instead needs the `AWS_BEARER_TOKEN_BEDROCK`
  secret (Step 2) and no role — simpler 2-step setup, weaker posture.
- **`bedrock` works with `tool: claude` or `tool: codex`, never `copilot`.** Note
  Codex on Bedrock runs OpenAI models, not Claude.

The one-time AWS-account setup (enable model access, create the OIDC provider +
IAM role, or mint the bearer token) is **out-of-band and you cannot do it** — it
lives in `testing/classifier/docs/BEDROCK.md`. Tell the human to follow that doc;
see Step 2.

## Step 2 — tell the human these two manual steps (you cannot do them)

Print this to the user verbatim — these are out-of-band and block the run:

1. **Add the API key secret** (consumer repo) for the `tool:` you chose:

   - **claude** (default) — paste the key from
     <https://console.anthropic.com/settings/keys> when prompted:
     ```
     gh secret set ANTHROPIC_API_KEY -R <owner>/<consumer-repo>
     ```
   - **codex** — paste the key from
     <https://platform.openai.com/api-keys> when prompted:
     ```
     gh secret set OPENAI_API_KEY -R <owner>/<consumer-repo>
     ```

   (Replace `<owner>/<consumer-repo>` with this repo's slug from `gh repo view`.
   Set only the one matching your `tool:` choice.)

   **If you set `provider: bedrock` instead:** do NOT set the API-key secret
   above. The human's manual work is the one-time AWS setup in
   `testing/classifier/docs/BEDROCK.md` — print this to them verbatim:

   - **bedrock + `aws-auth: oidc`** (recommended): in the AWS account, (1) enable
     Anthropic model access in the Bedrock console, (2) create a GitHub OIDC
     identity provider, (3) create the IAM role named in `aws-role-to-assume`
     with a trust policy pinned to `repo:<owner>/<consumer-repo>:*` and a
     permissions policy allowing `bedrock:InvokeModel*`. No repo secret needed.
   - **bedrock + `aws-auth: static`**: mint a Bedrock API key and set it:
     ```
     gh secret set AWS_BEARER_TOKEN_BEDROCK -R <owner>/<consumer-repo>
     ```
   Full copy-pasteable IAM policies and steps are in
   `testing/classifier/docs/BEDROCK.md` at the `@pilot` tag.

That is the only manual step. (The source repo is public, so no org-access
setting is needed.)

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
at the `@pilot` tag. For the Amazon Bedrock path (one-time AWS account setup, IAM
trust + permissions policies, OIDC vs static auth): `testing/classifier/docs/BEDROCK.md`.
Fetch repo files with (quote the URL — the `?` is a shell glob):
`curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/<path>`
