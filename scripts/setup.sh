#!/usr/bin/env bash
# =============================================================================
# setup.sh - One-time host setup for dev-containers
# =============================================================================
set -euo pipefail

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
source "$ROOT_DIR/lib/platform.sh"
source "$ROOT_DIR/lib/container-backend.sh"

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

echo "========================================"
echo "dev-containers: host setup"
echo "========================================"
echo ""
echo "Selected backend: $ACTIVE_BACKEND"
echo "CLI version: $(backend_version)"

# Initialize backend runtime when needed.
echo ""
case "$ACTIVE_BACKEND" in
  apple)
    echo "==> Starting apple/container system daemon..."
    backend_system_start 2>/dev/null && echo "✓ Daemon started" || echo "  (already running or not needed)"
    ;;
  colima)
    echo "==> Checking Colima runtime availability..."
    if backend_system_start; then
      echo "✓ Colima Docker runtime is reachable"
    else
      echo "✗ ERROR: Colima runtime is not reachable."
      echo "  Ensure Colima uses Docker runtime and Docker context points to Colima."
      echo "  Try: colima start --runtime docker && docker context use colima"
      exit 1
    fi
    ;;
  docker|orbstack)
    echo "==> Checking Docker-compatible runtime availability..."
    if backend_system_start 2>/dev/null; then
      echo "✓ Docker engine is reachable"
    else
      echo "✗ ERROR: Docker engine is not reachable."
      echo "  Start Docker Desktop or OrbStack and rerun setup."
      exit 1
    fi
    ;;
  podman)
    echo "==> Checking Podman runtime availability..."
    if backend_system_start 2>/dev/null; then
      echo "✓ Podman runtime is reachable"
    else
      echo "✗ ERROR: Podman runtime is not reachable."
      echo "  Start Podman (for macOS: podman machine start) and rerun setup."
      exit 1
    fi
    ;;
esac

REPOS_DIR_PROMPT="${DC_REPOS_DIR:-$HOME/repos}"
echo ""
echo "==> Repos directory"
echo "  Current: $REPOS_DIR_PROMPT"
read -r -p "  Enter base repos directory [$REPOS_DIR_PROMPT]: " repos_dir_input
if [[ -n "$repos_dir_input" ]]; then
  REPOS_DIR_PROMPT="$repos_dir_input"
fi

if [[ "$REPOS_DIR_PROMPT" == "~" || "$REPOS_DIR_PROMPT" == "~/"* ]]; then
  REPOS_DIR_PROMPT="$HOME${REPOS_DIR_PROMPT#\~}"
elif [[ "$REPOS_DIR_PROMPT" != /* ]]; then
  REPOS_DIR_PROMPT="$PWD/$REPOS_DIR_PROMPT"
fi

mkdir -p "$REPOS_DIR_PROMPT"
REPOS_DIR_PROMPT="$(cd -P "$REPOS_DIR_PROMPT" && pwd)"
echo "  ✓ $REPOS_DIR_PROMPT"

echo ""
echo "==> Creating host directories..."

DIRS=(
  "$HOME/.config/dev-containers"
)

for dir in "${DIRS[@]}"; do
  mkdir -p "$dir"
  echo "  ✓ $dir"
done

# Create global gitignore for secrets.
GLOBAL_GITIGNORE="$HOME/.gitignore_global"
if ! grep -q "dev-containers secrets" "$GLOBAL_GITIGNORE" 2>/dev/null; then
  cat >> "$GLOBAL_GITIGNORE" <<'EOF'

# dev-containers secrets (never commit these)
github-token
*.github-token
ssh_key
ssh_key.pub
.npmrc.local
EOF
  git config --global core.excludesfile "$GLOBAL_GITIGNORE" 2>/dev/null || true
  echo "✓ Updated global .gitignore at $GLOBAL_GITIGNORE"
fi

# Build base images.
echo ""
echo "==> Building base container images (this takes a few minutes)..."
echo ""

echo "--- Building dev-base ---"
backend_build_image \
  "dev-base:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.base" \
  "$ROOT_DIR"

echo ""
echo "--- Building dev-nodejs ---"
backend_build_image \
  "dev-nodejs:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.nodejs" \
  "$ROOT_DIR"

echo ""
echo "--- Building dev-golang ---"
backend_build_image \
  "dev-golang:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.golang" \
  "$ROOT_DIR"

# Optional VS Code extension check for Docker-compatible backends.
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  echo ""
  echo "==> Optional check: VS Code Dev Containers extension"
  if command -v code >/dev/null 2>&1; then
    if code --list-extensions 2>/dev/null | grep -qi '^ms-vscode-remote.remote-containers$'; then
      echo "✓ VS Code Dev Containers extension is installed"
    else
      echo "! VS Code Dev Containers extension not detected"
      echo "  Install extension ID: ms-vscode-remote.remote-containers"
      echo "  Non-VS Code workflows are unaffected."
    fi
  else
    echo "  (VS Code CLI not found; skipping extension check)"
    echo "  Non-VS Code workflows are unaffected."
  fi
fi

# Add alias + completion to the right bash profile.
PROFILE_FILE="$(platform_bash_profile)"
touch "$PROFILE_FILE"

ALIAS_LINE="alias dc='$ROOT_DIR/scripts/dc'"
if ! grep -Fq "$ALIAS_LINE" "$PROFILE_FILE"; then
  {
    echo ""
    echo "# dev-containers alias"
    echo "$ALIAS_LINE"
  } >> "$PROFILE_FILE"
  echo ""
  echo "✓ Added dc alias to $PROFILE_FILE"
fi

COMPLETION_LINE="source '$ROOT_DIR/scripts/dc-complete.bash'"
if ! grep -Fq "$COMPLETION_LINE" "$PROFILE_FILE"; then
  {
    echo ""
    echo "# dev-containers completion"
    echo "$COMPLETION_LINE"
  } >> "$PROFILE_FILE"
  echo "✓ Added dc completion to $PROFILE_FILE"
fi

REPOS_DIR_EXPORT_LINE="export DC_REPOS_DIR=\"$REPOS_DIR_PROMPT\""
if grep -Eq "^(export[[:space:]]+)?DC_REPOS_DIR=" "$PROFILE_FILE" 2>/dev/null; then
  tmp_profile="$(mktemp)"
  awk -v line="$REPOS_DIR_EXPORT_LINE" '
    /^(export[[:space:]]+)?DC_REPOS_DIR=/ {
      if (!updated) {
        print line
        updated=1
      }
      next
    }
    { print }
  ' "$PROFILE_FILE" > "$tmp_profile"
  cat "$tmp_profile" > "$PROFILE_FILE"
  rm -f "$tmp_profile"
  echo "✓ Updated DC_REPOS_DIR in $PROFILE_FILE"
else
  {
    echo ""
    echo "# dev-containers repos directory"
    echo "$REPOS_DIR_EXPORT_LINE"
  } >> "$PROFILE_FILE"
  echo "✓ Added DC_REPOS_DIR to $PROFILE_FILE"
fi

echo ""
echo "======================================================================"
echo "Setup complete."
echo "======================================================================"
echo "Backend: $ACTIVE_BACKEND"
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  echo "VS Code is optional; non-VS Code shell workflows work."
else
  echo "VS Code integration uses terminal profile passthrough."
fi
echo ""
echo "Next:"
echo "  1. source $PROFILE_FILE"
echo "  2. dc new <name> nodejs [port:port]"
echo "  3. dc new <name> golang [port:port]"
