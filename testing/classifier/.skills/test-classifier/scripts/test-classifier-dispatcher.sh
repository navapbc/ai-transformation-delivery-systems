#!/usr/bin/env bash
# .skills/test-classifier/scripts/test-classifier-dispatcher.sh
#
# Test-classifier dispatcher. Runs the test-classifier skill on the change
# under test and posts ONE PR comment with the verdicts. The helpfulness signal
# is captured locally at run time via the --submit terminal prompt (not a GitHub
# 👍/👎 reaction).
#
# This dispatcher is the testing-workstream sibling of the security
# workstream's pr-review-dispatcher.sh and intentionally mirrors its shape.
# It differs from a pre-commit dispatcher in three ways:
#
#   1. It computes its diff range from a pull-request base ref, not from the
#      git index. Auto-discovery uses `gh pr view`; manual override via --pr.
#   2. It parses a JSON intermediate format from the AI's response. With
#      --post-comment it uses the GitHub REST API (via `gh api`) to post ONE
#      file-level review comment on the PR with the classification table. It
#      anchors to a changed file when it can (falling back to an issue comment if
#      the PR has no diff to anchor to). On a CI / plain --post-comment run the
#      comment carries a 👍/👎 reaction ask (the async tuning signal the metricsai
#      harvester reads off GitHub); on a local --submit run it omits the ask
#      because the signal is captured by --submit's terminal prompt instead.
#   3. The classifier is advisory: by default the dispatcher exits 0 even when
#      tests were classified. The --gate flag flips this to exit 1 when the
#      result is CLASSIFIED (CI-blocking mode for teams that want it).
#
# Behavior: classify the failing tests and post ONE PR comment with the verdicts.
# Posting requires --post-comment; without it the report/JSON only prints (useful
# for a local dry view). Nothing is posted when nothing was triaged. Two tuning-
# signal surfaces, both supported: the posted comment's 👍/👎 reaction (read by the
# metricsai weekly harvest) on CI/--post-comment runs, and a terminal "helpful?"
# prompt written straight to the Testing Events sheet on local runs. That prompt
# fires BY DEFAULT on any interactive run when METRICSAI_WEBHOOK_URL/_KEY are set
# — no --submit needed; --submit just forces it explicitly. A failed sheet write
# is surfaced loudly but is non-fatal (the run still exits 0).
#
# Usage:
#   test-classifier-dispatcher.sh                              # no args → --unpushed (local committed+staged, report-only)
#   test-classifier-dispatcher.sh origin/main                  # bare ref → --against origin/main
#   test-classifier-dispatcher.sh --pr 1234 --post-comment     # post the PR comment
#   test-classifier-dispatcher.sh --pr 1234 --submit           # force the "helpful?" prompt + row (auto when webhook env is set)
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
# Absolute path to the skill file. MUST be absolute: the agent's CWD is the repo
# root, but the bundle lives under testing/classifier/ (and can be vendored at any
# depth), so a path relative to the bundle root would not resolve from the agent's
# CWD — it would 404 on the first Read and force a recovery `find`. Absolute always
# resolves regardless of where the bundle sits or where the agent is invoked.
SKILL_PATH_CANONICAL="${SKILLS_ROOT}/test-classifier/SKILL.md"

# ── Classifier-specific arg parsing ────────────────────────────────────────
# We intercept our own flags first, then pass the remainder to the shared
# library's parser. Recognized flags here:
#
#   --pr <number>         Explicit PR number (overrides auto-discovery)
#   --post-comment        Post ONE PR comment via gh api (omit to print only)
#   --submit              Explicitly force the "Was this helpful?" prompt + the
#                         Testing Events row, and (for back-compat) implies
#                         --post-comment. NOTE: the prompt + row already happen
#                         BY DEFAULT on any interactive run when the webhook env
#                         vars are set — so --submit is only needed to also post
#                         the comment, or to be explicit. Non-TTY/CI: skipped.
#   --gate                Exit 1 if the result is CLASSIFIED (CI-blocking mode)
#   --json-only           Print only the JSON block (machine consumption)
#   --no-run-suite        Read-only INFERRED pass: do NOT run the repo's suite
#                         (predict from the diff). The default is OBSERVED (run
#                         the suite); use this to triage an UNTRUSTED diff
#                         without executing its code. Same as AI_RUN_SUITE=0.
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
SIMULATE=0
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
    --no-run-suite)
      # Opt out of the OBSERVED default: read-only, predict from the diff
      # (INFERRED). Exported so the sourced lib and the agent see it.
      export AI_RUN_SUITE=0
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
    --simulate)
      # Skip the AI agent entirely and feed a synthetic classifier result
      # through the real posting/metrics path — validate the comment + 👍/👎 +
      # Testing Events pipeline without a live (slow/costly) agent run. Pair with
      # --post-comment / --submit to actually post + record. Set
      # AI_SIMULATE_RESULT=NO_ACTION to exercise the true-negative path;
      # defaults to a CLASSIFIED filler.
      SIMULATE=1
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

# Resolve the owner/name slug of the repo the PR lives in, from the `origin`
# remote — NOT `gh repo view`. On a fork, `gh repo view` resolves to the PARENT
# repo (e.g. a navapbc/ai-chatbot checkout reports vercel/chatbot), so posting
# and the metrics row would target the wrong repo. `origin` is the fork you are
# actually working in and whose PR number you passed. Override with AI_REVIEW_REPO
# (owner/name) for the rare cross-remote case. Cached after first resolution.
AI_REVIEW_REPO_SLUG=""
ai_review::repo_slug() {
  if [[ -n "${AI_REVIEW_REPO_SLUG}" ]]; then
    printf '%s' "${AI_REVIEW_REPO_SLUG}"; return 0
  fi
  if [[ -n "${AI_REVIEW_REPO:-}" ]]; then
    AI_REVIEW_REPO_SLUG="${AI_REVIEW_REPO}"
    printf '%s' "${AI_REVIEW_REPO_SLUG}"; return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    echo "ERROR: no 'origin' remote — cannot determine which repo the PR lives in." >&2
    echo "       Set one (git remote add origin <url>) or export AI_REVIEW_REPO=owner/name." >&2
    return 1
  fi
  # Normalize both forms to owner/name:
  #   https://github.com/owner/name(.git)   git@github.com:owner/name(.git)
  local slug="${url}"
  slug="${slug#*github.com[:/]}"   # strip scheme/host up to owner
  slug="${slug%.git}"              # strip trailing .git
  if [[ ! "${slug}" =~ ^[^/]+/[^/]+$ ]]; then
    echo "ERROR: could not parse owner/name from origin URL: ${url}" >&2
    echo "       Export AI_REVIEW_REPO=owner/name to set it explicitly." >&2
    return 1
  fi
  AI_REVIEW_REPO_SLUG="${slug}"
  printf '%s' "${AI_REVIEW_REPO_SLUG}"
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
  #
  # Works for OPEN, CLOSED, and MERGED PRs — `gh pr view` returns baseRefName for
  # any state (PR state does not gate this). The one real failure mode is repo
  # mismatch: we pin to origin's slug (the #64 fork fix), but if the PR actually
  # lives on a DIFFERENT repo than origin (e.g. the PR is on the upstream/parent,
  # or the user relies on `gh repo set-default`), the origin-pinned lookup finds
  # nothing. So: try origin first, then fall back to gh's OWN default resolution
  # (no -R), and adopt whichever repo actually resolved so posting + the metrics
  # row target the right place. AI_REVIEW_REPO overrides everything.
  if [[ -n "${PR_NUMBER}" ]]; then
    require_gh_cli "PR number was specified via --pr"
    local repo_slug base resolved_slug=""
    repo_slug="$(ai_review::repo_slug)" || exit 1

    # 1) origin-pinned lookup (the common/fork case).
    base="$(gh pr view "${PR_NUMBER}" -R "${repo_slug}" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
    if [[ -n "${base}" ]]; then
      resolved_slug="${repo_slug}"
    elif [[ -z "${AI_REVIEW_REPO:-}" ]]; then
      # 2) Fall back to gh's own repo resolution (no -R) — handles a PR that lives
      #    on a repo other than origin (upstream, or a gh default). Skipped when
      #    AI_REVIEW_REPO was set explicitly (the caller pinned it on purpose).
      base="$(gh pr view "${PR_NUMBER}" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
      if [[ -n "${base}" ]]; then
        resolved_slug="$(gh pr view "${PR_NUMBER}" --json headRepositoryOwner,headRepository \
                          --jq '.headRepositoryOwner.login + "/" + .headRepository.name' 2>/dev/null || true)"
        [[ -z "${resolved_slug}" ]] && resolved_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
        if [[ -n "${resolved_slug}" ]]; then
          echo "[test-classifier] PR #${PR_NUMBER} not found on origin (${repo_slug}); using ${resolved_slug} (gh's resolution)." >&2
          AI_REVIEW_REPO_SLUG="${resolved_slug}"   # adopt it for posting + metrics
        fi
      fi
    fi

    if [[ -z "${base}" ]]; then
      echo "ERROR: could not look up PR #${PR_NUMBER}." >&2
      echo "       It was not found on '${repo_slug}' (from your 'origin' remote)$([ -z "${AI_REVIEW_REPO:-}" ] && echo " or via gh's default repo")." >&2
      echo "       PR state (open/closed/merged) does NOT matter — this is a repo/access issue:" >&2
      echo "         • If the PR lives on a different repo, set it: AI_REVIEW_REPO=owner/name test-classifier --pr ${PR_NUMBER} …" >&2
      echo "         • Or check 'gh pr view ${PR_NUMBER}' works and your token has access to that repo." >&2
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
  # rather than scraping the raw JSON with brittle regexes. Pin to origin's slug
  # so a fork checkout discovers its OWN PR, not the parent repo's.
  local repo_slug
  repo_slug="$(ai_review::repo_slug)" || exit 1
  AI_REVIEW_PR_NUMBER="$(gh pr view -R "${repo_slug}" --json number --jq '.number' 2>/dev/null || true)"
  AI_REVIEW_PR_BASE="$(gh pr view -R "${repo_slug}" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"

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
# Step 1 (the failing-test signal) is mode-dependent: with AI_RUN_SUITE=1 (the
# default) the agent has shell execution and must locate + run the suite
# (OBSERVED); with AI_RUN_SUITE=0 (--no-run-suite) it predicts from the diff
# (INFERRED). See SKILL.md Step 1 for the full procedure. This default must match
# the lib's (ai-classifier-dispatch.sh) — both default to 1 (OBSERVED).
if [[ "${AI_RUN_SUITE:-1}" == "1" ]]; then
  read -r -d '' SIGNAL_STEP <<'SIGNAL' || true
  1. Collect the failing-test signal in OBSERVED mode (AI_RUN_SUITE=1 — you have
     shell execution): LOCATE this repo's test command (package.json scripts,
     Makefile, pytest/tox, go.mod, Cargo.toml, or its CI workflow's test step),
     INSTALL deps from the repo's lockfile (best-effort), and RUN the suite to
     get the real pass/fail output.

     RUN THE NARROWEST TEST TARGET, NOT A FULL BUILD. You are time-bounded. Do
     NOT trigger a whole-project build when a targeted test run exists — building
     everything before the suite is the single biggest cause of timeouts.
       - Multi-module Maven/Gradle: run tests for the changed module(s) only,
         e.g. `mvn -pl <changed-module> -am test` (or `-Dtest=...` for specific
         classes), or `gradle :<module>:test`. Do NOT run the root reactor build
         (`mvn test` / `mvn verify` at the root). Skip unrelated lifecycle phases
         where possible (`-DskipITs`, `-Dcheckstyle.skip`) so time goes to tests.
       - Other ecosystems: scope to the changed package / path (e.g.
         `pytest path/to/changed_tests`, `go test ./changedpkg/...`,
         `npm test -- <pattern>`) rather than the entire suite when the diff is
         local.
     Set "mode":"OBSERVED" in the JSON. If you cannot locate/install/run it (no
     suite, missing toolchain, needs services, times out), OR the only available
     path is a full build that would not finish in time, fall back to predicting
     from the diff, set "mode":"INFERRED", and state the reason in "summary".

     BUDGET DISCIPLINE — you have a bounded number of agentic turns; a turn is
     one assistant iteration, not one tool call, so batch independent lookups
     and chain setup steps with && into one command. Derive the bootstrap from
     the repo FIRST (its own setup entry point, else its CI workflow) instead
     of guessing package managers by trial and error. Run the suite ONCE as a
     blocking command — don't poll with sleep/pgrep. For a LARGE diff, if you
     have a subagent tool (Claude Code Task/Agent), delegate discovery to it
     (one parent turn; give it the paths/questions — it can't see your
     history); codex/copilot have none, so keep discovery serial but batched.
     Near the budget, STOP and emit your best verdict rather than overflowing.
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

Classify the failing tests for the change under test. The dispatcher precomputed
a candidate git range in the AI_REVIEW_DIFF_RANGE env var (base→HEAD normally;
base→index for a local --unpushed run). START there:

  git diff \$AI_REVIEW_DIFF_RANGE --name-only
  git diff \$AI_REVIEW_DIFF_RANGE --unified=5

IMPORTANT — verify the range actually reflects the change under test; do NOT
treat AI_REVIEW_DIFF_RANGE as gospel. The precomputed base (often \`origin/<base>\`)
can be WRONG or empty when the PR lives on a different repo than the local
\`origin\`, on a fork, or on an enterprise host (e.g. github.cms.gov), or when
\`origin/<base>\` is stale or absent. If \`git diff \$AI_REVIEW_DIFF_RANGE --name-only\`
is EMPTY or obviously not this PR's change, RE-RESOLVE the base yourself before
concluding there is nothing to classify:

  • This is a PR run when AI_REVIEW_PR_NUMBER is set; its repo is in
    AI_REVIEW_REPO_SLUG and its base branch in AI_REVIEW_PR_BASE.
  • Fetch the PR's base from its own repo and diff HEAD against what you fetched:
      gh pr view "\$AI_REVIEW_PR_NUMBER" -R "\$AI_REVIEW_REPO_SLUG" --json baseRefName,headRefOid
      # fetch the base ref from the PR's repo (works across remotes/hosts):
      url="\$(gh repo view -R "\$AI_REVIEW_REPO_SLUG" --json url --jq .url)"
      git fetch "\$url" "\$AI_REVIEW_PR_BASE"
      git diff FETCH_HEAD HEAD --name-only
      git diff FETCH_HEAD HEAD --unified=5
  • For a local --unpushed run (no PR number), fall back to the merge-base with
    the remote default branch, or the last pushed commit, as the base.

Use whichever range genuinely captures the change under test. State in the JSON
"summary" which base you used if you had to re-resolve it.

Follow the skill instructions in that SKILL.md file (path above) exactly:

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
     e2e-form-flow-drift | other), "confidence" (high | medium | low),
     "in_scope" (boolean — true if the failure is part of the change under test,
     false if it is a pre-existing/unrelated failure surfaced by the full suite;
     omitted ⇒ true), and a one-to-two-sentence "rationale". (This JSON contract is owned by the CI
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
# Document the dispatcher's own flags + defaulting via the lib's addendum hook —
# the shared --against/--unpushed/--dry-run/etc. are already covered by the lib.
if (( WANT_HELP == 1 )); then
  read -r -d '' AI_REVIEW_HELP_ADDENDUM <<'HELP_ADDENDUM' || true
test-classifier options (in addition to the shared options above):
  --pr <number>        Explicit PR number for posting (overrides auto-discovery).
  --post-comment       Post ONE PR comment with the verdicts + a 👍/👎 reaction
                       ask (omitted when the local "helpful?" prompt captures the
                       signal). Omit for a report-only run (prints, posts nothing).
  --submit             Force the "Was this helpful?" prompt + Testing Events row,
                       and (back-compat) imply --post-comment. NOT usually needed:
                       the prompt + row already fire by default on an interactive
                       run when the webhook env vars are set (see below).
  --gate               Exit 1 when the result is CLASSIFIED (CI-blocking mode).
  --json-only          Print only the machine-readable JSON block.
  --no-run-suite       Read-only INFERRED pass: predict from the diff instead of
                       running the suite (the default). Use it on an UNTRUSTED
                       diff you don't want to execute. Same as AI_RUN_SUITE=0.

Defaults when no diff-range/PR selector is given:
  (no arguments)       → --unpushed (committed + staged; local, report-only).
  a bare ref           → --against <ref>, e.g.  test-classifier origin/main

Environment:
  AI_RUN_SUITE         Run the suite (OBSERVED, default) vs. infer from the diff.
                       OBSERVED is the default; set AI_RUN_SUITE=0 (or pass
                       --no-run-suite) for a read-only INFERRED pass.
  METRICSAI_WEBHOOK_URL / METRICSAI_WEBHOOK_KEY
                       When BOTH are set, an interactive run prompts "helpful?"
                       and writes a Testing Events row automatically (no --submit
                       needed). A failed write is surfaced but non-fatal.
HELP_ADDENDUM
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

# Render the ONE PR comment body from the classifier JSON. We use python3 because
# pure-bash JSON handling is brittle.
#
# Arg 2 (want_reaction_ask): "1" → append the 👍/👎 reaction ask (the async tuning
# signal the metricsai harvester reads off GitHub); "0" → omit it. The two posting
# surfaces differ: a CI run (--post-comment, no --submit) has no local prompt, so
# the comment MUST carry the ask; a local --submit run already captured the signal
# via its terminal prompt, so the ask would be redundant noise. Both surfaces stay
# supported — see the caller in test_classifier::run.
render_pr_comment_body() {
  local classifier_json="$1"
  local want_reaction_ask="${2:-1}"   # default: include the ask (CI / plain --post-comment)

  if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required to render the PR comment from classifier JSON." >&2
    exit 1
  fi

  echo "${classifier_json}" | python3 -c '
import json, sys
want_reaction_ask = (sys.argv[1] == "1") if len(sys.argv) > 1 else True

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

# Signal-provenance banner (shared by both branches) so a prediction is never
# mistaken for a real run.
if mode == "OBSERVED":
    banner = "> **Observed** — these verdicts are grounded in the actual test run output."
else:
    banner = ("> **Inferred, not observed** — the suite was not run for this triage, so these "
              "verdicts are predicted from the diff. See the summary for why.")

# True-negative branch: the agent ran and found nothing to triage. We STILL post
# a comment (not silence) so the developer can 👍/👎 it — that reaction is the
# only tuning signal a true negative can produce, and the metrics harvester needs
# a comment to attach the reaction to. Keep the same anchor line above so the
# harvester matches it by the `test-classifier:` prefix.
if not classifications:
    lines.append("## AI Test Classifier — no action required")
    lines.append("")
    lines.append(banner)
    lines.append("")
    lines.append(summary or "No failing tests were triaged for the change under test.")
    lines.append("")
    if want_reaction_ask:
        lines.append("**React 👍 if this is right (nothing needed triage) / 👎 if a real "
                     "failure was missed**, and on a 👎 please **reply with a one-line "
                     "reason**. Advisory, non-blocking.")
    else:
        lines.append("_Advisory, non-blocking — diagnostic only; the classifier never edits code or tests._")
    print("\n".join(lines))
    sys.exit(0)

lines.append("## AI Test Classifier — triage of failing tests")
lines.append("")
lines.append(banner)
lines.append("")
lines.append(summary)
lines.append("")
lines.append("| Verdict | Test | Confidence | Scope |")
lines.append("|---|---|---|---|")
for c in classifications:
    verdict = c.get("verdict", "?")
    test = c.get("test", "?")
    confidence = c.get("confidence", "?")
    # in_scope omitted means assume in-scope (a changes own failures are the
    # common case). False = a pre-existing/unrelated failure surfaced by the suite.
    in_scope = c.get("in_scope", True)
    scope = "change" if in_scope else "pre-existing"
    lines.append(f"| {verdict} | `{test}` | {confidence} | {scope} |")
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

# Footer. Two cases:
#  • want_reaction_ask (CI / plain --post-comment): ask for the 👍/👎 reaction —
#    this is the async tuning signal the metricsai harvester reads off GitHub, and
#    the place devs interact on the PR. Posted as a review comment with a Reply
#    thread so a 👎 can carry a one-line reason the harvester also reads back.
#  • else (local --submit): the signal was already captured by the terminal
#    prompt, so just an advisory footer — no redundant reaction ask.
if want_reaction_ask:
    lines.append("**React 👍 if right / 👎 if wrong**, and on a 👎 please **reply to this "
                 "comment with a one-line reason** — that reply is the most useful tuning "
                 "signal we get. Advisory, non-blocking.")
else:
    lines.append("_Advisory, non-blocking — diagnostic only; the classifier never edits code or tests._")

print("\n".join(lines))
' "${want_reaction_ask}"
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
  if ! ai_review::valid_comment_capture "$resp"; then
    echo "ERROR: 'gh api' issue-comment call failed." >&2
    echo "       Check your gh auth status and that your token has 'pull-requests: write'" >&2
    echo "       (or 'issues: write')." >&2
    return 1
  fi
  POSTED_COMMENT_ID="${resp%%$'\t'*}"
  POSTED_COMMENT_CREATED="${resp#*$'\t'}"
}

# Validate an "<id>\t<created_at>" capture from a comment-POST response. A real
# success has a NUMERIC id. On an API error (e.g. a 422), `gh ... --jq` may print
# the raw error JSON to stdout, which would otherwise be stored verbatim as the
# comment_id and poison the metrics row — so require a numeric leading field.
ai_review::valid_comment_capture() {
  local resp="$1"
  [[ -n "$resp" && "$resp" != $'\t' ]] || return 1
  local id="${resp%%$'\t'*}"
  [[ "$id" =~ ^[0-9]+$ ]]
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
  repo_slug="$(ai_review::repo_slug)" || exit 1

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
    if ai_review::valid_comment_capture "$resp"; then
      POSTED_COMMENT_ID="${resp%%$'\t'*}"
      POSTED_COMMENT_CREATED="${resp#*$'\t'}"
      echo "[test-classifier] Review comment posted."
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
  echo "[test-classifier] Comment posted (issue comment)."
}

# ── Prompt "Was this helpful?" and post one Testing Events row via the webhook ─
# Streamlines the manual local loop: instead of (post comment → react 👍/👎 on
# GitHub → a separate weekly harvest), capture the developer's signal right after
# the run and POST it to the metricsai Google Apps Script webhook — the SAME
# transport metricsai uses (flat JSON body, fields aligned by header name, plus
# reserved `_tab` and `_key`). No service account, no gcloud, no token expiry —
# just two static env vars the developer sets once.
#
# This runs by DEFAULT on any interactive run when the webhook env vars are set
# (see the auto_submit logic in test_classifier::run) — the developer no longer
# needs to pass --submit. The explicit --submit flag remains as an opt-in and is
# a no-op when auto-submit already applies.
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
# Gated: only runs interactively (TTY, not CI) — non-interactive runs skip the
# prompt + POST (no human signal to record, no hang). Missing URL/key → captures
# the answer in the terminal and warns, but writes no row. A failed POST is
# surfaced loudly (HTTP code + response body) but is NON-FATAL: the run exits 0
# because the classification itself succeeded.
#
# Args: PR number, the extracted classifier JSON.
submit_metrics_row() {
  local pr_number="$1"
  local classifier_json="$2"

  # Interactivity check: probe the CONTROLLING TERMINAL (/dev/tty), NOT fd 0.
  # The OBSERVED agent runs Bash tool subprocesses (pnpm install, vitest, …) with
  # the dispatcher's fd 0 as their stdin; those can consume it to EOF or leave it
  # non-TTY by the time we get here. Testing `[[ ! -t 0 ]]` then wrongly reports
  # "non-interactive" and silently skips the prompt — even though /dev/tty is
  # available and we could ask. The prompt below reads from /dev/tty, so the guard
  # must gate on the SAME thing: can we open /dev/tty? In CI / a real non-TTY run
  # there is no controlling terminal, so this still skips correctly.
  if [[ "${CI:-}" == "true" ]] || ! { : <>/dev/tty; } 2>/dev/null; then
    ai_review::info "metrics: non-interactive run (no controlling terminal) — skipping the helpfulness prompt + Testing Events row." >&2
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    ai_review::warn "metrics: python3 not found; cannot build the Testing Events row — skipping it." >&2
    return 0
  fi

  # Prompt for the tuning signal, reading from the controlling terminal.
  #
  # Read DIRECTLY from /dev/tty (open it fresh per read), NOT fd 0 and NOT a
  # persistent fd we manage. After a long OBSERVED run the agent's `claude` /
  # browser subprocesses can leave fd 0 consumed and the terminal in an odd
  # state; an earlier version kept /dev/tty open on fd 3 and drained type-ahead
  # with `read -t 0` in a loop — that loop could spin/block on the post-run
  # terminal and the prompt never appeared. A plain blocking `read … < /dev/tty`
  # is the robust, well-understood pattern: it waits for a real line of input.
  local answer="" reason="" thumbs_up=0 thumbs_down=0
  printf '%s' "  Was the classification helpful? [y/n] (enter to skip): " >&2
  IFS= read -r answer < /dev/tty || answer=""
  case "${answer}" in
    y|Y|yes|YES) thumbs_up=1 ;;
    n|N|no|NO)
      thumbs_down=1
      printf '%s' "  Optional one-line reason (enter to skip): " >&2
      IFS= read -r reason < /dev/tty || reason=""
      ;;
    *)
      # Empty Enter or anything unrecognized = skip (don't guess a verdict).
      ai_review::info "metrics: skipped (no y/n answer) — nothing recorded to the sheet." >&2
      return 0
      ;;
  esac

  local webhook_url="${METRICSAI_WEBHOOK_URL:-}"
  local webhook_key="${METRICSAI_WEBHOOK_KEY:-}"
  local webhook_tab="${METRICSAI_WEBHOOK_TAB:-Testing Events}"
  if [[ -z "${webhook_url}" || -z "${webhook_key}" ]]; then
    ai_review::warn "metrics: METRICSAI_WEBHOOK_URL / METRICSAI_WEBHOOK_KEY not set — captured your answer but didn't post a row." >&2
    ai_review::log  "  Export both (the metricsai webhook URL + the AI Metrics API key) to enable the sink." >&2
    return 0
  fi

  local repo_slug
  repo_slug="$(ai_review::repo_slug 2>/dev/null || echo "")"

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

  # True negative: no classifications, so `repr` is empty. Record an explicit
  # NO_ACTION verdict rather than a blank row so the sheet distinguishes "agent
  # ran, nothing to triage" (a real, countable true negative) from a missing row.
  if [[ -z "${verdict}" ]]; then
    verdict="NO_ACTION"
  fi

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
  # Capture BOTH the response body and the first-hop status so a real failure
  # (e.g. the Apps Script denying access to the sheet, an auth error, a 4xx/5xx)
  # is surfaced verbatim rather than reduced to a bare code. Body and status are
  # split on a trailing sentinel line we ask curl to append via -w.
  local resp http_code
  resp="$(curl -sS -X POST "${webhook_url}" \
        -H "Content-Type: application/json" \
        -d "${body}" -w $'\n__HTTP_CODE__:%{http_code}' 2>&1 || true)"
  http_code="$(printf '%s' "${resp}" | sed -n 's/.*__HTTP_CODE__:\([0-9]*\).*/\1/p' | tail -1)"
  [[ -n "${http_code}" ]] || http_code="000"
  local resp_body
  resp_body="$(printf '%s' "${resp}" | sed 's/__HTTP_CODE__:[0-9]*$//' | sed '/^$/d')"
  if [[ "${http_code}" == "200" || "${http_code}" == "302" ]]; then
    ai_review::ok "Recorded a Testing Events row (tab=${webhook_tab}, verdict=${verdict:-?}, $([ "${thumbs_up}" = 1 ] && echo 👍 || echo 👎))."
  else
    # Loud, but non-fatal: the classification itself succeeded, so we still
    # exit 0. Surface the HTTP code AND the response body so the user can see
    # WHY it failed (e.g. no access to the sheet) — don't swallow it.
    ai_review::warn "Testing Events row was NOT recorded — webhook POST failed (HTTP ${http_code})." >&2
    ai_review::warn "  Your y/n answer was captured locally but did not reach the sheet." >&2
    [[ -n "${resp_body}" ]] && ai_review::warn "  Webhook response: ${resp_body}" >&2
    ai_review::warn "  Check METRICSAI_WEBHOOK_URL / METRICSAI_WEBHOOK_KEY and that you have access to the target sheet." >&2
  fi
}

# Synthesize a classifier output for --simulate mode, byte-compatible with what
# a real agent emits: the fenced JSON block plus the trailing result marker. This
# lets the full downstream path (parse_result → extract_classifier_json →
# render_pr_comment_body → post_comment_to_github → submit_metrics_row) run
# without invoking the agent. Set AI_SIMULATE_RESULT=NO_ACTION to exercise the
# true-negative comment + row instead of the default CLASSIFIED table.
ai_review::synthetic_output() {
  local kind="${AI_SIMULATE_RESULT:-CLASSIFIED}"
  local mode="INFERRED"
  (( AI_RUN_SUITE == 1 )) && mode="OBSERVED"

  if [[ "${kind}" == "NO_ACTION" ]]; then
    cat <<SIM
[SIMULATED OUTPUT — no agent was invoked (--simulate).]

<!-- AI_CLASSIFIER_JSON_BEGIN -->
{ "mode": "${mode}", "summary": "SIMULATED: no failing tests were triaged (pipeline dry run).", "classifications": [] }
<!-- AI_CLASSIFIER_JSON_END -->

<<<AI_REVIEW_RESULT:NO_ACTION>>>
SIM
  else
    cat <<SIM
[SIMULATED OUTPUT — no agent was invoked (--simulate).]

<!-- AI_CLASSIFIER_JSON_BEGIN -->
{ "mode": "${mode}", "summary": "SIMULATED: filler triage for pipeline dry run (these verdicts are not real).", "classifications": [ { "verdict": "FLAKY_FAILURE", "test": "simulated::filler_test", "path": "SIMULATED", "line": 0, "category": "other", "confidence": "low", "in_scope": true, "rationale": "Synthetic entry produced by --simulate to exercise the posting/metrics path without a live agent run." } ] }
<!-- AI_CLASSIFIER_JSON_END -->

<<<AI_REVIEW_RESULT:CLASSIFIED>>>
SIM
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

  # --simulate skips the agent, so it does not need a resolved/installed AI CLI.
  if (( SIMULATE == 0 )); then
    ai_review::resolve_tool
  fi

  if (( AI_REVIEW_DRY_RUN == 1 )); then
    ai_review::info "DRY-RUN — no AI invocation will be made."
    ai_review::log  "  Skill:          ${SKILL_HUMAN_NAME} (${SKILL_NAME})"
    ai_review::log  "  AI tool:        ${AI_REVIEW_TOOL_RESOLVED:-(skipped — --simulate)}"
    ai_review::log  "  PR number:      ${AI_REVIEW_PR_NUMBER:-(none — using --against directly)}"
    ai_review::log  "  Diff source:    $(ai_review::diff_command_description)"
    ai_review::log  "  Post comment:   ${POST_COMMENT}"
    ai_review::log  "  Submit metrics: ${SUBMIT}"
    ai_review::log  "  Gate mode:      ${GATE_MODE}"
    ai_review::log  "  Changed files:"
    ai_review::changed_files | sed 's/^/    /'
    exit 0
  fi

  export AI_REVIEW_AGAINST
  # Export the PR context so the agent can re-resolve the diff itself when the
  # precomputed range below is empty/wrong (forks, enterprise hosts, stale
  # origin/<base>). These may be empty for a local --unpushed run.
  export AI_REVIEW_PR_NUMBER="${AI_REVIEW_PR_NUMBER:-}"
  export AI_REVIEW_PR_BASE="${AI_REVIEW_PR_BASE:-}"
  export AI_REVIEW_REPO_SLUG="${AI_REVIEW_REPO_SLUG:-}"

  # The git range the AI should diff, matching the dispatcher's own accounting:
  #   --unpushed (INCLUDE_STAGED) → `--cached <base>`  (committed + staged)
  #   otherwise                   → `<base> HEAD`      (committed range)
  # This is a STARTING POINT, not gospel — the prompt authorizes the agent to
  # re-resolve locally if it doesn't reflect the real change under test.
  if [[ "${AI_REVIEW_INCLUDE_STAGED:-0}" == "1" ]]; then
    AI_REVIEW_DIFF_RANGE="--cached ${AI_REVIEW_AGAINST}"
  else
    AI_REVIEW_DIFF_RANGE="${AI_REVIEW_AGAINST} HEAD"
  fi
  export AI_REVIEW_DIFF_RANGE

  local classifier_output
  local invoke_rc=0
  if (( SIMULATE == 1 )); then
    ai_review::info "SIMULATE — skipping the AI agent; feeding synthetic output (${AI_SIMULATE_RESULT:-CLASSIFIED}) through the real posting/metrics path."
    ai_review::log  "────────────────────────────────────────────────────────────"
    classifier_output="$(ai_review::synthetic_output)"
  else
    ai_review::info "Running ${SKILL_HUMAN_NAME} on $(ai_review::diff_command_description) via ${AI_REVIEW_TOOL_RESOLVED}..."
    ai_review::log  "────────────────────────────────────────────────────────────"
    classifier_output="$(ai_review::invoke_ai)" || invoke_rc=$?
  fi

  if (( JSON_ONLY == 1 )); then
    extract_classifier_json "${classifier_output}"
  else
    # Human-facing terminal output: drop the machine-only markers (JSON block +
    # result sentinel). Parsing below still uses the untouched classifier_output.
    strip_machine_markers "${classifier_output}"
    ai_review::log "────────────────────────────────────────────────────────────"
  fi

  if (( invoke_rc != 0 )); then
    # Turn-budget overflow is a soft outcome: no verdict, but exit 0 so the PR
    # check stays green-advisory rather than failing red. Bump AI_SUITE_MAX_TURNS
    # or set AI_RUN_SUITE=0 for a diff-only (INFERRED) pass.
    if ai_review::is_max_turns "${classifier_output}"; then
      ai_review::warn "AI Test Classifier: agent hit the turn budget (AI_SUITE_MAX_TURNS=${AI_SUITE_MAX_TURNS}) before emitting a verdict — no classification this run (non-blocking)."
      ai_review::warn "  Bump AI_SUITE_MAX_TURNS for more headroom, or set AI_RUN_SUITE=0 (--no-run-suite) for a fast diff-only (INFERRED) pass."
      exit 0
    fi
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

  # ── Decide whether to capture the helpfulness signal (the Testing Events row).
  # Historically this required the explicit --submit flag. Now it is the DEFAULT
  # on any interactive run when the metricsai webhook is configured: if both
  # METRICSAI_WEBHOOK_URL and METRICSAI_WEBHOOK_KEY are set AND we have a
  # controlling terminal AND tests were actually classified, we prompt y/n and
  # write the row — no --submit needed. --submit stays as an explicit opt-in
  # (and is a harmless no-op when auto-submit already applies). CI / non-TTY runs
  # never prompt (submit_metrics_row itself guards on /dev/tty). A failed write
  # is surfaced loudly but never fails the run — the classification still stands.
  local auto_submit=0
  if [[ -n "${METRICSAI_WEBHOOK_URL:-}" && -n "${METRICSAI_WEBHOOK_KEY:-}" ]] \
     && [[ "${CI:-}" != "true" ]] && { : <>/dev/tty; } 2>/dev/null \
     && { [[ "${result}" == "CLASSIFIED" ]] || [[ "${result}" == "NO_ACTION" ]]; }; then
    auto_submit=1
  fi
  local do_submit=0
  (( SUBMIT == 1 || auto_submit == 1 )) && do_submit=1

  # ── Post ONE PR comment with the verdicts. ────────────────────────────────
  # --post-comment is what CI passes to actually post; omit it for a local dry
  # view (the JSON/report still prints to stdout). A comment is posted on BOTH
  # results: CLASSIFIED (the verdict table) AND NO_ACTION (a "no action required"
  # comment). The true negative is posted so its 👍/👎 reaction can be harvested
  # by the metrics loop — suppressing it (the earlier behavior) made true
  # negatives invisible to tuning. render_pr_comment_body renders a dedicated
  # "no action required" body when classifications is empty. The comment carries
  # the 👍/👎 reaction ask on a CI/--post-comment run; when we capture the signal
  # via the terminal prompt (--submit or auto-submit) the ask is omitted.
  if (( POST_COMMENT == 1 )); then
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
    # Include the 👍/👎 reaction ask UNLESS we're capturing the signal via the
    # terminal prompt (--submit or auto-submit). CI / plain --post-comment →
    # ask (1); prompt-capturing run → no ask (0). Both surfaces stay alive.
    local want_reaction_ask=1
    (( do_submit == 1 )) && want_reaction_ask=0
    local comment_body
    comment_body="$(render_pr_comment_body "${json_block}" "${want_reaction_ask}")"
    post_comment_to_github "${AI_REVIEW_PR_NUMBER}" "${comment_body}"
  fi

  # ── Capture the helpfulness signal + write the Testing Events row. ─────────
  # Runs on --submit OR auto-submit, INDEPENDENT of whether a comment was posted:
  # a local report-only run with no PR still prompts and writes a row (with empty
  # comment fields). Fires on CLASSIFIED and NO_ACTION alike (a true negative is
  # a countable row); submit_metrics_row guards internally on TTY and no-ops in CI.
  if (( do_submit == 1 )) && { [[ "${result}" == "CLASSIFIED" ]] || [[ "${result}" == "NO_ACTION" ]]; }; then
    local json_block_submit
    json_block_submit="$(extract_classifier_json "${classifier_output}")"
    if [[ -n "${json_block_submit}" ]]; then
      submit_metrics_row "${AI_REVIEW_PR_NUMBER:-}" "${json_block_submit}"
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
