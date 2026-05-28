---
applyTo: "**/auth/**,**/authn/**,**/authz/**,**/middleware/**,**/sessions/**,**/login/**,**/oauth/**,**/saml/**,**/jwt/**,**/permissions/**,**/rbac/**,**/acl/**"
---

# Authentication / Authorization Path Instructions

When reviewing changes to authentication, session, authorization, or
access-control code, apply the `security` perspective from
`.github/copilot-instructions.md` with heightened attention to the OWASP
Top 10 categories below. The full check list is in
`.skills/code-security/SKILL.md`; read that file before reviewing changes
to any file matched by this path pattern.

## High-yield checks for auth code

### Critical-severity flags

- Auth bypass: any code path that returns success or sets a session without
  actually validating the supplied credential, token, signature, or claim.
- Hardcoded JWT signing secrets, OAuth client secrets, or SAML private keys.
  **OWASP A07:2021** + **A02:2021** (Identification and Authentication
  Failures + Cryptographic Failures).
- Remote Code Execution via deserialization of session data, tokens, or
  cookies. **OWASP A08:2021** (Software and Data Integrity Failures).
- Direct SQL queries in the authn path constructed via string concatenation
  with user-supplied input. **OWASP A03:2021** (Injection).

### High-severity flags

- **Broken Access Control (OWASP A01:2021):**
  - New routes / endpoints / functions without an authentication check.
  - New routes that check authentication but not authorization — they verify
    the user is logged in but not that the user is allowed to access the
    specific resource. Look for missing ownership/role checks.
  - Direct object references that take an ID from the request and look up
    a resource without verifying the caller owns it.
  - Changes to role / permission logic that broaden access.
  - CORS policy changes that broaden allowed origins, especially to `*`
    on credentialed endpoints.
- **Authentication Failures (OWASP A07:2021):**
  - Session tokens generated with `Math.random()`, `rand()`, or other
    non-cryptographic RNGs.
  - Session tokens with insufficient entropy (< 128 bits) or length.
  - Missing session invalidation on logout, password change, or privilege
    change.
  - Password policies weakened (length reduced, complexity removed,
    breach-list checks removed).
  - "Remember me" tokens stored as plaintext or with weak hashing.
- **Cryptographic Failures (OWASP A02:2021):**
  - Password hashing using MD5, SHA-1, SHA-256, or any unsalted hash.
    Production code must use bcrypt, scrypt, argon2, or PBKDF2.
  - JWT signing with `none` algorithm allowed (`alg: "none"` accepted).
  - JWT verification that doesn't check the signature, only decodes claims.
  - TLS certificate verification disabled (`verify=False`, `rejectUnauthorized: false`).

### Medium-severity flags

- Rate limiting absent on login, password reset, or other sensitive
  endpoints. **OWASP A04:2021** (Insecure Design).
- MFA / 2FA bypass paths (e.g., "remember device" cookies that skip MFA
  indefinitely). **OWASP A07:2021.**
- Verbose error messages on auth failures that distinguish "user not found"
  from "wrong password" (enables enumeration).
- Sensitive values (tokens, passwords, MFA codes) passed to logging calls.
  **OWASP A09:2021** (Security Logging and Monitoring Failures).

### Low-severity flags

- Session cookies missing `Secure`, `HttpOnly`, or `SameSite` flags.
- Auth-related comments with TODO/FIXME indicating known gaps.

## Things to check carefully on every diff in this path

- **Middleware order.** Auth middleware must run before route handlers.
  Verify that newly added routes pass through the auth chain.
- **Decorator coverage.** If routes are protected by decorators (e.g.,
  `@require_auth`, `@login_required`), verify every new route has one.
  Untagged routes are easy to miss in review.
- **Permission checks at the data layer.** Belt-and-braces — even if a
  route checks `current_user.is_admin`, the data layer should verify
  ownership where it can.
- **Token lifetime and refresh logic.** Long-lived tokens that don't expire,
  refresh tokens that don't rotate, or stolen-token detection that doesn't
  invalidate all sessions for the user.

## Comment formatting reminders

All comments on auth code must:

1. Use the `security(<severity>):` Conventional Comments label.
2. Cite the OWASP Top 10 category where applicable (e.g.,
   "OWASP A01:2021 – Broken Access Control").
3. When citing a missing check, name the specific check that should be added.
4. Provide a `` ```suggestion `` block when the fix replaces the lines at
   the comment's location, OR a code-fence block (`` ```python ``,
   `` ```javascript ``, etc.) when the fix is structural.
5. Never include the actual value of a secret in a comment body. Redact
   with `...XXXX` or similar.
