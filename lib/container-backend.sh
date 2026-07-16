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
  # `colima status` writes its output to STDERR on current colima versions, so
  # capture both streams (and tolerate the non-zero exit colima returns when the
  # VM is down -- an empty result is handled below as "unknown runtime").
  status="$(colima status 2>&1 || true)"
  [[ -n "$status" ]] || return 1

  local runtime=""
  # `colima status` renders the runtime two ways across versions:
  #   legacy:  `runtime: docker`
  #   modern:  `time=".." level=info msg="runtime: docker"`  (logrus format)
  # Splitting on ':' and matching the first field (the old approach) breaks on
  # the modern form, where field $1 is the timestamp. Match the literal
  # `runtime:` token anywhere in the line and capture the following word.
  runtime="$(printf '%s\n' "$status" \
    | sed -nE 's/.*runtime:[[:space:]]*([A-Za-z0-9._-]+).*/\1/p' \
    | head -n1)"

  [[ -n "$runtime" ]] || return 1
  printf '%s\n' "${runtime,,}"
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

# Emit every backend whose CLI(s) are detectable on PATH, one per line, in a
# stable order: apple, docker, orbstack, colima, podman. This is CLI-presence
# detection ONLY -- no daemon reachability probe, no backend selection/pinning,
# no mutation of DEV_CONTAINERS_BACKEND. It is the single shared source of truth
# for "which backends count as available on this host", consumed by both
# `dce doctor` and the integration test harness so the two can never drift.
#
# OrbStack is reported only when a Docker context referencing it exists
# (otherwise it is indistinguishable from plain docker); Colima requires both
# the colima and docker CLIs. Always returns 0 (empty output = none available).
backend_detect_available() {
  if command -v container >/dev/null 2>&1; then printf 'apple\n'; fi
  if command -v docker >/dev/null 2>&1; then printf 'docker\n'; fi
  if command -v docker >/dev/null 2>&1 \
     && docker context ls --format '{{.Name}}' 2>/dev/null | grep -iq orbstack; then
    printf 'orbstack\n'
  fi
  if command -v colima >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    printf 'colima\n'
  fi
  if command -v podman >/dev/null 2>&1; then printf 'podman\n'; fi
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
      # apple/container has no `system info` subcommand; `system status` prints
      # the status table and exits 0 when services are running (reachability
      # probe for doctor + the integration suite).
      container system status
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

# True if a captured apple/container build log shows the native builder CANNOT
# complete the build in the current host environment -- independent of the
# Containerfile itself. Two known classes, both caused by the apple builder
# running in a vmnet-NAT'd namespace that a host VPN (or this host's networking)
# breaks:
#   * no outbound network -> apt/apk cannot resolve or reach any repo
#     ("Temporary failure resolving", "Unable to locate package", etc.)
#   * no build-context transfer -> COPY/ADD of a local file fails because the
#     builder receives an empty context ("failed to calculate checksum").
# Both persist until host networking is fixed; neither is a Containerfile bug.
# This is the trigger for _backend_apple_build_image's peer-backend fallback,
# which is safe because a genuine Containerfile error also fails on the peer.
# Used as:  if _backend_apple_native_build_blocked "$log"; then ...; fi
_backend_apple_native_build_blocked() {  # <build-log>
  [[ -n "$1" ]] || return 1
  printf '%s' "$1" | grep -Eq \
    'Temporary failure resolving|Temporary failure in name resolution|Unable to locate package|no installation candidate|Failed to fetch|failed to calculate checksum'
}

# Pick a reachable peer backend whose build network CAN reach the internet, for
# sourcing an image when apple/container's own builder has no egress. The docker
# family (docker/orbstack/colima) all drive the `docker` CLI and share its build
# network, so one `docker info` reachability check covers all three; podman is
# the fallback. Echoes the CLI binary name (docker|podman), or returns non-zero
# if none is reachable.
_backend_apple_peer_cli() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf 'docker\n'
    return 0
  fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    printf 'podman\n'
    return 0
  fi
  return 1
}

# Build <tag> on a peer CLI and load the resulting OCI archive into
# apple/container's store under the same tag. Returns non-zero on any failure;
# the caller decides how to surface it. <peer-cli> is "docker" or "podman".
#
# docker emits an OCI archive directly via `build --output type=oci,dest=` and
# preserves the -t ref, so `container image load` lands it under the clean tag.
# The --output flag requires BuildKit: DOCKER_BUILDKIT=1 is set so the docker CLI
# uses its built-in BuildKit even when the legacy builder is the default (e.g.
# when the buildx plugin is absent or the CLI predates BuildKit-as-default).
# podman has no --output on build, so it builds OCI then exports via
# `save --format oci-archive`; podman stores unqualified tags under localhost/,
# which the archive preserves, so the loaded image must be re-tagged to the name
# apple-side lookups (backend_image_exists) expect.
_backend_apple_build_via_peer() {  # <peer-cli> <tag> <file> <context> [build-args...]
  local peer="$1" tag="$2" file="$3" context="$4"; shift 4
  local oci_tar ok=1
  oci_tar="$(mktemp "${TMPDIR:-/tmp}/dce-apple-peer.XXXXXX.tar")" || return 1

  if [[ "$peer" == "docker" ]]; then
    DOCKER_BUILDKIT=1 docker build --output "type=oci,dest=$oci_tar" --tag "$tag" --file "$file" "$@" "$context" \
      && container image load --input "$oci_tar" >/dev/null \
      || ok=0
  else  # podman
    podman build --format oci --tag "$tag" --file "$file" "$@" "$context" \
      && podman save --format oci-archive -o "$oci_tar" "$tag" \
      && container image load --input "$oci_tar" >/dev/null \
      && container image tag "localhost/$tag" "$tag" \
      || ok=0
  fi

  rm -f "$oci_tar"
  [[ $ok -eq 1 ]] || return 1

  # Final guard: confirm the tag actually landed under the expected name before
  # reporting success (catches any tag-prefix surprise across CLI versions).
  backend_image_exists "$tag"
}

# Build an image for the apple/container backend. The native builder is tried
# first; on an environment-blocked failure (no outbound network / no build-
# context transfer -- typically a host VPN the vmnet NAT cannot traverse) it
# transparently rebuilds on a reachable docker/podman peer and loads the OCI
# image into apple/container under the same tag. Any OTHER failure (real
# Containerfile error, etc.) is re-streamed and propagated -- the fallback never
# masks it (a genuine error fails on the peer too).
_backend_apple_build_image() {  # <tag> <file> <context> [build-args...]
  local tag="$1" file="$2" context="$3"; shift 3
  local work_dir native_log peer rc=1

  # tee keeps live output streaming to the user while capturing the log so an
  # environment-blocked failure can be classified without a second run.
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dce-apple-build.XXXXXX")" || return 1
  native_log="$work_dir/native.log"

  if container build --tag "$tag" --file "$file" "$@" "$context" 2>&1 | tee "$native_log"; then
    rc=0
  elif ! _backend_apple_native_build_blocked "$(cat "$native_log" 2>/dev/null || true)"; then
    : # Real build error -- already streamed via tee; just propagate non-zero.
  elif ! peer="$(_backend_apple_peer_cli)"; then
    dce_warn "apple/container's native builder cannot complete this build in the current"
    dce_warn "environment (no outbound network or no build-context transfer -- typically a"
    dce_warn "host VPN the vmnet NAT cannot traverse), and no reachable docker/podman peer"
    dce_warn "to build on. Build '$tag' on another backend, export OCI, then: container image load."
  else
    dce_warn "apple/container's native builder cannot complete this build (environment block:"
    dce_warn "no outbound network / no build-context transfer)."
    dce_warn "Falling back: building '$tag' on '$peer' and loading the OCI image into apple/container."
    if _backend_apple_build_via_peer "$peer" "$tag" "$file" "$context" "$@"; then
      rc=0
    else
      dce_warn "peer build/load failed; apple/container image store left unchanged."
    fi
  fi

  rm -rf "$work_dir"
  return "$rc"
}

# Build an image from a Containerfile. Extra args are forwarded to the builder.
backend_build_image() {
  local tag="$1"
  local file="$2"
  local context="$3"
  shift 3

  case "$(backend_name)" in
    apple)
      _backend_apple_build_image "$tag" "$file" "$context" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" build --tag "$tag" --file "$file" "$@" "$context"
      ;;
  esac
}

# True if <needle> appears as an EXACT line in the output of the given command.
#
# The output is captured IN FULL before testing, so the reader never exits early
# and never SIGPIPEs the producer. This replaces the unsafe `<cmd> | grep -Fxq`
# shape: under `set -o pipefail`, grep's -q early-exit closes the pipe, a large
# producer (e.g. `image ls` over a full image store) dies on its next write with
# SIGPIPE (141), and pipefail turns a found match into a false-negative. Captured
# membership testing has none of that failure mode.
_backend_list_contains() {
  local needle="$1"; shift
  local out=""
  out="$("$@" 2>/dev/null)" || true
  [[ $'\n'"$out"$'\n' == *$'\n'"$needle"$'\n'* ]]
}

# Like _backend_list_contains but for the image store, and normalizes podman's
# "localhost/" prefix. podman stores/lists an unqualified build tag like
# `dce-base:latest` as `localhost/dce-base:latest`, while docker/orbstack/colima
# list the short name; docker/orbstack/colima keep working. Stripping a
# nonexistent leading "localhost/" from those short names is a no-op, so a single
# path covers the whole docker family. (Only image names get the prefix -- never
# container or network names -- so this stays out of _backend_list_contains.)
_backend_image_list_has() {  # <tag>
  local tag="$1" out normalized
  out="$("$(backend_cli)" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)" || true
  normalized="$(printf '%s\n' "$out" | sed -E 's|^localhost/||')"
  [[ $'\n'"$normalized"$'\n' == *$'\n'"$tag"$'\n'* ]]
}

# Return whether an image tag exists in the backend's image store.
# apple/container has several list-flag variants across versions, hence fallbacks.
backend_image_exists() {
  local tag="$1"

  case "$(backend_name)" in
    apple)
      if container image ls --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1; then
        _backend_list_contains "$tag" container image ls --format '{{.Repository}}:{{.Tag}}'
      elif container images --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1; then
        _backend_list_contains "$tag" container images --format '{{.Repository}}:{{.Tag}}'
      else
        # Raw-table fallback for older apple/container: reformat to repo:tag and
        # exact-match against the captured output (no early-exit reader).
        local raw="" rows=""
        raw="$(container image ls 2>/dev/null)" || raw=""
        rows="$(printf '%s\n' "$raw" | awk '{print $1 ":" $2}')" || rows=""
        [[ $'\n'"$rows"$'\n' == *$'\n'"$tag"$'\n'* ]]
      fi
      ;;
    docker|orbstack|colima|podman)
      _backend_image_list_has "$tag"
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

# Echo the on-disk size (in bytes) of an image, or empty when it cannot be
# determined. Best-effort and backend-local by design (like backend_image_id):
# empty is an acceptable "unknown," never a hard failure. Used by snapshot
# listings so operators can see disk cost.
backend_image_size() {
  local ref="$1"

  case "$(backend_name)" in
    apple)
      container image inspect "$ref" --format '{{.size}}' 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image inspect "$ref" --format '{{.Size}}' 2>/dev/null || true
      ;;
  esac
}

# Echo the value of an OCI image LABEL key, or empty when absent / unknown.
# Best-effort and backend-local by design: never fails a listing. Used to read
# dce.snapshot.* provenance labels stamped on snapshot images.
backend_image_label() {
  local ref="$1"
  local key="$2"

  case "$(backend_name)" in
    apple)
      container image inspect "$ref" --format "{{index .config.labels \"$key\"}}" 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image inspect "$ref" --format "{{index .Config.Labels \"$key\"}}" 2>/dev/null || true
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
      # podman lists unqualified builds as "localhost/<repo>"; strip the prefix
      # so consumers (clean/snapshot/rm/provenance) that match on short repo
      # names like "dce-base" / "dce-img-<hash>" / "dce-snap-<...>" see the same
      # short repo as docker/orbstack/colima. sed is not an early-exit reader, so
      # it cannot SIGPIPE the producer under pipefail.
      "$(backend_cli)" image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' \
        | sed -E 's|^localhost/||'
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
      "$(backend_cli)" volume rm "$volume_name" >/dev/null 2>&1
      ;;
  esac
}

# Copy the full contents of <src_volume> into <dst_volume>, preserving
# ownership and permissions. Used by `dce snapshot --include-volumes` to clone a
# hidden volume into a snapshot-specific volume isolated from the live original.
#
# Safety contract:
#   - The SOURCE is mounted READ-ONLY. The copy helper runs as root (uid 0) to
#     read every file; a read-only source makes it structurally impossible for a
#     copy-recipe bug to corrupt the LIVE volume a normal rebuild depends on.
#     "The source container is stopped" only blocks app writes, not helper
#     writes, so RO is the meaningful guarantee.
#   - The helper image is dce-base:latest (guaranteed present when a dce project
#     exists; ships tar/coreutils). The recipe is a pure-reader tar pipe; tar -p
#     preserves dev:dev (and any root:root) ownership, so no re-chown is needed.
#   - Named volumes are auto-created on reference, so <dst_volume> exists after
#     this call even on failure (as an empty volume) -- the desired degraded
#     state when a copy fails.
#
# Returns the helper's exit code (non-zero on copy failure). apple/container has
# no native volume-to-volume copy (`container cp` is container<->host only), so
# every backend uses the same temp-container recipe; only the mount flag differs
# (apple's `-v` documents no `:ro` suffix, so `--mount ... readonly` is used).
backend_volume_copy() {
  local src="$1"
  local dst="$2"

  local backend=""
  backend="$(backend_name)" || return 1

  local recipe='tar -C /from -cf - . | tar -C /to -xf -'

  case "$backend" in
    docker|orbstack|colima|podman)
      "$(backend_cli)" run --rm -u 0 \
        -v "$src":/from:ro -v "$dst":/to \
        dce-base:latest sh -c "$recipe" >/dev/null
      ;;
    apple)
      container run --rm --uid 0 \
        --mount type=volume,source="$src",target=/from,readonly \
        --mount type=volume,source="$dst",target=/to \
        dce-base:latest sh -c "$recipe" >/dev/null
      ;;
  esac
}

# List running containers (raw backend output).
backend_list_running() {
  case "$(backend_name)" in
    apple)
      # apple/container has no `ps` subcommand; the alias is `ls` (a.k.a `list`).
      container ls
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
      container ls -a
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
      # `ls -a -q` prints one container name per line (running + stopped); the
      # `-q` form avoids depending on the human-readable table column layout.
      _backend_list_contains "$name" container ls -a -q
      ;;
    docker|orbstack|colima|podman)
      _backend_list_contains "$name" "$(backend_cli)" ps -a --format '{{.Names}}'
      ;;
  esac
}

# Return whether a named container is currently running.
backend_is_running() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      _backend_list_contains "$name" container ls -q
      ;;
    docker|orbstack|colima|podman)
      _backend_list_contains "$name" "$(backend_cli)" ps --format '{{.Names}}'
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

# apple/container has no `commit` and no image `import`, so a commit is composed
# from `export` (flat merged FS tar, volumes excluded) + `build FROM scratch ADD`.
# `FROM scratch` discards image config, so base-image metadata (USER, WORKDIR,
# ENV, CMD, ENTRYPOINT) is read from the container's current image via
# `container image inspect` and re-emitted. USER re-application is mandatory:
# after a restore, credential injection writes ~/.ssh as the dev user, so a
# snapshot that defaulted to root would break the dev user. The caller must
# ensure the container is stopped first (export requires a stopped container).
_backend_apple_container_commit() {
  local container_name="$1"
  local image_tag="$2"
  shift 2
  local -a label_kv=("$@")

  # Read the source image's config so the FROM-scratch snapshot can re-apply
  # USER/WORKDIR/ENV/CMD/ENTRYPOINT -- without them the restored container has
  # no command and `container create` fails ("command/entrypoint not specified").
  # apple/container's inspect has no Go-template --format, so the config is read
  # from JSON via jq. jq is optional elsewhere in dce; without it the snapshot is
  # bare (metadata lost) and restore will fail.
  local image_ref="" cfg_user="" cfg_workdir="" cfg_env="" cfg_cmd="" cfg_entrypoint=""
  if command -v jq >/dev/null 2>&1; then
    image_ref="$(container inspect "$container_name" 2>/dev/null \
      | jq -r '.[0].configuration.image.reference // empty')"
    if [[ -n "$image_ref" ]]; then
      local img_json
      img_json="$(container image inspect "$image_ref" 2>/dev/null || true)"
      if [[ -n "$img_json" ]]; then
        # .config.config is the OCI config object; arrays emit empty when
        # null/[] so CMD/ENTRYPOINT are omitted rather than printed as [].
        cfg_user="$(printf '%s' "$img_json" | jq -r '.[0].variants[0].config.config.user // empty')"
        cfg_workdir="$(printf '%s' "$img_json" | jq -r '.[0].variants[0].config.config.WorkingDir // empty')"
        cfg_env="$(printf '%s' "$img_json" | jq -r '.[0].variants[0].config.config.Env[]?')"
        # Arrays: emit the JSON form only when non-empty so CMD/ENTRYPOINT are
        # omitted (not printed as []) when the source image has none.
        cfg_cmd="$(printf '%s' "$img_json" | jq -rc '(.[0].variants[0].config.config.Cmd // []) | if length > 0 then . else empty end')"
        cfg_entrypoint="$(printf '%s' "$img_json" | jq -rc '(.[0].variants[0].config.config.Entrypoint // []) | if length > 0 then . else empty end')"
      fi
    fi
  else
    dce_warn "apple snapshots require jq to copy image config; '$container_name' snapshot will lack USER/CMD/ENTRYPOINT and may fail to restore."
  fi

  local work_dir=""
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dce-snap.XXXXXX")" || {
    echo "ERROR: could not create a temp dir for the apple snapshot build." >&2
    return 1
  }
  # Normalize: $TMPDIR ends with "/", so the raw path contains "//" which
  # apple/container's builder rejects with "X is not a child of Y" when it is
  # passed as the build context. cd -P resolves the "//" and the /var symlink.
  work_dir="$(cd -P "$work_dir" && pwd)"
  local tar_file="$work_dir/rootfs.tar"
  local cfile="$work_dir/Containerfile"

  if ! container export -o "$tar_file" "$container_name" >/dev/null 2>&1; then
    rm -rf "$work_dir"
    echo "ERROR: apple/container export failed for '$container_name'." >&2
    echo "       Ensure the container is stopped before snapshotting." >&2
    return 1
  fi

  {
    printf 'FROM scratch\n'
    printf 'ADD rootfs.tar /\n'
    [[ -n "$cfg_user" ]] && printf 'USER %s\n' "$cfg_user"
    [[ -n "$cfg_workdir" ]] && printf 'WORKDIR %s\n' "$cfg_workdir"
    if [[ -n "$cfg_env" ]]; then
      local env_line=""
      while IFS= read -r env_line; do
        [[ -n "$env_line" ]] && printf 'ENV %s\n' "$env_line"
      done <<< "$cfg_env"
    fi
    # cfg_cmd / cfg_entrypoint are already JSON exec-form arrays (["a","b"]).
    [[ -n "$cfg_cmd" ]] && printf 'CMD %s\n' "$cfg_cmd"
    [[ -n "$cfg_entrypoint" ]] && printf 'ENTRYPOINT %s\n' "$cfg_entrypoint"
    if [[ ${#label_kv[@]} -gt 0 ]]; then
      local kv=""
      printf 'LABEL'
      for kv in "${label_kv[@]}"; do
        [[ -n "$kv" ]] && printf ' %s' "$kv"
      done
      printf '\n'
    fi
  } > "$cfile"

  # Route through backend_build_image so the snapshot build gets the same
  # peer-backend fallback as dce-base when apple's native builder can't complete
  # it in the current environment (no build-context transfer). Native is tried
  # first; the FROM-scratch+ADD build only falls back if context transfer fails.
  if ! backend_build_image "$image_tag" "$cfile" "$work_dir" >/dev/null 2>&1; then
    rm -rf "$work_dir"
    echo "ERROR: apple/container build failed for snapshot '$image_tag'." >&2
    return 1
  fi

  rm -rf "$work_dir"
}

# Commit a container's filesystem to <image_tag> as a new image. Captures the
# image + writable layer only (never named volumes or the bind-mounted repo),
# matching `export` semantics. Optional label_kv pairs ("key=value") are stamped
# as OCI image labels for snapshot provenance. The caller MUST ensure the
# container is stopped first: a clean commit (and apple's export) require it.
#
# docker/orbstack/colima/podman use native `<cli> commit`, which carries USER,
# ENV, WORKDIR, CMD, ENTRYPOINT, and existing labels forward automatically.
# apple/container has no commit/import, so it composes export + FROM-scratch
# build and re-applies base metadata (see _backend_apple_container_commit).
backend_container_commit() {
  local container_name="$1"
  local image_tag="$2"
  shift 2
  local -a label_kv=("$@")

  local backend=""
  backend="$(backend_name)" || return 1

  case "$backend" in
    docker|orbstack|colima|podman)
      local -a args=("commit")
      local kv=""
      for kv in "${label_kv[@]:-}"; do
        [[ -n "$kv" ]] || continue
        args+=(--change "LABEL $kv")
      done
      args+=("$container_name" "$image_tag")
      "$(backend_cli)" "${args[@]}" >/dev/null
      ;;
    apple)
      _backend_apple_container_commit "$container_name" "$image_tag" "${label_kv[@]:-}"
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
# Structured args keep the user-facing shape uniform: follow=true attaches
# (-f, blocks until interrupted); tail (empty or integer N) limits output to
# the last N lines. The follow flag (-f) is identical on every backend; the
# tail flag is NOT -- docker/orbstack/colima/podman take `--tail N`, while
# apple/container has no `--tail` and exposes line count as `-n N` -- so the
# flag is translated per backend to keep `dce logs --tail` working everywhere.
backend_logs() {
  local name="$1"
  local follow="$2"
  local tail="${3:-}"

  local backend=""
  backend="$(backend_name)" || return 1

  local -a log_args=()
  if [[ "$follow" == "true" ]]; then
    log_args+=("-f")
  fi
  if [[ -n "$tail" ]]; then
    if [[ "$backend" == "apple" ]]; then
      log_args+=("-n" "$tail")
    else
      log_args+=("--tail" "$tail")
    fi
  fi

  case "$backend" in
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
# is pinned in tests/contract/backend-dispatch.sh.
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
