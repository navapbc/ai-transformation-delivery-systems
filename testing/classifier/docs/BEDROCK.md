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

## Two auth modes — pick one

Set `aws-auth` (or the `AWS_AUTH` repo variable for the vendored path):

| `aws-auth` | What you store | Setup | Posture |
|---|---|---|---|
| **`static`** | one long-lived `AWS_BEARER_TOKEN_BEDROCK` secret | ~2 steps (mint a Bedrock API key) | fastest onboarding; a long-lived credential lives in the secrets store |
| **`oidc`** | nothing — short-lived STS creds per run | more setup (IAM role + OIDC trust, via the team's IaC/Terraform) | no stored credential; ephemeral per-run creds — the posture FISMA/federal environments expect |

**This is a security decision the client owns — surface both tradeoffs and let
them choose; do not default to `static` silently.** For a fast pilot start
`static` is tempting (mint one key, store it, done — it mirrors how most SDKs
onboard Bedrock, e.g. Vercel AI SDK's `AWS_BEARER_TOKEN_BEDROCK`). But:

- **`static` carries a real leak risk.** The Bedrock key authenticates against a
  **public** Bedrock API endpoint. If it ever escapes the secrets store, anyone
  can use it until it's rotated — including a deliberate **"denial of wallet"**
  (running up spend on purpose). A long-lived key in a FISMA system is the kind
  of thing that should not exist; ephemeral, time-bound creds are the standard.
  **If you use `static`, the cost guardrails below are mandatory, not optional.**
- **`oidc` removes the stored credential** (short-lived STS creds per run) but
  adds real setup the client carries in *their* infrastructure: an IAM role +
  permissions policy, typically created and lifecycle-managed via **their
  Terraform**. That's a few stanzas (an AI coding assistant can draft the
  Terraform), plus a one-time OIDC-trust configuration — more friction than a
  static key, but the right posture for federal/FISMA work.

For pilots in a CMS/federal boundary, **expect the client's security review to
require `oidc`** (no static keys dropped around) — and to need to sign off
either way before any credential is provisioned. Treat the choice as a question
to pose to the team, with the risks above stated, not a default you pick for
them. Both modes keep inference inside your AWS account — the difference is only
*how the runner authenticates*, not where the model runs.

### How `oidc` works (no long-lived keys)

1. The job requests a short-lived OIDC token from GitHub (needs
   `id-token: write` — already set in the workflows).
2. [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials)
   exchanges it for **temporary STS credentials** by assuming an IAM role **you**
   create in **your** AWS account.
3. The CLI picks those creds up via the default AWS SDK credential chain and
   routes inference through Bedrock in your region.

The role's trust policy restricts *which repo/branch* may assume it; its
permissions policy restricts *what Bedrock actions* it may take.

### How `static` works

You mint a **Bedrock API key** in the AWS console (Bedrock → API keys) and store
it as the `AWS_BEARER_TOKEN_BEDROCK` GitHub secret. The workflow passes it
through; both the Claude Code CLI and Codex honor it (it takes precedence over
SigV4). No IAM role or OIDC provider needed. You still do step 1 below (enable
model access); you skip steps 2–3.

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

> **Using `aws-auth: static`?** Stop here — also mint a Bedrock API key
> (Bedrock console → API keys) and store it as the `AWS_BEARER_TOKEN_BEDROCK`
> secret. Skip steps 2–3 (no OIDC provider or IAM role), then do the
> [Cost guardrails](#cost-guardrails-required-on-static-recommended-always)
> (mandatory on static) before you
> [wire it into the classifier](#wire-it-into-the-classifier).

### 2. Create the GitHub OIDC identity provider _(oidc only)_

If your account doesn't already have GitHub's OIDC provider, add it once:

- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

(Console: IAM → Identity providers → Add provider → OpenID Connect. Or see
[GitHub's guide](https://docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services).)

### 3. Create the IAM role the workflow assumes _(oidc only)_

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

## Cost guardrails (required on `static`, recommended always)

A pilot agent on Bedrock spends real money per run, and a leaked **static** key
on a public endpoint can be abused for open-ended spend. Put a ceiling and an
alarm in place **before** you hand a key to a pilot — on the static path this is
mandatory, not optional.

1. **AWS Budget + alert (do this first).** Create a monthly cost budget scoped to
   Bedrock with email/SNS alerts at, say, 50% / 80% / 100% of the cap. This
   doesn't stop spend by itself, but it's your early-warning tripwire.
   - Console: **Billing → Budgets → Create budget → Cost budget**, filter
     **Service = Amazon Bedrock**.
   - A `budgets:CreateBudget` action or the `aws_budgets_budget` Terraform
     resource does the same — fold it into the same IaC that creates the IAM
     role (oidc path), so the guardrail ships with the credential.
2. **Cap the blast radius, not just the alert.** A budget alert is reactive;
   pair it with a hard limit so a runaway/abused key can't run unbounded:
   - **Scope the credential tightly.** The IAM role (oidc) or the Bedrock API
     key's policy should allow **only `bedrock:InvokeModel*` on the specific
     inference-profile ARNs you approved** — nothing else. A key that can only
     invoke one model is far less useful to an attacker.
   - **Lower the per-account Bedrock request quotas** (Service Quotas → Amazon
     Bedrock → the per-model requests/tokens-per-minute limits) to a ceiling
     that comfortably fits CI but caps sustained abuse.
   - **Prefer `oidc` to shrink the window entirely.** Short-lived STS creds can't
     be abused after the run ends — the cleanest mitigation for denial-of-wallet.
3. **Rotate the static key on any suspicion**, and keep it out of logs (the
   workflow already passes it as a masked secret, never echoes it).

> **Static key + no budget = the risk Brian flagged in the pilot sync.** If the
> client won't allow `oidc` yet, do not skip step 1–2 — the budget + tight
> policy + lowered quota are what make a long-lived key acceptable for a
> time-boxed pilot.

---

## Wire it into the classifier

Two ways, matching the two consumption paths in
[`SETUP.md`](./SETUP.md).

### Path A — Reusable workflow (recommended)

In your caller workflow (`.github/workflows/ai-test-classifier.yml`), set the
provider inputs. The example below uses **`aws-auth: static`** — one Bedrock API
key, no IAM role (the simplest wiring; remember the cost guardrails above are
mandatory on this path). For `aws-auth: oidc`, set the role inputs instead (see
"How `oidc` works" above) and omit the bearer-token secret:

```yaml
name: AI test classifier
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write
  id-token: write            # harmless here; required only if you switch to aws-auth: oidc

jobs:
  classify:
    uses: navapbc/ai-transformation-delivery-systems/.github/workflows/test-classifier.yml@pilot
    with:
      tool: claude            # claude → Claude on Bedrock | codex → GPT-5.x on Bedrock
      provider: bedrock
      aws-auth: static        # static: one bearer-token secret (needs cost guardrails) | oidc: IAM role, no stored key
      aws-region: us-east-1
      # bedrock-model: us.anthropic.claude-sonnet-4-6   # optional; per-tool default below
    secrets:
      AWS_BEARER_TOKEN_BEDROCK: ${{ secrets.AWS_BEARER_TOKEN_BEDROCK }}
```

That's the whole change. Drop `provider`/`aws-*` (and restore the API key) to
fall back to the direct API path.

**Hardened variant — `aws-auth: oidc`** (no stored credential; assumes an IAM
role via OIDC — needs the role from steps 2–3 below):

```yaml
    with:
      tool: claude
      provider: bedrock
      aws-auth: oidc
      aws-region: us-east-1
      aws-role-to-assume: arn:aws:iam::123456789012:role/ai-test-classifier
    secrets:
      # No API key needed on the oidc bedrock path — leave them out.
      {}
```

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
| `AWS_AUTH` | `oidc` (default) or `static` | `static` uses the bearer-token secret instead of a role |
| `AWS_REGION` | e.g. `us-east-1` | Region with the model enabled |
| `AWS_ROLE_TO_ASSUME` | the role ARN | **oidc only** — from step 3 |
| `AWS_BEDROCK_MODEL` | *(optional)* | Default: claude → `us.anthropic.claude-sonnet-4-6`, codex → `openai.gpt-5.5` |

For `AWS_AUTH=static`, add the `AWS_BEARER_TOKEN_BEDROCK` **secret** instead of
`AWS_ROLE_TO_ASSUME`. No API-key secret is needed otherwise; the vendored
workflow forces `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` blank when
`AI_PROVIDER=bedrock`.

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
- [AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-create.html) — cost budget + alerts (the cost guardrail above)
- [Service Quotas — Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html) — per-model request/token rate caps
- [`SETUP.md`](./SETUP.md) — the consumption paths (A/B/C + Jenkins)
