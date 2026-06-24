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
#   - Destructive: requires typing 'yes' to confirm.
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--keep-hidden-volumes]"
  exit 1
fi

PROJECT=""
ROTATE_KEYS=false
KEEP_HIDDEN_VOLUMES=false

for arg in "$@"; do
  case "$arg" in
    --rotate-keys)
      ROTATE_KEYS=true
      ;;
    --keep-hidden-volumes)
      KEEP_HIDDEN_VOLUMES=true
      ;;
    --*)
      echo "ERROR: Unknown option: $arg"
      echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--keep-hidden-volumes]"
      exit 1
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$arg"
      else
        echo "ERROR: Unexpected argument: $arg"
        echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--keep-hidden-volumes]"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Project name is required."
  echo "Usage: rebuild-container.sh <project-name> [--rotate-keys] [--keep-hidden-volumes]"
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

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'."
  exit 1
fi

dce_load_project_config "$CONFIG"

if [[ -z "${CONTAINER_PROJECT:-}" ]]; then
  CONTAINER_PROJECT="$PROJECT"
fi

# Normalize persisted scopes/hidden paths, then re-derive the image from current
# overlay state. We never build here - the required image must already exist.
OVERLAY_SCOPES_CSV="${CONTAINER_OVERLAY_SCOPES:-}"

if ! declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1; then
  CONTAINER_HIDDEN_PATHS=()
fi

HIDDEN_PATHS_CSV="$(dce_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]:-}")" || exit 1
CONTAINER_HIDDEN_PATHS=()
if [[ -n "$HIDDEN_PATHS_CSV" ]]; then
  IFS=',' read -r -a CONTAINER_HIDDEN_PATHS <<< "$HIDDEN_PATHS_CSV"
fi

dce_load_global_config
NORMALIZED_SCOPES="$(dce_normalize_scopes_csv "$OVERLAY_SCOPES_CSV")" || exit 1
if [[ "$NORMALIZED_SCOPES" != "$OVERLAY_SCOPES_CSV" ]]; then
  OVERLAY_SCOPES_CSV="$NORMALIZED_SCOPES"
  dce_set_config_key "$CONFIG" "CONTAINER_OVERLAY_SCOPES" "$OVERLAY_SCOPES_CSV"
fi

DERIVED_IMAGE="$(dce_image_ref_from_scopes "$(dce_team_overlays_dir)" "$(dce_user_overlays_dir)" "$OVERLAY_SCOPES_CSV")" || exit 1

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
DOCKER_COMPATIBLE=false
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  DOCKER_COMPATIBLE=true
fi

if ! backend_image_exists "$DERIVED_IMAGE"; then
  echo "ERROR: Required image '$DERIVED_IMAGE' is not present on backend '$ACTIVE_BACKEND'."
  echo "Run: dce rebuild-image all"
  exit 1
fi

if [[ "${CONTAINER_IMAGE:-}" != "$DERIVED_IMAGE" ]]; then
  CONTAINER_IMAGE="$DERIVED_IMAGE"
  dce_set_config_key "$CONFIG" "CONTAINER_IMAGE" "$CONTAINER_IMAGE"
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
echo "======================================================================"
echo ""
echo "  Container:  ${CONTAINER_PROJECT}"
echo "  Image:      ${CONTAINER_IMAGE:-unknown}"
echo "  Overlay scope(s): ${OVERLAY_SCOPES_CSV:-(none)}"
echo "  Backend:    $ACTIVE_BACKEND"
echo "  Repos:      ${REPOS_DIR:-unknown} (PRESERVED - verify your commits separately)"
if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "  Hidden paths: ${CONTAINER_HIDDEN_PATHS[*]}"
  if $KEEP_HIDDEN_VOLUMES; then
    echo "  Hidden volumes: PRESERVED (--keep-hidden-volumes)"
  else
    echo "  Hidden volumes: REMOVED (clean rebuild)"
  fi
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

echo "This will DESTROY the container '$PROJECT' and recreate it."
echo "Your code in ${REPOS_DIR:-unknown} is safe."
echo ""
read -r -p "Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 0
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

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
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
  echo "  New SSH public key - add to GitHub and remove the old one:"
  echo "  https://github.com/ORG/REPO/settings/keys"
  echo ""
  cat "${SSH_KEY_PATH}.pub"
  echo ""
  read -r -p "  !! Pause here, update GitHub, then press Enter to continue..." pause_input
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
  hidden_volume="$(dce_hidden_volume_name "$PROJECT" "$hidden_path")"
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

backend_exec "$PROJECT" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
backend_exec_stdin "$PROJECT" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY_PATH"
# GitHub host keys are pinned in the base image; no runtime ssh-keyscan.
echo "  ✓ SSH key injected"

backend_exec "$PROJECT" git config --global url."git@github.com:".insteadOf "https://github.com/"
echo "  ✓ git configured (SSH insteadOf)"

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

echo ""
echo "======================================================================"
echo "Rebuild complete: $PROJECT"
echo "======================================================================"
echo ""
echo "  Container recreated from $CONTAINER_IMAGE"
echo "  Overlay scope(s): ${OVERLAY_SCOPES_CSV:-(none)}"
if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  if $KEEP_HIDDEN_VOLUMES; then
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
echo ""
echo "Next steps:"
echo "  [ ] dce install $PROJECT <path-to-dotfiles>   # reapply personal config"
echo "  [ ] dce shell $PROJECT                        # re-enter container"
echo ""
echo "Good habits after any rebuild:"
echo "  [ ] Quick sanity check: git log and git diff in $REPOS_DIR look right"
echo "  [ ] Rotate your GitHub PAT if it's due: $TOKEN_FILE"
echo "  [ ] Keep dotfiles current so customizations survive the next rebuild"
