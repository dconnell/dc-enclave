#!/usr/bin/env bash
# =============================================================================
# scripts/snapshot.sh - `dce snapshot` / `dce snapshots`: save a project
# container's filesystem AND hidden volumes to a tagged image so you can get
# back to that state later.
#
# A snapshot is a complete restore point: it commits the container's filesystem
# (image + writable layer) to dce-snap-<slug>-<label>:latest AND, by default,
# clones each hidden volume into dce-snapvol-<slug>-<label>-<hash> (source
# mounted read-only). It never captures the bind-mounted repo (host state), and
# injected credentials (SSH deploy key, git token) are scrubbed from the
# writable layer before the commit so they are never baked into the image --
# snapshot images are still shareable artifacts, so treat them as sensitive if
# you export or share one. It is an independent operation you can run at any
# time -- before a risky change, before a rebuild, or simply to preserve a
# state -- and snapshots live in the active backend's local image store only.
# Restoring one is opt-in via `dce rebuild-container --from-snap`.
#
# Surface (one dispatcher, three modes):
#   dce snapshot  <project> [<label>] [--exclude-volumes]
#                                             commit the container FS (+ hidden
#                                             volumes by default) to
#                                             dce-snap-<slug>-<label>:latest
#   dce snapshot  rm <project> <label>        remove one snapshot image
#   dce snapshots list [<project>]            list snapshots (with sizes)
#
# A snapshot is scrub -> stop -> commit -> start -> re-inject: injected
# credentials are removed from the writable layer while the container is still
# running (every backend's exec needs a live target), then re-seeded after the
# restart so the live container keeps working git/ssh (export / a clean commit
# require a stopped container on every backend); volume copies run in the same
# stop window. Restore is via `dce rebuild-container <project> --from-snap <label>`,
# which always isolates hidden volumes (populated where captured, empty
# otherwise) without rewriting CONTAINER_IMAGE. Reclamation is
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
Usage: dce snapshot <project> [<label>] [--exclude-volumes] [--exclude-volume <path>...] [--yes|-y]
       dce snapshot rm <project> <label>
       dce snapshots list [<project>]

Commit a project container's filesystem AND hidden volumes to a tagged image,
saving a state you can return to later -- before a risky change, before a
rebuild, or any time you want a save point. A snapshot is a complete restore
point: the image plus each hidden volume (node_modules, caches) cloned into a
snapshot-specific volume. The bind-mounted repo is NEVER captured (it is host
state). Injected credentials (SSH deploy key, git token) are scrubbed before
commit so they are never baked into the image -- but snapshot images are
shareable, so treat them as sensitive if you export or share one.

  snapshot <project> [<label>]
          Scrub -> stop -> commit -> restart -> re-inject the container,
          producing dce-snap-<project>-<label>:latest, and clone each hidden volume into
          dce-snapvol-<project>-<label>-<hash> with the source mounted READ-ONLY
          (a copy bug can never corrupt the live volume). <label> defaults to a
          sortable timestamp (YYYYmmdd-HHMMSS). Refuses to overwrite an existing
          label. A failed volume copy does NOT abort the snapshot: the path is
          recorded failed and restored empty with a WARNING.

          Because volume capture copies each volume (slow / disk-heavy), the
          command lists the volumes it will copy and asks for confirmation
          first. --yes/-y skips the prompt.

  snapshot <project> <label> --exclude-volumes
          Skip ALL volume capture (filesystem image only). Excluded volumes come
          back EMPTY on restore -- never silently reused from the live volumes.
          No confirmation prompt (nothing to copy).

  snapshot <project> <label> --exclude-volume <path[,path...]>
          Exclude specific hidden volumes only (repeatable; comma-separated).
          The rest are captured. Useful for "everything except the huge
          node_modules". Unknown paths are warned and ignored.

  snapshot rm <project> <label>
          Remove one snapshot image, its captured volumes, and its manifest.

  snapshots list [<project>]
          List snapshots (newest-first), with project, size, volumes captured,
          time, and base image. Optional <project> scopes to that project.

Restore a snapshot with:
  dce rebuild-container <project> --from-snap <label>

A restore always isolates hidden volumes: each comes back populated (if
captured) or EMPTY with a warning (if excluded, the copy failed, or the path was
added after the snapshot). The live originals are left untouched. Restore never
reuses the live volumes and never fails fast over a missing volume.

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

# One-line volume summary for a snapshot, read from its manifest: "captured N"
# (+ " (M failed)" / " (E excluded)" as relevant), or "" when there are no
# hidden paths (filesystem image only, no manifest).
_vol_summary() {
  local project="$1" label="$2"
  local manifest=""
  manifest="$(dce_snapshot_volumes_manifest "$project" "$label")"
  [[ -f "$manifest" ]] || { printf ''; return 0; }
  local cap=0 fail=0 exc=0 p="" state=""
  while IFS=$'\t' read -r p _ state || [[ -n "$p" ]]; do
    case "$state" in
      captured) cap=$((cap + 1)) ;;
      failed)   fail=$((fail + 1)) ;;
      excluded) exc=$((exc + 1)) ;;
    esac
  done < "$manifest"
  [[ $cap -gt 0 || $fail -gt 0 || $exc -gt 0 ]] || return 0
  local out="captured $cap"
  [[ $fail -gt 0 ]] && out+=" ($fail failed)"
  [[ $exc  -gt 0 ]] && out+=" ($exc excluded)"
  printf '%s' "$out"
}

# --- create -------------------------------------------------------------------
do_create() {
  local project="" label=""
  local exclude_volumes=false
  local assume_yes=false
  local -a exclude_volume_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude-volumes)
        exclude_volumes=true
        shift
        ;;
      --exclude-volume)
        [[ $# -ge 2 && "$2" != --* ]] || {
          echo "ERROR: --exclude-volume requires a path (or comma-separated list)." >&2
          USAGE >&2
          exit 1
        }
        exclude_volume_args+=("$2")
        shift 2
        ;;
      --yes|-y)
        assume_yes=true
        shift
        ;;
      --help|-h)
        USAGE
        exit 0
        ;;
      --*)
        echo "ERROR: Unknown option: $1" >&2
        USAGE >&2
        exit 1
        ;;
      *)
        if [[ -z "$project" ]]; then
          project="$1"
        elif [[ -z "$label" ]]; then
          label="$1"
        else
          echo "ERROR: Unexpected argument: $1" >&2
          USAGE >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  [[ -n "$project" ]] || { echo "ERROR: snapshot requires a <project>." >&2; USAGE >&2; exit 1; }

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

  # Resolve the per-path exclusion set from --exclude-volume args. Each must be a
  # configured hidden path; an unknown one is warned and ignored (no-op). Bare
  # --exclude-volumes excludes all (handled separately via $exclude_volumes).
  declare -A exclude_set=()
  if [[ ${#exclude_volume_args[@]} -gt 0 ]]; then
    declare -A known_hidden=()
    local _hp=""
    for _hp in "${CONTAINER_HIDDEN_PATHS[@]:-}"; do
      [[ -n "$_hp" ]] && known_hidden["$_hp"]=1
    done
    local _arg="" _part=""
    for _arg in "${exclude_volume_args[@]}"; do
      IFS=',' read -r -a _parts <<< "$_arg"
      for _part in "${_parts[@]}"; do
        # trim surrounding whitespace
        _part="${_part#"${_part%%[![:space:]]*}"}"
        _part="${_part%"${_part##*[![:space:]]}"}"
        [[ -z "$_part" ]] && continue
        if [[ -n "${known_hidden[$_part]:-}" ]]; then
          exclude_set["$_part"]=1
        else
          echo "WARN: --exclude-volume '$_part' is not a configured hidden path; ignoring." >&2
        fi
      done
    done
  fi

  # The set of hidden volumes that will actually be copied (drives the
  # confirmation prompt and the copy loop). Empty when --exclude-volumes or when
  # every path is selectively excluded.
  local -a copy_paths=()
  if ! $exclude_volumes; then
    local _cp=""
    for _cp in "${CONTAINER_HIDDEN_PATHS[@]:-}"; do
      [[ -z "$_cp" ]] && continue
      [[ -n "${exclude_set[$_cp]:-}" ]] && continue
      copy_paths+=("$_cp")
    done
  fi

  # Confirmation gate: only when volumes will actually be copied (the expensive
  # part). Skipped for --exclude-volumes / no hidden paths / all selectively
  # excluded, and with --yes/-y. Mirrors rebuild-container / dce rm.
  if [[ ${#copy_paths[@]} -gt 0 ]] && ! $assume_yes; then
    echo "This snapshot will copy ${#copy_paths[@]} hidden volume(s):"
    local _vp=""
    for _vp in "${copy_paths[@]}"; do
      echo "  - $_vp"
    done
    echo "Copying is proportional to their size and may be slow / use significant disk."
    echo "(Use --exclude-volumes or --exclude-volume <path> to skip volumes;"
    echo " --yes/-y skips this prompt.)"
    read -r -p "Type 'yes' to continue: " _confirm
    if [[ "$_confirm" != "yes" ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  local was_running=false
  if backend_is_running "$project"; then
    was_running=true
  fi

  echo "==> Snapshotting '$project' -> $snap_ref (backend: $backend)"
  echo "    Injected credentials are scrubbed before commit; snapshot images are"
  echo "    shareable, so treat them as sensitive if you export or share one."
  if [[ ${#copy_paths[@]} -eq 0 ]]; then
    if $exclude_volumes || [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
      echo "    Filesystem image only (hidden volumes excluded; restored empty)."
    else
      echo "    Filesystem image (no hidden volumes to capture)."
    fi
  else
    echo "    Filesystem image + hidden volumes."
  fi

  # Injected credentials (the SSH deploy key at ~/.ssh/id_ed25519 and, under PAT
  # auth, ~/.git-credentials) live in the container's writable layer, so a plain
  # commit would bake them into the shareable snapshot image. Scrub them BEFORE
  # committing. Every backend's `exec` requires a RUNNING container, so the scrub
  # runs while the container is still up -- the writable layer survives stop and
  # start, so removing the files pre-stop still yields a credential-free image. A
  # container that was already stopped is started for the scrub and left stopped
  # again after the commit (its credentials are re-seeded by the next `dce start`).
  if ! $was_running; then
    echo "==> Starting the stopped container to scrub credentials before commit..."
    backend_start "$project"
  fi

  local cred_scrub_status="ok"
  if ! backend_exec "$project" sh -c 'rm -f ~/.ssh/id_ed25519 ~/.git-credentials' 2>/dev/null; then
    cred_scrub_status="failed"
    echo "WARNING: credential scrub did not complete; the snapshot image" >&2
    echo "         $snap_ref may still contain injected credentials." >&2
    echo "         Treat it as sensitive and avoid exporting or sharing it." >&2
  fi

  echo "==> Stopping container (a clean commit requires a stopped container)..."
  backend_stop "$project"

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
        "dce.snapshot.utc=$snap_utc" \
        "dce.snapshot.cred_scrub=$cred_scrub_status"; then
    echo "ERROR: snapshot commit failed." >&2
    if $was_running; then
      echo "  (restarting container to restore its running state)" >&2
      backend_start "$project" || true
    fi
    exit 1
  fi

  # --- Hidden-volume capture (DEFAULT; --exclude-volumes / --exclude-volume) -
  # Volumes are part of an overall snapshot: by default each hidden volume is
  # cloned into a snapshot-specific volume with the source mounted READ-ONLY, in
  # the SAME stop window as the FS commit (no second stop). The filesystem image
  # is the primary artifact and already succeeded, so volume capture is
  # best-effort: a copy failure does NOT abort -- it records the path as
  # `failed` (restore mounts an empty volume + WARNING). Excluded paths
  # (--exclude-volumes for all, or --exclude-volume for specific ones) are
  # recorded `excluded` (no copy; restore mounts empty + note). The manifest is
  # the COMPLETE per-path disposition so a restore never silently reuses the
  # live originals and can report populated vs empty per path.
  local vol_captured=0 vol_failed=0 vol_excluded=0
  if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
    local manifest_dir="" manifest_file=""
    manifest_dir="$(dce_snapshot_volumes_dir "$project")"
    manifest_file="$(dce_snapshot_volumes_manifest "$project" "$label")"
    mkdir -p "$manifest_dir"

    if [[ ${#copy_paths[@]} -eq 0 ]]; then
      echo ""
      echo "==> Skipping hidden volumes (excluded; restored empty)..."
    else
      echo ""
      echo "==> Capturing hidden volumes (source mounted read-only)..."
    fi
    local manifest_tmp=""
    manifest_tmp="$(mktemp)"
    local hp="" src_vol="" dst_vol=""
    for hp in "${CONTAINER_HIDDEN_PATHS[@]}"; do
      [[ -z "$hp" ]] && continue
      dst_vol="$(dce_snapshot_volume_name "$project" "$label" "$hp")"

      # Excluded (all via --exclude-volumes, or selectively via --exclude-volume).
      if $exclude_volumes || [[ -n "${exclude_set[$hp]:-}" ]]; then
        printf '%s\t%s\t%s\n' "$hp" "$dst_vol" "excluded" >> "$manifest_tmp"
        vol_excluded=$((vol_excluded + 1))
        echo "  ~ Excluded: $hp (restored empty)"
        continue
      fi

      src_vol="$(dce_hidden_volume_name "$project" "$hp")"
      if ! dce_hidden_volume_exists "$src_vol"; then
        # Source absent: record failed. Restore mounts dst (auto-created empty
        # on reference) -- isolated, never the original.
        printf '%s\t%s\t%s\n' "$hp" "$dst_vol" "failed" >> "$manifest_tmp"
        vol_failed=$((vol_failed + 1))
        echo "  WARNING: hidden volume '$src_vol' not present for '$hp';"
        echo "           restored with an empty volume (reinstall deps there)."
        continue
      fi

      if backend_volume_copy "$src_vol" "$dst_vol"; then
        printf '%s\t%s\t%s\n' "$hp" "$dst_vol" "captured" >> "$manifest_tmp"
        vol_captured=$((vol_captured + 1))
        echo "  ✓ Captured: $hp -> $dst_vol"
      else
        # dst was auto-created (empty) on reference; record failed and continue.
        printf '%s\t%s\t%s\n' "$hp" "$dst_vol" "failed" >> "$manifest_tmp"
        vol_failed=$((vol_failed + 1))
        echo "  WARNING: volume copy failed for '$hp';"
        echo "           restored with an empty volume (reinstall deps there)."
        echo "           (source was mounted read-only; the live volume is unchanged.)"
      fi
    done

    # Atomic install of the manifest, owner-only (parity with project config).
    mv "$manifest_tmp" "$manifest_file"
    chmod 600 "$manifest_file"
  fi

  if $was_running; then
    echo "==> Restarting container..."
    backend_start "$project"
    # Re-seed the credentials the scrub removed so the live container keeps
    # working git/ssh (mirrors `dce start`). A container that was already stopped
    # before the snapshot is left stopped; its credentials are re-injected by the
    # next `dce start`.
    if [[ -n "${SSH_KEY_PATH:-}" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
      if ! backend_exec "$project" test -f ~/.ssh/id_ed25519 2>/dev/null; then
        backend_exec "$project" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
        backend_exec_stdin "$project" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY_PATH"
      fi
    fi
    dce_ensure_git_credentials "$project"
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
  if [[ $vol_captured -gt 0 || $vol_failed -gt 0 || $vol_excluded -gt 0 ]]; then
    local vol_note="Volumes: captured $vol_captured"
    [[ $vol_failed -gt 0 ]] && vol_note+=" ($vol_failed failed -> empty)"
    [[ $vol_excluded -gt 0 ]] && vol_note+=" ($vol_excluded excluded -> empty)"
    echo "  $vol_note"
    echo "  Restore mounts snapshot volumes, leaving the originals untouched;"
    echo "  dce rebuild-container $project --from-snap $label reports each as populated/empty."
  fi
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

  # Reclaim any snapshot volumes this label captured (dce-snapvol-<slug>-<label>-*)
  # and the manifest. Prefix is constructed from known slug+label, so internal
  # dashes in the label don't matter.
  local slug=""
  slug="$(dce_project_slug "$project")"
  local vol_prefix="dce-snapvol-$slug-$label-"
  local listed_vol="" removed_vols=0
  while IFS= read -r listed_vol; do
    [[ -z "$listed_vol" ]] && continue
    [[ "$listed_vol" == "$vol_prefix"* ]] || continue
    if backend_remove_volume "$listed_vol" 2>/dev/null; then
      removed_vols=$((removed_vols + 1))
    fi
  done < <(backend_list_volumes 2>/dev/null)
  [[ $removed_vols -gt 0 ]] && echo "Removed $removed_vols snapshot volume(s)."

  local manifest_file=""
  manifest_file="$(dce_snapshot_volumes_manifest "$project" "$label")"
  # rm -f tolerates a missing manifest (filesystem-only snapshot has none).
  rm -f "$manifest_file"
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
  # image_id (3rd field) is read to keep `tag` clean but is not used here.
  while IFS=$'\t' read -r repo tag _id; do
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
    local size="" base="" utc="" vols=""
    size="$(backend_image_size "$ref" 2>/dev/null || true)"
    base="$(backend_image_label "$ref" "dce.snapshot.base" 2>/dev/null || true)"
    utc="$(backend_image_label "$ref" "dce.snapshot.utc" 2>/dev/null || true)"
    if [[ -n "$matched_project" && "$matched_project" != "(orphan)" ]]; then
      vols="$(_vol_summary "$matched_project" "$label")"
    fi

    rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$label" "$matched_project" "$base" "$utc" "$size" "$vols")")
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
  printf '  %-20s %-18s %-10s %-22s %-16s %s\n' "LABEL" "PROJECT" "SIZE" "UTC" "VOLUMES" "BASE"
  # Newest-first: sort by label descending (the default timestamp label is sortable).
  local row=""
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local rlabel="" rproj="" rbase="" rutc="" rsize="" rvols=""
    IFS=$'\t' read -r rlabel rproj rbase rutc rsize rvols <<< "$row"
    [[ -z "$rbase" ]] && rbase="-"
    [[ -z "$rutc" ]] && rutc="-"
    [[ -z "$rvols" ]] && rvols="-"
    printf '  %-20s %-18s %-10s %-22s %-16s %s\n' "$rlabel" "$rproj" "$(_fmt_size "$rsize")" "$rutc" "$rvols" "$rbase"
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
    # create: $1 is the project (or a leading --exclude-volumes/--help). Flags
    # are parsed by do_create, so don't pre-reject them here.
    do_create "$@"
    ;;
esac
