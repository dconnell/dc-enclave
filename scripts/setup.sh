#!/usr/bin/env zsh
# =============================================================================
# setup.sh — One-time host setup for dev-containers
# Run once after cloning this repo.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "✗ ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
POSTGRES_CLIENT_MAJOR="${POSTGRES_CLIENT_MAJOR:-16}"

echo "╔══════════════════════════════════════╗"
echo "║   dev-containers: host setup         ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Selected backend: $ACTIVE_BACKEND"
echo "CLI version: $(backend_version)"
echo "PostgreSQL client major: $POSTGRES_CLIENT_MAJOR"

# ── 1. Initialize/check backend runtime ──────────────────────────────────────
echo ""
if [[ "$ACTIVE_BACKEND" == "apple" ]]; then
  echo "==> Starting apple/container system daemon..."
  backend_system_start 2>/dev/null && echo "✓ Daemon started" || echo "  (already running or not needed)"
else
  echo "==> Checking Docker-compatible runtime availability..."
  if backend_system_start 2>/dev/null; then
    echo "✓ Docker engine is reachable"
  else
    echo "✗ ERROR: Docker engine is not reachable."
    echo "  Start Docker Desktop or OrbStack and rerun setup."
    exit 1
  fi
fi

# ── 2. Create host directory structure ───────────────────────────────────────
echo ""
echo "==> Creating host directories..."

DIRS=(
  "$HOME/repos"
  "$HOME/.config/dev-containers"
  "$ROOT_DIR/projects"
)

for dir in "${DIRS[@]}"; do
  mkdir -p "$dir"
  echo "  ✓ $dir"
done

# ── 3. Create global .gitignore for secrets ──────────────────────────────────
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

# ── 4. Build base images ─────────────────────────────────────────────────────
echo ""
echo "==> Building base container images (this takes a few minutes)..."
echo ""

BUILD_ARGS=(--build-arg "PG_CLIENT_MAJOR=$POSTGRES_CLIENT_MAJOR")

echo "--- Building dev-base ---"
backend_build_image \
  "dev-base:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.base" \
  "$ROOT_DIR" \
  "${BUILD_ARGS[@]}"

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

# ── 5. Optional VS Code Dev Containers extension check ──────────────────────
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

# ── 6. Add shell alias ──────────────────────────────────────────────────────
ZSHRC="$HOME/.zshrc"
if ! grep -q "dev-containers alias" "$ZSHRC" 2>/dev/null; then
  cat >> "$ZSHRC" <<EOF

# ── dev-containers alias ────────────────────────────────────────
alias dc='$ROOT_DIR/scripts/dc'
# ────────────────────────────────────────────────────────────────
EOF
  echo ""
  echo "✓ Added dc alias to $ZSHRC"
  echo "  Run: source ~/.zshrc"
fi

if ! grep -q 'dc-complete.zsh' "$ZSHRC" 2>/dev/null; then
  echo "" >> "$ZSHRC"
  echo "# dc tab-completion" >> "$ZSHRC"
  echo "source '$ROOT_DIR/scripts/dc-complete.zsh'" >> "$ZSHRC"
  echo "✓ Added dc completion to $ZSHRC"
fi

# Keep alias in sync for users who had the old multi-alias block.
if grep -q "dev-containers aliases" "$ZSHRC" 2>/dev/null && ! grep -q "alias dc=" "$ZSHRC" 2>/dev/null; then
  echo "alias dc='$ROOT_DIR/scripts/dc'" >> "$ZSHRC"
  echo ""
  echo "✓ Added dc alias to $ZSHRC"
  echo "  You can remove the old dcnew/dcstart/etc aliases from $ZSHRC"
  echo "  Run: source ~/.zshrc"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Setup complete!                                         ║"
echo "║                                                          ║"
echo "║  Backend: $ACTIVE_BACKEND                                        ║"
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  echo "║  VS Code is optional; non-VS Code shell workflows work.  ║"
else
  echo "║  VS Code integration uses terminal profile passthrough.  ║"
fi
echo "║                                                          ║"
echo "║  Next:                                                   ║"
echo "║   1. source ~/.zshrc                                     ║"
echo "║   2. dc new <name> nodejs [port:port]                      ║"
echo "║   3. dc new <name> golang [port:port]                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
