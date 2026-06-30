#!/usr/bin/env bash
# .skills/test-classifier/scripts/sandbox-run.sh
#
# Sandbox CONTROL PLANE for OBSERVED test-classifier runs.
#
# OBSERVED mode (AI_RUN_SUITE=1) installs and runs the change-under-test's code.
# Run directly on a laptop that is arbitrary code execution with the developer's
# full ambient credentials, and it litters the working tree with node_modules/,
# downloaded browsers, and caches. This wrapper runs that work inside a
# disposable on-device smolvm VM instead:
#
#   • the VM gets ONLY the credentials the classifier needs, via an ephemeral
#     0600 env-file + a copied per-tool CLI config dir — smolvm has no --env
#     flag, so secrets stay OFF the command line (no host `ps` exposure);
#   • network egress is a strict --allow-host allowlist (fails closed);
#   • /workspace is a STAGED COPY of the repo, never the real checkout, so all
#     install artifacts land in the ephemeral staging dir and vanish on teardown;
#   • the VM is ephemeral (`machine run`, auto-cleaned) — no named VMs accrue.
#
# It is invoked by the dispatcher when AI_SANDBOX=1 and AI_RUN_SUITE=1. The
# dispatcher then runs UNMODIFIED inside the VM; this script's only job is
# stage-in, invocation, and guaranteed teardown — it is the trust boundary.
#
# Design doc: testing/classifier/docs/SANDBOXED_OBSERVED.md
#
# Usage (normally called by the dispatcher, not directly):
#   sandbox-run.sh -- <dispatcher args…>
#
# Environment:
#   AI_REVIEW_TOOL          claude | codex | copilot   (selects which CLI config
#                           dir is staged into the VM)
#   AI_SANDBOX_ALLOW_HOSTS  space-separated egress allowlist override; defaults
#                           to the classifier's known hosts (see below)
#   AI_SANDBOX_IMAGE        OCI image for the guest (default: node:20-bookworm —
#                           has node+npm; override per the repo's toolchain)
#   AI_SANDBOX_CPUS         vCPUs for the guest        (default: 4)
#   AI_SANDBOX_MEM          guest memory, MiB          (default: 4096)
#   AI_SUITE_TIMEOUT_SECS   wall-clock cap, forwarded as the in-VM timeout
#   AI_SANDBOX_KEEP         if "1", do NOT tear down the staging dir (debug only)

set -euo pipefail

# ── Resolve roots (mirror the dispatcher's own walk-up) ─────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .../testing/classifier/.skills/test-classifier/scripts → repo root is 5 up.
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  echo "✗ sandbox-run: not inside a git repository" >&2
  exit 1
fi

# Path of the dispatcher RELATIVE to the repo root — identical inside the VM,
# since /workspace/repo is a copy of this same tree.
DISPATCHER_REL="testing/classifier/.skills/test-classifier/scripts/test-classifier-dispatcher.sh"

# ── Args: everything after `--` is the dispatcher's argv ────────────────────
DISPATCH_ARGS=()
seen_sep=0
for a in "$@"; do
  if [[ "${seen_sep}" -eq 0 && "${a}" == "--" ]]; then seen_sep=1; continue; fi
  DISPATCH_ARGS+=("${a}")
done

# ── Logging helpers (stderr; stdout is reserved for the dispatcher's output) ─
log()  { echo "[sandbox] $*" >&2; }
die()  { echo "[sandbox] ✗ $*" >&2; exit 1; }

# ── Preflight — fail fast BEFORE minting anything ───────────────────────────
preflight() {
  command -v smolvm >/dev/null 2>&1 \
    || die "smolvm is not installed. Install it (see https://github.com/smol-machines/smolvm), or run without AI_SANDBOX=1 (unsandboxed OBSERVED) / with --no-sandbox."

  [[ -n "${AI_REVIEW_TOOL:-}" ]] \
    || die "AI_REVIEW_TOOL is not set (need it to stage the right CLI config). Set claude|codex|copilot."

  # Resolve and lower-case the tool name (matches the lib's own validation).
  TOOL="$(printf '%s' "${AI_REVIEW_TOOL}" | tr '[:upper:]' '[:lower:]')"
  case "${TOOL}" in
    claude|codex|copilot) ;;
    *) die "AI_REVIEW_TOOL='${AI_REVIEW_TOOL}' is not one of claude|codex|copilot." ;;
  esac
}

# ── Egress allowlist ────────────────────────────────────────────────────────
# The hosts the classifier provably needs. Overridable for private registries /
# provider proxies. Note script.googleusercontent.com — the metricsai webhook
# 302s there. Package registries are included so OBSERVED installs work; trim
# them if a repo vendors its deps.
default_allow_hosts() {
  echo "api.github.com \
codeload.github.com \
api.anthropic.com \
script.google.com \
script.googleusercontent.com \
registry.npmjs.org \
pypi.org \
files.pythonhosted.org"
}

# ── Stage-in: build the ephemeral workspace ─────────────────────────────────
# Layout under the 0700 staging dir:
#   staging/repo/      a clean copy of the repo at HEAD (NOT the live checkout)
#   staging/.env       0600; the env vars the dispatcher + CLIs read
#   staging/cred/      becomes $HOME in the VM; holds the one tool's config dir
STAGING=""
cleanup() {
  # Idempotent, runs on EXIT/INT/TERM. Shred the secret file first (best-effort;
  # the staging dir being ephemeral + unmounted is the primary control — see the
  # macOS/APFS caveat in the design doc), then remove the whole tree.
  [[ -n "${STAGING}" && -d "${STAGING}" ]] || return 0
  if [[ "${AI_SANDBOX_KEEP:-0}" == "1" ]]; then
    log "AI_SANDBOX_KEEP=1 — leaving staging dir for inspection: ${STAGING}"
    return 0
  fi
  if [[ -f "${STAGING}/.env" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${STAGING}/.env" 2>/dev/null || rm -f "${STAGING}/.env"
    else
      # No shred (e.g. stock macOS): overwrite then remove, best-effort.
      : > "${STAGING}/.env" 2>/dev/null || true
      rm -f "${STAGING}/.env"
    fi
  fi
  rm -rf "${STAGING}"
}

stage() {
  STAGING="$(mktemp -d "${TMPDIR:-/tmp}/tc-sandbox.XXXXXX")"
  chmod 0700 "${STAGING}"
  # Install the trap IMMEDIATELY after the dir exists, so an interrupt mid-stage
  # still tears down.
  trap cleanup EXIT INT TERM

  # 1) Repo copy at HEAD — git archive avoids copying node_modules/.git cruft and
  #    gives a clean tree. Untracked WIP is intentionally excluded (OBSERVED
  #    classifies committed state; matches the dispatcher's range semantics).
  mkdir -p "${STAGING}/repo"
  log "staging repo copy (HEAD) → ${STAGING}/repo"
  git -C "${REPO_ROOT}" archive --format=tar HEAD | tar -x -C "${STAGING}/repo"

  # 2) Env-file (0600). Only the vars the classifier reads, plus provider keys.
  #    We forward what is SET in the current environment; absent vars are skipped.
  local envf="${STAGING}/.env"
  ( umask 077; : > "${envf}" )
  forward_env() {
    local name="$1"
    # Indirect expansion; emit only if set and non-empty.
    if [[ -n "${!name:-}" ]]; then
      # Quote the value safely for `source` via printf %q.
      printf '%s=%q\n' "${name}" "${!name}" >> "${envf}"
    fi
  }
  log "writing ephemeral env-file (0600)"
  # Control vars the dispatcher/lib read:
  for v in AI_REVIEW_TOOL AI_RUN_SUITE AI_REVIEW_REPO \
           AI_SUITE_TIMEOUT_SECS AI_SUITE_MAX_TURNS AI_REVIEW_STREAM \
           GH_TOKEN GITHUB_TOKEN \
           METRICSAI_WEBHOOK_URL METRICSAI_WEBHOOK_KEY METRICSAI_WEBHOOK_TAB \
           ANTHROPIC_API_KEY OPENAI_API_KEY; do
    forward_env "$v"
  done
  # The in-VM run IS the suite execution, so force OBSERVED + non-interactive,
  # and mark the sandbox active so the in-VM dispatcher does NOT re-route (which
  # would recurse infinitely).
  {
    echo "AI_RUN_SUITE=1"
    echo "AI_SANDBOX_ACTIVE=1"     # recursion guard read by the dispatcher
    echo "CI=true"                 # non-TTY guard: skip the --submit prompt in-VM
    echo "HOME=/workspace/cred"    # so claude/codex find their copied config
  } >> "${envf}"

  # 3) Per-tool CLI config dir → becomes $HOME/<dir> in the VM. Copy (not link)
  #    so nothing in the VM can reach back to the host config. We copy only the
  #    resolved tool's dir, not the whole home.
  mkdir -p "${STAGING}/cred"
  case "${TOOL}" in
    claude)  stage_cred_dir "${HOME}/.claude"  ".claude" ;;
    codex)   stage_cred_dir "${HOME}/.codex"   ".codex"  ;;
    copilot) stage_cred_dir "${HOME}/.config/gh" ".config/gh" ;;  # copilot via gh
  esac
  # gh auth (for posting) — always stage if present, any tool may post.
  [[ -d "${HOME}/.config/gh" ]] && stage_cred_dir "${HOME}/.config/gh" ".config/gh"
}

# Copy a host config dir into the staged cred home, preserving the relative path.
# Args: <host src dir> <dest rel path under staging/cred>
stage_cred_dir() {
  local src="$1" rel="$2"
  if [[ ! -d "${src}" ]]; then
    log "note: ${src} not present — skipping (tool may rely on an env key instead)"
    return 0
  fi
  local dest="${STAGING}/cred/${rel}"
  mkdir -p "$(dirname "${dest}")"
  # -a preserves modes; the staging dir is already 0700 so this stays private.
  cp -a "${src}" "${dest}"
  log "staged credential dir ${rel} (copied, not linked)"
}

# ── Build and run the smolvm invocation ─────────────────────────────────────
run_in_vm() {
  local image="${AI_SANDBOX_IMAGE:-node:20-bookworm}"
  local cpus="${AI_SANDBOX_CPUS:-4}"
  local mem="${AI_SANDBOX_MEM:-4096}"

  # Assemble --allow-host flags from the allowlist.
  local hosts allow=()
  hosts="${AI_SANDBOX_ALLOW_HOSTS:-$(default_allow_hosts)}"
  local h
  for h in ${hosts}; do allow+=( --allow-host "${h}" ); done

  # In-VM entrypoint: source the env (never on the command line), cd into the
  # repo copy, exec the dispatcher with the original args. A timeout wraps it if
  # AI_SUITE_TIMEOUT_SECS is set, so a runaway suite can't hang the VM forever.
  # NOTE: we rely on `smolvm machine run` propagating the in-VM exit code to the
  # host. This is asserted, not assumed — see SANDBOXED_OBSERVED.md §7 spike #1.
  local timeout_prefix=""
  if [[ -n "${AI_SUITE_TIMEOUT_SECS:-}" ]]; then
    timeout_prefix="timeout ${AI_SUITE_TIMEOUT_SECS}"
  fi

  # Quote each dispatcher arg for safe embedding in the in-VM sh -c string.
  local quoted_args=""
  local arg
  for arg in "${DISPATCH_ARGS[@]+"${DISPATCH_ARGS[@]}"}"; do
    quoted_args+=" $(printf '%q' "${arg}")"
  done

  local in_vm_script
  in_vm_script="$(cat <<INNER
set -e
set -a; . /workspace/.env; set +a
cd /workspace/repo
exec ${timeout_prefix} ./${DISPATCHER_REL}${quoted_args}
INNER
)"

  log "launching ephemeral VM (image=${image}, cpus=${cpus}, mem=${mem})"
  log "egress allowlist: ${hosts}"
  # --net + allowlist; mount the staging dir as /workspace; ephemeral run.
  smolvm machine run \
    --net "${allow[@]}" \
    -v "${STAGING}:/workspace" \
    --image "${image}" \
    --cpus "${cpus}" \
    --mem "${mem}" \
    -- sh -c "${in_vm_script}"
}

main() {
  preflight
  stage
  run_in_vm   # exit code flows through; trap handles teardown
}

main
