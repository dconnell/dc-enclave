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
# All per-backend logic (registry, docker-CLI plumbing, apple, colima,
# orbstack, podman) lives in lib/backends/*.sh, sourced below; this file stays
# the stable facade path and keeps only the generic backend_<op> dispatchers.
# =============================================================================
#
# Adding a backend (the layout's payoff; plans/cleanup-plan.md §9):
#   1. Create lib/backends/<name>.sh with an include guard
#      (_DC_BACKENDS_<NAME>_SH_LOADED) and implement only its deltas (context
#      pin, startup probe, capability predicates); docker-CLI-family backends
#      inherit argv/capture plumbing from lib/backends/docker-cli.sh.
#   2. Register it in lib/backends/registry.sh: append to DCE_BACKENDS (order
#      = detection priority) and add case arms in _backend_normalize (aliases),
#      _backend_cli_available, _backend_set_cli, and _backend_warn_missing_cli;
#      add the `if command -v <cli>` line to backend_detect_available (an
#      if-chain, not a case); then only the dispatchers below that diverge
#      (usually create/exec/build).
#   3. Add tests/contract/backend-<name>.sh: a conformance test sourcing ONLY
#      the new module (stub-CLI CALL matrix), like the existing backend-*.sh.
#   4. Sweep the remaining fixed touchpoints: doctor checks and docs mentions.
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
# Block class matched by _backend_apple_native_build_blocked: "" (no match) or
# egress|context|transport. Reset by the classifier on every call.
declare -g _DC_APPLE_BLOCK_CLASS=""

# Resolve our own directory once so the module sources below use a stable path
# regardless of how this facade was reached (script-relative, symlink, etc.).
_dce_backend_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the backend modules in dependency order (registry first: docker-cli.sh
# calls backend_name/backend_cli from it). Each carries its own include guard,
# so the modules are also safe to source directly from tests.
# shellcheck disable=SC1091
# Sibling lib include; path resolved above, not followed statically.
source "$_dce_backend_lib_dir/backends/registry.sh"
# shellcheck disable=SC1091
source "$_dce_backend_lib_dir/backends/docker-cli.sh"
# shellcheck disable=SC1091
source "$_dce_backend_lib_dir/backends/apple.sh"
# shellcheck disable=SC1091
source "$_dce_backend_lib_dir/backends/colima.sh"
# shellcheck disable=SC1091
source "$_dce_backend_lib_dir/backends/orbstack.sh"
# shellcheck disable=SC1091
source "$_dce_backend_lib_dir/backends/podman.sh"

unset _dce_backend_lib_dir

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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
      _backend_apple_build_image "$tag" "$file" "$context" "$@"
      ;;
    docker|orbstack|colima|podman)
      # Force BuildKit: composed images write their ENTRYPOINT via a multi-line
      # `RUN cat >f <<'EOF' ... EOF` shell heredoc, which the *legacy* Docker
      # builder (the default when dockerd is started bare, e.g. on WSL2) parses
      # as a one-line RUN and emits as an EMPTY file -- the container then exits
      # 255 on start. BuildKit parses the heredoc as one instruction and writes
      # it intact. BuildKit is the default on Docker 23+, so this is a no-op
      # there; podman ignores DOCKER_BUILDKIT.
      DOCKER_BUILDKIT=1 "$(backend_cli)" build --tag "$tag" --file "$file" "$@" "$context"
      ;;
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
  esac
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
      # names like "dce-base", "dce-img-<hash>", "dce-<project>", or
      # "dce-snap-<...>" see the same short repo as docker/orbstack/colima.
      # sed is not an early-exit reader, so
      # it cannot SIGPIPE the producer under pipefail.
      "$(backend_cli)" image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' \
        | sed -E 's|^localhost/||'
      ;;
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
  esac
}

# Apply an additional tag <dst_ref> to an existing image <src_ref>.
#
# Tags are applied POST-build only, never as extra build-time `--tag` flags:
# apple/container's peer-fallback build path (docker/podman build -> save ->
# `container image load`) silently drops extra build-time tags, so additional
# names (e.g. per-project dce-<project>:latest aliases) must be attached after
# the canonical image already exists in the backend's store. The backend CLI's
# exit code propagates; callers surface failures.
backend_tag_image() {
  local src_ref="$1"
  local dst_ref="$2"

  case "$(backend_name)" in
    apple)
      container image tag "$src_ref" "$dst_ref"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" tag "$src_ref" "$dst_ref"
      ;;
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
  esac
}

# Resolve the DNS nameserver IPs to pass to a container at create time (--dns).
# Prints one IP per line on stdout (empty output = pass no --dns). Semantics:
#   - $DCE_DNS overrides on every backend (comma- or space-separated). An empty
#     value (variable set but empty) opts out entirely.
#   - Otherwise the apple/container backend defaults to public resolvers, because
#     apple/container's auto-configured resolver (the vmnet gateway, e.g.
#     192.168.64.1) does not forward external DNS -- containers can reach IPs but
#     not resolve hostnames, breaking extension install / git over https / npm.
#   - Docker-compatible backends default to none: their embedded DNS resolver
#     (e.g. 127.0.0.11) already resolves correctly.
backend_dns_servers() {
  local backend="${1:-}"

  if [[ -v DCE_DNS ]]; then
    local raw="${DCE_DNS//,/ }"
    # shellcheck disable=SC2206  # word-split DCE_DNS tokens (IPs have no spaces) by design
    local -a parts=($raw)
    local s
    for s in "${parts[@]}"; do
      [[ -n "$s" ]] && printf '%s\n' "$s"
    done
    return 0
  fi

  if [[ "$backend" == "apple" ]]; then
    printf '%s\n' 1.1.1.1 8.8.8.8
  fi
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

  # DNS nameservers (apple defaults to public resolvers; DCE_DNS overrides on
  # every backend). --dns is accepted by `container create` and `docker create`.
  local dns_servers=""
  dns_servers="$(backend_dns_servers "$backend")"
  if [[ -n "$dns_servers" ]]; then
    local d
    while IFS= read -r d; do
      [[ -n "$d" ]] && create_args+=(--dns "$d")
    done <<< "$dns_servers"
  fi

  case "$backend" in
    apple)
      container create --name "$name" "${create_args[@]}" "$image"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" create --name "$name" "${create_args[@]}" "$image" >/dev/null
      ;;
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
  esac
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
  esac
}

# Run a command in a container as root (uid 0) with stdin attached (no TTY).
# Used to stream data into the container with root permissions, e.g. staging a
# hosts fragment at /tmp before an /etc/hosts reconcile -- system files the dev
# user cannot write directly.
backend_exec_stdin_as_root() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec -i --uid 0 "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -i -u 0 "$name" "$@"
      ;;
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
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
    *) dce_die "Unsupported backend '$(backend_name)'." ;;
  esac
}
