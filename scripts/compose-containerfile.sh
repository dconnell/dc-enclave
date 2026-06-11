#!/usr/bin/env zsh
# =============================================================================
# compose-containerfile.sh — Compose runtime Containerfiles plus optional user
# overlay fragments into one generated Containerfile.
#
# Usage:
#   compose-containerfile.sh <output-file> <runtime-types-csv> [overlay-file ...]
#
# Example:
#   compose-containerfile.sh \
#     Containerfiles/generated/Containerfile.myproj \
#     nodejs,golang \
#     /Users/you/.config/dev-containers/Containerfile.username
# =============================================================================
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: compose-containerfile.sh <output-file> <runtime-types-csv> [overlay-file ...]"
  exit 1
fi

OUTPUT_FILE="${1:A}"
RUNTIME_INPUT="$2"
shift 2

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

TYPE_ORDER=(nodejs golang)
typeset -A TYPE_SELECTED

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
    echo "ERROR: Overlay file contains COPY/ADD, which is disallowed in phase 1: $overlay_file"
    echo "  Use RUN/ENV/ARG/SHELL/WORKDIR/USER instructions only."
    exit 1
  fi
}

RAW_TYPES=("${(@s:,:)RUNTIME_INPUT}")
for raw_type in "${RAW_TYPES[@]}"; do
  normalized_type="${raw_type//[[:space:]]/}"
  case "$normalized_type" in
    nodejs|golang)
      TYPE_SELECTED[$normalized_type]=1
      ;;
    "")
      ;;
    *)
      echo "ERROR: Unknown runtime type '$normalized_type'. Supported: nodejs, golang"
      exit 1
      ;;
  esac
done

RUNTIME_TYPES=()
for runtime_type in "${TYPE_ORDER[@]}"; do
  if [[ -n "${TYPE_SELECTED[$runtime_type]-}" ]]; then
    RUNTIME_TYPES+=("$runtime_type")
  fi
done

if [[ ${#RUNTIME_TYPES[@]} -eq 0 ]]; then
  echo "ERROR: At least one runtime type is required to compose a Containerfile."
  exit 1
fi

OVERLAY_FILES=()
for overlay_input in "$@"; do
  [[ -z "$overlay_input" ]] && continue
  overlay_file="${overlay_input:A}"
  if [[ ! -f "$overlay_file" ]]; then
    echo "ERROR: Overlay Containerfile not found: $overlay_file"
    exit 1
  fi

  validate_overlay_file "$overlay_file"
  OVERLAY_FILES+=("$overlay_file")
done

mkdir -p "${OUTPUT_FILE:h}"

{
  echo "FROM dev-base:latest"

  for runtime_type in "${RUNTIME_TYPES[@]}"; do
    runtime_containerfile="$ROOT_DIR/Containerfiles/Containerfile.$runtime_type"
    if [[ ! -f "$runtime_containerfile" ]]; then
      echo "ERROR: Missing runtime Containerfile: $runtime_containerfile" >&2
      exit 1
    fi

    emit_fragment "$runtime_containerfile" "Containerfile.$runtime_type"
  done

  for overlay_file in "${OVERLAY_FILES[@]}"; do
    emit_fragment "$overlay_file" "overlay:${overlay_file:t}"
  done

  echo ""
  echo "USER dev"
  echo 'CMD ["sleep", "infinity"]'
} > "$OUTPUT_FILE"

echo "✓ Generated composed Containerfile: $OUTPUT_FILE"
