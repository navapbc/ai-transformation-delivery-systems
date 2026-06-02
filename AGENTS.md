# AGENTS.md

Repository: `navapbc/ai-transformation-delivery-systems` — drop-in AI tooling
for Nava delivery teams. Two independent workstreams, each consumed separately:

- **`testing/classifier/`** — the AI **test-failure classifier**. Classifies
  each failing CI test as `APPLICATION_BUG` / `TEST_BUG` / `FLAKY_FAILURE` /
  `ENVIRONMENT_ISSUE`, and (in P1) posts one PR comment asking for a 👍/👎.
- **`security/`** — the AI security / PR-review bundle (separate; on its own
  branch). Not covered here.

## If your task is "set up / add / use the test classifier in this repo"

You are almost certainly being asked to install it in a **consumer** repo. Do
NOT vendor or copy files. Read **one** short doc and follow it (this repo is
public — fetch the raw URL directly, no auth):

```
curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/testing/classifier/AGENT_INSTALL.md
```

`AGENT_INSTALL.md` is ~40 lines and contains the exact caller workflow (pinned to
the `pilot` tag), the manual step to relay to the human (set the
`ANTHROPIC_API_KEY` secret), and the success criteria. It is the whole task.
Only fall back to `testing/classifier/docs/SETUP.md` (long-form, for humans) if
the install doc doesn't cover your case.

## Fetching files from this repo

This repo is **public**, so fetch raw files directly over HTTPS — no `gh`, no
auth, no base64. Use the moving `pilot` tag (latest on main):

```
curl -fsSL https://raw.githubusercontent.com/navapbc/ai-transformation-delivery-systems/pilot/<path>
```

## Conventions (if you work IN this repo, not just consume it)

- Conventional Commits: `type(scope): lowercase subject` (e.g.
  `feat(test-classifier): ...`). No Claude co-author trailer.
- The classifier bundle's canonical skill is `.skills/test-classifier/SKILL.md`,
  synced to per-tool dirs by `scripts/sync-skills.sh`. Edit the canonical copy.
- Shell scripts use `set -euo pipefail`; validate with `bash -n` before commit.
- Keep 👍/👎 emoji (functional — the metrics harvester reads those reactions);
  no other decorative emoji.
