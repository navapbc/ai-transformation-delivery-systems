#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test_classifier_comments.sh — harvest 👍/👎 reactions on AI test-classifier PR
# comments, tie each reaction back to the classifier's machine-readable verdict,
# and emit a TSV suitable for copy-paste into a tracking sheet.
#
# This mirrors security/metrics/pr_review_comments.sh (same fetch_api retry +
# `jq -s` slurp helper, same REPOSITORIES array + date-range shape, same
# robustness against non-array API responses). It is the metrics counterpart of
# the TESTING workstream's classifier.
#
# ---------------------------------------------------------------------------
# What this measures
# ---------------------------------------------------------------------------
# The classifier posts ONE issue comment per CI run that has findings. Each
# comment carries:
#   1. A Conventional-Comment label `test-classifier:` so it is greppable and
#      so humans recognize it instantly (matches the security copilot format).
#   2. An embedded, machine-readable JSON verdict block delimited by the
#      classifier's markers (see testing/classifier/.skills/test-classifier/SKILL.md
#      section 6B):
#        <!-- AI_CLASSIFIER_JSON_BEGIN -->  { ...verdict... }  <!-- AI_CLASSIFIER_JSON_END -->
#      The block is a single object with a "classifications" array (one entry
#      per failing test); each entry has the shape:
#        {
#          "verdict":    "APPLICATION_BUG" | "TEST_BUG" | "FLAKY_FAILURE" | "ENVIRONMENT_ISSUE",
#          "category":   "visual-drift" | "behavioral-drift" | "e2e-form-flow-drift" | "other",
#          "confidence": "high" | "medium" | "low"
#        }
#      We summarize that array down to one representative row by most-actionable
#      verdict (APPLICATION_BUG > TEST_BUG > FLAKY_FAILURE > ENVIRONMENT_ISSUE),
#      else the first entry.
#   3. A request for a MANDATORY 👍 / 👎 reaction from the developer. That
#      reaction is the tuning signal: 👍 = "classifier called it right",
#      👎 = "classifier called it wrong".
#
# For each classifier comment we record:
#   repo, pr, comment_id, verdict, category, confidence, thumbs_up, thumbs_down
#
# Those rows are the *classifier-precision inputs*: pairing each verdict with
# its 👍/👎 lets us compute the 👍-rate per verdict bucket over time.
#
# ---------------------------------------------------------------------------
# Identifying a classifier comment (the stable marker)
# ---------------------------------------------------------------------------
# We use TWO independent signals and require BOTH so we never miscount an
# unrelated bot comment:
#   - Author == TARGET_USER (the CI bot that posts classifier comments), AND
#   - Body begins with the Conventional-Comment label `test-classifier:`.
# The embedded JSON block is parsed best-effort; a comment with the label but
# no parseable JSON still counts (verdict/category/confidence fall back to "").
#
# ---------------------------------------------------------------------------
# Output / sinks
# ---------------------------------------------------------------------------
# DEFAULT: a TSV written to stdout, one row per
# classifier comment, with a header line. Copy-paste straight into a sheet.
#
# OPTIONAL Google Sheets sink: if BOTH GOOGLE_SHEETS_TOKEN and SHEET_ID are set
# in the environment, each row is also appended to the sheet via the Sheets API
# values:append endpoint. If either is unset we silently skip the sink and only
# print the TSV — no error, no noise.
#
#   Google Sheets service-account setup (shareable with Brian's metrics):
#     1. Create a Google Cloud service account; grant it nothing at the project
#        level. Share the TARGET spreadsheet with the service account's email
#        as an Editor (this is the only access it needs — least privilege).
#     2. Mint a short-lived OAuth2 bearer token for that service account with
#        the read+write scope:
#          https://www.googleapis.com/auth/spreadsheets
#        e.g. `gcloud auth print-access-token --impersonate-service-account=...`
#        or your CI's workload-identity exchange. Export it as:
#          export GOOGLE_SHEETS_TOKEN="ya29.<token>"
#     3. Keep SHEET_ID STATIC (the spreadsheet ID from its URL,
#        /spreadsheets/d/<SHEET_ID>/edit). Export it as:
#          export SHEET_ID="1AbC...xyz"
#        Optionally override the tab/range with SHEET_RANGE (default below).
#     The token is short-lived; the sheet ID is permanent. Never commit either.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   ./test_classifier_comments.sh                 # TSV to stdout (default)
#   ./test_classifier_comments.sh > rows.tsv      # capture for paste
#   GOOGLE_SHEETS_TOKEN=... SHEET_ID=... ./test_classifier_comments.sh   # + Sheets sink
#   DEBUG=1 ./test_classifier_comments.sh         # per-PR fetched/matched counts to stderr
# =============================================================================

# --- Configuration ---
REPOSITORIES=(
  "navapbc/strata"
  "navapbc/oscer"
)

# The CI bot user that posts classifier comments. Set to "ANY" to match any
# author (useful when piloting before a dedicated bot account exists).
TARGET_USER="${TARGET_USER:-github-actions[bot]}"

# Conventional-Comment label that every classifier comment leads with.
CLASSIFIER_LABEL="test-classifier"

START_DATE="${START_DATE:-2026-05-15}"
END_DATE="${END_DATE:-2026-05-21}"

# UTC
START_TS="${START_DATE}T00:00:00Z"
END_TS="${END_DATE}T23:59:59Z"

# Google Sheets sink (optional). Static SHEET_ID; short-lived bearer token.
GOOGLE_SHEETS_TOKEN="${GOOGLE_SHEETS_TOKEN:-}"
SHEET_ID="${SHEET_ID:-}"
SHEET_RANGE="${SHEET_RANGE:-Sheet1!A1}"

# --- Diagnostics go to stderr so stdout stays a clean TSV stream. ---
log() { echo "$@" >&2; }

log "Starting classifier thumbs harvest. Target User: $TARGET_USER"
log "Matching classifier comments by label prefix: '${CLASSIFIER_LABEL}:'"
log "Comment date range: $START_DATE to $END_DATE"
if [ -n "$GOOGLE_SHEETS_TOKEN" ] && [ -n "$SHEET_ID" ]; then
    log "Google Sheets sink: ENABLED (SHEET_ID=$SHEET_ID, range=$SHEET_RANGE)"
else
    log "Google Sheets sink: disabled (set GOOGLE_SHEETS_TOKEN and SHEET_ID to enable)"
fi
log "=================================================="

# Fetch a paginated API path with one retry after a short backoff.
# gh api --paginate concatenates per-page JSON arrays into `[..][..]` which is
# NOT valid JSON; slurping through jq merges them into a single flat array.
# Also forces the result to [] if the API ever returns a non-array (error obj),
# otherwise --argjson downstream would fail and abort the script under set -e.
fetch_api() {
    local path="$1"
    shift
    local raw
    raw=$(gh api --paginate "$@" "$path" 2>/dev/null) || {
        sleep 3
        raw=$(gh api --paginate "$@" "$path" 2>/dev/null) || raw=""
    }
    if [ -z "$raw" ]; then
        echo "[]"
        return
    fi
    printf '%s' "$raw" | jq -s '
        # Keep only array pages; coerce anything else to [] so non-array
        # responses (errors, scalars) never poison --argjson downstream.
        map(select(type == "array")) | add // []
    ' 2>/dev/null || echo "[]"
}

# Append one already-tab-joined row to the Google Sheet, if the sink is on.
# Builds a Sheets values:append payload (a single-row 2D array) and POSTs it.
# Failures are logged but never abort the run — the TSV is the source of truth.
sheets_append_row() {
    local repo="$1" pr="$2" cid="$3" verdict="$4" category="$5" conf="$6" up="$7" down="$8"
    [ -n "$GOOGLE_SHEETS_TOKEN" ] && [ -n "$SHEET_ID" ] || return 0

    local payload
    payload=$(jq -c -n \
        --arg repo "$repo" --arg pr "$pr" --arg cid "$cid" \
        --arg verdict "$verdict" --arg category "$category" --arg conf "$conf" \
        --arg up "$up" --arg down "$down" '
        { values: [[ $repo, $pr, $cid, $verdict, $category, $conf, $up, $down ]] }
    ')

    local url="https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values/${SHEET_RANGE}:append?valueInputOption=RAW&insertDataOption=INSERT_ROWS"
    if ! curl -sS -f -X POST "$url" \
            -H "Authorization: Bearer ${GOOGLE_SHEETS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1; then
        log "  WARNING: Sheets append failed for $repo PR#$pr comment $cid (row kept in TSV)."
    fi
}

# --- TSV header (stdout). ---
printf 'repo\tpr\tcomment_id\tverdict\tcategory\tconfidence\tthumbs_up\tthumbs_down\n'

TOTAL_ROWS=0

for REPO in "${REPOSITORIES[@]}"; do
    log "Processing repository: $REPO..."

    PR_LIST=$(gh pr list -R "$REPO" --state all --limit 1000 --json number 2>/dev/null) || {
        log "WARNING: Skipping $REPO: Failed to fetch PR list."
        continue
    }

    while read -r PR_NUM; do
        [ -n "$PR_NUM" ] || continue

        # Classifier comments are top-level PR (issue) comments posted by CI.
        ISSUE_JSON=$(fetch_api "/repos/$REPO/issues/$PR_NUM/comments")

        # Filter to classifier comments and parse the embedded verdict in one
        # jq pass. Each emitted object is a flat record ready for reaction
        # lookup; verdict/category/confidence fall back to "" when the JSON
        # block is absent or unparseable. We emit comment_id so the reactions
        # API can be queried per comment below.
        MATCHED=$(echo "$ISSUE_JSON" | jq -c \
            --arg target "$TARGET_USER" \
            --arg from "$START_TS" \
            --arg to "$END_TS" \
            --arg label "$CLASSIFIER_LABEL" '
            # Extract the JSON object between the AI_CLASSIFIER_JSON markers,
            # if any. The classifier emits a top-level object with a
            # "classifications" array (one entry per failing test), each with
            # verdict / category / confidence. We summarize that array into a
            # single representative row by picking the most actionable verdict,
            # in priority order APPLICATION_BUG > TEST_BUG > FLAKY_FAILURE >
            # ENVIRONMENT_ISSUE (a real shipped bug is the signal that matters
            # most), falling back to the first entry.
            def extract_verdict(body):
              (body | capture("<!-- AI_CLASSIFIER_JSON_BEGIN -->(?<j>[\\s\\S]*?)<!-- AI_CLASSIFIER_JSON_END -->"; "m").j)
              // ""
              | (try (fromjson) catch {});

            def summarize($obj):
              ($obj.classifications // []) as $cs
              | ( ["APPLICATION_BUG","TEST_BUG","FLAKY_FAILURE","ENVIRONMENT_ISSUE"]
                  | map(. as $v | ($cs[] | select((.verdict // "") == $v)))
                  | .[0] ) as $pick
              | ( $pick // ($cs[0] // {}) );

            .[]
            | select(
                (.body // "") != ""
                and ($target == "ANY" or (.user.login // "") == $target)
                and ((.created_at // "") >= $from and (.created_at // "") <= $to)
                and ((.body // "") | test("^[[:space:]]*" + $label + ":"; "i"))
              )
            | (summarize(extract_verdict(.body // ""))) as $v
            | {
                comment_id: (.id | tostring),
                verdict:    ($v.verdict    // ""),
                category:   ($v.category   // ""),
                confidence: (if ($v.confidence == null) then "" else ($v.confidence | tostring) end),
                # The comment object already carries authoritative 👍/👎 totals
                # in its `.reactions` summary (same source the security metrics
                # script uses) — read them here, no extra per-comment API call.
                up:   (.reactions["+1"] // 0),
                down: (.reactions["-1"] // 0)
              }
        ' 2>/dev/null || echo "")

        if [ "${DEBUG:-0}" = "1" ]; then
            IC=$(echo "$ISSUE_JSON" | jq 'length' 2>/dev/null || echo "?")
            MC=$(printf '%s\n' "$MATCHED" | grep -c . || true)
            log "  PR #$PR_NUM: issue_comments=$IC  classifier_matched=$MC"
        fi

        [ -n "$MATCHED" ] || continue

        # One row per matched classifier comment.
        printf '%s\n' "$MATCHED" | while IFS= read -r REC; do
            [ -n "$REC" ] || continue

            CID=$(echo "$REC" | jq -r '.comment_id')
            VERDICT=$(echo "$REC" | jq -r '.verdict')
            CATEGORY=$(echo "$REC" | jq -r '.category')
            CONFIDENCE=$(echo "$REC" | jq -r '.confidence')
            UP=$(echo "$REC" | jq -r '.up')
            DOWN=$(echo "$REC" | jq -r '.down')

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$REPO" "$PR_NUM" "$CID" "$VERDICT" "$CATEGORY" "$CONFIDENCE" "$UP" "$DOWN"

            sheets_append_row "$REPO" "$PR_NUM" "$CID" "$VERDICT" "$CATEGORY" "$CONFIDENCE" "$UP" "$DOWN"
        done
    done < <(echo "$PR_LIST" | jq -r '.[].number')
done

log ""
log "Done processing classifier comments (thumbs harvest)."

# =============================================================================
# Phase 2 — fix-PR merge-rate harvest (additive; does not touch the 👍/👎 rows)
# -----------------------------------------------------------------------------
# In Phase 2 the classifier opens the proposed fix as its OWN pull request on a
# branch named  ai-test-fix/<original_pr>-<n>  (base = the original PR's head
# ref), so the fix runs the repo's REAL CI. The developer's decision to MERGE
# that fix PR is the clean Phase 2 quality metric: "merge rate on proposed
# edits" = merged_fix_prs / total_fix_prs.
#
# We find every PR whose HEAD branch starts with 'ai-test-fix/' and, for each,
# emit: original_pr (parsed from the branch name), fix_pr_number, state
# (open|closed|merged), and merged (true|false). These go to stdout as a SECOND
# TSV section with its own header, after a blank separator line, so the first
# section (👍/👎 precision rows) is unchanged and both are machine-parseable.
# =============================================================================

# Branch-name prefix the Phase 2 fix PRs use (kept in sync with the workflow).
FIX_BRANCH_PREFIX="ai-test-fix/"

log ""
log "=================================================="
log "Starting Phase 2 fix-PR merge-rate harvest."
log "Matching fix PRs by head-branch prefix: '${FIX_BRANCH_PREFIX}'"

# Blank line separates the two TSV sections; second header follows.
printf '\n'
printf 'repo\toriginal_pr\tfix_pr_number\tstate\tmerged\n'

TOTAL_FIX_PRS=0
MERGED_FIX_PRS=0

for REPO in "${REPOSITORIES[@]}"; do
    log "Processing fix PRs for repository: $REPO..."

    # List PRs (any state) and keep only those whose head branch starts with
    # the fix prefix. gh pr list --head matches one exact branch, but each fix
    # PR has a UNIQUE branch (ai-test-fix/<pr>-<n>), so we list all and filter
    # by prefix in jq instead — one call per repo, same shape as the loop above.
    FIX_PR_JSON=$(gh pr list -R "$REPO" --state all --limit 1000 \
        --json number,headRefName,state,mergedAt 2>/dev/null) || {
        log "WARNING: Skipping fix-PR harvest for $REPO: failed to fetch PR list."
        continue
    }

    # Emit one compact record per fix PR. We derive `merged` from mergedAt so
    # the boolean is authoritative, and normalize `state` to merged in that
    # case (otherwise the lowercased gh state: open|closed). The original PR
    # number is parsed from ai-test-fix/<pr>-<n> (digits before the first '-'
    # after the prefix).
    FIX_MATCHED=$(echo "$FIX_PR_JSON" | jq -c \
        --arg prefix "$FIX_BRANCH_PREFIX" '
        .[]
        | (.headRefName // "") as $br
        | select($br | startswith($prefix))
        | ($br | ltrimstr($prefix) | capture("^(?<orig>[0-9]+)-").orig) as $orig
        | (.mergedAt != null) as $merged
        | {
            original_pr:   ($orig // ""),
            fix_pr_number: (.number | tostring),
            state:         (if $merged then "merged" else ((.state // "") | ascii_downcase) end),
            merged:        $merged
          }
    ' 2>/dev/null || echo "")

    if [ "${DEBUG:-0}" = "1" ]; then
        FC=$(printf '%s\n' "$FIX_MATCHED" | grep -c . || true)
        log "  $REPO: fix_prs_matched=$FC"
    fi

    [ -n "$FIX_MATCHED" ] || continue

    printf '%s\n' "$FIX_MATCHED" | while IFS= read -r REC; do
        [ -n "$REC" ] || continue

        ORIG_PR=$(echo "$REC" | jq -r '.original_pr')
        FIX_PR=$(echo "$REC" | jq -r '.fix_pr_number')
        STATE=$(echo "$REC" | jq -r '.state')
        MERGED=$(echo "$REC" | jq -r '.merged')

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$REPO" "$ORIG_PR" "$FIX_PR" "$STATE" "$MERGED"
    done

    # Tally for the stderr summary. Recomputed from FIX_MATCHED here because the
    # per-row loop above runs in a subshell (piped), so increments inside it
    # would not survive into this scope.
    REPO_TOTAL=$(printf '%s\n' "$FIX_MATCHED" | grep -c . || true)
    REPO_MERGED=$(printf '%s\n' "$FIX_MATCHED" | jq -r 'select(.merged == true) | 1' 2>/dev/null | grep -c . || true)
    TOTAL_FIX_PRS=$((TOTAL_FIX_PRS + REPO_TOTAL))
    MERGED_FIX_PRS=$((MERGED_FIX_PRS + REPO_MERGED))
done

if [ "$TOTAL_FIX_PRS" -gt 0 ]; then
    log "Fix-PR merge rate: ${MERGED_FIX_PRS}/${TOTAL_FIX_PRS} merged."
else
    log "Fix-PR merge rate: no fix PRs found (0/0)."
fi

log ""
log "Done processing all repositories."
