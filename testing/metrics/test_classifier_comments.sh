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
# How we find them (efficiently): the GitHub Search API's `in:comments`
# qualifier matches comment bodies server-side, so we ask only for the PRs whose
# comments mention the classifier label rather than listing every PR in the repo
# and fetching each one's comments. We then re-verify author + label prefix per
# comment, so a loose search match is never miscounted. Date windowing
# (START_DATE/END_DATE) is still applied per-comment in the jq pass below.
#
# For each classifier comment we record:
#   repo, pr, comment_id, comment_created_at, verdict, category, confidence,
#   thumbs_up, thumbs_down
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
# Default tab is the repo-keyed "Testing Events" source-of-truth tab in the
# "Weekly Pilot Team Metrics Gathering" sheet (one row per classifier comment;
# header repo|pr|comment_id|verdict|category|confidence|thumbs_up|thumbs_down).
# The space in the tab name MUST be quoted in the A1 range — values:append
# tolerates an unquoted single-cell anchor, but quote it to be safe.
SHEET_RANGE="${SHEET_RANGE:-'Testing Events'!A1}"

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
    local repo="$1" pr="$2" cid="$3" created_at="$4" verdict="$5" category="$6" conf="$7" up="$8" down="$9"
    [ -n "$GOOGLE_SHEETS_TOKEN" ] && [ -n "$SHEET_ID" ] || return 0

    local payload
    payload=$(jq -c -n \
        --arg repo "$repo" --arg pr "$pr" --arg cid "$cid" --arg created_at "$created_at" \
        --arg verdict "$verdict" --arg category "$category" --arg conf "$conf" \
        --arg up "$up" --arg down "$down" '
        { values: [[ $repo, $pr, $cid, $created_at, $verdict, $category, $conf, $up, $down ]] }
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
printf 'repo\tpr\tcomment_id\tcomment_created_at\tverdict\tcategory\tconfidence\tthumbs_up\tthumbs_down\n'

TOTAL_ROWS=0

for REPO in "${REPOSITORIES[@]}"; do
    log "Processing repository: $REPO..."

    # Find ONLY the PRs whose comments mention the classifier label, server-side,
    # via the Search API's `in:comments` qualifier — instead of listing every PR
    # and fetching each one's comments client-side. GitHub indexes comment bodies
    # (object_type "IssueComment"), so this collapses "all N PRs in the repo" down
    # to "the handful that actually carry a classifier comment". The downstream
    # per-PR loop is unchanged; only its input list is pre-filtered.
    #
    # Caveats handled by design: the Search API has a lower rate limit (~30/min)
    # and a short indexing lag (a just-posted comment may not be searchable for a
    # few seconds) — both irrelevant for a weekly metrics run. We still re-verify
    # each comment's author + `test-classifier:` prefix below, so a loose search
    # match never produces a false row.
    #
    # search/issues returns an OBJECT ({total_count, items:[...]}), not an array,
    # so we extract `.items[].number` directly rather than through fetch_api
    # (which slurps array pages). `--paginate` walks all result pages.
    SEARCH_Q="repo:${REPO} is:pr in:comments ${CLASSIFIER_LABEL}"
    PR_NUMS=$(gh api --paginate -X GET "search/issues" \
                --field q="$SEARCH_Q" --jq '.items[].number' 2>/dev/null \
              | sort -un) || {
        log "WARNING: Skipping $REPO: comment search failed."
        continue
    }

    if [ -z "$PR_NUMS" ]; then
        log "  No PRs with '${CLASSIFIER_LABEL}' comments found in $REPO."
        continue
    fi
    log "  Matched $(printf '%s\n' "$PR_NUMS" | grep -c .) PR(s) with classifier comments."

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
                # The event time: when the classifier posted the comment. This is
                # the authoritative key for weekly windowing/rollups, and is
                # stable across re-runs (unlike a harvest time).
                created_at: (.created_at // ""),
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
            CREATED_AT=$(echo "$REC" | jq -r '.created_at')
            VERDICT=$(echo "$REC" | jq -r '.verdict')
            CATEGORY=$(echo "$REC" | jq -r '.category')
            CONFIDENCE=$(echo "$REC" | jq -r '.confidence')
            UP=$(echo "$REC" | jq -r '.up')
            DOWN=$(echo "$REC" | jq -r '.down')

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$REPO" "$PR_NUM" "$CID" "$CREATED_AT" "$VERDICT" "$CATEGORY" "$CONFIDENCE" "$UP" "$DOWN"

            sheets_append_row "$REPO" "$PR_NUM" "$CID" "$CREATED_AT" "$VERDICT" "$CATEGORY" "$CONFIDENCE" "$UP" "$DOWN"
        done
    done < <(printf '%s\n' "$PR_NUMS")
done

log ""
log "Done processing all repositories."
