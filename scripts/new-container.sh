#!/usr/bin/env zsh
# =============================================================================
# new-container.sh — Create a new isolated development container.
#
# Usage:
#   new-container.sh <project-name> <type[,type...]> [host-port:container-port ...]
#   new-container.sh <project-name> <type[,type...]> --overlay-containerfile <file> [ports...]
#
# Runtime types:
#   nodejs   — Node.js / npm / frontend runtime
#   golang   — Go backend runtime
#
# Overlay support:
#   In the type CSV, unknown tokens that resolve to existing files are treated
#   as overlay Containerfile fragments.
#
# Examples:
#   ./new-container.sh myapp nodejs 3000:3000
#   ./new-container.sh myapp nodejs,golang 3000:3000 8080:8080
#   ./new-container.sh myapp nodejs,golang,../../path/to/Containerfile.username
#   ./new-container.sh myapp nodejs --overlay-containerfile ../../path/to/Containerfile.username
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: new-container.sh <project-name> <type[,type...]> [port:port ...]}"
TYPE_INPUT="${2:?Specify type(s): nodejs, golang, or nodejs,golang[,overlay-path]}"
shift 2

PORTS=()
EXTRA_OVERLAYS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay-containerfile)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --overlay-containerfile requires a file path argument"
        exit 1
      fi
      EXTRA_OVERLAYS+=("$2")
      shift 2
      ;;
    *)
      PORTS+=("$1")
      shift
      ;;
  esac
done

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"
COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
  exit 1
fi

TYPE_ORDER=(nodejs golang)
typeset -A TYPE_SELECTED
RAW_TYPES=("${(@s:,:)TYPE_INPUT}")
OVERLAY_FILES=()

for raw_type in "${RAW_TYPES[@]}"; do
  normalized_type="${raw_type//[[:space:]]/}"

  case "$normalized_type" in
    nodejs|golang)
      TYPE_SELECTED[$normalized_type]=1
      ;;
    "")
      ;;
    *)
      overlay_candidate="${normalized_type:A}"
      if [[ -f "$overlay_candidate" ]]; then
        OVERLAY_FILES+=("$overlay_candidate")
      else
        echo "ERROR: Unknown type token '$normalized_type'."
        echo "  Supported runtime types: nodejs, golang"
        echo "  Or provide an existing overlay Containerfile path."
        exit 1
      fi
      ;;
  esac
done

for overlay_input in "${EXTRA_OVERLAYS[@]}"; do
  overlay_candidate="${overlay_input:A}"
  if [[ ! -f "$overlay_candidate" ]]; then
    echo "ERROR: Overlay Containerfile not found: $overlay_candidate"
    exit 1
  fi
  OVERLAY_FILES+=("$overlay_candidate")
done

typeset -A OVERLAY_SEEN
DEDUPED_OVERLAYS=()
for overlay_file in "${OVERLAY_FILES[@]}"; do
  if [[ -z "${OVERLAY_SEEN[$overlay_file]-}" ]]; then
    OVERLAY_SEEN[$overlay_file]=1
    DEDUPED_OVERLAYS+=("$overlay_file")
  fi
done
OVERLAY_FILES=("${DEDUPED_OVERLAYS[@]}")

RUNTIME_TYPES=()
for runtime_type in "${TYPE_ORDER[@]}"; do
  if [[ -n "${TYPE_SELECTED[$runtime_type]-}" ]]; then
    RUNTIME_TYPES+=("$runtime_type")
  fi
done

if [[ ${#RUNTIME_TYPES[@]} -eq 0 ]]; then
  echo "ERROR: No valid runtime type selected. Use nodejs, golang, or both."
  exit 1
fi

RUNTIME_CSV="${(j:,:)RUNTIME_TYPES}"
HAS_NODEJS=false
if [[ -n "${TYPE_SELECTED[nodejs]-}" ]]; then
  HAS_NODEJS=true
fi

IMAGE_MODE="shared"
if [[ ${#RUNTIME_TYPES[@]} -gt 1 || ${#OVERLAY_FILES[@]} -gt 0 ]]; then
  IMAGE_MODE="project"
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

if backend_exists "$PROJECT"; then
  echo "ERROR: Container '$PROJECT' already exists."
  echo "  To rebuild: dc rebuild $PROJECT"
  exit 1
fi

COMPOSED_CONTAINERFILE=""
if [[ "$IMAGE_MODE" == "shared" ]]; then
  IMAGE="dev-${RUNTIME_TYPES[1]}:latest"
  DEVCONTAINER_BUILD_FILE="$ROOT_DIR/Containerfiles/Containerfile.${RUNTIME_TYPES[1]}"
else
  IMAGE="dev-${PROJECT}:latest"
  COMPOSED_CONTAINERFILE="$ROOT_DIR/Containerfiles/generated/Containerfile.${PROJECT}"
  DEVCONTAINER_BUILD_FILE="$COMPOSED_CONTAINERFILE"

  echo "==> Generating composed Containerfile for project image..."
  zsh "$COMPOSE_SCRIPT" "$COMPOSED_CONTAINERFILE" "$RUNTIME_CSV" "${OVERLAY_FILES[@]}"

  echo "==> Building project-scoped image: $IMAGE"
  backend_build_image "$IMAGE" "$COMPOSED_CONTAINERFILE" "$ROOT_DIR"
fi

echo "======================================================================"
echo "Creating container: $PROJECT"
echo "Runtime(s): $RUNTIME_CSV | Image: $IMAGE | Backend: $ACTIVE_BACKEND"
if [[ ${#OVERLAY_FILES[@]} -gt 0 ]]; then
  echo "Overlay Containerfiles: ${#OVERLAY_FILES[@]}"
fi
echo "======================================================================"
echo ""

mkdir -p "$SECRET_DIR" "$REPOS_DIR" "$PROJECT_CONFIG_DIR"
chmod 700 "$SECRET_DIR"
echo "✓ Directories created"
echo "  Repos mount: $REPOS_DIR"
echo "  Secrets:     $SECRET_DIR (chmod 700)"

SSH_KEY="$SECRET_DIR/ssh_key"
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -C "dev-container-${PROJECT}" -N "" -q
  chmod 600 "$SSH_KEY"
fi
echo ""
echo "✓ SSH deploy key: $SSH_KEY"
echo ""
echo "  Add this public key to GitHub Deploy Keys (write access):"
echo "  https://github.com/ORG/REPO/settings/keys"
echo ""
cat "${SSH_KEY}.pub"
echo ""

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

cat > "$CONFIG_FILE" <<EOF
# dev-container config for: $PROJECT
# Generated: $(date)
CONTAINER_PROJECT="$PROJECT"
CONTAINER_TYPE="$RUNTIME_CSV"
CONTAINER_RUNTIME_TYPES="$RUNTIME_CSV"
CONTAINER_IMAGE="$IMAGE"
CONTAINER_IMAGE_MODE="$IMAGE_MODE"
CONTAINER_BACKEND="$ACTIVE_BACKEND"
CONTAINER_COMPOSED_CONTAINERFILE="$COMPOSED_CONTAINERFILE"
REPOS_DIR="$REPOS_DIR"
SECRET_DIR="$SECRET_DIR"
SSH_KEY_PATH="$SECRET_DIR/ssh_key"
TOKEN_FILE="$SECRET_DIR/github-token"
NPMRC_PATH="$SECRET_DIR/.npmrc"
EOF

if [[ ${#PORTS[@]} -gt 0 ]]; then
  print -r -- "PORTS=(${(q)PORTS[@]})" >> "$CONFIG_FILE"
else
  echo "PORTS=()" >> "$CONFIG_FILE"
fi

if [[ ${#OVERLAY_FILES[@]} -gt 0 ]]; then
  print -r -- "CONTAINER_OVERLAY_FILES=(${(q)OVERLAY_FILES[@]})" >> "$CONFIG_FILE"
else
  echo "CONTAINER_OVERLAY_FILES=()" >> "$CONFIG_FILE"
fi

echo "✓ Config saved: $CONFIG_FILE"

VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
if $HAS_NODEJS; then
  VOLUME_ARGS+=(--volume "$SECRET_DIR/.npmrc:/home/dev/.npmrc:ro")
fi

PORT_ARGS=()
FORWARD_PORTS=()
for port_mapping in "${PORTS[@]}"; do
  [[ -z "$port_mapping" ]] && continue

  if [[ "$port_mapping" =~ '^[0-9]+:[0-9]+$' ]]; then
    host_port="${port_mapping%%:*}"
    container_port="${port_mapping##*:}"
    PORT_ARGS+=(--publish "$host_port:$container_port")
    FORWARD_PORTS+=("$container_port")
  elif [[ "$port_mapping" =~ '^[0-9]+$' ]]; then
    PORT_ARGS+=(--publish "$port_mapping:$port_mapping")
    FORWARD_PORTS+=("$port_mapping")
  else
    echo "ERROR: Invalid port mapping '$port_mapping'. Use host:container (e.g., 5173:5173)."
    exit 1
  fi
done

echo ""
echo "==> Creating container from image: $IMAGE"
backend_create "$PROJECT" "$IMAGE" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}"

echo ""
echo "==> Starting container for initial SSH key injection..."
backend_start "$PROJECT"
sleep 2

echo "==> Injecting SSH deploy key..."
backend_exec "$PROJECT" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
backend_exec_stdin "$PROJECT" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY"
backend_exec "$PROJECT" zsh -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null && chmod 644 ~/.ssh/known_hosts"

echo "==> Configuring git in container..."
backend_exec "$PROJECT" git config --global url."git@github.com:".insteadOf "https://github.com/"

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
      for forward_port in "${FORWARD_PORTS[@]}"; do
        if [[ -n "$FORWARD_PORTS_CSV" ]]; then
          FORWARD_PORTS_CSV+=", "
        fi
        FORWARD_PORTS_CSV+="$forward_port"
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
      for mount_entry in "${MOUNTS_ENTRIES[@]}"; do
        if ! $first_entry; then
          MOUNTS_BLOCK+=$',\n'
        fi
        MOUNTS_BLOCK+="    \"$mount_entry\""
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
echo "======================================================================"
echo "Container '$PROJECT' created and started."
echo "======================================================================"
echo "Checklist before use:"
echo "  [ ] Edit $TOKEN_FILE"
echo "  [ ] Add SSH public key to GitHub Deploy Keys for your repos"
echo "  [ ] Set up dotfiles in VS Code settings for personal config"
echo "      (see README: Personal configuration / dotfiles)"
if $DOCKER_COMPATIBLE; then
  echo "  [ ] (Optional) Open ~/repos/$PROJECT in VS Code Dev Containers"
else
  echo "  [ ] Open ~/repos/$PROJECT in VS Code (terminals auto-connect)"
fi
echo ""
echo "Commands:"
echo "  source ~/.zshrc"
echo "  dc shell $PROJECT"
echo "  dc stop $PROJECT"
echo "  dc start $PROJECT"
echo "  dc status"
