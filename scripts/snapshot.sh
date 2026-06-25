#!/usr/bin/env bash
# =============================================================================
# scripts/snapshot.sh - `dce snapshot` / `dce snapshots`: save a project
# container's filesystem to a tagged image so you can get back to that state
# later.
#
# A snapshot commits a project container's filesystem (image + writable layer;
# never named volumes or the bind-mounted repo) to a tagged image. It is an
# independent operation you can run at any time -- before a risky change, before
# a rebuild, or simply to preserve a state -- and snapshots live in the active
# backend's local image store only. Restoring one is opt-in via
# `dce rebuild-container --from-snap`.
#
# Surface (one dispatcher, three modes):
#   dce snapshot  <project> [<label>]         commit the container FS to
#                                             dce-snap-<slug>-<label>:latest
#   dce snapshot  rm <project> <label>        remove one snapshot image
#   dce snapshots list [<project>]            list snapshots (with sizes)
#
# Semantics are filesystem-layer only. A snapshot is stop -> commit -> start
# (export / a clean commit require a stopped container on every backend).
# Restore is via `dce rebuild-container <project> --from-snap <label>`, which
# recreates from the snapshot without rewriting CONTAINER_IMAGE. Reclamation is
# manual via `dce clean --snapshots [<project>]`; the default `dce clean` sweep
# already ignores dce-snap-* repos.
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

USAGE() {
  cat <<'EOF'
Usage: dce snapshot <project> [<label>]
       dce snapshot rm <project> <label>
       dce snapshots list [<project>]

Commit a project container's filesystem to a tagged image, saving a state you
can return to later -- before a risky change, before a rebuild, or any time you
want a save point. Filesystem-layer only: the image plus the writable layer.
Named volumes (node_modules, caches) and the bind-mounted repo are NEVER
captured.

  snapshot <project> [<label>]
          Stop -> commit -> restart the container, producing
          dce-snap-<project>-<label>:latest. <label> defaults to a sortable
          timestamp (YYYYmmdd-HHMMSS). Refuses to overwrite an existing label.

  snapshot rm <project> <label>
          Remove one snapshot image. Convenience for `dce clean --snapshots`.

  snapshots list [<project>]
          List snapshots (newest-first), with project, base image, time, and
          size. Optional <project> scopes to that project.

Restore a snapshot with:
  dce rebuild-container <project> --from-snap <label>

Reclaim snapshots with:
  dce clean --snapshots [<project>] [--dry-run]
EOF
}

# Human-readable byte count (1024-based) for display. Empty input -> "?".
_fmt_size() {
  local bytes="$1"
  [[ -n "$bytes" ]] || { printf '?'; return 0; }
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    awk -v b="$bytes" 'BEGIN {
      split("B KB MB GB TB", u, " ")
      i = 1
      while (b >= 1024 && i < 5) { b /= 1024; i++ }
      printf("%.1f%s", b, u[i])
    }'
  else
    printf '?'
  fi
}

# --- create -------------------------------------------------------------------
do_create() {
  local project="" label=""
  project="${1:-}"
  label="${2:-}"

  [[ -n "$project" ]] || { echo "ERROR: snapshot requires a <project>." >&2; USAGE >&2; exit 1; }

  if [[ $# -gt 2 ]]; then
    echo "ERROR: Unexpected argument(s): ${*:3}" >&2
    USAGE >&2
    exit 1
  fi

  if [[ -z "$label" ]]; then
    label="$(date -u +%Y%m%d-%H%M%S)"
  else
    if ! dce_validate_snapshot_label "$label"; then
      echo "ERROR: Invalid snapshot label '$label'." >&2
      echo "  Allowed pattern: ^[A-Za-z0-9_.-]+\$ (no spaces, '/', or ':')." >&2
      exit 1
    fi
  fi

  local config="$HOME/.config/dce-enclave/$project/config"
  if [[ ! -f "$config" ]]; then
    echo "ERROR: No project '$project' (config not found)." >&2
    exit 1
  fi

  dce_load_project_config "$config"
  if [[ -z "${CONTAINER_PROJECT:-}" ]]; then
    CONTAINER_PROJECT="$project"
  fi

  dce_load_global_config

  local slug="" snap_ref=""
  slug="$(dce_project_slug "$project")"
  snap_ref="$(dce_snapshot_ref "$project" "$label")"

  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  if ! backend_exists "$project"; then
    echo "ERROR: container '$project' does not exist on backend '$backend'." >&2
    echo "       Snapshots commit a running container's filesystem." >&2
    exit 1
  fi

  if backend_image_exists "$snap_ref"; then
    echo "ERROR: a snapshot with label '$label' already exists for '$project':" >&2
    echo "         $snap_ref" >&2
    echo "       Reclaim it first with: dce snapshot rm $project $label" >&2
    exit 1
  fi

  local was_running=false
  if backend_is_running "$project"; then
    was_running=true
  fi

  echo "==> Snapshotting '$project' -> $snap_ref (backend: $backend)"
  echo "    Filesystem-layer only (named volumes and the repo are not captured)."

  if $was_running; then
    echo "==> Stopping container (a clean commit requires a stopped container)..."
    backend_stop "$project"
  fi

  local base_ref="${CONTAINER_IMAGE:-}"
  local snap_utc; snap_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # OCI image labels carry snapshot provenance (distinct from the overlay-derived
  # dce.team.* / dce.content.* labels a scope-built image carries). base records
  # the image the container was running; it is NOT the project's configured image
  # after restore.
  if ! backend_container_commit "$project" "$snap_ref" \
        "dce.snapshot.project=$slug" \
        "dce.snapshot.label=$label" \
        "dce.snapshot.base=$base_ref" \
        "dce.snapshot.utc=$snap_utc"; then
    echo "ERROR: snapshot commit failed." >&2
    if $was_running; then
      echo "  (restarting container to restore its running state)" >&2
      backend_start "$project" || true
    fi
    exit 1
  fi

  if $was_running; then
    echo "==> Restarting container..."
    backend_start "$project"
  fi

  # Record a provenance event so the project log stays honest about where this
  # image came from (it is not a scope-derived build). Best-effort: never abort a
  # successful snapshot on a provenance-write failure.
  local snap_id=""
  snap_id="$(backend_image_id "$snap_ref" 2>/dev/null || true)"
  dce_log_provenance "$project" "$snap_ref" "snapshot" \
    "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}" "$snap_id" 2>/dev/null || true

  echo ""
  echo "  ✓ Snapshot created: $snap_ref"
  echo ""
  echo "Restore with:"
  echo "    dce rebuild-container $project --from-snap $label"
  echo "List with:"
  echo "    dce snapshots list $project"
  echo "Reclaim with:"
  echo "    dce clean --snapshots $project --dry-run"
}

# --- rm -----------------------------------------------------------------------
do_rm() {
  local project="${1:-}"
  local label="${2:-}"

  [[ -n "$project" ]] || { echo "ERROR: snapshot rm requires <project> <label>." >&2; USAGE >&2; exit 1; }
  [[ -n "$label" ]]   || { echo "ERROR: snapshot rm requires <project> <label>." >&2; USAGE >&2; exit 1; }
  if [[ $# -gt 2 ]]; then
    echo "ERROR: Unexpected argument(s): ${*:3}" >&2
    USAGE >&2
    exit 1
  fi
  if ! dce_validate_snapshot_label "$label"; then
    echo "ERROR: Invalid snapshot label '$label'." >&2
    exit 1
  fi

  backend_use "${CONTAINER_BACKEND:-}"

  local snap_ref=""
  snap_ref="$(dce_snapshot_ref "$project" "$label")"

  if ! backend_image_exists "$snap_ref"; then
    echo "ERROR: no snapshot '$label' for '$project' ($snap_ref)." >&2
    echo "       Run: dce snapshots list $project" >&2
    exit 1
  fi

  backend_remove_image "$snap_ref"
  echo "Removed snapshot: $snap_ref"
}

# --- list ---------------------------------------------------------------------
do_list() {
  local project="${1:-}"

  if [[ $# -gt 1 ]]; then
    echo "ERROR: Unexpected argument(s): ${*:2}" >&2
    USAGE >&2
    exit 1
  fi

  backend_use "${CONTAINER_BACKEND:-}"
  local backend; backend="$(backend_name)"

  # Build slug -> project-name map from active configs so a snapshot can be
  # attributed to its project and labeled. Snapshots whose project is gone
  # (orphan) fall back to their slug.
  declare -A slug_to_project=()
  local cfg_dir="$HOME/.config/dce-enclave"
  local d="" pname="" pslug=""
  if [[ -d "$cfg_dir" ]]; then
    for d in "$cfg_dir"/*; do
      [[ -d "$d" && -f "$d/config" ]] || continue
      pname="$(basename "$d")"
      pslug="$(dce_project_slug "$pname")"
      # First project wins on slug collision (slugs truncate at 24 chars).
      [[ -n "${slug_to_project[$pslug]:-}" ]] || slug_to_project["$pslug"]="$pname"
    done
  fi

  local target_slug=""
  if [[ -n "$project" ]]; then
    target_slug="$(dce_project_slug "$project")"
    if [[ ! -d "$cfg_dir/$project" ]]; then
      echo "ERROR: No project '$project' (config not found)." >&2
      exit 1
    fi
  fi

  # Collect snapshot repos: repo \t size \t base \t utc, plus resolved label.
  local snap_prefix="dce-snap-"
  local -a rows=()
  local repo="" tag=""
  # shellcheck disable=SC2034
  # image_id (3rd field) is read to keep `tag` clean but is not used here.
  while IFS=$'\t' read -r repo tag id; do
    [[ "$repo" == "$snap_prefix"* ]] || continue
    [[ "$tag" == "latest" ]] || continue

    # repo == dce-snap-<slug>-<label>. Find the slug from known projects; the
    # label is everything after "dce-snap-<slug>-". Orphan -> unknown slug.
    local rest="${repo#dce-snap-}"
    local matched_slug="" matched_project="" label=""
    local s=""
    for s in "${!slug_to_project[@]}"; do
      local pref="dce-snap-$s-"
      if [[ "$repo" == "$pref"* ]]; then
        # Prefer the longest matching slug (most-specific project).
        if [[ ${#s} -gt ${#matched_slug} ]]; then
          matched_slug="$s"
          matched_project="${slug_to_project[$s]}"
        fi
      fi
    done

    if [[ -n "$matched_slug" ]]; then
      label="${repo#dce-snap-"$matched_slug"-}"
    else
      # Orphan: cannot reliably split slug from label; show the raw repo tail.
      matched_project="(orphan)"
      label="$rest"
    fi

    if [[ -n "$target_slug" && "$matched_slug" != "$target_slug" ]]; then
      continue
    fi

    local ref="$repo:$tag"
    local size="" base="" utc=""
    size="$(backend_image_size "$ref" 2>/dev/null || true)"
    base="$(backend_image_label "$ref" "dce.snapshot.base" 2>/dev/null || true)"
    utc="$(backend_image_label "$ref" "dce.snapshot.utc" 2>/dev/null || true)"

    rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$label" "$matched_project" "$base" "$utc" "$size")")
  done < <(backend_list_images 2>/dev/null)

  echo "Snapshots (backend: $backend):"
  if [[ ${#rows[@]} -eq 0 ]]; then
    if [[ -n "$project" ]]; then
      echo "  (no snapshots for '$project')"
    else
      echo "  (no snapshots)"
    fi
    echo ""
    echo "Create one with: dce snapshot <project> [<label>]"
    exit 0
  fi

  echo ""
  printf '  %-20s %-18s %-10s %-22s %s\n' "LABEL" "PROJECT" "SIZE" "UTC" "BASE"
  # Newest-first: sort by label descending (the default timestamp label is sortable).
  local row=""
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local rlabel="" rproj="" rbase="" rutc="" rsize=""
    IFS=$'\t' read -r rlabel rproj rbase rutc rsize <<< "$row"
    [[ -z "$rbase" ]] && rbase="-"
    [[ -z "$rutc" ]] && rutc="-"
    printf '  %-20s %-18s %-10s %-22s %s\n' "$rlabel" "$rproj" "$(_fmt_size "$rsize")" "$rutc" "$rbase"
  done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1r)

  echo ""
  echo "Restore:    dce rebuild-container <project> --from-snap <label>"
  echo "Reclaim:    dce clean --snapshots [<project>] [--dry-run]"
}

# --- dispatch -----------------------------------------------------------------
case "${1:-}" in
  rm)
    shift
    do_rm "$@"
    ;;
  list)
    shift
    do_list "$@"
    ;;
  ""|-h|--help|help)
    USAGE
    ;;
  *)
    # create: $1 is the project (treat a leading unknown --flag as an error).
    if [[ "${1:-}" == --* ]]; then
      echo "ERROR: Unknown option: $1" >&2
      USAGE >&2
      exit 1
    fi
    do_create "$@"
    ;;
esac
