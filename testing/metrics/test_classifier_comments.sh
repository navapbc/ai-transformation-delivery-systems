#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test_classifier_comments.sh — NIGHTLY reaction backfill for the AI test
# classifier metrics.
#
# ---------------------------------------------------------------------------
# Role: this is the SECOND of two writers into the "Testing Events" tab of the
# pilot metrics sheet. The first writer is the classifier dispatcher itself
# (testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh):
# at the moment it posts a `test-classifier:` PR comment it APPENDS a row with
# the seven fields it knows at post time —
#   repo | pr | comment_id | comment_created_at | verdict | category | confidence
# leaving thumbs_up / thumbs_down BLANK.
#
# Reactions (👍/👎) arrive later, from humans, and GitHub emits NO event when a
# reaction is added (https://github.com/orgs/community/discussions/20824), so
# they must be pulled. THIS script is that pull: run on a schedule, it reads the
# rows already in the sheet, fetches each comment's current reaction counts, and
# writes back ONLY the thumbs_up / thumbs_down columns on the row that is already
# there. It does not discover comments, search GitHub, or crawl PRs — the sheet
# rows ARE the work list. One GET per comment_id, then one batched sheet update.
#
# Because it updates existing rows in place (keyed by the row it read), the tab
# stays at one row per classifier comment no matter how often this runs — a
# nightly cadence simply refreshes the counts as reactions accrue.
#
# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
#   - GitHub: `gh` reads GH_TOKEN. Needs read access to the pilot repos' issue
#     comments (public repos: default token; private: a fine-grained read PAT —
#     see testing/classifier/docs/SETUP.md "Metrics read access").
#   - Google Sheets: GOOGLE_SHEETS_TOKEN (a short-lived service-account bearer
#     token, scope https://www.googleapis.com/auth/spreadsheets) + a static
#     SHEET_ID. In CI these come from Workload Identity Federation; locally,
#     `gcloud auth print-access-token --impersonate-service-account=...`.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   GOOGLE_SHEETS_TOKEN=... SHEET_ID=... ./test_classifier_comments.sh
#   SHEET_RANGE="'Testing Events'!A1" ...   # override the tab (default below)
#   DEBUG=1 ...                             # per-comment fetch/update logs
#
# Both GOOGLE_SHEETS_TOKEN and SHEET_ID are REQUIRED — without a sheet to read,
# there is no work list. (Unlike the old harvester, there is no stdout-TSV mode:
# the post-time writer now owns row creation; this script only backfills.)
# =============================================================================

# --- Configuration ---
GOOGLE_SHEETS_TOKEN="${GOOGLE_SHEETS_TOKEN:-}"
SHEET_ID="${SHEET_ID:-}"
# Default tab is the repo-keyed "Testing Events" source-of-truth tab. The space
# in the tab name MUST be quoted in the A1 range.
SHEET_RANGE="${SHEET_RANGE:-'Testing Events'!A1}"
# Tab name alone (range without its trailing cell anchor), for building ranges.
SHEET_TAB="${SHEET_RANGE%%!*}"

# Column layout of the Testing Events tab (1-based), used to read keys and to
# target the backfill. A=repo C=comment_id H=thumbs_up I=thumbs_down.
COL_REPO=0          # 0-based index into a row array
COL_COMMENT_ID=2

log() { echo "$@" >&2; }

if [ -z "$GOOGLE_SHEETS_TOKEN" ] || [ -z "$SHEET_ID" ]; then
    log "ERROR: GOOGLE_SHEETS_TOKEN and SHEET_ID are both required (this script"
    log "       backfills reactions onto rows already in the sheet)."
    exit 1
fi

log "Starting nightly reaction backfill."
log "Sheet: $SHEET_ID  tab: $SHEET_TAB"
log "=================================================="

# Encode spaces/quotes in an A1 range for a URL path, but NOT '!' (the Sheets
# API needs a literal tab!cell separator; %21 makes the call fail).
url_encode_range() {
    local s="$1"
    s="${s//\'/%27}"
    s="${s// /%20}"
    printf '%s' "$s"
}

# Read the whole tab once. Emits one line per DATA row (skipping the header):
#   rownum<TAB>repo<TAB>comment_id
# rownum is the 1-based sheet row. Rows without a comment_id are skipped.
read_rows() {
    local enc resp
    enc=$(url_encode_range "${SHEET_TAB}")
    resp=$(curl -sS -f \
        -H "Authorization: Bearer ${GOOGLE_SHEETS_TOKEN}" \
        "https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values/${enc}" \
        2>/dev/null) || { log "ERROR: could not read the sheet."; return 1; }

    printf '%s' "$resp" | jq -r \
        --argjson rc "$COL_REPO" --argjson cc "$COL_COMMENT_ID" '
        (.values // []) | to_entries[]
        | select(.key > 0)                                  # skip header (row 1)
        | { row: (.key + 1), repo: (.value[$rc] // ""), cid: (.value[$cc] // "") }
        | select(.cid != "")
        | "\(.row)\t\(.repo)\t\(.cid)"
    ' 2>/dev/null
}

# Fetch current 👍/👎 for one comment. Args: repo, comment_id.
# Prints "up<TAB>down"; on any failure prints nothing (caller skips the row, so
# a transient error never clobbers an existing count with a wrong value).
fetch_reactions() {
    local repo="$1" cid="$2" raw
    raw=$(gh api "/repos/${repo}/issues/comments/${cid}" 2>/dev/null) || return 0
    printf '%s' "$raw" | jq -r '"\(.reactions["+1"] // 0)\t\(.reactions["-1"] // 0)"' 2>/dev/null || true
}

# Batch-write thumbs_up/thumbs_down for the collected rows in ONE Sheets call.
# Input on stdin: lines of "rownum<TAB>up<TAB>down". Builds a values:batchUpdate
# with one H<row>:I<row> range per line.
batch_update_reactions() {
    local data_ranges
    data_ranges=$(jq -R -s \
        --arg tab "$SHEET_TAB" '
        # Each input line -> a ValueRange covering H<row>:I<row>.
        split("\n") | map(select(length > 0) | split("\t"))
        | map({ range: ($tab + "!H" + .[0] + ":I" + .[0]),
                values: [[ (.[1] // "0"), (.[2] // "0") ]] })
    ')

    local n
    n=$(printf '%s' "$data_ranges" | jq 'length' 2>/dev/null || echo 0)
    if [ "${n:-0}" -eq 0 ]; then
        log "No rows to update."
        return 0
    fi

    local payload
    payload=$(jq -c -n --argjson data "$data_ranges" \
        '{ valueInputOption: "RAW", data: $data }')

    if curl -sS -f -X POST \
            "https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values:batchUpdate" \
            -H "Authorization: Bearer ${GOOGLE_SHEETS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1; then
        log "Updated reactions on ${n} row(s)."
    else
        log "ERROR: batch update failed; no rows were changed."
        return 1
    fi
}

# --- Main: read rows -> fetch reactions per comment -> batch-update. ---
UPDATES=$(mktemp)
trap 'rm -f "$UPDATES"' EXIT

ROW_COUNT=0
FETCHED=0
while IFS=$'\t' read -r rownum repo cid; do
    [ -n "$cid" ] || continue
    ROW_COUNT=$((ROW_COUNT + 1))

    reactions=$(fetch_reactions "$repo" "$cid")
    if [ -z "$reactions" ]; then
        [ "${DEBUG:-0}" = "1" ] && log "  row $rownum  $repo  comment $cid: fetch failed/skipped"
        continue
    fi
    up="${reactions%%$'\t'*}"
    down="${reactions##*$'\t'}"
    printf '%s\t%s\t%s\n' "$rownum" "$up" "$down" >> "$UPDATES"
    FETCHED=$((FETCHED + 1))
    [ "${DEBUG:-0}" = "1" ] && log "  row $rownum  $repo  comment $cid: 👍$up 👎$down"
done < <(read_rows)

log "Rows with a comment_id: ${ROW_COUNT}; reactions fetched: ${FETCHED}."

batch_update_reactions < "$UPDATES"

log "Done."
