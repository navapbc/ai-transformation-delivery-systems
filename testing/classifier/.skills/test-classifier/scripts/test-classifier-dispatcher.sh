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
#   test-classifier-dispatcher.sh                              # no args → --unpushed (local committed+staged, report-only)
#   test-classifier-dispatcher.sh origin/main                  # bare ref → --against origin/main
#   test-classifier-dispatcher.sh --pr 1234 --post-comment     # post the PR comment
#   test-classifier-dispatcher.sh --pr 1234 --submit           # post + prompt "helpful?" + append a Testing Events row
#   test-classifier-dispatcher.sh --against origin/main        # explicit base ref
#   test-classifier-dispatcher.sh --unpushed                   # local: committed+staged, NO PR (report-only)
#   test-classifier-dispatcher.sh --json-only                  # emit only the JSON block
#   test-classifier-dispatcher.sh --gate                       # exit 1 on CLASSIFIED
#   test-classifier-dispatcher.sh --dry-run                    # show plan, no AI call
#
# Required environment:
#   AI_REVIEW_TOOL          claude | codex | copilot
#
# Required when --post-comment is used:
#   gh CLI installed and authenticated; or GH_TOKEN exported
#
# Required when --submit posts the metrics row (interactive runs only):
#   METRICSAI_WEBHOOK_URL + METRICSAI_WEBHOOK_KEY (the metricsai Apps Script
#   endpoint + the AI Metrics API key — both static, set once). Row posts to the
#   "Testing Events" tab (override: METRICSAI_WEBHOOK_TAB). Absent → posts the
#   comment + prompts but skips the row. Same transport metricsai uses; no
#   service account or gcloud token needed.

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
# Skill text lives in-repo and is the canonical source of truth (this bundle owns
# its skill — no external fetch).
BUNDLE_ROOT="$(cd "${SKILLS_ROOT}/.." && pwd)"   # .skills → classifier (bundle root)
SKILL_PATH_CANONICAL=".skills/test-classifier/SKILL.md"

# ── Classifier-specific arg parsing ────────────────────────────────────────
# We intercept our own flags first, then pass the remainder to the shared
# library's parser. Recognized flags here:
#
#   --pr <number>         Explicit PR number (overrides auto-discovery)
#   --post-comment        Post ONE PR comment via gh api (omit to print only)
#   --submit              Implies --post-comment; then (interactive only) prompts
#                         "Was this helpful?" and appends one Testing Events row
#                         to the Sheet with the verdict + 👍/👎. Non-TTY/CI: posts
#                         and skips the prompt + row.
#   --gate                Exit 1 if the result is CLASSIFIED (CI-blocking mode)
#   --json-only           Print only the JSON block (machine consumption)
#
# All other flags (--dry-run, --no-block, --against, --unpushed) fall through to
# the lib. --unpushed classifies the local committed+staged diff with NO PR —
# PR discovery is skipped and the run is report-only (nothing posts).

PR_NUMBER=""
POST_COMMENT=0
GATE_MODE=0
JSON_ONLY=0
WANT_HELP=0
SUBMIT=0
POSTED_COMMENT_ID=""        # set by the post functions; consumed by --submit
POSTED_COMMENT_CREATED=""   # the comment's created_at (ISO-8601) from the API
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
    --submit)
      # Streamlined local loop: post the comment AND, when run interactively,
      # prompt "Was this helpful?" and append the answer as one Testing Events
      # row to the Sheet. Implies --post-comment (the row needs the comment_id).
      SUBMIT=1
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
    -h|--help)
      # Defer: PR discovery runs before the lib's parser, so a bare --help left
      # for the lib would error on PR lookup before reaching the help text. We
      # can't print here either — the lib (which defines print_help) is sourced
      # below. Flag it and emit right after the source.
      WANT_HELP=1
      shift
      ;;
    *)
      REMAINING_FOR_LIB+=("$1")
      shift
      ;;
  esac
done

# ── Convenience defaulting (so callers/wrappers stay dumb) ──────────────────
# The shell wrapper that fronts this dispatcher is a one-line passthrough; the
# ergonomic defaults live HERE so they're versioned with the bundle and never
# drift out of a hand-pasted ~/.zshrc function. Applied only when the caller
# gave no diff-range/PR selector (--against / --unpushed / --pr) of its own:
#
#   • a bare ref (e.g. `origin/main`) → --against <ref>  (classify <ref>..HEAD)
#   • otherwise                       → --unpushed       (committed + staged,
#                                        local report-only backstop)
#
# Other flags (--dry-run, --json-only, --post-comment, …) pass through unchanged.
#
# We detect "did the caller already choose a range/PR?" by scanning the args
# bound for the lib for --against/--unpushed, plus our own --pr. If any is
# present we add nothing. This runs BEFORE discover_pr_context, which inspects
# REMAINING_FOR_LIB for --against/--unpushed to decide whether to skip PR lookup.
ai_classifier::has_range_selector() {
  [[ -n "${PR_NUMBER}" ]] && return 0
  local a
  for a in "${REMAINING_FOR_LIB[@]+"${REMAINING_FOR_LIB[@]}"}"; do
    case "$a" in
      --against|--against=*|--unpushed) return 0 ;;
    esac
  done
  return 1
}

if ! ai_classifier::has_range_selector; then
  # A bare positional (doesn't start with '-') is a base ref; the lib would
  # otherwise drop it into AI_REVIEW_REMAINING and ignore it. Rewrite it to
  # --against and keep any other flags (--dry-run, --json-only, …) intact.
  bare_ref="" rest=()
  for a in "${REMAINING_FOR_LIB[@]+"${REMAINING_FOR_LIB[@]}"}"; do
    if [[ -z "${bare_ref}" && "${a#-}" == "${a}" ]]; then bare_ref="$a"; else rest+=("$a"); fi
  done
  if [[ -n "${bare_ref}" ]]; then
    REMAINING_FOR_LIB=("--against" "${bare_ref}" "${rest[@]+"${rest[@]}"}")
  else
    # No range/PR/ref anywhere → default to the local unpushed backstop.
    REMAINING_FOR_LIB+=("--unpushed")
  fi
fi

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
  # --against (explicit base) and --unpushed (local committed+staged, no PR)
  # both fix the diff range without needing `gh pr view`. In either case skip
  # PR discovery: the library's parser resolves the range. With --unpushed there
  # is no PR, so comment posting stays disabled (the --post-comment guard below
  # errors on the empty PR number) — a local run is report-only by design.
  for arg in "${REMAINING_FOR_LIB[@]+"${REMAINING_FOR_LIB[@]}"}"; do
    if [[ "${arg}" == "--against" ]] || [[ "${arg}" == --against=* ]] \
       || [[ "${arg}" == "--unpushed" ]]; then
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

Follow the file at the path above.

Classify the failing tests for the change under test. The exact git range is in
the AI_REVIEW_DIFF_RANGE env var (base→HEAD normally; base→index, i.e. committed
+ staged, for a local --unpushed run). Use it verbatim:

  git diff \$AI_REVIEW_DIFF_RANGE --unified=5
  git diff \$AI_REVIEW_DIFF_RANGE --name-only

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

# --help was requested during arg parsing above; the lib (which defines the help
# text) is now loaded, so emit it and exit before any PR discovery / AI call.
if (( WANT_HELP == 1 )); then
  ai_review::print_help
  exit 0
fi

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

# Strip the machine-only markers from the AI output for HUMAN display: the
# JSON block (BEGIN→END inclusive) and the <<<AI_REVIEW_RESULT:…>>> line. These
# exist for parsing / PR-comment posting and are noise in a local terminal run.
# Parsing always uses the untouched ${classifier_output}; this only affects what
# is printed. Trailing blank lines left by the removal are collapsed.
strip_machine_markers() {
  local input="$1"
  printf '%s\n' "${input}" | awk '
    /<!-- AI_CLASSIFIER_JSON_BEGIN -->/ { skip=1; next }
    /<!-- AI_CLASSIFIER_JSON_END -->/   { skip=0; next }
    skip { next }
    /^<<<AI_REVIEW_RESULT:[A-Z_]+>>>[[:space:]]*$/ { next }
    { print }
  ' | awk 'NF { blanks=0; print; next } { blanks++; if (blanks<=1) print }'
}

# Compact, terminal-native summary of the verdicts — the actionable punchline a
# local developer needs, lifted out of the long markdown report. One line per
# failing test: VERDICT, file:line, confidence, and the one-line "what to do"
# action derived from the verdict (mirrors SKILL.md's taxonomy table). The skill
# is diagnostic-only, so this points at the side to fix; it never proposes a
# patch. Printed to STDERR so it never touches the parsed stdout. Best-effort:
# if python3 or the JSON is unavailable, we silently skip it (the full report
# above still stands).
render_terminal_summary() {
  local classifier_json="$1"
  command -v python3 &>/dev/null || return 0
  [[ -n "${classifier_json}" ]] || return 0

  AI_C_RED="${AI_C_RED}" AI_C_YELLOW="${AI_C_YELLOW}" AI_C_GREEN="${AI_C_GREEN}" \
  AI_C_BLUE="${AI_C_BLUE}" AI_C_BOLD="${AI_C_BOLD}" AI_C_RESET="${AI_C_RESET}" \
  python3 - "${classifier_json}" >&2 <<'PY'
import json, os, sys

RED=os.environ.get("AI_C_RED",""); YEL=os.environ.get("AI_C_YELLOW","")
GRN=os.environ.get("AI_C_GREEN",""); BLU=os.environ.get("AI_C_BLUE","")
BOLD=os.environ.get("AI_C_BOLD",""); RST=os.environ.get("AI_C_RESET","")

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

cls = data.get("classifications") or []
if not cls:
    sys.exit(0)

# verdict → (color, one-line action). Mirrors SKILL.md's "What it means / action".
ACTION = {
    "APPLICATION_BUG":  (RED, "Fix the CODE — the app regressed; the test caught a real defect."),
    "TEST_BUG":         (YEL, "Fix the TEST — the app is correct; the assertion is stale."),
    "FLAKY_FAILURE":    (BLU, "Re-run to confirm, then deflake — not a code/test-logic patch."),
    "ENVIRONMENT_ISSUE":(BLU, "Fix the ENV / re-run — neither the app nor the test is at fault."),
}

mode = data.get("mode","")
print(f"\n{BOLD}─── Test Classifier — {len(cls)} classified" + (f" ({mode})" if mode else "") + f" ───{RST}")
for c in cls:
    verdict = c.get("verdict","") or "UNKNOWN"
    color, action = ACTION.get(verdict, (RST, ""))
    loc = c.get("path","")
    line = c.get("line")
    if loc and line not in (None, ""):
        loc = f"{loc}:{line}"
    conf = c.get("confidence","")
    conf_s = f"  ({conf})" if conf else ""
    print(f"  {color}{verdict:<17}{RST} {loc}{conf_s}")
    if action:
        print(f"    {color}→{RST} {action}")
PY
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

  # Pass the body via --field so gh handles JSON escaping for us. Capture id +
  # created_at (for --submit's metrics row); empty string on failure.
  local resp=""
  resp="$(gh api \
        "repos/${repo_slug}/issues/${pr_number}/comments" \
        --method POST \
        --field body="${body}" --jq '"\(.id)\t\(.created_at)"' 2>/dev/null || true)"
  if [[ -z "$resp" || "$resp" == $'\t' ]]; then
    echo "ERROR: 'gh api' issue-comment call failed." >&2
    echo "       Check your gh auth status and that your token has 'pull-requests: write'" >&2
    echo "       (or 'issues: write')." >&2
    return 1
  fi
  POSTED_COMMENT_ID="${resp%%$'\t'*}"
  POSTED_COMMENT_CREATED="${resp#*$'\t'}"
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
    # Capture id + created_at from the response so --submit can record them.
    # jq joins them with a tab; empty string on failure.
    local resp=""
    resp="$(gh api \
          "repos/${repo_slug}/pulls/${pr_number}/comments" \
          --method POST \
          --field body="${body}" \
          --field commit_id="${commit_id}" \
          --field path="${anchor_path}" \
          --field subject_type=file --jq '"\(.id)\t\(.created_at)"' 2>/dev/null || true)"
    if [[ -n "$resp" && "$resp" != $'\t' ]]; then
      POSTED_COMMENT_ID="${resp%%$'\t'*}"
      POSTED_COMMENT_CREATED="${resp#*$'\t'}"
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

# ── --submit: prompt "Was this helpful?" and post one row via the webhook ───
# Streamlines the manual local loop: instead of (post comment → react 👍/👎 on
# GitHub → a separate weekly harvest), capture the developer's signal right after
# the run and POST it to the metricsai Google Apps Script webhook — the SAME
# transport metricsai uses (flat JSON body, fields aligned by header name, plus
# reserved `_tab` and `_key`). No service account, no gcloud, no token expiry —
# just two static env vars the developer sets once.
#
# Fields (aligned by header name on the Apps Script side):
#   repo, pr, comment_id, comment_created_at, verdict, category, confidence,
#   thumbs_up, thumbs_down, reason   (+ _tab="Testing Events", _key=<api key>)
#
# Env:
#   METRICSAI_WEBHOOK_URL   the Apps Script /exec endpoint        (required)
#   METRICSAI_WEBHOOK_KEY   the "AI Metrics" API key (body _key)  (required)
#   METRICSAI_WEBHOOK_TAB   destination tab; defaults to Testing Events
#
# Gated: only runs interactively (TTY, not CI) — non-interactive runs post the
# comment and skip the prompt + POST (no human signal to record, no hang).
# Missing URL/key → records the answer to the terminal, warns, still posts the
# comment.
#
# Args: PR number, the extracted classifier JSON.
submit_metrics_row() {
  local pr_number="$1"
  local classifier_json="$2"

  if [[ ! -t 0 ]] || [[ "${CI:-}" == "true" ]]; then
    ai_review::info "--submit: non-interactive run — comment posted; skipping the helpfulness prompt + metrics row." >&2
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    ai_review::warn "--submit: python3 not found; cannot build the metrics row — skipping it." >&2
    return 0
  fi

  # Prompt for the tuning signal. Empty/invalid → skip (don't guess a verdict).
  local answer reason="" thumbs_up=0 thumbs_down=0
  printf '%s' "  Was the classification helpful? [y/n] (enter to skip): " >&2
  read -r answer
  case "${answer}" in
    y|Y|yes|YES) thumbs_up=1 ;;
    n|N|no|NO)
      thumbs_down=1
      printf '%s' "  Optional one-line reason (enter to skip): " >&2
      read -r reason
      ;;
    *)
      ai_review::info "--submit: no answer — skipping the metrics row (comment still posted)." >&2
      return 0
      ;;
  esac

  local webhook_url="${METRICSAI_WEBHOOK_URL:-}"
  local webhook_key="${METRICSAI_WEBHOOK_KEY:-}"
  local webhook_tab="${METRICSAI_WEBHOOK_TAB:-Testing Events}"
  if [[ -z "${webhook_url}" || -z "${webhook_key}" ]]; then
    ai_review::warn "--submit: METRICSAI_WEBHOOK_URL / METRICSAI_WEBHOOK_KEY not set — recorded your answer but didn't post a row." >&2
    ai_review::log  "  Export both (the metricsai webhook URL + the AI Metrics API key) to enable the sink." >&2
    return 0
  fi

  local repo_slug
  repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"

  # The classifier may emit multiple classifications; the Testing Events row is
  # per-comment, so collapse to one representative verdict by most-actionable
  # rank (APPLICATION_BUG > TEST_BUG > FLAKY_FAILURE > ENVIRONMENT_ISSUE) — the
  # same rule the harvester uses. Returns: verdict<TAB>category<TAB>confidence.
  local repr
  repr="$(printf '%s' "${classifier_json}" | python3 -c '
import json, sys
RANK = {"APPLICATION_BUG":3,"TEST_BUG":2,"FLAKY_FAILURE":1,"ENVIRONMENT_ISSUE":0}
try:
    cls = (json.load(sys.stdin) or {}).get("classifications") or []
except Exception:
    cls = []
if not cls:
    print("\t\t"); sys.exit(0)
best = max(cls, key=lambda c: RANK.get(c.get("verdict",""), -1))
print("\t".join([best.get("verdict","") or "", best.get("category","") or "", best.get("confidence","") or ""]))
' 2>/dev/null || printf '\t\t')"
  local verdict category confidence
  IFS=$'\t' read -r verdict category confidence <<< "${repr}"

  # comment_created_at comes from the comment POST response; fall back to now.
  local created_at="${POSTED_COMMENT_CREATED:-}"
  [[ -n "${created_at}" ]] || created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

  # Flat JSON body: named fields (Apps Script aligns by header) + reserved
  # _tab / _key. Built with python3 so values are safely JSON-escaped.
  local body
  body="$(python3 -c '
import json, sys
keys = ["repo","pr","comment_id","comment_created_at","verdict","category",
        "confidence","thumbs_up","thumbs_down","reason","_tab","_key"]
print(json.dumps(dict(zip(keys, sys.argv[1:1+len(keys)]))))
' "${repo_slug}" "${pr_number}" "${POSTED_COMMENT_ID}" "${created_at}" "${verdict}" "${category}" "${confidence}" "${thumbs_up}" "${thumbs_down}" "${reason}" "${webhook_tab}" "${webhook_key}")"

  # The Apps Script writes the row in doPost and answers /exec with a 302 to a
  # googleusercontent URL. The WRITE has already happened at that 302 — following
  # it can 405 on the final Drive hop even though the row landed, so we must NOT
  # use `-f -L` (that reports a false failure). Capture the first-hop status and
  # treat 200/302 as success; don't follow the redirect.
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${webhook_url}" \
        -H "Content-Type: application/json" \
        -d "${body}" 2>/dev/null || echo "000")"
  if [[ "${http_code}" == "200" || "${http_code}" == "302" ]]; then
    ai_review::ok "--submit: posted a row to the metrics webhook (tab=${webhook_tab}, verdict=${verdict:-?}, $([ "${thumbs_up}" = 1 ] && echo 👍 || echo 👎))."
  else
    ai_review::warn "--submit: webhook POST failed (HTTP ${http_code}; your answer was not recorded). Check METRICSAI_WEBHOOK_URL / METRICSAI_WEBHOOK_KEY." >&2
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
    ai_review::log  "  Submit metrics: ${SUBMIT}"
    ai_review::log  "  Gate mode:      ${GATE_MODE}"
    ai_review::log  "  Changed files:"
    ai_review::changed_files | sed 's/^/    /'
    exit 0
  fi

  ai_review::info "Running ${SKILL_HUMAN_NAME} on $(ai_review::diff_command_description) via ${AI_REVIEW_TOOL_RESOLVED}..."
  ai_review::log  "────────────────────────────────────────────────────────────"

  export AI_REVIEW_AGAINST

  # The git range the AI should diff, matching the dispatcher's own accounting:
  #   --unpushed (INCLUDE_STAGED) → `--cached <base>`  (committed + staged)
  #   otherwise                   → `<base> HEAD`      (committed range)
  if [[ "${AI_REVIEW_INCLUDE_STAGED:-0}" == "1" ]]; then
    AI_REVIEW_DIFF_RANGE="--cached ${AI_REVIEW_AGAINST}"
  else
    AI_REVIEW_DIFF_RANGE="${AI_REVIEW_AGAINST} HEAD"
  fi
  export AI_REVIEW_DIFF_RANGE

  local classifier_output
  local invoke_rc=0
  classifier_output="$(ai_review::invoke_ai)" || invoke_rc=$?

  if (( JSON_ONLY == 1 )); then
    extract_classifier_json "${classifier_output}"
  else
    # Human-facing terminal output: drop the machine-only markers (JSON block +
    # result sentinel). Parsing below still uses the untouched classifier_output.
    strip_machine_markers "${classifier_output}"
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
      # Terminal-native actionable summary (verdict + file:line + what-to-do),
      # for a human run only. Skipped under --json-only (machine consumption).
      if (( JSON_ONLY != 1 )); then
        render_terminal_summary "$(extract_classifier_json "${classifier_output}")"
      fi
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
        ai_review::err "--post-comment requires a discoverable PR. Use --pr <number> or ensure 'gh pr view' resolves. (A --unpushed local run has no PR, so it is report-only — drop --post-comment.)"
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

      # --submit: prompt for the helpfulness signal and append a Testing Events
      # row (interactive only; no-ops cleanly in CI / non-TTY).
      if (( SUBMIT == 1 )); then
        submit_metrics_row "${AI_REVIEW_PR_NUMBER}" "${json_block}"
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
