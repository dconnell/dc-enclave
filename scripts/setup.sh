#!/usr/bin/env bash
# =============================================================================
# scripts/setup.sh - One-time host setup for DC Enclave.
#
# Idempotent and safe to re-run. Per active backend it: starts/reaches the
# runtime, picks a repos dir, creates the config + two-root overlay/recipe/
# extension directories, writes the global config (DC_TEAM_DIR / DC_USER_DIR),
# registers a global gitignore for secrets, builds dce-base:latest into that
# backend's image store, and adds the `dce` alias + completion + DC_REPOS_DIR to
# the shell profile.
#
# Run once per backend you use - image stores are not shared across backends.
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
source "$ROOT_DIR/lib/platform.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

echo "========================================"
echo "DC Enclave: host setup"
echo "========================================"
echo ""
echo "Selected backend: $ACTIVE_BACKEND"
echo "CLI version: $(backend_version)"

# Initialize backend runtime when needed.
echo ""
case "$ACTIVE_BACKEND" in
  apple)
    echo "==> Starting apple/container system daemon..."
    backend_system_start 2>/dev/null && echo "✓ Daemon started" || echo "  (already running or not needed)"
    ;;
  colima)
    echo "==> Checking Colima runtime availability..."
    if backend_system_start; then
      echo "✓ Colima Docker runtime is reachable"
    else
      echo "✗ ERROR: Colima runtime is not reachable."
      echo "  Ensure Colima uses Docker runtime and Docker context points to Colima."
      echo "  Try: colima start --runtime docker && docker context use colima"
      exit 1
    fi
    ;;
  docker|orbstack)
    echo "==> Checking Docker-compatible runtime availability..."
    if backend_system_start 2>/dev/null; then
      echo "✓ Docker engine is reachable"
    else
      echo "✗ ERROR: Docker engine is not reachable."
      echo "  Start Docker Desktop or OrbStack and rerun setup."
      exit 1
    fi
    ;;
  podman)
    echo "==> Checking Podman runtime availability..."
    if backend_system_start 2>/dev/null; then
      echo "✓ Podman runtime is reachable"
    else
      echo "✗ ERROR: Podman runtime is not reachable."
      echo "  Start Podman (for macOS: podman machine start) and rerun setup."
      exit 1
    fi
    ;;
esac

REPOS_DIR_PROMPT="${DC_REPOS_DIR:-$HOME/repos}"
echo ""
echo "==> Repos directory"
echo "  Current: $REPOS_DIR_PROMPT"
read -r -p "  Enter base repos directory [$REPOS_DIR_PROMPT]: " repos_dir_input
if [[ -n "$repos_dir_input" ]]; then
  REPOS_DIR_PROMPT="$repos_dir_input"
fi

# shellcheck disable=SC2088
# ~ is a literal char matched against user input, not an expansion.
if [[ "$REPOS_DIR_PROMPT" == "~" || "$REPOS_DIR_PROMPT" == "~/"* ]]; then
  REPOS_DIR_PROMPT="$HOME${REPOS_DIR_PROMPT#\~}"
elif [[ "$REPOS_DIR_PROMPT" != /* ]]; then
  REPOS_DIR_PROMPT="$PWD/$REPOS_DIR_PROMPT"
fi

mkdir -p "$REPOS_DIR_PROMPT"
REPOS_DIR_PROMPT="$(cd -P "$REPOS_DIR_PROMPT" && pwd)"
echo "  ✓ $REPOS_DIR_PROMPT"

echo ""
echo "==> Creating host directories..."

DIRS=(
  "$HOME/.config/dce-enclave"
)

for dir in "${DIRS[@]}"; do
  mkdir -p "$dir"
  echo "  ✓ $dir"
done

GLOBAL_CONFIG="$HOME/.config/dce-enclave/config"
DEFAULT_TEAM_DIR="$(dce_team_default_root)"
DEFAULT_USER_DIR="$(dce_user_default_root)"

echo ""
echo "==> Bootstrapping global config..."
if [[ ! -f "$GLOBAL_CONFIG" ]]; then
  cat > "$GLOBAL_CONFIG" <<EOF
# Global DC Enclave config
# Each root may be its own git repo, holding both overlays/ (image layers) and
# container-recipes/ (per-container-name dce new recipe files).
DC_TEAM_DIR="$DEFAULT_TEAM_DIR"
DC_USER_DIR="$DEFAULT_USER_DIR"
EOF
  echo "  ✓ Created $GLOBAL_CONFIG"
fi

# Ensure both roots are present in the config (idempotent). Each writes a clean
# quoted assignment appended if absent.
_ensure_config_key() {
  local key="$1" value="$2"
  if grep -Eq "^[[:space:]]*${key}=" "$GLOBAL_CONFIG"; then
    echo "  ✓ ${key} already present in $GLOBAL_CONFIG"
  else
    {
      echo ""
      printf '%s="%s"\n' "$key" "$value"
    } >> "$GLOBAL_CONFIG"
    echo "  ✓ Added ${key} to $GLOBAL_CONFIG"
  fi
}
_ensure_config_key DC_TEAM_DIR "$DEFAULT_TEAM_DIR"
_ensure_config_key DC_USER_DIR "$DEFAULT_USER_DIR"

# Read both roots back through the hardened parser (no `source`), so a
# hand-edited global config can't execute code during setup.
_dce_setup_normalize() {
  local varname="$1"
  printf -v "$varname" '%s' "$(dce_expand_tilde "${!varname}" config)"
}

if ! DC_TEAM_DIR="$(dce_config_extract_scalar "$GLOBAL_CONFIG" DC_TEAM_DIR)" \
   || [[ -z "${DC_TEAM_DIR:-}" ]]; then
  dce_die "DC_TEAM_DIR is not set (or is malformed) in ~/.config/dce-enclave/config
Set DC_TEAM_DIR and rerun scripts/setup.sh"
fi
if ! DC_USER_DIR="$(dce_config_extract_scalar "$GLOBAL_CONFIG" DC_USER_DIR)" \
   || [[ -z "${DC_USER_DIR:-}" ]]; then
  dce_die "DC_USER_DIR is not set (or is malformed) in ~/.config/dce-enclave/config
Set DC_USER_DIR and rerun scripts/setup.sh"
fi
_dce_setup_normalize DC_TEAM_DIR
_dce_setup_normalize DC_USER_DIR

for _r in "$DC_TEAM_DIR" "$DC_USER_DIR"; do
  if [[ -e "$_r" && ! -d "$_r" ]]; then
    dce_die "Root path is not a directory: $_r"
  fi
done
unset _r

mkdir -p "$DC_TEAM_DIR/overlays" "$DC_TEAM_DIR/container-recipes" \
         "$DC_TEAM_DIR/extensions/vscode" \
         "$DC_USER_DIR/overlays" "$DC_USER_DIR/container-recipes" \
         "$DC_USER_DIR/extensions/vscode"
DC_TEAM_DIR="$(cd -P "$DC_TEAM_DIR" && pwd)"
DC_USER_DIR="$(cd -P "$DC_USER_DIR" && pwd)"

echo ""
echo "==> Ensuring team/user root directories..."
echo "  ✓ $DC_TEAM_DIR/overlays"
echo "  ✓ $DC_TEAM_DIR/container-recipes"
echo "  ✓ $DC_TEAM_DIR/extensions/vscode"
echo "  ✓ $DC_USER_DIR/overlays"
echo "  ✓ $DC_USER_DIR/container-recipes"
echo "  ✓ $DC_USER_DIR/extensions/vscode"

# Starter READMEs for each namespace, so the on-disk layout is self-documenting.
_write_overlays_readme() {
  local dir="$1" who="$2"
  if [[ ! -f "$dir/README.md" ]]; then
    cat > "$dir/README.md" <<EOF
# ${who} overlays

Optional ${who}-wide overlay Containerfile fragments. Place files directly here
named Containerfile.<scope> so they are auto-layered when the matching scope is
selected with dce new or dce rebuild-container. For example:

- Containerfile.all
- Containerfile.<any-scope-name>

These files are automatically layered by dce new/dce rebuild-container when they
exist.
EOF
    echo "  ✓ Created $dir/README.md"
  fi
}
_write_recipes_readme() {
  local dir="$1" who="$2"
  if [[ ! -f "$dir/README.md" ]]; then
    cat > "$dir/README.md" <<EOF
# ${who} container recipes

Optional ${who}-wide container recipes. A recipe is a key=value file named after
a container name (e.g. \`api\`) that pre-fills the inputs to \`dce new <name>\`
(scopes, cpus, memory, hide, network, ip, repo-path, port). \`dce new <name>\`
auto-loads \$DC_$(echo "$who" | tr '[:lower:]' '[:upper:]')_DIR/container-recipes/<name>
when it exists; user recipes override team recipes per key, and CLI flags
override both. The filename IS the container name.

repo-path is gated: an auto-loaded recipe cannot silently widen the host bind
mount. A recipe-sourced repo-path that resolves OUTSIDE the default repos dir
(\$DC_REPOS_DIR or ~/repos) asks for confirmation (--yes/-y honors it); values
that resolve to /, your home, the repos root, or a parent of it are rejected.
CLI --repo-path is never gated.

Example:
  scopes=nodejs,postgres
  cpus=2
  memory=4g
  hide=node_modules
  port=3000:3000
EOF
    echo "  ✓ Created $dir/README.md"
  fi
}
_write_extensions_readme() {
  local dir="$1" who="$2"
  if [[ ! -f "$dir/README.md" ]]; then
    cat > "$dir/README.md" <<EOF
# ${who} VS Code extensions

Optional ${who}-wide VS Code extension manifests. A manifest is a plain-text
file named <scope>.txt (e.g. nodejs.txt) with one extension id per line in
publisher.name form. Blank lines and # comments are allowed.

These files are layered by dce new and dce config sync-vscode using the same
model as overlays: an all.txt (if present) is prepended, then each effective
project scope; the team file is read before the user file per scope, and first
occurrence wins (de-duplicated, order-preserving). The merged set seeds and
syncs customizations.vscode.extensions in .devcontainer/devcontainer.json.

Inspect the resolved set, check runtime drift, and curate ids back into a
manifest here:

  dce extensions show <project>
  dce extensions diff <project>
  dce extensions capture <project> --scope <scope> <publisher.name>...
EOF
    echo "  ✓ Created $dir/README.md"
  fi
}
_write_overlays_readme "$DC_TEAM_DIR/overlays" team
_write_overlays_readme "$DC_USER_DIR/overlays" user
_write_recipes_readme "$DC_TEAM_DIR/container-recipes" team
_write_recipes_readme "$DC_USER_DIR/container-recipes" user
_write_extensions_readme "$DC_TEAM_DIR/extensions/vscode" team
_write_extensions_readme "$DC_USER_DIR/extensions/vscode" user

# Register a global gitignore so per-project secrets (tokens, SSH keys, npmrc)
# are never accidentally committed, and point git at it.
GLOBAL_GITIGNORE="$HOME/.gitignore_global"
if ! grep -q "DC Enclave secrets" "$GLOBAL_GITIGNORE" 2>/dev/null; then
  cat >> "$GLOBAL_GITIGNORE" <<'EOF'

# DC Enclave secrets (never commit these)
github-token
*.github-token
gitlab-token
*.gitlab-token
ssh_key
ssh_key.pub
.npmrc.local
EOF
  git config --global core.excludesfile "$GLOBAL_GITIGNORE" 2>/dev/null || true
  echo "✓ Updated global .gitignore at $GLOBAL_GITIGNORE"
fi

# BuildKit/buildx is required: dce Containerfiles use multi-line heredoc RUNs
# that the legacy builder drops, so backend_build_image builds with
# DOCKER_BUILDKIT=1, which needs the buildx plugin. Verify BEFORE the build so a
# missing plugin fails fast with install instructions instead of a mid-build
# error. No-op on podman (own builder) / apple (separate path).
if ! dce_buildx_require; then
  exit 1
fi

# Build base image.
echo ""
echo "==> Building base container image (this takes a few minutes)..."
echo ""

echo "--- Building dce-base ---"
backend_build_image \
  "dce-base:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.base" \
  "$ROOT_DIR"

# Optional VS Code extension check for Docker-compatible backends.
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  echo ""
  echo "==> Optional check: VS Code Dev Containers extension"
  if command -v code >/dev/null 2>&1; then
    if code --list-extensions 2>/dev/null | grep -qi '^ms-vscode-remote.remote-containers$'; then
      echo "✓ VS Code Dev Containers extension is installed"
    else
      echo "! VS Code Dev Containers extension not detected"
      echo "  Install extension ID: ms-vscode-remote.remote-containers"
      echo "  Non-VS Code workflows are unaffected."
    fi
  else
    echo "  (VS Code CLI not found; skipping extension check)"
    echo "  Non-VS Code workflows are unaffected."
  fi
fi

# Optional Mutagen check: only the docker-compatible backends support synced
# workspaces (--sync); apple/container has no Mutagen transport, so the check
# is skipped there (an "installed" line would imply --sync works there, which
# it does not). Mutagen is a host-side daemon, never required for the default
# bind-mount path; absence is informational, not fatal. dce verifies, never
# installs (plans/sync.md decision #11).
if dce_sync_backend_supported "$ACTIVE_BACKEND"; then
  echo ""
  echo "==> Optional check: Mutagen sync daemon (for dce new --sync)"
  if dce_mutagen_present; then
    echo "✓ Mutagen sync daemon is installed ($(dce_mutagen_version))"
    echo "  Synced workspaces (--sync) are available."
  else
    echo "! Mutagen sync daemon not found"
    echo "  Needed only for synced workspaces (dce new --sync / dce rebuild-container --sync)."
    echo "  The default bind-mount workflow does not require it."
    echo "  Install:  $(dce_mutagen_install_hint)"
    echo "  See:      docs/how-to/sync-workspace.md"
  fi
fi

# Add command shortcut + completion to the right shell profile. Profile selection is
# shell-driven (via $SHELL), not platform-driven: macOS defaults to zsh, so the
# old platform_bash_profile() choice wrote to ~/.bash_profile for users whose
# login shell never reads it. See lib/platform.sh.
USER_SHELL="$(platform_user_shell)"
PROFILE_FILE="$(platform_profile_file "$USER_SHELL")"
touch "$PROFILE_FILE"
echo ""
echo "==> Shell integration ($USER_SHELL -> $PROFILE_FILE)"

if [[ "$USER_SHELL" == "zsh" ]]; then
  # zsh command wiring: use a shell function, not an alias. A function is always
  # resolved before PATH lookup and reliably forwards args, so it stays robust
  # even if a user disables alias expansion (`setopt no_aliases`).
  DC_UNALIAS_LINE="unalias dce 2>/dev/null"
  DC_FUNCTION_LINE="dce() { \"$ROOT_DIR/scripts/dce\" \"\$@\"; }"
  LEGACY_ALIAS_LINE="alias dce='$ROOT_DIR/scripts/dce'"

  if grep -Fxq "$DC_FUNCTION_LINE" "$PROFILE_FILE"; then
    echo "  ✓ dce command function already present in $PROFILE_FILE"
  else
    {
      echo ""
      echo "# DC Enclave command"
      echo "$DC_UNALIAS_LINE"
      echo "$DC_FUNCTION_LINE"
    } >> "$PROFILE_FILE"
    echo "  ✓ Added dce command function to $PROFILE_FILE"
  fi

  # Migration: remove the exact legacy alias line managed by older setup runs.
  if grep -Fxq "$LEGACY_ALIAS_LINE" "$PROFILE_FILE"; then
    tmp_profile="$(mktemp)"
    grep -Fxv "$LEGACY_ALIAS_LINE" "$PROFILE_FILE" > "$tmp_profile"
    cat "$tmp_profile" > "$PROFILE_FILE"
    rm -f "$tmp_profile"
    echo "  ✓ Removed legacy dce alias line from $PROFILE_FILE"
  fi

  # Native zsh completion: put scripts/ on fpath, autoload _dce, ensure
  # compinit has run, and bind it to dce. Explicit compdef + autoload means this
  # works regardless of whether the user's own compinit runs before or after.
  # Bind _dce to `dce`. Because dce is a shell function (wired above), zsh
  # resolves the command name directly and `_comps[dce]` is what fires on
  # `dce <TAB>` -- no path-keyed binding is needed (that was an artifact of the
  # old alias-based wiring, where completion could key off the expanded alias
  # path). The path-qualified form is retained only as a legacy migration target.
  COMPDEF_LINE="compdef _dce dce"
  LEGACY_COMPDEF_LINE="compdef _dce dce '$ROOT_DIR/scripts/dce'"

  # Exact-line match (-Fxq): the new line is a substring of the legacy
  # path-qualified form, so a plain -F substring check would falsely report a
  # legacy line as already migrated.
  if grep -Fxq "$COMPDEF_LINE" "$PROFILE_FILE"; then
    echo "  ✓ Native zsh completion already present in $PROFILE_FILE"
  else
    if grep -Fxq "$LEGACY_COMPDEF_LINE" "$PROFILE_FILE"; then
      tmp_profile="$(mktemp)"
      awk -v old="$LEGACY_COMPDEF_LINE" -v new="$COMPDEF_LINE" '
        $0 == old { print new; next }
        { print }
      ' "$PROFILE_FILE" > "$tmp_profile"
      cat "$tmp_profile" > "$PROFILE_FILE"
      rm -f "$tmp_profile"
      echo "  ✓ Updated zsh compdef mapping in $PROFILE_FILE"
    else
      {
        echo ""
        echo "# DC Enclave completion (zsh)"
        echo "fpath+=('$ROOT_DIR/scripts')"
        echo "autoload -Uz _dce"
        echo "autoload -Uz compinit"
        echo "(( \${+_comps} )) || compinit -u"
        echo "$COMPDEF_LINE"
      } >> "$PROFILE_FILE"
      echo "  ✓ Added native zsh completion to $PROFILE_FILE"
    fi
  fi

  # Cleanup: if both legacy and new compdef lines exist, drop the legacy one.
  if grep -Fxq "$LEGACY_COMPDEF_LINE" "$PROFILE_FILE" \
     && grep -Fxq "$COMPDEF_LINE" "$PROFILE_FILE"; then
    tmp_profile="$(mktemp)"
    grep -Fxv "$LEGACY_COMPDEF_LINE" "$PROFILE_FILE" > "$tmp_profile"
    cat "$tmp_profile" > "$PROFILE_FILE"
    rm -f "$tmp_profile"
    echo "  ✓ Removed legacy zsh compdef line from $PROFILE_FILE"
  fi

  # Migration: a previous (bash-targeted) setup, or a manual bridge, may have
  # left a `source .../dce-complete.bash` line in ~/.zshrc. That file ends in the
  # bash-only `complete -F` builtin, which errors under zsh. Remove our exact
  # line if present; never touch anything else.
  STALE_BASH_COMP="source '$ROOT_DIR/scripts/dce-complete.bash'"
  if grep -Fq "$STALE_BASH_COMP" "$PROFILE_FILE"; then
    tmp_profile="$(mktemp)"
    grep -Fv "$STALE_BASH_COMP" "$PROFILE_FILE" > "$tmp_profile"
    cat "$tmp_profile" > "$PROFILE_FILE"
    rm -f "$tmp_profile"
    echo "  ✓ Removed stale bash completion line from $PROFILE_FILE (replaced by native zsh completion)"
  fi
else
  # bash command alias.
  ALIAS_LINE="alias dce='$ROOT_DIR/scripts/dce'"
  if ! grep -Fq "$ALIAS_LINE" "$PROFILE_FILE"; then
    {
      echo ""
      echo "# DC Enclave alias"
      echo "$ALIAS_LINE"
    } >> "$PROFILE_FILE"
    echo "  ✓ Added dce alias to $PROFILE_FILE"
  fi

  # bash: source the bash completion file (unchanged behavior).
  COMPLETION_LINE="source '$ROOT_DIR/scripts/dce-complete.bash'"
  if ! grep -Fq "$COMPLETION_LINE" "$PROFILE_FILE"; then
    {
      echo ""
      echo "# DC Enclave completion"
      echo "$COMPLETION_LINE"
    } >> "$PROFILE_FILE"
    echo "  ✓ Added dce completion to $PROFILE_FILE"
  else
    echo "  ✓ dce completion already present in $PROFILE_FILE"
  fi
fi

REPOS_DIR_EXPORT_LINE="export DC_REPOS_DIR=\"$REPOS_DIR_PROMPT\""
if grep -Eq "^(export[[:space:]]+)?DC_REPOS_DIR=" "$PROFILE_FILE" 2>/dev/null; then
  tmp_profile="$(mktemp)"
  awk -v line="$REPOS_DIR_EXPORT_LINE" '
    /^(export[[:space:]]+)?DC_REPOS_DIR=/ {
      if (!updated) {
        print line
        updated=1
      }
      next
    }
    { print }
  ' "$PROFILE_FILE" > "$tmp_profile"
  cat "$tmp_profile" > "$PROFILE_FILE"
  rm -f "$tmp_profile"
  echo "✓ Updated DC_REPOS_DIR in $PROFILE_FILE"
else
  {
    echo ""
    echo "# DC Enclave repos directory"
    echo "$REPOS_DIR_EXPORT_LINE"
  } >> "$PROFILE_FILE"
  echo "✓ Added DC_REPOS_DIR to $PROFILE_FILE"
fi

echo ""
echo "======================================================================"
echo "Setup complete."
echo "======================================================================"
echo "Backend: $ACTIVE_BACKEND"
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  echo "VS Code is optional; non-VS Code shell workflows work."
else
  echo "VS Code integration uses terminal profile passthrough."
fi
if dce_sync_backend_supported "$ACTIVE_BACKEND"; then
  if dce_mutagen_present; then
    echo "Mutagen: installed (--sync available)"
  else
    echo "Mutagen: not installed (--sync unavailable; see docs/how-to/sync-workspace.md)"
  fi
fi
if backend_is_docker_compatible "$ACTIVE_BACKEND"; then
  echo "buildx: installed (BuildKit image builds enabled)"
fi
echo ""
echo "Next:"
echo "  1. source $PROFILE_FILE   (or start a new $USER_SHELL shell)"
echo "  2. dce new <name> [scope] [port:port]"
