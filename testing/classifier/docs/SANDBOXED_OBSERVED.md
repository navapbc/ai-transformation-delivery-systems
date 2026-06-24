# Plan — Sandboxed OBSERVED runs via smolvm

**Status:** Phase 1 implemented (`scripts/sandbox-run.sh` + dispatcher routing,
opt-in `AI_SANDBOX=1`, default off). Phase 0 spikes remain to be validated on a
real `smolvm` install — see §7 / §8. Host-side logic (staging, env-file,
allowlist, teardown, routing matrix) is implemented and tested; the in-VM
execution path is unverified until the spikes run.
**Problem owner:** testing workstream.
**Related:** [`LOCAL_TEST_CLASSIFIER.md`](./LOCAL_TEST_CLASSIFIER.md) (the OBSERVED warning this plan resolves), [`SETUP.md`](./SETUP.md).

---

## 1. Why

OBSERVED mode (`AI_RUN_SUITE=1`) is the only way the classifier reaches a real
pass/fail signal — it locates, installs, and runs the suite. Today it does that
**directly on the developer's machine**, with no isolation:

- **Arbitrary code execution.** `pnpm install` / `pip install` on a PR branch
  runs that branch's install/postinstall scripts on the laptop. Pointed at an
  untrusted `--pr N`, that is RCE with the developer's shell, env, and creds.
- **Mess.** It leaves `node_modules/`, downloaded browsers (Playwright Chromium),
  caches, and other build artifacts behind in the working tree.
- **Credential blast radius.** The run has ambient access to everything the
  developer's shell can reach (`gh` auth, cloud creds, SSH keys, the metricsai
  webhook key).

The fix: run OBSERVED inside a fast, disposable on-device VM
([smolvm](https://github.com/smol-machines/smolvm)), with only the credentials
and network egress the classifier actually needs, and nothing left behind.

This plan does **not** change INFERRED mode (read-only, no execution — no sandbox
needed) or CI (already runs in a disposable runner). It targets the local
OBSERVED path only.

---

## 2. What smolvm gives us

From the smolvm README (verify against the pinned version at implementation
time — flags below are what the design assumes):

- **Ephemeral VMs**: `smolvm machine run --image <img> -- <cmd>` — "cleaned up
  after exit". Sub-second cold start; macOS (Apple Silicon) + Linux (KVM).
- **Volume mount**: `-v /host/dir:/workspace` (directories only; `/workspace`
  is the priority mount).
- **Egress control**: network is **off by default**; `--net` enables it and
  `--allow-host <host>` whitelists destinations. No `--net` → no network.
- **SSH forwarding**: `--ssh-agent` forwards the host agent; "private keys never
  enter the guest" (hypervisor-enforced).
- **Resources**: `--cpus`, `--mem`, `--gpu`.

**Documented gaps the design must not assume away** (not in the README as of
writing — confirm before building):

- **No `--env` / `-e` flag.** Env vars must cross via a file in the mount or via
  the `-- sh -c '…'` command line. We use the **env-file in the mount** (command
  line is visible in host `ps`).
- **No `--user` / `--workdir` flags documented.** The entrypoint script `cd`s
  itself; user handling is whatever the image defaults to.
- **Exit-code propagation undocumented.** The plan treats it as a risk
  (§7) — must verify `smolvm machine run` returns the in-VM command's exit code,
  since `--gate` and CI semantics depend on it.

---

## 3. Architecture — the control plane

A new wrapper, the **sandbox control plane**, sits between the `test-classifier`
function and the dispatcher. It is invoked only when sandboxing is requested for
an OBSERVED run; everything else (INFERRED, CI) bypasses it.

```
test-classifier --pr N --submit          (user, on host)
        │  AI_RUN_SUITE=1 and sandbox enabled?
        ▼
sandbox control plane  (NEW, host-side)
        │  1. mint an ephemeral staging dir (0700)
        │  2. stage repo checkout + env-file + copied cred dirs
        │  3. smolvm machine run  -v staging:/workspace  --net --allow-host …
        │        └── in-VM entrypoint: source env, cd repo, exec dispatcher
        │  4. capture stdout/stderr + exit code
        │  5. teardown: shred secrets, rm staging, (VM auto-cleaned)
        ▼
results surface on host exactly as a non-sandboxed run would
```

The dispatcher and the AI CLIs run **unmodified inside the VM**. The control
plane's only job is staging-in, invocation, and teardown — it is the trust
boundary.

### 3.1 Credential transport (decided: ephemeral env-file + config-dir copy)

The AI CLIs authenticate two different ways, so we handle both:

- **API-key style**: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, plus `GH_TOKEN`,
  `METRICSAI_WEBHOOK_URL`/`_KEY`/`_TAB`, and the `AI_REVIEW_*` / `AI_SUITE_*`
  control vars → written to `staging/.env` (mode `0600`).
- **CLI-config style**: Claude Code (`~/.claude`) and Codex (`~/.codex`)
  auth via their own config dirs (OAuth/subscription login, not always a raw
  key) → the needed config dir is **copied** (not symlinked) into
  `staging/cred/<tool>/` and the in-VM `HOME` is pointed at it.

In-VM entrypoint (sketch — not final):

```sh
set -a; . /workspace/.env; set +a          # env, never on the command line
export HOME=/workspace/cred                 # so claude/codex find their config
cd /workspace/repo
exec testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh "$@"
```

Only the **minimum** is staged — we copy the specific tool's config for the
resolved `AI_REVIEW_TOOL`, not the whole home dir. SSH (if a private dep needs
it) uses `--ssh-agent` so keys never enter the guest.

### 3.2 Network egress (decided: strict allowlist)

`--net` plus an explicit `--allow-host` list, nothing else:

| Host | Why |
|---|---|
| `api.github.com` | PR lookup + comment posting (`gh` / `gh api`) |
| `api.anthropic.com` | Claude inference (or provider equivalent) |
| `script.google.com` + `script.googleusercontent.com` | metricsai webhook (note the 302 to googleusercontent) |
| repo's package registries | OBSERVED installs — `registry.npmjs.org`, PyPI, etc. |

The allowlist is **configurable** (a repo may need a private registry or a
provider proxy). Default list above; override via a config var (e.g.
`AI_SANDBOX_ALLOW_HOSTS`). If an OBSERVED install reaches an unlisted host it
fails closed — documented as the expected, safe behavior, with the fix being to
add the host deliberately.

### 3.3 The mount = the workspace, and the "no mess" guarantee

`/workspace` is a host staging dir, **not** the developer's real checkout. We
stage a clean copy of the repo (or a `git worktree`/clone of HEAD) into
`staging/repo`. Consequences:

- Installs, `node_modules/`, downloaded browsers, caches → all land in the
  ephemeral staging dir, never in the real working tree.
- Teardown removes the staging dir entirely → **nothing left behind**.
- The real checkout is never mounted, so the VM can't modify it even if the
  agent goes wrong.

Trade-off: staging a copy costs disk + copy time. Mitigation in §6.

---

## 4. Lifecycle (good practices)

The control plane is built around a strict create→use→teardown lifecycle with
**guaranteed cleanup even on failure/interrupt**:

1. **Preflight** — check `smolvm` is installed and the platform supports it;
   resolve `AI_REVIEW_TOOL`; verify required creds exist *before* minting
   anything. Fail fast with a clear message.
2. **Stage (mint)** — `mktemp -d` at `0700`; copy repo (HEAD/PR ref), write
   `.env` at `0600`, copy the one needed cred dir. Record the path in a single
   variable.
3. **Trap** — install `trap cleanup EXIT INT TERM` *immediately after* the
   staging dir exists, so an interrupt during the run still tears down.
4. **Run** — `smolvm machine run` with the mount, `--net` + allowlist, resource
   caps (`--cpus`/`--mem`), and a wall-clock timeout (reuse
   `AI_SUITE_TIMEOUT_SECS`). Stream stdout/stderr through to the host.
5. **Capture** — propagate the in-VM exit code as the control plane's exit code
   (pending verification, §7). Copy out only declared artifacts if any (e.g. the
   JSON block is already on stdout — no file copy-out needed by default).
6. **Teardown (cleanup)** — `shred -u staging/.env` (best-effort; fall back to
   overwrite+rm where `shred` is unavailable, e.g. APFS/macOS caveat noted),
   `rm -rf staging`, ensure the ephemeral VM is gone (it auto-cleans, but
   assert it). Idempotent — safe to run twice.
7. **No persistent state** — we use `machine run` (ephemeral), never
   `machine create`. No named VMs accrue. (A future optimization may keep a
   *prewarmed base* VM for deps — see §6 — but that's opt-in and separately
   torn down.)

**Secret hygiene:** secrets exist only in the `0600` env-file inside the `0700`
staging dir, for the lifetime of one run, and are shredded on teardown. They are
never passed as command-line args (host `ps` exposure) and never written to the
real checkout. The copied cred dir is likewise shredded/removed.

---

## 5. Integration surface (minimal, opt-in)

- **New flag / env:** `--sandbox` (or `AI_SANDBOX=1`) opts an OBSERVED run into
  the VM. Default for now is **off** (so nothing changes silently); once proven,
  consider flipping the default so `AI_RUN_SUITE=1` *implies* `--sandbox` on
  supporting platforms, with `--no-sandbox` as the escape hatch.
- **Where it lives:** a new `scripts/sandbox-run.sh` in the test-classifier
  skill, plus a thin branch in the dispatcher (or the zsh function) that routes
  OBSERVED+sandbox through it. The dispatcher stays runnable bare (CI path
  unaffected).
- **Docs:** update `LOCAL_TEST_CLASSIFIER.md` — turn the current "no sandbox"
  WARNING into "OBSERVED runs sandboxed when `--sandbox` is set; here's how,"
  and document the allowlist override + the platform requirements.

---

## 6. Performance / ergonomics

- **Cold start** is sub-second per smolvm, but **dependency install** is the
  real cost (often minutes). Options, in order of effort:
  - *Baseline*: install every run inside the fresh VM (simple, slow, fully
    isolated).
  - *Prewarmed deps*: a `pack create` base image (or a kept warm VM) with the
    toolchain (node/pnpm/python) preinstalled, so only project deps install per
    run.
  - *Cached registry mount*: mount a read-only host package cache (risk:
    re-introduces a host write surface — evaluate carefully).
- **GPU/browser**: Playwright browser-mode suites need a browser in the guest;
  `--gpu` and a browser-capable image may be required. Flag as a spike (§8).

---

## 7. Risks / open questions (must resolve before/while building)

1. **Exit-code propagation** — does `smolvm machine run` return the in-VM
   command's code? `--gate` and CI depend on it. *Spike first.*
2. **No `--env` flag** — confirmed approach is env-file; verify nothing in the
   CLIs requires a real env var set *before* the shell (unlikely).
3. **Browser-mode suites in-guest** — does Playwright/Chromium run headless in
   the smolvm guest? (The live run that motivated this worked on the *host*; the
   guest is unproven.)
4. **`shred` on macOS/APFS** — copy-on-write + SSD wear-leveling weaken
   `shred`'s guarantees; the staging dir being ephemeral + unmounted is the
   primary control. Document honestly.
5. **Cred-dir copy correctness** — Claude/Codex config may contain
   machine-bound tokens or absolute paths that don't survive a copy + `HOME`
   remap. *Spike per tool.*
6. **Egress allowlist completeness** — first real OBSERVED run in-VM will reveal
   missing hosts; expect to iterate the default list.
7. **Platform coverage** — Linux needs KVM; some dev laptops/VMs lack it. The
   control plane must detect and fall back (refuse to run OBSERVED unsandboxed
   silently — instead error and require explicit `--no-sandbox`).

---

## 8. Phased delivery

- **Phase 0 — Spikes (de-risk).** *(Pending a real smolvm install.)* Verify
  exit-code propagation, env-file sourcing, one AI CLI authenticating from a
  copied config dir, and a trivial `pnpm test` running in-guest. The control
  plane is written to these assumptions; the spikes confirm them on real
  hardware. **Gate flipping the default (Phase 3) on these.**
- **Phase 1 — Control plane MVP.** ✅ *Implemented.* `sandbox-run.sh` with
  stage→run→teardown, ephemeral `0600` env-file + the resolved tool's copied
  config dir, strict `--allow-host` allowlist, trap-based cleanup with secret
  shredding. Dispatcher routes OBSERVED+`AI_SANDBOX=1` through it (recursion-
  guarded via `AI_SANDBOX_ACTIVE`). INFERRED and CI untouched; opt-in, default
  off. Host-side behavior tested (routing matrix, staging layout, env-file
  contents, teardown); preflight fails closed when `smolvm` is absent.
- **Phase 2 — Hardening + ergonomics.** Prewarmed deps, browser-mode support,
  allowlist override config, `shred` fallbacks, clear platform-detection errors.
- **Phase 3 — Make it the default.** Flip `AI_RUN_SUITE=1` to imply `--sandbox`
  on supported platforms; `--no-sandbox` escape hatch; update all docs and the
  onboarding warning.

Each phase is its own PR. Nothing merges to `main` without explicit approval.

---

## 9. Out of scope

- Sandboxing INFERRED (read-only; no execution).
- Changing CI (already isolated).
- The fork repo-resolution / credential-handling fixes already shipped (#64).
- Replacing Codex's own `--sandbox` — smolvm is an *outer* boundary; the inner
  one stays as defense-in-depth.
