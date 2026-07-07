#!/usr/bin/env bash
# =============================================================================
# scripts/network.sh - `dce network`: manage private networks between containers.
#
# Networks are first-class daemon objects (created via `docker network create` /
# `container network create`). dce stores no subnet state: both backend families
# auto-allocate and validate overlap. Per-container membership lives in each
# project's config as CONTAINER_NETWORKS=( <name>[:<ip>] ... ); `add`/`remove`
# keep that config in sync so rebuilds re-attach deterministically.
#
# Subcommands: create, ls/list, members, rm, add, remove.
# =============================================================================
set -euo pipefail

_sub="${BASH_SOURCE[0]}"
while [[ -L "$_sub" ]]; do
  _d="$(cd -P "$(dirname "$_sub")" && pwd)"
  _sub="$(readlink "$_sub")"
  [[ "$_sub" != /* ]] && _sub="$_d/$_sub"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_sub")" && pwd)"
unset _sub _d
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/network.sh"

USAGE() {
  cat <<'EOF'
Usage: dce network <subcommand> [args]

Private networks that let dce containers talk to each other without publishing
ports to the host. Membership is explicit: containers are only linked when
placed on the same network on purpose.

Subcommands:
  create <name> [--subnet <cidr>] [--subnet-v6 <cidr>]
                              Create a private network (auto-allocates a subnet).
  ls | list                   List networks and their dce members.
  members <name>              Show which projects are on a network.
  rm <name> [--force]         Remove a network (refuses while members exist
                              unless --force).
  add <name> <project> [--ip <addr>]
                              Attach an existing container to a network.
                              (Docker-compatible backends only.)
  remove <name> <project>     Detach a container from a network.
                              (Docker-compatible backends only.)

Addressing:
  Containers on the same network resolve each other by project name. On
  docker/orbstack/colima/podman that is the bare name (e.g. myapp-db); on
  apple/container it is <name>.test. Static IPs are opt-in via --ip and are
  supported on Docker-compatible backends only.
EOF
}

usage_die() {
  local msg="$1"
  dce_die "$msg
Usage: dce network <subcommand> [args]
Subcommands: create, ls|list, members, rm, add, remove"
}

SUBACTION="${1:-}"
[[ $# -gt 0 ]] && shift

# --- create ------------------------------------------------------------------
do_create() {
  local name=""
  local create_failed=0
  local -a subnet_args=()
  local subnet_v6=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subnet)
        [[ $# -ge 2 ]] || dce_die "--subnet requires a CIDR argument"
        dce_validate_subnet_value "$2" || exit 1
        subnet_args+=(--subnet "$2")
        shift 2
        ;;
      --subnet-v6)
        [[ $# -ge 2 && "$2" != --* ]] || dce_die "--subnet-v6 requires a CIDR argument"
        # Validated/translated per-backend below (docker-family has no --subnet-v6
        # flag; dce_validate_subnet_value is IPv4-only so it is not applied here).
        subnet_v6="$2"
        shift 2
        ;;
      --*)
        dce_die "Unknown option: $1"
        ;;
      *)
        [[ -z "$name" ]] || dce_die "Unexpected argument: $1"
        name="$1"; shift
        ;;
    esac
  done

  [[ -n "$name" ]] || usage_die "network create requires a <name>"
  if ! dce_validate_network_name "$name"; then
    dce_die "Invalid network name '$name'.
  Allowed pattern: ^[a-z0-9][a-z0-9._-]*$"
  fi

  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  # Translate --subnet-v6 for the active backend. docker-family has no
  # --subnet-v6 flag (IPv6 uses `--ipv6` plus a v6 `--subnet`), so emit that
  # pair; apple/container's v6 flag surface is unverified, so pass it through
  # unchanged (apple network support is create-time-only either way).
  if [[ -n "$subnet_v6" ]]; then
    if [[ "$backend" == "apple" ]]; then
      subnet_args+=(--subnet-v6 "$subnet_v6")
    else
      subnet_args+=(--ipv6 --subnet "$subnet_v6")
    fi
  fi

  if backend_network_exists "$name"; then
    echo "Network '$name' already exists on backend '$backend'."
    exit 0
  fi

  echo "==> Creating network '$name' on backend '$backend'..."
  if [[ ${#subnet_args[@]} -gt 0 ]]; then
    if ! backend_network_create "$name" "${subnet_args[@]}"; then create_failed=1; fi
  else
    if ! backend_network_create "$name"; then create_failed=1; fi
  fi
  if [[ "${create_failed:-0}" -eq 1 ]]; then
    local _msg="Failed to create network '$name'."
    if [[ "$backend" == "apple" ]]; then
      _msg+="
       apple/container requires macOS 26+ for user-defined networks.
       Verify macOS version, or use a Docker-compatible backend."
    fi
    dce_die "$_msg"
  fi
  echo "  ✓ Created network '$name'"
}

# --- ls / list ---------------------------------------------------------------
do_list() {
  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  echo "Networks (backend: $backend):"
  echo ""
  local listed="" name="" members=""
  if ! listed="$(backend_network_list 2>/dev/null)"; then
    echo "  (could not list networks)"
    return 0
  fi
  if [[ -z "$listed" ]]; then
    echo "  (no networks)"
    return 0
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    members="$(dce_network_referencing_projects "$name")"
    if [[ -n "$members" ]]; then
      printf '  %-20s members: %s\n' "$name" "$members"
    else
      printf '  %-20s (no dce members)\n' "$name"
    fi
  done <<< "$listed"
}

# --- members -----------------------------------------------------------------
do_members() {
  local name="${1:-}"
  [[ -n "$name" ]] || dce_die "network members requires a <name>"
  dce_validate_network_name "$name" || dce_die "Invalid network name '$name'"

  local p ip any=0
  echo "Members of network '$name':"
  while IFS=$'\t' read -r p ip; do
    [[ -n "$p" ]] || continue
    any=1
    printf '  %-20s %s\n' "$p" "${ip:--}"
  done < <(dce_network_members_of "$name")
  [[ "$any" -eq 1 ]] || echo "  (no dce projects reference this network)"
}

# --- rm ----------------------------------------------------------------------
do_rm() {
  local name=""
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force|-f) force=true; shift ;;
      --*) dce_die "Unknown option: $1" ;;
      *) [[ -z "$name" ]] || dce_die "Unexpected argument: $1"
         name="$1"; shift ;;
    esac
  done

  [[ -n "$name" ]] || dce_die "network rm requires a <name>"
  dce_validate_network_name "$name" || dce_die "Invalid network name '$name'"

  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  local refs; refs="$(dce_network_referencing_projects "$name")"

  if [[ -n "$refs" ]]; then
    if ! $force; then
      dce_die "Network '$name' still has dce members: $refs
       Detach them first: dce network remove $name <project>
       Or force removal with: dce network rm $name --force"
    fi
    echo "WARNING: --force disconnecting live containers: $refs" >&2
    if [[ "$backend" == "apple" ]]; then
      dce_die "apple/container cannot detach networks from existing containers.
       Remove the network from each project's config and rebuild them."
    fi
    local p
    for p in $refs; do
      backend_network_disconnect "$name" "$p" || true
    done
    echo "  NOTE: project configs still reference '$name'; they will fail to start" >&2
    echo "        until you remove it (dce network remove $name <project>)." >&2
  fi

  echo "==> Removing network '$name'..."
  backend_network_rm "$name"
  echo "  ✓ Removed network '$name'"
}

# --- add ---------------------------------------------------------------------
do_add() {
  local name="" project="" ip=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        [[ $# -ge 2 && "$2" != --* ]] || dce_die "--ip requires an address"
        ip="$2"; shift 2
        ;;
      --*) dce_die "Unknown option: $1" ;;
      *)
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$project" ]]; then project="$1"
        else dce_die "Unexpected argument: $1"; fi
        shift
        ;;
    esac
  done

  [[ -n "$name" && -n "$project" ]] || dce_die "network add requires <name> <project>"
  dce_validate_network_name "$name" || dce_die "Invalid network name '$name'"
  [[ -z "$ip" ]] || dce_validate_ip_value "$ip" || exit 1

  local config="$HOME/.config/dce-enclave/$project/config"
  [[ -f "$config" ]] || dce_die "No config for project '$project'."

  PORTS=(); CONTAINER_HIDDEN_PATHS=(); CONTAINER_NETWORKS=()
  dce_load_project_config "$config"
  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  if ! backend_is_docker_compatible "$backend"; then
    dce_die "'dce network add' is unsupported on backend '$backend'.
       apple/container sets networks only at create time.
       Add the network at creation: dce new $project --network $name
       Or rebuild with it: edit config, then dce rebuild-container $project"
  fi

  if ! backend_network_exists "$name"; then
    dce_die "Network '$name' does not exist on backend '$backend'.
       Create it first: dce network create $name"
  fi

  if ! backend_exists "$project"; then
    dce_die "Container '$project' does not exist on backend '$backend'."
  fi

  # Skip silently if already a member (idempotent), but still apply the IP if given.
  local entry="$name"; [[ -n "$ip" ]] && entry="$name:$ip"
  local already=false e
  for e in "${CONTAINER_NETWORKS[@]:-}"; do
    if [[ "$(dce_network_entry_name "$e")" == "$name" ]]; then already=true; break; fi
  done

  echo "==> Attaching '$project' to network '$name'..."
  if [[ -n "$ip" ]]; then
    backend_network_connect "$name" "$project" --ip "$ip"
  else
    backend_network_connect "$name" "$project"
  fi

  # Persist so the next rebuild re-attaches. Replace any existing entry for name.
  local -a newnets=()
  for e in "${CONTAINER_NETWORKS[@]:-}"; do
    [[ -z "$e" ]] && continue
    [[ "$(dce_network_entry_name "$e")" == "$name" ]] && continue
    newnets+=("$e")
  done
  newnets+=("$entry")
  if [[ ${#newnets[@]} -gt 0 ]]; then
    dce_set_config_array "$config" CONTAINER_NETWORKS "${newnets[@]}"
  else
    dce_set_config_array "$config" CONTAINER_NETWORKS
  fi
  echo "  ✓ Attached (recorded in $project config)"
  [[ "$already" == true ]] && echo "  (was already a member; IP updated)" || true
}

# --- remove ------------------------------------------------------------------
do_remove() {
  local name="${1:-}"
  local project="${2:-}"
  [[ -n "$name" && -n "$project" ]] || dce_die "network remove requires <name> <project>"
  dce_validate_network_name "$name" || dce_die "Invalid network name '$name'"

  local config="$HOME/.config/dce-enclave/$project/config"
  [[ -f "$config" ]] || dce_die "No config for project '$project'."

  # shellcheck disable=SC2034
  # Reset before dce_load_project_config repopulates them; cleared to avoid
  # stale leakage. CONTAINER_NETWORKS is read below.
  PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
  dce_load_project_config "$config"
  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  if ! backend_is_docker_compatible "$backend"; then
    dce_die "'dce network remove' is unsupported on backend '$backend'.
       Rebuild the container without this network instead."
  fi

  # Persist removal regardless of live state, but attempt live disconnect first.
  backend_network_disconnect "$name" "$project" 2>/dev/null || true

  local -a newnets=() e found=false
  for e in "${CONTAINER_NETWORKS[@]:-}"; do
    [[ -z "$e" ]] && continue
    if [[ "$(dce_network_entry_name "$e")" == "$name" ]]; then found=true; continue; fi
    newnets+=("$e")
  done

  if [[ "$found" == false ]]; then
    echo "Project '$project' is not a member of network '$name'."
    exit 0
  fi

  if [[ ${#newnets[@]} -gt 0 ]]; then
    dce_set_config_array "$config" CONTAINER_NETWORKS "${newnets[@]}"
  else
    dce_set_config_array "$config" CONTAINER_NETWORKS
  fi
  echo "  ✓ Detached '$project' from network '$name' (updated $project config)"
}

case "$SUBACTION" in
  create)  do_create "$@" ;;
  ls|list) do_list "$@" ;;
  members) do_members "$@" ;;
  rm)      do_rm "$@" ;;
  add)     do_add "$@" ;;
  remove)  do_remove "$@" ;;
  ""|-h|--help|help) USAGE ;;
  *)
    echo "Unknown network subcommand: $SUBACTION" >&2
    USAGE >&2
    exit 1
    ;;
esac
