# CI consumes canonical skills from agent-skills

This repo's CI **orchestration** (the dispatchers that select a diff, drive an AI
CLI, parse the JSON/marker contract, post PR comments, and feed the metrics
harvest) is separate from the skill **capability** (the instructions that tell
the AI *how* to classify a failing test or review a PR diff).

The capability for the migrated skills now lives canonically in
[`navapbc/agent-skills`](https://github.com/navapbc/agent-skills). This repo
**pulls those skills in** at a pinned ref and wraps them with the CI contract.
Capability in one place, orchestration here — the dependency points one way.

## What's migrated (and what isn't)

| Skill | Canonical home | CI here reads from |
|---|---|---|
| `test-classifier` | agent-skills | `.skills-vendor/` (fallback `.skills/`) |
| `pr-review` | agent-skills | `.skills-vendor/` (fallback `.skills/`) |
| `code-security` | this repo | `.skills/` |
| `iac-compliance` | this repo | `.skills/` |
| `codebase-audit` | this repo | `.skills/` |
| `finding-adjudication` | this repo | `.skills/` |

`pr-review` composes the `code-security` and `iac-compliance` perspectives, which
stay in this repo — so the pr-review dispatcher reads the vendored pr-review text
*plus* the two local perspective files.

## How it works

1. **`scripts/fetch-skills.sh`** vendors the migrated skills from
   `navapbc/agent-skills` at the **pinned** `AGENT_SKILLS_REF` into a gitignored
   `.skills-vendor/`. Run it as a CI step before the dispatchers (and once
   locally via the same script). Pinning to a tag/SHA — never `main` — means a
   downstream edit can't silently change CI behavior; upgrading a skill is an
   explicit bump of `AGENT_SKILLS_REF`.
2. **Each migrated dispatcher** resolves its skill path to the vendored copy when
   present, and **falls back to the in-repo `.skills/` copy** when it isn't (so a
   skipped fetch degrades gracefully instead of hard-failing).
3. **The CI contract stays in the dispatcher.** The JSON block shape and the
   `<<<AI_REVIEW_RESULT:...>>>` markers are inlined in the dispatcher prompt, not
   read from the skill file — because the published skills are intentionally
   CI-free.

## ⚠️ Status: staged ahead of the agent-skills release tag

This is wired but **not yet live**. `AGENT_SKILLS_REF` points at a tag that does
not exist yet, so `fetch-skills.sh` fails by design and the dispatchers use the
local `.skills/` fallback — i.e. **CI behavior is unchanged today.**

### Go-live checklist

- [ ] Merge [`navapbc/agent-skills#2`](https://github.com/navapbc/agent-skills/pull/2)
- [ ] Tag that repo (e.g. `v0.1.0`)
- [ ] Set `AGENT_SKILLS_REF` in `scripts/fetch-skills.sh` to that tag
- [ ] Add the `scripts/fetch-skills.sh` step to the CI workflows (GH Actions + Jenkins)
- [ ] Verify one CI run reads from `.skills-vendor/` (e.g. on Tim's repo)
- [ ] Delete the now-redundant local canonical copies:
      `testing/classifier/.skills/test-classifier/SKILL.md` and
      `security/review/.skills/pr-review/SKILL.md` (the fallback target goes away
      once vendored is proven; until then, keeping them is the safety net)
