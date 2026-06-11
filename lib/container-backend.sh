#!/usr/bin/env bash
# Shared backend abstraction for apple/container, Docker, OrbStack, and Podman.

if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dc_backend_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_dc_backend_lib_dir/common.sh"
  unset _dc_backend_lib_dir
fi

if [[ -n "${_DC_BACKEND_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKEND_SH_LOADED=1

declare -g DEV_CONTAINERS_BACKEND="${DEV_CONTAINERS_BACKEND:-}"
declare -g _DC_CLI=""
declare -g _DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
declare -g _DC_PODMAN_HOST_GATEWAY_WARNED=0

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
    podman|podman-desktop)
      printf '%s\n' "podman"
      ;;
    *)
      return 1
      ;;
  esac
}

_backend_cli_available() {
  local backend="$1"

  case "$backend" in
    apple)
      command -v container >/dev/null 2>&1
      ;;
    docker|orbstack)
      command -v docker >/dev/null 2>&1
      ;;
    podman)
      command -v podman >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

_backend_detect_auto() {
  local docker_context=""

  if command -v docker >/dev/null 2>&1; then
    docker_context="$(docker context show 2>/dev/null || true)"
    if [[ "${docker_context,,}" == *"orbstack"* ]]; then
      printf '%s\n' "orbstack"
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
  echo "  Install apple/container, Docker Desktop, OrbStack, or Podman." >&2
  return 1
}

_backend_set_cli() {
  local selected="$1"

  case "$selected" in
    apple)
      _DC_CLI="container"
      ;;
    docker|orbstack)
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
    podman)
      echo "  Missing command: podman" >&2
      ;;
  esac
}

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

backend_use() {
  local requested="${1:-${CONTAINER_BACKEND:-}}"
  local selected=""

  if [[ -n "$requested" ]]; then
    if ! selected="$(_backend_normalize "$requested")"; then
      echo "ERROR: Unsupported CONTAINER_BACKEND '$requested'." >&2
      echo "  Supported values: apple, docker, orbstack, podman" >&2
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
    dc_die "Unsupported backend '$selected'."
  fi

  DEV_CONTAINERS_BACKEND="$selected"
  export DEV_CONTAINERS_BACKEND
}

backend_name() {
  if [[ -z "${DEV_CONTAINERS_BACKEND:-}" ]]; then
    backend_use || return 1
  fi

  printf '%s\n' "$DEV_CONTAINERS_BACKEND"
}

backend_cli() {
  backend_name >/dev/null || return 1
  if [[ -z "$_DC_CLI" ]]; then
    _backend_set_cli "$DEV_CONTAINERS_BACKEND" || return 1
  fi

  printf '%s\n' "$_DC_CLI"
}

backend_is_docker_compatible() {
  local backend="${1:-}"
  if [[ -z "$backend" ]]; then
    backend="$(backend_name)" || return 1
  fi

  [[ "$backend" == "docker" || "$backend" == "orbstack" || "$backend" == "podman" ]]
}

backend_version() {
  case "$(backend_name)" in
    apple)
      container --version 2>/dev/null || echo "container version unknown"
      ;;
    docker|orbstack)
      docker --version 2>/dev/null || echo "docker version unknown"
      ;;
    podman)
      podman --version 2>/dev/null || echo "podman version unknown"
      ;;
  esac
}

backend_system_start() {
  case "$(backend_name)" in
    apple)
      container system start
      ;;
    docker|orbstack)
      docker info >/dev/null
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

backend_system_info() {
  case "$(backend_name)" in
    apple)
      container system info
      ;;
    docker|orbstack)
      docker info
      ;;
    podman)
      podman info
      ;;
  esac
}

backend_build_image() {
  local tag="$1"
  local file="$2"
  local context="$3"
  shift 3

  case "$(backend_name)" in
    apple)
      container build --tag "$tag" --file "$file" "$@" "$context"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" build --tag "$tag" --file "$file" "$@" "$context"
      ;;
  esac
}

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
    docker|orbstack|podman)
      "$(backend_cli)" image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      ;;
  esac
}

backend_remove_image() {
  local image_ref="$1"

  case "$(backend_name)" in
    apple)
      container image rm "$image_ref" >/dev/null 2>&1 || container rmi "$image_ref" >/dev/null 2>&1
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" image rm "$image_ref" >/dev/null
      ;;
  esac
}

backend_list_running() {
  case "$(backend_name)" in
    apple)
      container ps
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" ps
      ;;
  esac
}

backend_list_all() {
  case "$(backend_name)" in
    apple)
      container ps -a
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" ps -a
      ;;
  esac
}

backend_exists() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container ps -a 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
      ;;
  esac
}

backend_is_running() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container ps 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
      ;;
  esac
}

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
      dc_warn "Podman host-gateway alias is unavailable; use host.containers.internal inside containers."
      _DC_PODMAN_HOST_GATEWAY_WARNED=1
    fi
  fi

  case "$backend" in
    apple)
      container create --name "$name" "${create_args[@]}" "$image"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" create --name "$name" "${create_args[@]}" "$image" >/dev/null
      ;;
  esac
}

backend_start() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container start "$name"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" start "$name" >/dev/null
      ;;
  esac
}

backend_stop() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container stop "$name"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" stop "$name" >/dev/null
      ;;
  esac
}

backend_delete() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container delete "$name"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" rm -f "$name" >/dev/null
      ;;
  esac
}

backend_exec() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec "$name" "$@"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" exec "$name" "$@"
      ;;
  esac
}

backend_exec_stdin() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec -i "$name" "$@"
      ;;
    docker|orbstack|podman)
      "$(backend_cli)" exec -i "$name" "$@"
      ;;
  esac
}

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
    docker|orbstack|podman)
      "$(backend_cli)" exec -it "${exec_args[@]}" "$name" "${command[@]}"
      ;;
  esac
}
