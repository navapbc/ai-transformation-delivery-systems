#!/usr/bin/env bash
# .skills/codebase-audit/scripts/codebase-audit-dispatcher.sh
#
# Codebase-audit dispatcher. Enumerates directories, filters out
# known-skippable paths, then invokes the AI once per directory with the
# codebase-audit skill. Writes one report per batch to audit-reports/.
#
# This dispatcher differs significantly from the diff-mode ones:
#
#   1. It does not use a git diff. The scope of each AI invocation is a
#      directory's worth of files at rest.
#   2. It loops, invoking the AI multiple times (once per directory).
#   3. It supports resume mode — re-running after a failure picks up where
#      the previous run left off by skipping directories whose reports
#      already exist.
#   4. It is exit-code-agnostic by default — audit findings don't "fail"
#      anything; they're reported. The --gate flag converts FINDINGS into
#      exit 1 for CI use.
#
# Usage:
#   codebase-audit-dispatcher.sh                          # full audit, default settings
#   codebase-audit-dispatcher.sh --min-severity high      # only Critical+High
#   codebase-audit-dispatcher.sh --scope src/             # only audit src/ tree
#   codebase-audit-dispatcher.sh --scope src/ --scope infra/   # repeatable: audit both
#   codebase-audit-dispatcher.sh --sarif                  # also emit SARIF
#   codebase-audit-dispatcher.sh --force                  # re-audit even if reports exist
#   codebase-audit-dispatcher.sh --gate                   # exit 1 if any findings
#   codebase-audit-dispatcher.sh --dry-run                # list batches; no AI calls
#   codebase-audit-dispatcher.sh --list-batches           # print the batch plan, no execution
#   codebase-audit-dispatcher.sh --no-adjudicate          # skip the second-opinion pass
#   codebase-audit-dispatcher.sh --jobs 6                 # run 6 batches concurrently
#
# Parallelism (--jobs N / AUDIT_JOBS):
#   Batches are independent — each scopes one directory and writes its own
#   report — so execution fans out across N worker processes (default 4) while
#   batch PLANNING stays single-threaded and deterministic, keeping run-to-run
#   reports comparable. Each worker runs the same configured AI_REVIEW_TOOL.
#   --jobs 1 forces the original serial path. The throughput ceiling is the
#   vendor's rate limit; raise --jobs cautiously to avoid 429s.
#
# Adjudication (second opinion):
#   A directory that reports findings triggers an independent adjudication pass
#   (finding-adjudication skill) that confirms / dismisses / downgrades each
#   finding before its report, counts, index, and SARIF are written. Clean
#   directories are final and incur no second call. Controlled by AI_ADJUDICATION
#   (default on; --no-adjudicate or AI_ADJUDICATION=0 disables) and the optional
#   AI_ADJUDICATION_MODEL (a different model on the same CLI for the second pass).
#
# Output:
#   audit-reports/<directory>.md         (one per batched directory; slashes
#                                         in the path are replaced with __)
#   audit-reports/_INDEX.md              (cross-batch summary, generated last)
#   audit-reports/_findings.sarif        (only when --sarif is set)
#
# Required environment:
#   AI_REVIEW_TOOL          claude | codex | copilot
#
# Optional environment:
#   AUDIT_JOBS              Number of batches to process concurrently (default 4;
#                           overridden by --jobs). 1 = serial.

set -euo pipefail

# ── Resolve repository root and shared library ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
LIB_PATH="${REPO_ROOT}/.skills/_lib/ai-review-dispatch.sh"
# Absolute path to this script — re-invoked as a single-batch worker during
# parallel fan-out (see audit::worker_main / --__audit-one).
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${LIB_PATH}" ]]; then
  echo "ERROR: shared dispatch library not found at: ${LIB_PATH}" >&2
  echo "       This file is required. Re-install the skills (see README.md)." >&2
  exit 1
fi

cd "${REPO_ROOT}"

# ── Skill identity ──────────────────────────────────────────────────────────
SKILL_NAME="codebase-audit"
SKILL_HUMAN_NAME="Codebase Audit (security + compliance, full repo)"
SKILL_PATH_CANONICAL=".skills/codebase-audit/SKILL.md"

# ── Defaults ─────────────────────────────────────────────────────────────────
MIN_SEVERITY="low"
# Scope pathspecs. Repeatable: each --scope appends. Empty = whole repo.
SCOPE_ROOTS=()
EMIT_SARIF=0
FORCE=0
GATE_MODE=0
DRY_RUN=0
LIST_BATCHES_ONLY=0
NO_BLOCK=0
OUTPUT_DIR="audit-reports"
# Concurrency: env default (validated below), overridable by --jobs.
JOBS="${AUDIT_JOBS:-4}"

# ── Worker-mode detection ───────────────────────────────────────────────────
# When invoked by the parent's parallel fan-out as `--__audit-one <record>`,
# this process audits exactly one batch and exits. Its config arrives via the
# AUDIT_* environment variables the parent exports before fan-out, so the normal
# flag parser below is skipped. (Internal contract — not a public flag.)
AUDIT_WORKER_MODE=0
WORKER_RECORD=""
if [[ "${1:-}" == "--__audit-one" ]]; then
  AUDIT_WORKER_MODE=1
  WORKER_RECORD="${2:-}"
  MIN_SEVERITY="${AUDIT_MIN_SEVERITY:-${MIN_SEVERITY}}"
  EMIT_SARIF="${AUDIT_EMIT_SARIF:-${EMIT_SARIF}}"
  OUTPUT_DIR="${AUDIT_OUTPUT_DIR:-${OUTPUT_DIR}}"
fi

# ── JOBS validation ─────────────────────────────────────────────────────────
audit::validate_jobs() {
  if ! [[ "${JOBS}" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
    echo "ERROR: --jobs / AUDIT_JOBS must be a positive integer (got '${JOBS}')." >&2
    exit 2
  fi
}

# ── Arg parsing ─────────────────────────────────────────────────────────────
while (( AUDIT_WORKER_MODE == 0 )) && [[ $# -gt 0 ]]; do
  case "$1" in
    --min-severity)
      case "${2:-}" in
        critical|high|medium|low) MIN_SEVERITY="$2"; shift 2 ;;
        *) echo "ERROR: --min-severity must be one of: critical | high | medium | low" >&2; exit 2 ;;
      esac
      ;;
    --min-severity=*)
      MIN_SEVERITY="${1#*=}"
      case "${MIN_SEVERITY}" in
        critical|high|medium|low) ;;
        *) echo "ERROR: --min-severity must be one of: critical | high | medium | low" >&2; exit 2 ;;
      esac
      shift
      ;;
    --scope)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --scope requires a path argument." >&2; exit 2
      fi
      SCOPE_ROOTS+=("$2"); shift 2 ;;
    --scope=*)
      SCOPE_ROOTS+=("${1#*=}"); shift ;;
    --sarif)
      EMIT_SARIF=1; shift ;;
    --force)
      FORCE=1; shift ;;
    --gate)
      GATE_MODE=1; shift ;;
    -n|--dry-run)
      DRY_RUN=1; shift ;;
    --list-batches)
      LIST_BATCHES_ONLY=1; shift ;;
    --no-block)
      NO_BLOCK=1; shift ;;
    --no-adjudicate)
      AI_REVIEW_NO_ADJUDICATE=1; shift ;;
    --jobs)
      JOBS="${2:-}"; shift 2 ;;
    --jobs=*)
      JOBS="${1#*=}"; shift ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"; shift ;;
    -h|--help)
      # Print the leading comment block (everything before `set -euo pipefail`).
      sed -n '3,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "       Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ── Source shared library ──────────────────────────────────────────────────
# shellcheck source=../../_lib/ai-review-dispatch.sh
source "${LIB_PATH}"

audit::validate_jobs

# AI_REVIEW_TOOL is resolved at the start of main() (and worker_main()) rather
# than here, so a single resolution log line is printed per process.

# ── Skip patterns (directories never audited) ──────────────────────────────
# Anchored at any depth — applied to repo-relative paths.
SKIP_DIRNAMES=(
  node_modules
  .venv venv env .env
  vendor
  target dist build out
  __pycache__ .pytest_cache .mypy_cache .ruff_cache
  .next .nuxt .svelte-kit
  coverage .coverage htmlcov
  .git
  .terraform
  .gradle
  .idea .vscode
  bower_components
  .cache .parcel-cache
  .DS_Store
  # Audit output itself.
  audit-reports
  # Derived AI-tool skill directories (gitignored anyway, but in case a user
  # runs the audit on a worktree where they've materialized). The canonical
  # .skills/ IS in scope — only the per-tool mirrors are skipped.
  .claude .codex
)
# Additional path-prefix patterns (matched as path components in sequence).
SKIP_PATH_PREFIXES=(
  ".github/copilot/skills"
)

# ── Build the batch plan ───────────────────────────────────────────────────
# Strategy: every directory containing at least one reviewable file is a batch.
# We walk `git ls-files` (so we audit what's tracked, not what's gitignored),
# group by directory, and apply the skip rules.

audit::list_files() {
  # `git ls-files -- A B C` accepts multiple pathspecs and de-duplicates files
  # that match more than one, so overlapping --scope values are harmless.
  if (( ${#SCOPE_ROOTS[@]} > 0 )); then
    git -C "${REPO_ROOT}" ls-files -- "${SCOPE_ROOTS[@]}"
  else
    git -C "${REPO_ROOT}" ls-files
  fi
}

# Human-readable scope for logs and the index header.
audit::scope_display() {
  if (( ${#SCOPE_ROOTS[@]} == 0 )); then
    printf '<entire repo>'
  else
    local IFS=', '
    printf '%s' "${SCOPE_ROOTS[*]}"
  fi
}

audit::is_skippable_path() {
  local path="$1"
  # Path-prefix match (handles multi-component prefixes like
  # .github/copilot/skills which can't be checked component-by-component).
  local prefix
  for prefix in "${SKIP_PATH_PREFIXES[@]}"; do
    if [[ "${path}" == "${prefix}"/* ]] || [[ "${path}" == "${prefix}" ]]; then
      return 0
    fi
  done
  # Component-wise match.
  local part
  IFS='/' read -ra parts <<< "${path}"
  for part in "${parts[@]}"; do
    for skip in "${SKIP_DIRNAMES[@]}"; do
      if [[ "${part}" == "${skip}" ]]; then
        return 0
      fi
    done
  done
  return 1
}

audit::is_reviewable_extension() {
  # Returns 0 (true) for files we want to audit; 1 for binaries / lock files.
  local path="$1"
  local base
  base="$(basename "${path}")"

  # Lock files — skip
  case "${base}" in
    package-lock.json|yarn.lock|pnpm-lock.yaml|poetry.lock|Pipfile.lock|\
    Cargo.lock|Gemfile.lock|composer.lock|go.sum|*.lock)
      return 1
      ;;
  esac

  # Binary-by-extension — skip
  # (lowercase the path; bash 3.2 has no ${var,,} expansion)
  local lower
  lower="$(printf '%s' "${path}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.svg|*.webp|*.bmp|*.tiff|\
    *.mp3|*.mp4|*.mov|*.avi|*.webm|*.ogg|*.wav|\
    *.pdf|*.zip|*.tar|*.tar.gz|*.tgz|*.gz|*.bz2|*.xz|*.7z|*.rar|\
    *.woff|*.woff2|*.ttf|*.otf|*.eot|\
    *.so|*.dylib|*.dll|*.exe|*.bin|*.o|*.a|\
    *.class|*.jar|*.war|*.pyc|*.pyo|\
    *.db|*.sqlite|*.sqlite3)
      return 1
      ;;
  esac

  return 0
}

audit::plan_batches() {
  # Emit one line per batch: <dir>\t<file>|<file>|...
  #
  # bash 3.2 compatible: macOS ships bash 3.2, which has no associative
  # arrays or `mapfile`. Instead of accumulating files into a dir-keyed map,
  # we emit <dir>\t<file> pairs, sort by directory (a tab-led sort groups
  # each directory's files together), and coalesce adjacent rows with awk.
  local file dir
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if audit::is_skippable_path "${file}"; then continue; fi
    if ! audit::is_reviewable_extension "${file}"; then continue; fi
    dir="$(dirname "${file}")"
    [[ "${dir}" == "." ]] && dir="(root)"
    printf '%s\t%s\n' "${dir}" "${file}"
  done < <(audit::list_files) | LC_ALL=C sort | awk -F'\t' '
    {
      if ($1 != cur) {
        if (cur != "") { print cur "\t" files }
        cur = $1; files = $2
      } else {
        files = files "|" $2
      }
    }
    END { if (cur != "") print cur "\t" files }
  '
}

# ── Output path helper ──────────────────────────────────────────────────────
audit::report_path_for_dir() {
  local dir="$1"
  if [[ "${dir}" == "(root)" ]]; then
    printf '%s/_root.md\n' "${OUTPUT_DIR}"
  else
    # Slashes → double underscore to keep flat filenames safe.
    local safe="${dir//\//__}"
    printf '%s/%s.md\n' "${OUTPUT_DIR}" "${safe}"
  fi
}

# ── Per-batch invocation ────────────────────────────────────────────────────
audit::prompt_for_batch() {
  local dir="$1"
  local files_pipe="$2"

  # Convert pipe-separated files back to newline-separated.
  local files_nl
  files_nl="$(echo "${files_pipe}" | tr '|' '\n' | grep -v '^$' || true)"
  local count
  count="$(printf '%s\n' "${files_nl}" | wc -l | tr -d ' ')"

  cat <<PROMPT
You have access to the codebase-audit skill. The skill's full instructions
are in this repository at:

  .skills/codebase-audit/SKILL.md

You will additionally need to read the perspective skills:

  .skills/code-security/SKILL.md      (security perspective)
  .skills/iac-compliance/SKILL.md     (compliance perspective)

You are auditing one directory's worth of files. Follow the codebase-audit
skill's procedure exactly:

  - AUDIT_SCOPE_DIR:       ${dir}
  - AUDIT_MIN_SEVERITY:    ${MIN_SEVERITY}
  - AUDIT_EMIT_SARIF:      ${EMIT_SARIF}
  - AUDIT_REPO_ROOT:       ${REPO_ROOT}

The ${count} file(s) in scope:

${files_nl}

Read every file in scope, load up to 20 context files per the rules in
codebase-audit/SKILL.md (Step 2), apply both perspectives, and emit a
per-directory report in the exact markdown structure documented in
codebase-audit/SKILL.md Step 5.

After the report:
  - If AUDIT_EMIT_SARIF=1, emit the SARIF block per Step 7.
  - End with the result marker per Step 6:
      <<<AI_REVIEW_RESULT:CLEAN>>>      (if zero findings ≥ ${MIN_SEVERITY})
      <<<AI_REVIEW_RESULT:FINDINGS>>>   (if any findings ≥ ${MIN_SEVERITY})

Honor the severity threshold strictly: findings below ${MIN_SEVERITY} must
not appear in the report — not in the body, not in the summary table.
PROMPT
}

# Override the library's prompt-builder by writing the per-batch prompt to
# stdin of the AI CLI. We bypass ai_review::invoke_ai because we need a
# different prompt per call. Pattern: build the prompt, pipe to the CLI.

audit::invoke_for_batch() {
  local dir="$1"
  local files_pipe="$2"
  local prompt
  prompt="$(audit::prompt_for_batch "${dir}" "${files_pipe}")"

  case "${AI_REVIEW_TOOL_RESOLVED}" in
    claude)
      printf '%s' "${prompt}" | claude -p --output-format text
      ;;
    codex)
      printf '%s' "${prompt}" | codex exec --sandbox read-only --skip-git-repo-check -
      ;;
    copilot)
      printf '%s' "${prompt}" | copilot -p -
      ;;
    *)
      echo "ERROR: unknown AI tool: ${AI_REVIEW_TOOL_RESOLVED}" >&2
      exit 1
      ;;
  esac
}

# ── Index and SARIF assembly ────────────────────────────────────────────────
audit::extract_sarif() {
  local input="$1"
  echo "${input}" | awk '
    /<!-- AUDIT_SARIF_BEGIN -->/ { capturing=1; next }
    /<!-- AUDIT_SARIF_END -->/   { capturing=0; next }
    capturing { print }
  '
}

audit::parse_finding_counts() {
  # Reads a report on stdin; emits CRIT HIGH MED LOW (whitespace-separated).
  # Looks for the markdown summary table. Tolerant of either pipe-spaced
  # or compact formats.
  awk '
    /^\| *Critical/ { gsub(/[|]/," "); print "CRIT", $2+$3; found_crit=1 }
    /^\| *High/     { gsub(/[|]/," "); print "HIGH", $2+$3; found_high=1 }
    /^\| *Medium/   { gsub(/[|]/," "); print "MED",  $2+$3; found_med=1 }
    /^\| *Low/      { gsub(/[|]/," "); print "LOW",  $2+$3; found_low=1 }
  '
}

audit::write_index() {
  local index_path="${OUTPUT_DIR}/_INDEX.md"
  local total_crit=0 total_high=0 total_med=0 total_low=0
  local total_findings=0
  # findings_data: one "<sortkey>\t<markdown row>" line per directory that
  # has findings. clean_list: a markdown bullet per clean directory.
  local findings_data=""
  local clean_list=""
  local findings_count=0 clean_count=0 audited_count=0

  # Match dotfile reports too: a directory whose path starts with "." (e.g. the
  # canonical ".skills/", which is in scope) maps to a report filename beginning
  # with "." (slashes → "__"). Without dotglob the plain "*.md" glob skips those,
  # so their findings would be written to disk but silently dropped from the
  # index. nullglob keeps the loop from running once on a literal "*.md" when the
  # output dir is empty. Save and restore so we don't leak the setting.
  # ('shopt -p' exits non-zero when an option is unset, so guard with || true to
  # avoid tripping 'set -e'; it still prints the restore commands to stdout.)
  local _dotglob_was; _dotglob_was="$(shopt -p dotglob nullglob || true)"
  shopt -s dotglob nullglob
  for report in "${OUTPUT_DIR}"/*.md; do
    [[ -f "${report}" ]] || continue
    local base
    base="$(basename "${report}" .md)"
    [[ "${base}" == "_INDEX" ]] && continue
    audited_count=$(( audited_count + 1 ))

    local crit=0 high=0 med=0 low=0
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      local key val
      key="$(awk '{print $1}' <<< "${line}")"
      val="$(awk '{print $2}' <<< "${line}")"
      case "${key}" in
        CRIT) crit="${val:-0}" ;;
        HIGH) high="${val:-0}" ;;
        MED)  med="${val:-0}" ;;
        LOW)  low="${val:-0}" ;;
      esac
    done < <(audit::parse_finding_counts < "${report}")

    local subtotal=$(( crit + high + med + low ))
    total_crit=$(( total_crit + crit ))
    total_high=$(( total_high + high ))
    total_med=$(( total_med + med ))
    total_low=$(( total_low + low ))
    total_findings=$(( total_findings + subtotal ))

    # Convert filename back to directory representation for the index.
    # (Use //__// not //__/\/ — the escaped form leaks a literal backslash
    # under bash 3.2, which then renders inside the markdown code span.)
    local dir_repr="${base//__//}"
    [[ "${dir_repr}" == "_root" ]] && dir_repr="(repo root)"

    if (( subtotal > 0 )); then
      findings_count=$(( findings_count + 1 ))
      # Sort key: zero-padded severities so a plain reverse sort orders the
      # table worst-first — by Critical, then High, Medium, Low.
      local sortkey
      sortkey="$(printf '%05d%05d%05d%05d' "${crit}" "${high}" "${med}" "${low}")"
      # The link targets the report's Findings section (#findings) so a click
      # jumps straight to the findings, not the report's summary header.
      findings_data+="${sortkey}"$'\t'"| [\`${dir_repr}\`](./${base}.md#findings) | ${crit} | ${high} | ${med} | ${low} | ${subtotal} |"$'\n'
    else
      clean_count=$(( clean_count + 1 ))
      clean_list+="- \`${dir_repr}\`"$'\n'
    fi
  done
  eval "${_dotglob_was}"   # restore dotglob/nullglob to their prior state

  # Sort the findings rows worst-first and strip the sort key.
  local findings_rows=""
  if [[ -n "${findings_data}" ]]; then
    findings_rows="$(printf '%s' "${findings_data}" | LC_ALL=C sort -r | cut -f2-)"
  fi

  # Build the findings section (a worst-first table, or a clean-bill note).
  local findings_section=""
  if (( findings_count > 0 )); then
    findings_section="## ⚠️  Directories with findings (${findings_count})

Sorted worst-first — by Critical, then High, Medium, Low. Each directory
links straight to its findings.

| Directory | Critical | High | Medium | Low | Total |
|---|---:|---:|---:|---:|---:|
${findings_rows}
| **Totals** | **${total_crit}** | **${total_high}** | **${total_med}** | **${total_low}** | **${total_findings}** |"
  else
    findings_section="## ✅  No findings

No findings at or above the **${MIN_SEVERITY}** threshold across the
${audited_count} audited directories. Nothing to triage."
  fi

  # Publish the tallies as globals so main() can report the summary and decide
  # the --gate exit code after a parallel fan-out (where workers can't return
  # counts to the parent through the shell).
  AUDIT_INDEX_FINDINGS_COUNT="${findings_count}"
  AUDIT_INDEX_AUDITED_COUNT="${audited_count}"

  # Build the collapsed clean-directories section (omitted if none).
  local clean_section=""
  if (( clean_count > 0 )); then
    clean_section="## Clean directories (${clean_count})

<details>
<summary>${clean_count} directories had no findings at or above the threshold — expand to list</summary>

${clean_list}
</details>"
  fi

  cat > "${index_path}" <<EOF
# Audit Index

**Date generated:**      $(date -u +"%Y-%m-%d %H:%M UTC")
**AI tool:**             ${AI_REVIEW_TOOL_RESOLVED}
**Min severity:**        ${MIN_SEVERITY}
**Scope:**               $(audit::scope_display)
**Directories audited:** ${audited_count}  (${findings_count} with findings, ${clean_count} clean)

${findings_section}

## How to read this audit

The table above lists **only** directories with findings, worst-first; the
${clean_count} clean directories are collapsed at the bottom of this file so
they stay out of the way. Findings below the threshold (${MIN_SEVERITY})
were filtered out and appear in no report.

Recommended triage order:

1. **All Critical findings, across all directories** — these need same-day
   attention. Hardcoded secrets, exposed PHI, auth bypasses, and similar
   should not remain in the codebase.
2. **High findings in security-sensitive directories** — auth, payment
   processing, IaC root modules. These are the next 1–2 sprint priorities.
3. **High findings in less-sensitive directories** — quarter-level
   remediation backlog.
4. **Medium and Low findings** — review for patterns; a single recurring
   Medium across many files may indicate a systemic gap worth a focused
   improvement project.

${clean_section}
EOF
}

audit::write_sarif() {
  local sarif_path="${OUTPUT_DIR}/_findings.sarif"
  # Use Python to merge per-batch SARIF objects. We expect each batch to
  # have emitted a self-contained SARIF document; we coalesce their .runs[].
  if ! command -v python3 &>/dev/null; then
    ai_review::warn "python3 unavailable; skipping SARIF merge."
    return 0
  fi

  python3 - "${OUTPUT_DIR}" "${sarif_path}" <<'PY'
import json, sys, os, glob

out_dir = sys.argv[1]
out_path = sys.argv[2]
merged = {
    "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/a560296ca8c921f3bdb8d4a8db57ab83dae968a7/sarif-2.1/schema/sarif-schema-2.1.0.json",
    "version": "2.1.0",
    "runs": [],
}
for path in sorted(glob.glob(os.path.join(out_dir, "_sarif_*.json"))):
    try:
        with open(path) as f:
            doc = json.load(f)
        for run in doc.get("runs", []):
            merged["runs"].append(run)
    except Exception as e:
        print(f"WARN: could not merge {path}: {e}", file=sys.stderr)

with open(out_path, "w") as f:
    json.dump(merged, f, indent=2)
PY
}

# ── Per-batch processing ────────────────────────────────────────────────────
# Audits exactly one directory batch and writes its report (and per-batch SARIF
# temp, in SARIF mode). This is the unit of work that the serial loop calls
# directly and that the parallel fan-out re-invokes once per worker. It writes
# only its own uniquely-named output files, so concurrent calls never contend.
#
# Returns 0 when a report was written (clean OR findings); non-zero only when the
# AI invocation itself failed — in which case NO report is written, so resume
# mode retries that directory on the next run. Tallies are derived from the
# written reports afterward (audit::write_index), not returned from here, so this
# works identically whether called in-process or in a separate worker process.
audit::process_one_batch() {
  local dir="$1"
  local files_pipe="$2"
  local report_path
  report_path="$(audit::report_path_for_dir "${dir}")"

  ai_review::info "Auditing ${dir}..."

  local output rc=0
  output="$(audit::invoke_for_batch "${dir}" "${files_pipe}")" || rc=$?
  if (( rc != 0 )); then
    ai_review::err "[${dir}] AI invocation failed (rc=${rc}); no report written (resume will retry)."
    return 1
  fi

  # First-pass result marker for this batch.
  local marker
  marker="$(printf '%s\n' "${output}" | grep -oE '<<<AI_REVIEW_RESULT:(CLEAN|FINDINGS)>>>' | head -1 || true)"

  # Independent second-opinion adjudication. Runs only on batches that
  # reported findings, only when enabled — CLEAN batches are final and incur
  # no second AI call (cost scales with findings, not directory count). The
  # adjudicated output replaces the first-pass output, so the written report,
  # severity counts, _INDEX.md, and SARIF all reflect the confirmed findings.
  # Default ON for the audit (the explicit `1`): it's a slow batch job where
  # false-positive reduction is worth a cheap extra pass. (Pre-commit defaults
  # this OFF; both still honor an explicit AI_ADJUDICATION / --no-adjudicate.)
  if [[ "${marker}" == "<<<AI_REVIEW_RESULT:FINDINGS>>>" ]] && ai_review::adjudication_enabled 1; then
    ai_review::info "    [${dir}] findings — running adjudication (second opinion)${AI_ADJUDICATION_MODEL:+ via model ${AI_ADJUDICATION_MODEL}}..."
    local adj_output adj_rc=0 adj_marker=""
    adj_output="$(ai_review::adjudicate "${output}" "audit")" || adj_rc=$?
    if (( adj_rc == 0 )); then
      adj_marker="$(printf '%s\n' "${adj_output}" | grep -oE '<<<AI_REVIEW_RESULT:(CLEAN|FINDINGS)>>>' | head -1 || true)"
    fi
    if (( adj_rc != 0 )) || [[ -z "${adj_marker}" ]]; then
      ai_review::warn "    [${dir}] adjudication unavailable/unparseable; keeping first-pass findings."
    else
      output="${adj_output}"
      marker="${adj_marker}"
    fi
  fi

  # Strip the result marker from the report body (the dispatcher tracks
  # it, but the markdown report shouldn't show it).
  local body
  body="$(printf '%s\n' "${output}" | sed -E '/^<<<AI_REVIEW_RESULT:(CLEAN|FINDINGS)>>>$/d')"

  # Also strip the SARIF block if present (we save it separately).
  body="$(printf '%s\n' "${body}" | awk '
    /<!-- AUDIT_SARIF_BEGIN -->/ { in_sarif=1; next }
    /<!-- AUDIT_SARIF_END -->/   { in_sarif=0; next }
    !in_sarif { print }
  ')"

  # Write the markdown report.
  printf '%s\n' "${body}" > "${report_path}"

  # Save SARIF block (per-batch) if SARIF mode is on.
  if (( EMIT_SARIF == 1 )); then
    local sarif_body
    sarif_body="$(audit::extract_sarif "${output}")"
    if [[ -n "${sarif_body}" ]]; then
      local safe="${dir//\//__}"
      [[ "${dir}" == "(root)" ]] && safe="_root"
      printf '%s\n' "${sarif_body}" > "${OUTPUT_DIR}/_sarif_${safe}.json"
    fi
  fi

  case "${marker}" in
    "<<<AI_REVIEW_RESULT:FINDINGS>>>")
      ai_review::log "    [${dir}] → findings reported in ${report_path}" ;;
    "<<<AI_REVIEW_RESULT:CLEAN>>>")
      ai_review::log "    [${dir}] → clean (no findings ≥ ${MIN_SEVERITY})" ;;
    *)
      ai_review::warn "    [${dir}] → could not parse result marker; report saved anyway" ;;
  esac

  return 0
}

# ── Main audit loop ─────────────────────────────────────────────────────────
main() {
  # Resolve AI_REVIEW_TOOL (lib provides validation + error message).
  ai_review::resolve_tool

  ai_review::info "Codebase audit — ${SKILL_HUMAN_NAME}"
  ai_review::log  "  AI tool:        ${AI_REVIEW_TOOL_RESOLVED}"
  ai_review::log  "  Min severity:   ${MIN_SEVERITY}"
  ai_review::log  "  Scope:          $(audit::scope_display)"
  ai_review::log  "  Output dir:     ${OUTPUT_DIR}"
  ai_review::log  "  Emit SARIF:     $((EMIT_SARIF))"
  ai_review::log  "  Resume mode:    $((1 - FORCE))   (skip dirs with existing reports)"
  ai_review::log  "  Concurrency:    ${JOBS} $( (( JOBS > 1 )) && echo "(parallel)" || echo "(serial)" )"

  mkdir -p "${OUTPUT_DIR}"

  # Build the batch plan.
  # (bash 3.2 has no `mapfile`; read the lines into the array by hand.)
  local -a batches=()
  local _batch_line
  while IFS= read -r _batch_line; do
    [[ -z "${_batch_line}" ]] && continue
    batches+=("${_batch_line}")
  done < <(audit::plan_batches)

  if (( ${#batches[@]} == 0 )); then
    ai_review::warn "No reviewable directories found under $(audit::scope_display)."
    exit 0
  fi

  ai_review::log  "  Batches:        ${#batches[@]}"
  ai_review::log  "────────────────────────────────────────────────────────────"

  if (( LIST_BATCHES_ONLY == 1 )); then
    ai_review::info "Batch plan:"
    for line in "${batches[@]}"; do
      local dir="${line%%$'\t'*}"
      local files_pipe="${line#*$'\t'}"
      local n
      n="$(echo "${files_pipe}" | tr '|' '\n' | grep -cv '^$' || true)"
      printf '  %-50s %d files\n' "${dir}" "${n}"
    done
    exit 0
  fi

  if (( DRY_RUN == 1 )); then
    ai_review::info "DRY-RUN — would invoke AI for the batches above."
    exit 0
  fi

  # Resolve the work list. Batch planning (above) is deterministic and
  # single-threaded; here we apply resume mode — dropping directories whose
  # reports already exist (unless --force) — so workers only get real work.
  local -a to_run=()
  local skipped=0
  local line
  for line in "${batches[@]}"; do
    local dir="${line%%$'\t'*}"
    local report_path
    report_path="$(audit::report_path_for_dir "${dir}")"
    if [[ -f "${report_path}" ]] && (( FORCE == 0 )); then
      ai_review::log "SKIP ${dir} (report exists — use --force to re-audit)"
      skipped=$(( skipped + 1 ))
      continue
    fi
    to_run+=("${line}")
  done

  local exit_code=0
  local dispatched=${#to_run[@]}

  if (( dispatched > 0 )); then
    if (( JOBS <= 1 )); then
      # Serial path — identical behavior to the original loop.
      for line in "${to_run[@]}"; do
        local dir="${line%%$'\t'*}"
        local files_pipe="${line#*$'\t'}"
        audit::process_one_batch "${dir}" "${files_pipe}" || exit_code=1
      done
    else
      # Parallel path — fan out across JOBS worker processes. Each worker
      # re-invokes this script as `--__audit-one <record>` and audits one
      # directory, inheriting config through the exported AUDIT_* env vars
      # below. Records are NUL-delimited so embedded tabs/spaces survive.
      ai_review::info "Fanning out ${dispatched} batch(es) across ${JOBS} workers..."
      export AI_REVIEW_TOOL
      export AUDIT_MIN_SEVERITY="${MIN_SEVERITY}"
      export AUDIT_EMIT_SARIF="${EMIT_SARIF}"
      export AUDIT_OUTPUT_DIR="${OUTPUT_DIR}"
      [[ "${AI_REVIEW_NO_ADJUDICATE:-0}" == "1" ]] && export AI_REVIEW_NO_ADJUDICATE
      local fan_rc=0
      printf '%s\0' "${to_run[@]}" \
        | xargs -0 -P "${JOBS}" -n1 bash "${SELF}" --__audit-one || fan_rc=$?
      # xargs exits 123 if any worker exited non-zero (its AI call failed). Those
      # directories simply have no report and resume mode will retry them.
      if (( fan_rc != 0 )); then
        ai_review::warn "One or more batches failed (xargs rc=${fan_rc}); re-run to resume the missing directories."
        exit_code=1
      fi
    fi
  fi

  ai_review::log  "────────────────────────────────────────────────────────────"
  ai_review::info "Audit pass complete:"
  ai_review::log  "  Dispatched:      ${dispatched}"
  ai_review::log  "  Skipped (resume):${skipped}"

  # Generate the index. This also scans every written report and publishes the
  # tallies (AUDIT_INDEX_FINDINGS_COUNT / _AUDITED_COUNT) we use below — deriving
  # them from the reports rather than from per-batch return values means the
  # serial and parallel paths produce identical counts.
  ai_review::info "Generating ${OUTPUT_DIR}/_INDEX.md..."
  AUDIT_INDEX_FINDINGS_COUNT=0
  AUDIT_INDEX_AUDITED_COUNT=0
  audit::write_index

  ai_review::log  "  Directories w/ findings: ${AUDIT_INDEX_FINDINGS_COUNT} of ${AUDIT_INDEX_AUDITED_COUNT} audited"

  # Merge SARIF if requested.
  if (( EMIT_SARIF == 1 )); then
    ai_review::info "Merging SARIF documents into ${OUTPUT_DIR}/_findings.sarif..."
    audit::write_sarif
  fi

  ai_review::info "Done. Open ${OUTPUT_DIR}/_INDEX.md to triage findings."

  # Gate mode: exit non-zero if any directory had findings.
  if (( GATE_MODE == 1 )) && (( AUDIT_INDEX_FINDINGS_COUNT > 0 )); then
    ai_review::err "--gate mode: ${AUDIT_INDEX_FINDINGS_COUNT} director(ies) had findings, exiting non-zero."
    exit 1
  fi

  # If --no-block is set, always exit 0 regardless of failures during the loop.
  if (( NO_BLOCK == 1 )); then
    exit 0
  fi

  exit "${exit_code}"
}

# ── Worker entry point ──────────────────────────────────────────────────────
# Invoked as `--__audit-one <dir>\t<files_pipe>` by the parallel fan-out. Audits
# exactly one batch and exits with audit::process_one_batch's status.
audit::worker_main() {
  # Quiet tool resolution — the parent already announced and validated the tool;
  # one log line per worker would just be noise.
  ai_review::resolve_tool >/dev/null
  local dir="${WORKER_RECORD%%$'\t'*}"
  local files_pipe="${WORKER_RECORD#*$'\t'}"
  audit::process_one_batch "${dir}" "${files_pipe}"
}

if (( AUDIT_WORKER_MODE == 1 )); then
  audit::worker_main
else
  main
fi
