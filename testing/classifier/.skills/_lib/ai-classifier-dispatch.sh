#!/usr/bin/env bash
# .skills/_lib/ai-classifier-dispatch.sh
#
# Shared dispatch library sourced by the test-classifier dispatcher script.
#
# This library is tool-agnostic. It resolves which AI coding assistant to call
# (claude | codex | copilot) based on the AI_REVIEW_TOOL environment variable,
# invokes the chosen CLI in non-interactive mode with a deterministic prompt,
# and parses a structured result marker out of the response.
#
# It is a sibling of the security workstream's .skills/_lib/ai-review-dispatch.sh
# and deliberately keeps the same shape, the same ai_review:: helper namespace,
# and the same color/CI conventions so the two workstreams feel identical to a
# developer who has used either one. The ONLY domain difference is the result-
# marker vocabulary: the classifier speaks CLASSIFIED / NO_ACTION rather than
# PASS / WARN / BLOCK.
#
# Sourcing scripts must define the following variables BEFORE sourcing this
# library, then call ai_review::run (or run their own loop, as the dispatcher
# does).
#
#   SKILL_NAME              — short id, e.g. "test-classifier"
#   SKILL_HUMAN_NAME        — display name, e.g. "AI Test Classifier"
#   SKILL_PROMPT            — full prompt text passed to the AI CLI
#   SKILL_PATH_CANONICAL    — path to canonical SKILL.md under .skills/
#
# Optional:
#   SKILL_FILE_FILTER_FN  — name of a function that returns 0 if at least one
#                           relevant file is in the diff, 1 otherwise. If unset,
#                           the dispatcher runs regardless of file types.
#
# Result marker contract:
#   The AI is instructed to end its output with EXACTLY ONE of:
#       <<<AI_REVIEW_RESULT:CLASSIFIED>>>   (≥1 failing test triaged; any verdict)
#       <<<AI_REVIEW_RESULT:NO_ACTION>>>    (nothing failed; classifications empty)
#
# Classifier policy (advisory by default):
#   The classifier is non-blocking. CLASSIFIED is informational; it does not
#   fail the build unless the dispatcher's --gate flag is set. NO_ACTION is the
#   "all green / nothing to do" result. See the dispatcher for --gate semantics.
#
# Exit codes (library-level helpers):
#   0  — normal completion (the dispatcher owns the final exit decision)
#   1  — unrecoverable runtime error
#   2  — Configuration error (AI_REVIEW_TOOL unset or invalid; bad flags)

set -euo pipefail

# ── Library guard ───────────────────────────────────────────────────────────
if [[ "${_AI_CLASSIFIER_DISPATCH_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AI_CLASSIFIER_DISPATCH_LOADED=1

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
#   AI_REVIEW_NO_BLOCK  ("1" or "0") — run classification but never exit non-zero
#   AI_REVIEW_AGAINST   (string)     — git ref to diff against (the change under test)
#   AI_REVIEW_REMAINING (array)      — any unparsed args
ai_review::parse_args() {
  AI_REVIEW_DRY_RUN=0
  AI_REVIEW_NO_BLOCK=0
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
${SKILL_HUMAN_NAME} — test-failure classifier dispatcher

Usage:
  $(basename "${BASH_SOURCE[1]:-$0}") [options]

Options:
  -n, --dry-run        Print the resolved AI tool, prompt, and target files,
                       but do not invoke the AI. Exits 0.
  --no-block           Run the full classification but always exit 0, regardless
                       of the result marker (the classifier is advisory anyway;
                       this is belt-and-suspenders for CI experiments).
  --against <ref>      Classify failures relative to the change between <ref> and
                       HEAD (the "change under test"), e.g. --against origin/main
                       or --against HEAD~1.
  -h, --help           Show this help and exit.

Environment variables:
  AI_REVIEW_TOOL       Required. One of: claude | codex | copilot.
  CI                   If "true", colors are suppressed and errors prefer the
                       fail-fast path.
  NO_COLOR             If set (any value), suppress ANSI color codes.

Exit codes:
  0   Normal completion (classifier is advisory; --dry-run / --no-block)
  1   Unrecoverable runtime error (or --gate set and result is CLASSIFIED)
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
    ai_review::log "  This variable selects which AI coding assistant the classifier will use."
    ai_review::log "  It must be set to exactly one of:  claude  |  codex  |  copilot"
    ai_review::log ""
    ai_review::log "  Set it for your current shell:"
    ai_review::log "      export AI_REVIEW_TOOL=claude     # (or codex / copilot)"
    ai_review::log ""
    ai_review::log "  Persist it across sessions (macOS, zsh):"
    ai_review::log "      echo 'export AI_REVIEW_TOOL=claude' >> ~/.zshrc"
    ai_review::log ""
    ai_review::log "  See the testing/classifier README / playbook, section 'AI tool selection'."
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
    exit 1
  fi
}

# ── Diff collection ─────────────────────────────────────────────────────────
# Determines whether there is a "change under test" to reason about.
# When AI_REVIEW_AGAINST is empty, falls back to the staged diff (local use).
# When AI_REVIEW_AGAINST is set, uses the diff between that ref and HEAD.
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

ai_review::invoke_claude() {
  ai_review::require_cli "claude" \
    "Install Claude Code:  npm install -g @anthropic-ai/claude-code"

  # Claude Code auto-discovers .claude/skills/*/SKILL.md by description match,
  # but for determinism we also reference the path explicitly in the prompt.
  # -p = non-interactive (print) mode, exits after one response.
  claude -p "${SKILL_PROMPT}" 2>&1
}

ai_review::invoke_codex() {
  ai_review::require_cli "codex" \
    "Install OpenAI Codex CLI:  npm install -g @openai/codex   (or see https://github.com/openai/codex)"

  # codex exec = non-interactive subcommand.
  # --sandbox read-only = filesystem read access (needed for git diff / file
  # reads) with no write/network side effects, suitable for a CI triage step.
  codex exec --sandbox read-only --skip-git-repo-check "${SKILL_PROMPT}" 2>&1
}

ai_review::invoke_copilot() {
  ai_review::require_cli "copilot" \
    "Install GitHub Copilot CLI (agentic):  https://github.com/github/copilot-cli"

  # copilot -p = non-interactive single-prompt mode.
  copilot -p "${SKILL_PROMPT}" 2>&1
}

ai_review::invoke_ai() {
  case "${AI_REVIEW_TOOL_RESOLVED}" in
    claude)  ai_review::invoke_claude ;;
    codex)   ai_review::invoke_codex  ;;
    copilot) ai_review::invoke_copilot ;;
    *)
      ai_review::err "Internal error: unknown resolved tool '${AI_REVIEW_TOOL_RESOLVED}'"
      exit 1
      ;;
  esac
}

# ── Result marker parsing ───────────────────────────────────────────────────
# The canonical marker is:  <<<AI_REVIEW_RESULT:CLASSIFIED|NO_ACTION>>>
# We grep for the structured form; if absent we return UNPARSEABLE so the
# caller can fail safe (the AI must produce a marker; its absence is an error).
ai_review::parse_result() {
  local output="$1"

  if   grep -q '<<<AI_REVIEW_RESULT:CLASSIFIED>>>' <<< "${output}"; then
    echo "CLASSIFIED"
  elif grep -q '<<<AI_REVIEW_RESULT:NO_ACTION>>>'  <<< "${output}"; then
    echo "NO_ACTION"
  else
    echo "UNPARSEABLE"
  fi
}

# ── Main entry point ────────────────────────────────────────────────────────
# The test-classifier dispatcher runs its own loop (to inject PR discovery,
# mode handling, and PR-comment posting), but this generic runner is kept for
# parity with the security library and for simple ad-hoc local invocations.
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

  if ! ai_review::has_changes; then
    ai_review::ok "No change under test ($(ai_review::diff_command_description)) — nothing to classify."
    exit 0
  fi

  if declare -F "${SKILL_FILE_FILTER_FN:-}" >/dev/null 2>&1; then
    if ! "${SKILL_FILE_FILTER_FN}"; then
      ai_review::ok "No relevant files in diff — skipping ${SKILL_NAME}."
      exit 0
    fi
  fi

  ai_review::resolve_tool

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

  ai_review::info "Running ${SKILL_HUMAN_NAME} on $(ai_review::diff_command_description) via ${AI_REVIEW_TOOL_RESOLVED}..."
  ai_review::log  "────────────────────────────────────────────────────────────"

  # Export AI_REVIEW_AGAINST so the AI subprocess can see which diff range to
  # treat as the change under test; the skill consults this variable.
  export AI_REVIEW_AGAINST

  local review_output
  local invoke_rc=0
  review_output="$(ai_review::invoke_ai)" || invoke_rc=$?

  printf '%s\n' "${review_output}"
  ai_review::log  "────────────────────────────────────────────────────────────"

  if (( invoke_rc != 0 )); then
    ai_review::err "AI CLI (${AI_REVIEW_TOOL_RESOLVED}) exited with code ${invoke_rc}."
    if (( AI_REVIEW_NO_BLOCK == 1 )); then
      ai_review::warn "--no-block in effect: not failing despite CLI error."
      exit 0
    fi
    exit 1
  fi

  local result
  result="$(ai_review::parse_result "${review_output}")"

  case "${result}" in
    CLASSIFIED)
      ai_review::info "${AI_C_BOLD}${SKILL_HUMAN_NAME}: failing tests were classified. Review the verdicts above.${AI_C_RESET}"
      exit 0
      ;;
    NO_ACTION)
      ai_review::ok "${AI_C_BOLD}${SKILL_HUMAN_NAME}: no action — nothing failed.${AI_C_RESET}"
      exit 0
      ;;
    UNPARSEABLE|*)
      ai_review::err "Could not parse classifier result."
      ai_review::log "  Expected one of:"
      ai_review::log "      <<<AI_REVIEW_RESULT:CLASSIFIED>>>"
      ai_review::log "      <<<AI_REVIEW_RESULT:NO_ACTION>>>"
      ai_review::log "  None of these markers were present in the AI's response."
      ai_review::log "  This usually indicates the AI CLI errored or the prompt was modified."
      if (( AI_REVIEW_NO_BLOCK == 1 )); then
        ai_review::warn "--no-block in effect: not failing despite unparseable result."
        exit 0
      fi
      exit 1
      ;;
  esac
}
