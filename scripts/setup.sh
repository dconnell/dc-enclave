#!/usr/bin/env bash
# =============================================================================
# scripts/setup.sh - One-time host setup for dev-containers.
#
# Idempotent and safe to re-run. Per active backend it: starts/reaches the
# runtime, picks a repos dir, creates the config + two-root overlay/recipe
# directories, writes the global config (DC_TEAM_DIR / DC_USER_DIR), registers a
# global gitignore for secrets, builds dev-base:latest into that backend's image
# store, and adds the `dc` alias + completion + DC_REPOS_DIR to the shell
# profile.
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

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/platform.sh"
source "$ROOT_DIR/lib/container-backend.sh"

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

echo "========================================"
echo "dev-containers: host setup"
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
  "$HOME/.config/dev-containers"
)

for dir in "${DIRS[@]}"; do
  mkdir -p "$dir"
  echo "  ✓ $dir"
done

GLOBAL_CONFIG="$HOME/.config/dev-containers/config"
DEFAULT_TEAM_DIR="$(dc_team_default_root)"
DEFAULT_USER_DIR="$(dc_user_default_root)"

echo ""
echo "==> Bootstrapping global config..."
if [[ ! -f "$GLOBAL_CONFIG" ]]; then
  cat > "$GLOBAL_CONFIG" <<EOF
# Global dev-containers config
# Each root may be its own git repo, holding both overlays/ (image layers) and
# container-recipes/ (per-container-name dc new recipe files).
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
_dc_setup_normalize() {
  local varname="$1"
  local val="${!varname}"
  if [[ "$val" == "~" || "$val" == "~/"* ]]; then
    val="$HOME${val#\~}"
  elif [[ "$val" != /* ]]; then
    val="$HOME/.config/dev-containers/$val"
  fi
  printf -v "$varname" '%s' "$val"
}

if ! DC_TEAM_DIR="$(dc_config_extract_scalar "$GLOBAL_CONFIG" DC_TEAM_DIR)" \
   || [[ -z "${DC_TEAM_DIR:-}" ]]; then
  echo "ERROR: DC_TEAM_DIR is not set (or is malformed) in ~/.config/dev-containers/config"
  echo "Set DC_TEAM_DIR and rerun scripts/setup.sh"
  exit 1
fi
if ! DC_USER_DIR="$(dc_config_extract_scalar "$GLOBAL_CONFIG" DC_USER_DIR)" \
   || [[ -z "${DC_USER_DIR:-}" ]]; then
  echo "ERROR: DC_USER_DIR is not set (or is malformed) in ~/.config/dev-containers/config"
  echo "Set DC_USER_DIR and rerun scripts/setup.sh"
  exit 1
fi
_dc_setup_normalize DC_TEAM_DIR
_dc_setup_normalize DC_USER_DIR

for _r in "$DC_TEAM_DIR" "$DC_USER_DIR"; do
  if [[ -e "$_r" && ! -d "$_r" ]]; then
    echo "ERROR: Root path is not a directory: $_r"
    exit 1
  fi
done
unset _r

mkdir -p "$DC_TEAM_DIR/overlays" "$DC_TEAM_DIR/container-recipes" \
         "$DC_USER_DIR/overlays" "$DC_USER_DIR/container-recipes"
DC_TEAM_DIR="$(cd -P "$DC_TEAM_DIR" && pwd)"
DC_USER_DIR="$(cd -P "$DC_USER_DIR" && pwd)"

echo ""
echo "==> Ensuring team/user root directories..."
echo "  ✓ $DC_TEAM_DIR/overlays"
echo "  ✓ $DC_TEAM_DIR/container-recipes"
echo "  ✓ $DC_USER_DIR/overlays"
echo "  ✓ $DC_USER_DIR/container-recipes"

# Starter READMEs for each namespace, so the on-disk layout is self-documenting.
_write_overlays_readme() {
  local dir="$1" who="$2"
  if [[ ! -f "$dir/README.md" ]]; then
    cat > "$dir/README.md" <<EOF
# ${who} overlays

Optional ${who}-wide overlay Containerfile fragments. Place files directly here
named Containerfile.<scope> so they are auto-layered when the matching scope is
selected with dc new or dc rebuild-container. For example:

- Containerfile.all
- Containerfile.<any-scope-name>

These files are automatically layered by dc new/dc rebuild-container when they
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
a container name (e.g. \`api\`) that pre-fills the inputs to \`dc new <name>\`
(scopes, cpus, memory, hide, network, ip, repo-path, port). \`dc new <name>\`
auto-loads \$DC_$(echo "$who" | tr '[:lower:]' '[:upper:]')_DIR/container-recipes/<name>
when it exists; user recipes override team recipes per key, and CLI flags
override both. The filename IS the container name.

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
_write_overlays_readme "$DC_TEAM_DIR/overlays" team
_write_overlays_readme "$DC_USER_DIR/overlays" user
_write_recipes_readme "$DC_TEAM_DIR/container-recipes" team
_write_recipes_readme "$DC_USER_DIR/container-recipes" user

# Register a global gitignore so per-project secrets (tokens, SSH keys, npmrc)
# are never accidentally committed, and point git at it.
GLOBAL_GITIGNORE="$HOME/.gitignore_global"
if ! grep -q "dev-containers secrets" "$GLOBAL_GITIGNORE" 2>/dev/null; then
  cat >> "$GLOBAL_GITIGNORE" <<'EOF'

# dev-containers secrets (never commit these)
github-token
*.github-token
ssh_key
ssh_key.pub
.npmrc.local
EOF
  git config --global core.excludesfile "$GLOBAL_GITIGNORE" 2>/dev/null || true
  echo "✓ Updated global .gitignore at $GLOBAL_GITIGNORE"
fi

# Build base image.
echo ""
echo "==> Building base container image (this takes a few minutes)..."
echo ""

echo "--- Building dev-base ---"
backend_build_image \
  "dev-base:latest" \
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
  # zsh command wiring: use a shell function, not an alias. Some users disable
  # alias expansion (`setopt no_aliases`) or have another `dc` on PATH
  # (historically the desk calculator), which makes an alias-based setup brittle.
  # A function is always resolved before PATH lookup and reliably forwards args.
  DC_UNALIAS_LINE="unalias dc 2>/dev/null"
  DC_FUNCTION_LINE="dc() { \"$ROOT_DIR/scripts/dc\" \"\$@\"; }"
  LEGACY_ALIAS_LINE="alias dc='$ROOT_DIR/scripts/dc'"

  if grep -Fxq "$DC_FUNCTION_LINE" "$PROFILE_FILE"; then
    echo "  ✓ dc command function already present in $PROFILE_FILE"
  else
    {
      echo ""
      echo "# dev-containers command"
      echo "$DC_UNALIAS_LINE"
      echo "$DC_FUNCTION_LINE"
    } >> "$PROFILE_FILE"
    echo "  ✓ Added dc command function to $PROFILE_FILE"
  fi

  # Migration: remove the exact legacy alias line managed by older setup runs.
  if grep -Fxq "$LEGACY_ALIAS_LINE" "$PROFILE_FILE"; then
    tmp_profile="$(mktemp)"
    grep -Fxv "$LEGACY_ALIAS_LINE" "$PROFILE_FILE" > "$tmp_profile"
    cat "$tmp_profile" > "$PROFILE_FILE"
    rm -f "$tmp_profile"
    echo "  ✓ Removed legacy dc alias line from $PROFILE_FILE"
  fi

  # Native zsh completion: put scripts/ on fpath, autoload _dc, ensure
  # compinit has run, and bind it to dc. Explicit compdef + autoload means this
  # works regardless of whether the user's own compinit runs before or after.
  # Bind _dc to `dc`. Because dc is a shell function (wired above), zsh
  # resolves the command name directly and `_comps[dc]` is what fires on
  # `dc <TAB>` -- no path-keyed binding is needed (that was an artifact of the
  # old alias-based wiring, where completion could key off the expanded alias
  # path). The path-qualified form is retained only as a legacy migration target.
  COMPDEF_LINE="compdef _dc dc"
  LEGACY_COMPDEF_LINE="compdef _dc dc '$ROOT_DIR/scripts/dc'"

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
        echo "# dev-containers completion (zsh)"
        echo "fpath+=('$ROOT_DIR/scripts')"
        echo "autoload -Uz _dc"
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
  # left a `source .../dc-complete.bash` line in ~/.zshrc. That file ends in the
  # bash-only `complete -F` builtin, which errors under zsh. Remove our exact
  # line if present; never touch anything else.
  STALE_BASH_COMP="source '$ROOT_DIR/scripts/dc-complete.bash'"
  if grep -Fq "$STALE_BASH_COMP" "$PROFILE_FILE"; then
    tmp_profile="$(mktemp)"
    grep -Fv "$STALE_BASH_COMP" "$PROFILE_FILE" > "$tmp_profile"
    cat "$tmp_profile" > "$PROFILE_FILE"
    rm -f "$tmp_profile"
    echo "  ✓ Removed stale bash completion line from $PROFILE_FILE (replaced by native zsh completion)"
  fi
else
  # bash command alias.
  ALIAS_LINE="alias dc='$ROOT_DIR/scripts/dc'"
  if ! grep -Fq "$ALIAS_LINE" "$PROFILE_FILE"; then
    {
      echo ""
      echo "# dev-containers alias"
      echo "$ALIAS_LINE"
    } >> "$PROFILE_FILE"
    echo "  ✓ Added dc alias to $PROFILE_FILE"
  fi

  # bash: source the bash completion file (unchanged behavior).
  COMPLETION_LINE="source '$ROOT_DIR/scripts/dc-complete.bash'"
  if ! grep -Fq "$COMPLETION_LINE" "$PROFILE_FILE"; then
    {
      echo ""
      echo "# dev-containers completion"
      echo "$COMPLETION_LINE"
    } >> "$PROFILE_FILE"
    echo "  ✓ Added dc completion to $PROFILE_FILE"
  else
    echo "  ✓ dc completion already present in $PROFILE_FILE"
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
    echo "# dev-containers repos directory"
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
echo ""
echo "Next:"
echo "  1. source $PROFILE_FILE   (or start a new $USER_SHELL shell)"
echo "  2. dc new <name> [scope] [port:port]"
