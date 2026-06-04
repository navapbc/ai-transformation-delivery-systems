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
SKILL_PATH_CANONICAL=".skills/test-classifier/SKILL.md"

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

  testing/classifier/.skills/test-classifier/SKILL.md

(Tool-specific copies may also exist under .claude/skills/, .codex/skills/, or
.github/copilot/skills/; all are byte-identical to the canonical file above.)

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
     "mode" of "OBSERVED" or "INFERRED" (per step 1), plus "summary" and
     "classifications" as specified in test-classifier/SKILL.md section 6B:

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

# One-line tuning ask (👍/👎 is the signal the metrics loop measures).
lines.append("**React 👍 if right / 👎 if wrong** — your reaction tunes the classifier "
             "(a 👎 + one-line reason is gold). Advisory, non-blocking.")

print("\n".join(lines))
'
}

# Summarize the classifier JSON block to ONE representative verdict/category/
# confidence for the metrics row — same most-actionable priority the nightly
# harvester uses (APPLICATION_BUG > TEST_BUG > FLAKY_FAILURE > ENVIRONMENT_ISSUE),
# else the first classification. Prints "verdict<TAB>category<TAB>confidence".
summarize_classifier_json() {
  local json_block="$1"
  printf '%s' "${json_block}" | jq -r '
    (.classifications // []) as $cs
    | ( ["APPLICATION_BUG","TEST_BUG","FLAKY_FAILURE","ENVIRONMENT_ISSUE"]
        | map(. as $v | ($cs[] | select((.verdict // "") == $v))) | .[0] ) as $pick
    | ( $pick // ($cs[0] // {}) )
    | [ (.verdict // ""), (.category // ""), (.confidence // "") ] | @tsv
  ' 2>/dev/null || printf '\t\t'
}

# Append the metrics row for a just-posted classifier comment to the Google
# Sheet "Testing Events" tab, if the sink is configured. This is the POST-TIME
# writer: it fills the 7 fields known at post time
# (repo, pr, comment_id, comment_created_at, verdict, category, confidence) and
# leaves thumbs_up/thumbs_down blank — the nightly sweep backfills those from
# the comment's reactions later. Silent no-op unless BOTH GOOGLE_SHEETS_TOKEN
# and SHEET_ID are set; failure is logged but never fails the classifier run
# (the comment is already posted; metrics are best-effort).
append_metrics_row() {
  local repo="$1" pr="$2" comment_id="$3" created_at="$4" json_block="$5"
  [[ -n "${GOOGLE_SHEETS_TOKEN:-}" && -n "${SHEET_ID:-}" ]] || return 0

  local range="${SHEET_RANGE:-'Testing Events'!A1}"
  local verdict category confidence vcc
  vcc="$(summarize_classifier_json "${json_block}")"
  IFS=$'\t' read -r verdict category confidence <<<"${vcc}"

  local payload
  payload="$(jq -c -n \
    --arg repo "$repo" --arg pr "$pr" --arg cid "$comment_id" --arg ts "$created_at" \
    --arg v "$verdict" --arg cat "$category" --arg conf "$confidence" \
    '{ values: [[ $repo, $pr, $cid, $ts, $v, $cat, $conf, "", "" ]] }')"

  # Encode spaces/quotes in the range but NOT '!' (Sheets needs a literal
  # tab!cell separator; %21 makes the call fail).
  local enc="${range//\'/%27}"; enc="${enc// /%20}"
  if ! curl -sS -f -X POST \
        "https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values/${enc}:append?valueInputOption=RAW&insertDataOption=INSERT_ROWS" \
        -H "Authorization: Bearer ${GOOGLE_SHEETS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" >/dev/null 2>&1; then
    echo "[test-classifier] WARNING: metrics row append to the sheet failed (comment posted OK; nightly sweep will not have a row to backfill until this succeeds)." >&2
  else
    echo "[test-classifier] Metrics row appended to the sheet (reactions backfilled nightly)."
  fi
}

# Post ONE issue comment to the PR. Args: PR number, comment body, JSON block.
# On success, append the post-time metrics row (7 fields) to the sheet.
post_comment_to_github() {
  local pr_number="$1"
  local body="$2"
  local json_block="$3"

  require_gh_cli "--post-comment was specified"

  local repo_slug
  if ! repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    echo "ERROR: could not determine repo from gh CLI." >&2
    exit 1
  fi

  echo "[test-classifier] Posting ONE classification comment to ${repo_slug} PR #${pr_number} via gh api..."
  # Pass the body via --field so gh handles JSON escaping for us; the issue
  # comments endpoint posts a single top-level PR conversation comment that
  # developers can react to with 👍/👎. Capture the response so we can read the
  # new comment's id + created_at for the metrics row.
  local resp
  if ! resp="$(gh api \
        "repos/${repo_slug}/issues/${pr_number}/comments" \
        --method POST \
        --field body="${body}")"; then
    echo "ERROR: 'gh api' call failed." >&2
    echo "       Check your gh auth status and that your token has 'issues: write'" >&2
    echo "       (or 'pull-requests: write')." >&2
    exit 1
  fi
  echo "[test-classifier] Comment posted. Awaiting the developer's mandatory 👍/👎 reaction."

  # Post-time metrics writer (best-effort). The comment_id + created_at exist
  # only now, in the POST response.
  local comment_id created_at
  comment_id="$(printf '%s' "${resp}" | jq -r '.id // ""' 2>/dev/null)"
  created_at="$(printf '%s' "${resp}" | jq -r '.created_at // ""' 2>/dev/null)"
  if [[ -n "${comment_id}" ]]; then
    append_metrics_row "${repo_slug}" "${pr_number}" "${comment_id}" "${created_at}" "${json_block}"
  fi
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
      post_comment_to_github "${AI_REVIEW_PR_NUMBER}" "${comment_body}" "${json_block}"
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
