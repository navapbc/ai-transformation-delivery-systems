# Overview

Security metrics are to be collected weekly on Fridays, or the last working day of the week. They are to be input into the security metrics Google sheet shared by the crew. Sources of metrics include GitHub pull requests and SecurityHub compliance standard findings. These metrics help to evaluate the efficacy of shift-left workflow enhancements.

## AI-reviewed GitHub Pull Requests

Weekly tracking of key metrics will include security and compliance/IaC issues, AI-assessed severities, and engineer evaluation of the usefulness of AI review. Pilot teams - please perform a sanity check on script output when first using it to validate totals.

`pr_review_comments.sh` is a script that iterates through a pilot team's repositories.

### Prerequisites

- A GH fine-grained access token set in `GITHUB_TOKEN`, limited to read access to applicable repositories, and Pull Request access
- `jq` and the `gh` cli installed

### Setup

- A few constants set in the script including `REPOSITORIES`, `TARGET_USER`, `START_DATE` and `END_DATE`
  - `TARGET_USER` is the AI reviewer
    - TBC, but if AI review happens under an engineer's identity, the filtering should still work given conventional comments and assuming the human user doesn't use security or compliance labels
  - For dates and a consistent 7-day period, the Friday to end of next Thursday is recommended, e.g. 5/16 - 5/21

When executed, the script will output metrics, aggregated for all repositories:

```
======== SUMMARY ========
security:   3 comments  (THUMBS_UP: 2  THUMBS_DOWN: 1)
  Severity CRITICAL: 0 comments
  Severity HIGH:     1 comments
  Severity MEDIUM:   0 comments
  Severity LOW:      1 comments
compliance: 3 comments  (THUMBS_UP: 2  THUMBS_DOWN: 1)
  Severity CRITICAL: 1 comments
  Severity HIGH:     0 comments
  Severity MEDIUM:   1 comments
  Severity LOW:      1 comments
```

Note that PR usefulness is in essence voting by all team members that wish to provide a thumbs up or thumbs down, reactions are expected to significantly exceed security and compliance counts.

## Security Hub Misconfigurations

Gathering this metric gives an indication of IaC compliance issues that appeared in the previous week that agent skills and PR review did not catch.

`retrieve_sechub_misconfigurations.sh` provides an aws cli command to count the total number of new critical and high findings detections in enabled Security Hub standards over the reporting period.

### Prerequisites

- The aws cli is installed
- The aws cli has an access token in scope and available

### Setup

- Configure Start and End in the command-line example

When executed, the output will be an integer, with 0 indicating no new findings during the time period.
