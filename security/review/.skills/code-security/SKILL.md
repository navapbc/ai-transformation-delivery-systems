---
name: code-security
description: >
  Perform a comprehensive pre-commit security review on uncommitted changes.
  Covers all areas of the built-in /security-review, OWASP Top 10 (where
  applicable), and mandatorily detects secrets, PII, and PHI in staged changes.
  Use whenever a security review is requested, when running as a pre-commit
  hook, or any time uncommitted code changes need security validation before
  they enter the repository. Only report findings of low severity or above.
  Critical, high, and medium findings block the commit; low findings warn
  without blocking.
---

# Security Review Skill

A focused, pre-commit security review that protects the codebase and the
privacy of the beneficiaries the system serves. Runs on **staged (uncommitted)
changes only** — fast, targeted, and actionable.

This skill is invoked by a pre-commit hook dispatcher
(`.skills/code-security/scripts/code-security-hook-dispatcher.sh`) which
selects an AI assistant based on the `AI_REVIEW_TOOL` environment variable
(`claude` | `codex` | `copilot`). The skill instructions are identical across
all three assistants; only the invoking CLI differs.

This file (`.skills/code-security/SKILL.md`) is the **canonical** copy. Each
developer's chosen AI tool reads either this file or a byte-identical derived
copy under `.claude/`, `.codex/`, or `.github/copilot/`, depending on what
`scripts/sync-skills.sh` produced for their `AI_REVIEW_TOOL` setting.

---

## Execution Overview

1. **Collect the diff** — staged changes by default; `--against <ref>` for ad-hoc reviews
2. **Identify context files** — pull in related files that affect risk assessment
3. **Run the review** — secrets/PII/PHI detection first (mandatory), then OWASP + general security
4. **Report** — low/medium/high/critical findings, with severity, location, and remediation
5. **Emit result marker** — exactly one of `<<<AI_REVIEW_RESULT:PASS|WARN|BLOCK>>>`

**Severity-to-result mapping:**
| Severity contributing to report | Result |
|---|---|
| Any Critical, High, or Medium | BLOCK |
| Only Low | WARN |
| None | PASS |

---

## Step 1 — Collect Changes

By default, review the **staged diff**:

```bash
git diff --cached --unified=5      # full content of staged changes
git diff --cached --name-only      # list of staged file paths
```

If the dispatcher passed an `--against <ref>` argument, the changes to review
are the diff between that ref and HEAD instead. The dispatcher communicates
this via the `AI_REVIEW_AGAINST` environment variable:

```bash
if [ -n "$AI_REVIEW_AGAINST" ]; then
  git diff "$AI_REVIEW_AGAINST" HEAD --unified=5
  git diff "$AI_REVIEW_AGAINST" HEAD --name-only
fi
```

If the relevant diff is empty, exit cleanly:
> "No changes to review. Skipping."

---

## Step 2 — Load Targeted Context (Not the Full Codebase)

Loading the entire codebase is slow and expensive. Instead, load only files
that materially affect the security assessment of the changed code.

**Load these if they exist and are not already in the diff:**

| File type | Why it matters |
|---|---|
| `**/requirements.txt`, `**/package.json`, `**/go.mod`, `**/Gemfile`, `**/pom.xml`, `**/build.gradle` | Dependency versions — supply chain risk |
| `.env.example`, `config/`, `settings.py`, `application.yml`, `application.properties` | Expected config patterns; helps identify leaked secrets |
| Auth/middleware files that the changed files import or call | Auth bypass / privilege escalation context |
| Database model files when changed files contain queries | SQL injection / data exposure context |
| Serializers, validators, or schema files related to changed API routes | Input validation context |
| Files that define roles, permissions, or ACL rules | Access control context |

**Do NOT load** test fixture files, migrations, documentation, or any file not
directly relevant to the changed code's security posture.

Limit context loading to **≤ 15 additional files**. If more would be needed,
note the limitation in the report and focus on what is available.

---

## Step 3 — Run the Review

### 3A — Mandatory: Secrets, PII, and PHI Detection

This section is **non-negotiable**. Run it on every review regardless of
project type.

**Secrets to detect:**

- Hardcoded passwords, passphrases, or credentials (including in comments)
- API keys, tokens, or bearer values matching common patterns:
  - AWS: `AKIA[0-9A-Z]{16}`
  - GitHub: `gh[pousr]_[A-Za-z0-9]{36,}`
  - Generic: high-entropy strings (≥ 32 chars) assigned to variables named `key`, `secret`, `token`, `password`, `credential`, `auth`, `api_key`, `access_key`, etc.
  - Private keys / certificates (PEM headers: `-----BEGIN`)
  - JWT tokens (`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)
  - Connection strings containing credentials (`mongodb://user:pass@`, `postgresql://user:pass@`, etc.)
  - SSH private keys
- Any secret committed in `.env`, config files, or source code (not just `.env.example`)

**PII to detect:**

- Social Security Numbers (formatted or unformatted: `\d{3}-\d{2}-\d{4}` or `\d{9}`)
- Email addresses hardcoded as real values (not placeholders like `user@example.com`)
- Real names combined with identifiers (not in placeholder/test context)
- Phone numbers (North American: `\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}`, also international patterns)
- Physical addresses with real street names, cities, and ZIP codes
- Date of birth values paired with names or IDs
- Government-issued ID numbers (passport, driver's license patterns)
- Credit card numbers (`\b(?:\d[ -]?){13,16}\b`)
- Bank account or routing numbers

**PHI to detect (HIPAA context — flag if project appears to be healthcare-related):**

- Diagnosis codes (ICD-10: `[A-Z]\d{2}(\.\d{1,4})?`) in non-lookup contexts
- Medication names paired with patient identifiers
- Lab result values associated with individual identifiers
- Any of the 18 HIPAA identifiers hardcoded with real values:
  names, dates (except year), phone, fax, email, SSN, MRN, health plan #,
  account #, certificate/license #, VIN, device serial, URL, IP, biometric,
  full-face photo, any unique identifier
- Note: flag even if values appear in test data — real PHI must never exist in source

**Severity of secrets/PII/PHI findings:**

| Finding type | Severity |
|---|---|
| Secrets / credentials / API keys | **Critical** |
| PHI (real or appears real) | **Critical** |
| PII (real, identifiable individuals) | **High** |
| Suspected PII/PHI in test data (likely synthetic but uncertain) | **Medium** |
| Patterns that resemble PII/PHI but are clearly placeholder values | **Low** |

---

### 3B — OWASP Top 10 (apply where relevant to the project)

Review the diff against each applicable OWASP category. Skip categories with
no plausible attack surface in the changed code (e.g., skip injection checks
if the diff contains only CSS). Be explicit about what was skipped and why.

**A01 — Broken Access Control**
- New routes, endpoints, or functions without authentication/authorization checks
- Changes to role or permission logic that could expand access
- Direct object references without ownership validation
- CORS policy changes that broaden allowed origins

**A02 — Cryptographic Failures**
- Use of deprecated algorithms (MD5, SHA-1, DES, RC4, ECB mode)
- Hardcoded IVs or salts
- Sensitive data transmitted over HTTP (not HTTPS)
- Weak key lengths (RSA < 2048, AES < 128)
- Missing TLS certificate validation

**A03 — Injection**
- SQL: string concatenation or f-string formatting in queries; check for ORM bypass
- Command injection: `subprocess`, `exec`, `eval`, `os.system`, `shell=True` with user input
- LDAP, XPath, NoSQL injection patterns
- Template injection (server-side)

**A04 — Insecure Design**
- Business logic flaws in changed workflows (e.g., skippable payment steps)
- Missing rate limiting on sensitive operations
- Lack of multi-factor consideration on auth flows

**A05 — Security Misconfiguration**
- Debug mode enabled in non-development configs
- Default credentials or permissive defaults
- Verbose error messages that leak stack traces or internal paths
- Overly permissive file permissions set in code

**A06 — Vulnerable and Outdated Components**
- New dependencies added in package manifests — flag any that are:
  - Typosquatted (suspiciously similar to popular packages)
  - Pinned to `*` or very loose version ranges
  - Notably outdated (if assessable from context)

**A07 — Identification and Authentication Failures**
- Session tokens with insufficient entropy or length
- Missing session invalidation on logout
- Password policies weakened in changed code
- "Remember me" tokens stored insecurely

**A08 — Software and Data Integrity Failures**
- Deserialization of untrusted data without validation
- Unsigned or unverified software update mechanisms
- CI/CD pipeline changes that could allow injection of malicious code

**A09 — Security Logging and Monitoring Failures**
- Removal of security-relevant logging
- Logging of sensitive data (passwords, tokens, PII in log statements)
- Missing audit trail for privileged operations added in this diff

**A10 — Server-Side Request Forgery (SSRF)**
- User-controlled URLs passed to HTTP clients, fetch calls, or curl
- Insufficient validation of redirect targets
- Internal service URLs exposed to user input

---

### 3C — General Security Review

- **Input validation** — Missing or bypassable validation on user-supplied data
- **Output encoding** — XSS risk from unencoded output in HTML/JS contexts
- **File handling** — Path traversal, unrestricted upload types, insecure temp files
- **Error handling** — Exceptions caught and swallowed that hide security failures
- **Race conditions** — TOCTOU issues, unprotected shared state
- **Dependency confusion** — Internal package names that could be shadowed
- **Secrets in logs** — Sensitive values passed to logging calls
- **Prototype pollution** (JS/TS) — Unsafe object merges or assignments
- **Insecure randomness** — Use of `Math.random()` or `rand()` for security purposes

---

## Step 4 — Report

Report all findings assessed as **low severity or above**. Do not report
informational findings. Critical, high, and medium findings will block the
commit. Low findings warn without blocking.

### Report Format

```
## Security Review Report
**Scope:** <Staged changes (git diff --cached) | Diff against <ref>>
**Files reviewed:** <list files>
**Context files loaded:** <list, or "None">

---

### 🔴 CRITICAL / 🟠 HIGH / 🟡 MEDIUM Findings (blocking)

#### [SEVERITY] [Category] — [Short title]
**File:** `path/to/file.py`, line(s) N–M
**Finding:** Clear explanation of what was found and why it is a risk.
**Evidence:** (for secrets/PII/PHI: show only a redacted excerpt, never the full secret)
  e.g., `api_key = "AKIA...XXXX"` (redacted)
**Remediation:** Specific, actionable steps to fix this finding.

---

### 🔵 LOW Findings (non-blocking warnings)

#### [LOW] [Category] — [Short title]
**File:** `path/to/file.py`, line(s) N–M
**Finding:** Clear explanation of what was found and why it is a risk.
**Remediation:** Specific, actionable steps to fix this finding.

---
[repeat for each finding]

---

### Summary
| Severity | Count |
|---|---|
| Critical | N |
| High | N |
| Medium | N |
| Low | N |

**Commit recommendation:**
- 🚫 BLOCK — One or more critical, high, or medium findings present. Do not commit until resolved.
- ⚠️  WARN — Low findings only. Review before committing; commit is allowed.
- ✅ PASS — No findings of any reportable severity.
```

### Severity Definitions

| Severity | Criteria | Commit impact |
|---|---|---|
| **Critical** | Secrets/credentials in code; real PHI; direct RCE or auth bypass | 🚫 Blocks |
| **High** | Real PII; significant injection risk; broken access control; crypto failure | 🚫 Blocks |
| **Medium** | Potential injection with mitigating controls; suspicious PII (likely synthetic); missing input validation on internal surface | 🚫 Blocks |
| **Low** | Minor security hygiene issues; placeholder-like PII patterns; informational hardening opportunities | ⚠️ Warns |
| **Informational** | (Do not report) | — |

### Exit Behavior

When invoked via the pre-commit hook dispatcher, the final line of output
**must** be exactly one of the following markers. The dispatcher parses this
marker to decide whether the commit may proceed:

```
<<<AI_REVIEW_RESULT:PASS>>>
<<<AI_REVIEW_RESULT:WARN>>>
<<<AI_REVIEW_RESULT:BLOCK>>>
```

- Emit `BLOCK` if any critical, high, or medium finding is present.
- Emit `WARN` if only low findings are present.
- Emit `PASS` if there are no findings at any reportable severity.

The marker must be on its own line with no surrounding text. Failure to emit
a marker causes the dispatcher to fail safe (block the commit).

---

## Notes for Reviewers

- **False positives on PII/PHI:** If values are clearly synthetic test
  fixtures (e.g., `test@example.com`, `123-45-6789` used as a placeholder),
  downgrade to low severity. When in doubt, report at medium.
- **Secrets in history:** This skill reviews the diff, not git history. If a
  secret appears to have been recently removed, note it and recommend running
  `git log -p` and tools like `trufflehog` or `git-secrets` to check history.
- **Scope limitations:** This review covers the diff and targeted context. It
  is not a substitute for a full penetration test or automated SAST scan on
  the entire codebase.
test change
test change for dispatch verification
