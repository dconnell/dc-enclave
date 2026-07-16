#!/usr/bin/env bash
# =============================================================================
# lib/common/sync.sh - Synced-workspace (`--sync`) volume + Mutagen lifecycle.
#
# Sourced (never executed directly) via lib/common.sh. Owns the third managed
# volume family, dce-sync-<slug>-<12hex>, and the host-side Mutagen session that
# reconciles it two-way with the host checkout (host = alpha, canonical).
#
# Design invariants (see plans/sync.md):
#   - The host is canonical. Mutagen runs alpha=host, beta=the dce-sync volume
#     (reached through the project container's docker/podman transport), with
#     alpha-wins conflict resolution. The sync volume is a disposable cache of
#     the host that also accepts writes back.
#   - The sync volume is mounted at /workspace (the same path the bind mount
#     uses), so no in-container path moves.
#   - dce-sync-* is a distinct prefix from dce-hide-* and dce-snapvol-* so the
#     clean sweeps ignore it by construction.
#   - Mutagen is a host-side daemon; the session lifecycle is owned here, not by
#     any in-container entrypoint. apple/container has no Mutagen transport and
#     fails fast (see dce_sync_endpoint_for_backend).
#
# Depends on core.sh (dce_project_slug) and, at call time only, the backend_*
# abstraction (lib/container-backend.sh) for beta-endpoint resolution.
# =============================================================================

if [[ -n "${_DC_COMMON_SYNC_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_SYNC_SH_LOADED=1

# Mutagen session create is allowed to block this long on a `sync flush` before
# a rebuild destroys the container (belt-and-suspenders against sync lag).
# Overridable for tests / slow hosts.
: "${DC_SYNC_FLUSH_TIMEOUT:=120}"

# Build the deterministic managed-volume name for a project's synced workspace.
#
# Format: dce-sync-<project-slug>-<12hex>. One workspace per project, derived
# purely from the project (no path component, no randomness) so new/start/
# rebuild/rm all resolve the same volume. The 12hex is sha256(project) so two
# projects whose names share the 24-char slug prefix (dce_project_slug caps at
# 24) still get distinct volumes -- mirroring dce-hide-<slug>-<12hex>. The
# dce-sync- prefix keeps it out of the dce-hide-* hidden-volume sweep and the
# dce-snapvol-* snapshot sweep.
dce_sync_volume_name() {
  local project="$1"

  local project_slug=""
  project_slug="$(dce_project_slug "$project")"

  local key="sync-v1|$project"
  local hash=""
  hash="$(dce_sha256_hex "$key")"
  hash="${hash:0:12}"

  printf 'dce-sync-%s-%s\n' "$project_slug" "$hash"
}

# Build the Mutagen session name for a project. Same derivation as the volume
# (one session per project); the hash makes it unique even for long project
# names that share a slug prefix.
dce_sync_session_name() {
  local project="$1"

  local project_slug=""
  project_slug="$(dce_project_slug "$project")"

  local key="sync-v1|$project"
  local hash=""
  hash="$(dce_sha256_hex "$key")"
  hash="${hash:0:12}"

  printf 'dce-sync-%s-%s\n' "$project_slug" "$hash"
}

# Return 0 if the `mutagen` CLI is on PATH (the host-side sync daemon).
dce_mutagen_present() {
  command -v mutagen >/dev/null 2>&1
}

# Echo the Mutagen version string (best-effort; empty if mutagen is absent or
# its version probe fails). Used by `dce doctor` for synced projects.
dce_mutagen_version() {
  if ! dce_mutagen_present; then
    return 0
  fi
  mutagen version 2>/dev/null | awk 'NR==1 {print; exit}' || true
}

# Echo a per-platform install hint for Mutagen. Uses uname directly (not
# lib/platform.sh) so this helper stays usable wherever common.sh is sourced.
dce_mutagen_install_hint() {
  case "$(uname -s)" in
    Darwin)
      printf 'brew install mutagen-io/mutagen/mutagen'
      ;;
    *)
      printf 'install the release binary from the official Mutagen release archive'
      ;;
  esac
}

# Echo the fail-fast message used when `--sync` is requested but Mutagen is not
# installed. Single source so the create + rebuild paths print identical copy.
dce_mutagen_absent_message() {
  local project="${1:-}"
  local retry="dce new <name> <scope> --sync ..."
  if [[ -n "$project" ]]; then
    retry="dce rebuild-container $project --sync"
  fi
  cat <<EOF
--sync requires the Mutagen sync daemon, which was not found on your PATH.

  macOS:   $(dce_mutagen_install_hint)
  Linux:   $(dce_mutagen_install_hint)

Then re-run:  $retry

See: docs/how-to/sync-workspace.md
EOF
}

# Return 0 if BACKEND supports Mutagen-synced workspaces. Only the pure-docker
# family (docker/orbstack/colima) qualifies: Mutagen's docker transport reaches
# their containers directly. apple/container has no Mutagen transport, and podman
# is excluded because Mutagen has no podman:// transport and the docker-transport
# bridge to a podman-machine VM is blocked by SSH host-key verification (the
# podman socket lives inside the VM). Both fail fast upstream -- see
# dce_sync_unsupported_message.
dce_sync_backend_supported() {
  local backend="$1"
  [[ "$backend" == "docker" || "$backend" == "orbstack" || "$backend" == "colima" ]]
}

# Echo the fail-fast message for `--sync` on a backend that cannot support it.
# Single source so the new-container and rebuild paths print identical copy.
dce_sync_unsupported_message() {  # <backend>
  local backend="$1"
  case "$backend" in
    apple)
      cat <<'EOF'
--sync is not supported on the apple/container backend (no Mutagen transport).
  Use --hide to accelerate generated paths there, or switch to a
  docker-compatible backend (docker, orbstack, colima).
  See: docs/how-to/sync-workspace.md
EOF
      ;;
    podman)
      cat <<'EOF'
--sync is not supported on the podman backend: Mutagen has no podman transport,
  and the docker-transport bridge to a podman-machine VM is blocked by SSH
  host-key verification (the podman socket lives inside the VM). Use
  docker/orbstack/colima for --sync.
  See: docs/how-to/sync-workspace.md
EOF
      ;;
    *)
      printf -- '--sync is not supported on the %s backend.\n  See: docs/how-to/sync-workspace.md\n' "$backend"
      ;;
  esac
}

# Echo the Mutagen transport name for BACKEND: "docker" for docker/orbstack/colima
# (all speak the Docker API Mutagen's docker transport targets). Empty for apple
# (no transport) and podman (excluded upstream by dce_sync_backend_supported --
# Mutagen has no podman transport; callers must fail fast first).
dce_sync_endpoint_for_backend() {
  local backend="$1"
  case "$backend" in
    docker|orbstack|colima)
      printf 'docker'
      ;;
    *)
      printf ''
      ;;
  esac
}

# Echo the Mutagen beta endpoint URL for a project's synced workspace, reached
# through the active backend's transport and the project container (which mounts
# the dce-sync volume at /workspace). Volume-scoped in effect: the volume is
# what is preserved across rebuild, and the session reconciles back into it
# after the recreated container re-mounts it. Must run after backend_use().
dce_sync_beta_url() {
  local project="$1"
  local backend=""
  backend="$(backend_name)" || return 1
  local transport=""
  transport="$(dce_sync_endpoint_for_backend "$backend")"
  [[ -n "$transport" ]] || return 1
  # <transport>://<container>//<absolute-path> is Mutagen's absolute-path form.
  printf '%s://%s//workspace\n' "$transport" "$project"
}

# Return 0 if a Mutagen session for PROJECT exists. Uses `mutagen sync list
# <name>` which filters to the named session (0 when present). Best-effort: an
# unreachable mutagen daemon reports absent rather than failing the caller.
dce_sync_session_exists() {
  local project="$1"
  local session=""
  session="$(dce_sync_session_name "$project")"
  mutagen sync list "$session" >/dev/null 2>&1
}

# Create the two-way, host-canonical Mutagen sync session for a project.
#
# Args: <project> <alpha-host-path> [ignore-path ...]
# The host (alpha) wins conflicts; ownership is coerced to the container's dev
# user so the synced tree matches the dev-owned workspace the base image expects.
# Ignored paths become Mutagen --ignore rules (they stay on ext4, off the host).
# Returns non-zero if mutagen fails; the caller decides whether to abort.
dce_sync_create() {
  local project="$1"
  local alpha="$2"
  shift 2
  local -a ignore_paths=("$@")

  if ! dce_mutagen_present; then
    return 1
  fi

  local session=""
  session="$(dce_sync_session_name "$project")"
  local beta=""
  beta="$(dce_sync_beta_url "$project")" || return 1

  local -a args=(sync create "$alpha" "$beta")
  args+=(--name "$session")
  # Two-way with host (alpha) as the canonical conflict winner. The existing
  # read-write bind mount already lets container processes mutate the host tree;
  # this preserves that property under sync instead of silently dropping edits.
  # Mutagen 0.18+ renamed --sync-mode to --mode and removed --conflict-resolution:
  # two-way-resolved auto-resolves conflicts in favor of alpha by definition, so
  # host-canonical behavior needs no separate flag.
  args+=(--mode two-way-resolved)
  # Coerce ownership/mode to the dev-owned workspace the base image expects;
  # Mutagen's default ownership preservation would write host UIDs and break it.
  # Scoped to BETA (the container volume) only: alpha is the host, where the
  # "dev" user does not exist, so --default-owner (both endpoints) would fail to
  # resolve "dev" on the host ("unknown user dev"). The container agent resolves
  # it correctly. 0.18 renamed --owner/--group to --default-owner/--default-group
  # and removed --no-symlink-ownership (symlink behavior is now --symlink-mode;
  # the default is correct for the dev-owned tree).
  args+=(--default-file-mode-beta 0644)
  args+=(--default-directory-mode-beta 0755)
  args+=(--default-owner-beta dev)
  args+=(--default-group-beta dev)
  # .git syncs by default (decision: default-on); ignored paths opt out via
  # --sync-ignore, never via --ignore-vcs.
  local ip=""
  for ip in "${ignore_paths[@]:-}"; do
    [[ -z "$ip" ]] && continue
    args+=(--ignore "$ip")
  done

  mutagen "${args[@]}"
}

# Flush pending changes for a project's session before a destructive operation.
# Bounded by DC_SYNC_FLUSH_TIMEOUT so a wedged session never hangs a rebuild;
# best-effort: a flush failure is reported but does not abort (the host remains
# canonical, so the worst case is a re-reconcile after recreate).
dce_sync_flush() {
  local project="$1"
  if ! dce_mutagen_present; then
    return 0
  fi
  if ! dce_sync_session_exists "$project"; then
    return 0
  fi
  local session=""
  session="$(dce_sync_session_name "$project")"
  if ! dce_run_with_timeout "${DC_SYNC_FLUSH_TIMEOUT}" mutagen sync flush "$session" 2>/dev/null; then
    dce_warn "mutagen sync flush timed out or failed for '$session'; host remains canonical."
    return 0
  fi
  return 0
}

# Resume (or no-op) a project's session. Mutagen auto-resumes, but an explicit
# ensure covers a host reboot between stop/start. Idempotent and soft-failing:
# a missing session is recreated on the next create/rebuild path, not here.
dce_sync_resume() {
  local project="$1"
  if ! dce_mutagen_present; then
    return 0
  fi
  if ! dce_sync_session_exists "$project"; then
    return 0
  fi
  local session=""
  session="$(dce_sync_session_name "$project")"
  mutagen sync resume "$session" >/dev/null 2>&1 || true
}

# Terminate a project's Mutagen session. Called by `dce rm` BEFORE the volume is
# removed, so Mutagen releases the volume (otherwise removal fails or orphans
# the session). Soft-failing: a session that is already gone is not an error.
dce_sync_terminate() {
  local project="$1"
  if ! dce_mutagen_present; then
    return 0
  fi
  local session=""
  session="$(dce_sync_session_name "$project")"
  mutagen sync terminate "$session" >/dev/null 2>&1 || true
}

# Echo a one-word health state for a project's session, for `dce doctor`:
#   healthy  session present and syncing
#   paused   session present but halted (e.g. on conflict)
#   absent   no session for this project
#   error    mutagen absent or its list call failed
dce_sync_health() {
  local project="$1"

  if ! dce_mutagen_present; then
    printf 'error'
    return 0
  fi

  local session=""
  session="$(dce_sync_session_name "$project")"
  local out=""
  if ! out="$(mutagen sync list "$session" 2>/dev/null)"; then
    printf 'absent'
    return 0
  fi
  if [[ -z "$out" ]]; then
    printf 'absent'
    return 0
  fi

  # Mutagen halts the whole session on the first conflict and stops syncing
  # everything until resolved. Surface that prominently (silent symptom).
  if printf '%s' "$out" | grep -Eqi 'conflict|halted|paused'; then
    printf 'paused'
    return 0
  fi

  printf 'healthy'
}
