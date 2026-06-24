#!/usr/bin/env bash
# =============================================================================
# scripts/shell.sh - `dce shell`: open an interactive shell (or run one command)
# in a dev container. Starts the container if it isn't running, and injects the
# project's GITHUB_TOKEN into the shell environment when set.
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
  echo "ERROR: No config for '$PROJECT'. Run: dce new $PROJECT <scope>"
  exit 1
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if ! backend_is_running "$PROJECT"; then
  echo "  Container '$PROJECT' is not running - starting it..."
  "$SCRIPT_DIR/start.sh" "$PROJECT"
fi

# Read the GitHub token, skipping comment lines and the placeholder value so an
# unfilled token file doesn't leak "ghp_REPLACE_ME" into the environment.
GITHUB_TOKEN=""
if [[ -n "${TOKEN_FILE:-}" ]] && [[ -f "$TOKEN_FILE" ]]; then
  # Pattern on a single line: under mawk a multi-line `&&` pattern followed by
  # a newline-prefixed `{` action parses the action as a separate unconditional
  # rule, which would defeat the comment/placeholder filtering below.
  GITHUB_TOKEN="$(awk '
    $0 !~ /^#/ && $0 !~ /^ghp_REPLACE_ME/ && $0 ~ /[^[:space:]]/ {
      gsub(/[[:space:]]+/, "", $0)
      print
      exit
    }
  ' "$TOKEN_FILE" 2>/dev/null || true)"
fi

echo "  Entering container: $PROJECT"
echo "  Backend: $ACTIVE_BACKEND"
echo "  Workspace: /workspace (-> $REPOS_DIR on host)"
if [[ -n "$GITHUB_TOKEN" ]]; then
  echo "  GITHUB_TOKEN: set"
else
  echo "  GITHUB_TOKEN: NOT SET (edit ${TOKEN_FILE:-token file})"
fi
echo ""

# Seed GITHUB_TOKEN into a short-lived file inside the container over stdin, so
# the PAT value never appears in host process argv (readable via ps / /proc).
# The raw value is written (not a shell assignment) and read back via command
# substitution in the wrapper, so token-file metacharacters are never executed;
# the file is deleted before the user shell is exec'd and best-effort removed
# again on exit/interrupt.
_dce_token_env_file=""

_dce_seed_token_file() {
  _dce_token_env_file="$(backend_exec "$PROJECT" mktemp "/tmp/dce-gh-token.XXXXXX")"
  backend_exec "$PROJECT" chmod 600 "$_dce_token_env_file"
  # shellcheck disable=SC2016
  # sh -c runs in the container; $1 expands in that inner shell, not here.
  printf '%s' "$GITHUB_TOKEN" \
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
  if [[ -n "$GITHUB_TOKEN" ]]; then
    _dce_seed_token_file
    # shellcheck disable=SC2016
    # sh -lc runs in the container; $1/$2 and $(cat) expand in the inner shell.
    backend_exec "$PROJECT" env \
      "PS1=[${PROJECT}] %~ %# " \
      sh -lc 'export GITHUB_TOKEN="$(cat "$1")"; rm -f "$1"; exec zsh -ic "$2"' \
      _ "$_dce_token_env_file" "$COMMAND"
  else
    backend_exec "$PROJECT" env \
      "PS1=[${PROJECT}] %~ %# " \
      zsh -ic "$COMMAND"
  fi
else
  # shellcheck disable=SC2016
  # sh -lc runs in the container; $(hostname)/$(whoami)/$(pwd) expand there.
  backend_exec "$PROJECT" sh -lc 'echo "  Connected to container: $(hostname) (user=$(whoami), pwd=$(pwd))"'
  if [[ -n "$GITHUB_TOKEN" ]]; then
    _dce_seed_token_file
    # shellcheck disable=SC2016
    # sh -lc runs in the container; $1 and $(cat) expand in the inner shell.
    backend_exec_interactive "$PROJECT" \
      --env "PS1=[${PROJECT}] %~ %# " \
      -- \
      sh -lc 'export GITHUB_TOKEN="$(cat "$1")"; rm -f "$1"; cd /workspace 2>/dev/null || true; exec zsh -i' \
      _ "$_dce_token_env_file"
  else
    backend_exec_interactive "$PROJECT" \
      --env "PS1=[${PROJECT}] %~ %# " \
      -- \
      zsh -ic 'cd /workspace 2>/dev/null || true; exec zsh -i'
  fi
fi
