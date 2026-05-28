#!/bin/bash
set -euo pipefail

# =============================================================================
# classifier_thumbs.sh — harvest 👍/👎 reactions on AI test-classifier PR
# comments, tie each reaction back to the classifier's machine-readable verdict,
# and emit a TSV suitable for copy-paste into a tracking sheet.
#
# This mirrors security/metrics/pr_review_comments.sh (same fetch_api retry +
# `jq -s` slurp helper, same REPOSITORIES array + date-range shape, same
# robustness against non-array API responses). It is the metrics counterpart of
# the TESTING workstream's P1 classifier.
#
# ---------------------------------------------------------------------------
# What this measures
# ---------------------------------------------------------------------------
# The P1 classifier posts ONE issue comment per CI run that has findings. Each
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
#          "verdict":    "test-fix" | "code-fix" | "no-action",
#          "category":   "visual-drift" | "behavioral-drift" | "e2e-form-flow-drift" | "other",
#          "confidence": "high" | "medium" | "low"
#        }
#      We summarize that array down to one representative row (the first
#      non-no-action classification, else the first entry).
#   3. A request for a MANDATORY 👍 / 👎 reaction from the developer. That
#      reaction is the P1 tuning signal: 👍 = "classifier called it right",
#      👎 = "classifier called it wrong".
#
# For each classifier comment we record:
#   repo, pr, comment_id, verdict, category, confidence, thumbs_up, thumbs_down
#
# Those rows are the *classifier-precision inputs*: pairing each verdict with
# its 👍/👎 lets us compute the P1 👍-rate per verdict bucket over time.
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
# DEFAULT (the realistic P0 fallback): a TSV written to stdout, one row per
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
#   ./classifier_thumbs.sh                 # TSV to stdout (P0 fallback)
#   ./classifier_thumbs.sh > rows.tsv      # capture for paste
#   GOOGLE_SHEETS_TOKEN=... SHEET_ID=... ./classifier_thumbs.sh   # + Sheets sink
#   DEBUG=1 ./classifier_thumbs.sh         # per-PR fetched/matched counts to stderr
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

# Reactions API needs this preview Accept header on older API versions; modern
# GitHub serves reactions without it, but sending it is harmless and explicit.
REACTIONS_ACCEPT="application/vnd.github.squirrel-girl-preview+json"

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
            # single representative verdict/category/confidence for the row:
            # the first non-no-action classification (or the first entry).
            def extract_verdict(body):
              (body | capture("<!-- AI_CLASSIFIER_JSON_BEGIN -->(?<j>[\\s\\S]*?)<!-- AI_CLASSIFIER_JSON_END -->"; "m").j)
              // ""
              | (try (fromjson) catch {});

            def summarize($obj):
              ($obj.classifications // []) as $cs
              | ( [ $cs[] | select((.verdict // "") != "no-action") ] | .[0] )
                as $pick
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
                # Reactions are usually inlined on the comment object; capture
                # them as a first guess and refine via the reactions API below.
                up_inline:   (.reactions["+1"] // 0),
                down_inline: (.reactions["-1"] // 0)
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

            # Authoritative reaction counts via the reactions API (the inlined
            # `.reactions` summary can lag); fall back to the inlined counts if
            # the API call returns nothing.
            REACTIONS_JSON=$(fetch_api "/repos/$REPO/issues/comments/$CID/reactions" \
                                -H "Accept: ${REACTIONS_ACCEPT}")
            UP=$(echo "$REACTIONS_JSON" | jq '[.[] | select(.content == "+1")] | length' 2>/dev/null || echo 0)
            DOWN=$(echo "$REACTIONS_JSON" | jq '[.[] | select(.content == "-1")] | length' 2>/dev/null || echo 0)
            if [ "$UP" = "0" ] && [ "$DOWN" = "0" ]; then
                UP=$(echo "$REC" | jq -r '.up_inline')
                DOWN=$(echo "$REC" | jq -r '.down_inline')
            fi

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$REPO" "$PR_NUM" "$CID" "$VERDICT" "$CATEGORY" "$CONFIDENCE" "$UP" "$DOWN"

            sheets_append_row "$REPO" "$PR_NUM" "$CID" "$VERDICT" "$CATEGORY" "$CONFIDENCE" "$UP" "$DOWN"
        done
    done < <(echo "$PR_LIST" | jq -r '.[].number')
done

log ""
log "Done processing all repositories."
