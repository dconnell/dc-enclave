#!/usr/bin/env bash
# =============================================================================
# scripts/editor.sh - `dce editor`: launch the user's editor attached to a
# running dev container at /workspace. Starts the container if it isn't
# running (same preflight as `dce shell`).
#
# Docker-compatible backends use the standard "attached-container" URI; the
# apple/container backend uses VS Code Dev Containers' EXPERIMENTAL
# apple-container attach path (dev.containers.experimentalAppleContainerSupport).
# dce editor launches both programmatically via a --folder-uri vscode-remote://
# URI; for apple, the {id, image} pair is resolved live from `container inspect`
# so the URI matches what VS Code's own "Attach to Running Apple Container"
# picker would build.
#
# Editor selection precedence (see dce_editor_select in lib/editor.sh):
#   --editor <id>  >  $DCE_EDITOR  >  DCE_EDITOR in global config  >
#   $VISUAL        >  $EDITOR      >  default (vscode)
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
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/vscode.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/editor.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/extensions.sh"

EXPLICIT_EDITOR=""
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --editor)
      [[ $# -ge 2 ]] || dce_die "--editor requires a value"
      EXPLICIT_EDITOR="$2"
      shift 2
      ;;
    --editor=*)
      EXPLICIT_EDITOR="${1#--editor=}"
      shift
      ;;
    -h|--help|help)
      sed -n '3,18p' "$0" 2>/dev/null || true
      exit 0
      ;;
    --*)
      dce_die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        dce_die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "Usage: dce editor [--editor <id>] <project>" >&2
  echo "" >&2
  echo "Launch your editor attached to a running dev container at /workspace." >&2
  echo "Docker-compatible backends only (docker/orbstack/colima/podman)." >&2
  echo "" >&2
  echo "Editor selection: --editor <id> > \$DCE_EDITOR > global DCE_EDITOR > \$VISUAL > \$EDITOR > default" >&2
  exit 1
fi

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'. Run: dce new $PROJECT <scope>"
fi

# shellcheck disable=SC2034
# Reset before dce_load_project_config repopulates them; cleared to avoid stale
# leakage (CONTAINER_HIDDEN_PATHS / CONTAINER_NETWORKS / PORTS would otherwise
# inherit values from a prior in-process load).
PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if [[ "$ACTIVE_BACKEND" == "apple" ]]; then
  # Experimental: VS Code Dev Containers' apple-container attach is upstream-
  # experimental (dev.containers.experimentalAppleContainerSupport) and macOS-
  # only. Surface that clearly so a failed attach points at the setting rather
  # than at dce. Advisory only -- the launch proceeds.
  echo "  Note: apple/container Dev Containers attach is EXPERIMENTAL in VS Code."
  echo "        Enable \"Dev Containers: Experimental: Apple Container Support\""
  echo "        (dev.containers.experimentalAppleContainerSupport) in VS Code settings."
fi

EDITOR_ID="$(dce_editor_select "$EXPLICIT_EDITOR")"

if ! backend_is_running "$PROJECT"; then
  echo "  Container '$PROJECT' is not running - starting it..."
  "$SCRIPT_DIR/start.sh" "$PROJECT"
fi

echo "  Backend: $ACTIVE_BACKEND"
echo "  Workspace: /workspace (-> ${REPOS_DIR:-<repos-dir>} on host)"

# Read the project's git token for a status line (provider env-var name:
# GITHUB_TOKEN / GITLAB_TOKEN), mirroring `dce shell`. Empty = unset.
GIT_TOKEN="$(dce_read_git_token)"
ENV_VAR="$(dce_git_host_field "$(dce_project_git_host)" env_var)"
AUTH_METHOD="$(dce_git_auth_method)"
if [[ -n "$GIT_TOKEN" ]]; then
  echo "  ${ENV_VAR}: set"
else
  echo "  ${ENV_VAR}: NOT SET (edit ${TOKEN_FILE:-token file})"
fi

# Ensure git auth is wired in the container (HTTPS+PAT or SSH insteadOf +
# credential.helper store + VS Code machine setting) so the editor lands with
# working credentials even when the container was started before the token file
# was filled in -- `dce editor` must inject credentials just like `dce shell`.
# Idempotent; the PAT, if any, crosses via stdin inside the helper. Mirrors
# scripts/shell.sh:71 and scripts/start.sh:96.
dce_ensure_git_credentials "$PROJECT"

# Reconcile the project's hosts fragment into /etc/hosts so the attached editor
# gets the same name resolution as a `dce shell` entry (idempotent; no-op
# without a fragment).
dce_ensure_container_hosts "$PROJECT"

# dce editor preserves the same forensics-safe default as dce shell/start: if a
# PAT-backed ~/.git-credentials file already exists in the container, it is not
# silently overwritten on launch. That means a host-side token rotation can leave
# the editor using a stale token until the user explicitly pushes the new one via
# `dce rotate-token`. Surface that drift here so "editor launched, git auth
# still fails" points at the right repair instead of looking like attach wiring
# broke. Read-only compare; token never printed.
if [[ "$AUTH_METHOD" == "pat" ]]; then
  TOKEN_DRIFT="$(dce_check_git_token_drift "$PROJECT" 2>/dev/null || true)"
  case "$TOKEN_DRIFT" in
    drift)
      dce_warn "Container token differs from host token; attached editor Git auth may fail until you run: dce rotate-token $PROJECT"
      ;;
    absent)
      dce_warn "Container is missing the current host token in ~/.git-credentials; attached editor Git auth may fail until you run: dce rotate-token $PROJECT"
      ;;
  esac
fi

echo ""

# Best-effort: (re)seed the VS Code named-attach config so the attach lands in
# /workspace. This is normally done at `dce new`, but VS Code's globalStorage
# may not have existed yet on first create (the seed was a no-op then). Doing
# it again here is idempotent and cheap, so a late `dce editor` after VS Code
# has been run once just works.
while IFS= read -r _attach_cfg; do
  [[ -z "$_attach_cfg" ]] && continue
  echo "  ✓ VS Code named attach: $_attach_cfg"
done < <(dce_vscode_seed_named_attach_config "$PROJECT" "/workspace" "$AUTH_METHOD" || true)

# Validate a positive-numeric watch knob (fractional allowed). Values stay
# strings because bash arithmetic cannot hold fractions; the numeric >0 check
# therefore runs in awk. Invalid input degrades to the default (with a
# warning) rather than failing the launch -- the watcher is best-effort.
_dce_editor_watch_interval_or_default() {  # <value> <default> <env-name>
  local value="$1" default="$2" name="$3"
  # Absence is not misconfiguration: take the default quietly.
  [[ -n "$value" ]] || { printf '%s' "$default"; return 0; }
  if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$value" 'BEGIN { exit !(n + 0 > 0) }'; then
    printf '%s' "$value"
  else
    dce_warn "$name='$value' is not a positive number; using the default (${default}s)"
    printf '%s' "$default"
  fi
}

# First-open fallback (plans/extensions-first-open-convergence.md): spawn the
# detached extension watcher and tell the user where its log lands. Only
# post-adoption projects with a non-empty declared set qualify (the same
# guards dce_ext_enforce_declared applies internally), so pre-adoption
# projects keep the exact silent no-op they had before.
_dce_editor_spawn_ext_watch() {
  dce_ext_manifests_exist "$EDITOR_ID" "$DC_TEAM_DIR" "$DC_USER_DIR" \
    "${CONTAINER_OVERLAY_SCOPES:-}" || return 0
  local declared=""
  declared="$(dce_ext_resolve_set "$EDITOR_ID" "$DC_TEAM_DIR" "$DC_USER_DIR" \
    "${CONTAINER_OVERLAY_SCOPES:-}" 2>/dev/null)" || return 0
  [[ -z "${declared// /}" ]] && return 0

  local interval=""
  interval="$(_dce_editor_watch_interval_or_default "${DCE_EXT_WATCH_INTERVAL:-}" 5 "DCE_EXT_WATCH_INTERVAL")"
  local timeout=""
  timeout="$(_dce_editor_watch_interval_or_default "${DCE_EXT_WATCH_TIMEOUT:-}" 300 "DCE_EXT_WATCH_TIMEOUT")"

  local watch_log=""
  watch_log="$(_dce_ext_watch_log_path "$PROJECT")" || {
    # A name the path helper rejects ('/' is the only real path-escape
    # character) cannot carry watcher state: warn and skip the watcher
    # entirely (no spawn, no notice) -- the same tolerate-and-continue posture
    # as every other best-effort guard in this launch path.
    dce_warn "project name '$PROJECT' is not usable for watcher state paths; skipping the background extension watcher"
    return 0
  }
  # Pre-create the log under a user-only umask: the nohup redirect below would
  # otherwise create it with the ambient umask, leaving it group/world-readable
  # until the winning watcher's chmod 600 lands.
  ( umask 077; : >> "$watch_log" ) 2>/dev/null || true
  # nohup + & (not setsid, which is not macOS-portable) so the watcher
  # survives this process being replaced by the editor exec below. Its output
  # lands only in the log; the launch proceeds immediately.
  nohup "$SCRIPT_DIR/_editor-ext-watch.sh" "$PROJECT" "$EDITOR_ID" \
    "$interval" "$timeout" </dev/null >>"$watch_log" 2>&1 &
  echo "  VS Code Server not yet injected into '$PROJECT' (first open); declared"
  echo "  extensions will be installed by the background watcher (log: $watch_log)."
}

# Attach-mode extension convergence (plans/extensions.md §6 +
# plans/extensions-first-open-convergence.md). VS Code's attached-container
# open (the vscode-remote://attached-container URI used by
# dce_editor_launch_attach) does not reliably process
# customizations.vscode.extensions, so declared-but-missing extensions are
# installed via the in-container code-server CLI. Chicken-and-egg: the
# code-server CLI is itself injected by VS Code only AFTER it attaches, so a
# first-ever open cannot converge synchronously -- with the server present we
# enforce inline (unchanged); with it absent we hand the work to the detached
# watcher, which polls for the server and runs the same enforcement
# post-launch. Idempotent + advisory; gated on the extension-managed editor
# set (vscode in v1). Wrapped so a missing/broken global config (which
# dce_load_global_config dce_die-exits on) never blocks the launch.
if dce_ext_is_supported "$EDITOR_ID"; then
  (
    dce_load_global_config 2>/dev/null || exit 0
    if dce_ext_list_installed "$EDITOR_ID" "$PROJECT" >/dev/null 2>&1; then
      dce_ext_enforce_declared "$PROJECT" "$EDITOR_ID" \
        "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}"
    else
      _dce_editor_spawn_ext_watch
    fi
  ) || true
fi

# dce_editor_launch_attach* validates the binary, prints the "Launching editor"
# line, and execs the editor (replacing this process). The CLI forks and
# returns immediately under the VS Code-family launchers. The launch URI flavor
# is backend-specific: docker-compatible uses the attached-container scheme;
# apple/container uses the experimental apple-container scheme, keyed on the
# live {id, image} pair resolved from `container inspect` (CONTAINER_IMAGE is
# the fallback image reference if jq is unavailable).
if [[ "$ACTIVE_BACKEND" == "apple" ]]; then
  ref="$(backend_apple_attach_ref "$PROJECT" "${CONTAINER_IMAGE:-}")"
  apple_id="${ref%%$'\t'*}"
  apple_image="${ref#*$'\t'}"
  dce_editor_launch_attach_apple "$EDITOR_ID" "$PROJECT" "$apple_id" "$apple_image" "/workspace"
else
  dce_editor_launch_attach "$EDITOR_ID" "$PROJECT" "/workspace"
fi
