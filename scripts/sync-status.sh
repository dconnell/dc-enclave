#!/usr/bin/env bash
# =============================================================================
# scripts/sync-status.sh - `dce sync-status`: show Mutagen sync state for a
# synced (`--sync`) project's workspace.
#
# Resolves the project's Mutagen session name (dce-sync-<slug>-<12hex>) so the
# user never has to, then execs mutagen's own status commands:
#   dce sync-status <project>        live, streaming status (mutagen sync monitor)
#   dce sync-status <project> --once one-shot status (mutagen sync list)
#
# Mutagen runs host-side only; this is a host command. Refuses fast with
# actionable guidance when the project is not synced, mutagen is absent, or no
# session exists for the project. See plans/sync-visibility.md.
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

ONCE=false
PROJECT=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '3,17p' "$0" 2>/dev/null || true
      exit 0
      ;;
    --once|-1)
      ONCE=true
      ;;
    --*)
      dce_die "Unknown option: $arg (usage: dce sync-status [--once] <project>)"
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$arg"
      else
        dce_die "Unexpected argument: $arg (usage: dce sync-status [--once] <project>)"
      fi
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  dce_die "Usage: dce sync-status [--once] <project>"
fi

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'. Run: dce new $PROJECT <scope>"
fi

dce_load_project_config "$CONFIG"

if [[ "${CONTAINER_SYNC:-0}" != "1" ]]; then
  dce_die "'$PROJECT' is not a synced workspace.
  sync-status only applies to projects created with --sync.
  To enable a synced workspace: dce rebuild-container $PROJECT --sync
  See: docs/how-to/sync-workspace.md"
fi

if ! dce_mutagen_present; then
  dce_die "$(dce_mutagen_absent_message "$PROJECT")"
fi

SESSION="$(dce_sync_session_name "$PROJECT")"

if ! dce_sync_session_exists "$PROJECT"; then
  dce_die "No Mutagen session for '$PROJECT' (expected: $SESSION).
  Recreate it with: dce rebuild-container $PROJECT
  See: docs/how-to/sync-workspace.md"
fi

# Mutagen owns the display; exec so we do not sit between it and the TTY. The
# live monitor streams until the user interrupts (Ctrl-C); --once is a single
# snapshot. Session name is the resolved dce-sync-<slug>-<12hex>.
if $ONCE; then
  exec mutagen sync list "$SESSION"
fi
exec mutagen sync monitor "$SESSION"
