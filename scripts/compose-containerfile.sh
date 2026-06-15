#!/usr/bin/env bash
# =============================================================================
# compose-containerfile.sh - Compose base image plus scoped auto overlays
# into one generated Containerfile.
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

dc_load_global_config

NORMALIZED_SCOPES="$(dc_normalize_scopes_csv "$SCOPE_INPUT")" || exit 1
EFFECTIVE_SCOPES_CSV="$(dc_effective_scopes_csv "$DC_OVERLAYS_DIR" "$NORMALIZED_SCOPES")" || exit 1

SELECTED_SCOPES=()
if [[ -n "$EFFECTIVE_SCOPES_CSV" ]]; then
  IFS=',' read -r -a SELECTED_SCOPES <<< "$EFFECTIVE_SCOPES_CSV"
fi

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
    echo "  $namespace/$scope: found"
  else
    echo "  $namespace/$scope: not found, skipped"
  fi
}

echo "==> Layering overlays:"
for scope in "${SELECTED_SCOPES[@]}"; do
  append_auto_overlay team "$scope"
  append_auto_overlay user "$scope"
done

if [[ ${#SELECTED_SCOPES[@]} -gt 0 ]]; then
  SELECTED_SCOPE_SUMMARY="$(dc_join_by ', ' "${SELECTED_SCOPES[@]}")"
else
  SELECTED_SCOPE_SUMMARY="(none)"
fi

{
  echo "FROM dev-base:latest"
  echo ""
  echo "# Selected overlay scopes: $SELECTED_SCOPE_SUMMARY"

  for i in "${!AUTO_OVERLAY_FILES[@]}"; do
    emit_fragment "${AUTO_OVERLAY_FILES[$i]}" "overlay:auto:${AUTO_OVERLAY_LABELS[$i]}"
  done

  echo ""
  echo "USER dev"
  echo 'CMD ["sleep", "infinity"]'
} > "$OUTPUT_FILE"

AUTO_OVERLAY_SUMMARY="none"
if [[ ${#AUTO_OVERLAY_LABELS[@]} -gt 0 ]]; then
  AUTO_OVERLAY_SUMMARY="$(dc_join_by ', ' "${AUTO_OVERLAY_LABELS[@]}")"
fi

echo "✓ Generated composed Containerfile: $OUTPUT_FILE"
echo "  Auto overlays included: $AUTO_OVERLAY_SUMMARY"
