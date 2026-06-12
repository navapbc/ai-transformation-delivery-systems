# AI Test Classifier — Agent Install

> For AI coding agents. This is the whole task. Do not read SETUP.md (498 lines)
> unless something below fails. **Default path: GitHub Actions** (reusable
> workflow, no files vendored). Jenkins is a documented alternative — see
> "Choose your CI platform" below. Do not vendor or copy files on the Actions path.

## What you are doing

Add ONE workflow file to the **current (consumer) repo** that calls the
classifier's reusable workflow by pinned SHA. No scripts are copied in. (This is
the **GitHub Actions** path — the default. If the repo runs Jenkins, see the CI
choice immediately below.)

## Choose your CI platform (GitHub Actions | Jenkins)

The classifier core is CI-agnostic; only the wiring differs. **Default to
GitHub Actions** — it's the simple reusable-workflow path in this doc. Switch to
Jenkins only when the repo's CI is Jenkins (e.g. a client that can't use
Actions). If you don't know which the repo uses, **ask the human** before
writing any files — don't write a `.github/workflows/` file into a Jenkins repo.

| CI | What gets added to the consumer repo | Full instructions |
|----|--------------------------------------|-------------------|
| **GitHub Actions** (default) | one caller workflow at `.github/workflows/ai-test-classifier.yml` (reusable workflow, `@pilot`) | Steps 1–3 below |
| **Jenkins** (GitHub.com or GHES) | the `testing/classifier/` tree (vendored/checked out) + a `Jenkinsfile`; **no** reusable-workflow equivalent exists | `testing/classifier/jenkins/README.md` |

**If the repo runs Jenkins, stop here and follow the Jenkins path:**

1. The Jenkins integration needs this repo's `testing/` tree present in the
   consumer's workspace (Jenkins has no reusable-workflow mechanism, so the
   scripts must be vendored or checked out as a second source — the README
   explains both). Fetch the two Jenkins files so the human can see them:
   ```
   curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/testing/classifier/jenkins/Jenkinsfile
   curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/testing/classifier/jenkins/README.md
   ```
2. Then **follow `testing/classifier/jenkins/README.md`** — it is the Jenkins
   equivalent of Steps 1–3 here: prerequisites (plugins, agent tools), the
   credentials the human must create in the Jenkins store (you cannot do this —
   relay it), GitHub.com vs GitHub Enterprise (`GH_HOST`) setup, and the Bedrock
   option. The "Choose your AI tool" and "Choose your provider" decisions below
   apply identically on Jenkins (they set the same env vars).
3. Success signal is the same: a PR build that posts one triage comment.

**Two Jenkins-specific traps — get these right or the onboarding stalls (the
README has the fixes):**
- **Don't write a new declarative `Jenkinsfile` into a shop that runs *scripted*
  pipelines or a shared library.** It fails with `No such DSL method 'pipeline'`.
  Detect the team's existing pipeline style first; if it's scripted (`node { }`)
  or a shared library, **add a stage** using the scripted snippet in
  `jenkins/README.md` ("Existing pipelines: graft a stage") rather than
  replacing their file. When in doubt, ask the human which style they use.
- **If the team wants Bedrock, do NOT set `ANTHROPIC_API_KEY`** in the Jenkins
  env — a non-empty key silently bypasses Bedrock and bills the direct API. For
  a locked-down CloudBees worker that can't create a Jenkins credential or IAM
  role, use the **short-lived `AWS_BEARER_TOKEN_BEDROCK` build-parameter** path
  in `jenkins/README.md` ("Bedrock" → static build parameter) to get a first
  green run, then move to OIDC for steady state.

Everything from here down (Steps 1–3) is the **GitHub Actions** path.

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
# REQUIRED. A reusable workflow cannot grant itself more than the caller has, so
# these must be set HERE or the run fails: pull-requests: write (post the PR
# comment — without it the run 403s on setup), contents: read (check out the
# code), id-token: write (only used by provider: bedrock + aws-auth: oidc, but
# harmless to leave on the default path).
permissions:
  contents: read
  pull-requests: write
  id-token: write
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
the first line is `name: AI test classifier`, the `uses:` line is a single
unbroken line with one `@`, and the `permissions:` block is present (the run
fails without `pull-requests: write`). Then move on.

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

**If the user asks for Bedrock, the auth mode is a security decision they must
make — do NOT silently default it.** Ask, presenting both:
- `aws-auth: static` — one long-lived Bedrock API key in repo secrets. Fastest
  onboarding, but the key hits a **public** Bedrock endpoint, so a leak means
  open-ended spend ("denial of wallet"). **If they choose static, the cost
  guardrails in `BEDROCK.md` are mandatory.**
- `aws-auth: oidc` — no stored key; short-lived STS creds per run. The posture
  FISMA/federal reviews expect. Costs more setup: an IAM role + policy the team
  manages in *their* Terraform.

For a CMS/federal repo, **expect the client to require `oidc`** and to need to
sign off either way. If you can't reach them, stop and ask rather than guessing.
Full setup for both (and the cost guardrails) is in
`testing/classifier/docs/BEDROCK.md`. The examples below show the static `with:`
block; for oidc, follow BEDROCK.md.

The caller file you just wrote already contains the Bedrock block, **commented
out**. To switch to Bedrock you UNCOMMENT and fill those lines (do not retype the
file). Once the team has chosen the auth mode, edit
`.github/workflows/ai-test-classifier.yml`. The `with:` block for the **static**
path reads (for **oidc**, set `aws-auth: oidc` + `aws-role-to-assume:` and omit
the bearer secret — see `BEDROCK.md`):

```yaml
    with:
      tool: claude                 # claude (Claude models) | codex (OpenAI GPT-5.x). NOT copilot.
      provider: bedrock
      aws-region: us-east-1        # a region where your account has Anthropic model access
      aws-auth: static             # static: one Bedrock API key (needs cost guardrails) | oidc: IAM role, no stored key
      # bedrock-model: us.anthropic.claude-sonnet-4-6   # optional; codex → openai.gpt-5.5
```

and uncomment the `AWS_BEARER_TOKEN_BEDROCK` secret line in the `secrets:` block.

Key facts to get this right (do NOT skip):

- **`static` needs the `AWS_BEARER_TOKEN_BEDROCK` secret** (Step 2) and no IAM
  role — leave `aws-role-to-assume` out. One long-lived Bedrock API key lives in
  the repo secrets; that is the accepted tradeoff for the quick-start path.
- **On Bedrock, leave the API-key secret (`ANTHROPIC_API_KEY`) UNSET.** A
  non-empty key makes the CLI call the direct API and silently ignore Bedrock.
  (The reusable workflow blanks it on the bedrock path, but don't rely on that.)
- **`bedrock` works with `tool: claude` or `tool: codex`, never `copilot`.** Note
  Codex on Bedrock runs OpenAI models, not Claude.
- **`id-token: write` is already in the caller's `permissions:` block** — leave it
  even on the static path (it's harmless, and needed if you later switch to oidc).
- **OIDC variant (only if asked):** set `aws-auth: oidc` + `aws-role-to-assume:
  arn:aws:iam::<ACCOUNT_ID>:role/ai-test-classifier`, and do NOT set the bearer
  secret. Setup is in `BEDROCK.md`.

The one-time AWS-account setup (enable model access, then mint the Bedrock API
key) is **out-of-band and you cannot do it** — it lives in
`testing/classifier/docs/BEDROCK.md`. Tell the human to follow that doc; see Step 2.

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

   - **bedrock + `aws-auth: static`** (the default path): in the AWS account,
     (1) enable Anthropic model access in the Bedrock console, (2) mint a Bedrock
     API key (Bedrock console → API keys). No OIDC provider or IAM role needed.
     Then set the key as a repo secret:
     ```
     gh secret set AWS_BEARER_TOKEN_BEDROCK -R <owner>/<consumer-repo>
     ```
   - **bedrock + `aws-auth: oidc`** (only if the user asked for it): enable model
     access, then create a GitHub OIDC identity provider and the IAM role named in
     `aws-role-to-assume` (trust policy pinned to `repo:<owner>/<consumer-repo>:*`,
     permissions policy allowing `bedrock:InvokeModel*`). No repo secret needed.
   Full copy-pasteable steps (and IAM policies for the oidc variant) are in
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
For the **Jenkins** path (non-Actions CI, GitHub.com or GitHub Enterprise):
`testing/classifier/jenkins/README.md`.
Fetch repo files with (quote the URL — the `?` is a shell glob):
`curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/<path>`
