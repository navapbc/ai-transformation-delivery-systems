# Running the Test Classifier on Amazon Bedrock

This guide covers the **`provider: bedrock`** path: running the AI test
classifier with Claude inference served from **Amazon Bedrock inside your own
AWS account**, instead of calling the Anthropic API directly.

**Why this exists.** CMS guidance is that non-public internal code must not be
sent to an external AI agent — only Copilot is broadly covered today, with
Bedrock exceptions available to some teams. With Bedrock, the model runs in
*your* AWS account: the classifier's prompts and your code never leave your AWS
boundary, every call is logged in your CloudTrail, and access is governed by
your IAM. That is the compliance-aligned route for CMS-internal repos. It is the
same property Oddball's existing Bedrock PoC relies on.

> **Scope — which tool gets which model on Bedrock:**
>
> | `tool` | On Bedrock you get | Why |
> |---|---|---|
> | `claude` | **Claude** (Sonnet/Opus) | Claude Code CLI's native Bedrock mode |
> | `codex` | **OpenAI GPT-5.x** (not Claude) | Codex's built-in `amazon-bedrock` provider. Bedrock Claude speaks the Messages API, which Codex doesn't use — so Codex can't run Claude on Bedrock without a translation gateway (out of scope). |
> | `copilot` | — | No Bedrock provider. Rejected. |
>
> Both supported paths keep your code inside your AWS account. Pick the tool that
> matches your model preference; the workflow wires the rest.

This is the near-term path. The longer-term "contained VPC / launched VM /
Terraform teardown" lifecycle is **not** required to run the classifier on
Bedrock — the GitHub Actions runner plus OIDC role assumption below covers the
pilot. The trust model (your IAM role, your account, short-lived creds) is the
same one that design will build on later.

---

## How auth works (no long-lived keys)

The workflow authenticates to AWS with **GitHub OIDC**, not stored AWS keys:

1. The job requests a short-lived OIDC token from GitHub (needs
   `id-token: write` permission — already set in the workflows).
2. [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials)
   exchanges that token for **temporary STS credentials** by assuming an IAM
   role **you** create in **your** AWS account.
3. The Claude Code CLI picks those credentials up automatically via the default
   AWS SDK credential chain and, with `CLAUDE_CODE_USE_BEDROCK=1`, routes all
   inference through the Bedrock Invoke API in your region.

Nothing long-lived is stored in the repo. The role's trust policy restricts
*which repo and branch* may assume it; its permissions policy restricts *what
Bedrock actions* it may take.

---

## One-time AWS setup (per account)

You do this once in your team's AWS account. It needs an admin (or someone with
IAM + Bedrock permissions).

### 1. Enable Anthropic model access

First-time use of Anthropic models on Bedrock requires submitting a use-case
form, once per account:

1. Open the [Amazon Bedrock console](https://console.aws.amazon.com/bedrock/).
2. **Model catalog** → select an Anthropic model (e.g. Claude Sonnet 4.6).
3. Complete the use-case form. **Access is granted immediately on submission.**

Pick a region where the model is available (e.g. `us-east-1`); you'll use it as
`aws-region` below. The classifier uses **cross-region inference profile IDs**
(the `us.` prefix), so the model must be enabled for cross-region inference in
that region.

### 2. Create the GitHub OIDC identity provider

If your account doesn't already have GitHub's OIDC provider, add it once:

- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

(Console: IAM → Identity providers → Add provider → OpenID Connect. Or see
[GitHub's guide](https://docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services).)

### 3. Create the IAM role the workflow assumes

Create a role (e.g. `ai-test-classifier`) with **two** policies.

**Trust policy** — who may assume it. Lock it to your repo, and ideally to the
branch/PR refs that run the workflow:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
        }
      }
    }
  ]
}
```

> Tighten `:sub` further if you can, e.g.
> `repo:<OWNER>/<REPO>:pull_request` or `...:ref:refs/heads/main`. The broad
> `:*` is the loosest acceptable form.

**Permissions policy** — what it may do. This is the minimum the Claude Code
CLI needs on Bedrock:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowModelAndInferenceProfileAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*",
        "arn:aws:bedrock:*:*:foundation-model/*"
      ]
    }
  ]
}
```

> You can narrow `Resource` to the specific inference profile ARN(s) you
> approved. `bedrock:GetInferenceProfile` is optional but avoids an extra
> round-trip per model; keep it for cleanliness.

Note the role ARN — it's `aws-role-to-assume` below.

---

## Wire it into the classifier

Two ways, matching the two consumption paths in
[`SETUP.md`](./SETUP.md).

### Path A — Reusable workflow (recommended)

In your caller workflow (`.github/workflows/ai-test-classifier.yml`), set the
provider inputs and **grant `id-token: write` in the caller** (the reusable
workflow can't grant it for you):

```yaml
name: AI test classifier
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write
  id-token: write            # required for Bedrock OIDC

jobs:
  classify:
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@pilot
    with:
      tool: claude            # claude → Claude on Bedrock | codex → GPT-5.x on Bedrock
      provider: bedrock
      aws-region: us-east-1
      aws-role-to-assume: arn:aws:iam::123456789012:role/ai-test-classifier
      # bedrock-model: us.anthropic.claude-sonnet-4-6   # optional; per-tool default below
    secrets:
      # No API key needed on the bedrock path — leave them out.
      {}
```

That's the whole change. Drop `provider`/`aws-*` (and restore the API key) to
fall back to the direct API path.

**`bedrock-model` defaults by tool** (override only to pin a different one):

| `tool` | Default `bedrock-model` | Format |
|---|---|---|
| `claude` | `us.anthropic.claude-sonnet-4-6` | cross-region inference profile ID (`us.` prefix) |
| `codex` | `openai.gpt-5.5` | Bedrock OpenAI model ID |

> For `tool: codex`, the IAM role's permissions also need to cover the OpenAI
> model on Bedrock, and the model must be enabled in your region (step 1 applies
> to the OpenAI models, not Anthropic). GPT-5.5 is in US East (Ohio); GPT-5.4 in
> US East (Ohio) and US West (Oregon).

### Path C — Vendored workflow

If you vendored `testing/classifier/.github/workflows/ai-test-classifier.yml`
into your repo, the provider is driven by **repository variables** (Settings →
Secrets and variables → Actions → Variables) instead of inputs:

| Variable | Value | Notes |
|---|---|---|
| `AI_REVIEW_TOOL` | `claude` or `codex` | `copilot` is not supported on Bedrock |
| `AI_PROVIDER` | `bedrock` | Unset/`anthropic` keeps the direct API path |
| `AWS_REGION` | e.g. `us-east-1` | Region with the model enabled |
| `AWS_ROLE_TO_ASSUME` | the role ARN | From step 3 |
| `AWS_BEDROCK_MODEL` | *(optional)* | Default: claude → `us.anthropic.claude-sonnet-4-6`, codex → `openai.gpt-5.5` |

No API-key secret is needed; the vendored workflow forces `ANTHROPIC_API_KEY`
and `OPENAI_API_KEY` blank when `AI_PROVIDER=bedrock`.

---

## What the workflow sets for you

When the Bedrock path is active, the run step sets these in the job env (you
don't set them yourself). The AWS creds (`AWS_ACCESS_KEY_ID` /
`_SECRET_ACCESS_KEY` / `_SESSION_TOKEN`) always come from the OIDC step.

**`tool: claude`** — routes the Claude Code CLI through Bedrock:

```bash
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=<your region>                 # required; CLI does NOT read ~/.aws for this
ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-6   # cross-region inference profile ID
# ANTHROPIC_API_KEY forced empty so the CLI uses Bedrock, not the direct API
```

**`tool: codex`** — a CI-local `config.toml` (under `CODEX_HOME`) points Codex
at its built-in Bedrock provider:

```toml
model = "openai.gpt-5.5"
model_provider = "amazon-bedrock"
[model_providers.amazon-bedrock.aws]
region = "<your region>"
```

```bash
# OPENAI_API_KEY forced empty so codex uses the Bedrock provider, not direct API
```

---

## Troubleshooting

- **`Could not load credentials from any providers` / role not assumed** — the
  OIDC step failed. Check the role ARN, that the OIDC provider exists in the
  account, and that the trust policy's `:sub` matches `repo:<OWNER>/<REPO>:...`.
  Confirm `id-token: write` is present **in the caller** (Path A) — the reusable
  workflow can't add it.
- **`on-demand throughput isn't supported`** — you passed a bare model ID. Use a
  cross-region **inference profile** ID (the `us.` prefix), which is the default.
- **`AccessDeniedException` on invoke** — model access not enabled in that
  region (step 1), or the permissions policy is missing `bedrock:InvokeModel*`.
- **Wrong region** — `AWS_REGION` must be a region where your account has the
  model enabled. List what's available with
  `aws bedrock list-inference-profiles --region <region>`.
- **It silently used the direct API instead of Bedrock** — an `ANTHROPIC_API_KEY`
  (claude) or `OPENAI_API_KEY` (codex) was non-empty. On the Bedrock path the
  workflows force both blank; if you customized the workflow, make sure that
  still holds.
- **(codex) `model ... is not available` / validation error** — you pointed
  `bedrock-model` at a non-OpenAI model. Codex on Bedrock runs OpenAI models only
  (e.g. `openai.gpt-5.5`); it cannot run Claude. To run Claude on Bedrock, use
  `tool: claude`.
- **Forks and Dependabot PRs get no Bedrock run** — GitHub does not issue OIDC
  tokens to workflows triggered from a fork or from Dependabot (by design), so
  the role can't be assumed and the Bedrock step fails. This matters most for
  **public repos** (e.g. open-source pilots): contributor PRs from forks won't be
  classified via Bedrock. The direct-API path (`provider: anthropic`) has the same
  fork limitation for secrets. Internal-branch PRs are unaffected.

---

## References

- [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock) — env vars, IAM policy, model IDs
- [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials) — OIDC setup
- [Configuring OIDC in AWS (GitHub Docs)](https://docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [`SETUP.md`](./SETUP.md) — the three consumption paths (A/B/C)
