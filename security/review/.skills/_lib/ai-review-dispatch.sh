#!/usr/bin/env bash
# .skills/_lib/ai-review-dispatch.sh
#
# Shared dispatch library sourced by skill hook dispatcher scripts.
#
# This library is tool-agnostic. It resolves which AI coding assistant to call
# (claude | codex | copilot) based on the AI_REVIEW_TOOL environment variable,
# invokes the chosen CLI in non-interactive mode with a deterministic prompt,
# and parses a structured result marker out of the response.
#
# Sourcing scripts must define the following variables BEFORE sourcing this
# library, then call ai_review::run.
#
#   SKILL_NAME              — short id, e.g. "code-security"
#   SKILL_HUMAN_NAME        — display name, e.g. "Code Security Review"
#   SKILL_PROMPT            — full prompt text passed to the AI CLI
#   SKILL_PATH_CANONICAL    — path to canonical SKILL.md under .skills/
#
# Optional:
#   SKILL_FILE_FILTER_FN  — name of a function that returns 0 if at least one
#                           relevant file is staged, 1 otherwise. If unset, the
#                           dispatcher runs regardless of file types.
#
# Result marker contract:
#   The AI is instructed to end its output with EXACTLY ONE of:
#       <<<AI_REVIEW_RESULT:PASS>>>
#       <<<AI_REVIEW_RESULT:WARN>>>
#       <<<AI_REVIEW_RESULT:BLOCK>>>
#
# Severity policy (uniform across all skills):
#   Critical, High, Medium  → BLOCK (exit 1)
#   Low                     → WARN  (exit 0, with warning banner)
#   None                    → PASS  (exit 0)
#
# Exit codes:
#   0  — PASS or WARN (commit may proceed)
#   1  — BLOCK or unrecoverable error (commit must be rejected)
#   2  — Configuration error (AI_REVIEW_TOOL unset or invalid)
#
# Adjudication (second opinion):
#   When a first pass yields WARN or BLOCK, an independent adjudication pass
#   (finding-adjudication skill) re-inspects the cited code and confirms,
#   dismisses, or downgrades each finding; the gate is then decided by the
#   adjudicated marker. A PASS first pass is final (no second call). Controlled
#   by AI_ADJUDICATION (default on) and AI_ADJUDICATION_MODEL (optional model
#   override for the same CLI). If the adjudication pass fails or returns no
#   marker, the stricter first-pass result stands (fail-safe).

set -euo pipefail

# ── Library guard ───────────────────────────────────────────────────────────
if [[ "${_AI_REVIEW_DISPATCH_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AI_REVIEW_DISPATCH_LOADED=1

# ── Color helpers (suppressed in CI / non-TTY) ──────────────────────────────
if [[ -t 1 ]] && [[ "${CI:-}" != "true" ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  AI_C_RED=$'\033[0;31m'
  AI_C_YELLOW=$'\033[1;33m'
  AI_C_GREEN=$'\033[0;32m'
  AI_C_BLUE=$'\033[0;34m'
  AI_C_BOLD=$'\033[1m'
  AI_C_RESET=$'\033[0m'
else
  AI_C_RED=""
  AI_C_YELLOW=""
  AI_C_GREEN=""
  AI_C_BLUE=""
  AI_C_BOLD=""
  AI_C_RESET=""
fi

# ── Logging helpers ─────────────────────────────────────────────────────────
ai_review::log()  { printf '%s\n' "$*"; }
ai_review::info() { printf '%s[%s]%s %s\n' "${AI_C_BOLD}" "${SKILL_NAME}" "${AI_C_RESET}" "$*"; }
ai_review::ok()   { printf '%s[%s] %s%s\n' "${AI_C_GREEN}" "${SKILL_NAME}" "$*" "${AI_C_RESET}"; }
ai_review::warn() { printf '%s[%s] %s%s\n' "${AI_C_YELLOW}" "${SKILL_NAME}" "$*" "${AI_C_RESET}" >&2; }
ai_review::err()  { printf '%s[%s] ERROR: %s%s\n' "${AI_C_RED}" "${SKILL_NAME}" "$*" "${AI_C_RESET}" >&2; }

# ── CLI flag parsing ────────────────────────────────────────────────────────
# Sets:
#   AI_REVIEW_DRY_RUN   ("1" or "0") — print what would happen, do not call AI
#   AI_REVIEW_NO_BLOCK  ("1" or "0") — run review but never exit non-zero
#   AI_REVIEW_AGAINST   (string)     — git ref to diff against; default = staged
#   AI_REVIEW_REMAINING (array)      — any unparsed args
ai_review::parse_args() {
  AI_REVIEW_DRY_RUN=0
  AI_REVIEW_NO_BLOCK=0
  AI_REVIEW_NO_ADJUDICATE=0
  AI_REVIEW_AGAINST=""
  AI_REVIEW_REMAINING=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)
        AI_REVIEW_DRY_RUN=1
        shift
        ;;
      --no-block)
        AI_REVIEW_NO_BLOCK=1
        shift
        ;;
      --no-adjudicate)
        AI_REVIEW_NO_ADJUDICATE=1
        shift
        ;;
      --against)
        if [[ -z "${2:-}" ]]; then
          ai_review::err "--against requires a git ref argument"
          exit 2
        fi
        AI_REVIEW_AGAINST="$2"
        shift 2
        ;;
      --against=*)
        AI_REVIEW_AGAINST="${1#*=}"
        shift
        ;;
      -h|--help)
        ai_review::print_help
        exit 0
        ;;
      --)
        shift
        AI_REVIEW_REMAINING+=("$@")
        break
        ;;
      *)
        AI_REVIEW_REMAINING+=("$1")
        shift
        ;;
    esac
  done
}

ai_review::print_help() {
  cat <<EOF
${SKILL_HUMAN_NAME} — pre-commit dispatcher

Usage:
  $(basename "${BASH_SOURCE[1]:-$0}") [options]

Options:
  -n, --dry-run        Print the resolved AI tool, prompt, and target files,
                       but do not invoke the AI. Exits 0.
  --no-block           Run the full review but always exit 0, regardless of
                       findings (useful for testing in CI without blocking).
  --no-adjudicate      Skip the independent second-opinion adjudication pass
                       even when the first pass reports findings. Equivalent to
                       AI_ADJUDICATION=0.
  --against <ref>      Review the diff between <ref> and HEAD (or working tree)
                       instead of the staged changes. Useful for ad-hoc review,
                       e.g.  --against HEAD~1   or  --against main
  -h, --help           Show this help and exit.

Environment variables:
  AI_REVIEW_TOOL         Required. One of: claude | codex | copilot.
  AI_ADJUDICATION        If "0", disable the second-opinion adjudication pass.
                         Default: enabled. When enabled, a finding-bearing first
                         pass triggers a fresh, independent review that confirms,
                         dismisses, or downgrades each finding before the gate is
                         decided. A clean first pass never triggers it.
  AI_ADJUDICATION_MODEL  Optional. Model name passed to the same AI_REVIEW_TOOL
                         CLI for the adjudication pass only (e.g. a different
                         model for an independent second opinion). If unset, the
                         tool's default model is used.
  CI                     If "true", colors are suppressed and errors prefer the
                         fail-fast path.
  NO_COLOR               If set (any value), suppress ANSI color codes.

Exit codes:
  0   PASS or WARN (commit may proceed; or --dry-run / --no-block)
  1   BLOCK — findings require remediation; or unrecoverable runtime error
  2   Configuration error (AI_REVIEW_TOOL unset / invalid; bad flags)
EOF
}

# ── AI_REVIEW_TOOL validation ───────────────────────────────────────────────
# Resolves the tool name into AI_REVIEW_TOOL_RESOLVED (lower-cased, validated).
# Prints the resolved tool name for auditability on every run.
ai_review::resolve_tool() {
  if [[ -z "${AI_REVIEW_TOOL:-}" ]]; then
    ai_review::err "AI_REVIEW_TOOL environment variable is not set."
    ai_review::log ""
    ai_review::log "  This variable selects which AI coding assistant the hook will use."
    ai_review::log "  It must be set to exactly one of:  claude  |  codex  |  copilot"
    ai_review::log ""
    ai_review::log "  Set it for your current shell:"
    ai_review::log "      export AI_REVIEW_TOOL=claude     # (or codex / copilot)"
    ai_review::log ""
    ai_review::log "  Persist it across sessions (macOS, zsh):"
    ai_review::log "      echo 'export AI_REVIEW_TOOL=claude' >> ~/.zshrc"
    ai_review::log ""
    ai_review::log "  See the project README, section 'AI tool selection (AI_REVIEW_TOOL)'."
    exit 2
  fi

  # Lower-case for case-insensitive comparison.
  local raw="${AI_REVIEW_TOOL}"
  local lower
  lower="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"

  case "${lower}" in
    claude|codex|copilot)
      AI_REVIEW_TOOL_RESOLVED="${lower}"
      ;;
    *)
      ai_review::err "AI_REVIEW_TOOL='${raw}' is not a recognized value."
      ai_review::log "  Valid values: claude | codex | copilot"
      exit 2
      ;;
  esac

  ai_review::info "AI tool resolved: ${AI_C_BLUE}${AI_REVIEW_TOOL_RESOLVED}${AI_C_RESET}"
}

# ── CLI presence checks ─────────────────────────────────────────────────────
ai_review::require_cli() {
  local tool="$1"
  local install_hint="$2"

  if ! command -v "${tool}" &>/dev/null; then
    ai_review::err "'${tool}' CLI not found on PATH."
    ai_review::log "  ${install_hint}"
    ai_review::log "  After installing, re-run:  pre-commit install"
    exit 1
  fi
}

# ── Diff collection ─────────────────────────────────────────────────────────
# Determines whether there are any changes to review.
# When AI_REVIEW_AGAINST is empty (default pre-commit mode), checks staged diff.
# When AI_REVIEW_AGAINST is set, checks the diff between that ref and HEAD.
ai_review::has_changes() {
  if [[ -n "${AI_REVIEW_AGAINST}" ]]; then
    if ! git rev-parse --verify --quiet "${AI_REVIEW_AGAINST}^{commit}" >/dev/null; then
      ai_review::err "Git ref not found: ${AI_REVIEW_AGAINST}"
      exit 1
    fi
    ! git diff --quiet "${AI_REVIEW_AGAINST}" HEAD --
  else
    ! git diff --cached --quiet
  fi
}

ai_review::changed_files() {
  if [[ -n "${AI_REVIEW_AGAINST}" ]]; then
    git diff --name-only "${AI_REVIEW_AGAINST}" HEAD --
  else
    git diff --cached --name-only
  fi
}

ai_review::diff_command_description() {
  if [[ -n "${AI_REVIEW_AGAINST}" ]]; then
    echo "git diff ${AI_REVIEW_AGAINST} HEAD"
  else
    echo "git diff --cached"
  fi
}

# ── Tool-specific invocation ────────────────────────────────────────────────
# Each ai_review::invoke_* function reads SKILL_PROMPT and prints the AI's raw
# response to stdout. Any non-zero exit from the underlying CLI is fatal.
#
# Why pass the full prompt rather than relying on auto-discovery:
# Only Claude Code has first-class skill auto-discovery. Codex and Copilot do
# not. For a uniform, reliable contract, every tool receives the same explicit
# prompt that references the SKILL.md path in that tool's standard location.

# ai_review::invoke_tool <prompt> [model]
# Invokes the resolved AI CLI in non-interactive mode with the given prompt,
# printing the raw response to stdout. When [model] is non-empty, it is passed
# to the CLI's model-selection flag — this is how the adjudication pass can run
# on a different model from the first pass while staying on the same CLI (a
# Claude shop has only the `claude` binary, so a cross-vendor second opinion is
# not assumed). Any non-zero exit from the underlying CLI propagates.
ai_review::invoke_tool() {
  local prompt="$1"
  local model="${2:-}"

  case "${AI_REVIEW_TOOL_RESOLVED}" in
    claude)
      ai_review::require_cli "claude" \
        "Install Claude Code:  npm install -g @anthropic-ai/claude-code"
      # -p = non-interactive (print) mode, exits after one response.
      if [[ -n "${model}" ]]; then
        claude -p "${prompt}" --model "${model}" 2>&1
      else
        claude -p "${prompt}" 2>&1
      fi
      ;;
    codex)
      ai_review::require_cli "codex" \
        "Install OpenAI Codex CLI:  npm install -g @openai/codex   (or see https://github.com/openai/codex)"
      # --sandbox read-only = filesystem read access (git diff / file reads)
      # with no write/network side effects, suitable for a pre-commit hook.
      if [[ -n "${model}" ]]; then
        codex exec --sandbox read-only --skip-git-repo-check --model "${model}" "${prompt}" 2>&1
      else
        codex exec --sandbox read-only --skip-git-repo-check "${prompt}" 2>&1
      fi
      ;;
    copilot)
      ai_review::require_cli "copilot" \
        "Install GitHub Copilot CLI (agentic):  https://github.com/github/copilot-cli"
      # copilot -p = non-interactive single-prompt mode.
      if [[ -n "${model}" ]]; then
        copilot -p "${prompt}" --model "${model}" 2>&1
      else
        copilot -p "${prompt}" 2>&1
      fi
      ;;
    *)
      ai_review::err "Internal error: unknown resolved tool '${AI_REVIEW_TOOL_RESOLVED}'"
      exit 1
      ;;
  esac
}

# First-pass invocation: the configured tool, its default model, the dispatcher's
# SKILL_PROMPT.
ai_review::invoke_ai() {
  ai_review::invoke_tool "${SKILL_PROMPT}" ""
}

# ── Result marker parsing ───────────────────────────────────────────────────
# The canonical marker is:  <<<AI_REVIEW_RESULT:PASS|WARN|BLOCK>>>
# We grep for the structured form first; if absent we fall through to a safety
# BLOCK because the AI must produce a marker and its absence indicates an error.
ai_review::parse_result() {
  local output="$1"

  if   grep -q '<<<AI_REVIEW_RESULT:BLOCK>>>' <<< "${output}"; then
    echo "BLOCK"
  elif grep -q '<<<AI_REVIEW_RESULT:WARN>>>'  <<< "${output}"; then
    echo "WARN"
  elif grep -q '<<<AI_REVIEW_RESULT:PASS>>>'  <<< "${output}"; then
    echo "PASS"
  else
    echo "UNPARSEABLE"
  fi
}

# ── Adjudication (independent second-opinion pass) ──────────────────────────
# When a first pass reports findings, a fresh agent re-inspects the cited code
# and confirms / dismisses / downgrades each finding. This removes false
# positives before they reach the developer, with no manual suppression list.
# It runs ONLY when the first pass found something, so clean commits stay
# single-pass and fast — cost scales with noise, not commit volume.

ai_review::adjudication_enabled() {
  [[ "${AI_REVIEW_NO_ADJUDICATE:-0}" != "1" ]] && [[ "${AI_ADJUDICATION:-1}" != "0" ]]
}

# Strip any result marker lines so an embedded first-pass report cannot be
# mistaken for the adjudicator's own (authoritative) marker.
ai_review::strip_markers() {
  sed -E '/<<<AI_REVIEW_RESULT:(PASS|WARN|BLOCK|CLEAN|FINDINGS)>>>/d'
}

# ai_review::build_adjudication_prompt <first_pass_report> <markers>
#   <markers> is "pre-commit" (PASS/WARN/BLOCK) or "audit" (CLEAN/FINDINGS).
ai_review::build_adjudication_prompt() {
  local report="$1"
  local markers="$2"
  local clean_report
  clean_report="$(printf '%s\n' "${report}" | ai_review::strip_markers)"

  local marker_instructions
  case "${markers}" in
    audit)
      marker_instructions="End your response with EXACTLY ONE of these markers, on its own line:
  <<<AI_REVIEW_RESULT:CLEAN>>>      — no confirmed findings remain at or above threshold
  <<<AI_REVIEW_RESULT:FINDINGS>>>   — one or more confirmed findings remain at or above threshold"
      ;;
    *)
      marker_instructions="End your response with EXACTLY ONE of these markers, on its own line:
  <<<AI_REVIEW_RESULT:PASS>>>    — no confirmed findings remain at any severity
  <<<AI_REVIEW_RESULT:WARN>>>    — only confirmed LOW findings remain
  <<<AI_REVIEW_RESULT:BLOCK>>>   — one or more confirmed Critical/High/Medium findings remain"
      ;;
  esac

  cat <<PROMPT
You have access to the finding-adjudication skill. Its full instructions are at:

  .skills/finding-adjudication/SKILL.md

(Tool-specific byte-identical copies may exist under .claude/, .codex/, or
.github/copilot/.)

Read that SKILL.md, then act as an INDEPENDENT second reviewer adjudicating the
findings produced by a first-pass automated review. You did not perform the
first pass and must not assume it was correct.

The code under review is the same code the first pass examined. For diff-mode
reviews that is, by default, the staged changes (\`git diff --cached\`); if
AI_REVIEW_AGAINST is set in your environment, it is \`git diff \$AI_REVIEW_AGAINST HEAD\`.
For audit-mode reviews it is the files cited in the report. Inspect the actual
code yourself before judging each finding — do not rely on the report's summary.

For each finding in the first-pass report below, classify it as CONFIRMED,
FALSE_POSITIVE, or OVERSTATED (with a corrected lower severity), each with a
one-line rationale, following the finding-adjudication skill exactly. Do NOT
introduce new findings. Then produce the revised report in the format the skill
specifies: the surviving confirmed findings (at their final severity), followed
by a "Dismissed / Downgraded by adjudication" section that lists every change
with its reason, so nothing is silently removed.

Compute the result marker from the CONFIRMED findings only (after dismissals and
downgrades). ${marker_instructions}

If the first-pass report contains a SARIF block delimited by
<!-- AUDIT_SARIF_BEGIN --> and <!-- AUDIT_SARIF_END -->, emit an updated SARIF
block between the same delimiters reflecting only the confirmed findings at
their final severities.

──────────────────────── FIRST-PASS REPORT ────────────────────────
${clean_report}
────────────────────────────────────────────────────────────────────
PROMPT
}

# ai_review::adjudicate <first_pass_report> <markers>
# Runs the adjudication pass on the configured tool using AI_ADJUDICATION_MODEL
# (if set). Prints the adjudicated report to stdout; status logs go to stderr so
# callers can safely capture stdout.
ai_review::adjudicate() {
  local report="$1"
  local markers="${2:-pre-commit}"
  local prompt
  prompt="$(ai_review::build_adjudication_prompt "${report}" "${markers}")"
  ai_review::invoke_tool "${prompt}" "${AI_ADJUDICATION_MODEL:-}"
}

# ── Main entry point ────────────────────────────────────────────────────────
ai_review::run() {
  # Required-variable check.
  local missing=()
  [[ -z "${SKILL_NAME:-}"          ]] && missing+=("SKILL_NAME")
  [[ -z "${SKILL_HUMAN_NAME:-}"    ]] && missing+=("SKILL_HUMAN_NAME")
  [[ -z "${SKILL_PROMPT:-}"        ]] && missing+=("SKILL_PROMPT")
  if (( ${#missing[@]} > 0 )); then
    ai_review::err "Internal error: dispatcher library called without required variables: ${missing[*]}"
    exit 1
  fi

  # Parse args provided by the caller.
  ai_review::parse_args "$@"

  # If the dispatcher is configured to short-circuit on irrelevant files, run
  # that check before doing anything more expensive.
  if ! ai_review::has_changes; then
    ai_review::ok "No changes to review ($(ai_review::diff_command_description)) — skipping."
    exit 0
  fi

  if declare -F "${SKILL_FILE_FILTER_FN:-}" >/dev/null 2>&1; then
    if ! "${SKILL_FILE_FILTER_FN}"; then
      ai_review::ok "No relevant files in diff — skipping ${SKILL_NAME} review."
      exit 0
    fi
  fi

  # Resolve and announce the AI tool.
  ai_review::resolve_tool

  # Dry-run path: print plan, do not invoke AI.
  if (( AI_REVIEW_DRY_RUN == 1 )); then
    ai_review::info "DRY-RUN — no AI invocation will be made."
    ai_review::log  "  Skill:       ${SKILL_HUMAN_NAME} (${SKILL_NAME})"
    ai_review::log  "  AI tool:     ${AI_REVIEW_TOOL_RESOLVED}"
    ai_review::log  "  Diff source: $(ai_review::diff_command_description)"
    ai_review::log  "  Changed files:"
    ai_review::changed_files | sed 's/^/    /'
    ai_review::log  ""
    ai_review::log  "  Prompt that would be sent to ${AI_REVIEW_TOOL_RESOLVED}:"
    ai_review::log  "  ────────────────────────────────────────────────────────────"
    printf '%s\n' "${SKILL_PROMPT}" | sed 's/^/    /'
    ai_review::log  "  ────────────────────────────────────────────────────────────"
    exit 0
  fi

  # Run the actual review.
  ai_review::info "Running ${SKILL_HUMAN_NAME} on $(ai_review::diff_command_description) via ${AI_REVIEW_TOOL_RESOLVED}..."
  ai_review::log  "────────────────────────────────────────────────────────────"

  # Export AI_REVIEW_AGAINST so the AI subprocess can see it (it tells the AI
  # which git diff range to use; the skill consults this variable).
  export AI_REVIEW_AGAINST

  local review_output
  local invoke_rc=0
  # We capture both stdout and stderr from the AI CLI. set -e is in effect,
  # so wrap the call to allow inspection of the exit code.
  review_output="$(ai_review::invoke_ai)" || invoke_rc=$?

  printf '%s\n' "${review_output}"
  ai_review::log  "────────────────────────────────────────────────────────────"

  if (( invoke_rc != 0 )); then
    ai_review::err "AI CLI (${AI_REVIEW_TOOL_RESOLVED}) exited with code ${invoke_rc}."
    ai_review::log "  Treating as BLOCK to fail safe."
    if (( AI_REVIEW_NO_BLOCK == 1 )); then
      ai_review::warn "--no-block in effect: not blocking despite CLI failure."
      exit 0
    fi
    exit 1
  fi

  # Parse the first-pass result marker.
  local result
  result="$(ai_review::parse_result "${review_output}")"

  # Independent second-opinion adjudication. Runs only when the first pass found
  # something (WARN/BLOCK) and adjudication is enabled — a clean pass is final.
  if [[ "${result}" == "WARN" || "${result}" == "BLOCK" ]] && ai_review::adjudication_enabled; then
    ai_review::info "First pass result: ${result}. Running independent adjudication (second opinion)${AI_ADJUDICATION_MODEL:+ via model ${AI_ADJUDICATION_MODEL}}..."
    local adj_output adj_rc=0
    adj_output="$(ai_review::adjudicate "${review_output}" "pre-commit")" || adj_rc=$?

    if (( adj_rc != 0 )); then
      ai_review::warn "Adjudication pass failed (rc=${adj_rc}); keeping the first-pass result (${result})."
    else
      ai_review::log  "──────── Adjudication (independent second opinion) ────────"
      printf '%s\n' "${adj_output}"
      ai_review::log  "────────────────────────────────────────────────────────────"
      local adj_result
      adj_result="$(ai_review::parse_result "${adj_output}")"
      if [[ "${adj_result}" == "UNPARSEABLE" ]]; then
        ai_review::warn "Adjudication produced no parseable result marker; keeping the first-pass result (${result})."
      else
        ai_review::info "Adjudicated result: ${result} → ${adj_result} (gate decided by adjudication)."
        result="${adj_result}"
      fi
    fi
  fi

  # Act on the (possibly adjudicated) result marker.
  case "${result}" in
    PASS)
      ai_review::ok "${AI_C_BOLD}✅  ${SKILL_HUMAN_NAME} passed. No findings detected.${AI_C_RESET}"
      exit 0
      ;;
    WARN)
      ai_review::warn "${AI_C_BOLD}⚠️   ${SKILL_HUMAN_NAME} warnings found. Review the report above before proceeding.${AI_C_RESET}"
      ai_review::warn "Low-severity findings only. Commit is allowed."
      exit 0
      ;;
    BLOCK)
      ai_review::err "${AI_C_BOLD}🚫  COMMIT BLOCKED — Critical, high, or medium findings detected.${AI_C_RESET}"
      ai_review::err "Resolve all critical, high, and medium findings before committing."
      ai_review::err "See the report above for details and remediation guidance."
      ai_review::err "If you believe this is a false positive, see the README section on false positives."
      if (( AI_REVIEW_NO_BLOCK == 1 )); then
        ai_review::warn "--no-block in effect: not blocking despite BLOCK result."
        exit 0
      fi
      exit 1
      ;;
    UNPARSEABLE|*)
      ai_review::err "Could not parse review result."
      ai_review::log "  Expected one of:"
      ai_review::log "      <<<AI_REVIEW_RESULT:PASS>>>"
      ai_review::log "      <<<AI_REVIEW_RESULT:WARN>>>"
      ai_review::log "      <<<AI_REVIEW_RESULT:BLOCK>>>"
      ai_review::log "  None of these markers were present in the AI's response."
      ai_review::log "  This usually indicates the AI CLI encountered an error or the prompt was modified."
      ai_review::log "  Failing safe (BLOCK)."
      if (( AI_REVIEW_NO_BLOCK == 1 )); then
        ai_review::warn "--no-block in effect: not blocking despite unparseable result."
        exit 0
      fi
      exit 1
      ;;
  esac
}
