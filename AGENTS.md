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
NOT vendor or copy files. Read **one** short doc and follow it:

```
gh api "repos/navapbc/ai-transformation-delivery-systems/contents/testing/classifier/AGENT_INSTALL.md?ref=test-classifier-v0" --jq .content | base64 -d
```

`AGENT_INSTALL.md` is ~40 lines and contains the exact caller workflow (with the
pinned SHA already filled in), the two manual steps to relay to the human, and
the success criteria. It is the whole task. Only fall back to
`testing/classifier/docs/SETUP.md` (long-form, for humans) if the install doc
doesn't cover your case.

## Fetching files from this (private) repo

This repo is private, so `WebFetch` of github.com blob URLs returns 404. Use the
GitHub API with an authenticated `gh`, and **quote the URL** (the `?ref=` makes
zsh treat `?` as a glob):

```
gh api "repos/navapbc/ai-transformation-delivery-systems/contents/<path>?ref=test-classifier-v0" --jq .content | base64 -d
```

## Conventions (if you work IN this repo, not just consume it)

- Conventional Commits: `type(scope): lowercase subject` (e.g.
  `feat(test-classifier): ...`). No Claude co-author trailer.
- The classifier bundle's canonical skill is `.skills/test-classifier/SKILL.md`,
  synced to per-tool dirs by `scripts/sync-skills.sh`. Edit the canonical copy.
- Shell scripts use `set -euo pipefail`; validate with `bash -n` before commit.
- Keep 👍/👎 emoji (functional — the metrics harvester reads those reactions);
  no other decorative emoji.
