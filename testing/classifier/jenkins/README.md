# Running the AI test-classifier on Jenkins

This directory is the **Jenkins integration** for the test-classifier — the
counterpart to the GitHub Actions caller workflow. It exists for teams whose
clients can't use GitHub Actions and run Jenkins as their only CI.

The design point worth knowing up front: **the classifier is already
CI-agnostic.** The dispatcher
(`.skills/test-classifier/scripts/test-classifier-dispatcher.sh`), the prompt
(`SKILL.md`), the agent invocation, the diff, and the metrics harvester are
plain `shell + git + gh` — none of it knows whether it's running in Actions or
Jenkins. The only CI-specific glue is **how the PR context and secrets get
into the dispatcher's env**. That glue is two small files here:

| File | What it is |
|------|------------|
| `ci-adapter.sh` | Maps Jenkins' native PR env (`CHANGE_ID`, `CHANGE_TARGET`, `CHANGE_URL`) onto the dispatcher's contract and execs it. The whole Jenkins ↔ classifier seam. |
| `Jenkinsfile` | A reference declarative pipeline: checkout → install agent CLI → bind credentials → run the adapter → archive the record. Drop-in starting point. |

## How it maps to the GitHub Actions version

The dispatcher's entry contract is the same on both platforms. Only the source
of each value differs:

| Dispatcher needs | GitHub Actions provides | Jenkins provides |
|------------------|-------------------------|------------------|
| PR number | `github.event.pull_request.number` | `CHANGE_ID` (GitHub Branch Source plugin) |
| Base ref | `github.event.pull_request.base.ref` | `CHANGE_TARGET` |
| GitHub token (`GH_TOKEN`) | `github.token` | a PAT from the Jenkins credentials store |
| Agent CLI on PATH | `npm install -g …` step | `npm install -g …` step |
| Which agent (`AI_REVIEW_TOOL`) | workflow input | `environment` block |
| Run record | `actions/upload-artifact` | `archiveArtifacts` |

`gh` works in any CI — it reads `GH_TOKEN`/`GITHUB_TOKEN` from the env, no
`gh auth login` needed. The adapter passes **both** `--pr` and `--against` to
the dispatcher, so it never needs `gh pr view` to discover the PR; `gh` is used
only to **post the comment**.

## Prerequisites

1. **Job type:** a *multibranch pipeline* or *GitHub Organization* job using the
   **GitHub Branch Source** plugin. That's what populates `CHANGE_ID` /
   `CHANGE_TARGET` / `CHANGE_URL` on PR builds. (A plain freestyle/branch job
   won't have PR context — see "Non-multibranch jobs" below.)
2. **Agent tools** on the Jenkins agent: `git`, `node` + `npm`, `gh`, `jq`,
   `python3`. (Bake these into your agent image to skip per-build installs.)
3. **Credentials** in the Jenkins store (Manage Jenkins → Credentials):
   - `github-pat` — **secret text**, a GitHub PAT with `pull-requests: write`
     (and `contents: read`). Used by `gh` to post the comment.
   - `anthropic-api-key` — **secret text**, your Anthropic API key. *(Omit on
     Bedrock — see below.)*

   The ids (`github-pat`, `anthropic-api-key`) are referenced by
   `credentials(...)` in the `Jenkinsfile`; rename there if your store differs.

## Setup (GitHub.com)

1. Vendor this repo's `testing/` tree into the consumer repo (or check it out as
   a second source in the pipeline, mirroring the Actions bundle step).
2. Add a multibranch pipeline pointed at the repo, **Build Configuration → by
   Jenkinsfile**, script path `testing/classifier/jenkins/Jenkinsfile`.
3. Create the two credentials above.
4. Open a PR. The PR build runs the classifier and posts one review comment.

## Setup (GitHub Enterprise Server)

Same as above, plus: the adapter **auto-detects** the GHES host from
`CHANGE_URL` (e.g. `https://github.example.com/...`) and sets `GH_HOST` so `gh`
targets the right server. To be explicit, uncomment `GH_HOST` in the
`Jenkinsfile` `environment` block. The PAT must be minted on the **GHES**
instance, not github.com.

## Bedrock (inference inside your AWS account)

To route inference through Amazon Bedrock instead of the direct Anthropic API
(the no-data-leaves-your-AWS path — see `../docs/BEDROCK.md`):

1. **Remove** `ANTHROPIC_API_KEY` from the `environment` block (a non-empty key
   forces the direct API and bypasses Bedrock).
2. Add the Bedrock env the Claude Code CLI reads:
   ```groovy
   CLAUDE_CODE_USE_BEDROCK = '1'
   AWS_REGION              = 'us-east-1'
   ANTHROPIC_MODEL         = 'us.anthropic.claude-sonnet-4-6'  // a cross-region inference profile id
   ```
3. Provide AWS credentials by one of:
   - **Static** — a `AWS_BEARER_TOKEN_BEDROCK` secret-text credential (simplest).
   - **Keyless (recommended)** — the [Jenkins OIDC Provider plugin](https://plugins.jenkins.io/oidc-provider/)
     issues a build JWT; configure an AWS IAM role with an
     `sts:AssumeRoleWithWebIdentity` trust policy and assume it in a stage,
     exporting `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
     `AWS_SESSION_TOKEN`. This is the Jenkins analogue of the Actions OIDC step.

## Non-multibranch jobs

If you can't use a multibranch job, the adapter also accepts explicit overrides
— set these in the build env (e.g. as build parameters) and it works the same:

```bash
export PR_NUMBER=123        # the PR to classify + comment on
export BASE_REF=main        # the base branch to diff against
```

When neither `CHANGE_ID` nor `PR_NUMBER` is present, the adapter exits 0 (it's
not a PR build — nothing to classify).

## Metrics

The metrics harvester (`testing/metrics/test_classifier_comments.sh`) is
**standalone** and unchanged — it needs no CI integration. Run it as a separate
**scheduled** Jenkins job (or any cron host) with `GH_TOKEN` exported; it reads
the 👍/👎 reactions and reply reasons off the posted comments. See
`testing/metrics/README.md`.

## Environment / air-gap note

The agent makes outbound calls to the Anthropic API (or to Bedrock). A
locked-down Jenkins with **no egress** can't reach the direct API or `npm` — in
that case use **Bedrock in your own VPC** (or a VPC endpoint) for inference and
a pre-baked agent image so no `npm install` is needed at build time. The
classifier code itself needs no change; this is purely a network/provisioning
concern.
