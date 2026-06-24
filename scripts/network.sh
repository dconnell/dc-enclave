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

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/container-backend.sh"
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

SUBACTION="${1:-}"
[[ $# -gt 0 ]] && shift

# --- create ------------------------------------------------------------------
do_create() {
  local name=""
  local create_failed=0
  local -a subnet_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subnet)
        [[ $# -ge 2 ]] || { echo "ERROR: --subnet requires a CIDR argument" >&2; exit 1; }
        dce_validate_subnet_value "$2" || exit 1
        subnet_args+=(--subnet "$2")
        shift 2
        ;;
      --subnet-v6)
        [[ $# -ge 2 && "$2" != --* ]] || { echo "ERROR: --subnet-v6 requires a CIDR argument" >&2; exit 1; }
        subnet_args+=(--subnet-v6 "$2")
        shift 2
        ;;
      --*)
        echo "ERROR: Unknown option: $1" >&2; exit 1
        ;;
      *)
        [[ -z "$name" ]] || { echo "ERROR: Unexpected argument: $1" >&2; exit 1; }
        name="$1"; shift
        ;;
    esac
  done

  [[ -n "$name" ]] || { echo "ERROR: network create requires a <name>" >&2; USAGE >&2; exit 1; }
  if ! dce_validate_network_name "$name"; then
    echo "ERROR: Invalid network name '$name'." >&2
    echo "  Allowed pattern: ^[a-z0-9][a-z0-9._-]*$" >&2
    exit 1
  fi

  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

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
    echo "ERROR: Failed to create network '$name'." >&2
    if [[ "$backend" == "apple" ]]; then
      echo "       apple/container requires macOS 26+ for user-defined networks." >&2
      echo "       Verify macOS version, or use a Docker-compatible backend." >&2
    fi
    exit 1
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
  [[ -n "$name" ]] || { echo "ERROR: network members requires a <name>" >&2; exit 1; }
  dce_validate_network_name "$name" || { echo "ERROR: Invalid network name '$name'" >&2; exit 1; }

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
      --*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
      *) [[ -z "$name" ]] || { echo "ERROR: Unexpected argument: $1" >&2; exit 1; }
         name="$1"; shift ;;
    esac
  done

  [[ -n "$name" ]] || { echo "ERROR: network rm requires a <name>" >&2; exit 1; }
  dce_validate_network_name "$name" || { echo "ERROR: Invalid network name '$name'" >&2; exit 1; }

  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  local refs; refs="$(dce_network_referencing_projects "$name")"

  if [[ -n "$refs" ]]; then
    if ! $force; then
      echo "ERROR: Network '$name' still has dce members: $refs" >&2
      echo "       Detach them first: dce network remove $name <project>" >&2
      echo "       Or force removal with: dce network rm $name --force" >&2
      exit 1
    fi
    echo "WARNING: --force disconnecting live containers: $refs" >&2
    if [[ "$backend" == "apple" ]]; then
      echo "ERROR: apple/container cannot detach networks from existing containers." >&2
      echo "       Remove the network from each project's config and rebuild them." >&2
      exit 1
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
        [[ $# -ge 2 && "$2" != --* ]] || { echo "ERROR: --ip requires an address" >&2; exit 1; }
        ip="$2"; shift 2
        ;;
      --*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
      *)
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$project" ]]; then project="$1"
        else echo "ERROR: Unexpected argument: $1" >&2; exit 1; fi
        shift
        ;;
    esac
  done

  [[ -n "$name" && -n "$project" ]] || { echo "ERROR: network add requires <name> <project>" >&2; exit 1; }
  dce_validate_network_name "$name" || { echo "ERROR: Invalid network name '$name'" >&2; exit 1; }
  [[ -z "$ip" ]] || dce_validate_ip_value "$ip" || exit 1

  local config="$HOME/.config/dce-enclave/$project/config"
  [[ -f "$config" ]] || { echo "ERROR: No config for project '$project'." >&2; exit 1; }

  PORTS=(); CONTAINER_HIDDEN_PATHS=(); CONTAINER_NETWORKS=()
  dce_load_project_config "$config"
  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  if ! backend_is_docker_compatible "$backend"; then
    echo "ERROR: 'dce network add' is unsupported on backend '$backend'." >&2
    echo "       apple/container sets networks only at create time." >&2
    echo "       Add the network at creation: dce new $project --network $name" >&2
    echo "       Or rebuild with it: edit config, then dce rebuild-container $project" >&2
    exit 1
  fi

  if ! backend_network_exists "$name"; then
    echo "ERROR: Network '$name' does not exist on backend '$backend'." >&2
    echo "       Create it first: dce network create $name" >&2
    exit 1
  fi

  if ! backend_exists "$project"; then
    echo "ERROR: Container '$project' does not exist on backend '$backend'." >&2
    exit 1
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
  local -a newnets=() nname
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
  [[ -n "$name" && -n "$project" ]] || { echo "ERROR: network remove requires <name> <project>" >&2; exit 1; }
  dce_validate_network_name "$name" || { echo "ERROR: Invalid network name '$name'" >&2; exit 1; }

  local config="$HOME/.config/dce-enclave/$project/config"
  [[ -f "$config" ]] || { echo "ERROR: No config for project '$project'." >&2; exit 1; }

  PORTS=(); CONTAINER_HIDDEN_PATHS=(); CONTAINER_NETWORKS=()
  dce_load_project_config "$config"
  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  if ! backend_is_docker_compatible "$backend"; then
    echo "ERROR: 'dce network remove' is unsupported on backend '$backend'." >&2
    echo "       Rebuild the container without this network instead." >&2
    exit 1
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
