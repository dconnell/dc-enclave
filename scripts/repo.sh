#!/usr/bin/env bash
# =============================================================================
# scripts/repo.sh - `dce repo`: mutate the schema-v2 repo set for a project.
#
# Config-only command family for listing and editing REPO_NAMES/REPO_PATHS.
# Runtime mounts do not change until the user rebuilds the container.
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

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

USAGE() {
  cat <<'EOF'
Usage: dce repo list <project>
       dce repo add <project> [--yes|-y] <path>
       dce repo add <project> [--yes|-y] <name>=<path>
       dce repo remove <project> <name-or-path>
EOF
}

_repo_require_config() {
  local project="$1"
  local config=""
  config="$(dce_project_config_path "$project")"
  [[ -f "$config" ]] || dce_die "No config for project '$project'."
  printf '%s' "$config"
}

_repo_write_pairs() {
  local config="$1"
  shift
  local -a names=()
  local -a paths=()
  local pair=""
  for pair in "$@"; do
    names+=("${pair%%$'\t'*}")
    paths+=("${pair#*$'\t'}")
  done
  dce_set_repo_entries "$config" "${names[@]}" -- "${paths[@]}"
}

_repo_effective_path() {
  local path="$1"
  dce_resolve_path "$path" 2>/dev/null || dce_repo_path_canonical "$path"
}

_repo_maybe_confirm_outside_default_root() {  # <path> <label> <assume_yes>
  local path="$1" label="$2" assume_yes="$3"
  local default_root=""

  default_root="$(dce_default_repos_root)"
  default_root="$(dce_resolve_path "$default_root" 2>/dev/null || dce_repo_path_canonical "$default_root")"

  if [[ "$path" == "$default_root" || "$path" == "$default_root/"* ]]; then
    return 0
  fi

  echo "$label resolves outside the default repos directory:"
  echo "  resolved path : $path"
  echo "  default root  : $default_root"
  if [[ "$assume_yes" == true ]]; then
    echo "(--yes: honoring $label; it will be mounted read-write under /workspace after rebuild.)"
    return 0
  fi

  echo "Mounting it read-write under /workspace requires confirmation."
  local confirm=""
  read -r -p "Type 'yes' to continue: " confirm || confirm=""
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
}

do_list() {
  local project="${1:-}"
  [[ -n "$project" ]] || dce_die "repo list requires <project>"
  local config=""
  config="$(_repo_require_config "$project")"
  dce_load_project_config "$config"
  local line=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s=%s\n' "${line%%$'\t'*}" "${line#*$'\t'}"
  done < <(dce_repo_entries_lines)
}

do_add() {
  local assume_yes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        assume_yes=true
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        dce_die "Unknown option: $1
Usage: dce repo add <project> [--yes|-y] <path|name=path>"
        ;;
      *)
        break
        ;;
    esac
  done

  local project="${1:-}"
  local spec="${2:-}"
  [[ -n "$project" && -n "$spec" ]] || dce_die "repo add requires <project> <path|name=path>"

  local config=""
  config="$(_repo_require_config "$project")"
  dce_load_project_config "$config"

  local new_pair=""
  new_pair="$(dce_repo_spec_resolve "$spec")" || exit 1
  local new_name="${new_pair%%$'\t'*}"
  local new_path="${new_pair#*$'\t'}"

  if ! dce_validate_repo_path_not_repos_root_or_ancestor "$new_path" >&2; then
    exit 1
  fi
  _repo_maybe_confirm_outside_default_root "$new_path" "repo path" "$assume_yes"

  local -a pairs=()
  local line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && pairs+=("$line")
  done < <(dce_repo_entries_lines)
  pairs+=("$new_pair")

  local -a names=()
  local -a paths=()
  local -a validate_paths=()
  local pair=""
  for pair in "${pairs[@]}"; do
    names+=("${pair%%$'\t'*}")
    paths+=("${pair#*$'\t'}")
    validate_paths+=("$(_repo_effective_path "${pair#*$'\t'}")")
  done
  # shellcheck disable=SC2034  # consumed by dce_validate_repo_entries via globals
  REPO_NAMES=("${names[@]}")
  # shellcheck disable=SC2034  # consumed by dce_validate_repo_entries via globals
  REPO_PATHS=("${validate_paths[@]}")
  dce_validate_repo_entries >&2 || exit 1

  # Parity with `dce new`: create the target directory before it becomes a
  # bind source. A missing dir left to the backend would come into existence
  # root-owned inside the container, unwritable by the dev user.
  if ! mkdir -p "$new_path"; then
    dce_die "Could not create repo directory '$new_path' for repo '$new_name'."
  fi

  _repo_write_pairs "$config" "${pairs[@]}"
  echo "Updated repo set for '$project'."
  echo "Run 'dce rebuild-container $project' for the change to take effect."
}

do_remove() {
  local project="${1:-}"
  local target="${2:-}"
  [[ -n "$project" && -n "$target" ]] || dce_die "repo remove requires <project> <name-or-path>"

  local config=""
  config="$(_repo_require_config "$project")"
  dce_load_project_config "$config"

  local target_path=""
  if [[ "$target" == /* || "$target" == ~* || "$target" == ./* || "$target" == ../* ]]; then
    target_path="$(dce_expand_tilde "$target")"
    if [[ "$target_path" != /* ]]; then
      target_path="$PWD/$target_path"
    fi
    target_path="$(_repo_effective_path "$target_path")"
  fi

  local -a kept=()
  local removed=false
  local line="" name="" path=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    if [[ "$name" == "$target" || ( -n "$target_path" && "$(_repo_effective_path "$path")" == "$target_path" ) ]]; then
      removed=true
      continue
    fi
    kept+=("$line")
  done < <(dce_repo_entries_lines)

  [[ "$removed" == true ]] || dce_die "Repo '$target' not found in project '$project'."
  [[ ${#kept[@]} -gt 0 ]] || dce_die "A project must keep at least one repo."

  _repo_write_pairs "$config" "${kept[@]}"
  echo "Updated repo set for '$project'."
  echo "Run 'dce rebuild-container $project' for the change to take effect."
}

SUBACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$SUBACTION" in
  list)   do_list "$@" ;;
  add)    do_add "$@" ;;
  remove) do_remove "$@" ;;
  ""|-h|--help|help) USAGE ;;
  *)
    echo "Unknown repo subcommand: $SUBACTION" >&2
    USAGE >&2
    exit 1
    ;;
esac
