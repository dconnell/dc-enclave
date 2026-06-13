#!/usr/bin/env bash
# =============================================================================
# rebuild.sh - Destroy a container and recreate it from the known-good image
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: rebuild.sh <project-name> [--rotate-keys]"
  exit 1
fi

PROJECT="$1"
ROTATE_KEYS=false
if [[ $# -eq 2 ]]; then
  if [[ "$2" == "--rotate-keys" ]]; then
    ROTATE_KEYS=true
  else
    echo "Usage: rebuild.sh <project-name> [--rotate-keys]"
    exit 1
  fi
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

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/container-backend.sh"

CONFIG="$HOME/.config/dev-containers/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'."
  exit 1
fi

source "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"

RUNTIME_TYPES_CSV="${CONTAINER_RUNTIME_TYPES:-${CONTAINER_TYPE:-}}"
if [[ -z "$RUNTIME_TYPES_CSV" ]]; then
  echo "ERROR: Missing runtime type configuration in $CONFIG"
  exit 1
fi

IMAGE_MODE="${CONTAINER_IMAGE_MODE:-shared}"
COMPOSED_CONTAINERFILE="${CONTAINER_COMPOSED_CONTAINERFILE:-}"
OVERLAY_FILES=()
if declare -p CONTAINER_OVERLAY_FILES >/dev/null 2>&1; then
  OVERLAY_FILES=("${CONTAINER_OVERLAY_FILES[@]}")
fi

HAS_NODEJS=false
if [[ ",$RUNTIME_TYPES_CSV," == *",nodejs,"* ]]; then
  HAS_NODEJS=true
fi

echo "======================================================================"
echo "Rebuilding container: $PROJECT"
if $ROTATE_KEYS; then
  echo "Mode: rotate keys (new SSH deploy key will be generated)"
fi
echo "======================================================================"
echo ""
echo "  Container:  ${CONTAINER_PROJECT:-$PROJECT}"
echo "  Image:      ${CONTAINER_IMAGE:-unknown}"
echo "  Image mode: $IMAGE_MODE"
echo "  Runtime(s): $RUNTIME_TYPES_CSV"
echo "  Backend:    $ACTIVE_BACKEND"
echo "  Repos:      ${REPOS_DIR:-unknown} (PRESERVED - verify your commits separately)"
if [[ -n "${CONTAINER_CPUS:-}" || -n "${CONTAINER_MEMORY:-}" ]]; then
  echo "  Resources:  ${CONTAINER_CPUS:-(default)} CPU, ${CONTAINER_MEMORY:-(default)} memory"
fi
echo ""

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

  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -C "dev-container-${PROJECT}-rotated-$(date +%Y%m%d)" -N "" -q
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

CREATE_STEP=4
START_STEP=5

if [[ "$IMAGE_MODE" == "project" ]]; then
  CREATE_STEP=5
  START_STEP=6

  if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
    echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
    exit 1
  fi

  if [[ -z "$COMPOSED_CONTAINERFILE" ]]; then
    COMPOSED_CONTAINERFILE="$ROOT_DIR/Containerfiles/generated/Containerfile.${PROJECT}"
  fi

  echo ""
  echo "==> Step 4: Rebuilding project-scoped image from runtime + overlays..."
  bash "$COMPOSE_SCRIPT" "$COMPOSED_CONTAINERFILE" "$RUNTIME_TYPES_CSV" "${OVERLAY_FILES[@]}"
  backend_build_image "$CONTAINER_IMAGE" "$COMPOSED_CONTAINERFILE" "$ROOT_DIR"
  echo "  ✓ Project image rebuilt: $CONTAINER_IMAGE"
fi

echo ""
echo "==> Step $CREATE_STEP: Recreating container from $CONTAINER_IMAGE..."

VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
if $HAS_NODEJS && [[ -n "${NPMRC_PATH:-}" ]]; then
  VOLUME_ARGS+=(--volume "$NPMRC_PATH:/home/dev/.npmrc:ro")
fi

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

backend_create "$PROJECT" "$CONTAINER_IMAGE" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}" "${RESOURCE_ARGS[@]}"
echo "  ✓ Container created"

echo ""
echo "==> Step $START_STEP: Starting container and injecting credentials..."
backend_start "$PROJECT"
sleep 2

backend_exec "$PROJECT" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
backend_exec_stdin "$PROJECT" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY_PATH"
backend_exec "$PROJECT" zsh -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null && chmod 644 ~/.ssh/known_hosts"
echo "  ✓ SSH key injected"

backend_exec "$PROJECT" git config --global url."git@github.com:".insteadOf "https://github.com/"
echo "  ✓ git configured (SSH insteadOf)"

echo ""
echo "======================================================================"
echo "Rebuild complete: $PROJECT"
echo "======================================================================"
echo ""
echo "  Container recreated from $CONTAINER_IMAGE ($IMAGE_MODE mode)"
echo "  Runtime(s): $RUNTIME_TYPES_CSV"
if [[ "$IMAGE_MODE" == "project" ]]; then
  echo "  Project image was rebuilt with current overlay files."
elif [[ "$IMAGE_MODE" == "shared" ]]; then
  echo "  Note: shared image was not updated. To update it: dc rebuild-image <target>"
fi
echo ""
echo "Host repos ($REPOS_DIR) are untouched — container state was wiped."
if $ROTATE_KEYS; then
  echo "SSH deploy key rotated — confirm new key is on GitHub and old key is removed."
fi
echo ""
echo "Next steps:"
echo "  [ ] dc install $PROJECT <path-to-dotfiles>   # reapply personal config"
echo "  [ ] dc shell $PROJECT                        # re-enter container"
echo ""
echo "Good habits after any rebuild:"
echo "  [ ] Quick sanity check: git log and git diff in $REPOS_DIR look right"
echo "  [ ] Rotate your GitHub PAT if it's due: $TOKEN_FILE"
echo "  [ ] Keep dotfiles current so customizations survive the next rebuild"
