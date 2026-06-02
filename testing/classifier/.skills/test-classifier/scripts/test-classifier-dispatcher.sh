#!/usr/bin/env bash
# .skills/test-classifier/scripts/test-classifier-dispatcher.sh
#
# Test-classifier dispatcher. Runs the test-classifier skill on the change
# under test and posts ONE PR comment with the verdicts and a mandatory 👍/👎
# reaction.
#
# This dispatcher is the testing-workstream sibling of the security
# workstream's pr-review-dispatcher.sh and intentionally mirrors its shape.
# It differs from a pre-commit dispatcher in three ways:
#
#   1. It computes its diff range from a pull-request base ref, not from the
#      git index. Auto-discovery uses `gh pr view`; manual override via --pr.
#   2. It parses a JSON intermediate format from the AI's response. With
#      --post-comment it uses the GitHub REST API (via `gh api`) to post ONE
#      issue comment on the PR with the classification table and the 👍/👎 ask.
#   3. The classifier is advisory: by default the dispatcher exits 0 even when
#      tests were classified. The --gate flag flips this to exit 1 when the
#      result is CLASSIFIED (CI-blocking mode for teams that want it).
#
# Behavior: classify the failing tests and post ONE PR comment with the verdicts
# + a mandatory 👍/👎 ask (the tuning signal). Posting requires --post-comment;
# without it the report/JSON only prints (useful for a local dry view). Nothing
# is posted when nothing was triaged.
#
# Usage:
#   test-classifier-dispatcher.sh                              # auto-discover PR; print only
#   test-classifier-dispatcher.sh --pr 1234 --post-comment     # post the PR comment
#   test-classifier-dispatcher.sh --against origin/main        # explicit base ref
#   test-classifier-dispatcher.sh --json-only                  # emit only the JSON block
#   test-classifier-dispatcher.sh --gate                       # exit 1 on CLASSIFIED
#   test-classifier-dispatcher.sh --propose-fixes              # open fix PRs (opt-in)
#   test-classifier-dispatcher.sh --dry-run                    # show plan, no AI call
#
# Required environment:
#   AI_REVIEW_TOOL          claude | codex | copilot
#
# Required when --post-comment is used:
#   gh CLI installed and authenticated; or GH_TOKEN exported
#
# Required when --propose-fixes is used:
#   AI_FIX_PAT              A PAT (NOT the default GITHUB_TOKEN) with
#                          pull-requests:write + contents:write. Opening the fix
#                          PR with a PAT is what lets the repo's real CI run on
#                          it; a GITHUB_TOKEN-opened PR would not trigger CI.

set -euo pipefail

# ── Resolve repository root and shared library ─────────────────────────────
# The classifier's _lib lives under the testing/classifier/ subtree, not at the
# repo root, so we resolve the classifier root by walking up from this script:
#   .../testing/classifier/.skills/test-classifier/scripts/<this file>
#   .../testing/classifier/.skills/_lib/ai-classifier-dispatch.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # → .../testing/classifier/.skills
LIB_PATH="${SKILLS_ROOT}/_lib/ai-classifier-dispatch.sh"

if [[ ! -f "${LIB_PATH}" ]]; then
  echo "ERROR: shared dispatch library not found at: ${LIB_PATH}" >&2
  echo "       This file is required. Re-install the skills (see the playbook)." >&2
  exit 1
fi

# ── Skill identity ──────────────────────────────────────────────────────────
SKILL_NAME="test-classifier"
SKILL_HUMAN_NAME="AI Test Classifier (application-bug / test-bug / flaky / environment)"
SKILL_PATH_CANONICAL=".skills/test-classifier/SKILL.md"

# ── Classifier-specific arg parsing ────────────────────────────────────────
# We intercept our own flags first, then pass the remainder to the shared
# library's parser. Recognized flags here:
#
#   --pr <number>         Explicit PR number (overrides auto-discovery)
#   --post-comment        Post ONE PR comment via gh api (omit to print only)
#   --gate                Exit 1 if the result is CLASSIFIED (CI-blocking mode)
#   --json-only           Print only the JSON block (machine consumption)
#   --propose-fixes       Open a SEPARATE fix PR per fixable verdict (opt-in,
#                         default OFF). Requires the AI_FIX_PAT env var. The fix
#                         PR targets the ORIGINAL PR's head ref so merging it
#                         folds the fix in, and is opened with the PAT so the
#                         repo's real CI runs on it.
#
# All other flags (--dry-run, --no-block, --against) fall through to the lib.

PR_NUMBER=""
POST_COMMENT=0
GATE_MODE=0
JSON_ONLY=0
PROPOSE_FIXES=0
REMAINING_FOR_LIB=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      if [[ -z "${2:-}" ]] || [[ ! "${2}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --pr requires a numeric PR number" >&2
        exit 2
      fi
      PR_NUMBER="$2"
      shift 2
      ;;
    --pr=*)
      PR_NUMBER="${1#*=}"
      if [[ ! "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --pr requires a numeric PR number" >&2
        exit 2
      fi
      shift
      ;;
    --post-comment)
      POST_COMMENT=1
      shift
      ;;
    --gate)
      GATE_MODE=1
      shift
      ;;
    --json-only)
      JSON_ONLY=1
      shift
      ;;
    --propose-fixes)
      PROPOSE_FIXES=1
      shift
      ;;
    *)
      REMAINING_FOR_LIB+=("$1")
      shift
      ;;
  esac
done

# ── PR / base-ref discovery (mirrors the security dispatcher) ───────────────
require_gh_cli() {
  local why="$1"
  if ! command -v gh &>/dev/null; then
    echo "ERROR: 'gh' CLI is required (${why}) but is not installed." >&2
    echo "       Install:  brew install gh   (macOS)" >&2
    echo "       Then:     gh auth login" >&2
    echo "       Or set a fine-grained PAT via the GH_TOKEN env var." >&2
    exit 1
  fi
  if ! gh auth status &>/dev/null; then
    echo "ERROR: 'gh' CLI is installed but not authenticated." >&2
    echo "       Run:  gh auth login" >&2
    echo "       Or set the GH_TOKEN environment variable." >&2
    exit 1
  fi
}

ai_review::discover_pr_context() {
  # If --against was passed, it wins — no PR lookup needed.
  for arg in "${REMAINING_FOR_LIB[@]+"${REMAINING_FOR_LIB[@]}"}"; do
    if [[ "${arg}" == "--against" ]] || [[ "${arg}" == --against=* ]]; then
      return 0
    fi
  done

  # If --pr was given, look up that PR's base ref.
  if [[ -n "${PR_NUMBER}" ]]; then
    require_gh_cli "PR number was specified via --pr"
    local base
    base="$(gh pr view "${PR_NUMBER}" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
    if [[ -z "${base}" ]]; then
      echo "ERROR: could not look up PR #${PR_NUMBER} via gh CLI." >&2
      echo "       Verify the PR number exists and you have access to it." >&2
      exit 1
    fi
    REMAINING_FOR_LIB+=("--against" "origin/${base}")
    AI_REVIEW_PR_NUMBER="${PR_NUMBER}"
    AI_REVIEW_PR_BASE="${base}"
    # Capture the head ref + author too — the head ref is the base for any fix
    # PR (Phase 2), and the author feeds the recursion guard.
    AI_REVIEW_PR_HEAD="$(gh pr view "${PR_NUMBER}" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
    AI_REVIEW_PR_AUTHOR="$(gh pr view "${PR_NUMBER}" --json author --jq '.author.login' 2>/dev/null || true)"
    return 0
  fi

  # Otherwise auto-discover from the current branch.
  if ! command -v gh &>/dev/null; then
    echo "ERROR: cannot auto-discover the PR for the current branch — 'gh' CLI not installed." >&2
    echo "" >&2
    echo "  You have three options:" >&2
    echo "    1. Install gh and authenticate:  brew install gh && gh auth login" >&2
    echo "    2. Specify a PR explicitly:      --pr <number>" >&2
    echo "    3. Specify a base ref directly:  --against origin/main" >&2
    exit 1
  fi

  # Let gh extract the fields with --jq (same idiom as the --pr branch above),
  # rather than scraping the raw JSON with brittle regexes.
  AI_REVIEW_PR_NUMBER="$(gh pr view --json number --jq '.number' 2>/dev/null || true)"
  AI_REVIEW_PR_BASE="$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
  # Head ref (base for any Phase 2 fix PR) + author (recursion guard).
  AI_REVIEW_PR_HEAD="$(gh pr view --json headRefName --jq '.headRefName' 2>/dev/null || true)"
  AI_REVIEW_PR_AUTHOR="$(gh pr view --json author --jq '.author.login' 2>/dev/null || true)"

  if [[ -z "${AI_REVIEW_PR_NUMBER}" ]] || [[ -z "${AI_REVIEW_PR_BASE}" ]]; then
    echo "ERROR: 'gh pr view' could not find an open PR for the current branch." >&2
    echo "" >&2
    echo "  Either:" >&2
    echo "    • Push your branch and open a PR, then re-run; or" >&2
    echo "    • Specify the PR number explicitly:   --pr <number>" >&2
    echo "    • Specify the base ref directly:      --against origin/main" >&2
    exit 1
  fi

  REMAINING_FOR_LIB+=("--against" "origin/${AI_REVIEW_PR_BASE}")
  echo "[test-classifier] Auto-discovered PR #${AI_REVIEW_PR_NUMBER} (base: ${AI_REVIEW_PR_BASE})"
}

# ── Prompt construction ─────────────────────────────────────────────────────
# We instruct the AI to emit BOTH a human-readable report AND a fenced JSON
# block. The dispatcher extracts the JSON block to render the PR comment.

read -r -d '' SKILL_PROMPT <<PROMPT || true
You have access to the test-classifier skill. The skill's full instructions are
in this repository at:

  testing/classifier/.skills/test-classifier/SKILL.md

(Tool-specific copies may also exist under .claude/skills/, .codex/skills/, or
.github/copilot/skills/; all are byte-identical to the canonical file above.)

Classify the failing tests for the change under test — the diff between
AI_REVIEW_AGAINST and HEAD:

  git diff "\$AI_REVIEW_AGAINST" HEAD --unified=5
  git diff "\$AI_REVIEW_AGAINST" HEAD --name-only

Follow the skill instructions in test-classifier/SKILL.md exactly:

  1. Collect the failing-test signal (which tests failed and the failure output).
  2. Collect the change-under-test diff (above).
  3. For EACH failing test, decide ONE verdict using the four-verdict procedure
     (work it IN ORDER — rule out substrate causes before app-vs-test):
       - environment/infra failure (timeout, connection refused, port in use,
         runner OOM, missing service/secret) -> "ENVIRONMENT_ISSUE"
       - intermittent / non-deterministic (timing/ordering; would pass on an
         unchanged re-run) -> "FLAKY_FAILURE" (recommend a re-run to confirm)
       - test fails / app correct -> "TEST_BUG" (fix the TEST; it is stale or a
         change-detector firing on an intended change)
       - test fails / app regressed -> "APPLICATION_BUG" (fix the CODE; do NOT
         relax the test — never generate a no-op test for genuinely broken code)
     Passing tests are NOT classified (omit them). Prefer FLAKY_FAILURE with low
     confidence over a confident APPLICATION_BUG when a single run looks flaky.
  4. Tag each with a category: visual-drift | behavioral-drift | e2e-form-flow-drift | other.
  5. Assign a confidence: high | medium | low (be honest about uncertainty).
  6. Emit a human-readable terminal report (formatted markdown).
  7. After the report, emit ONE machine-readable JSON block delimited by these
     exact markers on their own lines:

       <!-- AI_CLASSIFIER_JSON_BEGIN -->
       { ...JSON object as specified in test-classifier/SKILL.md section 6B... }
       <!-- AI_CLASSIFIER_JSON_END -->

After the JSON block, end your response with EXACTLY ONE of the following
markers, on its own line, with no surrounding text:

  <<<AI_REVIEW_RESULT:CLASSIFIED>>>   (>=1 failing test triaged; any verdict)
  <<<AI_REVIEW_RESULT:NO_ACTION>>>    (nothing failed; classifications empty)

The marker must be consistent with the JSON classifications. Failure to emit a
marker, or a mismatch between the marker and the JSON, will cause the dispatcher
to log an error and exit non-zero. Do NOT propose code suggestions (P2) or
generate tests (P3) — both are out of current scope.
PROMPT

# ── Source shared library ───────────────────────────────────────────────────
# shellcheck source=../../_lib/ai-classifier-dispatch.sh
source "${LIB_PATH}"

# ── Helpers: JSON extraction and PR-comment posting ────────────────────────

# Pull the JSON block between AI_CLASSIFIER_JSON_BEGIN/END markers out of stdin.
extract_classifier_json() {
  local input="$1"
  echo "${input}" | awk '
    /<!-- AI_CLASSIFIER_JSON_BEGIN -->/ { capturing=1; next }
    /<!-- AI_CLASSIFIER_JSON_END -->/   { capturing=0; next }
    capturing { print }
  '
}

# Render the ONE PR comment body from the classifier JSON, including the
# mandatory 👍/👎 ask. We use python3 because pure-bash JSON handling is brittle.
render_pr_comment_body() {
  local classifier_json="$1"

  if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required to render the PR comment from classifier JSON." >&2
    exit 1
  fi

  echo "${classifier_json}" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"ERROR: could not parse classifier JSON from AI output: {e}", file=sys.stderr)
    sys.exit(1)

summary = data.get("summary", "AI test classifier triage of the failing tests.")
classifications = data.get("classifications", [])

lines = []
# Conventional-Comment label so the comment is greppable and the metrics
# harvester (testing/metrics/test_classifier_comments.sh) can identify it by a
# stable leading marker. Keep this in sync with CLASSIFIER_LABEL there.
lines.append("test-classifier: AI triage of failing tests")
lines.append("")
lines.append("## AI Test Classifier — triage of failing tests")
lines.append("")
lines.append(summary)
lines.append("")
lines.append("| Verdict | Test | Category | Confidence |")
lines.append("|---|---|---|---|")
for c in classifications:
    verdict = c.get("verdict", "?")
    test = c.get("test", "?")
    category = c.get("category", "other")
    confidence = c.get("confidence", "?")
    lines.append(f"| {verdict} | `{test}` | {category} | {confidence} |")
lines.append("")

# Per-test rationales (path:line for orientation).
for c in classifications:
    test = c.get("test", "?")
    path = c.get("path", "?")
    line = c.get("line", "?")
    verdict = c.get("verdict", "?")
    rationale = c.get("rationale", "")
    lines.append(f"- **{verdict}** — `{test}` ({path}:{line})")
    lines.append(f"  {rationale}")
lines.append("")
lines.append("---")
lines.append("")
lines.append("### 👍 / 👎 required — this is how we tune the classifier")
lines.append("")
lines.append("**Please react to this comment with 👍 if these calls are right, or 👎 "
             "if any are wrong.** Your reaction is the tuning signal we use to measure "
             "classifier precision and improve the calls over time. A 👎 with a one-line reply telling us which verdict "
             "was wrong is worth its weight in gold.")
lines.append("")
lines.append("This comment is advisory and non-blocking — it will never fail your build.")

print("\n".join(lines))
'
}

# Post ONE issue comment to the PR. Args: PR number, comment body.
post_comment_to_github() {
  local pr_number="$1"
  local body="$2"

  require_gh_cli "--post-comment was specified"

  local repo_slug
  if ! repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    echo "ERROR: could not determine repo from gh CLI." >&2
    exit 1
  fi

  echo "[test-classifier] Posting ONE classification comment to ${repo_slug} PR #${pr_number} via gh api..."
  # Pass the body via --field so gh handles JSON escaping for us; the issue
  # comments endpoint posts a single top-level PR conversation comment that
  # developers can react to with 👍/👎.
  if ! gh api \
        "repos/${repo_slug}/issues/${pr_number}/comments" \
        --method POST \
        --field body="${body}" >/dev/null; then
    echo "ERROR: 'gh api' call failed." >&2
    echo "       Check your gh auth status and that your token has 'issues: write'" >&2
    echo "       (or 'pull-requests: write')." >&2
    exit 1
  fi
  echo "[test-classifier] Comment posted. Awaiting the developer's mandatory 👍/👎 reaction."
}

# ── Phase 2: open a SEPARATE fix PR per fixable verdict (opt-in) ────────────
# For each classifications[] entry that carries a non-empty "fix" object, we
# branch off the ORIGINAL PR's head ref, `git apply` the proposed diff, commit,
# push, and open a PR whose base IS that head ref — so merging it folds the fix
# into the developer's PR, and (because we push/open with a PAT, not the default
# GITHUB_TOKEN) the repo's real CI runs on the fix PR and proves "the rest
# complies". TEST_BUG and APPLICATION_BUG get a fix; FLAKY_FAILURE and
# ENVIRONMENT_ISSUE never do (the AI omits "fix" for them).
#
# Args: PR number, original head ref, the extracted classifier JSON block.
open_fix_pr() {
  local pr_number="$1"
  local head_ref="$2"
  local classifier_json="$3"

  # The PAT is mandatory for this path: a GITHUB_TOKEN-opened PR does NOT trigger
  # the repo's CI, and validating the fix via CI is the whole point. Fail soft —
  # log clearly and skip, never crash the surrounding run.
  if [[ -z "${AI_FIX_PAT:-}" ]]; then
    ai_review::err "--propose-fixes requires the AI_FIX_PAT env var (a PAT with"
    ai_review::log "  pull-requests:write + contents:write). It must NOT be the default"
    ai_review::log "  GITHUB_TOKEN — a GITHUB_TOKEN-opened PR will not trigger the repo's"
    ai_review::log "  CI, and we need the fix PR's CI to run. Skipping fix-PR creation."
    return 0
  fi

  require_gh_cli "--propose-fixes was specified"

  if ! command -v python3 &>/dev/null; then
    ai_review::err "python3 is required to read fixes from the classifier JSON. Skipping fix-PR creation."
    return 0
  fi

  if [[ -z "${head_ref}" ]]; then
    ai_review::err "--propose-fixes requires the original PR's head ref, which could not be resolved. Skipping fix-PR creation."
    return 0
  fi

  local repo_slug
  if ! repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    ai_review::err "Could not determine repo from gh CLI. Skipping fix-PR creation."
    return 0
  fi

  # Emit one TAB-separated record per fixable classification:
  #   <index>\t<verdict>\t<base64 summary>\t<base64 rationale>\t<base64 diff>
  # We base64-encode the free-text/diff fields so embedded newlines and tabs
  # survive the line-oriented read loop below.
  local fixes
  fixes="$(echo "${classifier_json}" | python3 -c '
import base64, json, sys

try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"ERROR: could not parse classifier JSON for fixes: {e}", file=sys.stderr)
    sys.exit(1)

def b64(s):
    return base64.b64encode((s or "").encode("utf-8")).decode("ascii")

for i, c in enumerate(data.get("classifications", []), start=1):
    fix = c.get("fix")
    if not isinstance(fix, dict):
        continue
    diff = fix.get("diff") or ""
    if not diff.strip():
        continue
    verdict = c.get("verdict", "?")
    summary = fix.get("summary") or "apply proposed fix"
    rationale = c.get("rationale", "")
    print("\t".join([str(i), verdict, b64(summary), b64(rationale), b64(diff)]))
')" || {
    ai_review::err "Failed to extract fixes from classifier JSON. Skipping fix-PR creation."
    return 0
  }

  if [[ -z "${fixes}" ]]; then
    ai_review::info "No classifications carried an applyable 'fix' — nothing to propose."
    return 0
  fi

  # Make sure we have the original head ref locally to branch off it.
  if ! git rev-parse --verify --quiet "origin/${head_ref}" >/dev/null; then
    git fetch origin "${head_ref}" >/dev/null 2>&1 || true
  fi

  # Remember where we are so we can restore the working tree between fixes.
  local restore_ref
  restore_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "${restore_ref}" || "${restore_ref}" == "HEAD" ]]; then
    restore_ref="$(git rev-parse HEAD)"
  fi

  while IFS=$'\t' read -r idx verdict b64_summary b64_rationale b64_diff; do
    [[ -z "${idx}" ]] && continue

    local summary rationale diff fix_branch
    summary="$(printf '%s' "${b64_summary}" | base64 --decode)"
    rationale="$(printf '%s' "${b64_rationale}" | base64 --decode)"
    diff="$(printf '%s' "${b64_diff}" | base64 --decode)"
    fix_branch="ai-test-fix/${pr_number}-${idx}"

    ai_review::info "Preparing fix PR ${fix_branch} (${verdict}): ${summary}"

    # Branch off the ORIGINAL PR's head so the fix PR can target that head ref.
    if ! git checkout -B "${fix_branch}" "origin/${head_ref}" >/dev/null 2>&1; then
      ai_review::err "Could not create branch ${fix_branch} off origin/${head_ref}. Skipping this fix."
      git checkout "${restore_ref}" >/dev/null 2>&1 || true
      continue
    fi

    # Apply the proposed diff. If it does not apply cleanly, skip — never abort
    # the remaining fixes.
    if ! printf '%s\n' "${diff}" | git apply --index -; then
      ai_review::err "git apply failed for ${fix_branch} — diff did not apply cleanly. Skipping this fix."
      git checkout -- . >/dev/null 2>&1 || true
      git checkout "${restore_ref}" >/dev/null 2>&1 || true
      git branch -D "${fix_branch}" >/dev/null 2>&1 || true
      continue
    fi

    if ! git commit -m "fix(test-classifier-proposed): ${summary}" >/dev/null 2>&1; then
      ai_review::err "Nothing to commit (or commit failed) for ${fix_branch}. Skipping this fix."
      git checkout "${restore_ref}" >/dev/null 2>&1 || true
      git branch -D "${fix_branch}" >/dev/null 2>&1 || true
      continue
    fi

    # Push and open the PR with the PAT so the fix PR triggers the repo's CI.
    # Scope GH_TOKEN to just these calls via a subshell.
    local pr_body
    pr_body="$(printf '%s\n' \
      "Proposed fix for #${pr_number} from the AI test classifier (Phase 2)." \
      "" \
      "**Verdict:** ${verdict}" \
      "" \
      "**Rationale:** ${rationale}" \
      "" \
      "**Fix:** ${summary}" \
      "" \
      "CI on this PR validates the fix; merge to fold it into #${pr_number}.")"

    if (
      export GH_TOKEN="${AI_FIX_PAT}"
      # No --force: a bot must never clobber an existing branch. If the fix
      # branch already exists (a prior run for this PR/index), the push fails
      # and we skip rather than overwrite.
      git push "https://x-access-token:${AI_FIX_PAT}@github.com/${repo_slug}.git" \
        "${fix_branch}:${fix_branch}" >/dev/null 2>&1 || exit 1
      gh api "repos/${repo_slug}/pulls" \
        --method POST \
        --field title="[AI test fix] ${summary}" \
        --field head="${fix_branch}" \
        --field base="${head_ref}" \
        --field body="${pr_body}" >/dev/null || exit 1
    ); then
      ai_review::ok "Opened fix PR ${fix_branch} → base ${head_ref} (CI will validate it)."
    else
      ai_review::err "Failed to push/open fix PR ${fix_branch}. Skipping (other fixes continue)."
    fi

    git checkout "${restore_ref}" >/dev/null 2>&1 || true
  done <<< "${fixes}"
}

# ── Custom run loop (mirrors the security PR dispatcher) ────────────────────
test_classifier::run() {
  # Discover the PR (and inject --against into REMAINING_FOR_LIB).
  ai_review::discover_pr_context

  # ── Recursion guard ──────────────────────────────────────────────────────
  # When fix-PR creation is enabled we must NOT classify our own fix PRs, or the
  # classifier would loop on the PRs it just opened. Skip if the PR is authored
  # by the classifier bot OR its head branch is one of our fix branches. The
  # guard only engages when --propose-fixes is on (the token-wielding path); the
  # default classify+comment pilot behavior is never gated by it.
  if (( PROPOSE_FIXES == 1 )); then
    local _author="${AI_REVIEW_PR_AUTHOR:-}"
    local _head="${AI_REVIEW_PR_HEAD:-}"
    if [[ "${_author}" == *"[bot]" ]] \
       || [[ "${_author}" == "github-actions" ]] \
       || [[ "${_author}" == "github-actions[bot]" ]] \
       || [[ "${_head}" == ai-test-fix/* ]]; then
      ai_review::ok "Recursion guard: PR is bot-authored or on an ai-test-fix/ branch (author='${_author}', head='${_head}') — skipping classification."
      exit 0
    fi
  fi

  # Hand off remaining args to the library's parser.
  ai_review::parse_args "${REMAINING_FOR_LIB[@]+"${REMAINING_FOR_LIB[@]}"}"

  if ! ai_review::has_changes; then
    ai_review::ok "No change under test ($(ai_review::diff_command_description)) — nothing to classify."
    exit 0
  fi

  ai_review::resolve_tool

  if (( AI_REVIEW_DRY_RUN == 1 )); then
    ai_review::info "DRY-RUN — no AI invocation will be made."
    ai_review::log  "  Skill:          ${SKILL_HUMAN_NAME} (${SKILL_NAME})"
    ai_review::log  "  AI tool:        ${AI_REVIEW_TOOL_RESOLVED}"
    ai_review::log  "  PR number:      ${AI_REVIEW_PR_NUMBER:-(none — using --against directly)}"
    ai_review::log  "  Diff source:    $(ai_review::diff_command_description)"
    ai_review::log  "  Post comment:   ${POST_COMMENT}"
    ai_review::log  "  Gate mode:      ${GATE_MODE}"
    ai_review::log  "  Propose fixes:  ${PROPOSE_FIXES}"
    ai_review::log  "  Changed files:"
    ai_review::changed_files | sed 's/^/    /'
    exit 0
  fi

  ai_review::info "Running ${SKILL_HUMAN_NAME} on $(ai_review::diff_command_description) via ${AI_REVIEW_TOOL_RESOLVED}..."
  ai_review::log  "────────────────────────────────────────────────────────────"

  export AI_REVIEW_AGAINST

  local classifier_output
  local invoke_rc=0
  classifier_output="$(ai_review::invoke_ai)" || invoke_rc=$?

  if (( JSON_ONLY == 1 )); then
    extract_classifier_json "${classifier_output}"
  else
    printf '%s\n' "${classifier_output}"
    ai_review::log "────────────────────────────────────────────────────────────"
  fi

  if (( invoke_rc != 0 )); then
    ai_review::err "AI CLI (${AI_REVIEW_TOOL_RESOLVED}) exited with code ${invoke_rc}."
    exit 1
  fi

  local result
  result="$(ai_review::parse_result "${classifier_output}")"

  case "${result}" in
    CLASSIFIED)
      ai_review::info "Classifier result: CLASSIFIED"
      ;;
    NO_ACTION)
      ai_review::ok "Classifier result: NO_ACTION (nothing failed)."
      ;;
    *)
      ai_review::err "Could not parse classifier result marker."
      ai_review::log "  Expected one of:"
      ai_review::log "      <<<AI_REVIEW_RESULT:CLASSIFIED>>>"
      ai_review::log "      <<<AI_REVIEW_RESULT:NO_ACTION>>>"
      exit 1
      ;;
  esac

  # ── Post ONE PR comment requesting a mandatory 👍/👎 reaction. ────────────
  # This is the default behavior. --post-comment is what CI passes to actually
  # post; omit it for a local dry view (the JSON/report still prints to stdout).
  # Nothing is posted when nothing was triaged (NO_ACTION).
  if (( POST_COMMENT == 1 )); then
    if [[ "${result}" == "NO_ACTION" ]]; then
      ai_review::info "Result is NO_ACTION — nothing to triage, so no PR comment is posted."
    else
      if [[ -z "${AI_REVIEW_PR_NUMBER:-}" ]]; then
        ai_review::err "--post-comment requires a discoverable PR. Use --pr <number> or ensure 'gh pr view' resolves."
        exit 1
      fi
      local json_block
      json_block="$(extract_classifier_json "${classifier_output}")"
      if [[ -z "${json_block}" ]]; then
        ai_review::err "AI response did not contain a parseable JSON block."
        ai_review::log "  Expected fenced block bounded by:"
        ai_review::log "      <!-- AI_CLASSIFIER_JSON_BEGIN -->"
        ai_review::log "      <!-- AI_CLASSIFIER_JSON_END -->"
        exit 1
      fi
      local comment_body
      comment_body="$(render_pr_comment_body "${json_block}")"
      post_comment_to_github "${AI_REVIEW_PR_NUMBER}" "${comment_body}"
    fi
  fi

  # ── Phase 2 (opt-in): open a SEPARATE fix PR per fixable verdict. ─────────
  # Additive and strictly gated on --propose-fixes — the default path above is
  # untouched. Only runs when there is something to triage (CLASSIFIED) and a
  # PR is discoverable. open_fix_pr() fails soft (logs + skips) if AI_FIX_PAT is
  # missing or a diff does not apply, so it never crashes the surrounding run.
  if (( PROPOSE_FIXES == 1 )) && [[ "${result}" == "CLASSIFIED" ]]; then
    if [[ -z "${AI_REVIEW_PR_NUMBER:-}" ]]; then
      ai_review::warn "--propose-fixes needs a discoverable PR (use --pr <number> or ensure 'gh pr view' resolves); skipping fix-PR creation."
    else
      local fix_json_block
      fix_json_block="$(extract_classifier_json "${classifier_output}")"
      if [[ -z "${fix_json_block}" ]]; then
        ai_review::warn "--propose-fixes: AI response had no parseable JSON block; skipping fix-PR creation."
      else
        open_fix_pr "${AI_REVIEW_PR_NUMBER}" "${AI_REVIEW_PR_HEAD:-}" "${fix_json_block}"
      fi
    fi
  fi

  # ── --gate mode: exit non-zero when tests were classified. ────────────────
  # The classifier is advisory by default; --gate is for teams who want a red
  # build when the classifier triages any failing test.
  if (( GATE_MODE == 1 )) && [[ "${result}" == "CLASSIFIED" ]]; then
    if (( AI_REVIEW_NO_BLOCK == 1 )); then
      ai_review::warn "--gate would fail the build (result CLASSIFIED), but --no-block is set; exiting 0."
      exit 0
    fi
    ai_review::err "--gate mode: result is CLASSIFIED, exiting non-zero to fail the build."
    exit 1
  fi

  exit 0
}

test_classifier::run
