#!/usr/bin/env zsh
# Shared backend abstraction for apple/container, Docker, and OrbStack.

typeset -g DEV_CONTAINERS_BACKEND="${DEV_CONTAINERS_BACKEND:-}"

_backend_normalize() {
  local raw="${1:-}"
  local value="${raw:l}"

  case "$value" in
    "" )
      return 1
      ;;
    apple|container|apple-container)
      print -r -- "apple"
      ;;
    docker|docker-desktop)
      print -r -- "docker"
      ;;
    orbstack|orb)
      print -r -- "orbstack"
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
    *)
      return 1
      ;;
  esac
}

_backend_detect_auto() {
  local docker_context=""

  if command -v docker >/dev/null 2>&1; then
    docker_context="$(docker context show 2>/dev/null || true)"
    if [[ "${docker_context:l}" == *"orbstack"* ]]; then
      print -r -- "orbstack"
      return 0
    fi
  fi

  if command -v container >/dev/null 2>&1; then
    print -r -- "apple"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    print -r -- "docker"
    return 0
  fi

  echo "ERROR: No supported container backend found." >&2
  echo "  Install apple/container, Docker Desktop, or OrbStack." >&2
  return 1
}

backend_use() {
  local requested="${1:-${CONTAINER_BACKEND:-}}"
  local selected=""

  if [[ -n "$requested" ]]; then
    if ! selected="$(_backend_normalize "$requested")"; then
      echo "ERROR: Unsupported CONTAINER_BACKEND '$requested'." >&2
      echo "  Supported values: apple, docker, orbstack" >&2
      return 1
    fi
  else
    selected="$(_backend_detect_auto)" || return 1
  fi

  if ! _backend_cli_available "$selected"; then
    echo "ERROR: Backend '$selected' selected but required CLI is unavailable." >&2
    case "$selected" in
      apple)
        echo "  Missing command: container" >&2
        ;;
      docker|orbstack)
        echo "  Missing command: docker" >&2
        ;;
    esac
    return 1
  fi

  DEV_CONTAINERS_BACKEND="$selected"
  export DEV_CONTAINERS_BACKEND
}

backend_name() {
  if [[ -z "${DEV_CONTAINERS_BACKEND:-}" ]]; then
    backend_use || return 1
  fi

  print -r -- "$DEV_CONTAINERS_BACKEND"
}

backend_is_docker_compatible() {
  local backend="${1:-}"
  if [[ -z "$backend" ]]; then
    backend="$(backend_name)" || return 1
  fi

  [[ "$backend" == "docker" || "$backend" == "orbstack" ]]
}

backend_version() {
  case "$(backend_name)" in
    apple)
      container --version 2>/dev/null || echo "container version unknown"
      ;;
    docker|orbstack)
      docker --version 2>/dev/null || echo "docker version unknown"
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
    docker|orbstack)
      docker build --tag "$tag" --file "$file" "$@" "$context"
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
    docker|orbstack)
      docker image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      ;;
  esac
}

backend_remove_image() {
  local image_ref="$1"

  case "$(backend_name)" in
    apple)
      container image rm "$image_ref" >/dev/null 2>&1 || container rmi "$image_ref" >/dev/null 2>&1
      ;;
    docker|orbstack)
      docker image rm "$image_ref" >/dev/null
      ;;
  esac
}

backend_list_running() {
  case "$(backend_name)" in
    apple)
      container ps
      ;;
    docker|orbstack)
      docker ps
      ;;
  esac
}

backend_list_all() {
  case "$(backend_name)" in
    apple)
      container ps -a
      ;;
    docker|orbstack)
      docker ps -a
      ;;
  esac
}

backend_exists() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container ps -a 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
      ;;
    docker|orbstack)
      docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
      ;;
  esac
}

backend_is_running() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container ps 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
      ;;
    docker|orbstack)
      docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
      ;;
  esac
}

backend_create() {
  local name="$1"
  local image="$2"
  shift 2

  case "$(backend_name)" in
    apple)
      container create --name "$name" "$@" "$image"
      ;;
    docker|orbstack)
      docker create --name "$name" "$@" "$image" >/dev/null
      ;;
  esac
}

backend_start() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container start "$name"
      ;;
    docker|orbstack)
      docker start "$name" >/dev/null
      ;;
  esac
}

backend_stop() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container stop "$name"
      ;;
    docker|orbstack)
      docker stop "$name" >/dev/null
      ;;
  esac
}

backend_delete() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container delete "$name"
      ;;
    docker|orbstack)
      docker rm -f "$name" >/dev/null
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
    docker|orbstack)
      docker exec "$name" "$@"
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
    docker|orbstack)
      docker exec -i "$name" "$@"
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
    docker|orbstack)
      docker exec -it "${exec_args[@]}" "$name" "${command[@]}"
      ;;
  esac
}
