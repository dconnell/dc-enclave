#!/usr/bin/env zsh
# =============================================================================
# rebuild.sh — Destroy a container and recreate it from the known-good image
#
# Use this when:
#   - You suspect a malicious package has compromised the container
#   - You want a clean slate after an incident
#   - Routine "nuke and pave" hygiene
#
# What this DOES:
#   ✓ Destroys the compromised container (container filesystem gone)
#   ✓ Recreates container from the base image (clean state)
#   ✓ Re-injects SSH key and git config
#   ✓ Re-mounts your code (~/repos/<project> is untouched)
#
# What this does NOT do:
#   ✗ Clean your repos — do that manually after verifying commits
#   ✗ Rotate your GitHub token or SSH key — consider doing that too
#   ✗ Rebuild images — run rebuild-image.sh (or setup.sh) if image layers changed
#
# Usage:
#   rebuild.sh <project-name>
#   rebuild.sh <project-name> --rotate-keys   # also generate new SSH key
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: rebuild.sh <project-name> [--rotate-keys]}"
ROTATE_KEYS=false
[[ "${2:-}" == "--rotate-keys" ]] && ROTATE_KEYS=true

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG="$ROOT_DIR/projects/$PROJECT/config"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'."
  exit 1
fi

source "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
HAS_NODEJS=false
if [[ ",${CONTAINER_TYPE}," == *",nodejs,"* ]]; then
  HAS_NODEJS=true
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  REBUILDING CONTAINER: $PROJECT"
$ROTATE_KEYS && echo "║  Mode: ROTATE KEYS (new SSH deploy key will be generated)"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Container:  $CONTAINER_PROJECT"
echo "  Image:      $CONTAINER_IMAGE"
echo "  Backend:    $ACTIVE_BACKEND"
echo "  Repos:      $REPOS_DIR (PRESERVED — verify your commits separately)"
echo ""

# ── Safety pause ──────────────────────────────────────────────────────────────
echo "This will DESTROY the container '$PROJECT' and recreate it."
echo "Your code in $REPOS_DIR is safe."
echo ""
read -r "confirm?Type 'yes' to continue: "
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# ── 1. Stop the container if running ─────────────────────────────────────────
echo ""
echo "==> Step 1: Stopping container..."
if backend_is_running "$PROJECT"; then
  backend_stop "$PROJECT"
  echo "  ✓ Stopped"
else
  echo "  ✓ Already stopped"
fi

# ── 2. Destroy the container ──────────────────────────────────────────────────
echo ""
echo "==> Step 2: Deleting container (container filesystem wiped)..."
backend_delete "$PROJECT" 2>/dev/null && echo "  ✓ Container deleted" || echo "  (already gone)"

# ── 3. Optionally rotate SSH key ──────────────────────────────────────────────
if $ROTATE_KEYS; then
  echo ""
  echo "==> Step 3: Rotating SSH deploy key..."
  OLD_KEY_BACKUP="$SSH_KEY_PATH.bak.$(date +%Y%m%d%H%M%S)"
  mv "$SSH_KEY_PATH" "$OLD_KEY_BACKUP" 2>/dev/null && echo "  Backed up old key: $OLD_KEY_BACKUP"
  mv "${SSH_KEY_PATH}.pub" "${OLD_KEY_BACKUP}.pub" 2>/dev/null || true

  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -C "dev-container-${PROJECT}-rotated-$(date +%Y%m%d)" -N "" -q
  chmod 600 "$SSH_KEY_PATH"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────────┐"
  echo "  │ NEW SSH PUBLIC KEY — Add to GitHub and REMOVE the old one:      │"
  echo "  │ https://github.com/ORG/REPO/settings/keys                       │"
  echo "  └─────────────────────────────────────────────────────────────────┘"
  echo ""
  cat "${SSH_KEY_PATH}.pub"
  echo ""
  echo "  !! Pause here, update GitHub, then press Enter to continue..."
  read -r _
else
  echo ""
  echo "==> Step 3: Keeping existing SSH key (use --rotate-keys to regenerate)"
fi

# ── 4. Recreate container ─────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Recreating container from $CONTAINER_IMAGE..."

VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
if $HAS_NODEJS; then
  VOLUME_ARGS+=(--volume "$NPMRC_PATH:/home/dev/.npmrc:ro")
fi

PORT_ARGS=()
for p in "${PORTS[@]:-}"; do
  [[ -n "$p" ]] && PORT_ARGS+=(--publish "$p")
done

backend_create "$PROJECT" "$CONTAINER_IMAGE" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}"

echo "  ✓ Container created"

# ── 5. Start and re-inject credentials ────────────────────────────────────────
echo ""
echo "==> Step 5: Starting container and injecting credentials..."
backend_start "$PROJECT"
sleep 2

# Inject SSH key
backend_exec "$PROJECT" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
backend_exec_stdin "$PROJECT" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY_PATH"
backend_exec "$PROJECT" zsh -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null && chmod 644 ~/.ssh/known_hosts"
echo "  ✓ SSH key injected"

# Configure git (shared settings only — personal config comes from dotfiles)
backend_exec "$PROJECT" git config --global url."git@github.com:".insteadOf "https://github.com/"
echo "  ✓ git configured (SSH insteadOf)"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Rebuild complete: $PROJECT"
echo "║"
echo "║  Remaining manual steps (outside this script):"
echo "║  [ ] Review git log in $REPOS_DIR for unexpected commits"
echo "║  [ ] Check 'git diff HEAD~5' for unexpected file changes"
echo "║  [ ] Consider rotating your GitHub PAT: $TOKEN_FILE"
$ROTATE_KEYS && echo "║  [ ] Confirm new SSH key is on GitHub and old key is removed"
echo "║  [ ] Personal config (git identity, editor, shell) → dotfiles"
echo "║"
echo "║  Re-enter container:  scripts/shell.sh $PROJECT"
echo "╚══════════════════════════════════════════════════════════════════╝"
