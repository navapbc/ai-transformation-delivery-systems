# Testing metrics — classifier 👍/👎 capture

This directory is the metrics counterpart of the AI **test-classifier**
workstream. The pilot tracks, per classifier comment, the verdict the classifier
gave and the developer's 👍/👎 on it — the "is the classifier trusted?" signal.

## The two writers

The metrics live in the **`Testing Events`** tab of the pilot Google Sheet, one
row per classifier comment:

| repo | pr | comment_id | comment_created_at | verdict | category | confidence | thumbs_up | thumbs_down |
|------|----|------------|--------------------|---------|----------|------------|-----------|-------------|

Two writers fill that row, because the data arrives at two different times:

1. **Post-time writer — the classifier dispatcher** (`testing/classifier/.skills/
   test-classifier/scripts/test-classifier-dispatcher.sh`). When it posts a
   `test-classifier:` PR comment, it already knows everything except the
   reactions, so it **appends the row** with the first seven fields filled and
   `thumbs_up`/`thumbs_down` left blank. (`verdict`/`category`/`confidence` are
   summarized from the comment's JSON block to the most-actionable verdict, in
   priority order `APPLICATION_BUG` > `TEST_BUG` > `FLAKY_FAILURE` >
   `ENVIRONMENT_ISSUE`, else the first entry.)

2. **Nightly backfill — `test_classifier_comments.sh`** (this directory).
   Reactions are added by humans *after* the comment is posted, and **GitHub
   emits no event when a reaction is added**
   (<https://github.com/orgs/community/discussions/20824>), so they must be
   pulled on a schedule. This script reads the rows already in the sheet, does
   one `GET /repos/{repo}/issues/comments/{id}` per row to read its current
   `.reactions` counts, and writes back **only** the `thumbs_up`/`thumbs_down`
   columns. It does not search GitHub or crawl PRs — the sheet rows are the work
   list. Because it updates rows in place, running it nightly just refreshes the
   counts; it never duplicates a row.

This split is why there's no repo list to maintain here: the post-time writer
records which repo/PR/comment each row belongs to, and the backfill just follows
those rows.

## Running the backfill

```bash
export GOOGLE_SHEETS_TOKEN="ya29.<service-account-bearer-token>"
export SHEET_ID="<spreadsheet id from its URL>"   # in CI: vars.METRICS_SHEET_ID
export SHEET_RANGE="'Testing Events'!A1"          # optional; this is the default
DEBUG=1 ./test_classifier_comments.sh        # per-comment counts on stderr
```

Both `GOOGLE_SHEETS_TOKEN` and `SHEET_ID` are **required** — without a sheet to
read there is no work list. Requires `gh` (authenticated, with read access to
the pilot repos) and `jq`. A failed reaction fetch for a comment **skips** that
row rather than overwriting its existing counts, so a transient error never
clobbers good data. In CI this runs from `.github/workflows/
classifier-metrics-sweep.yml` (nightly), authenticating to Sheets via Workload
Identity Federation.

## Auth setup (service account, least privilege)

1. Create a Google Cloud **service account**, grant it nothing at the project
   level, and share the spreadsheet with its email as an **Editor** — that share
   is the only access it needs.
2. Mint a **short-lived** OAuth2 bearer token with scope
   `https://www.googleapis.com/auth/spreadsheets`
   (`gcloud auth print-access-token --impersonate-service-account=...`, or CI's
   workload-identity exchange). Export it as `GOOGLE_SHEETS_TOKEN`.
3. Keep `SHEET_ID` **static** (from the spreadsheet URL). The token rotates; the
   sheet ID is permanent. Never commit either.

For reading **private** pilot repos in CI, the maintainer provides one
fine-grained read PAT — see `testing/classifier/docs/SETUP.md`
"Metrics read access".

## Scope

This covers the pilot's one behavior: the classifier posts the verdict +
rationale and collects the mandatory 👍/👎. P2 (commit suggestions / merge-rate)
and P3 (zero-shot test generation) are out of scope and live only as future
direction in the playbook.
