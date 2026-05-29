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
#   codebase-audit-dispatcher.sh --sarif                  # also emit SARIF
#   codebase-audit-dispatcher.sh --force                  # re-audit even if reports exist
#   codebase-audit-dispatcher.sh --gate                   # exit 1 if any findings
#   codebase-audit-dispatcher.sh --dry-run                # list batches; no AI calls
#   codebase-audit-dispatcher.sh --list-batches           # print the batch plan, no execution
#
# Output:
#   audit-reports/<directory>.md         (one per batched directory; slashes
#                                         in the path are replaced with __)
#   audit-reports/_INDEX.md              (cross-batch summary, generated last)
#   audit-reports/_findings.sarif        (only when --sarif is set)
#
# Required environment:
#   AI_REVIEW_TOOL          claude | codex | copilot

set -euo pipefail

# ── Resolve repository root and shared library ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
LIB_PATH="${REPO_ROOT}/.skills/_lib/ai-review-dispatch.sh"

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
SCOPE_ROOT=""
EMIT_SARIF=0
FORCE=0
GATE_MODE=0
DRY_RUN=0
LIST_BATCHES_ONLY=0
NO_BLOCK=0
OUTPUT_DIR="audit-reports"

# ── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
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
      SCOPE_ROOT="$2"; shift 2 ;;
    --scope=*)
      SCOPE_ROOT="${1#*=}"; shift ;;
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
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
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

# Resolve AI_REVIEW_TOOL (lib provides validation + error message).
ai_review::resolve_tool

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
  if [[ -n "${SCOPE_ROOT}" ]]; then
    git -C "${REPO_ROOT}" ls-files -- "${SCOPE_ROOT}"
  else
    git -C "${REPO_ROOT}" ls-files
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
**Scope root:**          ${SCOPE_ROOT:-<entire repo>}
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

# ── Main audit loop ─────────────────────────────────────────────────────────
main() {
  ai_review::info "Codebase audit — ${SKILL_HUMAN_NAME}"
  ai_review::log  "  AI tool:        ${AI_REVIEW_TOOL_RESOLVED}"
  ai_review::log  "  Min severity:   ${MIN_SEVERITY}"
  ai_review::log  "  Scope:          ${SCOPE_ROOT:-<entire repo>}"
  ai_review::log  "  Output dir:     ${OUTPUT_DIR}"
  ai_review::log  "  Emit SARIF:     $((EMIT_SARIF))"
  ai_review::log  "  Resume mode:    $((1 - FORCE))   (skip dirs with existing reports)"

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
    ai_review::warn "No reviewable directories found under ${SCOPE_ROOT:-the repo root}."
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

  # Loop and invoke per batch.
  local total=${#batches[@]}
  local current=0
  local skipped=0
  local executed=0
  local with_findings=0
  local exit_code=0

  for line in "${batches[@]}"; do
    current=$(( current + 1 ))
    local dir="${line%%$'\t'*}"
    local files_pipe="${line#*$'\t'}"
    local report_path
    report_path="$(audit::report_path_for_dir "${dir}")"

    if [[ -f "${report_path}" ]] && (( FORCE == 0 )); then
      ai_review::log "[${current}/${total}] SKIP ${dir} (report exists — use --force to re-audit)"
      skipped=$(( skipped + 1 ))
      continue
    fi

    ai_review::info "[${current}/${total}] Auditing ${dir}..."

    local output rc=0
    output="$(audit::invoke_for_batch "${dir}" "${files_pipe}")" || rc=$?
    if (( rc != 0 )); then
      ai_review::err "AI invocation failed for ${dir} (rc=${rc}). Continuing with next batch."
      exit_code=1
      continue
    fi

    # Strip the result marker from the report body (the dispatcher tracks
    # it, but the markdown report shouldn't show it).
    local body marker
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

    # Determine marker result.
    marker="$(printf '%s\n' "${output}" | grep -oE '<<<AI_REVIEW_RESULT:(CLEAN|FINDINGS)>>>' | head -1 || true)"
    case "${marker}" in
      "<<<AI_REVIEW_RESULT:FINDINGS>>>")
        with_findings=$(( with_findings + 1 ))
        ai_review::log "    → findings reported in ${report_path}"
        ;;
      "<<<AI_REVIEW_RESULT:CLEAN>>>")
        ai_review::log "    → clean (no findings ≥ ${MIN_SEVERITY})"
        ;;
      *)
        ai_review::warn "    → could not parse result marker; report saved anyway"
        ;;
    esac

    executed=$(( executed + 1 ))
  done

  ai_review::log  "────────────────────────────────────────────────────────────"
  ai_review::info "Audit pass complete:"
  ai_review::log  "  Executed:        ${executed}"
  ai_review::log  "  Skipped (resume):${skipped}"
  ai_review::log  "  With findings:   ${with_findings}"

  # Generate the index.
  ai_review::info "Generating ${OUTPUT_DIR}/_INDEX.md..."
  audit::write_index

  # Merge SARIF if requested.
  if (( EMIT_SARIF == 1 )); then
    ai_review::info "Merging SARIF documents into ${OUTPUT_DIR}/_findings.sarif..."
    audit::write_sarif
  fi

  ai_review::info "Done. Open ${OUTPUT_DIR}/_INDEX.md to triage findings."

  # Gate mode: exit non-zero if any batch had findings.
  if (( GATE_MODE == 1 )) && (( with_findings > 0 )); then
    ai_review::err "--gate mode: ${with_findings} batch(es) had findings, exiting non-zero."
    exit 1
  fi

  # If --no-block is set, always exit 0 regardless of failures during the loop.
  if (( NO_BLOCK == 1 )); then
    exit 0
  fi

  exit "${exit_code}"
}

main
