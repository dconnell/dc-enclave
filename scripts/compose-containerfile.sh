#!/usr/bin/env bash
# =============================================================================
# scripts/compose-containerfile.sh - Compose base image + overlay scopes into
# one generated Containerfile for a derived (dev-img-<hash>) image.
#
# This implements the layering contract: team/all, user/all, then team/<scope>,
# user/<scope> for each requested scope, in that fixed order. FROM, CMD, and
# ENTRYPOINT from overlay fragments are stripped (the composed file owns the
# base image, the final CMD, and a single chained ENTRYPOINT); COPY/ADD are
# rejected (overlays must not couple to an external build context).
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

source "$ROOT_DIR/lib/common.sh"

usage() {
  echo "Usage: compose-containerfile.sh <output-file> <overlay-scopes-csv>"
}

# Parse flags (--help/-h, and reject unknown flags). No real options today.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      dc_die "Unknown flag for compose-containerfile.sh: $1"
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

OUTPUT_FILE_RAW="$1"
SCOPE_INPUT="$2"

if [[ "$OUTPUT_FILE_RAW" == /* ]]; then
  OUTPUT_FILE="$OUTPUT_FILE_RAW"
else
  OUTPUT_FILE="$PWD/$OUTPUT_FILE_RAW"
fi

OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -P "$OUTPUT_DIR" && pwd)"
OUTPUT_FILE="$OUTPUT_DIR/$(basename "$OUTPUT_FILE")"

# Emit one overlay fragment into the composed file with begin/end markers.
# Strips a leading FROM (we always build FROM dev-base) plus any CMD and
# ENTRYPOINT lines: the composed file owns one CMD and one chained ENTRYPOINT,
# so per-fragment ENTRYPOINTs would otherwise collide -- Docker keeps only the
# last in a stage, silently dropping the other ecosystems' sync hooks.
emit_fragment() {
  local fragment_file="$1"
  local label="$2"

  echo ""
  echo "# --- begin $label ---"
  awk '
    NR == 1 && toupper($1) == "FROM" { next }
    toupper($1) == "CMD" { next }
    toupper($1) == "ENTRYPOINT" { next }
    { print }
  ' "$fragment_file"
  echo "# --- end $label ---"
}

# Reject COPY/ADD in overlays. Generated files build with the repo as context,
# but overlays must stay context-free so team/user fragments compose portably.
validate_overlay_file() {
  local overlay_file="$1"

  if grep -Eiq '^[[:space:]]*(COPY|ADD)[[:space:]]+' "$overlay_file"; then
    dc_die "Overlay file contains COPY/ADD, which is disallowed: $overlay_file
Use RUN/ENV/ARG/SHELL/WORKDIR/USER only."
  fi
}

dc_load_global_config

TEAM_OD="$(dc_team_overlays_dir)"
USER_OD="$(dc_user_overlays_dir)"

NORMALIZED_SCOPES="$(dc_normalize_scopes_csv "$SCOPE_INPUT")" || exit 1
EFFECTIVE_SCOPES_CSV="$(dc_effective_scopes_csv "$TEAM_OD" "$USER_OD" "$NORMALIZED_SCOPES")" || exit 1

SELECTED_SCOPES=()
if [[ -n "$EFFECTIVE_SCOPES_CSV" ]]; then
  IFS=',' read -r -a SELECTED_SCOPES <<< "$EFFECTIVE_SCOPES_CSV"
fi

AUTO_OVERLAY_FILES=()
AUTO_OVERLAY_LABELS=()

# Record one overlay file for emission. The caller passes the resolved overlays
# leaf dir, the human-readable namespace label ("team"/"user"), and the scope;
# the label preserves the team/user layering contract for readability even
# though the on-disk layout is now <root>/overlays/Containerfile.<scope>. A
# missing unrequested file is reported but skipped silently (effective-scopes
# resolution already validated requested scopes).
append_auto_overlay() {
  local overlays_dir="$1"
  local namespace="$2"
  local scope="$3"
  local overlay_file="$overlays_dir/Containerfile.$scope"

  if [[ -f "$overlay_file" ]]; then
    validate_overlay_file "$overlay_file"
    AUTO_OVERLAY_FILES+=("$overlay_file")
    AUTO_OVERLAY_LABELS+=("$namespace/$scope")
    echo "  $namespace/$scope: found"
  else
    echo "  $namespace/$scope: not found, skipped"
  fi
}

# Layer overlays in canonical order: for each effective scope, team then user.
echo "==> Layering overlays:"
for scope in "${SELECTED_SCOPES[@]}"; do
  append_auto_overlay "$TEAM_OD" team "$scope"
  append_auto_overlay "$USER_OD" user "$scope"
done

if [[ ${#SELECTED_SCOPES[@]} -gt 0 ]]; then
  SELECTED_SCOPE_SUMMARY="$(dc_join_by ', ' "${SELECTED_SCOPES[@]}")"
else
  SELECTED_SCOPE_SUMMARY="(none)"
fi

# Provenance: detect each overlay source dir independently (plans/versioning.md).
# Per side we always have a content fingerprint; git commit/dirty/source are added
# when the dir is a git checkout. Values are scrubbed before inlining into LABELs
# (no quotes/backslash/dollar reach the Dockerfile). base.id and built.utc cannot
# be known at compose time (no backend), so they are declared as ARGs and injected
# at build time by the caller via --build-arg.
TEAM_CONTENT_HASH="$(dc_provenance_content_hash "$TEAM_OD" "$EFFECTIVE_SCOPES_CSV")"
USER_CONTENT_HASH="$(dc_provenance_content_hash "$USER_OD" "$EFFECTIVE_SCOPES_CSV")"
COMBINED_CONTENT_HASH="$(dc_provenance_combined_hash "$TEAM_CONTENT_HASH" "$USER_CONTENT_HASH")"
TEAM_GIT_COMMIT="$(dc_provenance_git_commit "$DC_TEAM_DIR")"
TEAM_GIT_DIRTY="$(dc_provenance_git_dirty "$DC_TEAM_DIR" overlays)"
TEAM_GIT_SOURCE="$(dc_provenance_git_source "$DC_TEAM_DIR")"
USER_GIT_COMMIT="$(dc_provenance_git_commit "$DC_USER_DIR")"
USER_GIT_DIRTY="$(dc_provenance_git_dirty "$DC_USER_DIR" overlays)"
USER_GIT_SOURCE="$(dc_provenance_git_source "$DC_USER_DIR")"

# Emit the composed file: always FROM dev-base:latest, a provenance LABEL block
# capturing overlay state, each overlay fragment in layered order, then force
# USER dev, a single chained ENTRYPOINT that runs every installed per-language
# sync hook, and a long-running CMD.
{
  echo "FROM dev-base:latest"
  echo ""
  echo "# Provenance labels (plans/versioning.md): overlay state at compose time."
  echo "# base.id / built.utc are injected at build time via --build-arg."
  echo 'ARG DC_BASE_ID=""'
  echo 'ARG DC_BUILT_UTC=""'
  echo "LABEL devcontainers.dc.version=\"$(dc_label_scrub "$DC_VERSION")\""
  echo "LABEL devcontainers.scopes=\"$(dc_label_scrub "$EFFECTIVE_SCOPES_CSV")\""
  echo "LABEL devcontainers.base.image=\"dev-base:latest\""
  echo "LABEL devcontainers.base.id=\"\${DC_BASE_ID}\""
  echo "LABEL devcontainers.team.content_hash=\"$(dc_label_scrub "$TEAM_CONTENT_HASH")\""
  echo "LABEL devcontainers.team.git_commit=\"$(dc_label_scrub "$TEAM_GIT_COMMIT")\""
  echo "LABEL devcontainers.team.git_dirty=\"$(dc_label_scrub "$TEAM_GIT_DIRTY")\""
  echo "LABEL devcontainers.team.source=\"$(dc_label_scrub "$TEAM_GIT_SOURCE")\""
  echo "LABEL devcontainers.user.content_hash=\"$(dc_label_scrub "$USER_CONTENT_HASH")\""
  echo "LABEL devcontainers.user.git_commit=\"$(dc_label_scrub "$USER_GIT_COMMIT")\""
  echo "LABEL devcontainers.user.git_dirty=\"$(dc_label_scrub "$USER_GIT_DIRTY")\""
  echo "LABEL devcontainers.user.source=\"$(dc_label_scrub "$USER_GIT_SOURCE")\""
  echo "LABEL devcontainers.content.hash=\"$(dc_label_scrub "$COMBINED_CONTENT_HASH")\""
  echo "LABEL devcontainers.built.utc=\"\${DC_BUILT_UTC}\""
  echo "LABEL org.opencontainers.image.revision=\"$(dc_label_scrub "$COMBINED_CONTENT_HASH")\""
  echo ""
  echo "# Selected overlay scopes: $SELECTED_SCOPE_SUMMARY"

  for i in "${!AUTO_OVERLAY_FILES[@]}"; do
    emit_fragment "${AUTO_OVERLAY_FILES[$i]}" "overlay:auto:${AUTO_OVERLAY_LABELS[$i]}"
  done

  echo ""
  echo "USER dev"
  # One ENTRYPOINT owned by the composed image: run every dc-*-entrypoint.sh
  # hook the overlays installed, then exec CMD. With no overlays the glob is
  # empty and it simply execs CMD. A hook exiting non-zero (e.g. a
  # DC_*_INSTALL_STRICT=1 failure) aborts startup via set -e so the container
  # does not run with broken dependencies. Quoted heredoc so the inner heredoc
  # and shell variables reach the image verbatim.
  cat <<'RUNNER_EOF'
RUN mkdir -p /home/dev/.local/bin
RUN cat > /home/dev/.local/bin/dc-entrypoint <<'DC_ENTRYPOINT_EOF'
#!/bin/sh
set -eu
# Chain every installed per-language dependency-sync hook, then run CMD.
for ep in /home/dev/.local/bin/dc-*-entrypoint.sh; do
  [ -x "$ep" ] || continue
  "$ep"
done
exec "$@"
DC_ENTRYPOINT_EOF
RUN chmod +x /home/dev/.local/bin/dc-entrypoint
ENTRYPOINT ["/home/dev/.local/bin/dc-entrypoint"]
RUNNER_EOF
  echo 'CMD ["sleep", "infinity"]'
} > "$OUTPUT_FILE"

AUTO_OVERLAY_SUMMARY="none"
if [[ ${#AUTO_OVERLAY_LABELS[@]} -gt 0 ]]; then
  AUTO_OVERLAY_SUMMARY="$(dc_join_by ', ' "${AUTO_OVERLAY_LABELS[@]}")"
fi

echo "✓ Generated composed Containerfile: $OUTPUT_FILE"
echo "  Auto overlays included: $AUTO_OVERLAY_SUMMARY"
