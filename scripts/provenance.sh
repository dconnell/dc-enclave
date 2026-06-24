#!/usr/bin/env bash
# =============================================================================
# scripts/provenance.sh - `dce provenance <project>`: show image provenance.
#
# Prints the overlay state (team/user git commits + content fingerprints, base
# image id, scope list, build time) that produced a project's current image, so
# a build can be traced back to the overlay repos for debugging. Source of truth
# is the project's append-only provenance.jsonl written by dce new / dce rebuild-
# image (plans/versioning.md). The same data is also stamped on the image as OCI
# labels (docker/podman inspect).
#
# Output is pretty-printed when jq is available; otherwise the raw JSONL line(s)
# are printed so the command never hard-requires jq.
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

usage() {
  echo "Usage: dce provenance <project> [--history|--all]"
  echo "       dce provenance <project> --help|-h"
}

HISTORY=false
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --history|--all)
      HISTORY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$PROJECT" ]]; then
        echo "ERROR: Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      PROJECT="$1"
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Project name is required." >&2
  usage >&2
  exit 1
fi

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No project '$PROJECT' (config not found)." >&2
  exit 1
fi

LOG="$(dce_provenance_log_path "$PROJECT")"

if [[ ! -s "$LOG" ]]; then
  echo "No provenance log for '$PROJECT'."
  echo "Run 'dce rebuild-image all' (or 'dce new <name> <scope>') to build and record one."
  exit 0
fi

# Render a side identifier as "git:<commit>" when under git, else
# "content:<hash>" (the always-available fingerprint). The commit is truncated
# for the dense table view; the full sha is kept in the log and shown by the
# detail view (`dce provenance <name>`).
_side_summary() {
  local line="$1" side="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$line" | jq -r --arg s "$side" \
      'if .[$s].git_commit == "" then "content:\(.[$s].content_hash[0:8])" else "git:\(.[$s].git_commit[0:12])" end' 2>/dev/null \
      || printf '?'
  else
    printf '%s' "$side"
  fi
}

if $HISTORY; then
  echo "Provenance history for '$PROJECT' (oldest -> newest):"
  echo ""
  if command -v jq >/dev/null 2>&1; then
    printf '%-26s %-18s %-18s %-22s %s\n' "BUILT(UTC)" "TEAM" "USER" "BASE ID" "IMAGE"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ts="$(printf '%s' "$line" | jq -r '.ts' 2>/dev/null || printf '?')"
      base="$(printf '%s' "$line" | jq -r '.base.id' 2>/dev/null || printf '?')"
      img="$(printf '%s' "$line" | jq -r '.image_ref' 2>/dev/null || printf '?')"
      printf '%-26s %-18s %-18s %-22s %s\n' \
        "$ts" "$(_side_summary "$line" team)" "$(_side_summary "$line" user)" "$base" "$img"
    done < "$LOG"
  else
    echo "(install jq for a tabular view; raw JSONL below)"
    cat "$LOG"
  fi
  exit 0
fi

# Default: the current (last) build.
LAST="$(tail -n1 "$LOG")"
echo "Provenance for '$PROJECT' (last recorded build):"
echo ""
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$LAST" | jq .
else
  echo "(install jq for pretty output; raw JSONL below)"
  printf '%s\n' "$LAST"
fi
