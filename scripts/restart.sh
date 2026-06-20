#!/usr/bin/env bash
# =============================================================================
# scripts/restart.sh - `dc restart`: restart one or all dev containers.
#
# Implemented as stop -> start so it reuses the proven per-project flows in
# stop.sh / start.sh: backend bring-up, OrbStack hidden-volume re-verification,
# and SSH-key re-injection all come for free. Both scripts handle the named-vs-
# all case identically, so this command is a thin orchestrator over them.
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

# stop then start; each sibling handles per-project backend resolution, hidden
# mounts, and the named-vs-all argument form. Under set -e a failure in stop
# (e.g. an unknown project name) prevents start, matching `dc stop` semantics.
"$SCRIPT_DIR/stop.sh" "$@"
"$SCRIPT_DIR/start.sh" "$@"
