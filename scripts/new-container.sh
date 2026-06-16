#!/usr/bin/env bash
# =============================================================================
# new-container.sh - Create a new isolated development container.
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: new-container.sh <project-name> [scope[,scope...]] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [port:port ...]}"
shift
SCOPE_INPUT=""
if [[ $# -gt 0 && "$1" != --* && ! "$1" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
  SCOPE_INPUT="$1"
  shift
fi

if [[ ! "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: Invalid project name '$PROJECT'."
  echo "  Allowed characters: letters, numbers, dot, underscore, hyphen"
  exit 1
fi

PORTS=()
REPO_PATH_OVERRIDE=""
HIDDEN_PATH_INPUTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-path)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --repo-path requires a path argument"
        exit 1
      fi
      REPO_PATH_OVERRIDE="$2"
      shift 2
      ;;
    --cpus)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --cpus requires a value (e.g. 2, 1.5)"
        exit 1
      fi
      CONTAINER_CPUS="$2"
      shift 2
      ;;
    --memory)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --memory requires a value (e.g. 4g, 512m)"
        exit 1
      fi
      CONTAINER_MEMORY="$2"
      shift 2
      ;;
    --hide)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --hide requires a value (e.g. node_modules or apps/web/node_modules,apps/api/node_modules)"
        exit 1
      fi
      HIDDEN_PATH_INPUTS+=("$2")
      shift 2
      ;;
    *)
      PORTS+=("$1")
      shift
      ;;
  esac
done

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
source "$ROOT_DIR/lib/vscode.sh"

dc_load_global_config

COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"
if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
  exit 1
fi

SCOPE_CSV="$(dc_normalize_scopes_csv "$SCOPE_INPUT")" || exit 1
IMAGE="$(dc_image_ref_from_scopes "$DC_OVERLAYS_DIR" "$SCOPE_CSV")" || exit 1

HIDDEN_PATHS_CSV="$(dc_normalize_hidden_paths_values "${HIDDEN_PATH_INPUTS[@]:-}")" || exit 1
CONTAINER_HIDDEN_PATHS=()
if [[ -n "$HIDDEN_PATHS_CSV" ]]; then
  IFS=',' read -r -a CONTAINER_HIDDEN_PATHS <<< "$HIDDEN_PATHS_CSV"
fi

PORT_ARGS=()
FORWARD_PORTS=()
for port_mapping in "${PORTS[@]}"; do
  [[ -z "$port_mapping" ]] && continue

  if [[ "$port_mapping" =~ ^[0-9]+:[0-9]+$ ]]; then
    host_port="${port_mapping%%:*}"
    container_port="${port_mapping##*:}"
    PORT_ARGS+=(--publish "$host_port:$container_port")
    FORWARD_PORTS+=("$container_port")
  elif [[ "$port_mapping" =~ ^[0-9]+$ ]]; then
    PORT_ARGS+=(--publish "$port_mapping:$port_mapping")
    FORWARD_PORTS+=("$port_mapping")
  else
    echo "ERROR: Invalid port mapping '$port_mapping'. Use host:container (e.g., 5173:5173)."
    exit 1
  fi
done

SECRET_DIR="$HOME/.config/dev-containers/$PROJECT"
CONFIG_FILE="$HOME/.config/dev-containers/$PROJECT/config"
CONFIG_FILE_DISPLAY="~/.config/dev-containers/$PROJECT/config"

if [[ -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Project '$PROJECT' already exists (config: $CONFIG_FILE_DISPLAY)"
  echo "Choose a different name or remove the existing project config."
  exit 1
fi

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
DOCKER_COMPATIBLE=false
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  DOCKER_COMPATIBLE=true
fi

if ! backend_image_exists "dev-base:latest"; then
  echo "ERROR: Base image 'dev-base:latest' not found on backend '$ACTIVE_BACKEND'."
  echo "  Run setup first: CONTAINER_BACKEND=$ACTIVE_BACKEND scripts/setup.sh"
  exit 1
fi

if backend_exists "$PROJECT"; then
  echo "ERROR: Container '$PROJECT' already exists."
  echo "To rebuild: dc rebuild-container $PROJECT"
  exit 1
fi

if [[ -n "$REPO_PATH_OVERRIDE" ]]; then
  repo_target="$REPO_PATH_OVERRIDE"
else
  repo_target="${DC_REPOS_DIR:-$HOME/repos}/$PROJECT"
fi

if [[ "$repo_target" == "~" || "$repo_target" == "~/"* ]]; then
  repo_target="$HOME${repo_target#\~}"
elif [[ "$repo_target" != /* ]]; then
  repo_target="$PWD/$repo_target"
fi

mkdir -p "$repo_target"
REPOS_DIR="$(dc_resolve_path "$repo_target")" || {
  if [[ -n "$REPO_PATH_OVERRIDE" ]]; then
    echo "ERROR: --repo-path could not be resolved: $REPO_PATH_OVERRIDE"
  else
    echo "ERROR: Default repo path could not be resolved: $repo_target"
  fi
  exit 1
}

COMPOSED_CONTAINERFILE=""
DEVCONTAINER_BUILD_FILE="$ROOT_DIR/Containerfiles/Containerfile.base"

if [[ "$IMAGE" != "dev-base:latest" ]]; then
  IMAGE_HASH="$(dc_image_hash_from_ref "$IMAGE")" || {
    echo "ERROR: Could not derive image hash from image ref: $IMAGE"
    exit 1
  }

  COMPOSED_CONTAINERFILE="$ROOT_DIR/Containerfiles/generated/Containerfile.${IMAGE_HASH}"
  DEVCONTAINER_BUILD_FILE="$COMPOSED_CONTAINERFILE"

  if backend_image_exists "$IMAGE"; then
    if [[ ! -f "$COMPOSED_CONTAINERFILE" ]]; then
      echo "==> Generating composed Containerfile for image: $IMAGE"
      bash "$COMPOSE_SCRIPT" "$COMPOSED_CONTAINERFILE" "$SCOPE_CSV"
    fi
    echo "==> Reusing existing image: $IMAGE"
  else
    echo "==> Generating composed Containerfile for image: $IMAGE"
    bash "$COMPOSE_SCRIPT" "$COMPOSED_CONTAINERFILE" "$SCOPE_CSV"
    echo "==> Building image: $IMAGE"
    backend_build_image "$IMAGE" "$COMPOSED_CONTAINERFILE" "$ROOT_DIR"
  fi
fi

echo "======================================================================"
echo "Creating container: $PROJECT"
echo "Overlay scope(s): ${SCOPE_CSV:-(none)} | Image: $IMAGE | Backend: $ACTIVE_BACKEND"
if [[ -n "${CONTAINER_CPUS:-}" || -n "${CONTAINER_MEMORY:-}" ]]; then
  echo "Resources: ${CONTAINER_CPUS:-(default)} CPU, ${CONTAINER_MEMORY:-(default)} memory"
fi
if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "Hidden paths: ${CONTAINER_HIDDEN_PATHS[*]}"
fi
echo "======================================================================"
echo ""

mkdir -p "$SECRET_DIR" "$REPOS_DIR"
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

cat > "$CONFIG_FILE" <<EOF
# dev-container config for: $PROJECT
# Generated: $(date)
CONTAINER_PROJECT="$PROJECT"
CONTAINER_OVERLAY_SCOPES="$SCOPE_CSV"
CONTAINER_IMAGE="$IMAGE"
CONTAINER_BACKEND="$ACTIVE_BACKEND"
CONTAINER_CPUS="${CONTAINER_CPUS:-}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-}"
REPOS_DIR="$REPOS_DIR"
SECRET_DIR="$SECRET_DIR"
SSH_KEY_PATH="$SECRET_DIR/ssh_key"
TOKEN_FILE="$SECRET_DIR/github-token"
NPMRC_PATH="$SECRET_DIR/.npmrc"
EOF

if [[ ${#PORTS[@]} -gt 0 ]]; then
  printf 'PORTS=(' >> "$CONFIG_FILE"
  printf '%q ' "${PORTS[@]}" >> "$CONFIG_FILE"
  printf ')\n' >> "$CONFIG_FILE"
else
  echo "PORTS=()" >> "$CONFIG_FILE"
fi

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  printf 'CONTAINER_HIDDEN_PATHS=(' >> "$CONFIG_FILE"
  printf '%q ' "${CONTAINER_HIDDEN_PATHS[@]}" >> "$CONFIG_FILE"
  printf ')\n' >> "$CONFIG_FILE"
else
  echo "CONTAINER_HIDDEN_PATHS=()" >> "$CONFIG_FILE"
fi

echo "✓ Config saved: $CONFIG_FILE"

RESOURCE_ARGS=()
if [[ -n "${CONTAINER_CPUS:-}" ]]; then
  RESOURCE_ARGS+=(--cpus "$CONTAINER_CPUS")
fi
if [[ -n "${CONTAINER_MEMORY:-}" ]]; then
  RESOURCE_ARGS+=(--memory "$CONTAINER_MEMORY")
fi

VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
VOLUME_ARGS+=(--volume "$SECRET_DIR/.npmrc:/home/dev/.npmrc:ro")
for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
  hidden_volume="$(dc_hidden_volume_name "$PROJECT" "$hidden_path")"
  VOLUME_ARGS+=(--volume "$hidden_volume:/workspace/$hidden_path")
done

echo ""
echo "==> Creating container from image: $IMAGE"
backend_create "$PROJECT" "$IMAGE" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}" "${RESOURCE_ARGS[@]}"

echo ""
echo "==> Starting container for initial SSH key injection..."
backend_start "$PROJECT"
sleep 2

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "==> Normalizing hidden-path ownership..."
  for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
    target="/workspace/$hidden_path"
    backend_exec_as_root "$PROJECT" sh -lc "mkdir -p '$target' && chown -R dev:dev '$target'"
    if ! backend_exec "$PROJECT" sh -lc "test -w '$target'"; then
      echo "ERROR: Hidden path is not writable by dev: $target"
      exit 1
    fi
  done
fi

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
    echo "  ✓ $DEVCONTAINER_FILE already exists - not overwritten."
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
    MOUNTS_ENTRIES+=("source=$SECRET_DIR/.npmrc,target=/home/dev/.npmrc,type=bind,readonly")
    for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
      hidden_volume="$(dc_hidden_volume_name "$PROJECT" "$hidden_path")"
      MOUNTS_ENTRIES+=("source=$hidden_volume,target=/workspace/$hidden_path,type=volume")
    done

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

  echo "==> Seeding VS Code named attach config..."
  ATTACH_CONFIG_COUNT=0
  while IFS= read -r attach_config_file; do
    [[ -z "$attach_config_file" ]] && continue
    ATTACH_CONFIG_COUNT=$((ATTACH_CONFIG_COUNT + 1))
    echo "  ✓ $attach_config_file"
  done < <(dc_vscode_seed_named_attach_config "$PROJECT" "/workspace")

  if [[ "$ATTACH_CONFIG_COUNT" -eq 0 ]]; then
    echo "  (No VS Code user storage found; config will be created after first VS Code attach.)"
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
    echo "  ✓ $VSCODE_SETTINGS already exists - not overwritten."
    echo "  Add this manually if needed:"
    echo '    "terminal.integrated.defaultProfile.osx": "dev-container"'
    echo "    \"terminal.integrated.profiles.osx\": { \"dev-container\": { \"path\": \"/bin/zsh\", \"args\": [\"-c\", \"$ROOT_DIR/scripts/shell.sh $PROJECT\"] } }"
  fi
fi

echo ""
echo "======================================================================"
echo "Container '$PROJECT' created and started."
echo "======================================================================"
echo ""
echo "Config: ~/.config/dev-containers/$PROJECT/"
echo "  [ ] github-token   Replace ghp_REPLACE_ME with your GitHub PAT"
echo "  [ ] ssh_key.pub    Add as GitHub Deploy Key for your repos"
echo ""
if $DOCKER_COMPATIBLE; then
  echo "  [ ] (Optional) Open $REPOS_DIR in VS Code Dev Containers"
else
  echo "  [ ] Open $REPOS_DIR in VS Code (terminals auto-connect)"
fi
echo "  [ ] Set up dotfiles in VS Code settings for personal config"
echo "      (see README: Personal configuration / dotfiles)"
echo ""
echo "Commands:"
echo "  dc shell $PROJECT"
echo "  dc stop $PROJECT"
echo "  dc start $PROJECT"
echo "  dc status"
