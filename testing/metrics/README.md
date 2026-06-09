# Testing metrics — classifier 👍/👎 capture

This directory is the metrics counterpart of the AI **test-classifier** workstream,
paralleling `security/metrics/`. It harvests the developer feedback signal that
the classifier asks for and turns it into rows you can track over time.

## What `test_classifier_comments.sh` measures

The classifier posts **one comment per CI run** that has findings. It posts as a
file-level pull-request **review comment** (so the comment has a native Reply
thread — a 👎 can be followed by a one-line reason), falling back to a plain
issue comment when the PR has no diff to anchor to. This harvester reads **both**
surfaces (`/issues/{pr}/comments` and `/pulls/{pr}/comments`) so the record is
complete across that transition and for older issue-comment runs.

Each comment leads with the Conventional-Comment label `test-classifier:` and
embeds a machine-readable verdict between the classifier's markers (defined in
`testing/classifier/.skills/test-classifier/SKILL.md` section 6B):

```
<!-- AI_CLASSIFIER_JSON_BEGIN -->
{ "summary": "...", "classifications": [
  { "verdict": "APPLICATION_BUG" | "TEST_BUG" | "FLAKY_FAILURE" | "ENVIRONMENT_ISSUE",
    "category": "visual-drift" | "behavioral-drift" | "e2e-form-flow-drift" | "other",
    "confidence": "high" | "medium" | "low", ... } ] }
<!-- AI_CLASSIFIER_JSON_END -->
```

The script summarizes the `classifications` array into one representative row
(the most-actionable verdict in priority order
`APPLICATION_BUG` > `TEST_BUG` > `FLAKY_FAILURE` > `ENVIRONMENT_ISSUE`, else the
first entry).

The comment requests a **mandatory 👍 / 👎 reaction** from the developer. That
reaction is the tuning signal:

- 👍 (`+1`) — the classifier called it right.
- 👎 (`-1`) — the classifier called it wrong.

The script pairs **each verdict with its reaction counts**, and — when the
developer left a 👎 reason as a reply in the review thread — captures that
reply's first line as `reason`, producing one row per classifier comment:

| repo | pr | comment_id | verdict | category | confidence | thumbs_up | thumbs_down | reason |
|------|----|------------|---------|----------|------------|-----------|-------------|--------|

The `reason` column is the first reply on the comment's thread (matched by
`in_reply_to_id`), flattened to one line; it is empty for issue comments (no
thread) and for comments with no reply.

These are the two things the pilot needs:

1. **👍-rate** — share of classifier comments that got a 👍 (overall and per
   verdict bucket). This is the headline "is the classifier trusted?" number.
2. **Classifier-precision inputs** — verdict × 👍/👎, so `APPLICATION_BUG` vs
   `TEST_BUG` vs `FLAKY_FAILURE` vs `ENVIRONMENT_ISSUE` accuracy can be tracked
   separately. We never want to ship a no-op test for genuinely broken code, so
   `APPLICATION_BUG` precision is the one to watch.

A classifier comment is identified by **two** signals, both required: the
author matches `TARGET_USER` (the CI bot, default `github-actions[bot]`) **and**
the body starts with `test-classifier:`. Reaction counts are read from the
inlined `.reactions` summary that both the issue-comments and pull-comments list
endpoints return on each comment — no extra per-comment reactions API call.

## Running it (TSV fallback — the default)

```bash
./test_classifier_comments.sh                 # TSV to stdout, ready to paste into a sheet
./test_classifier_comments.sh > rows.tsv      # capture to a file
DEBUG=1 ./test_classifier_comments.sh         # per-PR fetched/matched counts on stderr
```

All diagnostics go to **stderr**, so stdout is always a clean TSV (header +
rows). Configure the repos and window by editing `REPOSITORIES` or exporting
`START_DATE` / `END_DATE` / `TARGET_USER`. Requires `gh` (authenticated) and
`jq`.

## Optional Google Sheets sink

The primary sink is a single shared Google Sheet (shareable with Brian's
security metrics). It is **off unless both env vars are set**; otherwise the
script silently skips it and just prints the TSV.

```bash
export GOOGLE_SHEETS_TOKEN="ya29.<service-account-bearer-token>"
export SHEET_ID="1AbC...xyz"          # static; from /spreadsheets/d/<SHEET_ID>/edit
export SHEET_RANGE="Sheet1!A1"        # optional, this is the default
./test_classifier_comments.sh
```

Service-account setup (read+write scope, least privilege):

1. Create a Google Cloud **service account**. Grant it nothing at the project
   level. Share the target spreadsheet with the service account's email as an
   **Editor** — that share is the only access it needs.
2. Mint a **short-lived** OAuth2 bearer token with scope
   `https://www.googleapis.com/auth/spreadsheets`, e.g.
   `gcloud auth print-access-token --impersonate-service-account=...` or your
   CI's workload-identity exchange. Export it as `GOOGLE_SHEETS_TOKEN`.
3. Keep `SHEET_ID` **static** (the spreadsheet ID from its URL). The token is
   short-lived and rotates; the sheet ID is permanent.

Never commit the token or the sheet ID. Each row is appended via the Sheets
`values:append` endpoint; an append failure is logged to stderr but never
aborts the run — the stdout TSV remains the source of truth.

## Scope

This covers the pilot's one behavior: the classifier posts the verdict +
rationale and collects the mandatory 👍/👎, which this script harvests into
per-verdict precision inputs. P2 (commit suggestions / merge-rate) and P3
(zero-shot test generation) are out of scope here and live only as future
direction in the playbook.
