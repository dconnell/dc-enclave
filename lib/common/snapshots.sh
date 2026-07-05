#!/usr/bin/env bash
# =============================================================================
# lib/common/snapshots.sh - Snapshot image / volume naming and manifests.
#
# Sourced (never executed directly) via lib/common.sh. Pure naming/path helpers
# for the snapshot subsystem. Snapshot image repos (dce-snap-<slug>-<label>) and
# snapshot volumes (dce-snapvol-<slug>-<label>-<12hex>) are visually grouped with
# their project and kept distinct from dce-base / dce-img-* / dce-hide-* so the
# default image and hidden-volume sweeps ignore them. The volumes manifest is
# the COMPLETE mapping a restore trusts exclusively. Depends on core.sh
# (dce_project_slug, dce_sha256_hex).
# =============================================================================

if [[ -n "${_DC_COMMON_SNAPSHOTS_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_SNAPSHOTS_SH_LOADED=1

# Validate a snapshot label. Snapshot labels are embedded in image repository
# names (dce-snap-<slug>-<label>) and image-tag slots, so they must match the
# image-tag charset and never contain '/' or ':' (which would escape the ref).
dce_validate_snapshot_label() {
  local label="$1"
  [[ -n "$label" ]] || return 1
  [[ "$label" =~ ^[A-Za-z0-9_.-]+$ ]]
}

# Build the snapshot image reference: dce-snap-<project-slug>-<label>:latest.
# Mirrors dce-hide-<slug>-<hash> hidden-volume naming so snapshot repos are
# visually grouped with their project and excluded from the default image sweep
# (is_managed_repo only matches dce-base / dce-img-<16hex>).
dce_snapshot_ref() {
  local project="$1"
  local label="$2"

  printf 'dce-snap-%s-%s:latest\n' "$(dce_project_slug "$project")" "$label"
}

# Repo (repository name, no :tag) prefix for a project's snapshots, used to
# scope enumeration. dce-snap-<slug>-  — append a label (and :latest) for a ref.
dce_snapshot_repo_prefix() {
  local project="$1"
  printf 'dce-snap-%s-\n' "$(dce_project_slug "$project")"
}

# Build the snapshot-VOLUME name for a project hidden path under a given
# snapshot label: dce-snapvol-<slug>-<label>-<12hex>. Distinct from dce-hide-*
# (hidden volumes) and dce-snap-* (snapshot images) so default and hidden-
# volume sweeps ignore snapshot volumes; the <label> makes it snapshot-specific
# and addressable from the volumes manifest. The 12hex is derived from
# (project, label, path) so the name is reproducible from those three inputs.
dce_snapshot_volume_name() {
  local project="$1"
  local label="$2"
  local hidden_path="$3"

  local slug=""
  slug="$(dce_project_slug "$project")"

  local key="snapvol-v1|$project|$label|$hidden_path"
  local hash=""
  hash="$(dce_sha256_hex "$key")"
  hash="${hash:0:12}"

  printf 'dce-snapvol-%s-%s-%s\n' "$slug" "$label" "$hash"
}

# Directory holding a project's snapshot volume manifests (one per snapshot that
# captured volumes). Lives under the project config dir alongside secrets.
dce_snapshot_volumes_dir() {
  printf '%s/.config/dce-enclave/%s/snapshots\n' "$HOME" "$1"
}

# Path to the volumes manifest for a given snapshot label. The manifest is the
# COMPLETE mapping of the project's hidden paths -> snapshot volume at snapshot
# time, which is what makes "never fall back to the original volume" a structural
# invariant: restore trusts it exclusively. Absent => filesystem-only snapshot.
dce_snapshot_volumes_manifest() {
  printf '%s/%s.volumes\n' "$(dce_snapshot_volumes_dir "$1")" "$2"
}

# Echo the recorded disposition of a hidden path in a snapshot's manifest:
# "captured", "failed", or "excluded"; empty if the path is absent or the
# manifest is missing (restore treats empty as "not in snapshot" -> empty
# volume + warning). Used by restore to report populated vs empty per path.
dce_snapshot_volume_state() {
  local project="$1"
  local label="$2"
  local hidden_path="$3"

  local manifest=""
  manifest="$(dce_snapshot_volumes_manifest "$project" "$label")"
  [[ -f "$manifest" ]] || return 0

  local p="" state=""
  while IFS=$'\t' read -r p _ state || [[ -n "$p" ]]; do
    [[ "$p" == "$hidden_path" ]] && { printf '%s' "$state"; return 0; }
  done < "$manifest"

  return 0
}
