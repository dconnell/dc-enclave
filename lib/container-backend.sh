#!/usr/bin/env bash
# =============================================================================
# lib/container-backend.sh - Single abstraction over five container runtimes.
#
# Exposes a stable `backend_*` API (build/create/start/exec/volumes/...) that
# dispatches to the right CLI for the active backend:
#
#   apple   -> `container` (apple/container)   macOS only, distinct CLI shape
#   docker  -> `docker`
#   orbstack-> `docker` (OrbStack Docker context)
#   colima  -> `docker` (Colima, requires Docker runtime + Colima context)
#   podman  -> `podman`
#
# docker/orbstack/colima/podman all share the Docker CLI, so most operations
# collapse to one branch; apple/container diverges and gets per-op fallbacks.
# Selection is memoized in DEV_CONTAINERS_BACKEND / _DC_CLI after backend_use().
# =============================================================================

# Auto-source common.sh if this lib is loaded directly (keeps a single import).
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_backend_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_backend_lib_dir/common.sh"
  unset _dce_backend_lib_dir
fi

if [[ -n "${_DC_BACKEND_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKEND_SH_LOADED=1

# Memoized backend selection and CLI/exec state (populated by backend_use).
declare -g DEV_CONTAINERS_BACKEND="${DEV_CONTAINERS_BACKEND:-}"
declare -g _DC_CLI=""
declare -g _DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
declare -g _DC_PODMAN_HOST_GATEWAY_WARNED=0

# Canonicalize a backend name from its common aliases; fails on unknown input.
_backend_normalize() {
  local raw="${1:-}"
  local value="${raw,,}"

  case "$value" in
    "")
      return 1
      ;;
    apple|container|apple-container)
      printf '%s\n' "apple"
      ;;
    docker|docker-desktop)
      printf '%s\n' "docker"
      ;;
    orbstack|orb)
      printf '%s\n' "orbstack"
      ;;
    colima)
      printf '%s\n' "colima"
      ;;
    podman|podman-desktop)
      printf '%s\n' "podman"
      ;;
    *)
      return 1
      ;;
  esac
}

# Return whether the selected backend's CLI binary is on PATH.
_backend_cli_available() {
  local backend="$1"

  case "$backend" in
    apple)
      command -v container >/dev/null 2>&1
      ;;
    docker|orbstack)
      command -v docker >/dev/null 2>&1
      ;;
    colima)
      _backend_colima_cli_available && command -v docker >/dev/null 2>&1
      ;;
    podman)
      command -v podman >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# Colima needs both its own CLI and the docker CLI (it drives docker).
_backend_colima_cli_available() {
  command -v colima >/dev/null 2>&1
}

# Name of the Docker CLI's currently active context (Docker CLI concept, not ours).
_backend_docker_context_name() {
  docker context show 2>/dev/null || true
}

# Resolve the docker host endpoint URL for a given context name.
_backend_docker_context_host() {
  local context="$1"
  docker context inspect "$context" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || true
}

# True if the context name itself indicates OrbStack.
_backend_context_is_orbstack() {
  local context="$1"
  [[ "${context,,}" == *"orbstack"* ]]
}

# True if a Docker context points at Colima - by name, or by a host URL that
# references the Colima socket path (handles unnamed/renamed contexts).
_backend_context_is_colima() {
  local context="$1"
  local context_lower="${context,,}"

  if [[ "$context_lower" == *"colima"* ]]; then
    return 0
  fi

  if [[ -z "$context" ]]; then
    return 1
  fi

  local docker_host=""
  docker_host="$(_backend_docker_context_host "$context")"
  docker_host="${docker_host,,}"

  [[ "$docker_host" == *"/.colima/"* || "$docker_host" == *"colima"* ]]
}

# True if a Colima context is currently the active Docker context.
_backend_colima_context_active() {
  local context=""
  context="$(_backend_docker_context_name)"
  _backend_context_is_colima "$context"
}

# Locate an OrbStack Docker context and pin it via DOCKER_CONTEXT, or fail.
# OrbStack is indistinguishable from plain docker without an explicit context.
_backend_use_orbstack_context() {
  local ctx
  ctx="$(docker context ls --format '{{.Name}}' 2>/dev/null \
    | awk 'tolower($0) ~ /orbstack/ {print; exit}')"
  if [[ -z "$ctx" ]]; then
    echo "ERROR: OrbStack backend requires an OrbStack Docker context." >&2
    echo "  Install OrbStack or create a Docker context pointing to it." >&2
    return 1
  fi
  export DOCKER_CONTEXT="$ctx"
}

# Locate a Colima Docker context and pin it via DOCKER_CONTEXT, or fail.
_backend_use_colima_context() {
  local ctx
  ctx="$(docker context ls --format '{{.Name}}' 2>/dev/null \
    | awk 'tolower($0) ~ /colima/ {print; exit}')"
  if [[ -z "$ctx" ]]; then
    echo "ERROR: Colima backend requires a Colima Docker context." >&2
    echo "  Run: colima start" >&2
    echo "  Or: docker context use colima" >&2
    return 1
  fi
  export DOCKER_CONTEXT="$ctx"
}

# Read Colima's active runtime (docker/containerd/...) from `colima status`.
_backend_colima_runtime() {
  local status=""
  status="$(colima status 2>/dev/null || true)"
  [[ -n "$status" ]] || return 1

  local runtime=""
  runtime="$(printf '%s\n' "$status" | awk -F':' '
    tolower($1) ~ /runtime/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print tolower(value)
      exit
    }
  ')"

  [[ -n "$runtime" ]] || return 1
  printf '%s\n' "$runtime"
}

# Auto-detect the backend when CONTAINER_BACKEND is unset.
#
# Detection order matters: the active Docker context is inspected first so
# OrbStack and Colima (which both use the docker CLI) are identified before a
# generic docker fallback, then apple/container, docker, and podman by CLI.
_backend_detect_auto() {
  local docker_context=""

  if command -v docker >/dev/null 2>&1; then
    docker_context="$(_backend_docker_context_name)"
    if _backend_context_is_orbstack "$docker_context"; then
      printf '%s\n' "orbstack"
      return 0
    fi

    if _backend_context_is_colima "$docker_context"; then
      printf '%s\n' "colima"
      return 0
    fi
  fi

  if command -v container >/dev/null 2>&1; then
    printf '%s\n' "apple"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    printf '%s\n' "podman"
    return 0
  fi

  echo "ERROR: No supported container backend found." >&2
  echo "  Install apple/container, Docker Desktop, OrbStack, Colima, or Podman." >&2
  return 1
}

# Map a canonical backend name to the CLI binary used to drive it.
_backend_set_cli() {
  local selected="$1"

  case "$selected" in
    apple)
      _DC_CLI="container"
      ;;
    docker|orbstack|colima)
      _DC_CLI="docker"
      ;;
    podman)
      _DC_CLI="podman"
      ;;
    *)
      return 1
      ;;
  esac
}

# Print targeted install guidance when a selected backend's CLI is missing.
_backend_warn_missing_cli() {
  local selected="$1"

  echo "ERROR: Backend '$selected' selected but required CLI is unavailable." >&2
  case "$selected" in
    apple)
      echo "  Missing command: container" >&2
      ;;
    docker|orbstack)
      echo "  Missing command: docker" >&2
      ;;
    colima)
      if ! _backend_colima_cli_available; then
        echo "  Missing command: colima" >&2
      fi
      if ! command -v docker >/dev/null 2>&1; then
        echo "  Missing command: docker" >&2
      fi
      echo "  Install on macOS/Linux (Homebrew): brew install colima docker" >&2
      ;;
    podman)
      echo "  Missing command: podman" >&2
      ;;
  esac
}

# Fail fast unless a Colima Docker context is active. DC Enclave drives
# Colima through the docker CLI, so it must be pointed at Colima to work.
_backend_require_colima_context() {
  local context=""
  context="$(_backend_docker_context_name)"

  if _backend_context_is_colima "$context"; then
    return 0
  fi

  echo "ERROR: Colima backend requires an active Colima Docker context." >&2
  if [[ -n "$context" ]]; then
    echo "  Current Docker context: $context" >&2
  fi
  echo "  Docker context is managed by Docker CLI configuration." >&2
  echo "  Run: colima start" >&2
  echo "  Or: docker context use colima" >&2
  return 1
}

# Fail fast unless Colima is running with the docker runtime. Non-docker
# runtimes (e.g. containerd) are unsupported and silently misbehave.
_backend_require_colima_docker_runtime() {
  local runtime=""
  runtime="$(_backend_colima_runtime 2>/dev/null || true)"

  if [[ -n "$runtime" && "$runtime" != "docker" ]]; then
    echo "ERROR: Colima backend requires Colima runtime 'docker'." >&2
    echo "  Current Colima runtime: $runtime" >&2
    echo "  Recreate/start with Docker runtime: colima stop && colima start --runtime docker" >&2
    return 1
  fi

  return 0
}

# Capability probe: does this Podman version understand --add-host host-gateway?
# Result is cached in _DC_PODMAN_HOST_GATEWAY_SUPPORTED so we only probe once.
_backend_podman_supports_host_gateway() {
  if [[ -n "$_DC_PODMAN_HOST_GATEWAY_SUPPORTED" ]]; then
    [[ "$_DC_PODMAN_HOST_GATEWAY_SUPPORTED" == "1" ]]
    return $?
  fi

  if podman create --help 2>/dev/null | grep -q 'host-gateway'; then
    _DC_PODMAN_HOST_GATEWAY_SUPPORTED="1"
    return 0
  fi

  _DC_PODMAN_HOST_GATEWAY_SUPPORTED="0"
  return 1
}

# Resolve, validate, and lock in the active backend.
#
# Honors CONTAINER_BACKEND if set (otherwise auto-detects), confirms the CLI is
# installed, picks the matching binary, pins the Docker context for
# Colima/OrbStack, and exports DEV_CONTAINERS_BACKEND so later calls are cached.
# Every other backend_* function assumes this has run.
backend_use() {
  local requested="${1:-${CONTAINER_BACKEND:-}}"
  local selected=""

  if [[ -n "$requested" ]]; then
    if ! selected="$(_backend_normalize "$requested")"; then
      echo "ERROR: Unsupported CONTAINER_BACKEND '$requested'." >&2
      echo "  Supported values: apple, colima, docker, orbstack, podman" >&2
      return 1
    fi
  else
    selected="$(_backend_detect_auto)" || return 1
  fi

  if ! _backend_cli_available "$selected"; then
    _backend_warn_missing_cli "$selected"
    return 1
  fi

  if ! _backend_set_cli "$selected"; then
    dce_die "Unsupported backend '$selected'."
  fi

  DEV_CONTAINERS_BACKEND="$selected"
  export DEV_CONTAINERS_BACKEND

  case "$selected" in
    colima)
      _backend_use_colima_context || return 1
      ;;
    orbstack)
      _backend_use_orbstack_context || return 1
      ;;
    *)
      unset DOCKER_CONTEXT
      ;;
  esac
}

# Echo the canonical backend name, running backend_use() if not yet selected.
backend_name() {
  if [[ -z "${DEV_CONTAINERS_BACKEND:-}" ]]; then
    backend_use || return 1
  fi

  printf '%s\n' "$DEV_CONTAINERS_BACKEND"
}

# Echo the CLI binary (docker/container/podman) for the active backend, with
# a live Colima-context re-check so a switched-away context is caught early.
backend_cli() {
  backend_name >/dev/null || return 1
  if [[ -z "$_DC_CLI" ]]; then
    _backend_set_cli "$DEV_CONTAINERS_BACKEND" || return 1
  fi

  if [[ "$DEV_CONTAINERS_BACKEND" == "colima" ]]; then
    _backend_require_colima_context || return 1
  fi

  printf '%s\n' "$_DC_CLI"
}

# True for backends that speak the Docker CLI (docker/orbstack/colima/podman),
# i.e. everything except apple/container. Drives Docker-only code paths
# (devcontainer.json, VS Code attach config).
backend_is_docker_compatible() {
  local backend="${1:-}"
  if [[ -z "$backend" ]]; then
    backend="$(backend_name)" || return 1
  fi

  [[ "$backend" == "docker" || "$backend" == "orbstack" || "$backend" == "colima" || "$backend" == "podman" ]]
}

# Echo a human-readable version string for the active backend.
backend_version() {
  case "$(backend_name)" in
    apple)
      container --version 2>/dev/null || echo "container version unknown"
      ;;
    docker|orbstack)
      docker --version 2>/dev/null || echo "docker version unknown"
      ;;
    colima)
      local colima_version=""
      local docker_version=""

      colima_version="$(colima version 2>/dev/null | awk 'NR == 1 { print; exit }')"
      [[ -n "$colima_version" ]] || colima_version="colima version unknown"
      docker_version="$(docker --version 2>/dev/null || echo "docker version unknown")"

      printf '%s (%s)\n' "$colima_version" "$docker_version"
      ;;
    podman)
      podman --version 2>/dev/null || echo "podman version unknown"
      ;;
  esac
}

# Ensure the runtime engine is up (start daemon/machine/VM as needed) so the
# backend is ready for commands. Returns non-zero (with guidance) if unreachable.
backend_system_start() {
  case "$(backend_name)" in
    apple)
      container system start
      ;;
    docker|orbstack)
      docker info >/dev/null
      ;;
    colima)
      if ! _backend_colima_cli_available; then
        echo "ERROR: Colima backend selected but 'colima' command is unavailable." >&2
        echo "  Install: brew install colima docker" >&2
        return 1
      fi

      if ! _backend_colima_context_active || ! docker info >/dev/null 2>&1; then
        colima start >/dev/null 2>&1 || true
      fi

      _backend_require_colima_context || return 1

      if ! docker info >/dev/null 2>&1; then
        if ! _backend_require_colima_docker_runtime; then
          return 1
        fi
        echo "ERROR: Colima is not reachable via Docker CLI." >&2
        echo "  Try: colima start" >&2
        return 1
      fi

      _backend_require_colima_docker_runtime || return 1
      ;;
    podman)
      if podman info >/dev/null 2>&1; then
        return 0
      fi

      if podman machine --help >/dev/null 2>&1; then
        podman machine start >/dev/null 2>&1 || true
      fi

      if podman info >/dev/null 2>&1; then
        return 0
      fi

      echo "ERROR: Podman is not reachable." >&2
      echo "  Try: podman machine start (macOS) or ensure rootless podman is installed and configured." >&2
      return 1
      ;;
  esac
}

# Print detailed runtime info for the active backend (for `dce status`).
backend_system_info() {
  case "$(backend_name)" in
    apple)
      container system info
      ;;
    docker|orbstack)
      docker info
      ;;
    colima)
      colima status
      echo "---"
      _backend_require_colima_context || return 1
      docker info
      ;;
    podman)
      podman info
      ;;
  esac
}

# Build an image from a Containerfile. Extra args are forwarded to the builder.
backend_build_image() {
  local tag="$1"
  local file="$2"
  local context="$3"
  shift 3

  case "$(backend_name)" in
    apple)
      container build --tag "$tag" --file "$file" "$@" "$context"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" build --tag "$tag" --file "$file" "$@" "$context"
      ;;
  esac
}

# Return whether an image tag exists in the backend's image store.
# apple/container has several list-flag variants across versions, hence fallbacks.
backend_image_exists() {
  local tag="$1"

  case "$(backend_name)" in
    apple)
      if container image ls --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1; then
        container image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq "$tag"
      elif container images --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1; then
        container images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq "$tag"
      else
        container image ls 2>/dev/null | awk '{print $1 ":" $2}' | grep -Fxq "$tag"
      fi
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq "$tag"
      ;;
  esac
}

# Echo the backend-local image Id (content digest) for an image reference, or
# empty if it cannot be determined. Used for image provenance (the base.id
# label/log field) so a reader can tell whether dce-base was rebuilt since a
# derived image was built. Best-effort and backend-local by design: it never
# fails a build (empty is acceptable), and the value is not portable across
# backends -- it is only meaningful within one backend's image store.
backend_image_id() {
  local ref="$1"

  case "$(backend_name)" in
    apple)
      # apple/container's inspect surface differs from docker's; attempt the
      # closest form and fall through to empty on any failure.
      container image inspect "$ref" --format '{{.ID}}' 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image inspect "$ref" --format '{{.Id}}' 2>/dev/null || true
      ;;
  esac
}

# Echo the backend-local image Id that a running/stopped container is bound to,
# or empty if it cannot be determined. Used by the stale-container check
# (scripts/list.sh, scripts/status.sh) to compare the container's bound image
# against the current image the project's CONTAINER_IMAGE tag resolves to.
# Best-effort and backend-local by design, like backend_image_id: empty is an
# acceptable "unknown," never a hard failure.
backend_container_image_id() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      # apple/container's inspect surface differs from docker's; attempt the
      # closest form and fall through to empty on any failure.
      container inspect "$name" --format '{{.ImageID}}' 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" inspect "$name" --format '{{.Image}}' 2>/dev/null || true
      ;;
  esac
}

# Determine whether a project's container is stale: bound to an older image than
# the project's configured CONTAINER_IMAGE tag currently resolves to. This is
# the single stale predicate shared by `dce list` and `dce status`.
#
# Returns 0 (stale) only when drift is *proven*: the backend is usable, the
# container exists, and both the desired image's id and the container's bound
# image id are known and differ. Returns 1 in every other case (container
# missing, backend unavailable, an id unknown), so the caller never produces a
# false-positive stale warning. Prints a one-line reason on stdout when stale,
# empty otherwise, so callers can surface the comparison in debug output.
backend_container_is_stale() {
  local project="$1"
  local desired_ref="$2"

  [[ -n "$desired_ref" ]] || return 1

  local desired_id="" container_id=""
  desired_id="$(backend_image_id "$desired_ref" 2>/dev/null || true)"
  [[ -n "$desired_id" ]] || return 1

  container_id="$(backend_container_image_id "$project" 2>/dev/null || true)"
  [[ -n "$container_id" ]] || return 1

  if [[ "$desired_id" != "$container_id" ]]; then
    printf '%s\n' "container image $container_id != desired $desired_id"
    return 0
  fi
  return 1
}

# List images as repo<TAB>tag<TAB>id rows (normalized across backends/versions).
backend_list_images() {
  case "$(backend_name)" in
    apple)
      if container image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' >/dev/null 2>&1; then
        container image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      elif container images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' >/dev/null 2>&1; then
        container images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      else
        container image ls 2>/dev/null | awk 'NR > 1 {print $1 "\t" $2 "\t" $3}'
      fi
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      ;;
  esac
}

# Remove an image reference (silently succeeds if already absent).
backend_remove_image() {
  local image_ref="$1"

  case "$(backend_name)" in
    apple)
      container image rm "$image_ref" >/dev/null 2>&1 || container rmi "$image_ref" >/dev/null 2>&1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image rm "$image_ref" >/dev/null
      ;;
  esac
}

# List volume names (one per line). apple/container may emit JSON, hence parsing.
backend_list_volumes() {
  local backend=""
  backend="$(backend_name)" || return 1

  case "$backend" in
    apple)
      if container volume list --format json >/dev/null 2>&1; then
        container volume list --format json 2>/dev/null | awk -F'"' '/"name"[[:space:]]*:/ {print $4}'
      elif container volume ls --format '{{.Name}}' >/dev/null 2>&1; then
        container volume ls --format '{{.Name}}' 2>/dev/null
      else
        container volume list 2>/dev/null | awk 'NR > 1 {print $1}'
      fi
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" volume ls --format '{{.Name}}' 2>/dev/null
      ;;
  esac
}

# Remove a named volume (silently succeeds if already absent).
backend_remove_volume() {
  local volume_name="$1"

  case "$(backend_name)" in
    apple)
      if container volume delete "$volume_name" >/dev/null 2>&1; then
        return 0
      fi
      container volume rm "$volume_name" >/dev/null 2>&1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" volume rm "$volume_name" >/dev/null
      ;;
  esac
}

# List running containers (raw backend output).
backend_list_running() {
  case "$(backend_name)" in
    apple)
      container ps
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" ps
      ;;
  esac
}

# List all containers including stopped (raw backend output).
backend_list_all() {
  case "$(backend_name)" in
    apple)
      container ps -a
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" ps -a
      ;;
  esac
}

# Return whether a named container exists (any state).
backend_exists() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container ps -a 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
      ;;
  esac
}

# Return whether a named container is currently running.
backend_is_running() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container ps 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
      ;;
  esac
}

# Create a container from an image with the given create flags.
#
# For Podman we add a host.docker.internal=host-gateway alias when supported,
# so containers can reach the host by the same name as Docker backends; older
# Podman gets a one-time warning to use host.containers.internal instead.
backend_create() {
  local name="$1"
  local image="$2"
  shift 2

  local backend=""
  backend="$(backend_name)" || return 1

  local -a create_args=("$@")
  if [[ "$backend" == "podman" ]]; then
    if _backend_podman_supports_host_gateway; then
      create_args+=(--add-host "host.docker.internal=host-gateway")
    elif [[ "$_DC_PODMAN_HOST_GATEWAY_WARNED" -eq 0 ]]; then
      dce_warn "Podman host-gateway alias is unavailable; use host.containers.internal inside containers."
      _DC_PODMAN_HOST_GATEWAY_WARNED=1
    fi
  fi

  case "$backend" in
    apple)
      container create --name "$name" "${create_args[@]}" "$image"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" create --name "$name" "${create_args[@]}" "$image" >/dev/null
      ;;
  esac
}

# Start an existing container.
backend_start() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container start "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" start "$name" >/dev/null
      ;;
  esac
}

# Stop a running container.
backend_stop() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container stop "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" stop "$name" >/dev/null
      ;;
  esac
}

# Fetch a container's stdout/stderr log stream.
#
# Structured args keep argv consistent across backends (every backend's `logs`
# subcommand accepts the same -f/--tail shape on recent versions): follow=true
# attaches (-f, blocks until interrupted); tail (empty or integer N) prepends
# `--tail N`. Flag support is backend-version-dependent; on unsupported flags
# the backend itself reports the error.
backend_logs() {
  local name="$1"
  local follow="$2"
  local tail="${3:-}"

  local -a log_args=()
  if [[ "$follow" == "true" ]]; then
    log_args+=("-f")
  fi
  if [[ -n "$tail" ]]; then
    log_args+=("--tail" "$tail")
  fi

  case "$(backend_name)" in
    apple)
      container logs "${log_args[@]}" "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" logs "${log_args[@]}" "$name"
      ;;
  esac
}

# Delete a container (force-remove for Docker CLIs).
backend_delete() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container delete "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" rm -f "$name" >/dev/null
      ;;
  esac
}

# Run a command in a container as the dev user (non-interactive, no TTY).
backend_exec() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec "$name" "$@"
      ;;
  esac
}

# Run a command in a container as root (uid 0). Used for setup that the dev
# user can't do, e.g. chown of hidden-volume mount points.
backend_exec_as_root() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec --uid 0 "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -u 0 "$name" "$@"
      ;;
  esac
}

# Run a command in a container with stdin attached (no TTY). Used to stream
# data into the container, e.g. piping a host file or tar into the container.
backend_exec_stdin() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec -i "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -i "$name" "$@"
      ;;
  esac
}

# Open an interactive (TTY) session in a container as dev.
#
# Args before a literal "--" are passed as exec options (e.g. --env KEY=VAL);
# everything after "--" is the command to run. This lets callers inject env
# vars without colliding with the exec option namespace.
backend_exec_interactive() {
  local name="$1"
  shift

  local -a exec_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    exec_args+=("$1")
    shift
  done

  local -a command=("$@")

  case "$(backend_name)" in
    apple)
      container exec -it "${exec_args[@]}" "$name" "${command[@]}"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -it "${exec_args[@]}" "$name" "${command[@]}"
      ;;
  esac
}

# =============================================================================
# Network management. User-defined networks are first-class objects on both
# backend families: docker/orbstack/colima/podman via the Docker CLI, and
# apple/container via `container network` (macOS 26+). The CLI shapes diverge
# (apple uses `delete` not `rm`; apple resolves peers as `<name>.test`; apple
# cannot live-attach a network to an existing container), so every divergence
# is pinned in tests/backend-dispatch.sh.
# =============================================================================

# Create a user-defined network. Extra args (e.g. --subnet <cidr>) are appended
# after the name, matching apple/container's documented form and docker's lenient
# ordering. Idempotent callers should check backend_network_exists first.
backend_network_create() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container network create "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network create "$name" "$@" >/dev/null
      ;;
  esac
}

# List user-defined network names, one per line. docker emits names directly via
# --format; apple prints a columned table (NETWORK/STATE/SUBNET) whose header is
# skipped only when the first field is literally "NETWORK" (robust to reordering).
backend_network_list() {
  case "$(backend_name)" in
    apple)
      container network list 2>/dev/null \
        | awk 'NR==1 && $1=="NETWORK" {next} NF {print $1}'
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network ls --format '{{.Name}}' 2>/dev/null
      ;;
  esac
}

# Return 0 if a named network exists on the active backend, 1 if absent.
# Returns 2 if the underlying list call itself failed.
backend_network_exists() {
  local name="$1"
  local listed=""

  if ! listed="$(backend_network_list 2>/dev/null)"; then
    return 2
  fi

  local n=""
  while IFS= read -r n; do
    [[ "$n" == "$name" ]] && return 0
  done <<< "$listed"

  return 1
}

# Remove a user-defined network (silently succeeds if already absent on docker).
backend_network_rm() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container network delete "$name" >/dev/null 2>&1 || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network rm "$name" >/dev/null 2>&1 || true
      ;;
  esac
}

# Live-attach an existing container to a network. Extra args (e.g. --ip <addr>)
# are Docker connect options and precede NETWORK CONTAINER per docker syntax.
# apple/container sets networks only at create time, so live-attach is refused.
backend_network_connect() {
  local name="$1"
  local container="$2"
  shift 2

  case "$(backend_name)" in
    apple)
      echo "ERROR: apple/container cannot live-attach a network to an existing container." >&2
      echo "       Re-create with: dce rebuild-container $container (after adding the network to its config)." >&2
      return 1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network connect "$@" "$name" "$container" >/dev/null
      ;;
  esac
}

# Detach a container from a network. Unsupported on apple/container (see connect).
backend_network_disconnect() {
  local name="$1"
  local container="$2"

  case "$(backend_name)" in
    apple)
      echo "ERROR: apple/container cannot detach a network from an existing container." >&2
      return 1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network disconnect "$name" "$container" >/dev/null 2>&1 || true
      ;;
  esac
}
