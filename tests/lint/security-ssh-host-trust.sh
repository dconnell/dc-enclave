#!/usr/bin/env bash
# =============================================================================
# tests/lint/security-ssh-host-trust.sh - M4 regression: GitHub SSH host verification
# must use pinned keys, never runtime TOFU.
#
# GitHub host trust is established at image-build time from a pinned, reviewed
# known_hosts file -- never learned at runtime via `ssh-keyscan` or silently
# accepted via `StrictHostKeyChecking accept-new`. Both of the latter are
# unattended trust decisions that accept whatever key the network presents, so
# they are exactly the TOFU behavior pinning is meant to eliminate.
#
# This guard is static (no backend/container required) and asserts:
#   - no `ssh-keyscan ... github.com` in tracked runtime/bootstrap scripts,
#   - no `StrictHostKeyChecking accept-new` in the base Containerfile,
#   - the pinned known_hosts file exists, is copied into the base image, and is
#     referenced via UserKnownHostsFile with StrictHostKeyChecking yes,
#   - the pinned keys cover all three GitHub key types (ed25519/ecdsa/rsa) so a
#     single algorithm rollover cannot break connectivity,
#   - the pinned keys' fingerprints match GitHub's canonical published
#     fingerprints -- catches a wrong/poisoned pin, including during rotation.
#
# End-to-end SSH connectivity inside a real container is covered by the
# backend-dependent verification checklist in plans/security/m4.md, not here.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# Canonical GitHub SSH host key fingerprints, as published by GitHub at
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# and served (as ssh_key_fingerprints) over HTTPS at https://api.github.com/meta.
# Updating these constants IS the rotation action: a deliberate, reviewed change
# performed together with updating Containerfiles/ssh/github_known_hosts. See
# plans/security/m4.md (Verification channels) for the cross-channel procedure.
readonly FP_RSA='SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s'
readonly FP_ECDSA='SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM'
readonly FP_ED25519='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'

command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen required for this check"

BASE="$ROOT_DIR/Containerfiles/Containerfile.base"
PIN="$ROOT_DIR/Containerfiles/ssh/github_known_hosts"
[[ -f "$BASE" ]] || fail "base Containerfile missing: $BASE"
[[ -f "$PIN" ]] || fail "pinned known_hosts missing: $PIN (expected at $PIN)"

# --- no runtime ssh-keyscan for github.com ------------------------------------
# Runtime keyscan trusts whatever key the network presents with no verification.
mapfile -t RUNTIME_SCRIPTS < <(git -C "$ROOT_DIR" ls-files 'scripts/*' | grep -E '\.sh$' || true)
[[ ${#RUNTIME_SCRIPTS[@]} -gt 0 ]] || fail "no tracked scripts found to scan"

scan_re='ssh-keyscan[[:space:]].*github\.com'
keyscan_offenders=()
for s in "${RUNTIME_SCRIPTS[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    keyscan_offenders+=("$ROOT_DIR/$s:$hit")
  done < <(grep -En "$scan_re" "$ROOT_DIR/$s" 2>/dev/null || true)
done

if [[ ${#keyscan_offenders[@]} -gt 0 ]]; then
  echo "FAIL: runtime ssh-keyscan of github.com reintroduces TOFU:" >&2
  printf '  %s\n' "${keyscan_offenders[@]}" >&2
  echo "GitHub host keys are pinned in-image; remove the runtime keyscan." >&2
  exit 1
fi
pass "no runtime ssh-keyscan of github.com in tracked scripts"

# --- no accept-new in base image ----------------------------------------------
# accept-new silently trusts an unseen host key. The base image must fail closed.
if grep -Eq 'StrictHostKeyChecking[[:space:]]+accept-new' "$BASE"; then
  fail "base Containerfile still uses StrictHostKeyChecking accept-new (silent TOFU)"
fi
pass "no accept-new in base Containerfile"

# --- base image wires in pinned keys and fails closed -------------------------
# The pinned file must be copied into the image, referenced from the Host
# github.com block via UserKnownHostsFile, and enforced with StrictHostKeyChecking yes.
grep -Fq "github_known_hosts" "$BASE" \
  || fail "base Containerfile does not reference the pinned github_known_hosts file"
grep -Eq 'UserKnownHostsFile[[:space:]].*github' "$BASE" \
  || fail "base Containerfile must point Host github.com UserKnownHostsFile at the pinned key file"
grep -Eq 'StrictHostKeyChecking[[:space:]]+yes' "$BASE" \
  || fail "base Containerfile must set StrictHostKeyChecking yes for github.com"
pass "base image pins github.com host keys and fails closed"

# --- pinned file covers all three GitHub key types ----------------------------
# Resilience: pinning all of ed25519/ecdsa/rsa means a single algorithm
# rotation (GitHub rotated RSA in 2023) leaves the others working.
has_key_type() {
  local type="$1"
  grep -Eq "^github\.com[[:space:]]+${type}[[:space:]]" "$PIN"
}
has_key_type 'ssh-ed25519'         || fail "pinned file missing ssh-ed25519 entry"
has_key_type 'ecdsa-sha2-nistp256' || fail "pinned file missing ecdsa-sha2-nistp256 entry"
has_key_type 'ssh-rsa'             || fail "pinned file missing ssh-rsa entry"
pass "pinned file covers ed25519, ecdsa, and rsa key types"

# --- pinned keys match GitHub's canonical fingerprints ------------------------
# Strongest guard: if the pinned key bytes diverge from GitHub's published
# fingerprints, the pin is wrong or poisoned. A legitimate rotation requires
# updating the FP_* constants above AND the pinned key file in the same change.
declare -A WANT=(
  [ssh-ed25519]="$FP_ED25519"
  [ecdsa-sha2-nistp256]="$FP_ECDSA"
  [ssh-rsa]="$FP_RSA"
)
for ktype in ssh-ed25519 ecdsa-sha2-nistp256 ssh-rsa; do
  line="$(grep -E "^github\.com[[:space:]]+${ktype}[[:space:]]" "$PIN" | head -n1)"
  [[ -n "$line" ]] || fail "pinned file missing $ktype entry during fingerprint check"
  got_fp="$(ssh-keygen -lf - <<<"$line" | awk '{print $2}')"
  want_fp="${WANT[$ktype]}"
  [[ "$got_fp" == "$want_fp" ]] \
    || fail "pinned $ktype fingerprint mismatch: got $got_fp, expected $want_fp" \
            "(update the pinned file + FP_* constants together if this is a rotation)"
done
pass "pinned key fingerprints match GitHub's published values"

echo ""
echo "All M4 SSH host-trust checks passed."
