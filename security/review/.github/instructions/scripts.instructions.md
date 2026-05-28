---
applyTo: ".skills/**/*.sh,scripts/**/*.sh,.github/workflows/**/*.sh,**/hooks/**/*.sh"
---

# Shell Script Path Instructions

When reviewing changes to shell scripts — especially the AI-review
dispatchers and the sync utility — apply the `security` perspective from
`.github/copilot-instructions.md` with heightened attention to issues
specific to bash and pre-commit hook code. These scripts have elevated
trust: they run on every developer commit and in CI, they invoke external
tools with arguments, and a vulnerability here can degrade the entire
review system.

## High-yield checks for shell scripts

### Critical-severity flags

- **Review-bypass paths.** Anything that lets the dispatcher exit 0 (allow
  the commit) without actually running the review. Examples:
  - Catching all errors with `|| true` or `|| exit 0` that masks AI CLI
    failures (the AI failed but the dispatcher reports success).
  - Removing the fail-safe BLOCK default when the result marker is missing
    or unparseable.
  - Skipping the marker validation entirely.
- **Command injection** via unquoted user-controlled values passed to
  external commands. The dispatchers handle file paths, ref names, and
  environment variables — all of which can contain shell metacharacters.
- **Disabled `set -euo pipefail`.** All scripts in this repo must use
  `set -euo pipefail` at the top. A change that removes any of these
  flags is a critical regression.
- **Hardcoded secrets** in any script.

### High-severity flags

- **Unquoted variable expansions** that look like they should be quoted —
  especially `${file}`, `${ref}`, `${SCRIPT_DIR}`, anything from `$1..$N`,
  and anything read from `git diff`. The conventions to look for:
  - `[[ -f $file ]]` should be `[[ -f "${file}" ]]`
  - `cp $src $dest` should be `cp "${src}" "${dest}"`
  - `if grep -q $pattern $file` should be `if grep -q "${pattern}" "${file}"`
- **`eval` of any value derived from user input**, environment, or external
  command output.
- **Race conditions** between `[[ -f X ]]` checks and subsequent file
  operations (TOCTOU). Less critical for one-shot scripts but worth flagging.
- **External command output trusted without validation.** Specifically, the
  result marker parser must require an EXACT match against the expected
  marker strings — partial matches or fuzzy parsing is a critical regression.

### Medium-severity flags

- **Subshells that hide errors.** `$(command)` inside `set -e` does not
  always propagate the inner command's exit code; explicit checks (`|| rc=$?`)
  are required when the dispatcher needs to inspect what happened.
- **`echo` for user-controlled content** where `printf '%s\n'` would be
  safer (echo interprets backslash escapes on some platforms).
- **Missing `local`** on function-scoped variables — they bleed into the
  global scope and may collide with caller variables.
- **`head`/`tail`/`grep` pipelines that mask exit codes** in places where
  exit codes matter. `set -o pipefail` mitigates this, but explicit handling
  is sometimes still needed.

### Low-severity flags

- Missing shebang or wrong shebang (`#!/bin/sh` for bash-specific syntax).
- Inconsistent use of `[[ ]]` vs `[ ]` (`[[ ]]` is the project standard).
- Long lines (> 100 cols) without wrapping.
- Inconsistent quoting style.

## Things to check carefully on every diff in this path

- **The fail-safe block default.** When the AI's result marker is missing
  or unparseable, the dispatcher MUST exit non-zero (block). Any change to
  this behavior — even seemingly benign refactoring — is a critical regression.
- **The `AI_REVIEW_TOOL` validation.** Unset or invalid values must exit
  with code 2 and a clear error message that names the valid values
  (`claude | codex | copilot`).
- **The `--no-block` and `--gate` flags.** Their semantics must remain
  consistent: `--no-block` always exits 0, `--gate` makes the PR dispatcher
  exit 1 on non-APPROVE. A change that swaps or weakens these is a regression.
- **The skill-sync `--check` mode.** Must exit 1 when drift is detected and
  must NOT modify any files in `--check` mode (it is purely a verification
  command).
- **`gh api` payload construction.** The PR dispatcher constructs JSON
  payloads for the GitHub API. Any change to the construction must preserve
  proper escaping — both inside JSON strings and at the shell layer.

## Comment formatting reminders

All comments on shell scripts must:

1. Use the `security(<severity>):` Conventional Comments label. (Shell-
   script findings are security-perspective, not compliance.)
2. Be specific about which line and which behavior changes. "This script
   is dangerous" is not useful; "This change removes the marker-validation
   exit-1 path, allowing reviews with no marker to silently pass" is useful.
3. Provide a `` ```suggestion `` block when the fix is a line-level change,
   OR a `` ```bash `` block for structural changes.
