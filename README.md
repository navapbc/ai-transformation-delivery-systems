# ai-transformation-delivery-systems
This repo provides drop-in AI tooling for teams to install on their own repos. Your team can leverage tooling in two ways depending on your technical constraints:

- **In CI automatically on every PR (outer loop)** Findings post as PR comments
  and developer 👍/👎 feedback is gathered by metricsai. *How* it's wired in
  depends on the workflow and your CI — a reusable workflow, a vendored
  workflow/scripts, or Copilot auto-review (see each section).
- **Locally, on demand before pushing (inner loop)** A developer runs the
  scripts for a fast read — a terminal report, or a posted PR comment. No CI
  required.

As a rule of thumb, prefer the outer loop option for consistency and ease of use. Reach for the inner loop if technical constraints (e.g. no GitHub Actions, no Jenkins or Copilot, or inference must stay within your AWS boundary) make it easier, or you have a real process reason to shift the checks left in the software dev lifecycle.

 
## What's here: High-level overview
| Path | What it is | Consumed by |
|---|---|---|
| `testing/classifier/` | AI **test-failure classifier** — labels each failing test app-bug / test-bug / flaky / env | consumer repo CI and/or local |
| `security/` | AI **security / PR-review** bundle that flags secrets, PII/PHI, OWASP & IaC-compliance issues by severity | consumer repo CI and/or local |
| `metricsai/` | Python CLI that **gathers metrics** from the two workflows | run on demand |

**AI assistant compliance and configuration** Under the hood the testing and security
bundles work similarly, configured by two independent choices:

- **Which AI assistant runs** — set `AI_REVIEW_TOOL` to `claude`, `codex`, or
  `copilot` (per developer locally, or per repo in CI). Make your choice based on project tooling constraints. 
- **Where inference runs** — the vendor's API by default, or Amazon Bedrock in
  your own AWS account when code can't (or shouldn't) leave your AWS boundary (`claude` / `codex`
  only, not `copilot`). Make your choice based on project compliance guidelines.

Whichever you pick, the AI ends its output with one parseable
`<<<AI_REVIEW_RESULT:…>>>` marker that the dispatcher reads to decide the outcome.

## Testing classifier
**Problem solved:** we prevent AI tooling from "fixing" a failing test when the
*code* is what actually broke. When a test fails, the classifier answers **is
the *test* wrong, or is the *code* wrong?** For each test failure it issues one verdict
(`APPLICATION_BUG`, `TEST_BUG`, `FLAKY_FAILURE`, or `ENVIRONMENT_ISSUE`), along with a
short rationale, and then posts a PR comment. Developers are asked to 👍/👎 the comment to evaluate classifier quality. As of now, this workflow is diagnostic only with the hope of leveraging the classifier to move towards auto-fixing tests in the future without sacrificing quality.

Canonical classification logic lives in the skill:
[`testing/classifier/.skills/test-classifier/SKILL.md`](testing/classifier/.skills/test-classifier/SKILL.md).

### How data is gathered

```
  INNER LOOP (local, pre-push)          OUTER LOOP (CI, on every PR)
    test-classifier --submit              Actions (Emmy) / Jenkins
          │ terminal y/n                          │ runs suite (OBSERVED)
          │                                       ▼
          │                            ONE PR comment + 👍/👎 ──(devs react)
          │                                       │
          │                                       ▼
          │                              metricsai weekly run
          ▼                                       │
     "Testing Events" tab ─────► Google Sheet ◄───┘
```

Two writers, one sheet: CI 👍/👎 reactions (harvested weekly by `metricsai`) and
local `--submit` events (written immediately to the *Testing Events* tab).

### Options to run (inner loop and outer loop)
- **Outer loop (CI, on every PR)** — the designed path. It triggers on every PR,
  runs the suite itself, and comments **only when something fails**. GitHub
  Actions consumers reference a reusable workflow (no files copied); Jenkins
  consumers vendor the bundle and add a pipeline stage. Feedback is the 👍/👎 on
  the comment, harvested into the team's weekly metrics row.
- **Inner loop (local, pre-push)** — a `test-classifier` shell function classifies
  unpushed changes before a PR exists. Diff-only (INFERRED) by default, or runs
  the suite (OBSERVED) on demand; `--submit` records the developer's y/n straight
  to the sheet. A fast preview, not a substitute for the CI pass.

A team runs the **outer loop when its CI can host it**; the **inner loop is the
fallback** when CI can't — and a preview for everyone else.

## Security
**Problem solved:** stop secrets, PII/PHI, and security or compliance defects from
landing — the security counterpart to the classifier, answering **is this change
safe?** It reviews a change (or the whole repo) and reports findings by severity
(Critical / High / Medium / Low) with remediation, as a **PASS / WARN / BLOCK**
gate locally and as inline **PR comments** labeled `security(<severity>):` or
`compliance(<severity>):` with one-click fix suggestions. Like the classifier it
is advisory and never commits; a self-adjudication pass trims false positives.

It ships three layers:

- **`code-security`** — secrets, PII, PHI, and OWASP-style defects in a diff.
- **`iac-compliance`** — infrastructure-as-code against CMS ARS 5.1 + NIST SP
  800-53 Rev 5.
- **`pr-review` / `codebase-audit`** — the full PR diff (local, Actions, or
  Copilot), or a full-repo audit of the codebase at rest.

Canonical review logic lives in the skills, e.g.
[`security/review/.skills/pr-review/SKILL.md`](security/review/.skills/pr-review/SKILL.md).

### How data is gathered
```
  INNER LOOP (local, pre-commit)        OUTER LOOP (CI, on every PR)
    code-security / iac-compliance        Actions (vendored) / Copilot (licensed)
          │                                       │
          ▼                                       ▼
     PASS / WARN / BLOCK                   PR comments + 👍/👎 ──(devs react)
     (terminal, no sheet)                         │
                                                  ▼
                                          metricsai weekly run
                                                  │
                                                  ▼
                                            Google Sheet
```

Unlike testing, the local loop is a **gate, not a sheet writer** — only the CI
PR comments (👍/👎) and the AWS Security Hub count feed `metricsai`.

### Options to run (inner loop and outer loop)
- **Outer loop (CI, on every PR)** — the recorded path, with **two shipped
  options**: a **vendored GitHub Actions workflow** (`ai-pr-review.yml`, copied
  into the repo — security has no point-at-it reusable workflow), or **GitHub
  Copilot auto-review** (a GitHub app, nothing copied, but needs a Copilot
  Enterprise / Business + Code-Review license). Either posts inline
  `security(...)` / `compliance(...)` comments; the 👍/👎 plus an AWS Security Hub
  count feed the weekly metrics row. **There is no Jenkins integration for
  security** (testing has one) — the dispatcher is CI-agnostic so a team could
  wire it into Jenkins by hand, but that path isn't shipped. A periodic
  **`codebase-audit`** can also run in CI for a full-repo baseline.
- **Inner loop (local, pre-commit/pre-push)** — the `code-security` /
  `iac-compliance` shell functions (and a local `pr-review`) scan unpushed
  changes on demand and return a **PASS / WARN / BLOCK** result in the terminal.
  Report-only: it catches secrets/PII before they leave the laptop, but doesn't
  feed the sheet.

A team runs the **outer loop when its CI can host it**; the **inner loop is the
local backstop** that keeps secrets and PII out before code is ever pushed.

## Learn more
**Testing classifier**
- [Setup guide](testing/classifier/docs/SETUP.md) — install + all run paths (CI, Jenkins, local), for humans
- [Canonical skill](testing/classifier/.skills/test-classifier/SKILL.md) — the classification logic the AI follows

**Security**
- [Setup guide](security/review/README.md) — install + operations (pre-commit, PR review, audit), for humans
- Canonical skills — [`code-security`](security/review/.skills/code-security/SKILL.md) · [`iac-compliance`](security/review/.skills/iac-compliance/SKILL.md) · [`pr-review`](security/review/.skills/pr-review/SKILL.md)

**Metrics**
- [metricsai](metricsai/README.md) — how 👍/👎 + findings are harvested into a Google Sheet
