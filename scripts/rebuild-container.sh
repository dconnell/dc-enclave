#!/usr/bin/env bash
# =============================================================================
# scripts/rebuild-container.sh - `dce rebuild-container`: destroy and recreate a
# container from its selected image.
#
# Used for drift recovery and incident response. The host workspace (repos dir)
# is always preserved - only the container filesystem is wiped. It re-derives
# the image from current overlay state (it never builds images; run
# `dce rebuild-image all` first if the image is missing), then:
#   stop -> delete -> handle hidden volumes -> (optionally rotate SSH key) ->
#   recreate -> start -> re-inject credentials -> reseed VS Code config.
#
# Safety semantics:
#   - Hidden volumes are REMOVED by default for a clean slate; --keep-hidden-
#     volumes preserves them. Combining --rotate-keys with --keep-hidden-volumes
#     raises a loud warning (key rotation implies incident response).
#   - Destructive: requires typing 'yes' to confirm (unless --yes/-y).
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes|-y] [--from-snap <label>]"
  exit 1
fi

PROJECT=""
ROTATE_KEYS=false
INJECT_CREDS=false
KEEP_HIDDEN_VOLUMES=false
ASSUME_YES=false
FROM_SNAP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate-keys)
      ROTATE_KEYS=true
      shift
      ;;
    --inject-creds)
      INJECT_CREDS=true
      shift
      ;;
    --keep-hidden-volumes)
      KEEP_HIDDEN_VOLUMES=true
      shift
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --from-snap)
      [[ $# -ge 2 && "$2" != --* ]] || { echo "ERROR: --from-snap requires a <label> argument"; exit 1; }
      FROM_SNAP="$2"
      shift 2
      ;;
    --*)
      echo "ERROR: Unknown option: $1"
      echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes|-y] [--from-snap <label>]"
      exit 1
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        echo "ERROR: Unexpected argument: $1"
        echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes|-y] [--from-snap <label>]"
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Project name is required."
  echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes|-y] [--from-snap <label>]"
  exit 1
fi

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/network.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/vscode.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/devcontainer.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/extensions.sh"

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'."
  exit 1
fi

dce_load_project_config "$CONFIG"

if [[ -z "${CONTAINER_PROJECT:-}" ]]; then
  CONTAINER_PROJECT="$PROJECT"
fi

# Normalize persisted hidden paths (always). Scope normalization + image
# re-derivation are SKIPPED under --from-snap: the restore path recreates the
# container from a saved snapshot image instead of the scope-derived one, and it
# never rewrites CONTAINER_IMAGE (a snapshot is a one-off restore source, never
# the project's configured image). We never build images here.
OVERLAY_SCOPES_CSV="${CONTAINER_OVERLAY_SCOPES:-}"

if ! declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1; then
  CONTAINER_HIDDEN_PATHS=()
fi

HIDDEN_PATHS_CSV="$(dce_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]:-}")" || exit 1
CONTAINER_HIDDEN_PATHS=()
if [[ -n "$HIDDEN_PATHS_CSV" ]]; then
  IFS=',' read -r -a CONTAINER_HIDDEN_PATHS <<< "$HIDDEN_PATHS_CSV"
fi

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
DOCKER_COMPATIBLE=false
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  DOCKER_COMPATIBLE=true
fi

# Resolve the project's git host for provider-aware guidance copy.
RB_GIT_HOST="$(dce_project_git_host)"
RB_GIT_DISPLAY="$(dce_git_host_field "$RB_GIT_HOST" display_name)"
RB_GIT_DEPLOY_DOC="$(dce_git_host_field "$RB_GIT_HOST" deploy_url_doc)"

if [[ -n "$FROM_SNAP" ]]; then
  # --- restore path: image = the named snapshot ------------------------------
  if ! dce_validate_snapshot_label "$FROM_SNAP"; then
    echo "ERROR: Invalid snapshot label '$FROM_SNAP'." >&2
    echo "  Allowed pattern: ^[A-Za-z0-9_.-]+\$" >&2
    exit 1
  fi
  CONTAINER_IMAGE="$(dce_snapshot_ref "$PROJECT" "$FROM_SNAP")"
  if ! backend_image_exists "$CONTAINER_IMAGE"; then
    echo "ERROR: snapshot '$FROM_SNAP' is not present on backend '$ACTIVE_BACKEND'." >&2
    echo "         $CONTAINER_IMAGE" >&2
    echo "Run: dce snapshots list $PROJECT"
    exit 1
  fi
  # Under --from-snap, hidden volumes are ALWAYS isolated from the live
  # originals: each is mounted from a snapshot volume (populated if the snapshot
  # captured it, EMPTY otherwise), and the originals are left untouched. This
  # never fails fast over a missing volume and never reuses the live volume.
  # Deliberately do NOT call dce_load_global_config / dce_image_ref_from_scopes
  # and do NOT write CONTAINER_IMAGE back to config: a snapshot is a one-off
  # restore source, not the project's configured image.
else
  # --- normal path: re-derive the image from current overlay state -----------
  dce_load_global_config
  NORMALIZED_SCOPES="$(dce_normalize_scopes_csv "$OVERLAY_SCOPES_CSV")" || exit 1
  if [[ "$NORMALIZED_SCOPES" != "$OVERLAY_SCOPES_CSV" ]]; then
    OVERLAY_SCOPES_CSV="$NORMALIZED_SCOPES"
    dce_set_config_key "$CONFIG" "CONTAINER_OVERLAY_SCOPES" "$OVERLAY_SCOPES_CSV"
  fi

  DERIVED_IMAGE="$(dce_image_ref_from_scopes "$(dce_team_overlays_dir)" "$(dce_user_overlays_dir)" "$OVERLAY_SCOPES_CSV")" || exit 1

  if ! backend_image_exists "$DERIVED_IMAGE"; then
    echo "ERROR: Required image '$DERIVED_IMAGE' is not present on backend '$ACTIVE_BACKEND'."
    echo "Run: dce rebuild-image all"
    exit 1
  fi

  if [[ "${CONTAINER_IMAGE:-}" != "$DERIVED_IMAGE" ]]; then
    CONTAINER_IMAGE="$DERIVED_IMAGE"
    dce_set_config_key "$CONFIG" "CONTAINER_IMAGE" "$CONTAINER_IMAGE"
  fi
fi

# Re-validate the persisted network membership before destroying anything: a
# missing network (deleted out of band) or an apple limit violation must fail
# fast so the container is not destroyed into an un-reattachable state. The
# primary network is re-applied at create; extras are re-connected after.
NETWORK_ARGS=()
if ! declare -p CONTAINER_NETWORKS >/dev/null 2>&1; then
  CONTAINER_NETWORKS=()
fi
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  if ! dce_network_check_backend_limits "$ACTIVE_BACKEND" "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
  if ! dce_networks_ensure_exist "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
  mapfile -t NETWORK_ARGS < <(dce_networks_create_args "${CONTAINER_NETWORKS[@]}")
fi

# Detect the host timezone once so the rebuilt container mirrors the developer's
# local time, identical to `dce new` (keeps new/rebuild create-argv in parity).
HOST_TZ="$(dce_host_timezone)" || HOST_TZ=""
TZ_ARGS=()
if [[ -n "$HOST_TZ" ]]; then
  TZ_ARGS+=(--env "TZ=$HOST_TZ")
fi

echo "======================================================================"
echo "Rebuilding container: $PROJECT"
if $ROTATE_KEYS; then
  echo "Mode: rotate keys (new SSH deploy key will be generated)"
fi
if [[ -n "$FROM_SNAP" ]]; then
  echo "Mode: restore from snapshot '$FROM_SNAP'"
fi
echo "======================================================================"
echo ""
echo "  Container:  ${CONTAINER_PROJECT}"
echo "  Image:      ${CONTAINER_IMAGE:-unknown}"
if [[ -n "$FROM_SNAP" ]]; then
  echo "  Source:     snapshot '$FROM_SNAP' (CONTAINER_IMAGE is NOT rewritten)"
  echo "  Volumes:    snapshot volumes (populated where captured, empty otherwise;"
  echo "              originals left untouched)"
else
  echo "  Overlay scope(s): ${OVERLAY_SCOPES_CSV:-(none)}"
fi
echo "  Backend:    $ACTIVE_BACKEND"
echo "  Repos:      ${REPOS_DIR:-unknown} (PRESERVED - verify your commits separately)"
if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "  Hidden paths: ${CONTAINER_HIDDEN_PATHS[*]}"
  if [[ -n "$FROM_SNAP" ]]; then
    echo "  Hidden volumes: mounted from snapshot volumes (originals left untouched)"
  elif $KEEP_HIDDEN_VOLUMES; then
    echo "  Hidden volumes: PRESERVED (--keep-hidden-volumes)"
  else
    echo "  Hidden volumes: REMOVED (clean rebuild)"
  fi
fi
if [[ -n "$FROM_SNAP" ]] && $KEEP_HIDDEN_VOLUMES; then
  echo "  (note: --keep-hidden-volumes has no effect in --from-snap mode)"
fi
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  echo "  Networks: ${CONTAINER_NETWORKS[*]}"
fi
if [[ -n "${CONTAINER_CPUS:-}" || -n "${CONTAINER_MEMORY:-}" ]]; then
  echo "  Resources:  ${CONTAINER_CPUS:-(default)} CPU, ${CONTAINER_MEMORY:-(default)} memory"
fi
if [[ -n "$HOST_TZ" ]]; then
  echo "  Timezone:   $HOST_TZ (synced from host via --env TZ)"
else
  echo "  Timezone:   (host zone undetectable - container stays on image default)"
fi
echo ""

# Loud warning: key rotation signals incident response, where keeping hidden
# volumes (node_modules, caches) would let possibly-compromised code survive.
if $ROTATE_KEYS && $KEEP_HIDDEN_VOLUMES && [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "  ********************************************************************"
  echo "  *                                                                  *"
  echo "  *  WARNING: --rotate-keys implies incident response, but           *"
  echo "  *  --keep-hidden-volumes will preserve existing hidden volumes.    *"
  echo "  *  Compromised code in hidden volumes (e.g. node_modules,          *"
  echo "  *  build caches) will SURVIVE this rebuild.                        *"
  echo "  *                                                                  *"
  echo "  *  If this is a security recovery, remove --keep-hidden-volumes.   *"
  echo "  *                                                                  *"
  echo "  ********************************************************************"
  echo ""
fi

# Pre-destroy warning: undeclared editor extensions will be LOST (the container
# FS -- including ~/.vscode-server -- is wiped). Only running + docker-
# compatible + adopted projects are checked; the warning is advisory (does not
# block, even under --yes) and mirrors the rotate-keys notice style. Plans §8.
if $DOCKER_COMPATIBLE && backend_is_running "$PROJECT" 2>/dev/null; then
  # Resolve declared set in a subshell so a missing/broken global config (which
  # dce_load_global_config dce_die-exits on) is contained, not fatal to rebuild.
  # Emits the undeclared extensions (installed not in declared), one per line.
  # shellcheck disable=SC2086
  _rb_undeclared="$( {
    dce_load_global_config 2>/dev/null || exit 0
    dce_ext_manifests_exist vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" || exit 0
    _rb_d="$(dce_ext_resolve_set vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}")"
    _rb_i="$(dce_ext_list_installed vscode "$PROJECT" 2>/dev/null)" || exit 0
    printf '%s\n' "$_rb_i" | dce_ext_minus $_rb_d
  } 2>/dev/null )" || _rb_undeclared=""
  _rb_und_count="$(printf '%s\n' "$_rb_undeclared" | grep -c -v '^$' 2>/dev/null || printf '0')"
  if [[ "$_rb_und_count" -gt 0 ]]; then
    echo "  ********************************************************************"
    echo "  *                                                                  *"
    echo "  *  WARNING: $_rb_und_count installed editor extension(s) are       *"
    printf "  *  UNDECLARED and will be LOST in the rebuild:                     *\n"
    # shellcheck disable=SC2086
    for _u in $_rb_undeclared; do
      printf "  *    - %s\n" "$_u"
    done
    echo "  *                                                                  *"
    echo "  *  Capture them first to keep them across rebuilds:                *"
    echo "  *    dce extensions capture $PROJECT --scope <scope> --all         *"
    echo "  *                                                                  *"
    echo "  ********************************************************************"
    echo ""
  fi
fi

echo "This will DESTROY the container '$PROJECT' and recreate it."
echo "Your code in ${REPOS_DIR:-unknown} is safe."
if ! $ASSUME_YES; then
  echo ""
  read -r -p "Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
echo "==> Step 1: Stopping container..."
if backend_is_running "$PROJECT"; then
  backend_stop "$PROJECT"
  echo "  ✓ Stopped"
else
  echo "  ✓ Already stopped"
fi

echo ""
echo "==> Step 2: Deleting container (container filesystem wiped)..."
if backend_delete "$PROJECT" 2>/dev/null; then
  echo "  ✓ Container deleted"
else
  echo "  (already gone)"
fi

if [[ -n "$FROM_SNAP" ]]; then
  # Snapshot restore: hidden volumes are mounted from snapshot volumes at create
  # (populated or empty), so leave the live originals intact -- they are the
  # operator's pre-restore state to keep. Dispositions are reported after create.
  echo "  -> Snapshot restore: preserving original hidden volumes."
elif [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  if ! dce_rebuild_handle_hidden_volumes "$PROJECT" "$KEEP_HIDDEN_VOLUMES" "${CONTAINER_HIDDEN_PATHS[@]}"; then
    exit 1
  fi
fi

if $ROTATE_KEYS; then
  echo ""
  echo "==> Step 3: Rotating SSH deploy key..."
  OLD_KEY_BACKUP="${SSH_KEY_PATH}.bak.$(date +%Y%m%d%H%M%S)"

  if [[ -f "${SSH_KEY_PATH:-}" ]]; then
    mv "$SSH_KEY_PATH" "$OLD_KEY_BACKUP"
    echo "  Backed up old key: $OLD_KEY_BACKUP"
  fi
  if [[ -f "${SSH_KEY_PATH:-}.pub" ]]; then
    mv "${SSH_KEY_PATH}.pub" "${OLD_KEY_BACKUP}.pub"
  fi

  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -C "dce-container-${PROJECT}-rotated-$(date +%Y%m%d)" -N "" -q
  chmod 600 "$SSH_KEY_PATH"
  echo ""
  echo "  New SSH public key - add to ${RB_GIT_DISPLAY} and remove the old one:"
  echo "  https://${RB_GIT_DEPLOY_DOC}"
  echo ""
  cat "${SSH_KEY_PATH}.pub"
  echo ""
  read -r -p "  !! Pause here, update ${RB_GIT_DISPLAY}, then press Enter to continue..." pause_input
  : "$pause_input"
else
  echo ""
  echo "==> Step 3: Keeping existing SSH key (use --rotate-keys to regenerate)"
fi

echo ""
echo "==> Step 4: Recreating container from $CONTAINER_IMAGE..."

VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
if [[ -n "${NPMRC_PATH:-}" ]]; then
  VOLUME_ARGS+=(--volume "$NPMRC_PATH:/home/dev/.npmrc:ro")
fi
for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]:-}"; do
  [[ -z "$hidden_path" ]] && continue
  if [[ -n "$FROM_SNAP" ]]; then
    # Snapshot restore: mount the deterministic snapshot volume (populated if
    # captured; auto-created empty otherwise). Never the live original, never a
    # hard failure -- dispositions are reported after create.
    hidden_volume="$(dce_snapshot_volume_name "$PROJECT" "$FROM_SNAP" "$hidden_path")"
  else
    hidden_volume="$(dce_hidden_volume_name "$PROJECT" "$hidden_path")"
  fi
  VOLUME_ARGS+=(--volume "$hidden_volume:/workspace/$hidden_path")
done

PORT_ARGS=()
if declare -p PORTS >/dev/null 2>&1; then
  for p in "${PORTS[@]}"; do
    [[ -z "$p" ]] && continue

    if [[ "$p" =~ ^[0-9]+:[0-9]+$ ]]; then
      PORT_ARGS+=(--publish "$p")
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      PORT_ARGS+=(--publish "$p:$p")
    else
      echo "ERROR: Invalid port mapping '$p' in project config."
      echo "  Expected formats: host:container or single port"
      exit 1
    fi
  done
fi

RESOURCE_ARGS=()
if [[ -n "${CONTAINER_CPUS:-}" ]]; then
  RESOURCE_ARGS+=(--cpus "$CONTAINER_CPUS")
fi
if [[ -n "${CONTAINER_MEMORY:-}" ]]; then
  RESOURCE_ARGS+=(--memory "$CONTAINER_MEMORY")
fi

backend_create "$PROJECT" "$CONTAINER_IMAGE" "${TZ_ARGS[@]}" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}" "${RESOURCE_ARGS[@]}" "${NETWORK_ARGS[@]}"
echo "  ✓ Container created"

# Under a snapshot restore, report each hidden volume's disposition so the
# operator knows which are populated vs empty (excluded / copy failed / added
# after the snapshot). All come from snapshot volumes, never the live originals.
if [[ -n "$FROM_SNAP" ]] && [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "  -> Hidden volume dispositions:"
  for _hp in "${CONTAINER_HIDDEN_PATHS[@]}"; do
    [[ -z "$_hp" ]] && continue
    _state="$(dce_snapshot_volume_state "$PROJECT" "$FROM_SNAP" "$_hp")"
    case "$_state" in
      captured) echo "     ✓ populated: $_hp" ;;
      failed)   echo "     ! empty (copy failed): $_hp  -- reinstall deps here" ;;
      excluded) echo "     ~ empty (excluded from snapshot): $_hp" ;;
      *)        echo "     ~ empty (not in snapshot): $_hp" ;;
    esac
  done
fi

# Re-attach every network beyond the primary so the rebuilt container lands on
# the same private networks (with the same static IPs) as before.
if [[ ${#CONTAINER_NETWORKS[@]} -gt 1 ]]; then
  echo "  -> Re-attaching additional networks..."
  if ! dce_networks_attach_extras "$PROJECT" "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
fi

echo ""
echo "==> Step 5: Starting container and injecting credentials..."
backend_start "$PROJECT"
sleep 2

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "  -> Verifying hidden volume mounts..."
  if ! dce_ensure_hidden_mounts "$PROJECT" "${CONTAINER_HIDDEN_PATHS[@]}"; then
    exit 1
  fi
  echo "     ✓ Hidden volume mounts active"

  echo "  -> Normalizing hidden-path ownership..."
  for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
    target="/workspace/$hidden_path"
    backend_exec_as_root "$PROJECT" sh -lc "mkdir -p '$target' && chown -R dev:dev '$target'"
    if ! backend_exec "$PROJECT" sh -lc "test -w '$target'"; then
      echo "ERROR: Hidden path is not writable by dev: $target"
      exit 1
    fi
  done
fi

# Inject current credentials only when explicitly requested. A normal (non
# --from-snap) rebuild always injects (the container is freshly recreated, so
# there is nothing to preserve). A --from-snap restore injects ONLY when the
# operator opts in via --inject-creds (use the restored snapshot with current
# credentials) or --rotate-keys (incident response: regenerate the SSH key); a
# bare --from-snap leaves the snapshot's credential state untouched so a
# possibly-compromised snapshot can be inspected. When injecting, the token is
# force-written (overwrite if it differs), never only-if-missing -- the SSH key
# is always overwritten and dce_ensure_git_credentials is called with `force`.
if [[ -z "$FROM_SNAP" ]] || $INJECT_CREDS || $ROTATE_KEYS; then
  dce_inject_ssh_deploy_key "$PROJECT" force
  echo "  ✓ SSH key injected"
  dce_ensure_git_credentials "$PROJECT" force
  echo "  ✓ git configured (credential-aware insteadOf)"
else
  echo "  ✓ Credentials NOT injected — snapshot state preserved"
  echo "    To use this snapshot with current credentials, re-run with --inject-creds:"
  echo "    dce rebuild-container $PROJECT --from-snap $FROM_SNAP --inject-creds"
fi

if $DOCKER_COMPATIBLE; then
  echo ""
  echo "==> Step 6: Seeding VS Code named attach config..."
  ATTACH_CONFIG_COUNT=0
  while IFS= read -r attach_config_file; do
    [[ -z "$attach_config_file" ]] && continue
    ATTACH_CONFIG_COUNT=$((ATTACH_CONFIG_COUNT + 1))
    echo "  ✓ $attach_config_file"
  done < <(dce_vscode_seed_named_attach_config "$PROJECT" "/workspace")

  if [[ "$ATTACH_CONFIG_COUNT" -eq 0 ]]; then
    echo "  (No VS Code user storage found; config will be created after first VS Code attach.)"
  fi
fi

# Drift notice: the seeded .devcontainer/devcontainer.json is never rewritten by
# a rebuild, so a prior `dce config set` (scopes/hide/networks/ports) can leave
# VS Code desynced from the freshly-rebuilt container. Detection is read-only
# and non-fatal (safe under --yes); it just points at the diff + sync-vscode.
# Docker-compatible only (apple has no devcontainer.json).
if $DOCKER_COMPATIBLE && [[ -n "${REPOS_DIR:-}" ]]; then
  _rb_dc_file="$REPOS_DIR/.devcontainer/devcontainer.json"
  if [[ -f "$_rb_dc_file" ]]; then
    _rb_nets_csv=""
    if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
      _rb_nets_csv="$(dce_join_by ',' "${CONTAINER_NETWORKS[@]}")"
    fi
    _rb_ports_csv=""
    if declare -p PORTS >/dev/null 2>&1 && [[ ${#PORTS[@]} -gt 0 ]]; then
      _rb_ports_csv="$(dce_join_by ',' "${PORTS[@]}")"
    fi
    # Expected managed dockerfile. Normal path has global config loaded; under
    # --from-snap derive best-effort from the persisted scopes in a subshell so
    # a missing global config degrades to skipping the scopes field, not abort.
    _rb_build_df=""
    if [[ -z "$FROM_SNAP" ]]; then
      _rb_build_df="$(dce_devcontainer_build_file "$ROOT_DIR" "$OVERLAY_SCOPES_CSV")" || _rb_build_df=""
    else
      _rb_build_df="$( { dce_load_global_config 2>/dev/null && \
        dce_devcontainer_build_file "$ROOT_DIR" "${CONTAINER_OVERLAY_SCOPES:-}"; } 2>/dev/null )" || _rb_build_df=""
    fi
    # Editor-extensions declaration drift: resolve the adoption state so the
    # notice fires post-adoption and stays silent pre-adoption (migration guard).
    # Best-effort: a missing global config degrades to no extensions comparison.
    # Run in a subshell so dce_load_global_config's dce_die (on missing config)
    # is contained, not fatal to the rebuild. Emits "ADOPTED\n<csv>" post-adoption.
    _rb_ext_vals="$( {
      dce_load_global_config 2>/dev/null || exit 0
      dce_ext_manifests_exist vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" || exit 0
      printf 'ADOPTED\n'
      dce_ext_resolve_csv vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}"
    } 2>/dev/null )" || _rb_ext_vals=""
    _rb_ext_csv=""
    _rb_ext_adopted="false"
    case "$_rb_ext_vals" in
      ADOPTED*)
        _rb_ext_adopted="true"
        _rb_ext_csv="${_rb_ext_vals#ADOPTED}"
        _rb_ext_csv="${_rb_ext_csv#$'\n'}"
        ;;
    esac
    dce_devcontainer_detect_drift "$PROJECT" "$_rb_dc_file" "$_rb_build_df" \
      "$HIDDEN_PATHS_CSV" "$_rb_nets_csv" "$_rb_ports_csv" \
      "vscode" "$_rb_ext_csv" "$_rb_ext_adopted" >&2 || true
  fi
fi

echo ""
echo "======================================================================"
echo "Rebuild complete: $PROJECT"
echo "======================================================================"
echo ""
echo "  Container recreated from $CONTAINER_IMAGE"
if [[ -n "$FROM_SNAP" ]]; then
  echo "  Source:     snapshot '$FROM_SNAP'"
  echo "  (CONTAINER_IMAGE was NOT rewritten; the container will read 'stale')"
  echo "  (until the next normal rebuild -- this is correct, not an error.)"
else
  echo "  Overlay scope(s): ${OVERLAY_SCOPES_CSV:-(none)}"
fi
if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  if [[ -n "$FROM_SNAP" ]]; then
    echo "  Hidden volumes: mounted from snapshot volumes (originals untouched)"
  elif $KEEP_HIDDEN_VOLUMES; then
    echo "  Hidden volumes: preserved (--keep-hidden-volumes)"
  else
    echo "  Hidden volumes: removed (clean rebuild)"
  fi
fi
echo ""
echo "Host repos ($REPOS_DIR) are untouched — container state was wiped."
if $ROTATE_KEYS; then
  echo "SSH deploy key rotated — confirm new key is on GitHub and old key is removed."
fi

# Record a restore provenance event so the project log reflects that this image
# came from a snapshot (not a scope-derived build). Best-effort: never abort a
# successful rebuild on a provenance-write failure. Run in a subshell so a
# dce_die from a missing/broken global config cannot exit the rebuilt container's
# success path. Only relevant under --from-snap.
if [[ -n "$FROM_SNAP" ]]; then
  (
    dce_load_global_config
    dce_log_provenance "$PROJECT" "$CONTAINER_IMAGE" "restore" \
      "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" \
      "$(backend_image_id "$CONTAINER_IMAGE" 2>/dev/null || true)"
  ) 2>/dev/null || true
fi
echo ""
echo "Next steps:"
echo "  [ ] dce install $PROJECT <path-to-dotfiles>   # reapply personal config"
echo "  [ ] dce shell $PROJECT                        # re-enter container"
echo ""
echo "Good habits after any rebuild:"
echo "  [ ] Quick sanity check: git log and git diff in $REPOS_DIR look right"
echo "  [ ] Rotate your ${RB_GIT_DISPLAY} token if it's due: $TOKEN_FILE"
echo "  [ ] Keep dotfiles current so customizations survive the next rebuild"
