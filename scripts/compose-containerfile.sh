#!/usr/bin/env bash
# =============================================================================
# compose-containerfile.sh - Compose base image plus auto/explicit overlay
# fragments into one generated Containerfile.
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
  echo "Usage: compose-containerfile.sh [--no-team] [--no-user] <output-file> <overlay-scopes-csv> [explicit-overlay-file ...]"
}

INCLUDE_TEAM=1
INCLUDE_USER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-team)
      INCLUDE_TEAM=0
      shift
      ;;
    --no-user)
      INCLUDE_USER=0
      shift
      ;;
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

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

OUTPUT_FILE_RAW="$1"
SCOPE_INPUT="$2"
shift 2

if [[ "$OUTPUT_FILE_RAW" == /* ]]; then
  OUTPUT_FILE="$OUTPUT_FILE_RAW"
else
  OUTPUT_FILE="$PWD/$OUTPUT_FILE_RAW"
fi

OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -P "$OUTPUT_DIR" && pwd)"
OUTPUT_FILE="$OUTPUT_DIR/$(basename "$OUTPUT_FILE")"

emit_fragment() {
  local fragment_file="$1"
  local label="$2"

  echo ""
  echo "# --- begin $label ---"
  awk '
    NR == 1 && toupper($1) == "FROM" { next }
    toupper($1) == "CMD" { next }
    { print }
  ' "$fragment_file"
  echo "# --- end $label ---"
}

validate_overlay_file() {
  local overlay_file="$1"

  if grep -Eiq '^[[:space:]]*(COPY|ADD)[[:space:]]+' "$overlay_file"; then
    dc_die "Overlay file contains COPY/ADD, which is disallowed: $overlay_file
Use RUN/ENV/ARG/SHELL/WORKDIR/USER only."
  fi
}

AUTO_OVERLAY_FILES=()
AUTO_OVERLAY_LABELS=()

append_auto_overlay() {
  local namespace="$1"
  local scope="$2"
  local overlay_file="$DC_OVERLAYS_DIR/$namespace/Containerfile.$scope"

  if [[ -f "$overlay_file" ]]; then
    validate_overlay_file "$overlay_file"
    AUTO_OVERLAY_FILES+=("$overlay_file")
    AUTO_OVERLAY_LABELS+=("$namespace/$scope")
  fi
}

SELECTED_SCOPES=()
declare -A SCOPE_SELECTED=()
IFS=',' read -r -a RAW_SCOPES <<< "$SCOPE_INPUT"
for raw_scope in "${RAW_SCOPES[@]}"; do
  normalized_scope="${raw_scope//[[:space:]]/}"
  case "$normalized_scope" in
    nodejs|golang)
      if [[ -z "${SCOPE_SELECTED[$normalized_scope]-}" ]]; then
        SCOPE_SELECTED["$normalized_scope"]=1
        SELECTED_SCOPES+=("$normalized_scope")
      fi
      ;;
    "")
      ;;
    *)
      dc_die "Unknown overlay scope '$normalized_scope'. Supported: nodejs, golang"
      ;;
  esac
done

if [[ ${#SELECTED_SCOPES[@]} -eq 0 ]]; then
  dc_die "At least one overlay scope is required to compose a Containerfile."
fi

dc_load_global_config

if [[ "$INCLUDE_TEAM" == "1" ]]; then
  append_auto_overlay team all
fi
if [[ "$INCLUDE_USER" == "1" ]]; then
  append_auto_overlay user all
fi

for scope in "${SELECTED_SCOPES[@]}"; do
  if [[ "$INCLUDE_TEAM" == "1" ]]; then
    append_auto_overlay team "$scope"
  fi
  if [[ "$INCLUDE_USER" == "1" ]]; then
    append_auto_overlay user "$scope"
  fi
done

EXPLICIT_OVERLAY_FILES=()
for overlay_input in "$@"; do
  [[ -z "$overlay_input" ]] && continue

  overlay_file="$(dc_resolve_path "$overlay_input")" || {
    dc_die "Overlay path could not be resolved: $overlay_input"
  }

  if [[ ! -f "$overlay_file" ]]; then
    dc_die "Overlay Containerfile not found: $overlay_file"
  fi

  validate_overlay_file "$overlay_file"
  EXPLICIT_OVERLAY_FILES+=("$overlay_file")
done

SELECTED_SCOPE_SUMMARY="$(dc_join_by ', ' "${SELECTED_SCOPES[@]}")"

{
  echo "FROM dev-base:latest"
  echo ""
  echo "# Selected overlay scopes: $SELECTED_SCOPE_SUMMARY"

  for i in "${!AUTO_OVERLAY_FILES[@]}"; do
    emit_fragment "${AUTO_OVERLAY_FILES[$i]}" "overlay:auto:${AUTO_OVERLAY_LABELS[$i]}"
  done

  for overlay_file in "${EXPLICIT_OVERLAY_FILES[@]}"; do
    emit_fragment "$overlay_file" "overlay:explicit:$(basename "$overlay_file")"
  done

  echo ""
  echo "USER dev"
  echo 'CMD ["sleep", "infinity"]'
} > "$OUTPUT_FILE"

AUTO_OVERLAY_SUMMARY="none"
if [[ ${#AUTO_OVERLAY_LABELS[@]} -gt 0 ]]; then
  AUTO_OVERLAY_SUMMARY="$(dc_join_by ', ' "${AUTO_OVERLAY_LABELS[@]}")"
fi

EXPLICIT_OVERLAY_SUMMARY="none"
if [[ ${#EXPLICIT_OVERLAY_FILES[@]} -gt 0 ]]; then
  EXPLICIT_NAMES=()
  for overlay_file in "${EXPLICIT_OVERLAY_FILES[@]}"; do
    EXPLICIT_NAMES+=("$(basename "$overlay_file")")
  done
  EXPLICIT_OVERLAY_SUMMARY="$(dc_join_by ', ' "${EXPLICIT_NAMES[@]}")"
fi

echo "✓ Generated composed Containerfile: $OUTPUT_FILE"
echo "  Auto overlays included: $AUTO_OVERLAY_SUMMARY"
echo "  Explicit overlays: $EXPLICIT_OVERLAY_SUMMARY"
