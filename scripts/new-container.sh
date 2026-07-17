#!/usr/bin/env bash
# =============================================================================
# scripts/new-container.sh - `dce new`: create a new isolated dev container.
#
# High-level flow:
#   1. Parse project name, optional scope(s), flags (--repo-path/--cpus/
#      --memory/--hide), and host:container port mappings.
#   2. Resolve the derived image from scopes; compose+build it if missing,
#      reuse it if present (dce-base:latest when no scopes).
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
source "$ROOT_DIR/lib/recipe.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/vscode.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/devcontainer.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/extensions.sh"

# 1. Parse arguments: project name, optional scope, flags, and port mappings.
PROJECT="${1:?Usage: new-container.sh <project-name> [scope[,scope...]] [--config <path>|--config=<path>] [--save-team] [--save-user] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [--sync] [--sync-ignore <path[,path...]> ...] [--yes|-y] [port:port ...]}"
shift
SCOPE_INPUT=""
CLI_SET_SCOPE=false
if [[ $# -gt 0 && "$1" != -* && ! "$1" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
  SCOPE_INPUT="$1"
  CLI_SET_SCOPE=true
  shift
fi

if [[ ! "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  dce_die "Invalid project name '$PROJECT'.
  Allowed characters: letters, numbers, dot, underscore, hyphen"
fi

PORTS=()
REPO_PATH_OVERRIDE=""
HIDDEN_PATH_INPUTS=()
SYNC_IGNORE_INPUTS=()
NETWORK_INPUT=""
NETWORK_IP=""
RECIPE_CONFIG_PATH=""
SAVE_TEAM_RECIPE=false
SAVE_USER_RECIPE=false
GIT_HOST_INPUT=""
CLI_SET_CPUS=false
CLI_SET_MEMORY=false
CLI_SET_HIDE=false
CLI_SET_SYNC=false
CLI_SET_SYNC_IGNORE=false
CLI_SET_NETWORK=false
CLI_SET_IP=false
CLI_SET_REPO_PATH=false
CLI_SET_PORTS=false
SYNC_ENABLED=false
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--config requires a recipe file path"
      fi
      RECIPE_CONFIG_PATH="$2"
      shift 2
      ;;
    --config=*)
      RECIPE_CONFIG_PATH="${1#--config=}"
      if [[ -z "$RECIPE_CONFIG_PATH" ]]; then
        dce_die "--config requires a non-empty recipe file path"
      fi
      shift
      ;;
    --repo-path)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--repo-path requires a path argument"
      fi
      REPO_PATH_OVERRIDE="$2"
      CLI_SET_REPO_PATH=true
      shift 2
      ;;
    --cpus)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--cpus requires a value (e.g. 2, 1.5)"
      fi
      CONTAINER_CPUS="$2"
      CLI_SET_CPUS=true
      shift 2
      ;;
    --memory)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--memory requires a value (e.g. 4g, 512m)"
      fi
      CONTAINER_MEMORY="$2"
      CLI_SET_MEMORY=true
      shift 2
      ;;
    --hide)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--hide requires a value (e.g. node_modules or apps/web/node_modules,apps/api/node_modules)"
      fi
      HIDDEN_PATH_INPUTS+=("$2")
      CLI_SET_HIDE=true
      shift 2
      ;;
    --sync)
      SYNC_ENABLED=true
      CLI_SET_SYNC=true
      shift
      ;;
    --sync-ignore)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--sync-ignore requires a value (e.g. node_modules or apps/web/node_modules,apps/api/node_modules)"
      fi
      SYNC_IGNORE_INPUTS+=("$2")
      CLI_SET_SYNC_IGNORE=true
      shift 2
      ;;
    --network)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--network requires a value (e.g. myapp or myapp,obs or myapp:10.0.0.5)"
      fi
      NETWORK_INPUT="$2"
      CLI_SET_NETWORK=true
      shift 2
      ;;
    --ip)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--ip requires an IPv4 address (e.g. 10.0.0.5)"
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
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --git-host)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dce_die "--git-host requires a provider name (e.g. github, gitlab)"
      fi
      GIT_HOST_INPUT="$2"
      shift 2
      ;;
    --git-host=*)
      GIT_HOST_INPUT="${1#--git-host=}"
      if [[ -z "$GIT_HOST_INPUT" ]]; then
        dce_die "--git-host requires a provider name (e.g. github, gitlab)"
      fi
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
CLI_SYNC_IGNORE_INPUTS=("${SYNC_IGNORE_INPUTS[@]}")
CLI_PORTS=("${PORTS[@]}")

# --sync and --hide belong to different worlds and never compose. Reject at parse
# time with a pointer at the sync-world analog (--sync-ignore), and reject a
# lone --sync-ignore (it only has meaning under --sync).
if $CLI_SET_SYNC && $CLI_SET_HIDE; then
  dce_die "--sync and --hide are mutually exclusive.
     Under --sync, exclude generated paths with --sync-ignore instead.
     Example: --sync --sync-ignore node_modules"
fi
if $CLI_SET_SYNC_IGNORE && ! $CLI_SET_SYNC; then
  dce_die "--sync-ignore only has meaning with --sync."
fi

# Resolve the git host provider (github default). Validated against the registry
# so an unknown id fails fast with the known set, before any backend work.
GIT_HOST="$(dce_git_host_default)"
if [[ -n "$GIT_HOST_INPUT" ]]; then
  if ! dce_git_host_is_known "$GIT_HOST_INPUT"; then
    dce_die "Unknown git host '$GIT_HOST_INPUT'.
  Known providers: $(dce_git_host_known_providers | tr '\n' ' ')"
  fi
  GIT_HOST="$GIT_HOST_INPUT"
fi
GIT_HOST_TOKEN_FILENAME="$(dce_git_host_field "$GIT_HOST" token_filename)"
GIT_HOST_SENTINEL="$(dce_git_host_field "$GIT_HOST" sentinel)"
GIT_HOST_DEPLOY_DOC="$(dce_git_host_field "$GIT_HOST" deploy_url_doc)"
# Display name for user-facing copy.
GIT_HOST_DISPLAY="$(dce_git_host_field "$GIT_HOST" display_name)"

dce_load_global_config

SAVE_RECIPE_LINES=()
if $SAVE_TEAM_RECIPE || $SAVE_USER_RECIPE; then
  if $CLI_SET_SCOPE; then
    SAVE_SCOPE_CSV="$(dce_normalize_scopes_csv "$CLI_SCOPE_INPUT")" || exit 1
    [[ -n "$SAVE_SCOPE_CSV" ]] && SAVE_RECIPE_LINES+=("scopes=$SAVE_SCOPE_CSV")
  fi

  if $CLI_SET_CPUS; then
    dce_validate_cpus_value "$CLI_CONTAINER_CPUS" || exit 1
    SAVE_RECIPE_LINES+=("cpus=$CLI_CONTAINER_CPUS")
  fi

  if $CLI_SET_MEMORY; then
    dce_validate_memory_value "$CLI_CONTAINER_MEMORY" || exit 1
    SAVE_RECIPE_LINES+=("memory=$CLI_CONTAINER_MEMORY")
  fi

  if $CLI_SET_HIDE; then
    SAVE_HIDE_CSV="$(dce_normalize_hidden_paths_values "${CLI_HIDDEN_PATH_INPUTS[@]:-}")" || exit 1
    if [[ -n "$SAVE_HIDE_CSV" ]]; then
      IFS=',' read -r -a SAVE_HIDE_VALUES <<< "$SAVE_HIDE_CSV"
      for SAVE_HIDE_PATH in "${SAVE_HIDE_VALUES[@]}"; do
        [[ -z "$SAVE_HIDE_PATH" ]] && continue
        SAVE_RECIPE_LINES+=("hide=$SAVE_HIDE_PATH")
      done
    fi
  fi

  if $CLI_SET_SYNC; then
    SAVE_RECIPE_LINES+=("sync=1")
  fi

  if $CLI_SET_SYNC_IGNORE; then
    SAVE_SYNC_IGNORE_CSV="$(dce_normalize_hidden_paths_values "${CLI_SYNC_IGNORE_INPUTS[@]:-}")" || exit 1
    if [[ -n "$SAVE_SYNC_IGNORE_CSV" ]]; then
      IFS=',' read -r -a SAVE_SYNC_IGNORE_VALUES <<< "$SAVE_SYNC_IGNORE_CSV"
      for SAVE_SYNC_IGNORE_PATH in "${SAVE_SYNC_IGNORE_VALUES[@]}"; do
        [[ -z "$SAVE_SYNC_IGNORE_PATH" ]] && continue
        SAVE_RECIPE_LINES+=("sync-ignore=$SAVE_SYNC_IGNORE_PATH")
      done
    fi
  fi

  if $CLI_SET_NETWORK; then
    SAVE_NETWORK_CSV="$(dce_normalize_network_arg "$CLI_NETWORK_INPUT")" || exit 1
    [[ -n "$SAVE_NETWORK_CSV" ]] && SAVE_RECIPE_LINES+=("network=$SAVE_NETWORK_CSV")
  fi

  if $CLI_SET_IP; then
    dce_validate_ip_value "$CLI_NETWORK_IP" || exit 1
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
        dce_die "Invalid port mapping '$SAVE_PORT_MAPPING'. Use host:container (e.g., 5173:5173)."
      fi
    done
  fi
fi

# Load an explicit recipe (--config) or magic-resolved team/user recipes by
# project name, then merge with CLI precedence (CLI values override recipe
# values; list keys replace as a whole when supplied on the CLI).
if ! dce_recipe_resolve_inputs "$PROJECT" "$RECIPE_CONFIG_PATH"; then
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
# Sync opt-in: a recipe can request --sync / --sync-ignore; CLI flags still win.
if ! $CLI_SET_SYNC && [[ "${_DC_RECIPE_MERGED_SYNC:-}" == "1" ]]; then
  SYNC_ENABLED=true
fi
if [[ ${#SYNC_IGNORE_INPUTS[@]} -eq 0 && ${#_DC_RECIPE_MERGED_SYNC_IGNORE_INPUTS[@]} -gt 0 ]]; then
  SYNC_IGNORE_INPUTS=("${_DC_RECIPE_MERGED_SYNC_IGNORE_INPUTS[@]}")
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

# Validate the MERGED (CLI + recipe) sync/hide state, not just parse-time CLI.
# This catches recipe+CLI combinations like recipe sync + CLI hide.
if $SYNC_ENABLED && [[ ${#HIDDEN_PATH_INPUTS[@]} -gt 0 ]]; then
  dce_die "--sync and --hide are mutually exclusive.
     Under --sync, exclude generated paths with --sync-ignore instead.
     Example: --sync --sync-ignore node_modules"
fi
if [[ ${#SYNC_IGNORE_INPUTS[@]} -gt 0 ]] && ! $SYNC_ENABLED; then
  dce_die "--sync-ignore only has meaning with --sync."
fi

# Fail fast on merged resource values before any backend work.
if [[ -n "${CONTAINER_CPUS:-}" ]]; then
  dce_validate_cpus_value "$CONTAINER_CPUS" || exit 1
fi
if [[ -n "${CONTAINER_MEMORY:-}" ]]; then
  dce_validate_memory_value "$CONTAINER_MEMORY" || exit 1
fi

COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"
if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  dce_die "Compose helper not found at $COMPOSE_SCRIPT"
fi

# 2. Resolve the derived image for these scopes (dce-base:latest when none).
SCOPE_CSV="$(dce_normalize_scopes_csv "$SCOPE_INPUT")" || exit 1
IMAGE="$(dce_image_ref_from_scopes "$(dce_team_overlays_dir)" "$(dce_user_overlays_dir)" "$SCOPE_CSV")" || exit 1

HIDDEN_PATHS_CSV="$(dce_normalize_hidden_paths_values "${HIDDEN_PATH_INPUTS[@]:-}")" || exit 1
CONTAINER_HIDDEN_PATHS=()
if [[ -n "$HIDDEN_PATHS_CSV" ]]; then
  IFS=',' read -r -a CONTAINER_HIDDEN_PATHS <<< "$HIDDEN_PATHS_CSV"
fi

# --sync-ignore reuses the --hide grammar (relative, traversal-free, comma list,
# repeatable, de-duplicated) but applies it as Mutagen --ignore rules on the one
# sync volume instead of separate dce-hide-* volumes.
SYNC_IGNORE_PATHS_CSV="$(dce_normalize_hidden_paths_values "${SYNC_IGNORE_INPUTS[@]:-}")" || exit 1
CONTAINER_SYNC_IGNORE_PATHS=()
if [[ -n "$SYNC_IGNORE_PATHS_CSV" ]]; then
  IFS=',' read -r -a CONTAINER_SYNC_IGNORE_PATHS <<< "$SYNC_IGNORE_PATHS_CSV"
fi

# Resolve the network membership requested via --network (with optional --ip on
# the primary). The result is a CONTAINER_NETWORKS array of `name[:ip]` entries;
# backend-existence and limit checks run later, once the backend is selected.
CONTAINER_NETWORKS=()
if [[ -n "$NETWORK_INPUT" ]]; then
  NETWORKS_CSV="$(dce_normalize_network_arg "$NETWORK_INPUT")" || exit 1
  if [[ -n "$NETWORKS_CSV" ]]; then
    IFS=',' read -r -a CONTAINER_NETWORKS <<< "$NETWORKS_CSV"
  fi
fi
if [[ -n "$NETWORK_IP" ]]; then
  dce_validate_ip_value "$NETWORK_IP" || exit 1
  if [[ ${#CONTAINER_NETWORKS[@]} -eq 0 ]]; then
    dce_die "--ip requires --network (no networks requested)."
  fi
  primary="${CONTAINER_NETWORKS[0]}"
  if [[ "$primary" == *:* ]]; then
    dce_die "--ip conflicts with an explicit IP on the primary network ('$primary').
       Use either --ip <addr> or the 'name:ip' syntax, not both."
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
    dce_die "Invalid port mapping '$port_mapping'. Use host:container (e.g., 5173:5173)."
  fi
done

SECRET_DIR="$HOME/.config/dce-enclave/$PROJECT"
CONFIG_FILE="$HOME/.config/dce-enclave/$PROJECT/config"
# shellcheck disable=SC2088
# Display path shown to the user with a literal ~; not meant to expand.
CONFIG_FILE_DISPLAY="~/.config/dce-enclave/$PROJECT/config"

if [[ -f "$CONFIG_FILE" ]]; then
  dce_die "Project '$PROJECT' already exists (config: $CONFIG_FILE_DISPLAY)
Choose a different name or remove the existing project config."
fi

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"
DOCKER_COMPATIBLE=false
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  DOCKER_COMPATIBLE=true
fi

# --sync fail-fast gate (before any volume/container is created):
#   - apple/container: no Mutagen transport at all.
#   - podman: Mutagen has no podman transport; the docker-transport bridge to a
#     podman-machine VM is blocked by SSH host-key verification.
#   - docker/orbstack/colima require the host-side mutagen daemon.
if $SYNC_ENABLED; then
  if ! dce_sync_backend_supported "$ACTIVE_BACKEND"; then
    dce_die "$(dce_sync_unsupported_message "$ACTIVE_BACKEND")"
  fi
  if ! dce_mutagen_present; then
    dce_die "$(dce_mutagen_absent_message)"
  fi
fi

if ! backend_image_exists "dce-base:latest"; then
  dce_die "Base image 'dce-base:latest' not found on backend '$ACTIVE_BACKEND'.
  Run setup first: CONTAINER_BACKEND=$ACTIVE_BACKEND scripts/setup.sh"
fi

if backend_exists "$PROJECT"; then
  dce_die "Container '$PROJECT' already exists.
To rebuild: dce rebuild-container $PROJECT"
fi

# Validate the requested network membership against the selected backend: enforce
# apple's single-network/no-static-IP limits, and require every network to exist
# (networks are created explicitly via `dce network create`). Then derive the
# create-time args; extras are attached after the container exists.
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  if ! dce_network_check_backend_limits "$ACTIVE_BACKEND" "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
  if ! dce_networks_ensure_exist "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
fi
NETWORK_ARGS=()
if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  mapfile -t NETWORK_ARGS < <(dce_networks_create_args "${CONTAINER_NETWORKS[@]}")
fi

# -----------------------------------------------------------------------------
# repo-path safety gate
#
# `repo-path` selects the host directory bind-mounted read-write as /workspace.
# CLI `--repo-path` is an intentional power-user escape hatch (unrestricted);
# an auto-loaded (untrusted) recipe supplying `repo-path` is NOT -- it must not
# silently widen the mount. Two layers run BEFORE the container is created:
#
#   1. Character whitelist (any source): a value containing characters unsafe
#      in a bind-mount source (`:` breaks the `--volume src:dst` spec; shell
#      metacharacters, control chars, and quotes are refused too) is rejected
#      outright, before anything is created. This guards mount-spec integrity,
#      not the trust boundary, so it applies to CLI and recipe alike.
#   2. Sensitive-root + confirmation gate (recipe source only): after the target
#      is created and resolved to its CANONICAL form (symlinks followed), a
#      recipe repo-path that resolves to /, $HOME, the repos root, or a parent
#      of it is hard-rejected; one that merely lands OUTSIDE the default repos
#      dir is gated behind an operator confirmation (--yes/-y honors it with a
#      visible notice). Canonical resolution is essential here: a symlink can
#      make a path look inside the repos root lexically while actually pointing
#      at $HOME, so the lexical view alone is not a sound trust boundary. CLI
#      --repo-path skips this layer entirely (escape hatch).
# -----------------------------------------------------------------------------

# Expand a leading ~ to $HOME (literal-char match, not shell expansion), so a
# value like '~/repos' or '~' behaves the same whether it came from a recipe, the
# CLI, or $DC_REPOS_DIR. Delegates to dce_expand_tilde (tilde-only: relative
# paths are left untouched, since repo paths are resolved against $REPOS_DIR
# elsewhere, not the config dir).
_dce_new_repo_path_expand_tilde() {  # <path>
  dce_expand_tilde "$1"
}

# Return 0 (true) if the value contains any character outside the path-safe
# whitelist. Allowed: alphanumerics and  / . _ - ~ + @ , and space. Everything
# else ($ ` ; | & ( ) < > \ ! ' " : control chars ...) is rejected, since a
# bind-mount source must never risk confusing the `--volume src:dst` spec or
# downstream tooling.
_dce_new_repo_path_chars_unsafe() {  # <value>
  local v="$1"
  # The bracket-expression CONTENTS (no outer []); wrapped below so the variable
  # is not double-bracketed. Kept unquoted in the =~ so it is treated as a
  # character class, not a literal string.
  local _safe='[:alnum:]/._~+@, -'
  [[ "$v" =~ [^$_safe] ]]
}

# Return 0 (true) when an already-canonicalized mount source is too broad to
# expose: empty, the host root (/), the user's home, the repos root, or an
# ancestor of it. Recipe-sourced only -- the CLI --repo-path escape hatch is
# intentionally unrestricted.
_dce_new_repo_path_is_sensitive_root() {  # <resolved> <home> <repos_root>
  local resolved="$1" home="$2" root="$3"
  if [[ -z "$resolved" || "$resolved" == "/" ]]; then
    return 0
  fi
  if [[ "$resolved" == "$home" ]]; then
    return 0
  fi
  # resolved is the repos root or an ancestor of it (repos root is under it):
  # mounting it would expose sibling projects / the repos root itself.
  if [[ "$root" == "$resolved" || "$root" == "$resolved/"* ]]; then
    return 0
  fi
  return 1
}

if [[ -n "$REPO_PATH_OVERRIDE" ]]; then
  repo_target="$REPO_PATH_OVERRIDE"
else
  repo_target="$(_dce_new_repo_path_expand_tilde "${DC_REPOS_DIR:-$HOME/repos}")/$PROJECT"
fi
repo_target="$(_dce_new_repo_path_expand_tilde "$repo_target")"
if [[ "$repo_target" != /* ]]; then
  repo_target="$PWD/$repo_target"
fi

# Layer 1: character whitelist (any source), before anything is created. A value
# with characters unsafe for a bind-mount source (`:` splits the mount spec, etc.)
# is refused regardless of whether it came from the CLI or a recipe.
if _dce_new_repo_path_chars_unsafe "$repo_target"; then
  _new_repo_err="repo-path contains characters that are unsafe for a bind-mount source: $repo_target
       (Allowed: letters, digits, and  / . _ - ~ + @ , and space.)"
  if [[ -n "$REPO_PATH_OVERRIDE" && "$CLI_SET_REPO_PATH" == true ]]; then
    _new_repo_err+="
       (--repo-path was: $REPO_PATH_OVERRIDE)"
  elif [[ -n "$REPO_PATH_OVERRIDE" ]]; then
    _new_repo_err+="
       (recipe repo-path was: $REPO_PATH_OVERRIDE)"
  fi
  dce_die "$_new_repo_err"
fi

mkdir -p "$repo_target"
REPOS_DIR="$(dce_resolve_path "$repo_target")" || {
  if [[ -n "$REPO_PATH_OVERRIDE" ]]; then
    dce_die "--repo-path could not be resolved: $REPO_PATH_OVERRIDE"
  else
    dce_die "Default repo path could not be resolved: $repo_target"
  fi
}

# Canonical anchors (symlinks resolved) so the trust boundary reasons about where
# the mount will REALLY land, not where it appears to land lexically. A symlink
# can redirect an inside-repos-root path to $HOME or /; only the canonical form
# closes that hole.
HOME_CANON="$(dce_resolve_path "$HOME")"
DEFAULT_REPOS_ROOT_CANON="$(_dce_new_repo_path_expand_tilde "${DC_REPOS_DIR:-$HOME/repos}")"
DEFAULT_REPOS_ROOT_CANON="$(dce_resolve_path "$DEFAULT_REPOS_ROOT_CANON" 2>/dev/null || printf '%s' "$DEFAULT_REPOS_ROOT_CANON")"

# Layer 2: recipe-sourced repo-path only. CLI --repo-path is the escape hatch and
# skips this layer entirely.
if [[ -n "$REPO_PATH_OVERRIDE" && "$CLI_SET_REPO_PATH" != true ]]; then
  if _dce_new_repo_path_is_sensitive_root "$REPOS_DIR" "$HOME_CANON" "$DEFAULT_REPOS_ROOT_CANON"; then
    dce_die "recipe repo-path resolves to '$REPOS_DIR', a sensitive root
       (/, your home, the repos root, or a parent of it); refusing to widen the bind mount.
       (recipe repo-path was: $REPO_PATH_OVERRIDE)"
  fi
  # A RELATIVE recipe repo-path must resolve UNDER the repos root. One whose
  # `..` escapes it is unambiguous traversal and is hard-rejected -- NOT routed
  # to the confirmation path. Without this the verdict depends on $PWD depth: a
  # deep CWD (e.g. CI) resolves `../../..` to a non-sensitive intermediate dir
  # that slips past the sensitive-root check into the outside-default flow,
  # which `exit 0`s on decline. Legit outside-default usage is absolute, so it
  # still reaches the confirmation below untouched.
  if [[ "$REPO_PATH_OVERRIDE" != /* ]] \
     && [[ "$REPOS_DIR" != "$DEFAULT_REPOS_ROOT_CANON" && "$REPOS_DIR" != "$DEFAULT_REPOS_ROOT_CANON/"* ]]; then
    dce_die "recipe repo-path '$REPO_PATH_OVERRIDE' resolves outside the repos root ('$REPOS_DIR') via a relative path; refusing to widen the bind mount."
  fi
  if [[ "$REPOS_DIR" != "$DEFAULT_REPOS_ROOT_CANON" && "$REPOS_DIR" != "$DEFAULT_REPOS_ROOT_CANON/"* ]]; then
    echo "Recipe 'repo-path' resolves outside the default repos directory:"
    echo "  resolved path : $REPOS_DIR"
    echo "  default root  : $DEFAULT_REPOS_ROOT_CANON"
    if $ASSUME_YES; then
      echo "(--yes: honoring recipe repo-path; it will be mounted read-write as /workspace.)"
    else
      echo "Mounting it read-write as /workspace requires confirmation."
      read -r -p "Type 'yes' to continue: " _repo_path_confirm || _repo_path_confirm=""
      if [[ "$_repo_path_confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
      fi
    fi
  fi
fi

COMPOSED_CONTAINERFILE=""
DEVCONTAINER_BUILD_FILE="$ROOT_DIR/Containerfiles/Containerfile.base"

# If scopes select a derived image, compose+build it once (reuse if present).
if [[ "$IMAGE" != "dce-base:latest" ]]; then
  IMAGE_HASH="$(dce_image_hash_from_ref "$IMAGE")" || {
    dce_die "Could not derive image hash from image ref: $IMAGE"
  }

  COMPOSED_CONTAINERFILE="$ROOT_DIR/Containerfiles/generated/Containerfile.${IMAGE_HASH}"
  DEVCONTAINER_BUILD_FILE="$COMPOSED_CONTAINERFILE"

  # dce-base image Id feeds the provenance base.id label (best-effort, may be
  # empty if the backend cannot resolve it).
  PROV_BASE_ID="$(backend_image_id "dce-base:latest")"

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
  # still gets an entry so `dce provenance <project>` is populated.
  dce_log_provenance "$PROJECT" "$IMAGE" "new" "$DC_TEAM_DIR" "$DC_USER_DIR" "$SCOPE_CSV" "$PROV_BASE_ID"
fi

# Detect the host timezone once so the container mirrors the developer's local
# time (per-developer at create time, never baked into the shared image). Empty
# means no clean zone was found; we then omit --env TZ and leave the image
# default untouched. The result feeds both the create flag and devcontainer.json.
HOST_TZ="$(dce_host_timezone)" || HOST_TZ=""
TZ_ARGS=()
if [[ -n "$HOST_TZ" ]]; then
  TZ_ARGS+=(--env "TZ=$HOST_TZ")
fi

# Workspace-type env: baked at create so the in-container shell-rc banner is
# correct even before the sync volume is populated, and survives mid-reconcile.
# Precedes the volume group (env is fundamental), keeping new/rebuild parity.
WORKSPACE_TYPE_ARGS=(--env "DCE_WORKSPACE_TYPE=bind")
if $SYNC_ENABLED; then
  WORKSPACE_TYPE_ARGS=(--env "DCE_WORKSPACE_TYPE=sync")
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
if $SYNC_ENABLED; then
  echo "Workspace: synced (mutagen, host canonical) -> $REPOS_DIR"
  if [[ ${#CONTAINER_SYNC_IGNORE_PATHS[@]} -gt 0 ]]; then
    echo "Sync-ignore: ${CONTAINER_SYNC_IGNORE_PATHS[*]}"
  fi
elif [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
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
  ssh-keygen -t ed25519 -f "$SSH_KEY" -C "dce-container-${PROJECT}" -N "" -q
  chmod 600 "$SSH_KEY"
fi
echo ""
echo "✓ SSH deploy key: $SSH_KEY"
echo ""
echo "  Add this public key to ${GIT_HOST_DISPLAY} Deploy Keys (write access):"
echo "  https://${GIT_HOST_DEPLOY_DOC}"
echo ""
cat "${SSH_KEY}.pub"
echo ""

TOKEN_FILE="$SECRET_DIR/${GIT_HOST_TOKEN_FILENAME}"
if [[ ! -f "$TOKEN_FILE" ]]; then
  {
    echo "# ${GIT_HOST_DISPLAY} Personal Access Token for container: $PROJECT"
    echo "# Scope: repository contents read/write (fine-grained preferred; no admin)"
    echo "# Replace this line with your token:"
    echo "${GIT_HOST_SENTINEL}"
  } > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
echo "✓ ${GIT_HOST_DISPLAY} token placeholder: $TOKEN_FILE"
echo "  !! Edit this file and replace ${GIT_HOST_SENTINEL} with your token"

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
# through dce_load_project_config without executing command substitution.
esc_project="$(dce_escape_config_value "$PROJECT")" || exit 1
esc_scopes="$(dce_escape_config_value "$SCOPE_CSV")" || exit 1
esc_image="$(dce_escape_config_value "$IMAGE")" || exit 1
esc_backend="$(dce_escape_config_value "$ACTIVE_BACKEND")" || exit 1
esc_cpus="$(dce_escape_config_value "${CONTAINER_CPUS:-}")" || exit 1
esc_memory="$(dce_escape_config_value "${CONTAINER_MEMORY:-}")" || exit 1
esc_repos="$(dce_escape_config_value "$REPOS_DIR")" || exit 1
esc_secret="$(dce_escape_config_value "$SECRET_DIR")" || exit 1
esc_ssh="$(dce_escape_config_value "$SECRET_DIR/ssh_key")" || exit 1
esc_token="$(dce_escape_config_value "$SECRET_DIR/${GIT_HOST_TOKEN_FILENAME}")" || exit 1
esc_npmrc="$(dce_escape_config_value "$SECRET_DIR/.npmrc")" || exit 1
esc_git_host="$(dce_escape_config_value "$GIT_HOST")" || exit 1

cat > "$CONFIG_FILE" <<EOF
# DC Enclave config for: $PROJECT
# Generated: $(date)
CONTAINER_PROJECT="$esc_project"
CONTAINER_OVERLAY_SCOPES="$esc_scopes"
CONTAINER_IMAGE="$esc_image"
CONTAINER_BACKEND="$esc_backend"
CONTAINER_GIT_HOST="$esc_git_host"
CONTAINER_CPUS="$esc_cpus"
CONTAINER_MEMORY="$esc_memory"
REPOS_DIR="$esc_repos"
SECRET_DIR="$esc_secret"
SSH_KEY_PATH="$esc_ssh"
TOKEN_FILE="$esc_token"
NPMRC_PATH="$esc_npmrc"
CONTAINER_SYNC="$([ "$SYNC_ENABLED" == "true" ] && printf '1' || printf '0')"
EOF

if [[ ${#PORTS[@]} -gt 0 ]]; then
  { printf 'PORTS=('; printf '%q ' "${PORTS[@]}"; printf ')\n'; } >> "$CONFIG_FILE"
else
  echo "PORTS=()" >> "$CONFIG_FILE"
fi

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  { printf 'CONTAINER_HIDDEN_PATHS=('; printf '%q ' "${CONTAINER_HIDDEN_PATHS[@]}"; printf ')\n'; } >> "$CONFIG_FILE"
else
  echo "CONTAINER_HIDDEN_PATHS=()" >> "$CONFIG_FILE"
fi

if [[ ${#CONTAINER_SYNC_IGNORE_PATHS[@]} -gt 0 ]]; then
  { printf 'CONTAINER_SYNC_IGNORE_PATHS=('; printf '%q ' "${CONTAINER_SYNC_IGNORE_PATHS[@]}"; printf ')\n'; } >> "$CONFIG_FILE"
else
  echo "CONTAINER_SYNC_IGNORE_PATHS=()" >> "$CONFIG_FILE"
fi

if [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
  { printf 'CONTAINER_NETWORKS=('; printf '%q ' "${CONTAINER_NETWORKS[@]}"; printf ')\n'; } >> "$CONFIG_FILE"
else
  echo "CONTAINER_NETWORKS=()" >> "$CONFIG_FILE"
fi

# Owner-only permissions: the config holds secret paths and is a trusted input to
# later loads, so it must never be group/other-writable (the loader rejects that).
chmod 600 "$CONFIG_FILE"

echo "✓ Config saved: $CONFIG_FILE"

if $SAVE_TEAM_RECIPE; then
  TEAM_RECIPE_FILE="$(dce_team_recipes_dir)/$PROJECT"
  if ! dce_recipe_write_file "$TEAM_RECIPE_FILE" "${SAVE_RECIPE_LINES[@]}"; then
    exit 1
  fi
  echo "✓ Team recipe saved: $TEAM_RECIPE_FILE"
fi

if $SAVE_USER_RECIPE; then
  USER_RECIPE_FILE="$(dce_user_recipes_dir)/$PROJECT"
  if ! dce_recipe_write_file "$USER_RECIPE_FILE" "${SAVE_RECIPE_LINES[@]}"; then
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

# Mount flags. Default: workspace bind mount + read-only .npmrc + one hidden
# volume per --hide path. Under --sync the workspace bind mount is replaced by
# the dce-sync-<slug>-<12hex> named volume (Mutagen-populated, host-canonical) mounted
# at the SAME /workspace path; --hide is mutually exclusive so no hidden mounts.
VOLUME_ARGS=(--volume "$REPOS_DIR:/workspace")
if $SYNC_ENABLED; then
  VOLUME_ARGS=(--volume "$(dce_sync_volume_name "$PROJECT"):/workspace")
fi
VOLUME_ARGS+=(--volume "$SECRET_DIR/.npmrc:/home/dev/.npmrc:ro")
for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
  hidden_volume="$(dce_hidden_volume_name "$PROJECT" "$hidden_path")"
  VOLUME_ARGS+=(--volume "$hidden_volume:/workspace/$hidden_path")
done

echo ""
echo "==> Creating container from image: $IMAGE"
backend_create "$PROJECT" "$IMAGE" "${TZ_ARGS[@]}" "${WORKSPACE_TYPE_ARGS[@]}" "${VOLUME_ARGS[@]}" "${PORT_ARGS[@]}" "${RESOURCE_ARGS[@]}" "${NETWORK_ARGS[@]}"

# Attach any networks beyond the primary (Docker-compatible backends). On apple
# the limits check already restricted membership to a single primary network.
if [[ ${#CONTAINER_NETWORKS[@]} -gt 1 ]]; then
  echo "==> Attaching additional networks..."
  if ! dce_networks_attach_extras "$PROJECT" "${CONTAINER_NETWORKS[@]}"; then
    exit 1
  fi
fi

echo ""
echo "==> Starting container for initial SSH key injection..."
backend_start "$PROJECT"
sleep 2

if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "==> Verifying hidden volume mounts..."
  if ! dce_ensure_hidden_mounts "$PROJECT" "${CONTAINER_HIDDEN_PATHS[@]}"; then
    exit 1
  fi
  echo "  ✓ Hidden volume mounts active"

  echo "==> Normalizing hidden-path ownership..."
  for hidden_path in "${CONTAINER_HIDDEN_PATHS[@]}"; do
    target="/workspace/$hidden_path"
    backend_exec_as_root "$PROJECT" sh -lc "mkdir -p '$target' && chown -R dev:dev '$target'"
    if ! backend_exec "$PROJECT" sh -lc "test -w '$target'"; then
      dce_die "Hidden path is not writable by dev: $target"
    fi
  done
fi

# Under --sync: create the host-canonical Mutagen session (alpha=host $REPOS_DIR,
# beta=the dce-sync volume mounted at /workspace) with the derived --sync-ignore
# patterns and dev-coerced ownership. The first create does a full host->volume
# copy (minus ignored paths); for a large repo this is minutes, not seconds, so
# the progress is surfaced. Then ensure sync-ignored empty dirs are dev-owned so
# the install-on-start hook (running as dev) can populate them.
if $SYNC_ENABLED; then
  echo "==> Creating Mutagen sync session (host -> $PROJECT:/workspace)..."
  echo "    Initial copy of $REPOS_DIR may take a while for a large repo."
  # Wait until the container accepts exec before Mutagen probes it. The
  # post-start sleep above is enough on fast hosts with the base image, but a
  # heavier derived image on a slow backend (notably WSL2's dockerd, still
  # settling right after building the image) may not be probeable yet, and
  # Mutagen then fails with "unable to probe container: container not running".
  # Polling backend_exec is the faithful signal: Mutagen deploys its agent via
  # `docker exec`, so once exec succeeds Mutagen will too. Fast hosts exit on the
  # first probe; slow hosts get up to the cap.
  _sync_ready=0
  until backend_exec "$PROJECT" sh -lc 'true' >/dev/null 2>&1; do
    if (( _sync_ready >= 30 )); then
      dce_die "Container '$PROJECT' did not reach an exec-ready state; cannot start Mutagen sync.
  Inspect: $(backend_cli) ps -a | grep '$PROJECT'
  Logs:   dce logs $PROJECT"
    fi
    _sync_ready=$((_sync_ready + 1))
    sleep 1
  done
  # The dce-sync named volume mounts at /workspace. Most backends inherit dev
  # ownership from the image there, but docker under WSL2 brings the volume up
  # root:root -- so the Mutagen beta agent (which runs as dev) cannot write into
  # it and every alpha->beta transition fails. `mutagen sync list` then reports
  # "Transition problems" and host->container reconciliation never settles. chown
  # the sync root to dev BEFORE Mutagen does its initial copy. No-op on backends
  # where it is already dev-owned.
  backend_exec_as_root "$PROJECT" sh -lc 'chown dev:dev /workspace 2>/dev/null || true'
  if ! dce_sync_create "$PROJECT" "$REPOS_DIR" "${CONTAINER_SYNC_IGNORE_PATHS[@]:-}"; then
    dce_die "Mutagen sync session creation failed for '$PROJECT'.
  See: mutagen sync list
  Docs: docs/how-to/sync-workspace.md"
  fi
  echo "  ✓ Sync session active (host is canonical; two-way reconciliation)"
  if [[ ${#CONTAINER_SYNC_IGNORE_PATHS[@]} -gt 0 ]]; then
    echo "==> Normalizing sync-ignore path ownership..."
    for sync_ignored in "${CONTAINER_SYNC_IGNORE_PATHS[@]}"; do
      [[ -z "$sync_ignored" ]] && continue
      target="/workspace/$sync_ignored"
      backend_exec_as_root "$PROJECT" sh -lc "mkdir -p '$target' && chown -R dev:dev '$target' 2>/dev/null || true"
    done
  fi
fi

# Expose SSH_KEY_PATH / CONTAINER_GIT_HOST so the inject + git-auth helpers read
# through the same env the persisted config will use. At `dce new` time the
# token is still the placeholder, so dce_ensure_git_credentials resolves to the
# SSH insteadOf; it flips to HTTPS+PAT once the user fills the token.
# Exported because the consumers are the sourced lib helpers, not this file.
export SSH_KEY_PATH="$SSH_KEY"
export CONTAINER_GIT_HOST="$GIT_HOST"

echo "==> Injecting SSH deploy key..."
dce_inject_ssh_deploy_key "$PROJECT"

echo "==> Configuring git in container..."
dce_ensure_git_credentials "$PROJECT"

if $DOCKER_COMPATIBLE; then
  echo "==> Generating Dev Containers config for Docker-compatible backend..."
  # Docker-compatible: write a .devcontainer/devcontainer.json so VS Code Dev
  # Containers can build/attach the same recipe (existing file is preserved).
  DEVCONTAINER_DIR="$REPOS_DIR/.devcontainer"
  DEVCONTAINER_FILE="$DEVCONTAINER_DIR/devcontainer.json"

  if [[ -f "$DEVCONTAINER_FILE" ]]; then
    echo "  ✓ $DEVCONTAINER_FILE already exists - not overwritten."
    echo "  Update it manually, or reconcile it with:"
    echo "    dce config sync-vscode $PROJECT"
    echo "  (Containerfile for this recipe: $DEVCONTAINER_BUILD_FILE)"
    # Read-only drift notice: if the managed fields in the existing file no
    # longer match what `dce new` would generate, point the operator at the diff
    # and the sync command. Non-fatal; safe under --yes / non-interactive use.
    _new_nets_csv=""
    [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]] && _new_nets_csv="$(dce_join_by ',' "${CONTAINER_NETWORKS[@]}")"
    _new_ports_csv=""
    [[ ${#PORTS[@]} -gt 0 ]] && _new_ports_csv="$(dce_join_by ',' "${PORTS[@]}")"
    # Resolve the extension adoption state so declaration drift is reported for
    # adopted projects (manifests_exist) and suppressed pre-adoption (migration
    # guard). Mirrors the seeding resolution in the else-branch below.
    _new_ext_csv=""
    _new_ext_adopted="false"
    if dce_ext_manifests_exist vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" 2>/dev/null; then
      _new_ext_adopted="true"
      _new_ext_csv="$(dce_ext_resolve_csv vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" 2>/dev/null)"
    fi
    dce_devcontainer_detect_drift "$PROJECT" "$DEVCONTAINER_FILE" "$DEVCONTAINER_BUILD_FILE" \
      "$HIDDEN_PATHS_CSV" "$_new_nets_csv" "$_new_ports_csv" \
      "vscode" "$_new_ext_csv" "$_new_ext_adopted" >&2 || true
  else
    mkdir -p "$DEVCONTAINER_DIR"

    _new_nets_csv=""
    [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]] && _new_nets_csv="$(dce_join_by ',' "${CONTAINER_NETWORKS[@]}")"
    _new_ports_csv=""
    [[ ${#PORTS[@]} -gt 0 ]] && _new_ports_csv="$(dce_join_by ',' "${PORTS[@]}")"

    # Resolve the editor-extensions set for this project's scopes (vscode in v1)
    # so the seeded devcontainer.json carries customizations.vscode.extensions
    # and VS Code auto-installs them on first open (plans/extensions.md). Global
    # config (team/user roots) was loaded above for scope/image derivation.
    _new_ext_csv=""
    if dce_ext_manifests_exist vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" 2>/dev/null; then
      _new_ext_csv="$(dce_ext_resolve_csv vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" 2>/dev/null)"
    fi

    # The seeded JSON is produced by the single shared renderer so `dce new`,
    # drift detection, and `dce config sync-vscode` all agree on managed state.
    # Pass the current git auth method so the renderer can emit the VS Code
    # git-auth override only when a PAT is configured (see dce_devcontainer_render).
    dce_devcontainer_render "$PROJECT" "$DEVCONTAINER_BUILD_FILE" "$ROOT_DIR" \
      "$SECRET_DIR" "$HIDDEN_PATHS_CSV" "$_new_nets_csv" "$_new_ports_csv" "$HOST_TZ" \
      "$(dce_git_auth_method)" "vscode" "$_new_ext_csv" \
      > "$DEVCONTAINER_FILE"

    echo "  ✓ Created $DEVCONTAINER_FILE"
    echo "  To attach VS Code to the running '$PROJECT' container:"
    echo "    Dev Containers: Attach to Running Container..."
    echo "  (Do not use 'Reopen in Container' — it builds a separate editor container; see README.)"
  fi

  echo "==> Seeding VS Code named attach config..."
  ATTACH_CONFIG_COUNT=0
  while IFS= read -r attach_config_file; do
    [[ -z "$attach_config_file" ]] && continue
    ATTACH_CONFIG_COUNT=$((ATTACH_CONFIG_COUNT + 1))
    echo "  ✓ $attach_config_file"
  done < <(dce_vscode_seed_named_attach_config "$PROJECT" "/workspace")

  if [[ "$ATTACH_CONFIG_COUNT" -eq 0 ]]; then
    echo "  (No VS Code user storage found; config will be created after first VS Code attach.)"
  fi
else
  echo "==> Generating VS Code workspace settings for apple/container backend..."
  # apple/container has no Dev Containers extension; route VS Code terminals
  # through `dce shell` via a terminal profile instead.
  VSCODE_DIR="$REPOS_DIR/.vscode"
  VSCODE_SETTINGS="$VSCODE_DIR/settings.json"
  mkdir -p "$VSCODE_DIR"

  if [[ ! -f "$VSCODE_SETTINGS" ]]; then
    cat > "$VSCODE_SETTINGS" <<EOF
{
  "terminal.integrated.defaultProfile.osx": "dce-container",
  "terminal.integrated.profiles.osx": {
    "dce-container": {
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
    echo '    "terminal.integrated.defaultProfile.osx": "dce-container"'
    echo "    \"terminal.integrated.profiles.osx\": { \"dce-container\": { \"path\": \"/bin/zsh\", \"args\": [\"-c\", \"$ROOT_DIR/scripts/shell.sh $PROJECT\"] } }"
  fi
fi

echo ""
echo "======================================================================"
echo "Container '$PROJECT' created and started."
echo "======================================================================"
echo ""
echo "Config: ~/.config/dce-enclave/$PROJECT/"
echo "  [ ] ${GIT_HOST_TOKEN_FILENAME}   Replace ${GIT_HOST_SENTINEL} with your ${GIT_HOST_DISPLAY} token"
echo "  [ ] ssh_key.pub    Add as ${GIT_HOST_DISPLAY} Deploy Key for your repos"
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
echo "  dce shell $PROJECT"
echo "  dce stop $PROJECT"
echo "  dce start $PROJECT"
echo "  dce status"
