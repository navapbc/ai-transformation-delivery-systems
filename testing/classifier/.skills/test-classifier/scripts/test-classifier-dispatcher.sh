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
#      file-level review comment on the PR with the classification table and the
#      👍/👎 ask. A review comment (not an issue comment) so it has a Reply
#      thread: a 👎 can carry a one-line reason that the metrics harvester reads
#      back. Falls back to an issue comment if the PR has no diff to anchor to.
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
#   test-classifier-dispatcher.sh --dry-run                    # show plan, no AI call
#
# Required environment:
#   AI_REVIEW_TOOL          claude | codex | copilot
#
# Required when --post-comment is used:
#   gh CLI installed and authenticated; or GH_TOKEN exported

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
# Canonical skill text now lives in navapbc/agent-skills and is vendored by
# scripts/fetch-skills.sh into .skills-vendor/. Prefer the vendored copy; fall
# back to the in-repo .skills/ copy when the vendor dir is absent (e.g. fetch
# skipped, or pre-tag mock state). The dispatcher still owns the CI contract
# (JSON markers, result envelope) regardless of where the capability text loads.
if ! _REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
  _REPO_ROOT="$(cd "${SKILLS_ROOT}/../.." && pwd)"   # .skills → classifier → testing → repo root
fi
if [[ -f "${_REPO_ROOT}/.skills-vendor/test-classifier/SKILL.md" ]]; then
  SKILL_PATH_CANONICAL=".skills-vendor/test-classifier/SKILL.md"
else
  SKILL_PATH_CANONICAL=".skills/test-classifier/SKILL.md"
fi

# ── Classifier-specific arg parsing ────────────────────────────────────────
# We intercept our own flags first, then pass the remainder to the shared
# library's parser. Recognized flags here:
#
#   --pr <number>         Explicit PR number (overrides auto-discovery)
#   --post-comment        Post ONE PR comment via gh api (omit to print only)
#   --gate                Exit 1 if the result is CLASSIFIED (CI-blocking mode)
#   --json-only           Print only the JSON block (machine consumption)
#
# All other flags (--dry-run, --no-block, --against) fall through to the lib.

PR_NUMBER=""
POST_COMMENT=0
GATE_MODE=0
JSON_ONLY=0
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
  # If --against was passed, it wins for the diff range — no base-ref lookup
  # needed. But we still record --pr (when given) as the PR number so comment
  # posting has a target. This is the CI fast path: a caller that already knows
  # both the PR number and the base ref (e.g. the Jenkins adapter passing
  # CHANGE_ID + CHANGE_TARGET) supplies both flags and we skip `gh pr view`
  # entirely — gh is then needed only to post the comment.
  for arg in "${REMAINING_FOR_LIB[@]+"${REMAINING_FOR_LIB[@]}"}"; do
    if [[ "${arg}" == "--against" ]] || [[ "${arg}" == --against=* ]]; then
      if [[ -n "${PR_NUMBER}" ]]; then
        AI_REVIEW_PR_NUMBER="${PR_NUMBER}"
      fi
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
#
# Step 1 (the failing-test signal) is mode-dependent: with AI_RUN_SUITE=1 the
# agent has shell execution and must locate + run the suite (OBSERVED); otherwise
# it predicts from the diff (INFERRED). See SKILL.md Step 1 for the full procedure.
if [[ "${AI_RUN_SUITE:-0}" == "1" ]]; then
  read -r -d '' SIGNAL_STEP <<'SIGNAL' || true
  1. Collect the failing-test signal in OBSERVED mode (AI_RUN_SUITE=1 — you have
     shell execution): LOCATE this repo's test command (package.json scripts,
     Makefile, pytest/tox, go.mod, Cargo.toml, or its CI workflow's test step),
     INSTALL deps from the repo's lockfile (best-effort), and RUN the suite to
     get the real pass/fail output. Set "mode":"OBSERVED" in the JSON. If you
     cannot locate/install/run it (no suite, missing toolchain, needs services,
     times out), fall back to predicting from the diff, set "mode":"INFERRED",
     and state the reason in "summary".
SIGNAL
else
  read -r -d '' SIGNAL_STEP <<'SIGNAL' || true
  1. Collect the failing-test signal in INFERRED mode (no suite execution): reason
     statically over the diff and PREDICT which tests would fail and why. Set
     "mode":"INFERRED" in the JSON. Prefer lower confidence; FLAKY_FAILURE and
     ENVIRONMENT_ISSUE are generally not determinable from a diff alone.
SIGNAL
fi

read -r -d '' SKILL_PROMPT <<PROMPT || true
You have access to the test-classifier skill. The skill's full instructions are
in this repository at:

  ${SKILL_PATH_CANONICAL}

(The canonical skill text is published in navapbc/agent-skills and vendored here
by scripts/fetch-skills.sh; when the vendored copy is absent the in-repo
.skills/ copy is used. Either way, follow the file at the path above.)

Classify the failing tests for the change under test — the diff between
AI_REVIEW_AGAINST and HEAD:

  git diff "\$AI_REVIEW_AGAINST" HEAD --unified=5
  git diff "\$AI_REVIEW_AGAINST" HEAD --name-only

Follow the skill instructions in test-classifier/SKILL.md exactly:

${SIGNAL_STEP}
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
     exact markers on their own lines. The object MUST include a top-level
     "mode" of "OBSERVED" or "INFERRED" (per step 1), plus "summary" and a
     "classifications" array. Each classification entry has: "test", "path",
     "line", "verdict" (one of APPLICATION_BUG | TEST_BUG | FLAKY_FAILURE |
     ENVIRONMENT_ISSUE), "category" (visual-drift | behavioral-drift |
     e2e-form-flow-drift | other), "confidence" (high | medium | low), and a
     one-to-two-sentence "rationale". (This JSON contract is owned by the CI
     dispatcher, not the skill file.)

       <!-- AI_CLASSIFIER_JSON_BEGIN -->
       { "mode": "...", "summary": "...", "classifications": [ ... ] }
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

mode = str(data.get("mode", "INFERRED")).upper()
summary = data.get("summary", "AI test classifier triage of the failing tests.")
classifications = data.get("classifications", [])

lines = []
# Conventional-Comment label so the comment is greppable and the metrics
# harvester (testing/metrics/test_classifier_comments.sh) can identify it by a
# stable leading marker. Keep this in sync with CLASSIFIER_LABEL there.
# IMPORTANT: this anchor line must stay byte-identical — the banner goes AFTER it.
lines.append("test-classifier: AI triage of failing tests")
lines.append("")
lines.append("## AI Test Classifier — triage of failing tests")
lines.append("")
# Signal-provenance banner so a prediction is never mistaken for a real run.
if mode == "OBSERVED":
    lines.append("> **Observed** — these verdicts are grounded in the actual test run output.")
else:
    lines.append("> **Inferred, not observed** — the suite was not run for this triage, so these "
                 "verdicts are predicted from the diff. See the summary for why.")
lines.append("")
lines.append(summary)
lines.append("")
lines.append("| Verdict | Test | Confidence |")
lines.append("|---|---|---|")
for c in classifications:
    verdict = c.get("verdict", "?")
    test = c.get("test", "?")
    confidence = c.get("confidence", "?")
    lines.append(f"| {verdict} | `{test}` | {confidence} |")
lines.append("")

# Per-test rationales, collapsed by default so the comment stays scannable.
# Full detail is one click away (and also in the run artifact JSON).
if classifications:
    lines.append("<details><summary>Per-test rationale</summary>")
    lines.append("")
    for c in classifications:
        test = c.get("test", "?")
        path = c.get("path", "?")
        line = c.get("line", "?")
        verdict = c.get("verdict", "?")
        category = c.get("category", "other")
        rationale = c.get("rationale", "")
        lines.append(f"- **{verdict}** · {category} — `{test}` ({path}:{line})")
        lines.append(f"  {rationale}")
    lines.append("")
    lines.append("</details>")
    lines.append("")

# Tuning ask. The 👍/👎 reaction is the primary signal the metrics loop
# measures; because this is posted as a PR *review* comment it has a native
# Reply box, so a 👎 can now carry a one-line reason that the harvester picks
# up off the reply thread.
lines.append("**React 👍 if right / 👎 if wrong**, and on a 👎 please **reply to this "
             "comment with a one-line reason** — that reply is the most useful tuning "
             "signal we get. Advisory, non-blocking.")

print("\n".join(lines))
'
}

# Fallback: post ONE top-level issue comment to the PR. Args: repo slug, PR
# number, comment body. Used when the PR has no diff files to anchor a review
# comment to, or when the review-comment POST fails. Issue comments carry 👍/👎
# reactions but have no Reply thread (so a 👎 reason has nowhere to land) — hence
# this is the downgrade path, not the default.
post_issue_comment_to_github() {
  local repo_slug="$1"
  local pr_number="$2"
  local body="$3"

  # Pass the body via --field so gh handles JSON escaping for us.
  if ! gh api \
        "repos/${repo_slug}/issues/${pr_number}/comments" \
        --method POST \
        --field body="${body}" >/dev/null; then
    echo "ERROR: 'gh api' issue-comment call failed." >&2
    echo "       Check your gh auth status and that your token has 'pull-requests: write'" >&2
    echo "       (or 'issues: write')." >&2
    return 1
  fi
}

# Post ONE classification comment to the PR. Args: PR number, comment body.
#
# Posts as a file-level pull-request REVIEW comment (subject_type=file) so the
# comment gets a native Reply box — a 👎 can be followed by a one-line reason in
# the thread, which the metrics harvester reads back. Review comments must anchor
# to a path that is part of the PR diff, so we anchor to a changed file (the test
# verdicts are PR-level, so any changed file is a fine anchor). If there is no
# changed file or the review POST fails, we fall back to a plain issue comment so
# the classification is never silently dropped.
post_comment_to_github() {
  local pr_number="$1"
  local body="$2"

  require_gh_cli "--post-comment was specified"

  local repo_slug
  if ! repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    echo "ERROR: could not determine repo from gh CLI." >&2
    exit 1
  fi

  # Anchor path: a file in the PR diff. Prefer a changed test file if one is
  # present, since the comment is about test failures, but any changed file
  # works. We track the first file and the first test file as we stream the
  # diff, so we never index into the array (portable, and safe under set -u).
  local anchor_path="" first_file="" first_test=""
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -z "$first_file" ]] && first_file="$f"
    if [[ -z "$first_test" && "$f" =~ (test|spec|__tests__) ]]; then first_test="$f"; fi
  done < <(ai_review::changed_files)
  if [[ -n "$first_test" ]]; then
    anchor_path="$first_test"
  elif [[ -n "$first_file" ]]; then
    anchor_path="$first_file"
  fi

  # Head SHA the review comment pins to. gh resolves the PR's head; fall back to
  # the local checkout's HEAD when the API lookup is unavailable.
  local commit_id=""
  commit_id="$(gh api "repos/${repo_slug}/pulls/${pr_number}" --jq '.head.sha' 2>/dev/null || true)"
  [[ -z "$commit_id" ]] && commit_id="$(git rev-parse HEAD 2>/dev/null || true)"

  if [[ -n "$anchor_path" && -n "$commit_id" ]]; then
    echo "[test-classifier] Posting classification as a review comment on ${repo_slug} PR #${pr_number} (anchored to ${anchor_path})..."
    if gh api \
          "repos/${repo_slug}/pulls/${pr_number}/comments" \
          --method POST \
          --field body="${body}" \
          --field commit_id="${commit_id}" \
          --field path="${anchor_path}" \
          --field subject_type=file >/dev/null 2>&1; then
      echo "[test-classifier] Review comment posted. Awaiting the developer's 👍/👎 reaction (and a reply reason on a 👎)."
      return 0
    fi
    echo "[test-classifier] Review-comment POST failed; falling back to a plain issue comment." >&2
  else
    echo "[test-classifier] No changed file to anchor a review comment to; posting a plain issue comment." >&2
  fi

  # Fallback: plain issue comment (reaction-only, no reply thread).
  echo "[test-classifier] Posting ONE classification comment to ${repo_slug} PR #${pr_number} via gh api..."
  if ! post_issue_comment_to_github "${repo_slug}" "${pr_number}" "${body}"; then
    exit 1
  fi
  echo "[test-classifier] Comment posted (issue comment). Awaiting the developer's 👍/👎 reaction."
}

# ── Custom run loop (mirrors the security PR dispatcher) ────────────────────
test_classifier::run() {
  # Discover the PR (and inject --against into REMAINING_FOR_LIB).
  ai_review::discover_pr_context

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
