#!/usr/bin/env zsh
# =============================================================================
# new-container.sh — Create a new isolated development container
#
# Usage:
#   new-container.sh <project-name> <type[,type...]> [host-port:container-port ...]
#
# Types:
#   nodejs   — Node.js / npm / Vue frontend
#   golang   — Go backend
#
# Examples:
#   # Monorepo (full-stack in one container)
#   ./new-container.sh project1 nodejs 3000:3000 5173:5173
#   ./new-container.sh project1 nodejs,golang 3000:3000 5173:5173 8080:8080
#
#   # Multi-repo: separate containers per stack
#   ./new-container.sh myapp-frontend nodejs 3000:3000 5173:5173
#   ./new-container.sh myapp-backend  golang 8080:8080 9000:9000
#
# After running this script:
#   1. Edit ~/.config/dev-containers/<name>/github-token
#   2. Add the printed SSH public key to GitHub as a Deploy Key
#   3. Run: scripts/start.sh <name>
# =============================================================================
set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
PROJECT="${1:?Usage: new-container.sh <project-name> <type[,type...]> [port:port ...]}"
TYPE_INPUT="${2:?Specify type(s): nodejs, golang, or nodejs,golang}"
shift 2
PORTS=("$@")  # remaining args are port mappings

typeset -A TYPE_SELECTED
TYPE_ORDER=(nodejs golang)
RAW_TYPES=("${(@s:,:)TYPE_INPUT}")

for raw_type in "${RAW_TYPES[@]}"; do
  type="${raw_type//[[:space:]]/}"
  case "$type" in
    nodejs|golang)
      TYPE_SELECTED[$type]=1
      ;;
    "")
      ;;
    *)
      echo "ERROR: Unknown type '$type'. Use nodejs, golang, or nodejs,golang"
      exit 1
      ;;
  esac
done

TYPES=()
for t in "${TYPE_ORDER[@]}"; do
  if [[ -n "${TYPE_SELECTED[$t]-}" ]]; then
    TYPES+=("$t")
  fi
done

if [[ ${#TYPES[@]} -eq 0 ]]; then
  echo "ERROR: No valid type selected. Use nodejs, golang, or nodejs,golang"
  exit 1
fi

TYPE="${(j:,:)TYPES}"
TYPE_SLUG="${(j:-:)TYPES}"
HAS_NODEJS=false
if [[ -n "${TYPE_SELECTED[nodejs]-}" ]]; then
  HAS_NODEJS=true
fi

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
DOCKER_COMPATIBLE=false
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  DOCKER_COMPATIBLE=true
fi

SECRET_DIR="$HOME/.config/dev-containers/$PROJECT"
REPOS_DIR="$HOME/repos/$PROJECT"
PROJECT_CONFIG_DIR="$ROOT_DIR/projects/$PROJECT"
CONFIG_FILE="$PROJECT_CONFIG_DIR/config"
IMAGE="dev-${TYPE_SLUG}:latest"
COMBINED_CONTAINERFILES_DIR="$ROOT_DIR/Containerfiles/generated"
COMBINED_CONTAINERFILE="$COMBINED_CONTAINERFILES_DIR/Containerfile.${TYPE_SLUG}"
DEVCONTAINER_BUILD_FILE="$ROOT_DIR/Containerfiles/Containerfile.${TYPES[1]}"

if [[ ${#TYPES[@]} -gt 1 ]]; then
  mkdir -p "$COMBINED_CONTAINERFILES_DIR"

  {
    echo "FROM dev-base:latest"

    for t in "${TYPES[@]}"; do
      SOURCE_CONTAINERFILE="$ROOT_DIR/Containerfiles/Containerfile.$t"
      if [[ ! -f "$SOURCE_CONTAINERFILE" ]]; then
        echo "ERROR: Missing source Containerfile: $SOURCE_CONTAINERFILE" >&2
        exit 1
      fi

      echo ""
      echo "# --- begin Containerfile.$t ---"
      awk 'NR == 1 && $1 == "FROM" { next } $1 == "CMD" { next } { print }' "$SOURCE_CONTAINERFILE"
      echo "# --- end Containerfile.$t ---"
    done

    echo ""
    echo 'CMD ["sleep", "infinity"]'
  } > "$COMBINED_CONTAINERFILE"

  DEVCONTAINER_BUILD_FILE="$COMBINED_CONTAINERFILE"

  echo "==> Building combined runtime image for types: $TYPE"
  backend_build_image "$IMAGE" "$COMBINED_CONTAINERFILE" "$ROOT_DIR"
fi

# ── Guards ────────────────────────────────────────────────────────────────────
if backend_exists "$PROJECT"; then
  echo "ERROR: Container '$PROJECT' already exists."
  echo "  To rebuild: scripts/rebuild.sh $PROJECT"
  exit 1
fi

echo "╔══════════════════════════════════════════════════╗"
echo "║  Creating container: $PROJECT"
echo "║  Type: $TYPE | Image: $IMAGE | Backend: $ACTIVE_BACKEND"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Directories ────────────────────────────────────────────────────────────
mkdir -p "$SECRET_DIR" "$REPOS_DIR" "$PROJECT_CONFIG_DIR"
chmod 700 "$SECRET_DIR"
echo "✓ Directories created"
echo "  Repos mount: $REPOS_DIR"
echo "  Secrets:     $SECRET_DIR (chmod 700)"

# ── 2. SSH deploy key ─────────────────────────────────────────────────────────
SSH_KEY="$SECRET_DIR/ssh_key"
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -C "dev-container-${PROJECT}" -N "" -q
  chmod 600 "$SSH_KEY"
fi
echo ""
echo "✓ SSH deploy key: $SSH_KEY"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │ ADD THIS PUBLIC KEY TO GITHUB (Deploy Keys, write access):      │"
echo "  │ https://github.com/ORG/REPO/settings/keys                       │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
cat "${SSH_KEY}.pub"
echo ""

# ── 3. GitHub PAT placeholder ─────────────────────────────────────────────────
TOKEN_FILE="$SECRET_DIR/github-token"
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "# GitHub Personal Access Token for container: $PROJECT" > "$TOKEN_FILE"
  echo "# Scope: repo (or fine-grained: specific repos, contents read/write)" >> "$TOKEN_FILE"
  echo "# NO admin permissions, NO org-level access" >> "$TOKEN_FILE"
  echo "# Replace this line with your token:" >> "$TOKEN_FILE"
  echo "ghp_REPLACE_ME" >> "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
echo "✓ GitHub token placeholder: $TOKEN_FILE"
echo "  !! Edit this file and replace ghp_REPLACE_ME with your PAT"

# ── 4. .npmrc placeholder (nodejs-enabled containers) ───────────────────────
if $HAS_NODEJS; then
  NPMRC="$SECRET_DIR/.npmrc"
  if [[ ! -f "$NPMRC" ]]; then
    cat > "$NPMRC" <<'EOF'
# .npmrc for this container only
# Examples:
#   //registry.npmjs.org/:_authToken=YOUR_NPM_TOKEN
#   @myorg:registry=https://npm.pkg.github.com
#   //npm.pkg.github.com/:_authToken=YOUR_GITHUB_PAT
EOF
    chmod 600 "$NPMRC"
  fi
  echo "✓ .npmrc template: $NPMRC"
fi

# ── 5. Save project config (non-secret, can be committed) ────────────────────
cat > "$CONFIG_FILE" <<EOF
# dev-container config for: $PROJECT
# Generated: $(date)
CONTAINER_PROJECT="$PROJECT"
CONTAINER_TYPE="$TYPE"
CONTAINER_IMAGE="$IMAGE"
CONTAINER_BACKEND="$ACTIVE_BACKEND"
REPOS_DIR="$REPOS_DIR"
SECRET_DIR="$SECRET_DIR"
SSH_KEY_PATH="$SECRET_DIR/ssh_key"
TOKEN_FILE="$SECRET_DIR/github-token"
NPMRC_PATH="$SECRET_DIR/.npmrc"
PORTS=(${PORTS[@]+"${PORTS[@]}"})
EOF
echo "✓ Config saved: $CONFIG_FILE"

# ── 6. Build port and volume args ─────────────────────────────────────────────
VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
if $HAS_NODEJS; then
  VOLUME_ARGS+=(--volume "$SECRET_DIR/.npmrc:/home/dev/.npmrc:ro")
fi

PORT_ARGS=()
FORWARD_PORTS=()
for p in "${PORTS[@]}"; do
  [[ -z "$p" ]] && continue

  if [[ "$p" =~ '^[0-9]+:[0-9]+$' ]]; then
    host_port="${p%%:*}"
    container_port="${p##*:}"
    PORT_ARGS+=(--publish "$host_port:$container_port")
    FORWARD_PORTS+=("$container_port")
  elif [[ "$p" =~ '^[0-9]+$' ]]; then
    PORT_ARGS+=(--publish "$p:$p")
    FORWARD_PORTS+=("$p")
  else
    echo "ERROR: Invalid port mapping '$p'. Use host:container (e.g., 5173:5173)."
    exit 1
  fi
done

# ── 7. Create container ───────────────────────────────────────────────────────
echo ""
echo "==> Creating container from image: $IMAGE"
backend_create "$PROJECT" "$IMAGE" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}"

echo ""
echo "==> Starting container for initial SSH key injection..."
backend_start "$PROJECT"
sleep 2  # give the container a moment to initialize

# ── 8. Inject SSH key into container ─────────────────────────────────────────
echo "==> Injecting SSH deploy key..."
backend_exec "$PROJECT" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
backend_exec_stdin "$PROJECT" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY"
backend_exec "$PROJECT" zsh -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null && chmod 644 ~/.ssh/known_hosts"

# ── 9. Configure git ──────────────────────────────────────────────────────────
echo "==> Configuring git in container..."
backend_exec "$PROJECT" git config --global url."git@github.com:".insteadOf "https://github.com/"

# ── 10. Generate backend-specific VS Code integration ────────────────────────
if $DOCKER_COMPATIBLE; then
  echo "==> Generating Dev Containers config for Docker-compatible backend..."
  DEVCONTAINER_DIR="$REPOS_DIR/.devcontainer"
  DEVCONTAINER_FILE="$DEVCONTAINER_DIR/devcontainer.json"

  if [[ -f "$DEVCONTAINER_FILE" ]]; then
    echo "  ✓ $DEVCONTAINER_FILE already exists — not overwritten."
    echo "  Update it manually if you want to use this container recipe:"
    echo "    Containerfile: $DEVCONTAINER_BUILD_FILE"
  else
    mkdir -p "$DEVCONTAINER_DIR"

    FORWARD_PORTS_BLOCK=""
    if [[ ${#FORWARD_PORTS[@]} -gt 0 ]]; then
      FORWARD_PORTS_CSV=""
      for port in "${FORWARD_PORTS[@]}"; do
        if [[ -n "$FORWARD_PORTS_CSV" ]]; then
          FORWARD_PORTS_CSV+=", "
        fi
        FORWARD_PORTS_CSV+="$port"
      done
      FORWARD_PORTS_BLOCK=$',\n  "forwardPorts": ['"$FORWARD_PORTS_CSV"$']'
    fi

    MOUNTS_BLOCK=""
    MOUNTS_ENTRIES=()
    if $HAS_NODEJS; then
      MOUNTS_ENTRIES+=("source=$SECRET_DIR/.npmrc,target=/home/dev/.npmrc,type=bind,readonly")
    fi

    if [[ ${#MOUNTS_ENTRIES[@]} -gt 0 ]]; then
      MOUNTS_BLOCK=$',\n  "mounts": [\n'
      first_entry=true
      for entry in "${MOUNTS_ENTRIES[@]}"; do
        if ! $first_entry; then
          MOUNTS_BLOCK+=$',\n'
        fi
        MOUNTS_BLOCK+="    \"$entry\""
        first_entry=false
      done
      MOUNTS_BLOCK+=$'\n  ]'
    fi

    cat > "$DEVCONTAINER_FILE" <<EOF
{
  "name": "dev-$PROJECT",
  "build": {
    "dockerfile": "$DEVCONTAINER_BUILD_FILE",
    "context": "$ROOT_DIR"
  },
  "workspaceMount": "source=\${localWorkspaceFolder},target=/workspace,type=bind",
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "postCreateCommand": "true"$FORWARD_PORTS_BLOCK$MOUNTS_BLOCK
}
EOF

    echo "  ✓ Created $DEVCONTAINER_FILE"
    echo "  For a new Dev Container instance: Dev Containers: Reopen in Container"
    echo "  To use the same running '$PROJECT' container: Dev Containers: Attach to Running Container..."
  fi
else
  echo "==> Generating VS Code workspace settings for apple/container backend..."
  VSCODE_DIR="$REPOS_DIR/.vscode"
  VSCODE_SETTINGS="$VSCODE_DIR/settings.json"
  mkdir -p "$VSCODE_DIR"

  # Only write if it doesn't exist — don't clobber existing project settings
  if [[ ! -f "$VSCODE_SETTINGS" ]]; then
    cat > "$VSCODE_SETTINGS" <<EOF
{
  "terminal.integrated.defaultProfile.osx": "dev-container",
  "terminal.integrated.profiles.osx": {
    "dev-container": {
      "path": "/bin/zsh",
      "args": ["-c", "$ROOT_DIR/scripts/shell.sh $PROJECT"]
    }
  }
}
EOF
    echo "  ✓ Created $VSCODE_SETTINGS"
    echo "  All VS Code terminal tabs will open inside the container."
  else
    echo "  ✓ $VSCODE_SETTINGS already exists — not overwritten."
    echo "  Add this manually if needed:"
    echo '    "terminal.integrated.defaultProfile.osx": "dev-container"'
    echo '    "terminal.integrated.profiles.osx": { "dev-container": { "path": "/bin/zsh", "args": ["-c", "'"$ROOT_DIR/scripts/shell.sh $PROJECT"'"] } }'
  fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Container '$PROJECT' created and started!                       ║"
echo "║                                                                  ║"
echo "║  Checklist before use:                                           ║"
echo "║  [ ] Edit $TOKEN_FILE"
echo "║  [ ] Add SSH public key to GitHub Deploy Keys for your repos     ║"
echo "║  [ ] Clone your repos into: $REPOS_DIR                          ║"
echo "║  [ ] Set up dotfiles in VS Code settings for personal config     ║"
echo "║      (see README: Personal configuration / dotfiles)             ║"
if $DOCKER_COMPATIBLE; then
  echo "║  [ ] (Optional) Open ~/repos/$PROJECT in VS Code Dev Containers  ║"
else
  echo "║  [ ] Open ~/repos/$PROJECT in VS Code — terminals auto-connect  ║"
fi
echo "║                                                                  ║"
echo "║  Commands:                                                       ║"
echo "║    Shell:   scripts/shell.sh $PROJECT"
echo "║    Stop:    scripts/stop.sh $PROJECT"
echo "║    Status:  scripts/status.sh"
echo "╚══════════════════════════════════════════════════════════════════╝"
