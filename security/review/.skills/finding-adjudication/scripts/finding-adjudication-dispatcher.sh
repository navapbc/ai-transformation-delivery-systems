#!/usr/bin/env bash
# .skills/finding-adjudication/scripts/finding-adjudication-dispatcher.sh
#
# Standalone dispatcher for the finding-adjudication skill.
#
# In normal operation the adjudication pass is invoked automatically by the
# shared library (ai_review::adjudicate) after a finding-bearing first pass, so
# you rarely run this directly. It exists for ad-hoc use and testing: feed it a
# first-pass report and it runs the independent second-opinion adjudication.
#
# This is a thin wrapper that delegates to the shared dispatch library:
#   • Reads AI_REVIEW_TOOL ∈ {claude, codex, copilot}
#   • Uses AI_ADJUDICATION_MODEL (optional) for the adjudication model
#   • Parses <<<AI_REVIEW_RESULT:...>>> from the response
#
# Usage:
#   finding-adjudication-dispatcher.sh --findings report.md
#   finding-adjudication-dispatcher.sh --findings report.md --markers audit
#   cat report.md | finding-adjudication-dispatcher.sh --markers pre-commit
#   finding-adjudication-dispatcher.sh --findings report.md --dry-run
#
# Options:
#   --findings <file>   Path to the first-pass report to adjudicate. If omitted,
#                       the report is read from stdin.
#   --markers <vocab>   Result-marker vocabulary: pre-commit (PASS/WARN/BLOCK) or
#                       audit (CLEAN/FINDINGS). Default: pre-commit.
#   -n, --dry-run       Print the adjudication prompt that would be sent; no AI call.
#   -h, --help          Show this help and exit.

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

# ── Skill identity ──────────────────────────────────────────────────────────
SKILL_NAME="finding-adjudication"
SKILL_HUMAN_NAME="Finding Adjudication (independent second opinion)"
SKILL_PATH_CANONICAL=".skills/finding-adjudication/SKILL.md"

# ── Arg parsing ───────────────────────────────────────────────────────────────
FINDINGS_FILE=""
MARKERS="pre-commit"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings)  FINDINGS_FILE="${2:-}"; shift 2 ;;
    --findings=*) FINDINGS_FILE="${1#*=}"; shift ;;
    --markers)
      case "${2:-}" in
        pre-commit|audit) MARKERS="$2"; shift 2 ;;
        *) echo "ERROR: --markers must be one of: pre-commit | audit" >&2; exit 2 ;;
      esac
      ;;
    --markers=*)
      MARKERS="${1#*=}"
      case "${MARKERS}" in
        pre-commit|audit) ;;
        *) echo "ERROR: --markers must be one of: pre-commit | audit" >&2; exit 2 ;;
      esac
      shift
      ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "       Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ── Read the first-pass report ───────────────────────────────────────────────
if [[ -n "${FINDINGS_FILE}" ]]; then
  if [[ ! -f "${FINDINGS_FILE}" ]]; then
    echo "ERROR: findings file not found: ${FINDINGS_FILE}" >&2
    exit 2
  fi
  REPORT="$(cat "${FINDINGS_FILE}")"
else
  REPORT="$(cat)"
fi

if [[ -z "${REPORT//[[:space:]]/}" ]]; then
  echo "ERROR: no first-pass report provided (use --findings <file> or pipe via stdin)." >&2
  exit 2
fi

# ── Delegate to shared library ──────────────────────────────────────────────
# shellcheck source=../../_lib/ai-review-dispatch.sh
source "${LIB_PATH}"

ai_review::resolve_tool

if (( DRY_RUN == 1 )); then
  ai_review::info "DRY-RUN — adjudication prompt that would be sent to ${AI_REVIEW_TOOL_RESOLVED}${AI_ADJUDICATION_MODEL:+ (model ${AI_ADJUDICATION_MODEL})}:"
  ai_review::log  "────────────────────────────────────────────────────────────"
  ai_review::build_adjudication_prompt "${REPORT}" "${MARKERS}"
  ai_review::log  "────────────────────────────────────────────────────────────"
  exit 0
fi

ai_review::info "Adjudicating first-pass findings via ${AI_REVIEW_TOOL_RESOLVED}${AI_ADJUDICATION_MODEL:+ (model ${AI_ADJUDICATION_MODEL})}..."
ai_review::log  "────────────────────────────────────────────────────────────"

adj_output="$(ai_review::adjudicate "${REPORT}" "${MARKERS}")"
printf '%s\n' "${adj_output}"
ai_review::log  "────────────────────────────────────────────────────────────"

result="$(ai_review::parse_result "${adj_output}")"
ai_review::info "Adjudicated result: ${result}"

case "${result}" in
  PASS|CLEAN|WARN) exit 0 ;;
  BLOCK|FINDINGS)  exit 1 ;;
  *)               exit 1 ;;
esac
