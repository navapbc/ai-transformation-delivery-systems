#!/usr/bin/env bash
# Vendor test-classifier from navapbc/agent-skills into a gitignored
# .skills-vendor/ that the dispatcher reads from. Pin to a tag/SHA (never a
# branch) so a downstream edit can't silently change CI; bump AGENT_SKILLS_REF
# to upgrade. If the ref doesn't resolve, the dispatcher falls back to .skills/.
set -euo pipefail

AGENT_SKILLS_REF="${AGENT_SKILLS_REF:-v0.1.0}"
AGENT_SKILLS_REPO="${AGENT_SKILLS_REPO:-navapbc/agent-skills}"
SKILL="test-classifier"

BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${BUNDLE_ROOT}/.skills-vendor/${SKILL}/SKILL.md"
mkdir -p "$(dirname "${dest}")"

url="https://raw.githubusercontent.com/${AGENT_SKILLS_REPO}/${AGENT_SKILLS_REF}/skills/${SKILL}/SKILL.md"
curl -fsSL "${url}" -o "${dest}" || {
  echo "ERROR: could not fetch ${SKILL} from ${url} (does ref '${AGENT_SKILLS_REF}' exist?)" >&2
  exit 1
}
echo "vendored: ${SKILL}@${AGENT_SKILLS_REF}"
