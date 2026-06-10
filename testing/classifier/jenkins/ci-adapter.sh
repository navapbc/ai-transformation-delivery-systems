#!/usr/bin/env bash
# testing/classifier/jenkins/ci-adapter.sh
#
# CI adapter: Jenkins → the test-classifier dispatcher.
#
# The dispatcher (.skills/test-classifier/scripts/test-classifier-dispatcher.sh)
# is CI-agnostic. Its entry contract is just a handful of env vars + flags:
#
#     AI_REVIEW_TOOL   claude | codex | copilot     (which agent runs)
#     GH_TOKEN         a GitHub token for `gh`       (posting the PR comment)
#     --pr <n>         the PR number
#     --against <ref>  the base ref to diff against
#
# GitHub Actions fills that contract from `github.event.pull_request.*`. This
# adapter fills the SAME contract from Jenkins' native multibranch/PR env, so
# the dispatcher — and everything downstream of it — runs unchanged. The only
# per-CI code is this file.
#
# Jenkins PR env (set by the GitHub Branch Source plugin on a PR build):
#   CHANGE_ID       → the pull-request number          (→ PR_NUMBER, --pr)
#   CHANGE_TARGET   → the PR's target/base branch       (→ BASE_REF, --against)
#   CHANGE_URL      → the PR's html URL                 (host detection, GHE)
#
# Why we pass BOTH --pr and --against: the dispatcher will resolve the base ref
# itself via `gh pr view` when only --pr is given. We already know the base ref
# (CHANGE_TARGET), so passing --against too short-circuits that lookup — the
# dispatcher then needs `gh` ONLY to post the comment, not to discover the PR.
#
# Usage (from a Jenkinsfile stage, with credentials already bound to env):
#     export AI_REVIEW_TOOL=claude
#     export GH_TOKEN="$GITHUB_PAT"          # from Jenkins credentials
#     export ANTHROPIC_API_KEY="$ANTHROPIC"  # or the Bedrock vars (see README)
#     testing/classifier/jenkins/ci-adapter.sh
#
# This script is deliberately thin and side-effect-light: it validates the
# Jenkins context, normalizes it, fetches the base ref so the diff resolves, and
# execs the dispatcher. All classification logic lives in the dispatcher.

set -euo pipefail

# ── Resolve paths relative to this script, so it works vendored or staged ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"   # …/testing/classifier
DISPATCHER="${CLASSIFIER_ROOT}/.skills/test-classifier/scripts/test-classifier-dispatcher.sh"

log() { echo "[ci-adapter] $*" >&2; }
die() { echo "[ci-adapter] ERROR: $*" >&2; exit 1; }

[[ -x "${DISPATCHER}" ]] || die "dispatcher not found or not executable at ${DISPATCHER}"

# ── 1. Require the agent selection. ──────────────────────────────────────────
# Same contract as Actions; surface a clear message rather than letting the
# dispatcher fail deeper in.
[[ -n "${AI_REVIEW_TOOL:-}" ]] || die "AI_REVIEW_TOOL is not set (claude | codex | copilot)."

# ── 2. Map Jenkins PR context → the dispatcher's PR_NUMBER / BASE_REF. ────────
# Prefer Jenkins' native CHANGE_* vars; allow explicit PR_NUMBER/BASE_REF
# overrides so this also works in non-multibranch jobs (e.g. a parameterized
# build that passes the PR number in directly).
PR_NUMBER="${PR_NUMBER:-${CHANGE_ID:-}}"
BASE_REF="${BASE_REF:-${CHANGE_TARGET:-}}"

if [[ -z "${PR_NUMBER}" ]]; then
  # Not a PR build (e.g. a branch/tag build). The classifier is PR-scoped, so
  # there is nothing to do — exit cleanly rather than fail the pipeline.
  log "No PR context (CHANGE_ID/PR_NUMBER unset) — not a PR build. Skipping classification."
  exit 0
fi
[[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || die "PR number '${PR_NUMBER}' is not numeric."
[[ -n "${BASE_REF}" ]] || die "base ref unknown: set CHANGE_TARGET (multibranch) or BASE_REF explicitly."

# ── 3. GitHub host (GitHub.com vs GitHub Enterprise Server). ─────────────────
# `gh` talks to github.com by default. For a GHES PR, point it at the right host
# via GH_HOST. Auto-detect from CHANGE_URL when GH_HOST wasn't set explicitly.
if [[ -z "${GH_HOST:-}" && -n "${CHANGE_URL:-}" ]]; then
  # CHANGE_URL looks like https://<host>/<owner>/<repo>/pull/<n>
  detected_host="$(printf '%s' "${CHANGE_URL}" | sed -E 's#^https?://([^/]+)/.*#\1#')"
  if [[ -n "${detected_host}" && "${detected_host}" != "github.com" ]]; then
    export GH_HOST="${detected_host}"
    log "Detected GitHub Enterprise host from CHANGE_URL: GH_HOST=${GH_HOST}"
  fi
fi

# ── 4. Token plumbing for `gh`. ──────────────────────────────────────────────
# `gh` reads GH_TOKEN (then GITHUB_TOKEN) from the env — no `gh auth login`
# needed, on any CI. Jenkins binds the PAT to one of these via withCredentials.
if [[ -z "${GH_TOKEN:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
fi
[[ -n "${GH_TOKEN:-}" ]] || die "no GitHub token: bind a PAT to GH_TOKEN (or GITHUB_TOKEN) via Jenkins credentials."

# ── 5. Make the base ref resolvable for the diff. ────────────────────────────
# The dispatcher diffs `origin/<base> HEAD`. On a Jenkins PR checkout the base
# branch may not be present locally, so fetch it (shallow-ish, like the Actions
# workflow's depth=200) before handing off.
log "Fetching base ref origin/${BASE_REF} so the diff range resolves…"
git fetch --no-tags --depth=200 origin "${BASE_REF}:refs/remotes/origin/${BASE_REF}" 2>/dev/null \
  || log "WARNING: could not fetch origin/${BASE_REF}; the diff may be empty if it isn't already present."

# ── 6. Hand off to the dispatcher. ───────────────────────────────────────────
# CI=true mirrors the Actions env (suppresses colors, fail-fast). We pass --pr
# AND --against so no `gh pr view` discovery is needed (see header note).
export CI="${CI:-true}"
export PR_NUMBER BASE_REF

log "Running classifier: tool=${AI_REVIEW_TOOL} pr=#${PR_NUMBER} base=${BASE_REF}${GH_HOST:+ host=${GH_HOST}}"
exec "${DISPATCHER}" \
  --pr "${PR_NUMBER}" \
  --against "origin/${BASE_REF}" \
  --post-comment \
  "$@"
