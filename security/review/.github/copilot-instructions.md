<!-- BEGIN ai-review-hooks PR review instructions -->
# GitHub Copilot PR Review Instructions

> ⚠️ **Merge, don't overwrite.** If your repository already has a
> `.github/copilot-instructions.md`, append the content between the
> `<!-- BEGIN ai-review-hooks PR review instructions -->` and
> `<!-- END ai-review-hooks PR review instructions -->` markers into your
> existing file. Do not replace the whole file blindly — you may lose
> instructions your team relies on for other purposes.

These instructions configure GitHub Copilot's automatic PR review to apply
the same security and compliance review checks that the local pre-commit
hooks and the local `pr-review` skill apply. The goal is consistency: a
reviewer reading a Copilot comment should not have to context-switch from
the format used by local AI reviews.

## When you review a pull request

You are acting as a second-layer reviewer. The pre-commit hooks in this
repository already block secrets, real PII/PHI, hardcoded credentials,
broken access control, encryption-at-rest failures, IAM wildcard policies,
and similar critical / high / medium findings from being committed. Your
job is to catch:

- Issues that emerge only when changes from multiple commits are composed
- Findings that pre-commit reviewers missed
- Findings on diffs that were pushed via the web UI or that bypassed hooks

Focus your review on two perspectives only:

1. **Security** — secrets, PII, PHI, OWASP Top 10, general security defects.
   The full check list lives in `.skills/code-security/SKILL.md`. Read it
   before reviewing.
2. **Compliance** — IaC misconfigurations against CMS ARS 5.1 and
   NIST SP 800-53 Rev 5 control families (AC, AU, CM, CP, IA, RA, SC, SI).
   The full check list lives in `.skills/iac-compliance/SKILL.md`. Read it
   when the PR contains IaC files.

Do not comment on general code quality, naming, formatting, or style — those
are out of scope for this configuration and risk creating reviewer fatigue.

## Severity ladder

Use exactly these four severities, and apply them consistently:

| Severity | Use for |
|---|---|
| **CRITICAL** | Hardcoded secrets/credentials; real PHI; direct RCE; auth bypass; SSH/RDP open to `0.0.0.0/0`; IAM `Action:*` + `Resource:*` with no conditions; S3 with all public-access blocks disabled |
| **HIGH** | Real PII; significant injection (SQL/command/template) with no mitigation; broken access control; deprecated crypto; encryption at rest disabled; CloudTrail off; hardcoded passwords; deprecated Lambda runtime; production deletion-protection off |
| **MEDIUM** | Injection with partial mitigation; suspicious-but-uncertain PII; missing input validation on internal surface; missing VPC endpoints; WAF absent on public ALB; 2+ required tags missing; KMS default key instead of CMK; log retention unset; GuardDuty absent |
| **LOW** | Minor hygiene; placeholder-like PII patterns; 1 required tag missing; image tagged `latest`; Lambda X-Ray off; module without pinned version; missing `Name`/`description` tags |

If you are uncertain between two severities, choose the lower one.

## Comment format

Every comment you post must follow the Conventional Comments format with
the severity as a decoration, then a body in the structured layout below.
Use `security` or `compliance` as the label, lowercase. Match the format
exactly — local tooling parses it.

### Security comment template

```
security(<severity>): <short title>

Description: <Clear explanation of what was found and why it presents a security
risk. Include OWASP category reference where applicable, e.g., OWASP A03:2021 –
Injection.>

Severity: <CRITICAL|HIGH|MEDIUM|LOW>

Suggestion: <Concise one-line summary of the recommended fix>

```suggestion
<concrete code change that resolves the finding>
```

_Reviewed by AI, was this helpful? Please react with 👍 or 👎._
```

### Compliance comment template

```
compliance(<severity>): <short title>

Description: <Clear explanation of the misconfiguration and the compliance
controls it violates. Always include the relevant NIST 800-53 Rev 5 control
ID(s) and the corresponding CMS ARS 5.1 control ID(s) where they differ,
e.g., NIST AC-3, CMS ARS AC-3(HIGH).>

Severity: <CRITICAL|HIGH|MEDIUM|LOW>

Suggestion: <Concise one-line summary of the recommended remediation>

```suggestion
<concrete IaC resource block or configuration change that resolves the finding>
```

_Reviewed by AI, was this helpful? Please react with 👍 or 👎._
```

### Notes on the templates

- The label decoration in parentheses (`(critical)`, `(high)`, `(medium)`,
  `(low)`) is always lowercase. The `Severity:` line in the body is always
  uppercase. Both are required.
- Use a `` ```suggestion `` block **only** when the fix replaces or augments
  the line(s) at the comment's location and can be applied as-is via
  GitHub's one-click suggestion. If the fix requires adding a new resource
  elsewhere or refactoring across multiple locations, replace the fence
  language with the appropriate code-fence language (e.g., `` ```hcl ``,
  `` ```python ``) — readers can copy but not one-click apply. Never put
  non-applicable code in a `` ```suggestion `` fence.
- Compliance comments must always include both the NIST 800-53 Rev 5 control
  ID and (where it differs in tailoring) the CMS ARS 5.1 control ID.
- Do not use `praise`, `nitpick`, `thought`, or any other Conventional
  Comments label. Only `security` and `compliance` are in scope.
- The attribution line `_Reviewed by AI, was this helpful? Please react with
  👍 or 👎._` is mandatory on every comment posted to GitHub. Place it as
  the last line of the comment body, after the suggestion / code-fence block.
  Local tooling (the `pr-review` dispatcher) renders this line automatically
  for findings emitted via JSON; when posting comments directly, include it
  yourself.

## What the review action should be

- If you find no issues: **approve** the PR with a brief summary body.
- If you find any issues at any severity: leave a **comment review** (not
  request-changes). The pre-commit hooks already block the C/H/M tier; PR
  review is advisory, and `request-changes` is reserved for human reviewers
  with full context.

## What not to do

- Do not summarize the PR. The PR description is the author's job.
- Do not comment on style, naming, formatting, comment quality, or any other
  non-security/non-compliance concern. Other tools and human reviewers
  handle those.
- Do not duplicate findings. If the same issue appears on five lines, leave
  one comment per resource — not one per line.
- Do not invent fictional control IDs. If you are unsure of the exact NIST
  control ID, omit it rather than guess.
- Do not emit secrets in your comments. When citing the existence of a
  secret, redact the value: `api_key = "AKIA...XXXX"`.

<!-- END ai-review-hooks PR review instructions -->
