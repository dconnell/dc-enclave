#!/usr/bin/env bash
# =============================================================================
# scripts/shell.sh - `dce shell`: open an interactive shell (or run one command)
# in a dev container. Starts the container if it isn't running, and injects the
# project's git token into the shell environment as the provider's env var
# (GITHUB_TOKEN / GITLAB_TOKEN) when set.
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: shell.sh <project-name> [command]}"
shift

HAS_COMMAND=false
COMMAND=""
if [[ $# -gt 0 ]]; then
  HAS_COMMAND=true
  COMMAND="$*"
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

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'. Run: dce new $PROJECT <scope>"
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if ! backend_is_running "$PROJECT"; then
  echo "  Container '$PROJECT' is not running - starting it..."
  "$SCRIPT_DIR/start.sh" "$PROJECT"
fi

# Read the project's git token (skipping comments and the provider placeholder)
# via the shared helper so the filtering logic lives in one place. Empty = unset.
# ENV_VAR is the provider's shell env-var name (GITHUB_TOKEN / GITLAB_TOKEN) the
# token is exported as inside the container, so provider-native tooling (gh/glab,
# SDKs) reads it unmodified.
GIT_TOKEN="$(dce_read_git_token)"
ENV_VAR="$(dce_git_host_field "$(dce_project_git_host)" env_var)"

echo "  Entering container: $PROJECT"
echo "  Backend: $ACTIVE_BACKEND"
echo "  Workspace: /workspace (-> $REPOS_DIR on host)"
if [[ -n "$GIT_TOKEN" ]]; then
  echo "  ${ENV_VAR}: set"
else
  echo "  ${ENV_VAR}: NOT SET (edit ${TOKEN_FILE:-token file})"
fi
echo ""

# Ensure git auth is wired in the container (HTTPS+PAT or SSH insteadOf), so a
# `dce shell` into an already-running container also repairs auth -- not just
# `dce start`. Idempotent; the PAT, if any, crosses via stdin inside the helper.
dce_ensure_git_credentials "$PROJECT"

# Seed the token into a short-lived file inside the container over stdin, so the
# token value never appears in host process argv (readable via ps / /proc).
# The raw value is written (not a shell assignment) and read back via command
# substitution in the wrapper, so token-file metacharacters are never executed;
# the file is deleted before the user shell is exec'd and best-effort removed
# again on exit/interrupt.
_dce_token_env_file=""

_dce_seed_token_file() {
  _dce_token_env_file="$(backend_exec "$PROJECT" mktemp "/tmp/dce-git-token.XXXXXX")"
  backend_exec "$PROJECT" chmod 600 "$_dce_token_env_file"
  # shellcheck disable=SC2016
  # sh -c runs in the container; $1 expands in that inner shell, not here.
  printf '%s' "$GIT_TOKEN" \
    | backend_exec_stdin "$PROJECT" sh -c 'cat >"$1"' _ "$_dce_token_env_file"
}

_dce_cleanup_token_file() {
  if [[ -n "$_dce_token_env_file" ]]; then
    backend_exec "$PROJECT" rm -f "$_dce_token_env_file" 2>/dev/null || true
  fi
}
# Best-effort cleanup on normal exit or launch-time interrupt; never let a failed
# cleanup break normal shell usage.
trap '_dce_cleanup_token_file' EXIT INT TERM

if $HAS_COMMAND; then
  if [[ -n "$GIT_TOKEN" ]]; then
    _dce_seed_token_file
    # shellcheck disable=SC2016
    # sh -lc runs in the container; $1/$2/$3 and $(cat) expand in the inner
    # shell. $3 is the env-var NAME (registry-controlled), exported with the
    # value read from the temp file ($1); the value never touches host argv.
    backend_exec "$PROJECT" env \
      "PS1=[${PROJECT}] %~ %# " \
      sh -lc 'export "$3=$(cat "$1")"; rm -f "$1"; exec zsh -ic "$2"' \
      _ "$_dce_token_env_file" "$COMMAND" "$ENV_VAR"
  else
    backend_exec "$PROJECT" env \
      "PS1=[${PROJECT}] %~ %# " \
      zsh -ic "$COMMAND"
  fi
else
  # shellcheck disable=SC2016
  # sh -lc runs in the container; $(hostname)/$(whoami)/$(pwd) expand there.
  backend_exec "$PROJECT" sh -lc 'echo "  Connected to container: $(hostname) (user=$(whoami), pwd=$(pwd))"'
  if [[ -n "$GIT_TOKEN" ]]; then
    _dce_seed_token_file
    # shellcheck disable=SC2016
    # sh -lc runs in the container; $1/$2 and $(cat) expand in the inner shell.
    # $2 is the env-var NAME; the value (read from $1) never touches host argv.
    backend_exec_interactive "$PROJECT" \
      --env "PS1=[${PROJECT}] %~ %# " \
      -- \
      sh -lc 'export "$2=$(cat "$1")"; rm -f "$1"; cd /workspace 2>/dev/null || true; exec zsh -i' \
      _ "$_dce_token_env_file" "$ENV_VAR"
  else
    backend_exec_interactive "$PROJECT" \
      --env "PS1=[${PROJECT}] %~ %# " \
      -- \
      zsh -ic 'cd /workspace 2>/dev/null || true; exec zsh -i'
  fi
fi
