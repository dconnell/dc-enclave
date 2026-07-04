#!/usr/bin/env bash
# =============================================================================
# lib/extensions.sh - Editor extension manifest registry + resolution.
#
# Everything that differs per editor lives HERE as data, not scattered as
# hardcoded constants across scripts. An editor is a short id ("vscode"); each
# field is returned by the helpers below.
#
# v1 ships the VS Code adapter only ("vscode"). It maps to the "vscode"
# namespace: manifests live under $DC_{TEAM,USER}_DIR/extensions/vscode/<scope>.txt
# and the devcontainer.json target is customizations.vscode.extensions.
#
# Adding an editor = adding lines to the case branches below (namespace +
# dispatch). Nothing editor-specific leaks outside this file. The pure
# host-side helpers (resolve/parse/format/manifests_exist/minus) have NO
# container-backend dependency; the dispatch helpers (list_installed /
# list_host / install_one) call backend_exec, so the caller (a scripts/*.sh)
# must source lib/container-backend.sh before invoking them.
#
# See plans/extensions.md for the full design, including the migration guard
# and the two drift dimensions (declaration vs runtime).
# =============================================================================

# Auto-source deps if this lib is loaded directly (single-import convenience),
# mirroring the idiom in lib/devcontainer.sh / lib/editor.sh.
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_ext_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_ext_lib_dir/common.sh"
  unset _dce_ext_lib_dir
fi

if [[ -z "${_DC_PLATFORM_SH_LOADED:-}" ]]; then
  _dce_ext_platform_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_ext_platform_lib_dir/platform.sh"
  unset _dce_ext_platform_lib_dir
fi

if [[ -n "${_DC_EXTENSIONS_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_EXTENSIONS_SH_LOADED=1

# Echo every editor id with extension management support, one per line. The
# extension-supported subset is intentionally separate from the launcher
# registry (dce_editor_known_ids in lib/editor.sh): a launcher-known editor
# (e.g. vscode-insiders) may not yet have an extension adapter. v1: vscode.
dce_ext_supported_editors() {
  printf 'vscode\n'
}

# Return 0 if ID has extension-management support, 1 otherwise.
dce_ext_is_supported() {
  local id="$1" k=""
  while IFS= read -r k; do
    [[ "$k" == "$id" ]] && return 0
  done < <(dce_ext_supported_editors)
  return 1
}

# Canonical id for a loose spelling. Accepts the binary name "code" as an alias
# for "vscode" so users can pass --editor code. Anything else passes through
# unchanged and is then validated by dce_ext_is_supported at the call site.
dce_ext_normalize_editor() {
  local raw="$1"
  case "$raw" in
    code) printf 'vscode' ;;
    *)    printf '%s' "$raw" ;;
  esac
}

# Echo the default editor id for extension management. VS Code is the only
# editor with extension management in v1.
dce_ext_default_editor() {
  printf 'vscode'
}

# Map an editor id to its namespace: the path segment under extensions/ and the
# customizations.<namespace> key in devcontainer.json. Fails closed (non-zero,
# no output) for an unsupported editor so a typo can never silently pick a
# default namespace. v1: vscode -> vscode.
dce_ext_namespace() {
  local editor="$1"
  case "$editor" in
    vscode) printf 'vscode' ;;
    *) return 1 ;;
  esac
}

# Absolute path of a single manifest file under a root. <root> is a DC_TEAM_DIR
# or DC_USER_DIR; the editor's namespace is interpolated. Fails for an unknown
# editor.
dce_ext_manifest_path() {
  local root="$1" editor="$2" scope="$3"
  local ns=""
  ns="$(dce_ext_namespace "$editor")" || return 1
  printf '%s/extensions/%s/%s.txt\n' "$root" "$ns" "$scope"
}

# Parse a manifest file and emit extension IDs, one per line. Strips '#'
# comments (full-line and inline -- extension IDs contain no '#'), blank lines,
# and a trailing CR; trims surrounding whitespace; de-duplicates within the file
# preserving first-occurrence order. A missing file is a no-op (no output).
dce_ext_parse_manifest() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local line stripped id
  local -A seen=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    # Drop an inline/full-line comment: everything from the first '#'.
    stripped="${line%%#*}"
    # Trim leading/trailing whitespace.
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    [[ -z "$stripped" ]] && continue
    [[ -n "${seen[$stripped]:-}" ]] && continue
    seen["$stripped"]=1
    printf '%s\n' "$stripped"
  done < "$file"
}

# Resolve the merged, de-duplicated, order-preserved extension set for a project
# scope selection. Reuses the overlay scope model: "all" is auto-prepended when
# any all manifest exists, then each requested scope (excluding "all") is
# appended. Files are read team-then-user per scope, so the canonical order is
# team-all -> user-all -> team-<scope> -> user-<scope>. First occurrence of an
# ID wins (de-dup). Missing files are silently skipped -- an extension manifest
# is optional. Returns 1 for an unsupported editor or an invalid scope name;
# emits nothing on an empty resolution.
dce_ext_resolve_set() {
  local editor="$1" team_root="$2" user_root="$3" scopes_csv="$4"

  local ns=""
  ns="$(dce_ext_namespace "$editor")" || return 1
  local team_dir="$team_root/extensions/$ns"
  local user_dir="$user_root/extensions/$ns"

  local norm=""
  norm="$(dce_normalize_scopes_csv "$scopes_csv" 2>/dev/null)" || return 1

  local -a scopes=()
  if [[ -f "$team_dir/all.txt" || -f "$user_dir/all.txt" ]]; then
    scopes+=("all")
  fi
  local -a req=()
  local _s
  if [[ -n "$norm" ]]; then
    local IFS=','
    read -r -a req <<< "$norm"
  fi
  for _s in "${req[@]}"; do
    [[ -n "$_s" ]] || continue
    [[ "$_s" == "all" ]] && continue
    scopes+=("$_s")
  done

  local -A seen=()
  local -a ids_out=()
  local scope root file
  for scope in "${scopes[@]}"; do
    for root in "$team_dir" "$user_dir"; do
      file="$root/$scope.txt"
      [[ -f "$file" ]] || continue
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        [[ -n "${seen[$id]:-}" ]] && continue
        seen["$id"]=1
        ids_out+=("$id")
      done < <(dce_ext_parse_manifest "$file")
    done
  done

  if [[ ${#ids_out[@]} -gt 0 ]]; then
    printf '%s\n' "${ids_out[@]}"
  fi
  return 0
}

# Convenience wrapper: resolve the effective set (dce_ext_resolve_set) and render
# it as a comma-joined CSV. Used by `dce new` and `dce config sync-vscode` to
# derive the seeded/synced extensions array. Echoes "" on an empty resolution;
# propagates dce_ext_resolve_set's non-zero status on failure.
dce_ext_resolve_csv() {
  local editor="$1" team_root="$2" user_root="$3" scopes_csv="$4"
  local out=""
  out="$(dce_ext_resolve_set "$editor" "$team_root" "$user_root" "$scopes_csv")" || return 1
  [[ -z "$out" ]] && { printf ''; return 0; }
  printf '%s\n' "$out" | tr '\n' ',' | sed 's/,$//'
}

# Migration-guard predicate: return 0 if ANY effective-scope manifest exists for
# the editor (including "all"), 1 otherwise. Used to decide whether
# dce_devcontainer_sync should manage the customizations.<ns>.extensions array
# (adopt -> fully-managed) or leave it untouched (pre-adoption -> preserve).
dce_ext_manifests_exist() {
  local editor="$1" team_root="$2" user_root="$3" scopes_csv="$4"

  local ns=""
  ns="$(dce_ext_namespace "$editor")" || return 1
  local team_dir="$team_root/extensions/$ns"
  local user_dir="$user_root/extensions/$ns"

  local norm=""
  norm="$(dce_normalize_scopes_csv "$scopes_csv" 2>/dev/null)" || {
    # Fail closed on a malformed non-empty scope set, matching resolve_set. An
    # empty CSV is not an error (it legitimately means "only the all manifest").
    [[ -z "$scopes_csv" ]] && norm="" || return 1
  }

  local -a check=("all")
  local -a req=()
  local _s
  if [[ -n "$norm" ]]; then
    local IFS=','
    read -r -a req <<< "$norm"
  fi
  for _s in "${req[@]}"; do
    [[ -n "$_s" ]] || continue
    [[ "$_s" == "all" ]] && continue
    check+=("$_s")
  done

  local scope
  for scope in "${check[@]}"; do
    if [[ -f "$team_dir/$scope.txt" || -f "$user_dir/$scope.txt" ]]; then
      return 0
    fi
  done
  return 1
}

# Render a list of extension IDs in the requested format:
#   ids      one ID per line (default-like)
#   manifest alias for ids (the file body)
#   json     a JSON array ["a","b"] suitable for customizations.<ns>.extensions
# IDs are json-escaped in the json format. Empty set -> ids/manifest empty,
# json "[]". Returns 1 for an unknown format.
#
# The `editor` argument is RESERVED: all v1 formats are editor-neutral. It is
# part of the signature so a future editor that formats differently (e.g. a
# non-JSON manifest format) can branch on it without an API break.
dce_ext_format() {
  local format="$1" editor="$2"
  shift 2
  # Currently unused; kept on the API for forward-compat (see doc comment).
  : "$editor"
  local id esc arr=""
  case "$format" in
    ids|manifest)
      for id in "$@"; do
        [[ -n "$id" ]] && printf '%s\n' "$id"
      done
      ;;
    json)
      for id in "$@"; do
        [[ -z "$id" ]] && continue
        esc="$(dce_json_escape "$id")"
        arr+="\"$esc\","
      done
      [[ "$arr" == *, ]] && arr="${arr%,}"
      printf '[%s]' "$arr"
      ;;
    *)
      return 1
      ;;
  esac
}

# Validate a VS Code extension ID (publisher.name). Used by `capture` to keep
# garbage out of manifests: an ID containing '#' would be silently truncated by
# parse_manifest's comment stripping, a space would split across argv, and a
# '/' would risk path confusion. The pattern requires a dot, an alphanumeric
# lead char, and only [A-Za-z0-9._-] otherwise (the charset real IDs use).
dce_ext_is_valid_id() {
  local id="$1"
  [[ -n "$id" ]] || return 1
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$ ]]
}

# Set difference: read list A on stdin (one per line) and emit the items NOT
# present among the positional arguments (list B). Blank lines in A are
# skipped. Used by the `available` (host minus container) and `diff`
# (container minus declared / declared minus container) subcommands. Extension
# counts are small (<1000), so passing B as args is safe.
dce_ext_minus() {
  local -A in_b=()
  local b
  for b in "$@"; do
    [[ -n "$b" ]] && in_b["$b"]=1
  done
  local a
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    [[ -n "${in_b[$a]:-}" ]] && continue
    printf '%s\n' "$a"
  done
}

# -----------------------------------------------------------------------------
# Dispatch helpers (require a backend). The caller (a scripts/*.sh) must source
# lib/container-backend.sh before invoking these. v1 implements vscode only.
# -----------------------------------------------------------------------------

# Resolve the in-container VS Code `code` CLI path. The `code` binary is part
# of the VS Code Server, which VS Code injects into the container on first
# attach (Dev Containers: Attach to Running Container...). VS Code Server adds
# `code` to PATH only for VS Code's integrated terminal (via session env), NOT
# for the container's default env -- so a bare `docker exec <name> code ...`
# fails with "code: not found" even though the user's interactive shell sees
# `code` fine. Resolve via PATH first, then fall back to globbing canonical VS
# Code Server install locations. Ignore `.../bin/remote-cli/code`: that wrapper
# is VS Code-terminal/WSL-only and fails under normal host `docker exec`.
#
# Returns the absolute path on stdout (return 0) when found; returns 1 with no
# output when VS Code Server is not yet injected (the container has never been
# opened in VS Code). Single sh -c so resolution costs one exec round-trip and
# works on every backend that passes args through to the container's shell.
_dce_ext_vscode_container_bin() {
  local container="$1"
  # shellcheck disable=SC2016  # $HOME et al must expand INSIDE the container shell, not on the host
  backend_exec "$container" sh -c '
    bin="$(command -v code 2>/dev/null)" || bin=""
    # A remote-cli wrapper is not usable from plain docker exec. If PATH points
    # there, prefer a sibling code/code-server binary; otherwise keep searching.
    if [ -n "$bin" ] && [ "${bin%/remote-cli/code}" != "$bin" ]; then
      pref_code="${bin%/remote-cli/code}/code"
      pref_server="${bin%/remote-cli/code}/code-server"
      if [ -x "$pref_code" ]; then
        bin="$pref_code"
      elif [ -x "$pref_server" ]; then
        bin="$pref_server"
      else
        bin=""
      fi
    fi
    if [ -n "$bin" ]; then
      printf "%s" "$bin"
      exit 0
    fi

    # docker exec can run with HOME unset/non-interactive envs; derive a best-
    # effort home and search canonical VS Code Server install paths directly.
    home="${HOME:-}"
    if [ -z "$home" ] && command -v getent >/dev/null 2>&1; then
      home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    fi

    for c in \
      "$home"/.vscode-server/bin/*/bin/code \
      "$home"/.vscode-server/bin/*/bin/code-server \
      "$home"/.vscode-server-insiders/bin/*/bin/code \
      "$home"/.vscode-server-insiders/bin/*/bin/code-server \
      /home/dev/.vscode-server/bin/*/bin/code \
      /home/dev/.vscode-server/bin/*/bin/code-server \
      /home/dev/.vscode-server-insiders/bin/*/bin/code \
      /home/dev/.vscode-server-insiders/bin/*/bin/code-server \
      /home/*/.vscode-server/bin/*/bin/code \
      /home/*/.vscode-server/bin/*/bin/code-server \
      /home/*/.vscode-server-insiders/bin/*/bin/code \
      /home/*/.vscode-server-insiders/bin/*/bin/code-server \
      /root/.vscode-server/bin/*/bin/code \
      /root/.vscode-server/bin/*/bin/code-server \
      /root/.vscode-server-insiders/bin/*/bin/code \
      /root/.vscode-server-insiders/bin/*/bin/code-server \
      /vscode/vscode-server/bin/*/bin/code \
      /vscode/vscode-server/bin/*/bin/code-server \
      /vscode/vscode-server/bin/*/*/bin/code \
      /vscode/vscode-server/bin/*/*/bin/code-server \
      /vscode/vscode-server-insiders/bin/*/bin/code \
      /vscode/vscode-server-insiders/bin/*/bin/code-server \
      /vscode/vscode-server-insiders/bin/*/*/bin/code \
      /vscode/vscode-server-insiders/bin/*/*/bin/code-server
    do
      if [ -x "$c" ]; then
        printf "%s" "$c"
        exit 0
      fi
    done

    exit 1
  ' 2>/dev/null
}

# List extension IDs installed in a running container's editor (as the dev
# user). v1 vscode: resolves the in-container VS Code Server code-server CLI
# (see _dce_ext_vscode_container_bin for why a bare `docker exec ... code` does
# not work) and runs `--list-extensions`. code-server implements this flag
# correctly from a plain host docker-exec (verified against VS Code Server
# 1.127); the remote-cli/code wrapper does not (it refuses outside a VS Code
# terminal). Returns the extension stream on stdout (empty if none installed).
# Returns 1 when the CLI cannot be resolved -- i.e. VS Code Server has not yet
# been injected, which is the case for any container the user has never opened
# in VS Code.
dce_ext_list_installed() {
  local editor="$1" container="$2"
  case "$editor" in
    vscode)
      local bin=""
      bin="$(_dce_ext_vscode_container_bin "$container")" || return 1
      [[ -n "$bin" ]] || return 1
      backend_exec "$container" "$bin" --list-extensions 2>/dev/null
      ;;
    *)
      dce_die "extension management for editor '$editor' is not yet supported."
      ;;
  esac
}

# List extension IDs installed in the HOST editor. v1 vscode: discovers the
# `code` binary (PATH, then the macOS .app bundle) and runs
# `code --list-extensions`. Returns 1 if no binary is found.
dce_ext_list_host() {
  local editor="$1"
  case "$editor" in
    vscode)
      local bin=""
      bin="$(_dce_ext_vscode_host_bin)" || return 1
      "$bin" --list-extensions 2>/dev/null
      ;;
    *)
      dce_die "extension management for editor '$editor' is not yet supported."
      ;;
  esac
}

# Install one extension into a running container (as the dev user). Idempotent
# (VS Code reports success if already installed). v1 vscode: resolves the
# in-container code-server CLI and runs `--install-extension <id>`. The
# code-server binary supports marketplace install from a plain host docker-exec
# (verified against VS Code Server 1.127); the remote-cli/code wrapper does not.
#
# Called by the attach-mode enforcement in dce_ext_enforce_declared (which
# scripts/editor.sh invokes before launch). Returns the backend_exec exit code.
dce_ext_install_one() {
  local editor="$1" container="$2" id="$3"
  case "$editor" in
    vscode)
      local bin=""
      bin="$(_dce_ext_vscode_container_bin "$container")" || return 1
      backend_exec "$container" "$bin" --install-extension "$id" >/dev/null 2>&1
      ;;
    *)
      dce_die "extension management for editor '$editor' is not yet supported."
      ;;
  esac
}

# Runtime extension drift between a running container and the declared manifest
# set. Returns one token on stdout (mirrors dce_check_git_token_drift):
#   match  installed set == declared set
#   drift  the sets differ (either direction)
#   absent running/adopted, but the `code` CLI is absent in the container
#   skip   cannot check: non-docker backend, container not running, or
#          pre-adoption (no manifests)
# Never exits non-zero (drift is informational, not fatal). The caller must have
# sourced lib/container-backend.sh and selected the backend via backend_use.
dce_ext_check_runtime_drift() {
  local project="$1" editor="$2" team_root="$3" user_root="$4" scopes_csv="$5"

  if ! backend_is_docker_compatible "$(backend_name 2>/dev/null || printf unknown)" \
     2>/dev/null; then
    printf 'skip'
    return 0
  fi
  if ! backend_is_running "$project" 2>/dev/null; then
    printf 'skip'
    return 0
  fi
  if ! dce_ext_manifests_exist "$editor" "$team_root" "$user_root" "$scopes_csv" 2>/dev/null; then
    printf 'skip'
    return 0
  fi

  local declared="" installed=""
  if ! declared="$(dce_ext_resolve_set "$editor" "$team_root" "$user_root" "$scopes_csv" 2>/dev/null)"; then
    printf 'skip'
    return 0
  fi

  if ! installed="$(dce_ext_list_installed "$editor" "$project" 2>/dev/null)"; then
    # VS Code Server (and thus `code`) has not been injected in-container yet.
    # Treat as "absent" so callers can distinguish this from broader skips.
    printf 'absent'
    return 0
  fi

  local d_sorted i_sorted
  d_sorted="$(printf '%s\n' "$declared" | grep -v '^$' | LC_ALL=C sort -u)"
  i_sorted="$(printf '%s\n' "$installed" | grep -v '^$' | LC_ALL=C sort -u)"
  if [[ "$d_sorted" == "$i_sorted" ]]; then
    printf 'match'
  else
    printf 'drift'
  fi
  return 0
}

# Enforce the declared extension set in a running container: install each
# declared-but-uninstalled ID via the in-container code-server CLI. This is the
# plans/extensions.md §6 attach-mode convergence path -- VS Code's
# attached-container open (the vscode-remote://attached-container URI used by
# dce_editor_launch_attach) does not reliably process
# customizations.vscode.extensions, so `dce editor` drives convergence itself.
#
# Idempotent and advisory: pre-adoption projects (no manifests) and first-ever
# opens (VS Code Server not yet injected -> no in-container code-server) are
# skipped with a notice; per-id install failures are reported but never fatal.
#
# Prints human-readable status to stdout. Never exits non-zero (convergence is
# best-effort; the editor launch must still proceed). The caller must have
# sourced lib/container-backend.sh, selected the backend via backend_use, and
# (for DC_TEAM_DIR/DC_USER_DIR) loaded the global config.
dce_ext_enforce_declared() {
  local project="$1" editor="$2" team_root="$3" user_root="$4" scopes_csv="$5"

  # Non-attach backends have no in-container extension store; nothing to enforce.
  if ! backend_is_docker_compatible "$(backend_name 2>/dev/null || printf unknown)" 2>/dev/null; then
    return 0
  fi
  if ! backend_is_running "$project" 2>/dev/null; then
    return 0
  fi
  # Pre-adoption: no manifests -> nothing declared -> leave runtime state alone.
  if ! dce_ext_manifests_exist "$editor" "$team_root" "$user_root" "$scopes_csv" 2>/dev/null; then
    return 0
  fi

  local declared=""
  if ! declared="$(dce_ext_resolve_set "$editor" "$team_root" "$user_root" "$scopes_csv" 2>/dev/null)"; then
    return 0
  fi
  # Manifests exist but resolve to nothing -> nothing to enforce.
  [[ -z "${declared// /}" ]] && return 0

  # First-ever open guard: code-server is injected by VS Code on attach, so it is
  # absent until the container has been opened once. Without it, install cannot
  # run; skip and let the next `dce editor` enforce after the server lands.
  local bin=""
  if ! bin="$(_dce_ext_vscode_container_bin "$project" 2>/dev/null)"; then
    echo "  editor extensions: skipped in-container install (VS Code Server not yet injected;"
    echo "                     re-open once in VS Code, then re-run 'dce editor $project')."
    return 0
  fi
  [[ -z "$bin" ]] && return 0

  local installed=""
  installed="$(dce_ext_list_installed "$editor" "$project" 2>/dev/null || true)"

  # Missing = declared \ installed. dce_ext_minus reads list A on stdin, list B
  # as args; word-splitting installed IDs is intended (IDs have no spaces).
  local missing=""
  # shellcheck disable=SC2086  # word-splitting installed IDs into args is intended
  missing="$(printf '%s\n' "$declared" | dce_ext_minus $installed)"
  local miss_count=0
  miss_count="$(printf '%s\n' "$missing" | grep -c -v '^$' 2>/dev/null || printf '0')"
  if [[ "$miss_count" -eq 0 ]]; then
    return 0
  fi

  echo "  editor extensions: installing $miss_count declared extension(s) into '$project'..."
  local id="" ok=0 fail=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if dce_ext_install_one "$editor" "$project" "$id"; then
      printf '    \xe2\x9c\x93 %s\n' "$id"
      ok=$((ok+1))
    else
      printf '    \xe2\x9c\x97 %s (install failed; will retry next \x27dce editor\x27)\n' "$id"
      fail=$((fail+1))
    fi
  done <<< "$missing"
  if [[ "$fail" -gt 0 ]]; then
    echo "  editor extensions: $ok installed, $fail failed (declared set converges once retries succeed)."
  else
    echo "  editor extensions: $ok installed."
  fi
  return 0
}

# Resolve the host `code` binary. Mirrors the vscode branch of
# dce_editor_find_binary in lib/editor.sh so the host extension list works on
# every supported platform. Discovery order:
#   1. $DCE_EDITOR_BIN override (any platform)
#   2. WSL2: Windows `code.exe` via interop first, then Linux `code`
#      (matches the dominant Docker Desktop + Dev Containers WSL2 setup)
#   3. macOS: `code` on PATH, then the .app bundle fallback
#   4. Linux: `code` on PATH
# Returns 1 if no candidate is found. Kept here (not sourced from lib/editor.sh)
# so this lib stays self-contained for its host-listing dispatch.
_dce_ext_vscode_host_bin() {
  if [[ -n "${DCE_EDITOR_BIN:-}" ]]; then
    if [[ -x "$DCE_EDITOR_BIN" ]]; then
      printf '%s' "$DCE_EDITOR_BIN"
      return 0
    fi
    return 1
  fi
  case "$(platform_os 2>/dev/null || printf unknown)" in
    wsl2)
      command -v code.exe >/dev/null 2>&1 && { command -v code.exe; return 0; }
      command -v code >/dev/null 2>&1 && { command -v code; return 0; }
      ;;
    macos)
      command -v code >/dev/null 2>&1 && { command -v code; return 0; }
      local app="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
      if [[ -x "$app" ]]; then
        printf '%s' "$app"
        return 0
      fi
      ;;
    linux|*)
      command -v code >/dev/null 2>&1 && { command -v code; return 0; }
      ;;
  esac
  return 1
}
