# Local Security Review — Manual Functions

The `code-security` and `iac-compliance` hooks are shipped **opt-in**. They are
configured with `stages: [manual]` in `.pre-commit-config.yaml`, which means
they **do not run automatically on `git commit`**. Instead, developers run them
on demand — whenever a change has security implications that warrant a local
review before pushing.

This guide sets up two shell **functions** — `code-security` and
`iac-compliance` — that make those reviews a one-word command from anywhere
inside the repository. By default each reviews **everything you haven't pushed
yet** (all locally-committed *and* staged changes), so it mirrors what a
reviewer would see in your PR.

---

## Why opt-in / manual?

- **Speed and focus.** AI-assisted review costs real wall-clock time and tokens.
  Running it on *every* commit taxes routine, non-security changes (docs,
  refactors, formatting). Manual invocation puts the developer in control: run
  the review when the diff actually touches auth, secrets, PII/PHI, data flows,
  or infrastructure.
- **It's a local backstop, not the only gate.** Most teams also have PR-level
  review (GitHub Actions and/or GitHub's built-in Copilot review). The local
  hooks exist so a developer can get the project's *own* security/compliance
  methodology — the skill check-lists and self-adjudication — before the code
  ever leaves the machine. GitHub's built-in Copilot review can't run that
  methodology, so the manual local run is where it actually happens.
- **No surprises.** A manual-stage hook never blocks a commit, so it can't
  wedge an unrelated commit at an inconvenient time.

To make a hook run automatically on every commit instead, change its
`stages: [manual]` to `stages: [pre-commit]` in `.pre-commit-config.yaml`. Note
that the **pre-commit stage always reviews the staged diff only** — the
"everything unpushed" scope below applies to the manual functions, not the
commit-time hook.

---

## Prerequisites

1. **The skill files are installed and synced.** From a fresh clone:
   ```bash
   scripts/sync-skills.sh      # materializes the skill files for your AI tool
   pre-commit install          # wires the commit-stage skills-in-sync guard
   ```
   (The functions call the dispatcher directly and don't need `pre-commit`, but
   the sync step is still required so the AI tool can read the skills.)
2. **`AI_REVIEW_TOOL` set** to `claude`, `codex`, or `copilot` — see
   `README.md`, section "AI tool selection". The dispatcher exits with a helpful
   message if it's unset.
3. **`zsh`** (these snippets are zsh; adapt for bash if needed).

---

## Add the functions to `~/.zshrc`

Paste both blocks into `~/.zshrc`, then `source ~/.zshrc` (or open a new shell):

```zsh
# AI-assisted local security review — manual, opt-in.
#   <no arg>  → review everything not yet pushed (committed + staged)
#   <ref>     → review the committed range <ref>..HEAD
code-security() {
  local root disp
  root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "✗ not inside a git repository"; return 1; }
  disp="$root/.skills/code-security/scripts/code-security-hook-dispatcher.sh"
  [ -x "$disp" ] \
    || { echo "✗ code-security dispatcher not found/executable: $disp"; return 1; }
  if [ -n "$1" ]; then
    echo "▶ code-security: ${1}..HEAD (committed range)"
    "$disp" --against "$1"
  else
    echo "▶ code-security: all not-yet-pushed changes (committed + staged)"
    "$disp" --unpushed
  fi
}

iac-compliance() {
  local root disp
  root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "✗ not inside a git repository"; return 1; }
  disp="$root/.skills/iac-compliance/scripts/iac-compliance-hook-dispatcher.sh"
  [ -x "$disp" ] \
    || { echo "✗ iac-compliance dispatcher not found/executable: $disp"; return 1; }
  if [ -n "$1" ]; then
    echo "▶ iac-compliance: ${1}..HEAD (committed range)"
    "$disp" --against "$1"
  else
    echo "▶ iac-compliance: all not-yet-pushed changes (committed + staged)"
    "$disp" --unpushed
  fi
}
```

What each function does:

1. **Confirms you're in a git repo** — `git rev-parse --show-toplevel` doubles as
   the repo check (empty → not a repo) and gives the authoritative root, so the
   function works from any subdirectory.
2. **Locates the dispatcher** at the repo root and confirms it's executable.
3. **Runs the review** by calling the dispatcher directly:
   - **no argument** → `--unpushed`: everything not yet pushed (all committed +
     staged changes). The base is your branch's upstream, falling back to the
     merge-base with the remote default branch. If neither can be determined
     (e.g. a brand-new branch with no remote), it errors and asks for an explicit
     ref rather than silently reviewing less than you expect.
   - **a ref** → `--against <ref>`: the committed range `<ref>..HEAD`.

---

## Usage

```bash
code-security                 # everything unpushed: committed + staged
code-security origin/main     # the committed range origin/main..HEAD
code-security HEAD~1          # just the last commit

iac-compliance                # same, for infrastructure-as-code
```

**Scope details.**

- `--unpushed` (the default) reviews **committed + staged** changes — it
  **excludes unstaged working-tree edits**. Commit or `git add` work-in-progress
  to include it.
- `iac-compliance` only reports on infrastructure files (`*.tf`, `*.tfvars`,
  `*.bicep`, `*.yaml`, …); non-IaC files in the range are ignored.
- Need a **staged-only** spot check without committing? That's exactly the
  commit-time hook's scope — run it on the manual stage:
  `pre-commit run --hook-stage manual code-security` (reviews `git diff --cached`).

---

## When to run

Run a local review when your change has plausible security or compliance
implications, for example:

- Touching authentication, authorization, sessions, or tokens.
- Handling secrets, credentials, PII, or PHI.
- New or changed data flows, deserialization, subprocess/shell calls, SQL.
- Editing infrastructure-as-code (`iac-compliance`).

For routine, non-security changes there's no need to run them — that's the point
of opt-in.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `✗ not inside a git repository` | You're not in a git work tree. `cd` into the repo. |
| `✗ <skill> dispatcher not found/executable` | The skills aren't installed at the repo root, or the script lost its `+x` bit. Re-install / `chmod +x`. |
| `--unpushed: couldn't determine what's been pushed` | No upstream and no remote default branch (e.g. brand-new branch, no remote). Pass an explicit base: `code-security origin/main` or `code-security <ref>`. |
| `AI_REVIEW_TOOL … not set` | Export `AI_REVIEW_TOOL=claude` (or `codex`/`copilot`); see `README.md`. |
| Review seems to miss recent edits | `--unpushed` excludes *unstaged* changes. `git add` or commit them first. |

---

## Related

- `README.md` — full setup, severity definitions, flags (`--unpushed`,
  `--against`, …), performance tuning.
- `INSTALL.txt` — quick install, including these function snippets.
- `docs/PR_REVIEW_SETUP.md` — PR-level review (GitHub Actions, Copilot, PATs).
