#!/usr/bin/env bash
# =============================================================================
# scripts/editor.sh - `dce editor`: launch the user's editor attached to a
# running dev container at /workspace. Starts the container if it isn't
# running (same preflight as `dce shell`).
#
# Docker-compatible backends only. apple/container is refused: the VS Code Dev
# Containers extension requires the Docker API socket, which apple/container
# does not expose (the same root cause as the devcontainer.json gate at
# lib/devcontainer.sh:23). The command refuses with actionable guidance rather
# than silently doing something else.
#
# Editor selection precedence (see dce_editor_select in lib/editor.sh):
#   --editor <id>  >  $DCE_EDITOR  >  DCE_EDITOR in global config  >
#   $VISUAL        >  $EDITOR      >  default (vscode)
# =============================================================================
set -euo pipefail

EXPLICIT_EDITOR=""
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --editor)
      [[ $# -ge 2 ]] || { echo "ERROR: --editor requires a value" >&2; exit 1; }
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
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        exit 1
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

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'. Run: dce new $PROJECT <scope>" >&2
  exit 1
fi

# shellcheck disable=SC2034
# Reset before dce_load_project_config repopulates them; cleared to avoid stale
# leakage (CONTAINER_HIDDEN_PATHS / CONTAINER_NETWORKS / PORTS would otherwise
# inherit values from a prior in-process load).
PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if ! backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  # Hard refuse on apple/container. dce editor is an attach command; on a
  # backend with no attach path, refuse rather than silently opening the host
  # folder (which is a different command than the user invoked).
  echo "ERROR: 'dce editor' is unsupported on backend '$ACTIVE_BACKEND'." >&2
  echo "       apple/container is not Docker-API compatible, so the VS Code Dev" >&2
  echo "       Containers extension cannot attach to it." >&2
  echo "       To open the host repo folder directly, launch your editor yourself" >&2
  echo "       on: ${REPOS_DIR:-<repos-dir>}" >&2
  echo "       To use 'dce editor', switch to a Docker-compatible backend" >&2
  echo "       (docker/orbstack/colima/podman)." >&2
  exit 1
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

# dce_editor_launch_attach validates the binary, prints the "Launching editor"
# line, and execs the editor (replacing this process). The CLI forks and
# returns immediately under the VS Code-family launchers.
dce_editor_launch_attach "$EDITOR_ID" "$PROJECT" "/workspace"
