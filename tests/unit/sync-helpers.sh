#!/usr/bin/env bash
# Synced-workspace (--sync) pure-helper unit tests: volume/session naming,
# transport resolution, backend support, and the install hint.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# --- volume / session naming (deterministic from project slug + 12hex) ---
# Format is dce-sync-<slug>-<12hex> (mirrors dce-hide-<slug>-<12hex>) so two
# projects sharing a 24-char slug prefix still get distinct volumes.
v="$(dce_sync_volume_name "MyProj")"
[[ "$v" == dce-sync-myproj-* ]] && [[ "${#v}" -ge 24 ]] || fail "sync volume name shape [$v]"
[[ "$v" == dce-sync-myproj-$(dce_sha256_hex "sync-v1|MyProj" | cut -c1-12) ]] \
  || fail "sync volume name hash mismatch [$v]"

v="$(dce_sync_volume_name "Apps/Web API")"
[[ "$v" == dce-sync-apps-web-api-* ]] || fail "sync volume name slug collapse [$v]"

# Session name mirrors the volume (one session per project, same derivation).
s="$(dce_sync_session_name "MyProj")"
[[ "$s" == "$v" || "$s" == dce-sync-myproj-* ]] || fail "sync session name [$s]"

# Same project -> same volume across calls (reproducible).
[[ "$(dce_sync_volume_name "proj-x")" == "$(dce_sync_volume_name "proj-x")" ]] \
  || fail "sync volume name must be reproducible"

# Distinct projects -> distinct volumes (collision-free even for long names
# that share a 24-char slug prefix).
a="$(dce_sync_volume_name "test-docker-20260714120000-sync-lifecycle")"
b="$(dce_sync_volume_name "test-docker-20260714120000-sync-snapshot")"
[[ "$a" != "$b" ]] || fail "distinct long projects must not collide on sync volume name"

# Distinct from the hidden-volume and snapshot-volume families by prefix.
hv="$(dce_hidden_volume_name "MyProj" "node_modules")"
[[ "$hv" == dce-hide-* ]] || fail "hidden volume prefix"
[[ "$(dce_sync_volume_name "MyProj")" == dce-sync-* ]] || fail "sync volume prefix"
snap="$(dce_snapshot_volume_name "MyProj" "lbl" "node_modules")"
[[ "$snap" == dce-snapvol-* ]] || fail "snapshot volume prefix"

# --- backend transport + support ---
[[ "$(dce_sync_endpoint_for_backend "docker")" == "docker" ]] || fail "docker transport"
[[ "$(dce_sync_endpoint_for_backend "orbstack")" == "docker" ]] || fail "orbstack transport"
[[ "$(dce_sync_endpoint_for_backend "colima")" == "docker" ]] || fail "colima transport"
[[ -z "$(dce_sync_endpoint_for_backend "podman")" ]] || fail "podman must have no transport (unsupported)"
[[ -z "$(dce_sync_endpoint_for_backend "apple")" ]] || fail "apple must have no transport"

for b in docker orbstack colima; do
  dce_sync_backend_supported "$b" || fail "backend should be supported: $b"
done
for b in apple podman; do
  if dce_sync_backend_supported "$b"; then fail "backend must NOT be sync-supported: $b"; fi
done

# --- beta URL (uses active backend; stub backend_name) ---
# shellcheck disable=SC2329  # stub: invoked indirectly by dce_sync_beta_url.
backend_name() { printf 'docker\n'; }
url="$(dce_sync_beta_url "myapp")"
[[ "$url" == "docker://myapp//workspace" ]] || fail "docker beta url [$url]"

# podman is unsupported (no transport): beta URL resolves empty / fails fast.
# shellcheck disable=SC2329  # stub: invoked indirectly by dce_sync_beta_url.
backend_name() { printf 'podman\n'; }
if url="$(dce_sync_beta_url "myapp" 2>/dev/null)" && [[ -n "$url" ]]; then
  fail "podman beta url must be empty/unsupported, got [$url]"
fi

# --- install hint is non-empty regardless of platform ---
[[ -n "$(dce_mutagen_install_hint)" ]] || fail "install hint must be non-empty"

# --- absent message references the how-to doc ---
msg="$(dce_mutagen_absent_message)"
grep -Fq 'docs/how-to/sync-workspace.md' <<<"$msg" || fail "absent message must link the how-to"

# --- config loader rejects CONTAINER_SYNC=1 + non-empty CONTAINER_HIDDEN_PATHS ---
_cfg_dir="$(mktemp -d)"
trap 'rm -rf "$_cfg_dir"' EXIT
_cfg="$_cfg_dir/config"
{
  printf 'CONTAINER_PROJECT="proj"\n'
  printf 'CONTAINER_BACKEND="docker"\n'
  printf 'CONTAINER_SYNC="1"\n'
  printf 'CONTAINER_HIDDEN_PATHS=(node_modules)\n'
} > "$_cfg"
chmod 600 "$_cfg"
if dce_load_project_config "$_cfg" >/dev/null 2>&1; then
  fail "config loader must reject CONTAINER_SYNC=1 + non-empty CONTAINER_HIDDEN_PATHS"
fi
# And the inverse: CONTAINER_SYNC=1 with an empty hidden set + sync-ignore loads.
{
  printf 'CONTAINER_PROJECT="proj"\n'
  printf 'CONTAINER_BACKEND="docker"\n'
  printf 'CONTAINER_SYNC="1"\n'
  printf 'CONTAINER_HIDDEN_PATHS=()\n'
  printf 'CONTAINER_SYNC_IGNORE_PATHS=(node_modules dist)\n'
} > "$_cfg"
chmod 600 "$_cfg"
dce_load_project_config "$_cfg" >/dev/null 2>&1 \
  || fail "config loader must accept CONTAINER_SYNC=1 with empty hidden + sync-ignore"
[[ "${CONTAINER_SYNC:-}" == "1" ]] || fail "loaded CONTAINER_SYNC"
[[ "${CONTAINER_SYNC_IGNORE_PATHS[1]:-}" == "dist" ]] || fail "loaded sync-ignore array"

# Missing CONTAINER_SYNC on a subsequent load must clear the prior value.
{
  printf 'CONTAINER_PROJECT="proj"\n'
  printf 'CONTAINER_BACKEND="docker"\n'
  printf 'CONTAINER_HIDDEN_PATHS=()\n'
  printf 'CONTAINER_SYNC_IGNORE_PATHS=()\n'
} > "$_cfg"
chmod 600 "$_cfg"
dce_load_project_config "$_cfg" >/dev/null 2>&1 \
  || fail "config loader must accept config without CONTAINER_SYNC"
[[ -z "${CONTAINER_SYNC:-}" ]] || fail "CONTAINER_SYNC must reset when omitted in a later load"

pass "sync helpers (naming, transport, support, hints, config rejection)"
