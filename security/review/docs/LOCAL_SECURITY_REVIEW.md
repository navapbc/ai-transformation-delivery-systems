# Local Security Review — Manual Aliases

The `code-security` and `iac-compliance` hooks are shipped **opt-in**. They are
configured with `stages: [manual]` in `.pre-commit-config.yaml`, which means
they **do not run automatically on `git commit`**. Instead, developers run them
on demand — whenever a change has security implications that warrant a local
review before pushing.

This guide sets up two shell aliases — `code-security` and
`iac-compliance` — that make those manual runs a one-word command from
anywhere inside the repository.

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
`stages: [manual]` back to `stages: [pre-commit]` in `.pre-commit-config.yaml`.

---

## Prerequisites

1. **`pre-commit` installed and the hooks present.** From a fresh clone:
   ```bash
   pre-commit install        # wires the commit-stage guard (skills-in-sync)
   scripts/sync-skills.sh     # materializes the skill files for your AI tool
   ```
   (Manual-stage hooks run via `pre-commit run --hook-stage manual` regardless
   of `pre-commit install`, but the rest of the setup above is still required.)
2. **`AI_REVIEW_TOOL` set** to `claude`, `codex`, or `copilot` — see
   `README.md`, section "AI tool selection". The dispatcher exits with a helpful
   message if it's unset.
3. **`zsh`** (these snippets are zsh; adapt for bash if needed).

---

## Add the aliases to `~/.zshrc`

Paste both blocks into `~/.zshrc`, then `source ~/.zshrc` (or open a new shell):

```zsh
# AI-assisted local security review — manual, opt-in hooks.
# Run from anywhere inside a repo that has the hooks installed.
alias code-security='
root="$(git rev-parse --show-toplevel 2>/dev/null)";
if [ -z "$root" ]; then
  echo "✗ not inside a git repository";
elif grep -q "id: code-security" "$root/.pre-commit-config.yaml" 2>/dev/null; then
  echo "▶ code-security (staged changes) — full sweep: pre-commit run --hook-stage manual code-security --all-files";
  pre-commit run --hook-stage manual code-security;
else
  echo "✗ code-security hook not configured in $root/.pre-commit-config.yaml";
fi'

alias iac-compliance='
root="$(git rev-parse --show-toplevel 2>/dev/null)";
if [ -z "$root" ]; then
  echo "✗ not inside a git repository";
elif grep -q "id: iac-compliance" "$root/.pre-commit-config.yaml" 2>/dev/null; then
  echo "▶ iac-compliance (staged IaC files) — full sweep: pre-commit run --hook-stage manual iac-compliance --all-files";
  pre-commit run --hook-stage manual iac-compliance;
else
  echo "✗ iac-compliance hook not configured in $root/.pre-commit-config.yaml";
fi'
```

What each alias does:

1. **Confirms you're in a git repo** — `git rev-parse --show-toplevel` doubles as
   the repo check (empty → not a repo) and gives the authoritative root, so the
   alias works from any subdirectory.
2. **Confirms the hook is configured** — greps the repo-root
   `.pre-commit-config.yaml` for the specific hook `id`, so it only runs a hook
   that's actually wired up (and prints a clear message otherwise).
3. **Runs it manually** — `pre-commit run --hook-stage manual <id>`. The
   `--hook-stage manual` is required: a `stages: [manual]` hook is invisible to
   a plain `pre-commit run <id>` (you'd get *"No hook with id … in stage
   pre-commit"*).

---

## Usage

```bash
code-security        # review currently staged changes
iac-compliance       # review staged IaC files (*.tf, *.yaml, etc.)
```

**Staged vs. whole repo.** By default these review the **staged** diff — the
same scope a commit-time hook would see — which is fast and usually what you
want before pushing. For a full-tree sweep, run the underlying command directly:

```bash
pre-commit run --hook-stage manual code-security --all-files
pre-commit run --hook-stage manual iac-compliance --all-files
```

> ⚠️ `--all-files` invokes the AI over the entire repository — slower and more
> costly. Use it deliberately, not as a default.

**`iac-compliance` only fires on matching files.** That hook has a file filter
(`*.tf`, `*.tfvars`, `*.bicep`, `*.yaml`, …) and `always_run: false`, so a
staged run with no matching IaC files staged will report "no files to check" and
skip. Use `--all-files` to scan IaC across the whole repo regardless of staging.

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
| `✗ <hook> not configured …` | The repo's `.pre-commit-config.yaml` doesn't declare that hook id, or you're in a different repo. |
| `No hook with id … in stage pre-commit` | You ran `pre-commit run <id>` without `--hook-stage manual`. Use the alias, or add the flag. |
| `AI_REVIEW_TOOL … not set` | Export `AI_REVIEW_TOOL=claude` (or `codex`/`copilot`); see `README.md`. |
| `pre-commit: command not found` | Install pre-commit (`brew install pre-commit` / `pip install pre-commit`) and ensure it's on the PATH your interactive shell resolves. |

---

## Related

- `README.md` — full setup, severity definitions, flags, performance tuning.
- `INSTALL.txt` — quick install, including these alias snippets.
- `docs/PR_REVIEW_SETUP.md` — PR-level review (GitHub Actions, Copilot, PATs).
