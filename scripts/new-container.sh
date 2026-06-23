#!/usr/bin/env bash
# =============================================================================
# scripts/new-container.sh - `dc new`: create a new isolated dev container.
#
# High-level flow:
#   1. Parse project name, optional scope(s), flags (--repo-path/--cpus/
#      --memory/--hide), and host:container port mappings.
#   2. Resolve the derived image from scopes; compose+build it if missing,
#      reuse it if present (dev-base:latest when no scopes).
#   3. Fail fast if the base image, project config, or container already exists.
#   4. Create the per-project secret dir: SSH deploy key, GitHub token
#      placeholder, .npmrc template (all tight permissions).
#   5. Write the project config and create+start the container with mounts,
#      ports, resource limits, and hidden volumes.
#   6. Verify hidden mounts, fix their ownership, inject SSH key + git config.
#   7. Generate editor integration: devcontainer.json (Docker-compatible) or
#      VS Code terminal-profile settings (apple/container).
# =============================================================================
set -euo pipefail

# 1. Parse arguments: project name, optional scope, flags, and port mappings.
PROJECT="${1:?Usage: new-container.sh <project-name> [scope[,scope...]] [--config <path>|--config=<path>] [--save-team] [--save-user] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [port:port ...]}"
shift
SCOPE_INPUT=""
CLI_SET_SCOPE=false
if [[ $# -gt 0 && "$1" != --* && ! "$1" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
  SCOPE_INPUT="$1"
  CLI_SET_SCOPE=true
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
NETWORK_INPUT=""
NETWORK_IP=""
RECIPE_CONFIG_PATH=""
SAVE_TEAM_RECIPE=false
SAVE_USER_RECIPE=false
CLI_SET_CPUS=false
CLI_SET_MEMORY=false
CLI_SET_HIDE=false
CLI_SET_NETWORK=false
CLI_SET_IP=false
CLI_SET_REPO_PATH=false
CLI_SET_PORTS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --config requires a recipe file path"
        exit 1
      fi
      RECIPE_CONFIG_PATH="$2"
      shift 2
      ;;
    --config=*)
      RECIPE_CONFIG_PATH="${1#--config=}"
      if [[ -z "$RECIPE_CONFIG_PATH" ]]; then
        echo "ERROR: --config requires a non-empty recipe file path"
        exit 1
      fi
      shift
      ;;
    --repo-path)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --repo-path requires a path argument"
        exit 1
      fi
      REPO_PATH_OVERRIDE="$2"
      CLI_SET_REPO_PATH=true
      shift 2
      ;;
    --cpus)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --cpus requires a value (e.g. 2, 1.5)"
        exit 1
      fi
      CONTAINER_CPUS="$2"
      CLI_SET_CPUS=true
      shift 2
      ;;
    --memory)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --memory requires a value (e.g. 4g, 512m)"
        exit 1
      fi
      CONTAINER_MEMORY="$2"
      CLI_SET_MEMORY=true
      shift 2
      ;;
    --hide)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --hide requires a value (e.g. node_modules or apps/web/node_modules,apps/api/node_modules)"
        exit 1
      fi
      HIDDEN_PATH_INPUTS+=("$2")
      CLI_SET_HIDE=true
      shift 2
      ;;
    --network)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --network requires a value (e.g. myapp or myapp,obs or myapp:10.0.0.5)"
        exit 1
      fi
      NETWORK_INPUT="$2"
      CLI_SET_NETWORK=true
      shift 2
      ;;
    --ip)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --ip requires an IPv4 address (e.g. 10.0.0.5)"
        exit 1
      fi
      NETWORK_IP="$2"
      CLI_SET_IP=true
      shift 2
      ;;
    --save-team)
      SAVE_TEAM_RECIPE=true
      shift
      ;;
    --save-user)
      SAVE_USER_RECIPE=true
      shift
      ;;
    *)
      PORTS+=("$1")
      CLI_SET_PORTS=true
      shift
      ;;
  esac
done

# Preserve the raw CLI-supplied values so --save-team/--save-user can persist the
# exact user inputs (not recipe defaults merged in later).
CLI_SCOPE_INPUT="$SCOPE_INPUT"
CLI_CONTAINER_CPUS="${CONTAINER_CPUS:-}"
CLI_CONTAINER_MEMORY="${CONTAINER_MEMORY:-}"
CLI_NETWORK_INPUT="$NETWORK_INPUT"
CLI_NETWORK_IP="$NETWORK_IP"
CLI_REPO_PATH_OVERRIDE="$REPO_PATH_OVERRIDE"
CLI_HIDDEN_PATH_INPUTS=("${HIDDEN_PATH_INPUTS[@]}")
CLI_PORTS=("${PORTS[@]}")

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
source "$ROOT_DIR/lib/network.sh"
source "$ROOT_DIR/lib/recipe.sh"
source "$ROOT_DIR/lib/vscode.sh"

dc_load_global_config

SAVE_RECIPE_LINES=()
if $SAVE_TEAM_RECIPE || $SAVE_USER_RECIPE; then
  if $CLI_SET_SCOPE; then
    SAVE_SCOPE_CSV="$(dc_normalize_scopes_csv "$CLI_SCOPE_INPUT")" || exit 1
    [[ -n "$SAVE_SCOPE_CSV" ]] && SAVE_RECIPE_LINES+=("scopes=$SAVE_SCOPE_CSV")
  fi

  if $CLI_SET_CPUS; then
    dc_validate_cpus_value "$CLI_CONTAINER_CPUS" || exit 1
    SAVE_RECIPE_LINES+=("cpus=$CLI_CONTAINER_CPUS")
  fi

  if $CLI_SET_MEMORY; then
    dc_validate_memory_value "$CLI_CONTAINER_MEMORY" || exit 1
    SAVE_RECIPE_LINES+=("memory=$CLI_CONTAINER_MEMORY")
  fi

  if $CLI_SET_HIDE; then
    SAVE_HIDE_CSV="$(dc_normalize_hidden_paths_values "${CLI_HIDDEN_PATH_INPUTS[@]:-}")" || exit 1
    if [[ -n "$SAVE_HIDE_CSV" ]]; then
      IFS=',' read -r -a SAVE_HIDE_VALUES <<< "$SAVE_HIDE_CSV"
      for SAVE_HIDE_PATH in "${SAVE_HIDE_VALUES[@]}"; do
        [[ -z "$SAVE_HIDE_PATH" ]] && continue
        SAVE_RECIPE_LINES+=("hide=$SAVE_HIDE_PATH")
      done
    fi
  fi

  if $CLI_SET_NETWORK; then
    SAVE_NETWORK_CSV="$(dc_normalize_network_arg "$CLI_NETWORK_INPUT")" || exit 1
    [[ -n "$SAVE_NETWORK_CSV" ]] && SAVE_RECIPE_LINES+=("network=$SAVE_NETWORK_CSV")
  fi

  if $CLI_SET_IP; then
    dc_validate_ip_value "$CLI_NETWORK_IP" || exit 1
    SAVE_RECIPE_LINES+=("ip=$CLI_NETWORK_IP")
  fi

  if $CLI_SET_REPO_PATH; then
    SAVE_RECIPE_LINES+=("repo-path=$CLI_REPO_PATH_OVERRIDE")
  fi

  if $CLI_SET_PORTS; then
    for SAVE_PORT_MAPPING in "${CLI_PORTS[@]}"; do
      [[ -z "$SAVE_PORT_MAPPING" ]] && continue
      if [[ "$SAVE_PORT_MAPPING" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        SAVE_RECIPE_LINES+=("port=$SAVE_PORT_MAPPING")
      else
        echo "ERROR: Invalid port mapping '$SAVE_PORT_MAPPING'. Use host:container (e.g., 5173:5173)."
        exit 1
      fi
    done
  fi
fi

# Load an explicit recipe (--config) or magic-resolved team/user recipes by
# project name, then merge with CLI precedence (CLI values override recipe
# values; list keys replace as a whole when supplied on the CLI).
if ! dc_recipe_resolve_inputs "$PROJECT" "$RECIPE_CONFIG_PATH"; then
  exit 1
fi

if [[ -z "$SCOPE_INPUT" && -n "${_DC_RECIPE_MERGED_SCOPE_INPUT:-}" ]]; then
  SCOPE_INPUT="$_DC_RECIPE_MERGED_SCOPE_INPUT"
fi
if [[ -z "${CONTAINER_CPUS:-}" && -n "${_DC_RECIPE_MERGED_CONTAINER_CPUS:-}" ]]; then
  CONTAINER_CPUS="$_DC_RECIPE_MERGED_CONTAINER_CPUS"
fi
if [[ -z "${CONTAINER_MEMORY:-}" && -n "${_DC_RECIPE_MERGED_CONTAINER_MEMORY:-}" ]]; then
  CONTAINER_MEMORY="$_DC_RECIPE_MERGED_CONTAINER_MEMORY"
fi
if [[ ${#HIDDEN_PATH_INPUTS[@]} -eq 0 && ${#_DC_RECIPE_MERGED_HIDDEN_PATH_INPUTS[@]} -gt 0 ]]; then
  HIDDEN_PATH_INPUTS=("${_DC_RECIPE_MERGED_HIDDEN_PATH_INPUTS[@]}")
fi
if [[ -z "$NETWORK_INPUT" && -n "${_DC_RECIPE_MERGED_NETWORK_INPUT:-}" ]]; then
  NETWORK_INPUT="$_DC_RECIPE_MERGED_NETWORK_INPUT"
fi
if [[ -z "$NETWORK_IP" && -n "${_DC_RECIPE_MERGED_NETWORK_IP:-}" ]]; then
  NETWORK_IP="$_DC_RECIPE_MERGED_NETWORK_IP"
fi
if [[ -z "$REPO_PATH_OVERRIDE" && -n "${_DC_RECIPE_MERGED_REPO_PATH_OVERRIDE:-}" ]]; then
  REPO_PATH_OVERRIDE="$_DC_RECIPE_MERGED_REPO_PATH_OVERRIDE"
fi
if [[ ${#PORTS[@]} -eq 0 && ${#_DC_RECIPE_MERGED_PORTS[@]} -gt 0 ]]; then
  PORTS=("${_DC_RECIPE_MERGED_PORTS[@]}")
fi

# Fail fast on merged resource values before any backend work.
if [[ -n "${CONTAINER_CPUS:-}" ]]; then
  dc_validate_cpus_value "$CONTAINER_CPUS" || exit 1
fi
if [[ -n "${CONTAINER_MEMORY:-}" ]]; then
  dc_validate_memory_value "$CONTAINER_MEMORY" || exit 1
fi

COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"
if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
  exit 1
fi

# 2. Resolve the derived image for these scopes (dev-base:latest when none).
SCOPE_CSV="$(dc_normalize_scopes_csv "$SCOPE_INPUT")" || exit 1
IMAGE="$(dc_image_ref_from_scopes "$(dc_team_overlays_dir)" "$(dc_user_overlays_dir)" "$SCOPE_CSV")" || exit 1

HIDDEN_PATHS_CSV="$(dc_normalize_hidden_paths_values "${HIDDEN_PATH_INPUTS[@]:-}")" || exit 1
CONTAINER_HIDDEN_PATHS=()
if [[ -n "$HIDDEN_PATHS_CSV" ]]; then
  IFS=',' read -r -a CONTAINER_HIDDEN_PATHS <<< "$HIDDEN_PATHS_CSV"
fi

# Resolve the network membership requested via --network (with optional --ip on
# the primary). The result is a CONTAINER_NETWORKS array of `name[:ip]` entries;
# backend-existence and limit checks run later, once the backend is selected.
CONTAINER_NETWORKS=()
if [[ -n "$NETWORK_INPUT" ]]; then
  NETWORKS_CSV="$(dc_normalize_network_arg "$NETWORK_INPUT")" || exit 1
  if [[ -n "$NETWORKS_CSV" ]]; then
    IFS=',' read -r -a CONTAINER_NETWORKS <<< "$NETWORKS_CSV"
  fi
fi
if [[ -n "$NETWORK_IP" ]]; then
  dc_validate_ip_value "$NETWORK_IP" || exit 1
  if [[ ${#CONTAINER_NETWORKS[@]} -eq 0 ]]; then
    echo "ERROR: --ip requires --network (no networks requested)."
    exit 1
  fi
  primary="${CONTAINER_NETWORKS[0]}"
  if [[ "$primary" == *:* ]]; then
    echo "ERROR: --ip conflicts with an explicit IP on the primary network ('$primary')."
    echo "       Use either --ip <addr> or the 'name:ip' syntax, not both."
    exit 1
  fi
  CONTAINER_NETWORKS[0]="${primary}:${NETWORK_IP}"
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

# Validate the requested network membership against the selected backend: enforce
# apple's single-network/no-static-IP limits, and require every network to exist
# (networks are created explicitly via `dc network create`). Then derive the
# create-time args; extras are attached after the container exists.
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  if ! dc_network_check_backend_limits "$ACTIVE_BACKEND" "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
  if ! dc_networks_ensure_exist "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
fi
NETWORK_ARGS=()
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  mapfile -t NETWORK_ARGS < <(dc_networks_create_args "${CONTAINER_NETWORKS[@]}")
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

# If scopes select a derived image, compose+build it once (reuse if present).
if [[ "$IMAGE" != "dev-base:latest" ]]; then
  IMAGE_HASH="$(dc_image_hash_from_ref "$IMAGE")" || {
    echo "ERROR: Could not derive image hash from image ref: $IMAGE"
    exit 1
  }

  COMPOSED_CONTAINERFILE="$ROOT_DIR/Containerfiles/generated/Containerfile.${IMAGE_HASH}"
  DEVCONTAINER_BUILD_FILE="$COMPOSED_CONTAINERFILE"

  # dev-base image Id feeds the provenance base.id label (best-effort, may be
  # empty if the backend cannot resolve it).
  PROV_BASE_ID="$(backend_image_id "dev-base:latest")"

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
    PROV_BUILT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    backend_build_image "$IMAGE" "$COMPOSED_CONTAINERFILE" "$ROOT_DIR" \
      --build-arg "DC_BASE_ID=$PROV_BASE_ID" \
      --build-arg "DC_BUILT_UTC=$PROV_BUILT_UTC"
  fi

  # Record this image's provenance in the project log (deduped). A reused image
  # still gets an entry so `dc provenance <project>` is populated.
  dc_log_provenance "$PROJECT" "$IMAGE" "new" "$DC_TEAM_DIR" "$DC_USER_DIR" "$SCOPE_CSV" "$PROV_BASE_ID"
fi

# Detect the host timezone once so the container mirrors the developer's local
# time (per-developer at create time, never baked into the shared image). Empty
# means no clean zone was found; we then omit --env TZ and leave the image
# default untouched. The result feeds both the create flag and devcontainer.json.
HOST_TZ="$(dc_host_timezone)" || HOST_TZ=""
TZ_ARGS=()
if [[ -n "$HOST_TZ" ]]; then
  TZ_ARGS+=(--env "TZ=$HOST_TZ")
fi

echo "======================================================================"
echo "Creating container: $PROJECT"
echo "Overlay scope(s): ${SCOPE_CSV:-(none)} | Image: $IMAGE | Backend: $ACTIVE_BACKEND"
if [[ -n "${CONTAINER_CPUS:-}" || -n "${CONTAINER_MEMORY:-}" ]]; then
  echo "Resources: ${CONTAINER_CPUS:-(default)} CPU, ${CONTAINER_MEMORY:-(default)} memory"
fi
if [[ -n "$HOST_TZ" ]]; then
  echo "Timezone: $HOST_TZ (synced from host via --env TZ)"
else
  echo "Timezone: (host zone undetectable - container stays on image default)"
fi
if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "Hidden paths: ${CONTAINER_HIDDEN_PATHS[*]}"
fi
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  echo "Networks: ${CONTAINER_NETWORKS[*]}"
fi
echo "======================================================================"
echo ""

mkdir -p "$SECRET_DIR" "$REPOS_DIR"
chmod 700 "$SECRET_DIR"
echo "✓ Directories created"
echo "  Repos mount: $REPOS_DIR"
echo "  Secrets:     $SECRET_DIR (chmod 700)"

# Bootstrap per-project secrets (only created if missing, never overwritten).
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

# Serialize every scalar value through the shared escaper so the persisted config
# is inert data: any $/backtick/quote/backslash is escaped and round-trips safely
# through dc_load_project_config without executing command substitution.
esc_project="$(dc_escape_config_value "$PROJECT")" || exit 1
esc_scopes="$(dc_escape_config_value "$SCOPE_CSV")" || exit 1
esc_image="$(dc_escape_config_value "$IMAGE")" || exit 1
esc_backend="$(dc_escape_config_value "$ACTIVE_BACKEND")" || exit 1
esc_cpus="$(dc_escape_config_value "${CONTAINER_CPUS:-}")" || exit 1
esc_memory="$(dc_escape_config_value "${CONTAINER_MEMORY:-}")" || exit 1
esc_repos="$(dc_escape_config_value "$REPOS_DIR")" || exit 1
esc_secret="$(dc_escape_config_value "$SECRET_DIR")" || exit 1
esc_ssh="$(dc_escape_config_value "$SECRET_DIR/ssh_key")" || exit 1
esc_token="$(dc_escape_config_value "$SECRET_DIR/github-token")" || exit 1
esc_npmrc="$(dc_escape_config_value "$SECRET_DIR/.npmrc")" || exit 1

cat > "$CONFIG_FILE" <<EOF
# dev-container config for: $PROJECT
# Generated: $(date)
CONTAINER_PROJECT="$esc_project"
CONTAINER_OVERLAY_SCOPES="$esc_scopes"
CONTAINER_IMAGE="$esc_image"
CONTAINER_BACKEND="$esc_backend"
CONTAINER_CPUS="$esc_cpus"
CONTAINER_MEMORY="$esc_memory"
REPOS_DIR="$esc_repos"
SECRET_DIR="$esc_secret"
SSH_KEY_PATH="$esc_ssh"
TOKEN_FILE="$esc_token"
NPMRC_PATH="$esc_npmrc"
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

if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  printf 'CONTAINER_NETWORKS=(' >> "$CONFIG_FILE"
  printf '%q ' "${CONTAINER_NETWORKS[@]}" >> "$CONFIG_FILE"
  printf ')\n' >> "$CONFIG_FILE"
else
  echo "CONTAINER_NETWORKS=()" >> "$CONFIG_FILE"
fi

# Owner-only permissions: the config holds secret paths and is a trusted input to
# later loads, so it must never be group/other-writable (the loader rejects that).
chmod 600 "$CONFIG_FILE"

echo "✓ Config saved: $CONFIG_FILE"

if $SAVE_TEAM_RECIPE; then
  TEAM_RECIPE_FILE="$(dc_team_recipes_dir)/$PROJECT"
  if ! dc_recipe_write_file "$TEAM_RECIPE_FILE" "${SAVE_RECIPE_LINES[@]}"; then
    exit 1
  fi
  echo "✓ Team recipe saved: $TEAM_RECIPE_FILE"
fi

if $SAVE_USER_RECIPE; then
  USER_RECIPE_FILE="$(dc_user_recipes_dir)/$PROJECT"
  if ! dc_recipe_write_file "$USER_RECIPE_FILE" "${SAVE_RECIPE_LINES[@]}"; then
    exit 1
  fi
  echo "✓ User recipe saved: $USER_RECIPE_FILE"
fi

RESOURCE_ARGS=()
if [[ -n "${CONTAINER_CPUS:-}" ]]; then
  RESOURCE_ARGS+=(--cpus "$CONTAINER_CPUS")
fi
if [[ -n "${CONTAINER_MEMORY:-}" ]]; then
  RESOURCE_ARGS+=(--memory "$CONTAINER_MEMORY")
fi

# Mount flags: workspace bind mount, read-only .npmrc, one hidden volume per path.
VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
VOLUME_ARGS+=(--volume "$SECRET_DIR/.npmrc:/home/dev/.npmrc:ro")
for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
  hidden_volume="$(dc_hidden_volume_name "$PROJECT" "$hidden_path")"
  VOLUME_ARGS+=(--volume "$hidden_volume:/workspace/$hidden_path")
done

echo ""
echo "==> Creating container from image: $IMAGE"
backend_create "$PROJECT" "$IMAGE" "${TZ_ARGS[@]}" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}" "${RESOURCE_ARGS[@]}" "${NETWORK_ARGS[@]}"

# Attach any networks beyond the primary (Docker-compatible backends). On apple
# the limits check already restricted membership to a single primary network.
if [[ ${#CONTAINER_NETWORKS[@]} -gt 1 ]]; then
  echo "==> Attaching additional networks..."
  if ! dc_networks_attach_extras "$PROJECT" "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
fi

echo ""
echo "==> Starting container for initial SSH key injection..."
backend_start "$PROJECT"
sleep 2

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "==> Verifying hidden volume mounts..."
  if ! dc_ensure_hidden_mounts "$PROJECT" "${CONTAINER_HIDDEN_PATHS[@]}"; then
    exit 1
  fi
  echo "  ✓ Hidden volume mounts active"

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
# GitHub host keys are pinned in the base image; no runtime ssh-keyscan.

echo "==> Configuring git in container..."
backend_exec "$PROJECT" git config --global url."git@github.com:".insteadOf "https://github.com/"

if $DOCKER_COMPATIBLE; then
  echo "==> Generating Dev Containers config for Docker-compatible backend..."
  # Docker-compatible: write a .devcontainer/devcontainer.json so VS Code Dev
  # Containers can build/attach the same recipe (existing file is preserved).
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

    # runArgs carries the network membership so a VS Code "Reopen in Container"
    # build attaches to the same private network(s) as `dc new` did. The primary
    # network is listed first (with its optional static IP), extras after.
    RUNARGS_BLOCK=""
    if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
      _ra_primary="${CONTAINER_NETWORKS[0]}"
      _ra_name="$(dc_network_entry_name "$_ra_primary")"
      _ra_ip="$(dc_network_entry_ip "$_ra_primary")"
      RUNARGS_ENTRIES=("--network" "$_ra_name")
      [[ -n "$_ra_ip" ]] && RUNARGS_ENTRIES+=("--ip" "$_ra_ip")
      for ((_ra_i = 1; _ra_i < ${#CONTAINER_NETWORKS[@]}; _ra_i++)); do
        RUNARGS_ENTRIES+=("--network" "$(dc_network_entry_name "${CONTAINER_NETWORKS[$_ra_i]}")")
      done
      RUNARGS_BLOCK=$',\n  "runArgs": ['
      _ra_first=true
      for _ra_e in "${RUNARGS_ENTRIES[@]}"; do
        $_ra_first || RUNARGS_BLOCK+=", "
        RUNARGS_BLOCK+="\"$_ra_e\""
        _ra_first=false
      done
      RUNARGS_BLOCK+="]"
    fi

    # containerEnv carries the detected host TZ so a VS Code "Reopen in
    # Container" build lands on the same timezone as the dc-created container.
    # HOST_TZ is charset-validated (no quotes/backslashes), so it is JSON-safe.
    CONTAINERENV_BLOCK=""
    if [[ -n "$HOST_TZ" ]]; then
      CONTAINERENV_BLOCK=$',\n  "containerEnv": {\n    "TZ": "'"$HOST_TZ"$'"\n  }'
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
  "postCreateCommand": "true"$FORWARD_PORTS_BLOCK$MOUNTS_BLOCK$RUNARGS_BLOCK$CONTAINERENV_BLOCK
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
  # apple/container has no Dev Containers extension; route VS Code terminals
  # through `dc shell` via a terminal profile instead.
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
