#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
REPOSITORIES=(
  "navapbc/strata"
  "navapbc/oscer"
)

TARGET_USER="github-copilot[bot]"   
START_DATE="2026-05-15"
END_DATE="2026-05-21"

# UTC
START_TS="${START_DATE}T00:00:00Z"
END_TS="${END_DATE}T23:59:59Z"

echo "Starting PR comment search. Target User: $TARGET_USER"
echo "Filtering for Conventional Comments starting with 'security' or 'compliance'"
echo "Scanning issue comments, inline review comments, and review submission bodies."
echo "Comment date range: $START_DATE to $END_DATE"
echo "=================================================="

# Collect every matching normalized comment here for end-of-run aggregation.
NORMALIZED_ALL="$(mktemp)"
trap 'rm -f "$NORMALIZED_ALL"' EXIT

# Fetch a paginated API path with one retry after a short backoff.
# gh api --paginate concatenates per-page JSON arrays into `[..][..]` which is
# NOT valid JSON; slurping through jq merges them into a single flat array.
# Also forces the result to [] if the API ever returns a non-array (error obj),
# otherwise --argjson downstream would fail and abort the script under set -e.
fetch_api() {
    local path="$1"
    local raw
    raw=$(gh api --paginate "$path" 2>/dev/null) || {
        sleep 3
        raw=$(gh api --paginate "$path" 2>/dev/null) || raw=""
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

for REPO in "${REPOSITORIES[@]}"; do
    echo "Processing repository: $REPO..."

    PR_LIST=$(gh pr list -R "$REPO" --state all --limit 1000 \
        --search "updated:${START_DATE}..${END_DATE}" \
        --json number 2>/dev/null) || {
        echo "WARNING: Skipping $REPO: Failed to fetch PR list."
        continue
    }

    echo "$PR_LIST" | jq -r '.[].number' | while read -r PR_NUM; do
        # Issue comments (top-level PR conversation).
        ISSUE_JSON=$(fetch_api "/repos/$REPO/issues/$PR_NUM/comments")
        # Inline review comments (line-by-line on the diff).
        REVIEW_JSON=$(fetch_api "/repos/$REPO/pulls/$PR_NUM/comments")
        # Review submission bodies (approve / request changes / comment).
        SUBMISSIONS_JSON=$(fetch_api "/repos/$REPO/pulls/$PR_NUM/reviews")

        # Diagnostic: per-source fetched / matched counts for this PR.
        # Set DEBUG=0 to silence; set VERBOSE=1 for per-comment match booleans.
        if [ "${DEBUG:-1}" = "1" ]; then
            count_matches() {
                local json="$1" date_field="$2"
                echo "$json" | jq --arg target "$TARGET_USER" \
                                  --arg from "$START_TS" \
                                  --arg to "$END_TS" \
                                  --arg df "$date_field" '
                    [ .[] | select(
                          (.body // "") != ""
                          and ($target == "ANY" or (.user.login // "") == $target)
                          and ((.[$df] // "") >= $from and (.[$df] // "") <= $to)
                          and ((.body // "") | test("^[[:space:]]*(security|compliance)"; "i"))
                      ) ] | length
                '
            }
            IC=$(echo "$ISSUE_JSON"       | jq 'length')
            RC=$(echo "$REVIEW_JSON"      | jq 'length')
            SC=$(echo "$SUBMISSIONS_JSON" | jq 'length')
            IM=$(count_matches "$ISSUE_JSON"       "created_at")
            RM=$(count_matches "$REVIEW_JSON"      "created_at")
            SM=$(count_matches "$SUBMISSIONS_JSON" "submitted_at")
            echo "  PR #$PR_NUM: issue=$IC/$IM  review=$RC/$RM  submissions=$SC/$SM   (fetched/matched)" >&2

            if [ "${VERBOSE:-0}" = "1" ] && [ "$RC" -gt 0 ]; then
                echo "$REVIEW_JSON" | jq -r --arg target "$TARGET_USER" \
                                            --arg from "$START_TS" \
                                            --arg to "$END_TS" '
                    .[] |
                    ( (.body // "") | gsub("\n"; " ") | .[0:80] ) as $preview
                    | ( (.user.login // "?") ) as $login
                    | ( (.created_at // "?") ) as $ts
                    | ( ($target == "ANY") or ($login == $target) ) as $a_ok
                    | ( ($ts >= $from) and ($ts <= $to) ) as $d_ok
                    | ( (.body // "") | test("^[[:space:]]*(security|compliance)"; "i") ) as $r_ok
                    | "    [author=\($a_ok) date=\($d_ok) regex=\($r_ok)] \($login) @ \($ts): \($preview)"
                ' >&2
            fi
        fi

        # Normalize into uniform shape and filter.
        jq -c -n \
          --argjson issue "$ISSUE_JSON" \
          --argjson review "$REVIEW_JSON" \
          --argjson submissions "$SUBMISSIONS_JSON" \
          --arg target "$TARGET_USER" \
          --arg from "$START_TS" \
          --arg to "$END_TS" \
          '
          def norm(type):
            {
              type: type,
              author: (.user.login // ""),
              createdAt: (.created_at // .submitted_at // ""),
              body: (.body // ""),
              path: (.path // null),
              thumbsUp:   (.reactions["+1"] // 0),
              thumbsDown: (.reactions["-1"] // 0)
            };
          [
            ($issue       | map(norm("issue_comment"))),
            ($review      | map(norm("inline_review_comment"))),
            ($submissions | map(norm("review_submission")))
          ]
          | add
          | map(select(
              .body != ""
              and ($target == "ANY" or .author == $target)
              and (.createdAt >= $from and .createdAt <= $to)
              and (.body | test("^[[:space:]]*(security|compliance)"; "i"))
            ))
          | .[]
          ' \
        | tee -a "$NORMALIZED_ALL" \
        | jq -r --arg repo "$REPO" --arg pr_num "$PR_NUM" '
            "Repo: \($repo) | PR #\($pr_num) | Date: \(.createdAt) | Author: \(.author) | Context: \(.type)" +
            (if .path then "\nFile: \(.path)" else "" end) +
            "\nComment: \(.body)\n" +
            "Reactions: " + (
              if (.thumbsUp == 0 and .thumbsDown == 0) then
                "None"
              else
                "THUMBS_UP: \(.thumbsUp), THUMBS_DOWN: \(.thumbsDown)"
              end
            ) +
            "\n--------------------------------------------------"
          '
    done
done

echo ""
echo "======== SUMMARY ========"
if [ ! -s "$NORMALIZED_ALL" ]; then
    echo "No matching comments found."
else
    jq -s -r '
      def label_for(b):
        if   (b | test("^[[:space:]]*security";   "i")) then "security"
        elif (b | test("^[[:space:]]*compliance"; "i")) then "compliance"
        else "other" end;

      def stats(items):
        {
          count: (items | length),
          up:    (items | map(.thumbsUp)   | add // 0),
          down:  (items | map(.thumbsDown) | add // 0)
        };

      def sev_count(items; level):
        [items[] | select(.body | test("Severity:[[:space:]]*" + level + "\\b"; "i"))] | length;

      def severity_block(items):
        "  Severity CRITICAL: \(sev_count(items; "CRITICAL")) comments\n" +
        "  Severity HIGH:     \(sev_count(items; "HIGH")) comments\n" +
        "  Severity MEDIUM:   \(sev_count(items; "MEDIUM")) comments\n" +
        "  Severity LOW:      \(sev_count(items; "LOW")) comments";

      . as $all
      | ([$all[] | select(label_for(.body) == "security")])   as $sec_items
      | ([$all[] | select(label_for(.body) == "compliance")]) as $comp_items
      | (stats($sec_items))  as $sec
      | (stats($comp_items)) as $comp
      |
        "security:   \($sec.count) comments  (THUMBS_UP: \($sec.up)  THUMBS_DOWN: \($sec.down))\n" +
        severity_block($sec_items) + "\n\n" +
        "compliance: \($comp.count) comments  (THUMBS_UP: \($comp.up)  THUMBS_DOWN: \($comp.down))\n" +
        severity_block($comp_items) + "\n\n" +
        "   (severity matches /Severity:\\s*<LEVEL>\\b/i in body)"
    ' "$NORMALIZED_ALL"
fi

echo ""
echo "Done processing all repositories."
