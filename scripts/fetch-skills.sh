#!/usr/bin/env bash
# scripts/fetch-skills.sh
#
# Vendor the canonical skill files from navapbc/agent-skills into a local,
# gitignored directory that the CI dispatchers read from.
#
# WHY THIS EXISTS
# ---------------
# The shareable skills (test-classifier, pr-review) are authored CLEAN and
# CI-free in navapbc/agent-skills — that repo is their canonical home (the
# Mastra/Vercel model: capability lives in one place, runtime-agnostic). This
# repo's CI dispatchers own the *orchestration* (diff selection, the JSON/marker
# contract, PR-comment posting, the metrics harvest) and PULL the *capability*
# (the skill instructions) from agent-skills at a PINNED ref.
#
# Pinning (not tracking `main`) is deliberate: a future edit in agent-skills can
# never silently change this repo's CI behavior. Upgrading a skill is an
# explicit, reviewable bump of AGENT_SKILLS_REF here — exactly like pinning a
# GitHub Action to a SHA.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️  MOCK / NOT YET LIVE
# This script is staged ahead of the agent-skills release tag. Until
# navapbc/agent-skills cuts the tag named in AGENT_SKILLS_REF below, the fetch
# will fail by design and the dispatchers fall back to the local .skills/ copy
# (see SKILL_PATH_CANONICAL resolution in each dispatcher). Flip this live by:
#   1. merging navapbc/agent-skills#2,
#   2. tagging that repo (e.g. v0.1.0),
#   3. setting AGENT_SKILLS_REF to that tag,
#   4. deleting the now-redundant local canonical copies of the migrated skills.
# ─────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   scripts/fetch-skills.sh                 # vendor all migrated skills at the pin
#   scripts/fetch-skills.sh --check         # verify the vendored copies exist & match the pin
#   AGENT_SKILLS_REF=v0.2.0 scripts/fetch-skills.sh   # one-off ref override

set -euo pipefail

# ── Pin ──────────────────────────────────────────────────────────────────────
# The agent-skills ref to vendor from. MUST be an immutable tag or full SHA in
# CI — never a branch. (No tag exists yet; this is the mock placeholder.)
AGENT_SKILLS_REF="${AGENT_SKILLS_REF:-v0.1.0}"
AGENT_SKILLS_REPO="${AGENT_SKILLS_REPO:-navapbc/agent-skills}"

# ── Skills that now live canonically in agent-skills ─────────────────────────
# Only the migrated skills are listed. The other security/testing skills
# (code-security, iac-compliance, finding-adjudication, codebase-audit) still
# live in this repo's .skills/ trees and are intentionally NOT fetched here.
MIGRATED_SKILLS=(
  "test-classifier"
  "pr-review"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/.skills-vendor"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

raw_url() {
  # raw.githubusercontent.com/<repo>/<ref>/skills/<skill>/SKILL.md
  printf 'https://raw.githubusercontent.com/%s/%s/skills/%s/SKILL.md' \
    "${AGENT_SKILLS_REPO}" "${AGENT_SKILLS_REF}" "$1"
}

fail() { echo "ERROR: $*" >&2; exit 1; }

if (( CHECK_ONLY == 1 )); then
  drift=0
  for skill in "${MIGRATED_SKILLS[@]}"; do
    dest="${VENDOR_DIR}/${skill}/SKILL.md"
    if [[ ! -f "${dest}" ]]; then
      echo "MISSING: ${dest} (run scripts/fetch-skills.sh)" >&2
      drift=1
    fi
  done
  (( drift == 0 )) && echo "Vendored skills present for ref ${AGENT_SKILLS_REF}." || exit 1
  exit 0
fi

echo "Vendoring ${#MIGRATED_SKILLS[@]} skill(s) from ${AGENT_SKILLS_REPO}@${AGENT_SKILLS_REF}..."
for skill in "${MIGRATED_SKILLS[@]}"; do
  dest_dir="${VENDOR_DIR}/${skill}"
  dest="${dest_dir}/SKILL.md"
  mkdir -p "${dest_dir}"
  url="$(raw_url "${skill}")"
  if ! curl -fsSL "${url}" -o "${dest}"; then
    fail "could not fetch ${skill} from ${url}
       The pinned ref '${AGENT_SKILLS_REF}' may not exist yet.
       Until navapbc/agent-skills#2 is merged and tagged, this is expected —
       dispatchers fall back to the local .skills/ copy. See header for go-live steps."
  fi
  # Sanity: must look like a SKILL.md (frontmatter + matching name).
  head -1 "${dest}" | grep -q '^---' || fail "${dest} does not begin with YAML frontmatter"
  grep -q "^name: ${skill}\$" "${dest}" || fail "${dest} frontmatter name does not match '${skill}'"
  echo "  vendored: ${skill} -> ${dest#${REPO_ROOT}/}"
done
echo "Done. Dispatchers will read from .skills-vendor/ when present."
