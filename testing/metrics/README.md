# Testing metrics — classifier 👍/👎 capture

This directory is the metrics counterpart of the AI **test-classifier** workstream,
paralleling `security/metrics/`. It harvests the developer feedback signal that
the classifier asks for and turns it into rows you can track over time.

## What `test_classifier_comments.sh` measures

The classifier posts **one issue comment per CI run** that has findings.
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

The script pairs **each verdict with its reaction counts**, producing one row
per classifier comment:

| repo | pr | comment_id | verdict | category | confidence | thumbs_up | thumbs_down |
|------|----|------------|---------|----------|------------|-----------|-------------|

These are the two things the pilot needs:

1. **👍-rate** — share of classifier comments that got a 👍 (overall and per
   verdict bucket). This is the headline "is the classifier trusted?" number.
2. **Classifier-precision inputs** — verdict × 👍/👎, so `APPLICATION_BUG` vs
   `TEST_BUG` vs `FLAKY_FAILURE` vs `ENVIRONMENT_ISSUE` accuracy can be tracked
   separately. We never want to ship a no-op test for genuinely broken code, so
   `APPLICATION_BUG` precision is the one to watch.

A classifier comment is identified by **two** signals, both required: the
author matches `TARGET_USER` (the CI bot, default `github-actions[bot]`) **and**
the body starts with `test-classifier:`. Reaction counts come from the
reactions API (`GET /repos/{owner}/{repo}/issues/comments/{id}/reactions`),
falling back to the inlined `.reactions` summary.

## Phase 2 — fix-PR merge-rate output

In Phase 2 the classifier no longer suggests fixes inline; it opens each
proposed fix as its **own pull request** on a branch named
`ai-test-fix/<original_pr>-<n>`, based on the original PR's head ref. That fix
PR runs the repo's **real CI** (proving "the rest complies"), and the
developer's decision to **merge** it is the clean quality signal.

After the 👍/👎 rows, the script prints a **second TSV section** (preceded by a
blank separator line and its own header) listing every fix PR it can find —
i.e. every PR whose head branch starts with `ai-test-fix/`:

| repo | original_pr | fix_pr_number | state | merged |
|------|-------------|---------------|-------|--------|

- `original_pr` — parsed from the branch name `ai-test-fix/<original_pr>-<n>`
  (the digits before the first `-` after the prefix); ties the fix back to the
  developer's PR it was proposed against.
- `fix_pr_number` — the fix PR's own number.
- `state` — `open`, `closed` (rejected/superseded), or `merged`.
- `merged` — `true`/`false`, derived authoritatively from the PR's `mergedAt`.

This maps directly to the Phase 2 **"merge rate on proposed edits"** metric:

```
merge rate = merged_fix_prs / total_fix_prs
```

where `merged_fix_prs` is the count of rows with `merged == true` and
`total_fix_prs` is the number of fix-PR rows. The script also logs that ratio
to **stderr** at the end of the run (e.g. `Fix-PR merge rate: 3/5 merged.`) as
a convenience; stdout stays clean TSV.

Because each fix PR has a unique branch, the harvest lists all PRs per repo and
filters by the `ai-test-fix/` prefix in `jq` (rather than `gh pr list --head`,
which matches a single exact branch). Recursion is avoided upstream: the
classifier skips bot-authored / `ai-test-fix/` PRs, so these fix PRs never get
classified (and so never appear in the 👍/👎 section above).

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

This covers two behaviors. (1) The **pilot** behavior — the classifier posts
the verdict + rationale and collects the mandatory 👍/👎, harvested into
per-verdict precision inputs (section above). (2) **Phase 2** — when a repo
opts in, the classifier opens its proposed fix as a separate `ai-test-fix/...`
PR; this script harvests those PRs' merge state into the "merge rate on
proposed edits" metric. Both sections are emitted in one run, with Phase 2 rows
appearing only if any fix PRs exist (otherwise just the header and a `0/0`
stderr note). P3 (zero-shot test generation) remains out of scope here and
lives only as future direction in the playbook.
