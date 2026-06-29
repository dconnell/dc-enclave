#!/usr/bin/env bash
# =============================================================================
# tests/lint/security-ssh-host-trust.sh - SSH host verification must use pinned
# keys, never runtime TOFU, for EVERY supported git host.
#
# Host trust is established at image-build time from a pinned, reviewed
# known_hosts file -- never learned at runtime via `ssh-keyscan` or silently
# accepted via `StrictHostKeyChecking accept-new`. Both of the latter are
# unattended trust decisions that accept whatever key the network presents, so
# they are exactly the TOFU behavior pinning is meant to eliminate.
#
# This guard is data-driven over the provider registry (lib/git-host.sh): for
# each known provider it asserts:
#   - no `ssh-keyscan ... <ssh_host>` in tracked runtime/bootstrap scripts,
#   - the pinned known_hosts file exists, is copied into the base image, and is
#     referenced via UserKnownHostsFile with StrictHostKeyChecking yes,
#   - the pinned keys cover all three key types (ed25519/ecdsa/rsa) so a single
#     algorithm rollover cannot break connectivity,
#   - the pinned keys' fingerprints match the host's canonical published
#     fingerprints -- catches a wrong/poisoned pin, including during rotation.
# Plus two global checks: no `accept-new` in the base Containerfile, and every
# pin file's header names its verification channels + a Last-verified date.
#
# Adding a host = adding a PROVIDERS entry + its FP_* constants; the loop scales.
# End-to-end SSH connectivity inside a real container is covered by the
# backend-dependent verification checklist, not here.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Load the provider registry so the loop is driven by the same source of truth
# the auth code uses (lib/git-host.sh -> dce_git_host_known_providers).
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/git-host.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen required for this check"

BASE="$ROOT_DIR/Containerfiles/Containerfile.base"
SSH_DIR="$ROOT_DIR/Containerfiles/ssh"
[[ -f "$BASE" ]] || fail "base Containerfile missing: $BASE"

# Canonical SSH host key fingerprints, as published by each host. Updating a
# constant IS the rotation action: a deliberate, reviewed change performed
# together with updating the matching Containerfiles/ssh/<host>_known_hosts.
# See docs/how-to/add-git-host.md (Verification channels) for the per-host
# cross-channel procedure.
#
# GitHub: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
readonly FP_GITHUB_RSA='SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s'
readonly FP_GITHUB_ECDSA='SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM'
readonly FP_GITHUB_ED25519='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
#
# GitLab: https://docs.gitlab.com/ee/user/gitlab_com/#ssh-host-keys-fingerprints
readonly FP_GITLAB_ED25519='SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8'
readonly FP_GITLAB_ECDSA='SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw'
readonly FP_GITLAB_RSA='SHA256:ROQFvPThGrW4RuWLoL9tq9I9zJ42fK4XywyRtbOz/EQ'

# Resolve a provider's three fingerprints by id (kept here, not in the registry,
# because they are test-only truth anchors, not runtime auth data).
fp_ed25519_for() {
  case "$1" in
    github) printf '%s' "$FP_GITHUB_ED25519" ;;
    gitlab) printf '%s' "$FP_GITLAB_ED25519" ;;
  esac
}
fp_ecdsa_for() {
  case "$1" in
    github) printf '%s' "$FP_GITHUB_ECDSA" ;;
    gitlab) printf '%s' "$FP_GITLAB_ECDSA" ;;
  esac
}
fp_rsa_for() {
  case "$1" in
    github) printf '%s' "$FP_GITHUB_RSA" ;;
    gitlab) printf '%s' "$FP_GITLAB_RSA" ;;
  esac
}

# --- no accept-new in base image (global) ------------------------------------
# accept-new silently trusts an unseen host key. The base image must fail closed.
if grep -Eq 'StrictHostKeyChecking[[:space:]]+accept-new' "$BASE"; then
  fail "base Containerfile still uses StrictHostKeyChecking accept-new (silent TOFU)"
fi
pass "no accept-new in base Containerfile"

# --- StrictHostKeyChecking yes is present (global) ---------------------------
grep -Eq 'StrictHostKeyChecking[[:space:]]+yes' "$BASE" \
  || fail "base Containerfile must set StrictHostKeyChecking yes for pinned hosts"
pass "base Containerfile enforces StrictHostKeyChecking yes"

# --- collect tracked runtime scripts once (for the per-host keyscan scan) -----
mapfile -t RUNTIME_SCRIPTS < <(git -C "$ROOT_DIR" ls-files 'scripts/*' | grep -E '\.sh$' || true)
[[ ${#RUNTIME_SCRIPTS[@]} -gt 0 ]] || fail "no tracked scripts found to scan"

# --- per-provider pin integrity (data-driven over the registry) ---------------
check_provider() {
  local provider="$1"
  local pin="" ssh_host="" display=""
  pin="$SSH_DIR/$(dce_git_host_field "$provider" known_hosts_filename)"
  ssh_host="$(dce_git_host_field "$provider" ssh_host)"
  display="$(dce_git_host_field "$provider" web_host)"

  [[ -f "$pin" ]] || fail "pinned known_hosts missing for $provider: $pin"

  # (a) no runtime ssh-keyscan of this host. Runtime keyscan trusts whatever
  # key the network presents with no verification.
  local scan_re="ssh-keyscan[[:space:]].*${ssh_host//./\\.}"
  local offenders=()
  for s in "${RUNTIME_SCRIPTS[@]}"; do
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      offenders+=("$ROOT_DIR/$s:$hit")
    done < <(grep -En "$scan_re" "$ROOT_DIR/$s" 2>/dev/null || true)
  done
  if [[ ${#offenders[@]} -gt 0 ]]; then
    echo "FAIL: runtime ssh-keyscan of $ssh_host reintroduces TOFU:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    echo "$ssh_host host keys are pinned in-image; remove the runtime keyscan." >&2
    exit 1
  fi
  pass "no runtime ssh-keyscan of $ssh_host in tracked scripts"

  # (b) base image wires in this provider's pinned keys.
  grep -Fq "$(basename "$pin")" "$BASE" \
    || fail "base Containerfile does not reference the pinned $provider file ($pin)"
  # The ssh config block points the host's UserKnownHostsFile at the copied pin
  # (COPY maps <provider>_known_hosts -> ssh_known_hosts.<provider>).
  grep -Eq "UserKnownHostsFile[[:space:]]+[^[:space:]]*ssh_known_hosts\.${provider}" "$BASE" \
    || fail "base Containerfile must point $ssh_host UserKnownHostsFile at ssh_known_hosts.$provider"
  pass "base image pins $ssh_host host keys and fails closed"

  # (c) pinned file covers all three key types. Resilience: pinning all of
  # ed25519/ecdsa/rsa means a single algorithm rotation leaves the others working.
  local ktype
  for ktype in ssh-ed25519 ecdsa-sha2-nistp256 ssh-rsa; do
    grep -Eq "^${ssh_host//./\\.}[[:space:]]+${ktype}[[:space:]]" "$pin" \
      || fail "pinned $provider file missing $ktype entry"
  done
  pass "pinned $provider file covers ed25519, ecdsa, and rsa key types"

  # (d) pinned keys match the host's canonical fingerprints. Strongest guard:
  # if the pinned key bytes diverge from the published fingerprints, the pin is
  # wrong or poisoned. A legitimate rotation requires updating the FP_* constants
  # above AND the pinned key file in the same change.
  declare -A want=(
    [ssh-ed25519]="$(fp_ed25519_for "$provider")"
    [ecdsa-sha2-nistp256]="$(fp_ecdsa_for "$provider")"
    [ssh-rsa]="$(fp_rsa_for "$provider")"
  )
  local line got_fp want_fp
  for ktype in ssh-ed25519 ecdsa-sha2-nistp256 ssh-rsa; do
    line="$(grep -E "^${ssh_host//./\\.}[[:space:]]+${ktype}[[:space:]]" "$pin" | head -n1)"
    [[ -n "$line" ]] || fail "pinned $provider file missing $ktype entry during fingerprint check"
    got_fp="$(ssh-keygen -lf - <<<"$line" | awk '{print $2}')"
    want_fp="${want[$ktype]}"
    [[ "$got_fp" == "$want_fp" ]] \
      || fail "pinned $provider $ktype fingerprint mismatch: got $got_fp, expected $want_fp" \
              "(update the pinned file + FP_* constants together if this is a rotation)"
  done
  pass "pinned $provider key fingerprints match $display's published values"

  # (e) pin-file header carries the evidence trail: it must name its
  # verification channels and a Last verified date, so a future host's pin can't
  # ship without the provenance the procedure requires.
  grep -Eq 'Last verified:' "$pin" \
    || fail "pinned $provider file header missing 'Last verified:' date"
  grep -Eqi 'channel|verified against|ssh-keyscan|docs\.' "$pin" \
    || fail "pinned $provider file header must name its verification channels"
  pass "pinned $provider file header records verification channels + date"
}

while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  check_provider "$p"
done < <(dce_git_host_known_providers)

echo ""
echo "All SSH host-trust checks passed (data-driven over the provider registry)."
